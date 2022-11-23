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

        proc vkfn {fn {instance instance}} {
            csubst {PFN_$fn $fn = (PFN_$fn) glfwGetInstanceProcAddress($instance, "$fn");}
        }
    } else {
        proc vkfn {fn {instance instance}} {
            csubst {PFN_$fn $fn = (PFN_$fn) vkGetInstanceProcAddr($instance, "$fn");}
        }
    }

    proc vktry {call} { csubst {
        VkResult res = $call;
        if (res != VK_SUCCESS) {
            fprintf(stderr, "Failed $call: %d\n", res); exit(1);
        }
    } }

    dc proc init {} void [csubst {
        PFN_vkGetInstanceProcAddr vkGetInstanceProcAddr;
        if ($macos) { glfwInit(); }
        else {
            void *vulkanLibrary = dlopen("libvulkan.so.1", RTLD_NOW);
            if (vulkanLibrary == NULL) {
                fprintf(stderr, "Failed to load libvulkan: %s\n", dlerror()); exit(1);
            }
            vkGetInstanceProcAddr = (PFN_vkGetInstanceProcAddr) dlsym(vulkanLibrary, "vkGetInstanceProcAddr");
        }

        VkInstance instance; {
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

        VkPhysicalDevice physicalDevice; {
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

        
        uint32_t graphicsQueueFamilyIndex = UINT32_MAX; {
            $[vkfn vkGetPhysicalDeviceQueueFamilyProperties]

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
        for (int i = 0; i < propertyCount; i++) {
            printf("Layer %d: %s\n", i, layerProperties[i].layerName);
        }

        VkSurfaceKHR surface;
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
            GLFWwindow* window = glfwCreateWindow(640, 480, "Window Title", NULL, NULL);
            if (glfwCreateWindowSurface(instance, window, NULL, &surface) != VK_SUCCESS) {
                fprintf(stderr, "Failed to create GLFW window surface\n"); exit(1);
            }
        }

        {
            VkBool32 presentSupport = 0; 
            $[vkfn vkGetPhysicalDeviceSurfaceSupportKHR]
            vkGetPhysicalDeviceSurfaceSupportKHR(physicalDevice, graphicsQueueFamilyIndex, surface, &presentSupport);
            if (!presentSupport) {
                fprintf(stderr, "Vulkan graphics queue family doesn't support presenting to surface\n"); exit(1);
            }
        }

        VkQueue graphicsQueue;
        VkQueue presentQueue; {
            $[vkfn vkGetDeviceQueue]
            vkGetDeviceQueue(device, graphicsQueueFamilyIndex, 0, &graphicsQueue);
            presentQueue = graphicsQueue;
        }
    }]

    dc compile
}

Display::init
