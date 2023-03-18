use vulkano::instance::{Instance, InstanceExtensions};
use vulkano_win::VkSurfaceBuild;
use winit::event_loop::EventLoop;
use winit::window::WindowBuilder;

fn main() {
    // Create a new Vulkan instance
    let instance = Instance::new(None, &InstanceExtensions::none(), None)
        .expect("failed to create Vulkan instance");

    // Create an event loop and window
    let event_loop = EventLoop::new();
    let window = WindowBuilder::new()
        .build_vk_surface(&event_loop, instance.clone())
        .unwrap();

    // ...
}
