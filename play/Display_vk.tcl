# FOLK_ENTRY=play/Display_vk.tcl tclsh8.6 main.tcl

source "pi/cUtils.tcl"

set ::isLaptop false
proc When {args} {}
source "virtual-programs/images.folk"

namespace eval Display {
    set macos [expr {$tcl_platform(os) eq "Darwin"}]

    rename [c create] dc
    defineImageType dc
    dc cflags -I./vendor
    dc code {
        #define VOLK_IMPLEMENTATION
        #include "volk/volk.h"
    }
    dc include <stdlib.h>
    if {$macos} {
        dc include <GLFW/glfw3.h>
        dc cflags -lglfw
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

        VkCommandBuffer commandBuffer;
        uint32_t imageIndex;

        VkSemaphore imageAvailableSemaphore;
        VkSemaphore renderFinishedSemaphore;
        VkFence inFlightFence;
    }
    dc proc init {} void [csubst {
        $[vktry volkInitialize()]
        if ($macos) {
            glfwInit();
        }

        // Set up VkInstance instance:
        {
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
        volkLoadInstance(instance);

        // Set up VkPhysicalDevice physicalDevice
        {
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

            $[vktry {vkCreateDevice(physicalDevice, &createInfo, NULL, &device)}]
        }

        uint32_t propertyCount;
        vkEnumerateInstanceLayerProperties(&propertyCount, NULL);
        VkLayerProperties layerProperties[propertyCount];
        vkEnumerateInstanceLayerProperties(&propertyCount, layerProperties);

        // Get drawing surface.
        VkSurfaceKHR surface;
        $[expr { $macos ? { GLFWwindow* window; } : {} }]
        if (!$macos) {
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
            
            $[vktry {vkCreateSwapchainKHR(device, &createInfo, NULL, &swapchain)}]
        }

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

            $[vktry {vkCreateFramebuffer(device, &framebufferInfo, NULL, &swapchainFramebuffers[i])}]
        }

        VkCommandPool commandPool; {
            VkCommandPoolCreateInfo poolInfo = {0};
            poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
            poolInfo.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
            poolInfo.queueFamilyIndex = graphicsQueueFamilyIndex;

            $[vktry {vkCreateCommandPool(device, &poolInfo, NULL, &commandPool)}]
        }
        // Set up VkCommandBuffer commandBuffer
        {
            VkCommandBufferAllocateInfo allocInfo = {0};
            allocInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
            allocInfo.commandPool = commandPool;
            allocInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
            allocInfo.commandBufferCount = 1;

            $[vktry {vkAllocateCommandBuffers(device, &allocInfo, &commandBuffer)}]
        }
        
        {
            VkSemaphoreCreateInfo semaphoreInfo = {0};
            semaphoreInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;

            VkFenceCreateInfo fenceInfo = {0};
            fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
            fenceInfo.flags = VK_FENCE_CREATE_SIGNALED_BIT;

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

        VkShaderModule shaderModule;
        $[vktry {vkCreateShaderModule(device, &createInfo, NULL, &shaderModule)}]
        return shaderModule;
    }]

    # Pipeline creation:

    defineVulkanHandleType dc VkPipeline
    defineVulkanHandleType dc VkPipelineLayout
    defineVulkanHandleType dc VkDescriptorSet
    defineVulkanHandleType dc VkDescriptorSetLayout
    dc typedef uint64_t VkDeviceSize
    dc argtype VkDescriptorType { int $argname; __ENSURE_OK(Tcl_GetIntFromObj(interp, $obj, &$argname)); }
    dc rtype VkDescriptorType { $robj = Tcl_NewIntObj($rvalue); }
    variable VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER 1
    variable VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER 6
    dc struct PipelineBinding {
        char name[100];
        VkDescriptorType type;
        VkDeviceSize size;

        // If this binding directly maps to an argument in the
        // pipeline definition (i.e., it is not a binding for a
        // composite UBO of multiple arguments), then these are the
        // name, type, and index of that argument:
        char argname[100];
        char argtype[100];
        int argidx;
    }
    dc struct PipelineUboField {
        char argname[100];
        char argtype[100];
        int argidx;
    }
    dc struct Pipeline {
        VkPipeline pipeline;
        VkPipelineLayout pipelineLayout;
        VkDescriptorSetLayout descriptorSetLayout;

        int nbindings;
        PipelineBinding* bindings;

        int nuboFields;
        PipelineUboField* uboFields;
    }
    dc proc createPipeline {VkShaderModule vertShaderModule
                            VkShaderModule fragShaderModule
                            int nbindings PipelineBinding[] bindings
                            int nuboFields PipelineUboField[] uboFields} Pipeline [csubst {
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
        colorBlendAttachment.blendEnable = VK_TRUE;
        colorBlendAttachment.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
        colorBlendAttachment.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        colorBlendAttachment.colorBlendOp = VK_BLEND_OP_ADD;
        colorBlendAttachment.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
        colorBlendAttachment.dstAlphaBlendFactor = VK_BLEND_FACTOR_ZERO;
        colorBlendAttachment.alphaBlendOp = VK_BLEND_OP_ADD;

        VkPipelineColorBlendStateCreateInfo colorBlending = {0};
        colorBlending.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        colorBlending.logicOpEnable = VK_FALSE;
        colorBlending.logicOp = VK_LOGIC_OP_COPY; // Optional
        colorBlending.attachmentCount = 1;
        colorBlending.pAttachments = &colorBlendAttachment;

        VkDescriptorSetLayout descriptorSetLayout; {
            VkDescriptorSetLayoutBinding argsLayoutBindings[nbindings];
            for (int i = 0; i < nbindings; i++) {
                memset(&argsLayoutBindings[i], 0, sizeof(argsLayoutBindings[i]));
                argsLayoutBindings[i].binding = i;
                argsLayoutBindings[i].descriptorType = bindings[i].type;
                argsLayoutBindings[i].descriptorCount = 1;
                argsLayoutBindings[i].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
            }

            VkDescriptorSetLayoutCreateInfo layoutInfo = {0};
            layoutInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
            layoutInfo.bindingCount = nbindings;
            layoutInfo.pBindings = argsLayoutBindings;
            $[vktry {vkCreateDescriptorSetLayout(device, &layoutInfo, NULL, &descriptorSetLayout)}]
        }

        VkPipelineLayout pipelineLayout; {
            VkPipelineLayoutCreateInfo pipelineLayoutInfo = {0};
            pipelineLayoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
            pipelineLayoutInfo.setLayoutCount = 1;
            pipelineLayoutInfo.pSetLayouts = &descriptorSetLayout;
            
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

            $[vktry {vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &pipelineInfo, NULL, &pipeline)}]
        }

        PipelineBinding* bindingsRetain = ckalloc(nbindings*sizeof(PipelineBinding));
        memcpy(bindingsRetain, bindings, nbindings*sizeof(PipelineBinding));
        PipelineUboField* uboFieldsRetain = ckalloc(nuboFields*sizeof(PipelineUboField));
        memcpy(uboFieldsRetain, uboFields, nuboFields*sizeof(PipelineUboField));
        return (Pipeline) {
            .pipeline = pipeline,
            .pipelineLayout = pipelineLayout,
            .descriptorSetLayout = descriptorSetLayout,

            .nbindings = nbindings,
            .bindings = bindingsRetain,

            .nuboFields = nuboFields,
            .uboFields = uboFieldsRetain
        };
    }]

    # Buffer allocation:

    dc code [csubst {
        uint32_t findMemoryType(uint32_t typeFilter, VkMemoryPropertyFlags properties) {
            VkPhysicalDeviceMemoryProperties memProperties;
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

            $[vktry {vkCreateBuffer(device, &bufferInfo, NULL, buffer)}]

            VkMemoryRequirements memRequirements;
            vkGetBufferMemoryRequirements(device, *buffer, &memRequirements);

            VkMemoryAllocateInfo allocInfo = {0};
            allocInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
            allocInfo.allocationSize = memRequirements.size;
            allocInfo.memoryTypeIndex = findMemoryType(memRequirements.memoryTypeBits, properties);

            $[vktry {vkAllocateMemory(device, &allocInfo, NULL, bufferMemory)}]
            vkBindBufferMemory(device, *buffer, *bufferMemory, 0);
        }
    }]

    # Image allocation:
    dc code [csubst {
        void createImage(uint32_t width, uint32_t height,
                         VkFormat format, VkImageTiling tiling, VkImageUsageFlags usage, VkMemoryPropertyFlags properties,
                         VkImage* image, VkDeviceMemory* imageMemory) {
            VkImageCreateInfo imageInfo = {0};
            imageInfo.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
            imageInfo.imageType = VK_IMAGE_TYPE_2D;
            imageInfo.extent.width = width;
            imageInfo.extent.height = height;
            imageInfo.extent.depth = 1;
            imageInfo.mipLevels = 1;
            imageInfo.arrayLayers = 1;
            imageInfo.format = format;
            imageInfo.tiling = tiling;
            imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
            imageInfo.usage = usage;
            imageInfo.samples = VK_SAMPLE_COUNT_1_BIT;
            imageInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;

            $[vktry {vkCreateImage(device, &imageInfo, NULL, image)}]

            VkMemoryRequirements memRequirements;
            vkGetImageMemoryRequirements(device, *image, &memRequirements);

            VkMemoryAllocateInfo allocInfo = {0};
            allocInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
            allocInfo.allocationSize = memRequirements.size;
            allocInfo.memoryTypeIndex = findMemoryType(memRequirements.memoryTypeBits, properties);

            $[vktry {vkAllocateMemory(device, &allocInfo, NULL, imageMemory)}]

            vkBindImageMemory(device, *image, *imageMemory, 0);
        }
        void transitionImageLayout(VkCommandBuffer commandBuffer,
                                   VkImage image, VkFormat format, VkImageLayout oldLayout, VkImageLayout newLayout) {
            VkImageMemoryBarrier barrier = {0};
            barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
            barrier.oldLayout = oldLayout;
            barrier.newLayout = newLayout;
            barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
            barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
            barrier.image = image;
            barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
            barrier.subresourceRange.baseMipLevel = 0;
            barrier.subresourceRange.levelCount = 1;
            barrier.subresourceRange.baseArrayLayer = 0;
            barrier.subresourceRange.layerCount = 1;

            VkPipelineStageFlags sourceStage;
            VkPipelineStageFlags destinationStage;
            if (oldLayout == VK_IMAGE_LAYOUT_UNDEFINED && newLayout == VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) {
                barrier.srcAccessMask = 0;
                barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;

                sourceStage = VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
                destinationStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
            } else if (oldLayout == VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL && newLayout == VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) {
                barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
                barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;

                sourceStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
                destinationStage = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
            } else {
                exit(91);
            }
            vkCmdPipelineBarrier(commandBuffer,
                                 sourceStage, destinationStage,
                                 0,
                                 0, NULL,
                                 0, NULL,
                                 1, &barrier);
        }
    }]
    

    defineVulkanHandleType dc VkBuffer
    defineVulkanHandleType dc VkDeviceMemory
    defineVulkanHandleType dc VkDescriptorSet
    defineVulkanHandleType dc VkImage
    defineVulkanHandleType dc VkImageView
    defineVulkanHandleType dc VkSampler
    # A single input resource for a Pipeline. (Note that multiple
    # pipeline arguments get coalesced into 1 input resource, if
    # they're coalesced into a single uniform buffer.)
    dc struct PipelineInputResource {
        // For a uniform buffer:
        VkBuffer buffer;
        VkDeviceMemory memory;
        void* addr;

        // For an image:
        VkBuffer stagingBuffer;
        VkDeviceMemory stagingBufferMemory;
        VkImage textureImage;
        VkDeviceMemory textureImageMemory;
        VkImageView textureImageView;
        VkSampler textureSampler;
    }
    dc struct PipelineInputResourceParameters {
        // For a uniform buffer: none

        // For an image:
        int width;
        int height;
    }
    # Called before draw time.
    dc proc pipelineInputResourceCopyUniformBufferData {PipelineInputResource resource Tcl_Obj* data} void {
        int n; uint8_t* buf = Tcl_GetByteArrayFromObj(data, &n);
        memcpy(resource.addr, buf, n);
    }
    # Called before draw time.
    dc proc pipelineInputResourceCopyImage {PipelineInputResource resource image_t im} void {
        size_t size = im.width * im.height * 4;

        // Copy im to resource.stagingBuffer:
        void* data;
        vkMapMemory(device, resource.stagingBufferMemory, 0, size, 0, &data);
        memcpy(data, im.data, size);
        vkUnmapMemory(device, resource.stagingBufferMemory);

        transitionImageLayout(commandBuffer,
                              resource.textureImage, VK_FORMAT_R8G8B8A8_SRGB, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
        // Copy ret.stagingBuffer to ret.textureImage:
        {
            VkBufferImageCopy region = {0};
            region.bufferOffset = 0;
            region.bufferRowLength = 0;
            region.bufferImageHeight = 0;

            region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
            region.imageSubresource.mipLevel = 0;
            region.imageSubresource.baseArrayLayer = 0;
            region.imageSubresource.layerCount = 1;

            region.imageOffset = (VkOffset3D) {0, 0, 0};
            region.imageExtent = (VkExtent3D) {im.width, im.height, 1};
            vkCmdCopyBufferToImage(commandBuffer,
                                   resource.stagingBuffer,
                                   resource.textureImage,
                                   VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                                   1,
                                   &region);
        }
        transitionImageLayout(commandBuffer,
                              resource.textureImage, VK_FORMAT_R8G8B8A8_SRGB, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
    }
    # Stores and describes all inputs of a Pipeline. You need to
    # allocate as many PipelineInputSet per pipeline as you might have
    # invocations in flight of that pipeline.
    dc struct PipelineInputSet {
        int nresources; // Should be equal to nbindings for the Pipeline.
        PipelineInputResource* resources;

        VkDescriptorSet descriptorSet;
    }
    dc proc createPipelineInputResource {PipelineBinding binding PipelineInputResourceParameters parameters} PipelineInputResource {
        PipelineInputResource ret;
        if (binding.type == VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER) {
            createBuffer(binding.size, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                         VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                         &ret.buffer, &ret.memory);
            vkMapMemory(device, ret.memory, 0, binding.size, 0, &ret.addr);

        } else if (binding.type == VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER) {
            memset(&ret, 0, sizeof(ret));

            // FIXME: allocate all the stuff
            size_t size = parameters.width * parameters.height * 4;
            createBuffer(size, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                         VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                         &ret.stagingBuffer, &ret.stagingBufferMemory);
            // The buffer will be used by draw to copy the image in.

            createImage(parameters.width, parameters.height,
                        VK_FORMAT_R8G8B8A8_SRGB, VK_IMAGE_TILING_OPTIMAL,
                        VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
                        &ret.textureImage, &ret.textureImageMemory);
            // Set up ret.textureImageView:
            {
                VkImageViewCreateInfo viewInfo = {0};
                viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
                viewInfo.image = ret.textureImage;
                viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
                viewInfo.format = VK_FORMAT_R8G8B8A8_SRGB;
                viewInfo.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
                viewInfo.subresourceRange.baseMipLevel = 0;
                viewInfo.subresourceRange.levelCount = 1;
                viewInfo.subresourceRange.baseArrayLayer = 0;
                viewInfo.subresourceRange.layerCount = 1;
                $[vktry {vkCreateImageView(device, &viewInfo, NULL, &ret.textureImageView)}]
            }
            // Set up ret.textureSampler:
            {
                VkSamplerCreateInfo samplerInfo = {0};
                samplerInfo.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
                samplerInfo.magFilter = VK_FILTER_LINEAR;
                samplerInfo.minFilter = VK_FILTER_LINEAR;
                samplerInfo.addressModeU = VK_SAMPLER_ADDRESS_MODE_REPEAT;
                samplerInfo.addressModeV = VK_SAMPLER_ADDRESS_MODE_REPEAT;
                samplerInfo.addressModeW = VK_SAMPLER_ADDRESS_MODE_REPEAT;
                samplerInfo.anisotropyEnable = VK_FALSE; // TODO: do we want this?
                samplerInfo.borderColor = VK_BORDER_COLOR_INT_OPAQUE_BLACK;
                samplerInfo.unnormalizedCoordinates = VK_FALSE;
                samplerInfo.compareEnable = VK_FALSE;
                samplerInfo.compareOp = VK_COMPARE_OP_ALWAYS;
                samplerInfo.mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR;
                samplerInfo.mipLodBias = 0.0f;
                samplerInfo.minLod = 0.0f;
                samplerInfo.maxLod = 0.0f;
                $[vktry {vkCreateSampler(device, &samplerInfo, NULL, &ret.textureSampler)}]
            }
        } else { exit(90); }
        return ret;
    }
    dc proc createPipelineInputSet {Pipeline pipeline PipelineInputResourceParameters[] parameters} PipelineInputSet {
        PipelineInputSet ret;
        ret.nresources = pipeline.nbindings;
        ret.resources = ckalloc(sizeof(PipelineInputResource) * ret.nresources);
        for (int i = 0; i < pipeline.nbindings; i++) {
            ret.resources[i] = createPipelineInputResource(pipeline.bindings[i], parameters[i]);
        }

        static VkDescriptorPool descriptorPool = NULL;
        if (descriptorPool == NULL) {
            // TODO: Generalize the way this works.
            VkDescriptorPoolSize poolSizes[2] = {0};
            poolSizes[0].type = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
            poolSizes[0].descriptorCount = 100;
            poolSizes[1].type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            poolSizes[1].descriptorCount = 100;

            VkDescriptorPoolCreateInfo poolInfo = {0};
            poolInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
            poolInfo.poolSizeCount = 2;
            poolInfo.pPoolSizes = poolSizes;
            poolInfo.maxSets = 100;
            $[vktry {vkCreateDescriptorPool(device, &poolInfo, NULL, &descriptorPool)}]
        }

        // Set up ret.descriptorSet:
        {
            VkDescriptorSetAllocateInfo allocInfo = {0};
            allocInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
            allocInfo.descriptorPool = descriptorPool;
            allocInfo.descriptorSetCount = 1;
            allocInfo.pSetLayouts = &pipeline.descriptorSetLayout;

            $[vktry {vkAllocateDescriptorSets(device, &allocInfo, &ret.descriptorSet)}]
        }
        // Write to ret.descriptorSet so it points at all the resources:
        {
            VkWriteDescriptorSet descriptorWrites[pipeline.nbindings];
            for (int i = 0; i < pipeline.nbindings; i++) {
                VkWriteDescriptorSet* descriptorWrite = &descriptorWrites[i];
                memset(descriptorWrite, 0, sizeof(*descriptorWrite));
                descriptorWrite->sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
                descriptorWrite->dstSet = ret.descriptorSet;
                descriptorWrite->dstBinding = i;
                descriptorWrite->dstArrayElement = 0;
                descriptorWrite->descriptorType = pipeline.bindings[i].type;
                descriptorWrite->descriptorCount = 1;

                if (descriptorWrite->descriptorType == VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER) {
                    VkDescriptorBufferInfo* bufferInfo = alloca(sizeof(VkDescriptorBufferInfo));
                    memset(bufferInfo, 0, sizeof(*bufferInfo));

                    bufferInfo->buffer = ret.resources[i].buffer;
                    bufferInfo->offset = 0;
                    bufferInfo->range = pipeline.bindings[i].size;
                    descriptorWrite->pBufferInfo = bufferInfo;
                } else if (descriptorWrite->descriptorType == VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER) {
                    VkDescriptorImageInfo* imageInfo = alloca(sizeof(VkDescriptorImageInfo));
                    memset(imageInfo, 0, sizeof(*imageInfo));

                    imageInfo->imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
                    imageInfo->imageView = ret.resources[i].textureImageView;
                    imageInfo->sampler = ret.resources[i].textureSampler;
                    descriptorWrite->pImageInfo = imageInfo;
                } else {
                    exit(90);
                }
            }

            vkUpdateDescriptorSets(device, pipeline.nbindings, descriptorWrites, 0, NULL);
        }

        return ret;
    }

    dc proc drawStart {} void {
        vkWaitForFences(device, 1, &inFlightFence, VK_TRUE, UINT64_MAX);

        vkResetFences(device, 1, &inFlightFence);

        vkAcquireNextImageKHR(device, swapchain, UINT64_MAX, imageAvailableSemaphore, VK_NULL_HANDLE, &imageIndex);

        vkResetCommandBuffer(commandBuffer, 0);

        VkCommandBufferBeginInfo beginInfo = {0};
        beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        beginInfo.flags = 0; // TODO: Should this be one-time?
        beginInfo.pInheritanceInfo = NULL;
        $[vktry {vkBeginCommandBuffer(commandBuffer, &beginInfo)}]

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
    dc proc drawImpl {Pipeline pipeline PipelineInputSet inputSet} void {
        vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipeline);

        vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                                pipeline.pipelineLayout,
                                0, 1,
                                &inputSet.descriptorSet, 0, NULL);

        vkCmdDraw(commandBuffer, 4, 1, 0, 0);
    }
    variable pipelineInputSetsCache [dict create]
    proc pipelineFindOrCreateUnusedInputSet {pipeline arglist} {
        variable pipelineInputSetsCache
        variable VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
        # Iterate over the pipeline bindings. Find any additional
        # parameters for the input set.
        set parameters [list]
        for {set i 0} {$i < [Pipeline nbindings $pipeline]} {incr i} {
            set binding [Pipeline bindings $pipeline $i]
            set type [PipelineBinding type $binding]
            if {$type == $VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER} {
                set argidx [PipelineBinding argidx $binding]
                set im [lindex $arglist $argidx]
                puts "im is ($im)"
                lappend parameters [dict create width [image width $im] height [image height $im]]
            } else {
                # TODO: hack
                lappend parameters [dict create width 0 height 0]
            }
        }
        set key [list $pipeline $parameters]

        if {![dict exists $pipelineInputSetsCache $key]} {
            for {set i 0} {$i < 5} {incr i} {
                set inputSet [createPipelineInputSet $pipeline $parameters]
                dict set pipelineInputSetsCache $key $inputSet false
            }
        }
        dict for {iSet isInUse} [dict get $pipelineInputSetsCache $key] {
            if {!$isInUse} {
                # Mark as in-use:
                set inputSet $iSet
                dict set pipelineInputSetsCache $key $inputSet true
                break
            }
        }
        if {![info exists inputSet]} { error "No available input set for pipeline" }
        return $inputSet
    }
    proc draw {pipeline args} {
        set inputSet [pipelineFindOrCreateUnusedInputSet $pipeline $args]

        # TODO: Figure out packing rules for UBO struct.
        set uboFmt [list]
        set uboArgs [list]
        for {set i 0} {$i < [Pipeline nuboFields $pipeline]} {incr i} {
            set uboField [Pipeline uboFields $pipeline $i]
            set argtype [PipelineUboField argtype $uboField]
            set argidx [PipelineUboField argidx $uboField]
            if {$argtype eq "float"} { lappend uboFmt "f" } \
                elseif {$argtype eq "vec2"} { lappend uboFmt "f2" }
            lappend uboArgs [lindex $args $argidx]
        }
        set uboData [binary format [join $uboFmt ""] {*}$uboArgs]

        set nbindings [dict get $pipeline nbindings]
        variable VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
        variable VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
        for {set i 0} {$i < $nbindings} {incr i} {
            set binding [Pipeline bindings $pipeline $i]
            set resource [PipelineInputSet resources $inputSet $i]
            set type [PipelineBinding type $binding]
            if {$type == $VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER} {
                pipelineInputResourceCopyUniformBufferData $resource $uboData
            } elseif {$type == $VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER} {
                set im [lindex $args [PipelineBinding argidx $binding]]
                pipelineInputResourceCopyImage $resource $im
            }
        }

        drawImpl $pipeline $inputSet
    }
    dc proc drawEnd {} void {
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

        variable VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
        variable VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER

        set uboFields [list]
        set bindings [list]
        set argidx 0
        foreach {argtype argname} $args {
            if {$argtype eq "sampler2D"} {
                lappend bindings [dict create \
                                      name $argname \
                                      type $VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER \
                                      size 0 \
                                      \
                                      argname $argname \
                                      argtype $argtype \
                                      argidx $argidx]
            } else {
                lappend uboFields [dict create \
                                       argtype $argtype \
                                       argname $argname \
                                       argidx $argidx]
            }
            incr argidx
        }
        if {[llength $uboFields] > 0} {
            set size 0
            foreach field $uboFields { dict with field {
                if {$argtype eq "float"} { set size [+ $size 4] } \
                    elseif {$argtype eq "vec2"} { set size [+ $size 8] }
            } }
            set binding [dict create name Args type $VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER size $size \
                            argname "" argtype "" argidx -1]
            set bindings [list $binding {*}$bindings]
        }

        set fragShaderModule [createShaderModule [glslc -fshader-stage=frag [csubst {
            #version 450

            $[join [lmap {i binding} [lenumerate $bindings] {
                if {[dict get $binding type] eq $VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER} { subst {
                    layout(binding = $i) uniform Args {
                        [join [lmap field $uboFields {
                            dict with field {
                                expr {"$argtype $argname;"}
                            }
                        }] "\n"]
                    } args;
                } } else { subst {
                    layout(binding = $i) uniform [dict get $binding argtype] [dict get $binding argname];
                } }
            }] "\n"]

            layout(location = 0) out vec4 outColor;

            void main() {
                $[join [lmap field $uboFields {
                    dict with field {
                        expr {"$argtype $argname = args.$argname;"}
                    }
                }] " "]
                $body
            }
        }]]]

        # pipeline needs to contain a specification of all args,
        # so Display::draw can fill the args into UBO and samplers etc.
        set pipeline [Display::createPipeline $vertShaderModule $fragShaderModule \
                          [llength $bindings] $bindings \
                          [llength $uboFields] $uboFields]
        return $pipeline
    }
}

proc glslc {args} {
    set cmdargs [lreplace $args end end]
    set glsl [lindex $args end]
    set glslfd [file tempfile glslfile glslfile.glsl]; puts $glslfd $glsl; close $glslfd
    split [string map {\n ""} [exec glslc {*}$cmdargs -mfmt=num -o - $glslfile]] ","
}

if {[info exists ::argv0] && $::argv0 eq [info script] || \
        ([info exists ::entry] && $::entry == "play/Display_vk.tcl")} {
    namespace eval Display { dc compile }

    Display::init

    # set circle [Display::pipeline {vec2 center float radius} {
    #     float dist = length(gl_FragCoord.xy - center) - radius;
    #     outColor = dist < 0.0 ? vec4(gl_FragCoord.xy / 640, 0, 1.0) : vec4(0, 0, 0, 0);
    # }]

    # set line [Display::pipeline {vec2 from vec2 to float thickness} {
    #     float l = length(to - from);
    #     vec2 d = (to - from) / l;
    #     vec2 q = (gl_FragCoord.xy - (from + to)*0.5);
    #          q = mat2(d.x, -d.y, d.y, d.x) * q;
    #          q = abs(q) - vec2(l, thickness)*0.5;
    #     float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);

    #     outColor = dist < 0.0 ? vec4(1, 0, 1, 1) : vec4(0, 0, 0, 0);
    # }]

    set image [Display::pipeline {sampler2D image} {
        outColor = vec4(1, 0, 0, 1);
    }]

    # FIXME: bounding box for scissors
    # FIXME: sampler2D, text

    # set redOnRight [Display::pipeline {} {
    #     outColor = gl_FragCoord.x > 400 ? vec4(gl_FragCoord.x / 4096.0, 0, 0, 1.0) : vec4(0, 0, 0, 0);
    # }]

    Display::drawStart

    # Display::draw $circle {200 50} 30
    # Display::draw $circle {300 300} 20
    # Display::draw $line {0 0} {100 100} 10
    # Display::draw $redOnRight
    Display::draw $image [image loadJpeg "/Users/osnr/Downloads/u9.jpg"]

    Display::drawEnd

    while 1 { Display::poll }
}
