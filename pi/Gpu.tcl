# Gpu.tcl --
#
#     Hardware interface with the GPU (Vulkan). Provides the ability
#     to run pixel shaders with image and numerical parameters (so you
#     can draw images, shapes, etc from Display.)

source "pi/cUtils.tcl"
if {[info exists ::argv0] && $::argv0 eq [info script] || \
        ([info exists ::entry] && $::entry == "pi/Gpu.tcl")} {
    set ::isLaptop true
    set ::thisNode [exec hostname]
    source "lib/language.tcl"
    source "lib/c.tcl"
    proc When {args} {}
}
source "virtual-programs/images.folk"

namespace eval ::Gpu {
    set macos [expr {$tcl_platform(os) eq "Darwin"}]

    if {!$macos} {
        foreach renderFile [glob -nocomplain "/dev/dri/render*"] {
            if {![file readable $renderFile]} {
                puts stderr "Gpu: Warning: $renderFile is not readable by current user; Vulkan device may not appear.
Try doing `sudo adduser folk render`."
            }
        }
    }
    
    if {$::isLaptop} {
        set WIDTH [* 640 2]; set HEIGHT [* 480 2]
    } else {
        regexp {mode "(\d+)x(\d+)"} [exec fbset] -> WIDTH HEIGHT
    }

    rename [c create] dc
    defineImageType dc
    dc cflags -I./vendor
    dc code {
        #define VOLK_IMPLEMENTATION
        #include "volk/volk.h"

        static const char* VkResultToString(VkResult res) {
                switch (res) {
        #define CASE(x) case VK_##x: return #x;
                CASE(SUCCESS)                       CASE(NOT_READY)
                CASE(TIMEOUT)                       CASE(EVENT_SET)
                CASE(EVENT_RESET)                   CASE(INCOMPLETE)
                CASE(ERROR_OUT_OF_HOST_MEMORY)      CASE(ERROR_OUT_OF_DEVICE_MEMORY)
                CASE(ERROR_INITIALIZATION_FAILED)   CASE(ERROR_DEVICE_LOST)
                CASE(ERROR_MEMORY_MAP_FAILED)       CASE(ERROR_LAYER_NOT_PRESENT)
                CASE(ERROR_EXTENSION_NOT_PRESENT)   CASE(ERROR_FEATURE_NOT_PRESENT)
                CASE(ERROR_INCOMPATIBLE_DRIVER)     CASE(ERROR_TOO_MANY_OBJECTS)
                CASE(ERROR_FORMAT_NOT_SUPPORTED)    CASE(ERROR_FRAGMENTED_POOL)
                CASE(ERROR_UNKNOWN)                 CASE(ERROR_OUT_OF_POOL_MEMORY)
                CASE(ERROR_INVALID_EXTERNAL_HANDLE) CASE(ERROR_FRAGMENTATION)
                CASE(ERROR_INVALID_OPAQUE_CAPTURE_ADDRESS)
                CASE(PIPELINE_COMPILE_REQUIRED)      CASE(ERROR_SURFACE_LOST_KHR)
                CASE(ERROR_NATIVE_WINDOW_IN_USE_KHR) CASE(SUBOPTIMAL_KHR)
                CASE(ERROR_OUT_OF_DATE_KHR)          CASE(ERROR_INCOMPATIBLE_DISPLAY_KHR)
                CASE(ERROR_VALIDATION_FAILED_EXT)    CASE(ERROR_INVALID_SHADER_NV)
        #ifdef VK_ENABLE_BETA_EXTENSIONS
                CASE(ERROR_IMAGE_USAGE_NOT_SUPPORTED_KHR)
                CASE(ERROR_VIDEO_PICTURE_LAYOUT_NOT_SUPPORTED_KHR)
                CASE(ERROR_VIDEO_PROFILE_OPERATION_NOT_SUPPORTED_KHR)
                CASE(ERROR_VIDEO_PROFILE_FORMAT_NOT_SUPPORTED_KHR)
                CASE(ERROR_VIDEO_PROFILE_CODEC_NOT_SUPPORTED_KHR)
                CASE(ERROR_VIDEO_STD_VERSION_NOT_SUPPORTED_KHR)
        #endif
                CASE(ERROR_INVALID_DRM_FORMAT_MODIFIER_PLANE_LAYOUT_EXT)
                CASE(ERROR_NOT_PERMITTED_KHR)
                CASE(ERROR_FULL_SCREEN_EXCLUSIVE_MODE_LOST_EXT)
                CASE(THREAD_IDLE_KHR)        CASE(THREAD_DONE_KHR)
                CASE(OPERATION_DEFERRED_KHR) CASE(OPERATION_NOT_DEFERRED_KHR)
                default: return "unknown";
                }
        #undef CASE
        }
    }
    dc include <stdlib.h>
    if {$macos} {
        dc cflags -I/opt/homebrew/include -L/opt/homebrew/lib
        dc include <GLFW/glfw3.h>
        dc cflags -lglfw
    }

    proc vktry {call} { string map {\n " "} [csubst {{
        VkResult res = $call;
        if (res != VK_SUCCESS) {
            fprintf(stderr, "Failed $call: %s (%d)\n",
                    VkResultToString(res), res); exit(1);
        }
    }}] }
    namespace export vktry

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

        VkCommandPool commandPool;

        VkCommandBuffer commandBuffer;
        uint32_t imageIndex;

        VkSemaphore imageAvailableSemaphore;
        VkSemaphore renderFinishedSemaphore;
        VkFence inFlightFence;
    }
    dc proc init {} void [csubst {
        $[vktry volkInitialize()]
        $[if {$macos} { expr {"glfwInit();"} }]

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
                VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME,
            }} : {{
                // 2 extensions for non-X11/Wayland display
                VK_KHR_SURFACE_EXTENSION_NAME,
                VK_KHR_DISPLAY_EXTENSION_NAME,
                VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME,
            }} }];
            createInfo.enabledExtensionCount = sizeof(enabledExtensions)/sizeof(enabledExtensions[0]);
            createInfo.ppEnabledExtensionNames = enabledExtensions;
            $[if {$macos} { expr {{
                createInfo.flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
            }} }]
            VkResult res = vkCreateInstance(&createInfo, NULL, &instance);
            if (res != VK_SUCCESS) {
                fprintf(stderr, "Failed vkCreateInstance: %s (%d)\n",
                        VkResultToString(res), res);
                if (res == VK_ERROR_LAYER_NOT_PRESENT) {
                    fprintf(stderr, "\nIt looks like a required layer is missing.\n"
                            "Did you install `vulkan-validationlayers`?\n");
                }
                exit(1);
            }
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
                "VK_KHR_portability_subset",
                VK_KHR_MAINTENANCE3_EXTENSION_NAME
            }} : {{
                VK_KHR_SWAPCHAIN_EXTENSION_NAME,
                VK_KHR_MAINTENANCE3_EXTENSION_NAME
            }} }];

            VkDeviceCreateInfo createInfo = {0};
            createInfo.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
            createInfo.pQueueCreateInfos = &queueCreateInfo;
            createInfo.queueCreateInfoCount = 1;
            createInfo.pEnabledFeatures = &deviceFeatures;
            createInfo.enabledLayerCount = 0;
            createInfo.enabledExtensionCount = sizeof(deviceExtensions)/sizeof(deviceExtensions[0]);
            createInfo.ppEnabledExtensionNames = deviceExtensions;

            /* VkPhysicalDeviceDescriptorIndexingFeatures descriptorIndexingFeatures = {0}; */
            /* descriptorIndexingFeatures.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES; */
            /* descriptorIndexingFeatures.descriptorBindingPartiallyBound = VK_TRUE; */
            /* // TODO: Do we need more descriptor indexing features? */
            /* createInfo.pNext = &descriptorIndexingFeatures; */

            $[vktry {vkCreateDevice(physicalDevice, &createInfo, NULL, &device)}]
        }

        uint32_t propertyCount;
        vkEnumerateInstanceLayerProperties(&propertyCount, NULL);
        VkLayerProperties layerProperties[propertyCount];
        vkEnumerateInstanceLayerProperties(&propertyCount, layerProperties);

        // Get drawing surface.
        VkSurfaceKHR surface;
        $[expr { $macos ? {
            GLFWwindow* window;
            glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
            window = glfwCreateWindow(640, 480, "Window Title", NULL, NULL);
            if (glfwCreateWindowSurface(instance, window, NULL, &surface) != VK_SUCCESS) {
                fprintf(stderr, "Failed to create GLFW window surface\n"); exit(1);
            }
        } : [csubst {
            // TODO: support multiple displays, pick best display mode

            uint32_t displayCount = 1; VkDisplayPropertiesKHR displayProps;
            vkGetPhysicalDeviceDisplayPropertiesKHR(physicalDevice, &displayCount, &displayProps);

            uint32_t modeCount = 1; VkDisplayModePropertiesKHR modeProps;
            vkGetDisplayModePropertiesKHR(physicalDevice, displayProps.display, &modeCount, &modeProps);

            VkDisplaySurfaceCreateInfoKHR createInfo = {0};
            createInfo.sType = VK_STRUCTURE_TYPE_DISPLAY_SURFACE_CREATE_INFO_KHR;
            createInfo.displayMode = modeProps.displayMode;
            createInfo.planeIndex = 0;
            createInfo.transform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
            createInfo.alphaMode = VK_DISPLAY_PLANE_ALPHA_PER_PIXEL_BIT_KHR;
            createInfo.imageExtent = (VkExtent2D) { .width = $WIDTH, .height = $HEIGHT }; // TODO: find out
            if (vkCreateDisplayPlaneSurfaceKHR(instance, &createInfo, NULL, &surface) != VK_SUCCESS) {
                fprintf(stderr, "Failed to create Vulkan display plane surface\n"); exit(1);
            }
        }] }]

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
                $[expr { $macos ? {
                    glfwGetFramebufferSize(window, (int*) &extent.width, (int*) &extent.height);
                    if (capabilities.minImageExtent.width > extent.width) { extent.width = capabilities.minImageExtent.width; }
                    if (capabilities.maxImageExtent.width < extent.width) { extent.width = capabilities.maxImageExtent.width; }
                    if (capabilities.minImageExtent.height > extent.height) { extent.height = capabilities.minImageExtent.height; }
                    if (capabilities.maxImageExtent.height < extent.height) { extent.height = capabilities.maxImageExtent.height; }
                } : {} }]
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
        swapchainFramebuffers = (VkFramebuffer *) ckalloc(sizeof(VkFramebuffer) * swapchainImageCount);
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

        // Set up VkCommandPool commandPool
        {
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
#ifdef VK_USE_64_BIT_PTR_DEFINES
            %s $argname; sscanf(Tcl_GetString($obj), "(%s) 0x%%p", &$argname);
#else
            %s $argname; sscanf(Tcl_GetString($obj), "(%s) 0x%%llx", &$argname);
#endif
        } $type $type $type $type]
        # Tcl_ObjPrintf doesn't work with %lld/%llx for some reason,
        # so we do it by hand.
        $cc rtype $type [format {
#ifdef VK_USE_64_BIT_PTR_DEFINES
            $robj = Tcl_ObjPrintf("(%s) 0x%%" PRIxPTR, (uintptr_t) $rvalue);
#else
            {
              char buf[100]; snprintf(buf, 100, "(%s) 0x%%llx", $rvalue);
              $robj = Tcl_NewStringObj(buf, -1);
            }
#endif
        } $type $type]
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
    dc struct Pipeline {
        VkPipeline pipeline;
        VkPipelineLayout pipelineLayout;

        int id;
        size_t pushConstantsSize;
    }
    dc proc createPipeline {int id
                            VkShaderModule vertShaderModule
                            VkShaderModule fragShaderModule
                            size_t pushConstantsSize} Pipeline [csubst {
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
            // We're just going to draw a quad (4 vertices -> first 3
            // vertices are top-left triangle, last 3 vertices are
            // bottom-right triangle).
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

        VkPipelineLayout pipelineLayout; {
            VkPipelineLayoutCreateInfo pipelineLayoutInfo = {0};
            pipelineLayoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;

            pipelineLayoutInfo.pSetLayouts = &imageDescriptorSetLayout;
            pipelineLayoutInfo.setLayoutCount = 1;

            // We configure all pipelines with push constants size =
            // 128 (the maximum), no matter what actual push constants
            // they take; this is so that pipelines are all
            // layout-compatible so we can reuse descriptor set
            // between pipelines without needing to rebind it.
            {
                VkPushConstantRange pushConstantRange = {0};
                pushConstantRange.offset = 0;
                pushConstantRange.size = 128;
                pushConstantRange.stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT;

                pipelineLayoutInfo.pPushConstantRanges = &pushConstantRange;
                pipelineLayoutInfo.pushConstantRangeCount = 1;
            }

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

        return (Pipeline) {
            .pipeline = pipeline,
            .pipelineLayout = pipelineLayout,

            .id = id,
            .pushConstantsSize = pushConstantsSize
        };
    }]
    
    dc code {
        static VkPipeline boundPipeline;
        static VkDescriptorSet boundDescriptorSet;
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

        boundPipeline = VK_NULL_HANDLE;
        boundDescriptorSet = VK_NULL_HANDLE;
    }
    dc proc drawImpl {Pipeline pipeline Tcl_Obj* pushConstantsObj} void {
        if (boundPipeline != pipeline.pipeline) {
            vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipeline);
            boundPipeline = pipeline.pipeline;
        }

        if (boundDescriptorSet != imageDescriptorSet) {
            vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                                    pipeline.pipelineLayout, 0, 1, &imageDescriptorSet, 0, NULL);
            boundDescriptorSet = imageDescriptorSet;
        }

        {
            int pushConstantsDataSize;
            uint8_t* pushConstantsData = Tcl_GetByteArrayFromObj(pushConstantsObj, &pushConstantsDataSize);
            if (pushConstantsDataSize != pipeline.pushConstantsSize) {
                fprintf(stderr, "drawImpl: Expected push constants size %zu; push constants data size was %d\n",
                        pipeline.pushConstantsSize, pushConstantsDataSize);
                exit(101);
            }
            vkCmdPushConstants(commandBuffer, pipeline.pipelineLayout,
                               VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 0,
                               pipeline.pushConstantsSize, pushConstantsData);
        }

        // 1 quad -> 2 triangles -> 6 vertices
        vkCmdDraw(commandBuffer, 6, 1, 0, 0);
    }

    # Draw to the screen using pipeline `pipeline`. Each arg in `args`
    # should be a push-constant parameter of the pipeline. Can only be
    # called between `drawStart` and `drawEnd`.
    proc draw {pipeline args} {
        variable WIDTH; variable HEIGHT
        set args [linsert $args 0 [list $WIDTH $HEIGHT]]

        drawImpl $pipeline [encodeArgs[Pipeline id $pipeline] {*}$args]
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
        $[expr { $macos ? { glfwPollEvents(); } : {} }]
    }

    # Construct a reusable GLSL function that can be linked into and
    # called from a shader/pipeline.
    proc fn {args rtype body} {
        set fnArgs [list]
        # We inline all dependent functions from the caller scope
        # immediately here, since we don't know if those dependencies
        # would be accessible/in scope at all when this function gets
        # actually compiled into a shader.
        set depFnDict [dict create]
        foreach {argtype argname} $args {
            if {$argtype eq "fn"} {
                # TODO: Support fn being a list {fnName fn}.
                dict set depFnDict [string map {: ""} $argname] [uplevel [list set $argname]]
            } else {
                lappend fnArgs $argtype $argname
            }
        }
        return [list $fnArgs $depFnDict $rtype $body]
    }

    # Construct a shader pipeline that can be used to draw to the
    # screen.
    variable nextPipelineId 0
    proc pipeline {args} {
        if {[llength $args] == 3} {
            lassign $args vertArgs vertBody fragBody
            set fragArgs [list]
        } elseif {[llength $args] == 4} {
            lassign $args vertArgs vertBody fragArgs fragBody
        } else {
            error {Gpu::pipeline: should be used as [Gpu::pipeline vertArgs vertBody fragBody], or [Gpu::pipeline vertArgs vertBody fragArgs fragBody]}
        }
        set vertFnDict [dict create]
        set fragFnDict [dict create]
        set pushConstants [list]
        set vertArgs [linsert $vertArgs 0 vec2 _resolution]
        foreach {argtype argname} $vertArgs {
            if {$argtype eq "fn"} {
                # TODO: Support fn being a list {name fn}.
                set fn [uplevel [list set $argname]]
                set vertFnDict [dict merge $vertFnDict [lindex $fn 1]]
                dict set vertFnDict [string map {: ""} $argname] $fn
                continue
            }
            lappend pushConstants $argtype $argname
        }
        foreach {argtype argname} $fragArgs {
            if {$argtype eq "fn"} {
                # TODO: Support fn being a list {name fn}.
                set fn [uplevel [list set $argname]]
                set fragFnDict [dict merge $fragFnDict [lindex $fn 1]]
                dict set fragFnDict [string map {: ""} $argname] $fn
                continue
            } else {
                error "Fragment arguments not supported"
            }
        }

        # Create a C subcompiler to create a fast routine to encode
        # the push constants on each draw call.
        set cc [c create]
        $cc typedef int sampler2D
        $cc struct vec2 { float x; float y; }
        $cc struct vec3 { float x; float y; float z; }
        $cc struct vec4 { float x; float y; float z; float w; }
        $cc struct uvec4 { uint32_t x; uint32_t y; uint32_t z; uint32_t w; }

        $cc argtype vec2 {
            vec2 $argname;
            {
                int $[set argname]_objc; Tcl_Obj** $[set argname]_objv;
                __ENSURE_OK(Tcl_ListObjGetElements(interp, $obj, &$[set argname]_objc, &$[set argname]_objv));
                __ENSURE($[set argname]_objc == 2);
                double x; __ENSURE_OK(Tcl_GetDoubleFromObj(interp, $[set argname]_objv[0], &x));
                double y; __ENSURE_OK(Tcl_GetDoubleFromObj(interp, $[set argname]_objv[1], &y));
                $argname = (vec2) { (float)x, (float)y };
            }
        }
        $cc argtype vec3 {
            vec3 $argname;
            {
                int $[set argname]_objc; Tcl_Obj** $[set argname]_objv;
                __ENSURE_OK(Tcl_ListObjGetElements(interp, $obj, &$[set argname]_objc, &$[set argname]_objv));
                __ENSURE($[set argname]_objc == 3);
                double x; __ENSURE_OK(Tcl_GetDoubleFromObj(interp, $[set argname]_objv[0], &x));
                double y; __ENSURE_OK(Tcl_GetDoubleFromObj(interp, $[set argname]_objv[1], &y));
                double z; __ENSURE_OK(Tcl_GetDoubleFromObj(interp, $[set argname]_objv[2], &z));
                $argname = (vec3) { (float)x, (float)y, (float)z };
            }
        }
        $cc argtype vec4 {
            vec4 $argname;
            {
                int $[set argname]_objc; Tcl_Obj** $[set argname]_objv;
                __ENSURE_OK(Tcl_ListObjGetElements(interp, $obj, &$[set argname]_objc, &$[set argname]_objv));
                __ENSURE($[set argname]_objc == 4);
                double x; __ENSURE_OK(Tcl_GetDoubleFromObj(interp, $[set argname]_objv[0], &x));
                double y; __ENSURE_OK(Tcl_GetDoubleFromObj(interp, $[set argname]_objv[1], &y));
                double z; __ENSURE_OK(Tcl_GetDoubleFromObj(interp, $[set argname]_objv[2], &z));
                double w; __ENSURE_OK(Tcl_GetDoubleFromObj(interp, $[set argname]_objv[3], &w));
                $argname = (vec4) { (float)x, (float)y, (float)z, (float)w };
            }
        }
        $cc argtype uvec4 {
            uvec4 $argname;
            {
                int $[set argname]_objc; Tcl_Obj** $[set argname]_objv;
                __ENSURE_OK(Tcl_ListObjGetElements(interp, $obj, &$[set argname]_objc, &$[set argname]_objv));
                __ENSURE($[set argname]_objc == 4);
                uint32_t x; __ENSURE_OK(Tcl_GetIntFromObj(interp, $[set argname]_objv[0], (int*) &x));
                uint32_t y; __ENSURE_OK(Tcl_GetIntFromObj(interp, $[set argname]_objv[1], (int*) &y));
                uint32_t z; __ENSURE_OK(Tcl_GetIntFromObj(interp, $[set argname]_objv[2], (int*) &z));
                uint32_t w; __ENSURE_OK(Tcl_GetIntFromObj(interp, $[set argname]_objv[3], (int*) &w));
                $argname = (uvec4) { (uint32_t)x, (uint32_t)y, (uint32_t)z, (uint32_t)w };
            }
        }
        $cc code [csubst {
            typedef struct Args {
                $[join [lmap {argtype argname} $pushConstants {
                    expr {"_Alignas(sizeof($argtype)) $argtype $argname;"}
                }] "\n"]
            } Args;
        }]
        $cc include <stddef.h>
        $cc proc getArgsSize {} int { return sizeof(Args); }
        variable nextPipelineId
        set pipelineId $nextPipelineId
        $cc proc encodeArgs$pipelineId $pushConstants Tcl_Obj* {
            Args args = {$[join [lmap {argtype argname} $pushConstants { subst {.$argname = $argname} }] " ,"]};
            return Tcl_NewByteArrayObj((uint8_t *)&args, sizeof(args));
        }
        $cc compile
        incr nextPipelineId

        set pushConstantsSize [getArgsSize]

        set pushConstantsCode [if {[llength $pushConstants] > 0} {
            subst {
                layout(push_constant) uniform Args {
                    [join [lmap {argtype argname} $pushConstants {
                        if {$argname eq "_"} continue
                        if {$argtype eq "sampler2D"} {
                            expr {"int $argname;"}
                        } else {
                            expr {"$argtype $argname;"}
                        }
                    }] "\n"]
                } args;
            }
        }]

        set vertShaderModule [createShaderModule [glslc -fshader-stage=vert [csubst {
            #version 450

            $pushConstantsCode

            $[join [dict values [dict map {fnName fn} $vertFnDict {
                lassign $fn fnArgs _ fnRtype fnBody
                subst {
                    $fnRtype $fnName ([join [lmap {fnArgtype fnArgname} $fnArgs {subst {$fnArgtype $fnArgname}}] ", "]) {
                        $fnBody
                    }
                }
            }]] "\n"]

            vec2 vert() {
                $[join [lmap {argtype argname} $pushConstants {
                    if {$argname eq "_"} continue
                    if {$argtype eq "sampler2D"} continue
                    expr {"$argtype $argname = args.$argname;"}
                }] " "]
                $vertBody
            }

            void main() {
                vec2 v = (2.0*vert() - args._resolution)/args._resolution;
                gl_Position = vec4(v, 0.0, 1.0);
            }
        }]]]
        # We pass the descriptor set with all images (samplers) to all
        # fragment shaders, so we never need to rebind it (at draw
        # time, the shader may get an index into the array if it's
        # meant to draw an image).
        #
        # Note that we use combined image + sampler, instead of 1
        # global sampler and multiple textures/images, because that's
        # the only way to allow each image to have its own dimensions
        # (dimensions are a property bound to the sampler).
        set fragShaderModule [createShaderModule [glslc -fshader-stage=frag [csubst {
            #version 450

            layout(set = 0, binding = 0) uniform sampler2D _samplers[$ImageManager::GPU_MAX_IMAGES];

            $pushConstantsCode

            layout(location = 0) out vec4 outColor;

            $[join [dict values [dict map {fnName fn} $fragFnDict {
                lassign $fn fnArgs _ fnRtype fnBody
                subst {
                    $fnRtype $fnName ([join [lmap {fnArgtype fnArgname} $fnArgs {subst {$fnArgtype $fnArgname}}] ", "]) {
                        $fnBody
                    }
                }
            }]] "\n"]

            $[join [lmap {argtype argname} $pushConstants {
                if {$argtype eq "sampler2D"} {
                    expr {"#define $argname _samplers\[args.$argname\]"}
                }
            }] "\n"]

            vec4 frag() {
                $[join [lmap {argtype argname} $pushConstants {
                    if {$argname eq "_"} continue
                    if {$argtype ne "sampler2D"} {
                        expr {"$argtype $argname = args.$argname;"}
                    }
                }] " "]
                $fragBody
            }
            void main() { outColor = frag(); }
        }]]]

        # pipeline needs to contain a specification of push constants,
        # so they can be filled in at draw time.
        set pipeline [Gpu::createPipeline $pipelineId $vertShaderModule $fragShaderModule \
                          $pushConstantsSize]
        return $pipeline
    }

    namespace export dc
    namespace eval ImageManager {
        namespace import [namespace parent]::*

        # TODO: Support more than 16 concurrent images. This
        # constraint is imposed by Vulkan by default (device
        # maxPerStageDescriptorSamplers limit is 16). I think we can
        # increase it by querying GPU settings somehow.
        variable GPU_MAX_IMAGES 16

        # The technique used to manage images here is to have a
        # single giant descriptor set for a giant GPU-side array of
        # images, which all shaders can access. (That descriptor set
        # _never_ has to be rebound; it stays bound through all draw
        # calls, forever.)
        # 
        # Each image has to be 'copied to the GPU' before you do any
        # draw calls that use it. Copying an image to the GPU gives
        # you a GPU-side image handle, which is just an integer index
        # into the GPU-side array. You can pass that image handle
        # into draw calls as a parameter (push constant) when you
        # want to draw/use the image.
        #
        # See:
        # - http://kylehalladay.com/blog/tutorial/vulkan/2018/01/28/Textue-Arrays-Vulkan.html
        # - https://chunkstories.xyz/blog/a-note-on-descriptor-indexing/
        # - https://gist.github.com/DethRaid/0171f3cfcce51950ee4ef96c64f59617
        # - http://roar11.com/2019/06/vulkan-textures-unbound/
        dc code {
            VkDescriptorSetLayout imageDescriptorSetLayout;
            VkDescriptorSet imageDescriptorSet;
        }
        dc proc imageManagerInit {} void {
            // Set up imageDescriptorSetLayout:
            {
                /* VkDescriptorBindingFlags flags[1]; */
                /* flags[0] = VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT; */

                /* VkDescriptorSetLayoutBindingFlagsCreateInfo bindingFlags = {0}; */
                /* bindingFlags.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO; */
                /* bindingFlags.bindingCount = 1; */
                /* bindingFlags.pBindingFlags = flags; */

                VkDescriptorSetLayoutBinding bindings[1];
                memset(bindings, 0, sizeof(bindings));
                bindings[0].binding = 0;
                bindings[0].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
                bindings[0].descriptorCount = $GPU_MAX_IMAGES;
                bindings[0].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;

                VkDescriptorSetLayoutCreateInfo createInfo = {0};
                createInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
                createInfo.bindingCount = 1;
                createInfo.pBindings = bindings;
                /* createInfo.flags = VK_DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT; */
                /* createInfo.pNext = &bindingFlags; */

                vkCreateDescriptorSetLayout(device, &createInfo, NULL, &imageDescriptorSetLayout);
            }
            
            VkDescriptorPool descriptorPool; {
                VkDescriptorPoolSize poolSize = {0};
                poolSize.type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
                poolSize.descriptorCount = 512;

                VkDescriptorPoolCreateInfo poolInfo = {0};
                poolInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
                poolInfo.poolSizeCount = 1;
                poolInfo.pPoolSizes = &poolSize;
                poolInfo.maxSets = 100;
                $[vktry {vkCreateDescriptorPool(device, &poolInfo, NULL, &descriptorPool)}]
            }

            // Set up imageDescriptorSet:
            {
                VkDescriptorSetAllocateInfo allocInfo = {0};
                allocInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
                allocInfo.descriptorPool = descriptorPool;
                allocInfo.descriptorSetCount = 1;
                allocInfo.pSetLayouts = &imageDescriptorSetLayout;

                $[vktry {vkAllocateDescriptorSets(device, &allocInfo, &imageDescriptorSet)}]
            }
        }

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
            VkCommandBuffer beginSingleTimeCommands() {
                VkCommandBufferAllocateInfo allocInfo = {0};
                allocInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
                allocInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
                allocInfo.commandPool = commandPool;
                allocInfo.commandBufferCount = 1;

                VkCommandBuffer commandBuffer;
                vkAllocateCommandBuffers(device, &allocInfo, &commandBuffer);

                VkCommandBufferBeginInfo beginInfo = {0};
                beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
                beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;

                vkBeginCommandBuffer(commandBuffer, &beginInfo);

                return commandBuffer;
            }
            void endSingleTimeCommands(VkCommandBuffer commandBuffer) {
                vkEndCommandBuffer(commandBuffer);

                VkSubmitInfo submitInfo = {0};
                submitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
                submitInfo.commandBufferCount = 1;
                submitInfo.pCommandBuffers = &commandBuffer;

                vkQueueSubmit(graphicsQueue, 1, &submitInfo, VK_NULL_HANDLE);
                vkQueueWaitIdle(graphicsQueue);

                vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);
            }
            void transitionImageLayout(VkImage image, VkFormat format,
                                       VkImageLayout oldLayout, VkImageLayout newLayout) {
                VkCommandBuffer commandBuffer = beginSingleTimeCommands();

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

                endSingleTimeCommands(commandBuffer);
            }
        }]

        # Allocates(!) a copy of `im` with 4 channels, on the Tcl
        # local heap. Up to the caller to free it.
        dc proc copyImageToRgba {image_t im} image_t {
            if (im.components == 4) return im;
            if (im.components != 1 && im.components != 3) exit(2);

            image_t ret = im;
            ret.components = 4;
            ret.bytesPerRow = ret.width * ret.components;
            ret.data = ckalloc(ret.bytesPerRow * ret.height);

            if (im.components == 3) {
                for (int y = 0; y < im.height; y++) {
                    for (int x = 0; x < im.width; x++) {
                        int imidx = y*im.bytesPerRow + x*im.components;
                        int r = im.data[imidx+0],
                            g = im.data[imidx+1], 
                            b = im.data[imidx+2];

                        int ridx = y*ret.bytesPerRow + x*ret.components;
                        ret.data[ridx+0] = r;
                        ret.data[ridx+1] = g;
                        ret.data[ridx+2] = b;
                        ret.data[ridx+3] = 255;
                    }
                }
            } else {
                for (int y = 0; y < im.height; y++) {
                    for (int x = 0; x < im.width; x++) {
                        int imidx = y*im.bytesPerRow + x*im.components;
                        int r = im.data[imidx],
                            g = im.data[imidx], 
                            b = im.data[imidx];

                        int ridx = y*ret.bytesPerRow + x*ret.components;
                        ret.data[ridx+0] = r;
                        ret.data[ridx+1] = g;
                        ret.data[ridx+2] = b;
                        ret.data[ridx+3] = 255;
                    }
                }
            }
            return ret;
        }

        dc typedef int gpu_image_handle_t
        dc code [csubst {
            // Points to all GPU-side data structures associated with
            // an image (that we will destroy when we evict that
            // image).
            typedef struct gpu_image_block {
                bool alive;

                VkImage textureImage;
                VkDeviceMemory textureImageMemory;
                VkImageView textureImageView;
                VkSampler textureSampler; 
            } gpu_image_block;
            gpu_image_block gpuImages[$GPU_MAX_IMAGES];

            gpu_image_handle_t allocateGpuImageHandle() {
                for (int i = 0; i < $GPU_MAX_IMAGES; i++) {
                    if (!gpuImages[i].alive) { return i; }
                }
                fprintf(stderr, "Gpu: Exceeded GPU_MAX_IMAGES\n"); exit(1);
            }
        }]
        dc proc copyImageToGpu {image_t im0} gpu_image_handle_t {
            gpu_image_handle_t imageId = allocateGpuImageHandle();
            gpu_image_block* block = &gpuImages[imageId];
            block->alive = true;

            // Image must be RGBA.
            image_t im;
            if (im0.components != 4) { im = copyImageToRgba(im0); }
            else { im = im0; }

            size_t size = im.width * im.height * 4;

            VkBuffer stagingBuffer;
            VkDeviceMemory stagingBufferMemory;
            createBuffer(size, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                         VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                         &stagingBuffer, &stagingBufferMemory);

            createImage(im.width, im.height,
                        VK_FORMAT_R8G8B8A8_SRGB, VK_IMAGE_TILING_OPTIMAL,
                        VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
                        &block->textureImage, &block->textureImageMemory);

            // Set up block->textureImageView:
            {
                VkImageViewCreateInfo viewInfo = {0};
                viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
                viewInfo.image = block->textureImage;
                viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
                viewInfo.format = VK_FORMAT_R8G8B8A8_SRGB;
                viewInfo.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
                viewInfo.subresourceRange.baseMipLevel = 0;
                viewInfo.subresourceRange.levelCount = 1;
                viewInfo.subresourceRange.baseArrayLayer = 0;
                viewInfo.subresourceRange.layerCount = 1;
                $[vktry {vkCreateImageView(device, &viewInfo, NULL, &block->textureImageView)}]
            }
            // Set up block->textureSampler:
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
                $[vktry {vkCreateSampler(device, &samplerInfo, NULL, &block->textureSampler)}]
            }

            // Copy im to stagingBuffer:
            {
                void* data; vkMapMemory(device, stagingBufferMemory, 0, size, 0, &data);
                for (int y = 0; y < im.height; y++) {
                    memcpy(data + y*im.width*4,
                           im.data + y*im.bytesPerRow,
                           im.width*4);
                }
                vkUnmapMemory(device, stagingBufferMemory);
            }
            // Copy stagingBuffer to block->textureImage:
            {
                transitionImageLayout(block->textureImage, VK_FORMAT_R8G8B8A8_SRGB,
                                      VK_IMAGE_LAYOUT_UNDEFINED,
                                      VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);

                VkCommandBuffer commandBuffer = beginSingleTimeCommands();

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
                                       stagingBuffer,
                                       block->textureImage,
                                       VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                                       1,
                                       &region);

                endSingleTimeCommands(commandBuffer);

                transitionImageLayout(block->textureImage, VK_FORMAT_R8G8B8A8_SRGB,
                                      VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                                      VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
            }

            vkDestroyBuffer(device, stagingBuffer, NULL);
            vkFreeMemory(device, stagingBufferMemory, NULL);

            // Write this image+sampler to the imageDescriptorSet
            static bool didInitializeDescriptors = false;
            {
                VkDescriptorImageInfo imageInfo = {0};
                imageInfo.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
                imageInfo.imageView = block->textureImageView;
                imageInfo.sampler = block->textureSampler;

                if (!didInitializeDescriptors) {
                    // Hack: if we're not using the descriptor
                    // indexing extension, we can't have a partially
                    // bound descriptor set, so we need to fill all
                    // the slots in the image array with
                    // _something_. We just fill all slots wtih the
                    // first image for now. See
                    // http://roar11.com/2019/06/vulkan-textures-unbound/
                    VkWriteDescriptorSet descriptorWrites[$GPU_MAX_IMAGES] = {0};
                    for (int i = 0; i < $GPU_MAX_IMAGES; i++) {
                        descriptorWrites[i].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
                        descriptorWrites[i].dstSet = imageDescriptorSet;
                        descriptorWrites[i].dstBinding = 0;
                        descriptorWrites[i].dstArrayElement = i;
                        descriptorWrites[i].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
                        descriptorWrites[i].descriptorCount = 1;
                        descriptorWrites[i].pImageInfo = &imageInfo;
                    }
                    vkUpdateDescriptorSets(device, $GPU_MAX_IMAGES, descriptorWrites, 0, NULL);
                    didInitializeDescriptors = true;
                } else {
                    VkWriteDescriptorSet descriptorWrite = {0};
                    descriptorWrite.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
                    descriptorWrite.dstSet = imageDescriptorSet;
                    descriptorWrite.dstBinding = 0;
                    descriptorWrite.dstArrayElement = imageId;
                    descriptorWrite.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
                    descriptorWrite.descriptorCount = 1;
                    descriptorWrite.pImageInfo = &imageInfo;
                    vkUpdateDescriptorSets(device, 1, &descriptorWrite, 0, NULL);
                }
            }

            if (im0.components != 4) { ckfree(im.data); }
            return imageId;
        }
        dc proc freeGpuImage {gpu_image_handle_t gim} void {
            gpu_image_block* block = &gpuImages[gim];
            block->alive = false;

            vkDeviceWaitIdle(device); // TODO: this is probably slow

            // HACK: Use GPU image 0 as a placeholder so it doesn't
            // fault if it tries to access this freed image.
            {
                VkDescriptorImageInfo imageInfo = {0};
                imageInfo.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
                imageInfo.imageView = gpuImages[0].textureImageView;
                imageInfo.sampler = gpuImages[0].textureSampler;

                VkWriteDescriptorSet descriptorWrite = {0};
                descriptorWrite.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
                descriptorWrite.dstSet = imageDescriptorSet;
                descriptorWrite.dstBinding = 0;
                descriptorWrite.dstArrayElement = gim;
                descriptorWrite.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
                descriptorWrite.descriptorCount = 1;
                descriptorWrite.pImageInfo = &imageInfo;
                vkUpdateDescriptorSets(device, 1, &descriptorWrite, 0, NULL);
            }

            vkDestroyImage(device, block->textureImage, NULL);
            vkFreeMemory(device, block->textureImageMemory, NULL);
            vkDestroySampler(device, block->textureSampler, NULL);
            vkDestroyImageView(device, block->textureImageView, NULL);
        }
    }

    if {!$macos} {
        # Needed on Raspberry Pi 4:
        c loadlib [lindex [exec /usr/sbin/ldconfig -p | grep libatomic.so | head -1] end]
    }

    dc compile
}

proc glslc {args} {
    set cmdargs [lreplace $args end end]
    set glsl [lindex $args end]
    set glslfd [file tempfile glslfile glslfile.glsl]; puts $glslfd $glsl; close $glslfd
    split [string map {\n ""} [exec glslc {*}$cmdargs -mfmt=num -o - $glslfile]] ","
}

if {[info exists ::argv0] && $::argv0 eq [info script] || \
        ([info exists ::entry] && $::entry == "pi/Gpu.tcl")} {
    Gpu::init
    Gpu::ImageManager::imageManagerInit

    set fullScreenVert {
        vec2 vertices[4] = vec2[4](vec2(0, 0), vec2(_resolution.x, 0), vec2(0, _resolution.y), _resolution);
        return vertices[gl_VertexIndex];
    }
    set circle [Gpu::pipeline {vec2 center float radius} $fullScreenVert {
        float dist = length(gl_FragCoord.xy - center) - radius;
        return dist < 0.0 ? vec4(gl_FragCoord.xy / 640, 0, 1.0) : vec4(0, 0, 0, 0);
    }]

    set line [Gpu::pipeline {vec2 from vec2 to float thickness} {
        vec2 vertices[4] = vec2[4](
             min(from, to) - thickness,
             vec2(max(from.x, to.x) + thickness, min(from.y, to.y) - thickness),
             vec2(min(from.x, to.x) - thickness, max(from.y, to.y) + thickness),
             max(from, to) + thickness
        );
        return vertices[gl_VertexIndex];
    } {
        float l = length(to - from);
        vec2 d = (to - from) / l;
        vec2 q = (gl_FragCoord.xy - (from + to)*0.5);
             q = mat2(d.x, -d.y, d.y, d.x) * q;
             q = abs(q) - vec2(l, thickness)*0.5;
        float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);

        return dist < 0.0 ? vec4(1, 0, 1, 1) : vec4(0, 0, 0, 0);
    }]

    set redOnRight [Gpu::pipeline {} $fullScreenVert {
        return gl_FragCoord.x > 640 ? vec4(gl_FragCoord.x / 4096.0, 0, 0, 1.0) : vec4(0, 0, 0, 0);
    }]

    # Inverse bilinear interpolation, based on
    # https://www.shadertoy.com/view/lsBSDm
    set cross2d [Gpu::fn {vec2 a vec2 b} float {
        return a.x*b.y - a.y*b.x;
    }]
    set invBilinear [Gpu::fn {vec2 p vec2 a vec2 b vec2 c vec2 d fn cross2d} vec2 {
        vec2 res = vec2(-1.0);

        vec2 e = b-a;
        vec2 f = d-a;
        vec2 g = a-b+c-d;
        vec2 h = p-a;
        
        float k2 = cross2d( g, f );
        float k1 = cross2d( e, f ) + cross2d( h, g );
        float k0 = cross2d( h, e );

        // if edges are parallel, this is a linear equation
        if( abs(k2)<0.001 )
        {
            res = vec2( (h.x*k1+f.x*k0)/(e.x*k1-g.x*k0), -k0/k1 );
        }
        // otherwise, it's a quadratic
	else
        {
            float w = k1*k1 - 4.0*k0*k2;
            if( w<0.0 ) return vec2(-1.0);
            w = sqrt( w );

            float ik2 = 0.5/k2;
            float v = (-k1 - w)*ik2;
            float u = (h.x - f.x*v)/(e.x + g.x*v);
            
            if( u<0.0 || u>1.0 || v<0.0 || v>1.0 )
            {
                v = (-k1 + w)*ik2;
                u = (h.x - f.x*v)/(e.x + g.x*v);
            }
            res = vec2( u, v );
        }
        return res;
    }]

    set image [Gpu::pipeline {sampler2D image vec2 a vec2 b vec2 c vec2 d} {
        vec2 vertices[4] = vec2[4](a, b, d, c);
        return vertices[gl_VertexIndex];
    } {fn invBilinear} {
        vec2 p = gl_FragCoord.xy;
        vec2 uv = invBilinear(p, a, b, c, d);
        if( max( abs(uv.x-0.5), abs(uv.y-0.5))<0.5 ) {
            return texture(image, uv);
        }
        return vec4(0.0, 0.0, 0.0, 0.0);
    }]

    source "virtual-programs/print.folk"

    if {[string match "scoriae*" $::thisNode]} {
        set impath "/Users/osnr/Downloads/u9.jpg"
        set impath2 "/Users/osnr/Downloads/793.jpg"
    } elseif {$::thisNode eq "folk0" || $thisNode eq "folk-omar"} {
        set impath "/home/folk/folk-images/html-energy-laptops.jpeg"
        set impath2 "/home/folk/folk-images/megaman-sprites-5x2.jpg"
    } else { error "Don't know what images to use." }
    set im [Gpu::ImageManager::copyImageToGpu [image loadJpeg $impath]]
    set im2 [Gpu::ImageManager::copyImageToGpu [image loadJpeg $impath2]]

    set aprilTag [Gpu::pipeline {uvec4 tagBitsVec
                                 vec2 a vec2 b vec2 c vec2 d} {
        vec2 vertices[4] = vec2[4](a, b, d, c);
        return vertices[gl_VertexIndex];
    } {fn invBilinear} {
        vec2 p = gl_FragCoord.xy;
        vec2 uv = invBilinear(p, a, b, c, d);

        int x = int(uv.x * 10); int y = int(uv.y * 10);
        int bitIdx = y * 10 + x;
        uint bit = (tagBitsVec[bitIdx / 32] >> (bitIdx % 32)) & 0x1;
        return bit == 1 ? vec4(1, 1, 1, 1) : vec4(0, 0, 0, 1);
    }]
    set drawTags [list]
    for {set i 0} {$i < 20} {incr i} {
        set tagImage [::tagImageForId $i]
        set tagBits [list]
        # 10x10 AprilTag -> 100 bits
        for {set y 0} {$y < 10} {incr y} {
            for {set x 0} {$x < 10} {incr x} {
                set j [expr {$y * [image_t bytesPerRow $tagImage] + $x}]
                set bit [== [image_t data $tagImage $j] 255]
                lappend tagBits $bit
            }
        }
        # -> 2 64-bit integers
        set tagBitsVec [list 0b[join [lreverse [lrange $tagBits 0 31]] ""] \
                            0b[join [lreverse [lrange $tagBits 32 63]] ""] \
                            0b[join [lreverse [lrange $tagBits 64 95]] ""] \
                            0b[join [lreverse [lrange $tagBits 96 127]] ""]]
        set x [expr {200 + $i*45}]
        set y 0
        lappend drawTags \
            [list Gpu::draw $aprilTag $tagBitsVec \
                 [list $x $y]               [list [+ $x 40] $y] \
                 [list [+ $x 40] [+ $y 40]] [list $x [+ $y 40]]]
    }

    set t 0
    while 1 {
        if {$t == 100} {
            puts "Im2 is $im2"
            Gpu::ImageManager::freeGpuImage $im2
            set im2 [Gpu::ImageManager::copyImageToGpu [image loadJpeg "/Users/osnr/Downloads/IMG_5992.jpeg"]]
            puts "New im2 is $im2"
        }

        Gpu::drawStart

        Gpu::draw $circle {200 50} 30
        Gpu::draw $circle {300 300} 20
        Gpu::draw $line {0 0} {100 100} 10
        Gpu::draw $redOnRight

        Gpu::draw $image $im2 {100 0} {200 0} {200 200} {100 200}
        Gpu::draw $image $im [list [expr {sin($t/300.0)*300}] 300] {400 300} {400 400} {200 400}

        foreach drawTag $drawTags { {*}$drawTag }

        Gpu::draw $line {100 0} {200 0} 10
        Gpu::draw $line {200 0} {200 200} 10
        Gpu::draw $line {200 200} {100 200} 10
        Gpu::draw $line {100 200} {100 0} 10

        Gpu::drawEnd
        Gpu::poll
        incr t
    }
}
