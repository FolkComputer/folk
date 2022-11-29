source "lib/c.tcl"
source "useful/bullseye-play.tcl"

set ps [programToPs 66 "hello"]
set fd [file tempfile psfile psfile.ps]; puts $fd $ps; close $fd
exec convert $psfile -quality 300 -colorspace RGB [file rootname $psfile].jpeg
set jpegfile [file rootname $psfile].jpeg

rename [c create] ic
ic include <stdlib.h>
ic code "#undef EXTERN"
ic include <jpeglib.h>
source "pi/critclUtils.tcl"
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

source "useful/Display_vk.tcl"
namespace eval Display {
    dc code {
        VkPipeline computePipeline;
        VkImage computeCameraImage;
        VkCommandBuffer computeCommandBuffer;
    }
    defineImageType Display::dc
    dc proc allocate {int bufferSize} void [csubst {
        VkPhysicalDeviceMemoryProperties properties;
        $[vkfn vkGetPhysicalDeviceMemoryProperties]
        vkGetPhysicalDeviceMemoryProperties(physicalDevice, &properties);

        const VkDeviceSize memorySize = bufferSize * 2;

        uint32_t memoryTypeIndex = UINT32_MAX;
        for (uint32_t k = 0; k < properties.memoryTypeCount; k++) {
            const VkMemoryType memoryType = properties.memoryTypes[k];
            if ((VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT & memoryType.propertyFlags)
                && (VK_MEMORY_PROPERTY_HOST_COHERENT_BIT & memoryType.propertyFlags)
                && (memorySize < properties.memoryHeaps[memoryType.heapIndex].size)) {
                // found our memory type!
                memoryTypeIndex = k; break;
            }
        }
        if (memoryTypeIndex == UINT32_MAX) { exit(1); }

        VkDeviceMemory memory; {
            VkMemoryAllocateInfo allocateInfo = {0};
            allocateInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
            allocateInfo.allocationSize = memorySize;
            allocateInfo.memoryTypeIndex = memoryTypeIndex;

            $[vkfn vkAllocateMemory]
            $[vktry {vkAllocateMemory(device, &allocateInfo, 0, &memory)}]
        } {
            uint8_t* payload;
            $[vkfn vkMapMemory]
            $[vktry {vkMapMemory(device, memory, 0, memorySize, 0, (void*) &payload)}]
            for (uint32_t k = 1; k < memorySize / sizeof(uint8_t); k++) {
                payload[k] = rand();
            }
            $[vkfn vkUnmapMemory]
            vkUnmapMemory(device, memory);
        }

        // subdivide it into two buffers
        $[vkfn vkCreateBuffer]
        $[vkfn vkBindBufferMemory]
        const VkBufferCreateInfo bufferCreateInfo = {
            .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = 0,
            .flags = 0,
            .size = bufferSize,
            .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 1,
            .pQueueFamilyIndices = &computeQueueFamilyIndex
        };
        VkBuffer inBuffer; {
            $[vktry {vkCreateBuffer(device, &bufferCreateInfo, 0, &inBuffer)}]
            $[vktry {vkBindBufferMemory(device, inBuffer, memory, 0)}]
        }
        VkBuffer outBuffer; {
            $[vktry {vkCreateBuffer(device, &bufferCreateInfo, 0, &outBuffer)}]
            $[vktry {vkBindBufferMemory(device, outBuffer, memory, bufferSize)}]
        }

        uint32_t shaderCode[] = $[glslc -fshader-stage=comp {
            #version 450
            layout (local_size_x = 256) in;

            layout (set = 0, binding = 0) buffer inBuffer {
                mat4 transform;
                int matrixCount;
            } inData;

            layout (set = 0, binding = 1) buffer outBuffer {
                mat4 matrices[];
            } outData;

            void main() {
                
            }
        }];
        VkShaderModule shaderModule = createShaderModule(shaderCode, sizeof(shaderCode));

        VkDescriptorSetLayout descriptorSetLayout; {
            VkDescriptorSetLayoutBinding bindings[] = {
                {0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, 0},
                {1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, 0}
            };
            VkDescriptorSetLayoutCreateInfo createInfo = {
                .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
                .pNext = 0,
                .flags = 0,
                .bindingCount = sizeof(bindings)/sizeof(bindings[0]),
                .pBindings = bindings
            };
            $[vkfn vkCreateDescriptorSetLayout]
            $[vktry {vkCreateDescriptorSetLayout(device, &createInfo, 0, &descriptorSetLayout)}]
        }

        // Set up VkPipeline computePipeline
        {
            VkPipelineLayout pipelineLayout; {
                VkPipelineLayoutCreateInfo createInfo = {0};
                createInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
                createInfo.setLayoutCount = 1;
                createInfo.pSetLayouts = &descriptorSetLayout;
                $[vkfn vkCreatePipelineLayout]
                $[vktry {vkCreatePipelineLayout(device, &createInfo, 0, &pipelineLayout)}]
            }

            VkComputePipelineCreateInfo createInfo = {0};
            createInfo.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
            createInfo.stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
            createInfo.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
            createInfo.stage.module = shaderModule;
            createInfo.stage.pName = "main";
            createInfo.layout = pipelineLayout;

            $[vkfn vkCreateComputePipelines]
            $[vktry {vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &createInfo, 0, &computePipeline)}]
        }
    }]

    dc compile
}
Display::init
Display::allocate 128
puts hi