source "lib/c.tcl"

namespace eval Display {
    rename [c create] dc
    dc include <vulkan/vulkan.h>
    dc include <stdlib.h>
    dc include <dlfcn.h>

    dc proc init {} void {
        void *vulkanLibrary = dlopen("libvulkan.so.1", RTLD_NOW);
        PFN_vkGetInstanceProcAddr vkGetInstanceProcAddr = (PFN_vkGetInstanceProcAddr) dlsym(vulkanLibrary, "vkGetInstanceProcAddr");
        PFN_vkCreateInstance vkCreateInstance = (PFN_vkCreateInstance) vkGetInstanceProcAddr(NULL, "vkCreateInstance");

        VkInstance instance; {
            VkInstanceCreateInfo createInfo = {0};
            createInfo.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
            createInfo.enabledLayerCount = 0;

            // extensions for non-X11/Wayland display
            const char *enabledExtensions[] = {
                VK_KHR_SURFACE_EXTENSION_NAME,
                VK_KHR_DISPLAY_EXTENSION_NAME
            };
            createInfo.enabledExtensionCount = sizeof(enabledExtensions)/sizeof(enabledExtensions[0]);
            createInfo.ppEnabledExtensionNames = enabledExtensions;

            if (vkCreateInstance(&createInfo, NULL, &instance) != VK_SUCCESS) {
                fprintf(stderr, "Failed to create Vulkan instance\n"); exit(1);
            }
        }

        VkPhysicalDevice physicalDevice; {
            PFN_vkEnumeratePhysicalDevices vkEnumeratePhysicalDevices =
                (PFN_vkEnumeratePhysicalDevices) vkGetInstanceProcAddr(instance, "vkEnumeratePhysicalDevices");

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

        
        uint32_t graphicsQueueFamilyIndex = UINT32_MAX; {
            PFN_vkGetPhysicalDeviceQueueFamilyProperties vkGetPhysicalDeviceQueueFamilyProperties =
            (PFN_vkGetPhysicalDeviceQueueFamilyProperties) vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceQueueFamilyProperties");

            uint32_t queueFamilyCount = 0;
            vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice, &queueFamilyCount, NULL);
            VkQueueFamilyProperties queueFamilies[queueFamilyCount];
            vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice, &queueFamilyCount, queueFamilies);
            for (int i = 0; i < queueFamilyCount; i++) {
                if (queueFamilies[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
                    graphicsQueueFamilyIndex = i;
                }
            }
            if (graphicsQueueFamilyIndex == UINT32_MAX) {
                fprintf(stderr, "Failed to find a Vulkan graphics queue family\n"); exit(1);
            }
        }

        VkDevice device; {
            VkDeviceQueueCreateInfo queueCreateInfo = {0};
            queueCreateInfo.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
            queueCreateInfo.queueFamilyIndex = graphicsQueueFamilyIndex;
            queueCreateInfo.queueCount = 1;
            float queuePriority = 1.0f;
            queueCreateInfo.pQueuePriorities = &queuePriority;

            VkPhysicalDeviceFeatures deviceFeatures = {0};

            VkDeviceCreateInfo createInfo = {0};
            createInfo.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
            createInfo.pQueueCreateInfos = &queueCreateInfo;
            createInfo.queueCreateInfoCount = 1;
            createInfo.pEnabledFeatures = &deviceFeatures;
            createInfo.enabledLayerCount = 0;
            createInfo.enabledExtensionCount = 0;

            PFN_vkCreateDevice vkCreateDevice =
                    (PFN_vkCreateDevice) vkGetInstanceProcAddr(instance, "vkCreateDevice");
            if (vkCreateDevice(physicalDevice, &createInfo, NULL, &device) != VK_SUCCESS) {
                fprintf(stderr, "Failed to create Vulkan logical device\n"); exit(1);
            }
        }

        VkQueue graphicsQueue; {
            PFN_vkGetDeviceQueue vkGetDeviceQueue =
                (PFN_vkGetDeviceQueue) vkGetInstanceProcAddr(instance, "vkGetDeviceQueue");
            vkGetDeviceQueue(device, graphicsQueueFamilyIndex, 0, &graphicsQueue);
        }

        /* VkSurfaceKHR surface; { */
        /*     VkDisplaySurfaceCreateInfoKHR createInfo = {0}; */
        /*     createInfo.sType = VK_STRUCTURE_TYPE_DISPLAY_SURFACE_CREATE_INFO_KHR; */
        /*     createInfo.displayMode = 0; */
        /*     createInfo.planeIndex = 0; */
        /*     // createInfo.imageExtent = visibleRegion; */
        /*     vkCreateDisplayPlaneSurfaceKHR(instance, &createInfo, NULL, &surface); */
        /* } */

        
        

//        uint32_t display_count = 0;
//        vkGetPhysicalDeviceDisplayPropertiesKHR(vc->physical_device,
//                                                &display_count, NULL);
    }

    dc compile
}

Display::init
