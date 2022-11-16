source "lib/c.tcl"

namespace eval Display {
    c include <vulkan/vulkan.h>
    c include <stdlib.h>
    c include <dlfcn.h>

    c proc init {} void {
        void *vulkanLibrary = dlopen("libvulkan.so.1", RTLD_NOW);
        PFN_vkGetInstanceProcAddr vkGetInstanceProcAddr = (PFN_vkGetInstanceProcAddr) dlsym(vulkanLibrary, "vkGetInstanceProcAddr");
        PFN_vkCreateInstance vkCreateInstance = (PFN_vkCreateInstance) vkGetInstanceProcAddr(NULL, "vkCreateInstance");

        VkInstance instance;
        VkInstanceCreateInfo createInfo = {0};
        createInfo.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        createInfo.enabledLayerCount = 0;
        if (vkCreateInstance(&createInfo, NULL, &instance) != VK_SUCCESS) {
            exit(1);
        }

        

//        uint32_t display_count = 0;
//        vkGetPhysicalDeviceDisplayPropertiesKHR(vc->physical_device,
//                                                &display_count, NULL);
    }

    c compile
}

Display::init
