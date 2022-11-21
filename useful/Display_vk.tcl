source "lib/c.tcl"

proc csubst {s} {
    uplevel [list subst [string map {\\ \\\\ [ \\[ $\[ [} $s]]
}

namespace eval Display {
    set macos [expr {$tcl_platform(os) eq "Darwin"}]

    rename [c create] dc
    dc include <vulkan/vulkan.h>
    dc include <stdlib.h>
    dc include <dlfcn.h>
    if {$macos} {
        dc include <GLFW/glfw3.h>
        dc cflags -lglfw
        c loadlib "libVkLayer_khronos_validation.dylib"
    }

    dc proc init {} void [csubst {
        if ($macos) {
            glfwInit();
        }

        void *vulkanLibrary = dlopen("$[expr { $macos ? "libMoltenVK.dylib" : "libvulkan.so.1" }]", RTLD_NOW);
        if (vulkanLibrary == NULL) {
            fprintf(stderr, "Failed to load libvulkan: %s\n", dlerror()); exit(1);
        }
        PFN_vkGetInstanceProcAddr vkGetInstanceProcAddr = (PFN_vkGetInstanceProcAddr) dlsym(vulkanLibrary, "vkGetInstanceProcAddr");

        VkInstance instance; {
            PFN_vkCreateInstance vkCreateInstance =
                (PFN_vkCreateInstance) vkGetInstanceProcAddr(NULL, "vkCreateInstance");

            VkInstanceCreateInfo createInfo = {0};
            createInfo.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;

            const char* validationLayers[] = {
                "VK_LAYER_KHRONOS_validation"
            };
            createInfo.enabledLayerCount = sizeof(validationLayers)/sizeof(validationLayers[0]);
            createInfo.ppEnabledLayerNames = validationLayers;

            const char* enabledExtensions[] = $[expr { $macos ? {{
                VK_KHR_SURFACE_EXTENSION_NAME,
                "VK_EXT_metal_surface"
            }} : {{
                // 2 extensions for non-X11/Wayland display
                VK_KHR_SURFACE_EXTENSION_NAME,
                VK_KHR_DISPLAY_EXTENSION_NAME
            }} }];
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

            const char *deviceExtensions[] = {
                VK_KHR_SWAPCHAIN_EXTENSION_NAME
            };

            VkDeviceCreateInfo createInfo = {0};
            createInfo.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
            createInfo.pQueueCreateInfos = &queueCreateInfo;
            createInfo.queueCreateInfoCount = 1;
            createInfo.pEnabledFeatures = &deviceFeatures;
            createInfo.enabledLayerCount = 0;
            createInfo.enabledExtensionCount = sizeof(deviceExtensions)/sizeof(deviceExtensions[0]);
            createInfo.ppEnabledExtensionNames = deviceExtensions;

            PFN_vkCreateDevice vkCreateDevice =
                    (PFN_vkCreateDevice) vkGetInstanceProcAddr(instance, "vkCreateDevice");
            if (vkCreateDevice(physicalDevice, &createInfo, NULL, &device) != VK_SUCCESS) {
                fprintf(stderr, "Failed to create Vulkan logical device\n"); exit(1);
            }
        }

        VkSurfaceKHR surface;
        if (!$macos) {
            PFN_vkCreateDisplayPlaneSurfaceKHR vkCreateDisplayPlaneSurfaceKHR =
                (PFN_vkCreateDisplayPlaneSurfaceKHR) vkGetInstanceProcAddr(instance, "vkCreateDisplayPlaneSurfaceKHR");
            VkDisplaySurfaceCreateInfoKHR createInfo = {0};
            createInfo.sType = VK_STRUCTURE_TYPE_DISPLAY_SURFACE_CREATE_INFO_KHR;
            createInfo.displayMode = 0; // TODO: dynamically find out
            createInfo.planeIndex = 0;
            createInfo.imageExtent = (VkExtent2D) { .width = 3840, .height = 2160 }; // TODO: find out
            if (vkCreateDisplayPlaneSurfaceKHR(instance, &createInfo, NULL, &surface) != VK_SUCCESS) {
                fprintf(stderr, "Failed to create Vulkan display plane surface\n"); exit(1);
            }
        } else {
            uint32_t glfwExtensionCount = 0;
            const char** glfwExtensions = glfwGetRequiredInstanceExtensions(&glfwExtensionCount);
            for (int i = 0; i < glfwExtensionCount; i++) {
                printf("require %d: %s\n", i, glfwExtensions[i]);
            }
            
            glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
            GLFWwindow* window = glfwCreateWindow(640, 480, "Window Title", NULL, NULL);
            if (glfwCreateWindowSurface(instance, window, NULL, &surface) != VK_SUCCESS) {
                fprintf(stderr, "Failed to create GLFW window surface\n"); exit(1);
            }
        }

        {
            VkBool32 presentSupport = 0; 
            PFN_vkGetPhysicalDeviceSurfaceSupportKHR vkGetPhysicalDeviceSurfaceSupportKHR =
                (PFN_vkGetPhysicalDeviceSurfaceSupportKHR) vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceSurfaceSupportKHR");
            vkGetPhysicalDeviceSurfaceSupportKHR(physicalDevice, graphicsQueueFamilyIndex, surface, &presentSupport);
            if (!presentSupport) {
                fprintf(stderr, "Vulkan graphics queue family doesn't support presenting to surface\n"); exit(1);
            }
        }

        VkQueue graphicsQueue;
        VkQueue presentQueue; {
            PFN_vkGetDeviceQueue vkGetDeviceQueue =
                (PFN_vkGetDeviceQueue) vkGetInstanceProcAddr(instance, "vkGetDeviceQueue");
            vkGetDeviceQueue(device, graphicsQueueFamilyIndex, 0, &graphicsQueue);
            presentQueue = graphicsQueue;
        }
    }]

    dc compile
}

Display::init
