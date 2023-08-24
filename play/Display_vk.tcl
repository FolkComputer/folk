source "lib/c.tcl"

namespace eval Display {
    set macos [expr {$tcl_platform(os) eq "Darwin"}]

    rename [c create] dc
    dc include <vulkan/vulkan.h>
    dc include <stdlib.h>
    dc include <dlfcn.h>
    if {$macos} {
        dc include <GLFW/glfw3.h>
        dc cflags -lglfw

        proc vkfn {fn {instance instance}} {
            csubst {PFN_$fn $fn = (PFN_$fn) glfwGetInstanceProcAddress($instance, "$fn");}
        }
    } else {
        proc vkfn {fn {instance instance}} {
            csubst {PFN_$fn $fn = (PFN_$fn) vkGetInstanceProcAddr($instance, "$fn");}
        }
    }

    proc vktry {call} { csubst {{
        VkResult res = $call;
        if (res != VK_SUCCESS) {
            fprintf(stderr, "Failed $call: %d\n", res); exit(1);
        }
    }} }

    dc code {
        VkInstance instance;
        VkPhysicalDevice physicalDevice;
        VkDevice device;

        uint32_t computeQueueFamilyIndex;

        VkQueue graphicsQueue;
        VkQueue presentQueue;
        VkQueue computeQueue;

        VkRenderPass renderPass;

        VkSwapchainKHR swapchain;
        uint32_t swapchainImageCount;
        VkFramebuffer* swapchainFramebuffers;
        VkExtent2D swapchainExtent;

        VkDescriptorPool descriptorPool;

        VkCommandBuffer commandBuffer;
        uint32_t imageIndex;

        VkSemaphore imageAvailableSemaphore;
        VkSemaphore renderFinishedSemaphore;
        VkFence inFlightFence;
    }
    dc proc init {} void [csubst {
        PFN_vkGetInstanceProcAddr vkGetInstanceProcAddr;
        if ($macos) {
            (void)vkGetInstanceProcAddr;
            glfwInit();
        }
        else {
            void *vulkanLibrary = dlopen("libvulkan.so.1", RTLD_NOW);
            if (vulkanLibrary == NULL) {
                fprintf(stderr, "Failed to load libvulkan: %s\n", dlerror()); exit(1);
            }
            vkGetInstanceProcAddr = (PFN_vkGetInstanceProcAddr) dlsym(vulkanLibrary, "vkGetInstanceProcAddr");
        }

        // Set up VkInstance instance:
        {
            $[vkfn vkCreateInstance NULL]

            VkInstanceCreateInfo createInfo = {0};
            createInfo.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;

            const char* validationLayers[] = {
                "VK_LAYER_KHRONOS_validation"
            };
            createInfo.enabledLayerCount = sizeof(validationLayers)/sizeof(validationLayers[0]);
            createInfo.ppEnabledLayerNames = validationLayers;

            const char* enabledExtensions[] = $[expr { $macos ? {{
                VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME,
                VK_KHR_SURFACE_EXTENSION_NAME,
                "VK_EXT_metal_surface",
                "VK_KHR_get_physical_device_properties2" 
            }} : {{
                // 2 extensions for non-X11/Wayland display
                VK_KHR_SURFACE_EXTENSION_NAME,
                VK_KHR_DISPLAY_EXTENSION_NAME
            }} }];
            createInfo.enabledExtensionCount = sizeof(enabledExtensions)/sizeof(enabledExtensions[0]);
            createInfo.ppEnabledExtensionNames = enabledExtensions;
            createInfo.flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;

            $[vktry {vkCreateInstance(&createInfo, NULL, &instance)}]
        }

        // Set up VkPhysicalDevice physicalDevice
        {
            $[vkfn vkEnumeratePhysicalDevices]

            uint32_t physicalDeviceCount = 0;
            vkEnumeratePhysicalDevices(instance, &physicalDeviceCount, NULL);
            if (physicalDeviceCount == 0) {
                fprintf(stderr, "Failed to find Vulkan physical device\n"); exit(1);
            }
            printf("Found %d Vulkan devices\n", physicalDeviceCount);
            VkPhysicalDevice physicalDevices[physicalDeviceCount];
            vkEnumeratePhysicalDevices(instance, &physicalDeviceCount, physicalDevices);

            physicalDevice = physicalDevices[0];
        }
        
        uint32_t graphicsQueueFamilyIndex = UINT32_MAX;
        computeQueueFamilyIndex = UINT32_MAX; {
            $[vkfn vkGetPhysicalDeviceQueueFamilyProperties]

            uint32_t queueFamilyCount = 0;
            vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice, &queueFamilyCount, NULL);
            VkQueueFamilyProperties queueFamilies[queueFamilyCount];
            vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice, &queueFamilyCount, queueFamilies);
            for (int i = 0; i < queueFamilyCount; i++) {
                if (queueFamilies[i].queueFlags & VK_QUEUE_COMPUTE_BIT) {
                    computeQueueFamilyIndex = i;
                }
                if (queueFamilies[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
                    graphicsQueueFamilyIndex = i;
                    break;
                }
            }
            if (graphicsQueueFamilyIndex == UINT32_MAX) {
                fprintf(stderr, "Failed to find a Vulkan graphics queue family\n"); exit(1);
            }
            if (computeQueueFamilyIndex == UINT32_MAX) {
                fprintf(stderr, "Failed to find a Vulkan compute queue family\n"); exit(1);
            }
        }

        // Set up VkDevice device
        {
            VkDeviceQueueCreateInfo queueCreateInfo = {0};
            queueCreateInfo.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
            queueCreateInfo.queueFamilyIndex = graphicsQueueFamilyIndex;
            queueCreateInfo.queueCount = 1;
            float queuePriority = 1.0f;
            queueCreateInfo.pQueuePriorities = &queuePriority;

            VkPhysicalDeviceFeatures deviceFeatures = {0};

            const char *deviceExtensions[] = $[expr { $macos ? {{
                VK_KHR_SWAPCHAIN_EXTENSION_NAME,
                "VK_KHR_portability_subset"
            }} : {{
                VK_KHR_SWAPCHAIN_EXTENSION_NAME
            }} }];

            VkDeviceCreateInfo createInfo = {0};
            createInfo.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
            createInfo.pQueueCreateInfos = &queueCreateInfo;
            createInfo.queueCreateInfoCount = 1;
            createInfo.pEnabledFeatures = &deviceFeatures;
            createInfo.enabledLayerCount = 0;
            createInfo.enabledExtensionCount = sizeof(deviceExtensions)/sizeof(deviceExtensions[0]);
            createInfo.ppEnabledExtensionNames = deviceExtensions;

            $[vkfn vkCreateDevice]
            $[vktry {vkCreateDevice(physicalDevice, &createInfo, NULL, &device)}]
        }

        uint32_t propertyCount;
        $[vkfn vkEnumerateInstanceLayerProperties]
        vkEnumerateInstanceLayerProperties(&propertyCount, NULL);
        VkLayerProperties layerProperties[propertyCount];
        vkEnumerateInstanceLayerProperties(&propertyCount, layerProperties);

        // Get drawing surface.
        VkSurfaceKHR surface;
        $[expr { $macos ? { GLFWwindow* window; } : {} }]
        if (!$macos) {
            $[vkfn vkCreateDisplayPlaneSurfaceKHR]
            VkDisplaySurfaceCreateInfoKHR createInfo = {0};
            createInfo.sType = VK_STRUCTURE_TYPE_DISPLAY_SURFACE_CREATE_INFO_KHR;
            createInfo.displayMode = 0; // TODO: dynamically find out
            createInfo.planeIndex = 0;
            createInfo.imageExtent = (VkExtent2D) { .width = 3840, .height = 2160 }; // TODO: find out
            if (vkCreateDisplayPlaneSurfaceKHR(instance, &createInfo, NULL, &surface) != VK_SUCCESS) {
                fprintf(stderr, "Failed to create Vulkan display plane surface\n"); exit(1);
            }
        } else {
            /* uint32_t glfwExtensionCount = 0; */
            /* const char** glfwExtensions = glfwGetRequiredInstanceExtensions(&glfwExtensionCount); */
            /* for (int i = 0; i < glfwExtensionCount; i++) { */
            /*     printf("require %d: %s\n", i, glfwExtensions[i]); */
            /* } */
            
            glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
            window = glfwCreateWindow(640, 480, "Window Title", NULL, NULL);
            if (glfwCreateWindowSurface(instance, window, NULL, &surface) != VK_SUCCESS) {
                fprintf(stderr, "Failed to create GLFW window surface\n"); exit(1);
            }
        }

        uint32_t presentQueueFamilyIndex; {
            VkBool32 presentSupport = 0; 
            $[vkfn vkGetPhysicalDeviceSurfaceSupportKHR]
            vkGetPhysicalDeviceSurfaceSupportKHR(physicalDevice, graphicsQueueFamilyIndex, surface, &presentSupport);
            if (!presentSupport) {
                fprintf(stderr, "Vulkan graphics queue family doesn't support presenting to surface\n"); exit(1);
            }
            presentQueueFamilyIndex = graphicsQueueFamilyIndex;
        }

        // Figure out capabilities/format/mode of physical device for surface.
        VkSurfaceCapabilitiesKHR capabilities;
        VkExtent2D extent;
        uint32_t imageCount;
        VkSurfaceFormatKHR surfaceFormat;
        VkPresentModeKHR presentMode; {
            $[vkfn vkGetPhysicalDeviceSurfaceCapabilitiesKHR]
            vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physicalDevice, surface, &capabilities);

            if (capabilities.currentExtent.width != UINT32_MAX) {
                extent = capabilities.currentExtent;
            } else {
                glfwGetFramebufferSize(window, (int*) &extent.width, (int*) &extent.height);
                if (capabilities.minImageExtent.width > extent.width) { extent.width = capabilities.minImageExtent.width; }
                if (capabilities.maxImageExtent.width < extent.width) { extent.width = capabilities.maxImageExtent.width; }
                if (capabilities.minImageExtent.height > extent.height) { extent.height = capabilities.minImageExtent.height; }
                if (capabilities.maxImageExtent.height < extent.height) { extent.height = capabilities.maxImageExtent.height; }
            }

            imageCount = capabilities.minImageCount + 1;
            if (capabilities.maxImageCount > 0 && imageCount > capabilities.maxImageCount) {
                imageCount = capabilities.maxImageCount;
            }

            $[vkfn vkGetPhysicalDeviceSurfaceFormatsKHR]
            uint32_t formatCount;
            vkGetPhysicalDeviceSurfaceFormatsKHR(physicalDevice, surface, &formatCount, NULL);
            VkSurfaceFormatKHR formats[formatCount];
            if (formatCount == 0) { fprintf(stderr, "No supported surface formats.\n"); exit(1); }
            vkGetPhysicalDeviceSurfaceFormatsKHR(physicalDevice, surface, &formatCount, formats);
            surfaceFormat = formats[0]; // semi-arbitrary default
            for (int i = 0; i < formatCount; i++) {
                if (formats[i].format == VK_FORMAT_B8G8R8A8_SRGB && formats[i].colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
                    surfaceFormat = formats[i];
                }
            }

            $[vkfn vkGetPhysicalDeviceSurfacePresentModesKHR]
            uint32_t presentModeCount;
            vkGetPhysicalDeviceSurfacePresentModesKHR(physicalDevice, surface, &presentModeCount, NULL);
            VkPresentModeKHR presentModes[presentModeCount];
            if (presentModeCount == 0) { fprintf(stderr, "No supported present modes.\n"); exit(1); }
            vkGetPhysicalDeviceSurfacePresentModesKHR(physicalDevice, surface, &presentModeCount, presentModes);
            presentMode = VK_PRESENT_MODE_FIFO_KHR; // guaranteed to be available
            for (int i = 0; i < presentModeCount; i++) {
                if (presentModes[i] == VK_PRESENT_MODE_MAILBOX_KHR) {
                    presentMode = presentModes[i];
                }
            }
        }

        // Set up VkSwapchainKHR swapchain
        {
            VkSwapchainCreateInfoKHR createInfo = {0};
            createInfo.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
            createInfo.surface = surface;

            createInfo.minImageCount = imageCount;
            createInfo.imageFormat = surfaceFormat.format;
            createInfo.imageColorSpace = surfaceFormat.colorSpace;
            createInfo.imageExtent = extent;
            createInfo.imageArrayLayers = 1;
            createInfo.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;

            if (graphicsQueueFamilyIndex != presentQueueFamilyIndex) {
                fprintf(stderr, "Graphics and present queue families differ\n"); exit(1);
            }
            createInfo.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
            createInfo.queueFamilyIndexCount = 0;
            createInfo.pQueueFamilyIndices = NULL;

            createInfo.preTransform = capabilities.currentTransform;
            createInfo.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
            createInfo.presentMode = presentMode;
            createInfo.clipped = VK_TRUE;
            createInfo.oldSwapchain = VK_NULL_HANDLE;
            
            $[vkfn vkCreateSwapchainKHR]
            $[vktry {vkCreateSwapchainKHR(device, &createInfo, NULL, &swapchain)}]
        }

        $[vkfn vkGetSwapchainImagesKHR]
        // Set up uint32_t swapchainImageCount:
        vkGetSwapchainImagesKHR(device, swapchain, &swapchainImageCount, NULL);
        VkImage swapchainImages[swapchainImageCount];
        VkFormat swapchainImageFormat;
        // Set up VkExtent2D swapchainExtent:
        {
            vkGetSwapchainImagesKHR(device, swapchain, &swapchainImageCount, swapchainImages);
            swapchainImageFormat = surfaceFormat.format;
            swapchainExtent = extent;
        }

        VkImageView swapchainImageViews[swapchainImageCount]; {
            $[vkfn vkCreateImageView]
            for (size_t i = 0; i < swapchainImageCount; i++) {
                VkImageViewCreateInfo createInfo = {0};
                createInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
                createInfo.image = swapchainImages[i];
                createInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
                createInfo.format = swapchainImageFormat;
                createInfo.components.r = VK_COMPONENT_SWIZZLE_IDENTITY;
                createInfo.components.g = VK_COMPONENT_SWIZZLE_IDENTITY;
                createInfo.components.b = VK_COMPONENT_SWIZZLE_IDENTITY;
                createInfo.components.a = VK_COMPONENT_SWIZZLE_IDENTITY;
                createInfo.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
                createInfo.subresourceRange.baseMipLevel = 0;
                createInfo.subresourceRange.levelCount = 1;
                createInfo.subresourceRange.baseArrayLayer = 0;
                createInfo.subresourceRange.layerCount = 1;
                $[vktry {vkCreateImageView(device, &createInfo, NULL, &swapchainImageViews[i])}]
            }
        }

        // Set up VkQueue graphicsQueue and VkQueue presentQueue and VkQueue computeQueue
        {
            $[vkfn vkGetDeviceQueue]
            vkGetDeviceQueue(device, graphicsQueueFamilyIndex, 0, &graphicsQueue);
            presentQueue = graphicsQueue;
            computeQueue = graphicsQueue;
        }

        // Set up VkRenderPass renderPass:
        {
            VkAttachmentDescription colorAttachment = {0};
            colorAttachment.format = swapchainImageFormat;
            colorAttachment.samples = VK_SAMPLE_COUNT_1_BIT;
            colorAttachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
            colorAttachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
            colorAttachment.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
            colorAttachment.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
            colorAttachment.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
            colorAttachment.finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

            VkAttachmentReference colorAttachmentRef = {0};
            colorAttachmentRef.attachment = 0;
            colorAttachmentRef.layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

            VkSubpassDescription subpass = {0};
            subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
            subpass.colorAttachmentCount = 1;
            subpass.pColorAttachments = &colorAttachmentRef;

            VkRenderPassCreateInfo renderPassInfo = {0};
            renderPassInfo.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
            renderPassInfo.attachmentCount = 1;
            renderPassInfo.pAttachments = &colorAttachment;
            renderPassInfo.subpassCount = 1;
            renderPassInfo.pSubpasses = &subpass;

            VkSubpassDependency dependency = {0};
            dependency.srcSubpass = VK_SUBPASS_EXTERNAL;
            dependency.dstSubpass = 0;
            dependency.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
            dependency.srcAccessMask = 0;
            dependency.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
            dependency.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;

            renderPassInfo.dependencyCount = 1;
            renderPassInfo.pDependencies = &dependency;
            
            $[vkfn vkCreateRenderPass]
            $[vktry {vkCreateRenderPass(device, &renderPassInfo, NULL, &renderPass)}]
        }

        // Set up VkFramebuffer swapchainFramebuffers[swapchainImageCount]:
        swapchainFramebuffers = ckalloc(sizeof(VkFramebuffer) * swapchainImageCount);
        for (size_t i = 0; i < swapchainImageCount; i++) {
            VkImageView attachments[] = { swapchainImageViews[i] };
            
            VkFramebufferCreateInfo framebufferInfo = {0};
            framebufferInfo.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
            framebufferInfo.renderPass = renderPass;
            framebufferInfo.attachmentCount = 1;
            framebufferInfo.pAttachments = attachments;
            framebufferInfo.width = swapchainExtent.width;
            framebufferInfo.height = swapchainExtent.height;
            framebufferInfo.layers = 1;

            $[vkfn vkCreateFramebuffer]
            $[vktry {vkCreateFramebuffer(device, &framebufferInfo, NULL, &swapchainFramebuffers[i])}]
        }

        VkCommandPool commandPool; {
            VkCommandPoolCreateInfo poolInfo = {0};
            poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
            poolInfo.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
            poolInfo.queueFamilyIndex = graphicsQueueFamilyIndex;

            $[vkfn vkCreateCommandPool]
            $[vktry {vkCreateCommandPool(device, &poolInfo, NULL, &commandPool)}]
        }
        // Set up VkCommandBuffer commandBuffer
        {
            VkCommandBufferAllocateInfo allocInfo = {0};
            allocInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
            allocInfo.commandPool = commandPool;
            allocInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
            allocInfo.commandBufferCount = 1;

            $[vkfn vkAllocateCommandBuffers]
            $[vktry {vkAllocateCommandBuffers(device, &allocInfo, &commandBuffer)}]
        }
        
        {
            VkSemaphoreCreateInfo semaphoreInfo = {0};
            semaphoreInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;

            VkFenceCreateInfo fenceInfo = {0};
            fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
            fenceInfo.flags = VK_FENCE_CREATE_SIGNALED_BIT;

            $[vkfn vkCreateSemaphore]
            $[vkfn vkCreateFence]
            $[vktry {vkCreateSemaphore(device, &semaphoreInfo, NULL, &imageAvailableSemaphore)}]
            $[vktry {vkCreateSemaphore(device, &semaphoreInfo, NULL, &renderFinishedSemaphore)}]
            $[vktry {vkCreateFence(device, &fenceInfo, NULL, &inFlightFence)}]
        }
    }]

    proc defineVulkanHandleType {cc type} {
        set cc [uplevel {namespace current}]::$cc
        $cc argtype $type [format {
            %s $argname; sscanf(Tcl_GetString($obj), "(%s) 0x%%p", &$argname);
        } $type $type]
        $cc rtype $type [format {
            $robj = Tcl_ObjPrintf("(%s) 0x%%" PRIxPTR, (uintptr_t) $rvalue);
        } $type]
    }

    # Shader compilation:

    defineVulkanHandleType dc VkShaderModule
    dc proc createShaderModule {Tcl_Obj* codeObj} VkShaderModule [csubst {
        int codeObjc; Tcl_Obj** codeObjv;
        Tcl_ListObjGetElements(NULL, codeObj, &codeObjc, &codeObjv);
        uint32_t code[codeObjc];
        for (int i = 0; i < codeObjc; i++) {
            Tcl_GetIntFromObj(NULL, codeObjv[i], (int32_t *)&code[i]);
        }

        VkShaderModuleCreateInfo createInfo = {0};
        createInfo.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;                
        createInfo.codeSize = codeObjc * sizeof(code[0]);
        createInfo.pCode = code;
        $[vkfn vkCreateShaderModule]

        VkShaderModule shaderModule;
        $[vktry {vkCreateShaderModule(device, &createInfo, NULL, &shaderModule)}]
        return shaderModule;
    }]

    # Buffer allocation:

    dc code [csubst {
        uint32_t findMemoryType(uint32_t typeFilter, VkMemoryPropertyFlags properties) {
            VkPhysicalDeviceMemoryProperties memProperties;
            $[vkfn vkGetPhysicalDeviceMemoryProperties]
            vkGetPhysicalDeviceMemoryProperties(physicalDevice, &memProperties);

            for (uint32_t i = 0; i < memProperties.memoryTypeCount; i++) {
                if ((typeFilter & (1 << i)) && (memProperties.memoryTypes[i].propertyFlags & properties) == properties) {
                    return i;
                }
            }

            exit(1);
        }

        void createBuffer(VkDeviceSize size, VkBufferUsageFlags usage, VkMemoryPropertyFlags properties,
                          VkBuffer* buffer, VkDeviceMemory* bufferMemory) {
            VkBufferCreateInfo bufferInfo = {0};
            bufferInfo.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
            bufferInfo.size = size;
            bufferInfo.usage = usage;
            bufferInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;

            $[vkfn vkCreateBuffer]
            $[vktry {vkCreateBuffer(device, &bufferInfo, NULL, buffer)}]

            VkMemoryRequirements memRequirements;
            $[vkfn vkGetBufferMemoryRequirements]
            vkGetBufferMemoryRequirements(device, *buffer, &memRequirements);

            VkMemoryAllocateInfo allocInfo = {0};
            allocInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
            allocInfo.allocationSize = memRequirements.size;
            allocInfo.memoryTypeIndex = findMemoryType(memRequirements.memoryTypeBits, properties);

            $[vkfn vkAllocateMemory]
            $[vktry {vkAllocateMemory(device, &allocInfo, NULL, bufferMemory)}]
            $[vkfn vkBindBufferMemory]
            vkBindBufferMemory(device, *buffer, *bufferMemory, 0);
        }
    }]
    defineVulkanHandleType dc VkBuffer
    defineVulkanHandleType dc VkDeviceMemory
    dc typedef uint64_t VkDeviceSize
    dc struct Buffer {
        VkBuffer buffer;
        VkDeviceMemory memory;
        void* addr;
    }
    dc proc createUniformBuffer {VkDeviceSize size} Buffer {
        Buffer ret;
        createBuffer(size, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                     VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                     &ret.buffer, &ret.memory);
        $[vkfn vkMapMemory]
        vkMapMemory(device, ret.memory, 0, size, 0, &ret.addr);
        return ret;
    }

    # Pipeline creation:

    defineVulkanHandleType dc VkPipeline
    defineVulkanHandleType dc VkPipelineLayout
    defineVulkanHandleType dc VkDescriptorSet
    dc struct Pipeline {
        VkPipeline pipeline;
        VkPipelineLayout pipelineLayout;
        VkDescriptorSet argsDescriptorSet;
        Buffer argsBuffer;
    }
    dc proc createPipeline {VkShaderModule vertShaderModule
                            VkShaderModule fragShaderModule
                            VkDeviceSize argsBufferSize} Pipeline [csubst {
        // Now what?
        // Create graphics pipeline.
        VkPipelineShaderStageCreateInfo shaderStages[2]; {
            VkPipelineShaderStageCreateInfo vertShaderStageInfo = {0};
            vertShaderStageInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
            vertShaderStageInfo.stage = VK_SHADER_STAGE_VERTEX_BIT;
            vertShaderStageInfo.module = vertShaderModule;
            vertShaderStageInfo.pName = "main";

            VkPipelineShaderStageCreateInfo fragShaderStageInfo = {0};
            fragShaderStageInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
            fragShaderStageInfo.stage = VK_SHADER_STAGE_FRAGMENT_BIT;
            fragShaderStageInfo.module = fragShaderModule;
            fragShaderStageInfo.pName = "main";

            shaderStages[0] = vertShaderStageInfo;
            shaderStages[1] = fragShaderStageInfo;
        }

        VkPipelineVertexInputStateCreateInfo vertexInputInfo = {0}; {
            vertexInputInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
            vertexInputInfo.vertexBindingDescriptionCount = 0;
            vertexInputInfo.vertexAttributeDescriptionCount = 0;
        }

        VkPipelineInputAssemblyStateCreateInfo inputAssembly = {0}; {
            inputAssembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
            // We're just going to draw a fullscreen quad (4 vertices
            // -> first 3 vertices are top-left triangle, last 3
            // vertices are bottom-right triangle).
            inputAssembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP;
            inputAssembly.primitiveRestartEnable = VK_FALSE;
        }

        VkViewport viewport = {0}; {
            viewport.x = 0.0f;
            viewport.y = 0.0f;
            viewport.width = (float) swapchainExtent.width;
            viewport.height = (float) swapchainExtent.height;
            viewport.minDepth = 0.0f;
            viewport.maxDepth = 1.0f;
        }
        VkRect2D scissor = {0}; {
            scissor.offset = (VkOffset2D) {0, 0};
            scissor.extent = swapchainExtent;
        }
        VkPipelineViewportStateCreateInfo viewportState = {0};
        viewportState.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        viewportState.viewportCount = 1;
        viewportState.pViewports = &viewport;
        viewportState.scissorCount = 1;
        viewportState.pScissors = &scissor;

        VkPipelineRasterizationStateCreateInfo rasterizer = {0};
        rasterizer.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        rasterizer.depthClampEnable = VK_FALSE;
        rasterizer.rasterizerDiscardEnable = VK_FALSE;
        rasterizer.polygonMode = VK_POLYGON_MODE_FILL;
        rasterizer.lineWidth = 1.0f;
        rasterizer.cullMode = VK_CULL_MODE_BACK_BIT;
        rasterizer.frontFace = VK_FRONT_FACE_CLOCKWISE;
        rasterizer.depthBiasEnable = VK_FALSE;

        VkPipelineMultisampleStateCreateInfo multisampling = {0};
        multisampling.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        multisampling.sampleShadingEnable = VK_FALSE;
        multisampling.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;

        VkPipelineColorBlendAttachmentState colorBlendAttachment = {0};
        colorBlendAttachment.colorWriteMask =
          VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT |
          VK_COLOR_COMPONENT_A_BIT;
        colorBlendAttachment.blendEnable = VK_FALSE;

        VkPipelineColorBlendStateCreateInfo colorBlending = {0};
        colorBlending.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        colorBlending.logicOpEnable = VK_FALSE;
        colorBlending.logicOp = VK_LOGIC_OP_COPY; // Optional
        colorBlending.attachmentCount = 1;
        colorBlending.pAttachments = &colorBlendAttachment;

        VkDescriptorSetLayout descriptorSetLayout; {
            VkDescriptorSetLayoutBinding argsLayoutBinding = {0};
            argsLayoutBinding.binding = 0;
            argsLayoutBinding.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
            argsLayoutBinding.descriptorCount = 1;
            argsLayoutBinding.stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;

            VkDescriptorSetLayoutCreateInfo layoutInfo = {0};
            layoutInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
            layoutInfo.bindingCount = 1;
            layoutInfo.pBindings = &argsLayoutBinding;
            $[vkfn vkCreateDescriptorSetLayout]
            $[vktry {vkCreateDescriptorSetLayout(device, &layoutInfo, NULL, &descriptorSetLayout)}]
        }

        VkPipelineLayout pipelineLayout; {
            VkPipelineLayoutCreateInfo pipelineLayoutInfo = {0};
            pipelineLayoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
            pipelineLayoutInfo.setLayoutCount = 1;
            pipelineLayoutInfo.pSetLayouts = &descriptorSetLayout;
            
            $[vkfn vkCreatePipelineLayout]
            $[vktry {vkCreatePipelineLayout(device, &pipelineLayoutInfo, NULL, &pipelineLayout)}]
        }

        VkPipeline pipeline; {
            VkGraphicsPipelineCreateInfo pipelineInfo = {0};
            pipelineInfo.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
            pipelineInfo.stageCount = 2;
            pipelineInfo.pStages = shaderStages;
            pipelineInfo.pVertexInputState = &vertexInputInfo;
            pipelineInfo.pInputAssemblyState = &inputAssembly;
            pipelineInfo.pViewportState = &viewportState;
            pipelineInfo.pRasterizationState = &rasterizer;
            pipelineInfo.pMultisampleState = &multisampling;
            pipelineInfo.pDepthStencilState = NULL;
            pipelineInfo.pColorBlendState = &colorBlending;
            pipelineInfo.pDynamicState = NULL;

            pipelineInfo.layout = pipelineLayout;

            pipelineInfo.renderPass = renderPass;
            pipelineInfo.subpass = 0;

            pipelineInfo.basePipelineHandle = VK_NULL_HANDLE;
            pipelineInfo.basePipelineIndex = -1;

            $[vkfn vkCreateGraphicsPipelines]
            $[vktry {vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &pipelineInfo, NULL, &pipeline)}]
        }

        VkDescriptorPool descriptorPool; {
            VkDescriptorPoolSize poolSize = {0};
            poolSize.type = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
            poolSize.descriptorCount = 1;
            VkDescriptorPoolCreateInfo poolInfo = {0};
            poolInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
            poolInfo.poolSizeCount = 1;
            poolInfo.pPoolSizes = &poolSize;
            poolInfo.maxSets = 1;
            $[vkfn vkCreateDescriptorPool]
            $[vktry {vkCreateDescriptorPool(device, &poolInfo, NULL, &descriptorPool)}]
        }
        VkDescriptorSet descriptorSet; {
            VkDescriptorSetAllocateInfo allocInfo = {0};
            allocInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
            allocInfo.descriptorPool = descriptorPool;
            allocInfo.descriptorSetCount = 1;
            allocInfo.pSetLayouts = &descriptorSetLayout;

            $[vkfn vkAllocateDescriptorSets]
            $[vktry {vkAllocateDescriptorSets(device, &allocInfo, &descriptorSet)}]
        }

        Buffer argsBuffer = createUniformBuffer(argsBufferSize);

        {
            VkDescriptorBufferInfo bufferInfo = {0};
            bufferInfo.buffer = argsBuffer.buffer;
            bufferInfo.offset = 0;
            bufferInfo.range = argsBufferSize;
        
            VkWriteDescriptorSet descriptorWrite = {0};
            descriptorWrite.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            descriptorWrite.dstSet = descriptorSet;
            descriptorWrite.dstBinding = 0;
            descriptorWrite.dstArrayElement = 0;
            descriptorWrite.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
            descriptorWrite.descriptorCount = 1;
            descriptorWrite.pBufferInfo = &bufferInfo;

            $[vkfn vkUpdateDescriptorSets]
            vkUpdateDescriptorSets(device, 1, &descriptorWrite, 0, NULL);
        }

        return (Pipeline) {
            .pipeline = pipeline,
            .pipelineLayout = pipelineLayout,
            .argsDescriptorSet = descriptorSet,
            .argsBuffer = argsBuffer
        };
    }]

    dc proc drawStart {} void {
        $[vkfn vkWaitForFences]
        vkWaitForFences(device, 1, &inFlightFence, VK_TRUE, UINT64_MAX);

        $[vkfn vkResetFences]
        vkResetFences(device, 1, &inFlightFence);

        $[vkfn vkAcquireNextImageKHR]
        vkAcquireNextImageKHR(device, swapchain, UINT64_MAX, imageAvailableSemaphore, VK_NULL_HANDLE, &imageIndex);

        $[vkfn vkResetCommandBuffer]
        vkResetCommandBuffer(commandBuffer, 0);

        VkCommandBufferBeginInfo beginInfo = {0};
        beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        beginInfo.flags = 0;
        beginInfo.pInheritanceInfo = NULL;
        $[vkfn vkBeginCommandBuffer]
        $[vktry {vkBeginCommandBuffer(commandBuffer, &beginInfo)}]

        $[vkfn vkCmdBeginRenderPass]
        {
            VkRenderPassBeginInfo renderPassInfo = {0};
            renderPassInfo.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
            renderPassInfo.renderPass = renderPass;
            renderPassInfo.framebuffer = swapchainFramebuffers[imageIndex];
            renderPassInfo.renderArea.offset = (VkOffset2D) {0, 0};
            renderPassInfo.renderArea.extent = swapchainExtent;

            VkClearValue clearColor = {{{0.0f, 0.0f, 0.0f, 1.0f}}};
            renderPassInfo.clearValueCount = 1;
            renderPassInfo.pClearValues = &clearColor;

            vkCmdBeginRenderPass(commandBuffer, &renderPassInfo, VK_SUBPASS_CONTENTS_INLINE);
        }
    }
    dc proc drawImpl {Pipeline pipeline} void {
        $[vkfn vkCmdBindPipeline]
        vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipeline);

        $[vkfn vkCmdBindDescriptorSets]
        vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                                pipeline.pipelineLayout,
                                0, 1,
                                &pipeline.argsDescriptorSet, 0, NULL);

        $[vkfn vkCmdDraw]
        vkCmdDraw(commandBuffer, 4, 1, 0, 0);
    }
    proc draw {pipeline args} {
        set argsStruct [dict create]
        foreach argName [dict get $pipeline argNames] argValue $args {
            dict set argsStruct $argName $argValue
        }
        set addr [dict get $pipeline argsBuffer addr]
        updateArgs $addr $argsStruct
        drawImpl $pipeline
    }
    dc proc drawEnd {} void {
        $[vkfn vkCmdEndRenderPass]
        $[vkfn vkEndCommandBuffer]

        vkCmdEndRenderPass(commandBuffer);
        $[vktry {vkEndCommandBuffer(commandBuffer)}]

        VkSemaphore signalSemaphores[] = {renderFinishedSemaphore};
        {
            VkSubmitInfo submitInfo = {0};
            submitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;

            VkSemaphore waitSemaphores[] = {imageAvailableSemaphore};
            VkPipelineStageFlags waitStages[] = {VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
            submitInfo.waitSemaphoreCount = 1;
            submitInfo.pWaitSemaphores = waitSemaphores;
            submitInfo.pWaitDstStageMask = waitStages;

            submitInfo.commandBufferCount = 1;
            submitInfo.pCommandBuffers = &commandBuffer;

            submitInfo.signalSemaphoreCount = 1;
            submitInfo.pSignalSemaphores = signalSemaphores;

            $[vkfn vkQueueSubmit]
            $[vktry {vkQueueSubmit(graphicsQueue, 1, &submitInfo, inFlightFence)}]
        }
        {
            VkPresentInfoKHR presentInfo = {0};
            presentInfo.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
            presentInfo.waitSemaphoreCount = 1;
            presentInfo.pWaitSemaphores = signalSemaphores;

            VkSwapchainKHR swapchains[] = {swapchain};
            presentInfo.swapchainCount = 1;
            presentInfo.pSwapchains = swapchains;
            presentInfo.pImageIndices = &imageIndex;
            presentInfo.pResults = NULL;

            $[vkfn vkQueuePresentKHR]
            vkQueuePresentKHR(presentQueue, &presentInfo);
        }
    }

    dc proc poll {} void {
        glfwPollEvents();
    }

    proc pipeline {args body} {
        variable vertShaderModule
        if {![info exists vertShaderModule]} {
            set vertShaderModule [createShaderModule [glslc -fshader-stage=vert {
                #version 450

                vec2 positions[4] = vec2[](vec2(-1, -1),
                                           vec2(1, -1),
                                           vec2(-1, 1),
                                           vec2(1, 1));

                void main() {
                    gl_Position = vec4(positions[gl_VertexIndex], 0.0, 1.0);
                }
            }]]
        }

        set fragShaderModule [createShaderModule [glslc -fshader-stage=frag [csubst {
            #version 450

            layout(binding = 0) uniform Args {
                $[join [lmap {argtype argname} $args {expr {"$argtype $argname;"}}] "\n"]
            } args;

            layout(location = 0) out vec4 outColor;

            void main() {$body}
        }]]]

        set cc [c create]
        $cc include <cglm/cglm.h>
        $cc argtype vec2 {
            int objc; Tcl_Obj** objv;
            __ENSURE_OK(Tcl_ListObjGetElements(interp, $obj, &objc, &objv));
            __ENSURE(objc == 2);
            double x; __ENSURE_OK(Tcl_GetDoubleFromObj(interp, objv[0], &x));
            double y; __ENSURE_OK(Tcl_GetDoubleFromObj(interp, objv[1], &y));
            vec2 $argname = { (float)x, (float)y };
        }
        $cc rtype vec2 { $robj = Tcl_ObjPrintf("%f %f", $rvalue[0], $rvalue[1]); }
        $cc struct Args [join [lmap {argtype argname} $args {expr {"$argtype $argname;"}}] "\n"]
        $cc proc getArgsStructSize {} int { return sizeof(Args); }
        $cc proc updateArgs {void* addr Args args} void {
            memcpy(addr, &args, sizeof(args));
        }
        $cc compile

        set pipeline [Display::createPipeline $vertShaderModule $fragShaderModule [getArgsStructSize]]
        dict set pipeline argNames [lmap {argtype argname} $args {set argname}]
        return $pipeline
    }
}

proc glslc {args} {
    set cmdargs [lreplace $args end end]
    set glsl [lindex $args end]
    set glslfd [file tempfile glslfile glslfile.glsl]; puts $glslfd $glsl; close $glslfd
    split [string map {\n ""} [exec glslc {*}$cmdargs -mfmt=num -o - $glslfile]] ","
}

# Make a display list.
set displayList {
    {rect 10 10 200 200}
    {rect 210 210 500 500}
}
# https://vkguide.dev/docs/chapter-3/scene_management/

if {[info exists ::argv0] && $::argv0 eq [info script]} {
    namespace eval Display { dc compile }

    Display::init

    set circle [Display::pipeline {vec2 center float radius} {
        float d = length(gl_FragCoord.xy - args.center) - args.radius;
        outColor = d < 0.0 ? vec4(gl_FragCoord.xy / 640, 0, 1.0) : vec4(0, 0, 0, 0);
    }]

    Display::drawStart

    Display::draw $circle {100 200} 30
    # Display::draw $circle {300 300} 20

    Display::drawEnd

    while 1 { Display::poll }
}
