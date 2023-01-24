source "lib/c.tcl"
source "play/bullseye-play.tcl"

# First, generate a synthetic JPEG file with a bullseye fiducial in
# it. This is our fake 'camera image'.

set ps [programToPs 66 "hello"]
set fd [file tempfile psfile psfile.ps]; puts $fd $ps; close $fd
exec convert $psfile -quality 300 -colorspace RGB [file rootname $psfile].jpeg
set jpegfile [file rootname $psfile].jpeg

# Next, load the fiducial into an in-memory image_t bitmap.

rename [c create] ic
ic include <stdlib.h>
ic code "#undef EXTERN"
ic include <jpeglib.h>
source "pi/cUtils.tcl"
defineImageType ic
ic proc loadImageFromJpeg {char* filename} image_t {
    struct jpeg_decompress_struct cinfo;
    struct jpeg_error_mgr jerr;
    cinfo.err = jpeg_std_error(&jerr);
    jpeg_create_decompress(&cinfo);

    FILE* f = fopen(filename, "rb");
    jpeg_stdio_src(&cinfo, f);

    if (jpeg_read_header(&cinfo, TRUE) != JPEG_HEADER_OK) { printf("Fail\n"); exit(1); }
    jpeg_start_decompress(&cinfo);

    image_t dest = (image_t) {
        .width = cinfo.output_width,
        .height = cinfo.output_height,
        .components = cinfo.output_components,
        .bytesPerRow = cinfo.output_width * cinfo.output_components,
        .data = ckalloc(cinfo.output_width * cinfo.output_height * cinfo.output_components)
    };
    
    while (cinfo.output_scanline < cinfo.output_height) {
        unsigned char *buffer_array[1];
        buffer_array[0] = dest.data + cinfo.output_scanline * dest.bytesPerRow;
        jpeg_read_scanlines(&cinfo, buffer_array, 1);
    }
    jpeg_finish_decompress(&cinfo);
    jpeg_destroy_decompress(&cinfo);
    fclose(f);
    return dest;
}
ic cflags -ljpeg
ic compile

set image [loadImageFromJpeg $jpegfile]
puts $image

# Now set up the GPU and prepare to feed the bitmap into the GPU.

source "play/Display_vk.tcl"
namespace eval Display {
    dc include <string.h>
    dc code {
        VkDescriptorSetLayout computeDescriptorSetLayout;
        VkPipelineLayout computePipelineLayout;
        VkPipeline computePipeline;
        VkCommandBuffer computeCommandBuffer;
    }
    defineImageType dc
    dc rtype VkDeviceMemory {
        Tcl_SetObjResult(interp, Tcl_ObjPrintf("($rtype) 0x%" PRIxPTR, (uintptr_t) rv));
        return TCL_OK;
    }
    dc argtype VkDeviceMemory {
        if (sscanf(Tcl_GetString($obj), "($argtype) 0x%p", &$argname) != 1) {
            return TCL_ERROR;
        }
    }

    dc typedef uint32_t VkMemoryPropertyFlags
    dc proc findMemoryType {int typeFilter VkMemoryPropertyFlags properties} int [csubst {
        VkPhysicalDeviceMemoryProperties memProperties;
        $[vkfn vkGetPhysicalDeviceMemoryProperties]
        vkGetPhysicalDeviceMemoryProperties(physicalDevice, &memProperties);

        for (uint32_t i = 0; i < memProperties.memoryTypeCount; i++) {
            if ((typeFilter & (1 << i)) && (memProperties.memoryTypes[i].propertyFlags & properties) == properties) {
                return i;
            }
        }
        exit(1);
    }]

    dc typedef uint64_t VkDeviceSize
    dc typedef uint32_t VkBufferUsageFlags
    dc proc createBuffer {VkDeviceSize size VkBufferUsageFlags usage VkMemoryPropertyFlags properties
                          VkBuffer* outBuffer VkDeviceMemory* outMemory} void [csubst {
        VkBufferCreateInfo createInfo = {
            .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = 0,
            .flags = 0,
            .size = size,
            .usage = usage,
            .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = 0
        };
        $[vktry {vkCreateBuffer(device, &createInfo, NULL, outBuffer)}]

        VkMemoryRequirements memRequirements;
        vkGetBufferMemoryRequirements(device, *outBuffer, &memRequirements);

        VkMemoryAllocateInfo allocInfo = {
            .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = memRequirements.size,
            .memoryTypeIndex = findMemoryType(memRequirements.memoryTypeBits, properties)
        };
        $[vktry {vkAllocateMemory(device, &allocInfo, NULL, outMemory)}]
        vkBindBufferMemory(device, *outBuffer, *outMemory, 0);
    }]

    dc proc createBufferAndCopyImage {image_t im
                                      VkBuffer* outBuffer VkDeviceMemory* outBufferMemory} void [csubst {
        size_t imSize = im.bytesPerRow * im.height * im.components;
        createBuffer(imSize,
                     VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                     VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                     outBuffer, outBufferMemory);

        void *data;
        $[vkfn vkMapMemory]
        $[vktry {vkMapMemory(device, *outBufferMemory, 0, imSize, 0, &data)}]
        memcpy(data, im.data, imSize);
        $[vkfn vkUnmapMemory]
        vkUnmapMemory(device, *outBufferMemory);
    }]

    dc proc setupBuffers {} void [csubst {
        // Based on:
        // https://bakedbits.dev/posts/vulkan-compute-example/
        // https://lisyarus.github.io/blog/graphics/2022/04/21/compute-blur.html
        // https://www.youtube.com/watch?v=KN9nHo9kvZs
        uint32_t shaderCode[] = $[glslc -fshader-stage=comp {
            #version 450
            layout(local_size_x = 16, local_size_y = 16) in;
            layout(rgba8, binding = 0) uniform restrict readonly image2D u_input_image;
            layout(rgba8, binding = 1) uniform restrict writeonly image2D u_output_image;

            const int M = 16;
            const int N = 2 * M + 1;
            // sigma = 10
            const float coeffs[N] = float[N](
	        0.012318109844189502,
                0.014381474814203989,
                0.016623532195728208,
                0.019024086115486723,
                0.02155484948872149,
                0.02417948052890078,
                0.02685404941667096,
                0.0295279624870386,
                0.03214534135442581,
                0.03464682117793548,
                0.0369716985390341,
                0.039060328279673276,
                0.040856643282313365,
                0.04231065439216247,
                0.043380781642569775,
                0.044035873841196206,
                0.04425662519949865,
                0.044035873841196206,
                0.043380781642569775,
                0.04231065439216247,
                0.040856643282313365,
                0.039060328279673276,
                0.0369716985390341,
                0.03464682117793548,
                0.03214534135442581,
                0.0295279624870386,
                0.02685404941667096,
                0.02417948052890078,
                0.02155484948872149,
                0.019024086115486723,
                0.016623532195728208,
                0.014381474814203989,
                0.012318109844189502
            );

            void main() {
                ivec2 size = imageSize(u_input_image);
                ivec2 coord = ivec2(gl_GlobalInvocationID.xy);

                if (coord.x < size.x && coord.y < size.y) {
                    vec4 sum = vec4(0.0);

                    for (int i = 0; i < N; ++i) {
                        for (int j = 0; j < N; ++j) {
                            ivec2 pc = coord + ivec2(i - M, j - M);
                            if (pc.x < 0) pc.x = 0;
                            if (pc.y < 0) pc.y = 0;
                            if (pc.x >= size.x) pc.x = size.x - 1;
                            if (pc.y >= size.y) pc.y = size.y - 1;
                      
                            sum += coeffs[i] * coeffs[j] * imageLoad(u_input_image, pc);
                        }
                    }
                    imageStore(u_output_image, coord, sum);
                }
            }
        }];
        VkShaderModule shaderModule = createShaderModule(shaderCode, sizeof(shaderCode));

        // Set up VkDescriptorSetLayout computeDescriptorSetLayout
        {
            VkDescriptorSetLayoutBinding bindings[] = {
                {0, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1, VK_SHADER_STAGE_COMPUTE_BIT, 0},
                {1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1, VK_SHADER_STAGE_COMPUTE_BIT, 0}
            };
            VkDescriptorSetLayoutCreateInfo createInfo = {
                .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
                .pNext = 0,
                .flags = 0,
                .bindingCount = sizeof(bindings)/sizeof(bindings[0]),
                .pBindings = bindings
            };
            $[vkfn vkCreateDescriptorSetLayout]
            $[vktry {vkCreateDescriptorSetLayout(device, &createInfo, 0, &computeDescriptorSetLayout)}]
        }

        // Set up VkPipelineLayout computePipelineLayout
        {
            VkPipelineLayoutCreateInfo createInfo = {0};
            createInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
            createInfo.setLayoutCount = 1;
            createInfo.pSetLayouts = &computeDescriptorSetLayout;
            $[vkfn vkCreatePipelineLayout]
            $[vktry {vkCreatePipelineLayout(device, &createInfo, 0, &computePipelineLayout)}]
        }

        // Set up VkPipeline computePipeline
        {
            VkComputePipelineCreateInfo createInfo = {0};
            createInfo.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
            createInfo.stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
            createInfo.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
            createInfo.stage.module = shaderModule;
            createInfo.stage.pName = "main";
            createInfo.layout = computePipelineLayout;

            $[vkfn vkCreateComputePipelines]
            $[vktry {vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &createInfo, 0, &computePipeline)}]
        }
    }]

    dc proc execute {} void [csubst {
        VkDescriptorPool descriptorPool; {
            VkDescriptorPoolSize size = {0};
            size.type = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
            size.descriptorCount = 2;

            VkDescriptorPoolCreateInfo createInfo = {0};
            createInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
            createInfo.maxSets = 1;
            createInfo.poolSizeCount = 1;
            createInfo.pPoolSizes = &size;
    
            $[vkfn vkCreateDescriptorPool]
            $[vktry {vkCreateDescriptorPool(device, &createInfo, 0, &descriptorPool)}]
        }

        VkDescriptorSet descriptorSet; {
            VkDescriptorSetAllocateInfo allocateInfo = {0};
            allocateInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
            allocateInfo.descriptorPool = descriptorPool;
            allocateInfo.descriptorSetCount = 1;
            allocateInfo.pSetLayouts = &computeDescriptorSetLayout;

            $[vkfn vkAllocateDescriptorSets]
            $[vktry {vkAllocateDescriptorSets(device, &allocateInfo, &descriptorSet)}]

            VkDescriptorImageInfo descriptorImageInfoIn = {
                .sampler,
                .imageView,
                .imageLayout
            };
            VkDescriptorImageInfo descriptorImageInfoOut = {
                .sampler
                .imageView
                .imageLayout
            };
            VkWriteDescriptorSet writeDescriptorSet[2] = {
                {
                    .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                    .pNext = 0,
                    .dstSet = descriptorSet,
                    .dstBinding = 0,
                    .dstArrayElement = 0,
                    .descriptorCount = 1,
                    .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
                    .pImageInfo = 0,
                    .pBufferInfo = &descriptorBufferInfoIn,
                    .pTexelBufferView = 0
                },
                {
                    .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                    .pNext = 0,
                    .dstSet = descriptorSet,
                    .dstBinding = 1,
                    .dstArrayElement = 0,
                    .descriptorCount = 1,
                    .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                    .pImageInfo = 0,
                    .pBufferInfo = &descriptorBufferInfoOut,
                    .pTexelBufferView = 0
                }
            };

            $[vkfn vkUpdateDescriptorSets]
            vkUpdateDescriptorSets(device, 2, writeDescriptorSet, 0, 0);
        }

        VkCommandPool commandPool; {
            VkCommandPoolCreateInfo createInfo = {
                .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                .pNext = 0,
                .flags = 0,
                .queueFamilyIndex = computeQueueFamilyIndex
            };
            $[vkfn vkCreateCommandPool]
            $[vktry {vkCreateCommandPool(device, &createInfo, 0, &commandPool)}]
        }

        VkCommandBuffer commandBuffer; {
            VkCommandBufferAllocateInfo allocateInfo = {
                .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                .pNext = 0,
                .commandPool = commandPool,
                .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
                .commandBufferCount = 1
            };
            $[vkfn vkAllocateCommandBuffers]
            $[vktry {vkAllocateCommandBuffers(device, &allocateInfo, &commandBuffer)}]

            VkCommandBufferBeginInfo beginInfo = {
                .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                .pNext = 0,
                .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
                .pInheritanceInfo = 0
            };
            $[vkfn vkBeginCommandBuffer]
            $[vktry {vkBeginCommandBuffer(commandBuffer, &beginInfo)}]
        }

        $[vkfn vkCmdBindPipeline]
        vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_COMPUTE, computePipeline);
        $[vkfn vkCmdBindDescriptorSets]
        vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_COMPUTE, computePipelineLayout, 0, 1, &descriptorSet, 0, 0);

        $[vkfn vkCmdDispatch]
        vkCmdDispatch(commandBuffer, 128, 1, 1);

        $[vkfn vkEndCommandBuffer]
        $[vktry {vkEndCommandBuffer(commandBuffer)}]

        VkQueue queue;
        $[vkfn vkGetDeviceQueue]
        vkGetDeviceQueue(device, computeQueueFamilyIndex, 0, &queue);

        VkSubmitInfo submitInfo = {
            .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = 0,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = 0,
            .pWaitDstStageMask = 0,
            .commandBufferCount = 1,
            .pCommandBuffers = &commandBuffer,
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = 0
        };
        $[vkfn vkQueueSubmit]
        $[vkfn vkQueueWaitIdle]
        $[vkfn vkMapMemory]
        $[vktry {vkQueueSubmit(queue, 1, &submitInfo, 0)}]
        $[vktry {vkQueueWaitIdle(queue)}]

        float *payload;
        $[vktry {vkMapMemory(device, memory, 0, 128 * sizeof(float) * 2, 0, (void *)&payload)}]

        for (int i = 0; i < 128; i++) {
            printf("in[%d] = %f\n", i, payload[i]);
            printf("out[%d] = %f (%f)\n", i, payload[128 + i], payload[128 + i] - payload[i]);
        }
    }]

    dc compile
}

Display::init
puts "1. initialized!"

Display::createBufferAndCopyImage $image
puts "2. allocated memory and filled with image!"

Display::execute
puts "3. executed!"
