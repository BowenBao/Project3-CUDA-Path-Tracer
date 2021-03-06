#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/remove.h>

#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"

#define ERRORCHECK 1

#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)
void checkCUDAErrorFn(const char *msg, const char *file, int line) {
#if ERRORCHECK
    cudaDeviceSynchronize();
    cudaError_t err = cudaGetLastError();
    if (cudaSuccess == err) {
        return;
    }

    fprintf(stderr, "CUDA error");
    if (file) {
        fprintf(stderr, " (%s:%d)", file, line);
    }
    fprintf(stderr, ": %s: %s\n", msg, cudaGetErrorString(err));
#  ifdef _WIN32
    getchar();
#  endif
    exit(EXIT_FAILURE);
#endif
}

__host__ __device__
thrust::default_random_engine makeSeededRandomEngine(int iter, int index, int depth) {
    int h = utilhash((1 << 31) | (depth << 22) | iter) ^ utilhash(index);
    return thrust::default_random_engine(h);
}

inline int ilog2(int x) {
	int lg = 0;
	while (x >>= 1) {
		++lg;
	}
	return lg;
}

inline int ilog2ceil(int x) {
	return ilog2(x - 1) + 1;
}

// stream compaction
namespace StreamCompaction {
	namespace Common {
		__global__ void kernMapToBoolean(int n, int *bools, const PathSegment *idata);

		__global__ void kernScatter(int n, int *odata,
			const int *idata, const int *bools, const int *indices);

		/**
		* Maps an array to an array of 0s and 1s for stream compaction. Elements
		* which map to 0 will be removed, and elements which map to 1 will be kept.
		*/
		__global__ void kernMapToBoolean(int n, int *bools, const PathSegment *idata, bool compactOnes) {
			// TODO
			int index = (blockIdx.x * blockDim.x) + threadIdx.x;
			if (index >= n) return;
			int flagValue = 0;
			if (compactOnes) flagValue = 1;
			if (DIRECT_LIGHTING)
			{
				if (!idata[index].bounceCompleted) bools[index] = flagValue;
				else bools[index] = 1 - flagValue;
			}
			else
			{
				if (idata[index].remainingBounces > 0) bools[index] = flagValue;
				else bools[index] = 1 - flagValue;
			}
		}

		/**
		* Performs scatter on an array. That is, for each element in idata,
		* if bools[idx] == 1, it copies idata[idx] to odata[indices[idx]].
		*/
		__global__ void kernScatter(int n, PathSegment *odata,
			const PathSegment *idata, const int *bools, const int *indices) {
			// TODO
			int index = (blockIdx.x * blockDim.x) + threadIdx.x;
			if (index >= n) return;
			if (bools[index] == 1)
			{
				odata[indices[index]] = idata[index];
			}
		}


		__global__ void kernScanUpSweep(int N, int interval, int *data)
		{
			// up sweep
			int index = (blockIdx.x * blockDim.x) + threadIdx.x;
			int real_index = index * interval * 2;
			if (real_index >= N) return;
			int cur_index = real_index + 2 * interval - 1;
			int last_index = real_index + interval - 1;
			if (cur_index >= N) return;

			data[cur_index] = data[last_index] + data[cur_index];
		}

		__global__ void kernScanDownSweep(int N, int interval, int *data)
		{
			// down seep
			int index = (blockIdx.x * blockDim.x) + threadIdx.x;
			int real_index = index * interval * 2;
			if (real_index >= N) return;
			int last_index = real_index + interval - 1;
			int cur_index = real_index + 2 * interval - 1;
			if (cur_index >= N) return;
			int tmp = data[last_index];
			data[last_index] = data[cur_index];
			data[cur_index] += tmp;
		}

		__global__ void kernMapDigitToBoolean(int N, int digit, int *odata, const int *idata)
		{
			int index = (blockIdx.x * blockDim.x) + threadIdx.x;
			if (index >= N) return;
			int mask = 1 << digit;
			if ((idata[index] & mask) == 0)
			{
				if (digit != 31) odata[index] = 0;
				else odata[index] = 1;
			}
			else
			{
				if (digit != 31) odata[index] = 1;
				else odata[index] = 0;
			}
		}

		__global__ void kernFlipBoolean(int N, int *odata, const int *idata)
		{
			int index = (blockIdx.x * blockDim.x) + threadIdx.x;
			if (index >= N) return;
			if (idata[index] == 0)
			{
				odata[index] = 1;
			}
			else
			{
				odata[index] = 0;
			}
		}

		__global__ void kernSortOneRound(int N, int *bools, int *indices_zero, int *indices_one, int maxFalse,
			int *odata, const int *idata)
		{
			int index = (blockIdx.x * blockDim.x) + threadIdx.x;
			if (index >= N) return;
			if (bools[index] == 0)
			{
				// false;
				odata[indices_zero[index]] = idata[index];
			}
			else
			{
				odata[indices_one[index] + maxFalse] = idata[index];
			}
		}

		/**
		* Performs prefix-sum (aka scan) on idata, storing the result into odata.
		*/
		float scan(int n, int *odata, const int *idata, int blockSize) {
			// record time
			float diff(0);
			cudaEvent_t start, end;
			cudaEventCreate(&start);
			cudaEventCreate(&end);
			cudaEventRecord(start, 0);

			int loop_times = ilog2ceil(n);
			int totalNum = 1;
			for (int i = 0; i < loop_times; ++i)
			{
				totalNum *= 2;
			}
			int interval = 1;
			//printf("total looptimes: %d, total num %d\n", loop_times, totalNum);

			int *tmp_data;
			cudaMalloc((void**)&tmp_data, totalNum * sizeof(int));
			cudaMemset(tmp_data, 0, totalNum);
			cudaMemcpy(tmp_data, idata, n * sizeof(int), cudaMemcpyHostToDevice);


			// up sweep
			for (int i = 0; i < loop_times; ++i)
			{
				dim3 fullBlocksPerGrid((totalNum / (interval * 2) + blockSize - 1) / blockSize);
				kernScanUpSweep << <fullBlocksPerGrid, blockSize >> >(totalNum, interval, tmp_data);
				interval *= 2;
			}

			// down sweep
			cudaMemset(&tmp_data[totalNum - 1], 0, sizeof(int));

			for (int i = 0; i < loop_times; ++i)
			{
				dim3 fullBlocksPerGrid((totalNum / interval + blockSize - 1) / blockSize);
				interval /= 2;
				kernScanDownSweep << <fullBlocksPerGrid, blockSize >> >(totalNum, interval, tmp_data);
			}

			cudaMemcpy(odata, tmp_data, n*sizeof(int), cudaMemcpyDeviceToHost);
			cudaFree(tmp_data);

			cudaEventRecord(end, 0);
			cudaEventSynchronize(start);
			cudaEventSynchronize(end);
			cudaEventElapsedTime(&diff, start, end);

			//printf("GPU scan took %fms\n", diff);
			return diff;
		}

		/**
		* Performs stream compaction on idata, storing the result into odata.
		* All zeroes are discarded.
		*
		* @param n      The number of elements in idata.
		* @param odata  The array into which to store elements.
		* @param idata  The array of elements to compact.
		* @returns      The number of elements remaining after compaction.
		*/
		int pathCompact(int n, PathSegment *odata, const PathSegment *idata, double &time, int blockSize, bool compactOnes) {
			// record time
			float diff(0);
			cudaEvent_t start, end;
			cudaEventCreate(&start);
			cudaEventCreate(&end);
			cudaEventRecord(start, 0);

			dim3 fullBlocksPerGrid((n + blockSize - 1) / blockSize);

			int *indices_cuda;
			int *bools_cuda;

			int *indices = new int[n];
			int *bools = new int[n];

			cudaMalloc((void**)&indices_cuda, n * sizeof(int));
			cudaMalloc((void**)&bools_cuda, n * sizeof(int));

			Common::kernMapToBoolean << <fullBlocksPerGrid, blockSize >> >(n, bools_cuda, idata, compactOnes);

			cudaMemcpy(bools, bools_cuda, n * sizeof(int), cudaMemcpyDeviceToHost);

			scan(n, indices, bools, blockSize);

			cudaMemcpy(indices_cuda, indices, n * sizeof(int), cudaMemcpyHostToDevice);

			Common::kernScatter << <fullBlocksPerGrid, blockSize >> >(n, odata, idata, bools_cuda, indices_cuda);

			int remain_elem;
			cudaMemcpy(&remain_elem, &indices_cuda[n - 1], sizeof(int), cudaMemcpyDeviceToHost);
			remain_elem += bools[n - 1];

			delete[] bools;
			delete[] indices;

			cudaFree(indices_cuda);
			cudaFree(bools_cuda);

			cudaEventRecord(end, 0);
			cudaEventSynchronize(start);
			cudaEventSynchronize(end);
			cudaEventElapsedTime(&diff, start, end);

			//printf("GPU compact took %fms\n", diff);

			time = diff;
			return remain_elem;
		}


	}
}




//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution,
        int iter, glm::vec3* image) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;

    if (x < resolution.x && y < resolution.y) {
        int index = x + (y * resolution.x);
        glm::vec3 pix = image[index];

        glm::ivec3 color;
        color.x = glm::clamp((int) (pix.x / iter * 255.0), 0, 255);
        color.y = glm::clamp((int) (pix.y / iter * 255.0), 0, 255);
        color.z = glm::clamp((int) (pix.z / iter * 255.0), 0, 255);

        // Each thread writes one pixel location in the texture (textel)
        pbo[index].w = 0;
        pbo[index].x = color.x;
        pbo[index].y = color.y;
        pbo[index].z = color.z;
    }
}

static Scene * hst_scene = NULL;
static glm::vec3 * dev_image = NULL;
static Geom * dev_geoms = NULL;
static Material * dev_materials = NULL;
static PathSegment * dev_paths = NULL;
static ShadeableIntersection * dev_intersections = NULL;
static ShadeableIntersection * dev_intersections_cache = NULL;
// TODO: static variables for device memory, any extra info you need, etc
// ...

void pathtraceInit(Scene *scene) {
    hst_scene = scene;
    const Camera &cam = hst_scene->state.camera;
    const int pixelcount = cam.resolution.x * cam.resolution.y;

    cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
    cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));

  	cudaMalloc(&dev_paths, pixelcount * sizeof(PathSegment));

  	cudaMalloc(&dev_geoms, scene->geoms.size() * sizeof(Geom));
  	cudaMemcpy(dev_geoms, scene->geoms.data(), scene->geoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);

  	cudaMalloc(&dev_materials, scene->materials.size() * sizeof(Material));
  	cudaMemcpy(dev_materials, scene->materials.data(), scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);

  	cudaMalloc(&dev_intersections, pixelcount * sizeof(ShadeableIntersection));
  	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

	cudaMalloc(&dev_intersections_cache, pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_intersections_cache, 0, pixelcount * sizeof(ShadeableIntersection));

    // TODO: initialize any extra device memeory you need

    checkCUDAError("pathtraceInit");
}

void pathtraceFree() {
    cudaFree(dev_image);  // no-op if dev_image is null
  	cudaFree(dev_paths);
  	cudaFree(dev_geoms);
  	cudaFree(dev_materials);
  	cudaFree(dev_intersections);
	cudaFree(dev_intersections_cache);
    // TODO: clean up any extra device memory you created

    checkCUDAError("pathtraceFree");
}

__host__ __device__ float getFresnelCoef(const glm::vec3& direction, const glm::vec3 materialNorm)
{
	float r0 = glm::pow((GLASS_AIR_RATIO - 1.0f) / (GLASS_AIR_RATIO + 1.0f), 2);
	return r0 + (1.0f - r0) * glm::pow(1.0f - glm::dot(materialNorm, -direction), 5);
}


/**
* Generate PathSegments with rays from the camera through the screen into the
* scene, which is the first bounce of rays.
*
* Antialiasing - add rays for sub-pixel sampling
* motion blur - jitter rays "in time"
* lens effect - jitter ray origin positions based on a lens
*/
__global__ void generateRayFromCamera(Camera cam, int iter, int traceDepth, PathSegment* pathSegments)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < cam.resolution.x && y < cam.resolution.y) {
		int index = x + (y * cam.resolution.x);
			
		thrust::default_random_engine rng = makeSeededRandomEngine(iter, index, 0);
		thrust::uniform_real_distribution<float> u01(0, 1);

		PathSegment & segment = pathSegments[index];

		segment.ray.origin = cam.position;
		segment.color = glm::vec3(1.0f, 1.0f, 1.0f);

		// TODO: implement antialiasing by jittering the ray
		float x_anti = x;
		float y_anti = y;
		if (ANTIALIASING && !FIRST_BOUNCE_CACHE)
		{
			x_anti += u01(rng) / 2;
			y_anti += u01(rng) / 2;
		}

		segment.ray.direction = glm::normalize(cam.view
			- cam.right * cam.pixelLength.x * ((float)x_anti - (float)cam.resolution.x * 0.5f)
			- cam.up * cam.pixelLength.y * ((float)y_anti - (float)cam.resolution.y * 0.5f)
			);
		segment.ray.outside = true;

		segment.pixelIndex = index;
		segment.remainingBounces = traceDepth;
		segment.bounceCompleted = false;
	}
}

// TODO:
// computeIntersections handles generating ray intersections ONLY.
// Generating new rays is handled in your shader(s).
// Feel free to modify the code below.
__global__ void computeIntersections(
	int depth
	, int num_paths
	, PathSegment * pathSegments
	, Geom * geoms
	, int geoms_size
	, ShadeableIntersection * intersections
	)
{
	int path_index = blockIdx.x * blockDim.x + threadIdx.x;

	if (path_index < num_paths && pathSegments[path_index].remainingBounces > 0)
	{
		PathSegment pathSegment = pathSegments[path_index];

		float t;
		glm::vec3 intersect_point;
		glm::vec3 normal;
		float t_min = FLT_MAX;
		int hit_geom_index = -1;
		//bool outside = true;

		glm::vec3 tmp_intersect;
		glm::vec3 tmp_normal;

		// naive parse through global geoms

		for (int i = 0; i < geoms_size; i++)
		{
			Geom & geom = geoms[i];

			if (geom.type == CUBE)
			{
				t = boxIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, pathSegment.ray.outside);
			}
			else if (geom.type == SPHERE)
			{
				t = sphereIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, pathSegment.ray.outside);
			}
			// TODO: add more intersection tests here... triangle? metaball? CSG?

			// Compute the minimum t from the intersection tests to determine what
			// scene geometry object was hit first.
			if (t > 0.0f && t_min > t)
			{
				t_min = t;
				hit_geom_index = i;
				intersect_point = tmp_intersect;
				normal = tmp_normal;
			}
		}

		if (hit_geom_index == -1)
		{
			intersections[path_index].t = -1.0f;
		}
		else
		{
			//The ray hits something
			intersections[path_index].t = t_min;
			intersections[path_index].materialId = geoms[hit_geom_index].materialid;
			intersections[path_index].surfaceNormal = normal;
		}
	}
}

__global__ void computeDirectLighting(int iter, int num_paths, PathSegment *dev_paths, const Geom &dev_geoms)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx >= num_paths) return;

	glm::vec3 lightPoint = dev_geoms.translation;
	dev_paths[idx].ray.direction = glm::normalize(lightPoint - dev_paths[idx].ray.origin);
}

__global__ void shadeDirectLightingMaterial(int iter, int num_paths,
	ShadeableIntersection *shadeableIntersections, PathSegment *pathSegment, Material *materials)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx >= num_paths) return;
	ShadeableIntersection intersection = shadeableIntersections[idx];
	if (intersection.t > 0.0f)
	{
		Material material = materials[intersection.materialId];
		if (material.emittance > 0.0f)
		{
			// hit light object
			pathSegment[idx].color *= material.color * material.emittance;
			pathSegment[idx].bounceCompleted = true;
		}
	}
}


__global__ void shadeRealMaterial(
	int iter,
	int num_paths,
	ShadeableIntersection *shadeableIntersections,
	PathSegment *pathSegments,
	Material *materials)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx >= num_paths) return;
	if (pathSegments[idx].remainingBounces <= 0) return;
	ShadeableIntersection intersection = shadeableIntersections[idx];
	if (intersection.t > 0.0f)
	{
		thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, 0);
		thrust::uniform_real_distribution<float> u01(0, 1);

		Material material = materials[intersection.materialId];
		glm::vec3 materialColor = material.color;

		if (material.emittance > 0.0f)
		{
			// Object is light
			pathSegments[idx].color *= materialColor *material.emittance;
			pathSegments[idx].remainingBounces = 0;
			pathSegments[idx].bounceCompleted = true;
		}
		else
		{
			pathSegments[idx].color *= materialColor;

			// BSDF
			if (material.hasReflective)
			{
				// ideal reflection
				glm::vec3 new_direction = glm::reflect(pathSegments[idx].ray.direction, intersection.surfaceNormal);
				glm::vec3 new_origin = pathSegments[idx].ray.direction * intersection.t + pathSegments[idx].ray.origin + EPSILON * new_direction;

				pathSegments[idx].ray.direction = new_direction;
				pathSegments[idx].ray.origin = new_origin;

			}
			else if (material.hasRefractive)
			{
				float cosi = glm::dot(pathSegments[idx].ray.direction, intersection.surfaceNormal);
				float etai = 1, etat = 1.5;
				glm::vec3 n = intersection.surfaceNormal;
				if (cosi < 0)
				{
					cosi = -cosi;
				}
				else
				{
					float tmp = etai;
					etai = etat;
					etat = tmp;
				}

				float eta = etai / etat;
				float k = 1 - eta * eta * (1 - cosi * cosi);

				if (k < 0)
				{
					// reflection
					glm::vec3 new_direction = glm::reflect(pathSegments[idx].ray.direction, intersection.surfaceNormal);
					glm::vec3 new_origin = pathSegments[idx].ray.direction * intersection.t + pathSegments[idx].ray.origin + EPSILON * new_direction;

					pathSegments[idx].ray.direction = new_direction;
					pathSegments[idx].ray.origin = new_origin;
				}
				else
				{
					// refraction
					glm::vec3 new_direction = (eta * cosi - glm::sqrt(k)) * n + pathSegments[idx].ray.direction * eta;
					glm::vec3 new_origin = pathSegments[idx].ray.direction * intersection.t + pathSegments[idx].ray.origin + EPSILON_GLASS * new_direction;
					
					pathSegments[idx].ray.direction = new_direction;
					pathSegments[idx].ray.origin = new_origin;
				}
			}
			else
			{
				// diffuse
				glm::vec3 new_direction = calculateRandomDirectionInHemisphere(intersection.surfaceNormal,
					rng);
				glm::vec3 new_origin = pathSegments[idx].ray.direction * intersection.t + pathSegments[idx].ray.origin + EPSILON * new_direction;

				pathSegments[idx].ray.direction = new_direction;
				pathSegments[idx].ray.origin = new_origin;
			}
			pathSegments[idx].remainingBounces--;

			if (!DIRECT_LIGHTING && pathSegments[idx].remainingBounces <= 0)
			{
				pathSegments[idx].color = glm::vec3(0.0f);
			}
		}
	}
	else
	{
		// hit nothing
		pathSegments[idx].color = glm::vec3(0.0f);
		pathSegments[idx].remainingBounces = 0;
		pathSegments[idx].bounceCompleted = true;
	}

}

// Add the current iteration's output to the overall image
__global__ void finalGather(int nPaths, glm::vec3 * image, PathSegment * iterationPaths)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < nPaths)
	{
		PathSegment iterationPath = iterationPaths[index];
		image[iterationPath.pixelIndex] += iterationPath.color;
	}
}

struct PathRemainingBounceZeroTest
{
	__host__ __device__
	bool operator()(const PathSegment& a)
	{
		return a.remainingBounces <= 0;
	}
};

struct PathRemainingBounceNonZeroTest
{
	__host__ __device__
		bool operator()(const PathSegment& a)
	{
		return a.remainingBounces > 0;
	}
};


/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(uchar4 *pbo, int frame, int iter) {
	const int traceDepth = hst_scene->state.traceDepth;
	printf("Trace depth : %d\n", traceDepth);
	const Camera &cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;
	const int maxDepth = hst_scene->state.traceDepth;

	// 2D block for generating ray from camera
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// 1D block for path tracing
	const int blockSize1d = 128;

	///////////////////////////////////////////////////////////////////////////

	// Recap:
	// * Initialize array of path rays (using rays that come out of the camera)
	//   * You can pass the Camera object to that kernel.
	//   * Each path ray must carry at minimum a (ray, color) pair,
	//   * where color starts as the multiplicative identity, white = (1, 1, 1).
	//   * This has already been done for you.
	// * For each depth:
	//   * Compute an intersection in the scene for each path ray.
	//     A very naive version of this has been implemented for you, but feel
	//     free to add more primitives and/or a better algorithm.
	//     Currently, intersection distance is recorded as a parametric distance,
	//     t, or a "distance along the ray." t = -1.0 indicates no intersection.
	//     * Color is attenuated (multiplied) by reflections off of any object
	//   * TODO: Stream compact away all of the terminated paths.
	//     You may use either your implementation or `thrust::remove_if` or its
	//     cousins.
	//     * Note that you can't really use a 2D kernel launch any more - switch
	//       to 1D.
	//   * TODO: Shade the rays that intersected something or didn't bottom out.
	//     That is, color the ray by performing a color computation according
	//     to the shader, then generate a new ray to continue the ray path.
	//     We recommend just updating the ray's PathSegment in place.
	//     Note that this step may come before or after stream compaction,
	//     since some shaders you write may also cause a path to terminate.
	// * Finally, add this iteration's results to the image. This has been done
	//   for you.

	// TODO: perform one iteration of path tracing

	generateRayFromCamera << <blocksPerGrid2d, blockSize2d >> >(cam, iter, traceDepth, dev_paths);
	checkCUDAError("generate camera ray");

	int depth = 0;
	PathSegment* dev_path_end = dev_paths + pixelcount;
	int num_paths = dev_path_end - dev_paths;

	//PathSegment *tmp_segment = new PathSegment[pixelcount];
	//PathSegment *tmp_segment_end = tmp_segment + pixelcount;

	PathSegment *tmp_segment;
	cudaMalloc(&tmp_segment, pixelcount * sizeof(PathSegment));
	PathSegment *tmp_segment_end = tmp_segment + pixelcount;

	// --- PathSegment Tracing Stage ---
	// Shoot ray into scene, bounce between objects, push shading chunks

	bool iterationComplete = false;
	bool firstBounce = FIRST_BOUNCE_CACHE;
	while (!iterationComplete) {
		num_paths = dev_path_end - dev_paths;
		printf("New iteration: %d paths left\n", num_paths);

		// clean shading chunks
		cudaMemset(dev_intersections, 0, num_paths * sizeof(ShadeableIntersection));

		// tracing
		dim3 numblocksPathSegmentTracing = (num_paths + blockSize1d - 1) / blockSize1d;

		if (!firstBounce)
		{
			computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
				depth
				, num_paths
				, dev_paths
				, dev_geoms
				, hst_scene->geoms.size()
				, dev_intersections
				);
			checkCUDAError("trace one bounce");
			cudaDeviceSynchronize();
			depth++;
			printf("Compute intersection \n");
		}
		else if (iter == 1)
		{
			// first bounce of first iteration, construct cache.			
			computeIntersections << < numblocksPathSegmentTracing, blockSize1d >> > (
				depth,
				num_paths,
				dev_paths,
				dev_geoms,
				hst_scene->geoms.size(),
				dev_intersections_cache);
			checkCUDAError("trace one bounce");
			cudaDeviceSynchronize();
			depth++;
			printf("Compute first bounce intersection \n");
		}

		// TODO:
		// --- Shading Stage ---
		// Shade path segments based on intersections and generate new rays by
		// evaluating the BSDF.
		// Start off with just a big kernel that handles all the different
		// materials you have in the scenefile.
		// TODO: compare between directly shading the path segments and shading
		// path segments that have been reshuffled to be contiguous in memory.

		if (firstBounce)
		{
			shadeRealMaterial << <numblocksPathSegmentTracing, blockSize1d >> >(
				iter,
				num_paths,
				dev_intersections_cache,
				dev_paths,
				dev_materials);
			checkCUDAError("shade one bounce");
			printf("Shade one bounce using cache complete\n");
		}
		else
		{
			shadeRealMaterial << <numblocksPathSegmentTracing, blockSize1d >> >(
				iter,
				num_paths,
				dev_intersections,
				dev_paths,
				dev_materials);
			checkCUDAError("shade one bounce");
			printf("Shade one bounce complete\n");
		}

		// stream compaction
		//cudaMemcpy(tmp_segment, dev_paths, num_paths * sizeof(PathSegment), cudaMemcpyDeviceToDevice);
		if (COMPACTION)
		{
			double time;
			// first compact ones with remaining bounces.
			int nonZeroCount = StreamCompaction::Common::pathCompact(num_paths, tmp_segment, dev_paths, time, blockSize1d, true);
			// dev_path_end should be the start point of 0 on the original dev_paths.
			dev_path_end = dev_paths + nonZeroCount;
			// tmp_segment_end should be the start point of 0 on tmp_segment.
			tmp_segment_end = tmp_segment + nonZeroCount;
			// now we have 1s on tmp_segment to tmp_segment_end. we need to compact 0 as well.
			int zeroCount = StreamCompaction::Common::pathCompact(num_paths, tmp_segment_end, dev_paths, time, blockSize1d, false);
			// now we have 0s as well, copy both back to dev_paths.
			cudaMemcpy(dev_paths, tmp_segment, nonZeroCount * sizeof(PathSegment), cudaMemcpyDeviceToDevice);
			cudaMemcpy(dev_path_end, tmp_segment_end, zeroCount * sizeof(PathSegment), cudaMemcpyDeviceToDevice);
			checkCUDAError("Stream compaction.");
		}
		else if (depth >= maxDepth)
		{
			iterationComplete = true;
			printf("Iteration complete for no compaction\n");
		}

		if (DIRECT_LIGHTING)
		{
			// check depth against maxDepth
			if (depth >= maxDepth)
			{
				num_paths = dev_path_end - dev_paths;
				dim3 numblocksPathSegmentTracing = (num_paths + blockSize1d - 1) / blockSize1d;
				// pick one light source
				int geomIdx = 0;
				for (auto geom : hst_scene->geoms)
				{
					if (hst_scene->materials[geom.materialid].emittance > 0)
					{
						break;
					}
					geomIdx++;
				}

				if (geomIdx >= hst_scene->geoms.size())
				{
					// no light source found.
					iterationComplete = true;
					break;
				}

				// apply direct lighting. Update final ray direction.
				computeDirectLighting<<<numblocksPathSegmentTracing, blockSize1d>>>(iter, num_paths, dev_paths, dev_geoms[geomIdx]);
				// compute intersection.
				// clean shading chunks
				cudaMemset(dev_intersections, 0, num_paths * sizeof(ShadeableIntersection));
				computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
					depth
					, num_paths
					, dev_paths
					, dev_geoms
					, hst_scene->geoms.size()
					, dev_intersections
					);
				checkCUDAError("trace direct lighting bounce");
				cudaDeviceSynchronize();
				depth++;
				printf("Compute direct lighting intersection \n");
				shadeDirectLightingMaterial<<<numblocksPathSegmentTracing, blockSize1d>>>(iter, num_paths, dev_intersections, dev_paths, dev_materials);
				checkCUDAError("shade direct lighting bounce");
				printf("Shade direct lighting bounce using complete\n");

				iterationComplete = true;
			}
		}
		else
		{
			if (dev_path_end <= dev_paths)
			{
				iterationComplete = true;
				printf("Complete one iteration...");
			}
		}

		firstBounce = false;
	}

	// Assemble this iteration and apply it to the image
	dim3 numBlocksPixels = (pixelcount + blockSize1d - 1) / blockSize1d;
	finalGather << <numBlocksPixels, blockSize1d >> >(pixelcount, dev_image, dev_paths);

	///////////////////////////////////////////////////////////////////////////

	// Send results to OpenGL buffer for rendering
	sendImageToPBO << <blocksPerGrid2d, blockSize2d >> >(pbo, cam.resolution, iter, dev_image);

	// Retrieve image from GPU
	cudaMemcpy(hst_scene->state.image.data(), dev_image,
		pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);

	cudaFree(tmp_segment);
	checkCUDAError("pathtrace");
}







