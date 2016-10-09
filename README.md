CUDA Path Tracer
================

**University of Pennsylvania, CIS 565: GPU Programming and Architecture, Project 3**

* Bowen Bao
* Tested on: Windows 10, i7-6700K @ 4.00GHz 32GB, GTX 1080 8192MB (Personal Computer)

## Overview

Here's the list of features of this project:

1. Core Features:
	* Shading kernel with BSDF evaluation.
	* Path continuation/termination using Stream Compaction.
	* First bounce intersection cache.
2. Extra Features:
	* Refraction with Frensel effects using Schlick's approximation.
	* Stochastic Sampled Antialiasing.
	* Direct lighting.

![](/img/cornell_final.png)

## Instruction to Run

You can change the setup of the program in file utilities.h, where First bounce caching, antialiasing and direct lighting are all togglable(note that since first bounce caching and antialiasing are conflicting features, only antialiasing is active if both are set to be true). 

## Performance Analysis
### Performance of different implementation

![](/img/process_time.png)

Here's the test result for each of the methods. The tests are run with the block size of 128. The average process time of each iteration is shown in the graph. We could observe that the total number of iterations doesn't affect the average performance very much. We could also observe that by using stream compaction, the average process time actually increases. 

![](/img/overhead.png)

This might due to that in this scenario, the overhead in our case here is mostly on cpu instead of gpu. Adding stream compaction is putting more pressure on the cpu side, since it has to copy the data from device to host and start the stream compaction procedure. Adding stream compaction may be more useful for higher resolution rendering, where the computation on the gpu side becomes the bottleneck.

## Extra Credits
### Refraction with Frensel effects using Schlick's approximation.
In this part I extended the shader to deal with refraction rays. The final effect can be viewed in the following graph. I followed the algorithm of http://www.scratchapixel.com/lessons/3d-basic-rendering/introduction-to-shading/reflection-refraction-fresnel in my implementation. As we could observe in the graph, we have both reflection and refraction for the glass material.
![](/img/cornell_glass.png)

### Stochastic Sampled Antialiasing.
I followed the algorithms in http://paulbourke.net/miscellaneous/aliasing/ when implementing the antialiasing feature. Observe in the following graph that we achieved much better effects with same performance.
![](/img/antialiasing.png)

### Direct lighting.
Most of the rays are wasted in our previous implementation, as they didn't contribute any color information because they hadn't hit the light source in their "last" bounce. With direct lighting however, we tried to make use of that information by adding an additional bounce at the end to reach the light source and record the color. Following are the comparison of rendering with and without direct lighting. At the same time, we are also comparing how the number of iterations affect the final result. 
![](/img/cornell_dl_5000_1000.png)
![](/img/cornell_5000_1000.png)

As we could see in the graph, rendering with direct lighting achieves a brighter image under the same iteration. It also achieves a cleaner image much faster than rendering without direct lighting. 
