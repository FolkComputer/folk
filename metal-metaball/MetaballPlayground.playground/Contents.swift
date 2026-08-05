// Metaball Playground — Metal + PS5 DualSense
//
// A full-screen metaball field rendered by a Metal fragment shader, driven by
// a game controller (built for the PS5 DualSense, works with any extended
// gamepad). The five glyphs  △ ○ ▩ ▦ ✖︎  sit along the bottom of the screen
// and light up — and burst a metaball in their color — when their buttons are
// pressed.
//
// Run it either way:
//   1. Open MetaballPlayground.playground in Xcode and press Run.
//   2. From a terminal:  swift Contents.swift
//
// Controls:
//   Left stick     move the big warm metaball
//   Right stick    move the teal buddy metaball
//   R2 / L2        inflate / deflate the big metaball
//   △  (triangle)  light the △ glyph, green burst
//   ○  (circle)    light the ○ glyph, red burst
//   ▩  (square)    light the ▩ glyph, pink burst
//   ▦  (touchpad click; Options button on non-DualSense pads)
//   ✖︎  (cross)     light the ✖︎ glyph, blue burst
//
// The dot in the top-left corner is green when a controller is connected.

import AppKit
import MetalKit
import GameController
import simd

#if canImport(PlaygroundSupport)
import PlaygroundSupport
#endif

// MARK: - Metal shader

let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 resolution;
    float  time;
    float  connected;
    float4 glow0;      // glyph glow: triangle, circle, square, grid
    float  glowCross;  // glyph glow: cross
    int    ballCount;
    float2 pad;
};

struct Ball {
    float4 posRadius;  // xy: position (0..1), z: radius (fraction of min dim), w: strength
    float4 color;
};

vertex float4 vmain(uint vid [[vertex_id]]) {
    float2 v[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    return float4(v[vid], 0.0, 1.0);
}

constant float3 glyphColors[5] = {
    float3(0.25, 0.85, 0.51),   // triangle: green
    float3(0.94, 0.37, 0.34),   // circle: red
    float3(0.95, 0.47, 0.77),   // square: pink
    float3(0.72, 0.76, 0.84),   // grid (touchpad): silver
    float3(0.42, 0.63, 0.96),   // cross: blue
};

fragment float4 fmain(float4 pos [[position]],
                      constant Uniforms& u [[buffer(0)]],
                      constant Ball* balls [[buffer(1)]],
                      texture2d<float> glyphs [[texture(0)]]) {
    constexpr sampler smp(filter::linear);
    float2 p = pos.xy;
    float2 res = u.resolution;
    float minDim = min(res.x, res.y);

    // Background: soft dark vignette.
    float2 q = p / res - 0.5;
    float3 rgb = mix(float3(0.055, 0.060, 0.110), float3(0.015, 0.016, 0.040),
                     clamp(length(q) * 1.6, 0.0, 1.0));

    // Metaball field: classic sum of r^2/d^2, color-weighted by contribution.
    float field = 0.0;
    float3 fieldCol = float3(0.0);
    for (int i = 0; i < u.ballCount; i++) {
        float2 bp = balls[i].posRadius.xy * res;
        float r = balls[i].posRadius.z * minDim;
        float2 d = p - bp;
        float c = balls[i].posRadius.w * (r * r) / (dot(d, d) + 1.0);
        field += c;
        fieldCol += balls[i].color.rgb * c;
    }
    fieldCol /= max(field, 1e-5);
    float body = smoothstep(1.0, 1.12, field);
    float rim = smoothstep(0.68, 1.0, field) * (1.0 - body);
    rgb = mix(rgb, fieldCol, body);
    rgb += fieldCol * rim * 0.5;
    rgb += fieldCol * body * smoothstep(2.0, 6.0, field) * 0.35;

    // Button-glyph strip along the bottom; each cell samples one glyph
    // from the atlas and brightens with its button's glow.
    float cell = min(res.x / 7.0, minDim / 5.0);
    float2 origin = float2((res.x - cell * 5.0) * 0.5, res.y - cell * 1.35);
    float2 local = (p - origin) / cell;
    if (local.x >= 0.0 && local.x < 5.0 && local.y >= 0.0 && local.y < 1.0) {
        int idx = int(floor(local.x));
        float a = glyphs.sample(smp, float2((float(idx) + fract(local.x)) / 5.0, local.y)).a;
        float glow = (idx == 4) ? u.glowCross : u.glow0[min(idx, 3)];
        float3 gcol = glyphColors[idx];
        rgb = mix(rgb, gcol * (0.32 + 0.68 * glow), a);
        rgb += gcol * a * glow * 0.9;
    }

    // Controller status dot, top-left: green when a gamepad is connected.
    float dotR = minDim * 0.010;
    float dd = length(p - float2(dotR * 2.5, dotR * 2.5));
    float da = smoothstep(dotR, dotR * 0.7, dd);
    rgb = mix(rgb, u.connected > 0.5 ? float3(0.30, 0.90, 0.45) : float3(0.45, 0.20, 0.20), da);

    return float4(rgb, 1.0);
}
"""

// MARK: - CPU-side data (layouts match the MSL structs above)

struct Uniforms {
    var resolution: SIMD2<Float> = .init(1, 1)
    var time: Float = 0
    var connected: Float = 0
    var glow0: SIMD4<Float> = .zero
    var glowCross: Float = 0
    var ballCount: Int32 = 0
    var pad: SIMD2<Float> = .zero
}

struct Ball {
    var posRadius: SIMD4<Float>
    var color: SIMD4<Float>
}

struct Burst {
    var pos: SIMD2<Float>
    var color: SIMD3<Float>
    var age: Float
}

// The exact glyphs, in button order: triangle, circle, square, touchpad, cross.
let glyphChars = ["△", "○", "▩", "▦", "✖︎"]

let glyphTints: [SIMD3<Float>] = [
    SIMD3(0.25, 0.85, 0.51),
    SIMD3(0.94, 0.37, 0.34),
    SIMD3(0.95, 0.47, 0.77),
    SIMD3(0.72, 0.76, 0.84),
    SIMD3(0.42, 0.63, 0.96),
]

// MARK: - Glyph atlas: rasterize the five characters into one texture row

func makeGlyphTexture(device: MTLDevice) -> MTLTexture {
    let cell = 128
    let width = cell * 5, height = cell
    let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
        let font = NSFont.systemFont(ofSize: 84, weight: .semibold)
        for (i, g) in glyphChars.enumerated() {
            let s = NSAttributedString(string: g, attributes: [
                .font: font, .foregroundColor: NSColor.white,
            ])
            let sz = s.size()
            s.draw(at: NSPoint(x: CGFloat(i * cell) + (CGFloat(cell) - sz.width) / 2,
                               y: (CGFloat(cell) - sz.height) / 2))
        }
        return true
    }

    var rect = NSRect(x: 0, y: 0, width: width, height: height)
    guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
        fatalError("could not rasterize glyph atlas")
    }
    var data = [UInt8](repeating: 0, count: width * height * 4)
    let ctx = CGContext(data: &data, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                        width: width, height: height,
                                                        mipmapped: false)
    desc.usage = .shaderRead
    let tex = device.makeTexture(descriptor: desc)!
    tex.replaceRegion(MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                      withBytes: data, bytesPerRow: width * 4)
    return tex
}

// MARK: - Renderer

final class Renderer: NSObject, MTKViewDelegate {
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let glyphTexture: MTLTexture

    var viewSize = SIMD2<Float>(820, 520)
    let start = CACurrentMediaTime()
    var last = CACurrentMediaTime()

    var player = SIMD2<Float>(0.50, 0.45)
    var buddy = SIMD2<Float>(0.62, 0.58)
    var glows = [Float](repeating: 0, count: 5)
    var wasPressed = [Bool](repeating: false, count: 5)
    var bursts: [Burst] = []

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        queue = device.makeCommandQueue()!
        let library = try! device.makeLibrary(source: shaderSource, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "vmain")
        desc.fragmentFunction = library.makeFunction(name: "fmain")
        desc.colorAttachments[0].pixelFormat = pixelFormat
        pipeline = try! device.makeRenderPipelineState(descriptor: desc)
        glyphTexture = makeGlyphTexture(device: device)
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewSize = SIMD2<Float>(Float(size.width), Float(size.height))
    }

    // Normalized center of glyph i's cell, so bursts rise out of the glyph.
    func glyphCenter(_ i: Int) -> SIMD2<Float> {
        let cell = min(viewSize.x / 7.0, min(viewSize.x, viewSize.y) / 5.0)
        let originX = (viewSize.x - cell * 5.0) / 2.0
        return SIMD2((originX + (Float(i) + 0.5) * cell) / viewSize.x,
                     (viewSize.y - cell * 1.1) / viewSize.y)
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(now - last, 0.05))
        last = now
        let time = Float(now - start)

        // Poll the first extended gamepad. GC's ABXY map to the DualSense as
        // A=cross, B=circle, X=square, Y=triangle.
        var pressed = [Bool](repeating: false, count: 5)
        var leftStick = SIMD2<Float>.zero
        var rightStick = SIMD2<Float>.zero
        var inflate: Float = 0
        var deflate: Float = 0
        var connected = false
        if let pad = GCController.controllers().first(where: { $0.extendedGamepad != nil })?.extendedGamepad {
            connected = true
            leftStick = SIMD2(pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value)
            rightStick = SIMD2(pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value)
            inflate = pad.rightTrigger.value
            deflate = pad.leftTrigger.value
            pressed[0] = pad.buttonY.isPressed  // triangle
            pressed[1] = pad.buttonB.isPressed  // circle
            pressed[2] = pad.buttonX.isPressed  // square
            pressed[4] = pad.buttonA.isPressed  // cross
            if #available(macOS 11.1, *), let ds = pad as? GCDualSenseGamepad {
                pressed[3] = ds.touchpadButton.isPressed
            } else {
                pressed[3] = pad.buttonOptions?.isPressed ?? false
            }
        }

        // Sticks steer the two player-controlled balls (screen y points down).
        let speed: Float = 0.45
        player += SIMD2(leftStick.x, -leftStick.y) * speed * dt
        buddy += SIMD2(rightStick.x, -rightStick.y) * speed * dt
        player = simd_clamp(player, SIMD2(0.05, 0.05), SIMD2(0.95, 0.95))
        buddy = simd_clamp(buddy, SIMD2(0.05, 0.05), SIMD2(0.95, 0.95))

        // Glyph glows follow the buttons; a rising edge spawns a burst ball
        // in the glyph's color.
        for i in 0..<5 {
            glows[i] = pressed[i] ? 1.0 : max(0.0, glows[i] - dt * 2.5)
            if pressed[i] && !wasPressed[i] {
                bursts.append(Burst(pos: glyphCenter(i), color: glyphTints[i], age: 0))
            }
            wasPressed[i] = pressed[i]
        }
        for i in bursts.indices {
            bursts[i].age += dt
            bursts[i].pos.y -= dt * 0.16
        }
        bursts.removeAll { $0.age > 1.4 }
        if bursts.count > 8 { bursts.removeFirst(bursts.count - 8) }

        // Assemble this frame's balls: four ambient drifters, the two
        // stick-driven balls, then any live bursts.
        var balls: [Ball] = []
        let ambient: [(freq: SIMD2<Float>, phase: Float, radius: Float, color: SIMD3<Float>)] = [
            (SIMD2(0.31, 0.23), 0.0, 0.085, SIMD3(0.35, 0.25, 0.75)),
            (SIMD2(0.17, 0.29), 2.1, 0.075, SIMD3(0.20, 0.45, 0.70)),
            (SIMD2(0.23, 0.37), 4.0, 0.065, SIMD3(0.55, 0.25, 0.65)),
            (SIMD2(0.27, 0.19), 1.2, 0.070, SIMD3(0.25, 0.55, 0.60)),
        ]
        for a in ambient {
            let pos = SIMD2<Float>(0.5 + 0.30 * sinf(time * a.freq.x + a.phase),
                                   0.5 + 0.26 * cosf(time * a.freq.y + a.phase * 1.7))
            balls.append(Ball(posRadius: SIMD4(pos.x, pos.y, a.radius, 1),
                              color: SIMD4(a.color, 1)))
        }
        let playerR: Float = 0.09 * (1 + 0.9 * inflate) / (1 + 0.7 * deflate)
        balls.append(Ball(posRadius: SIMD4(player.x, player.y, playerR, 1),
                          color: SIMD4(0.95, 0.90, 0.75, 1)))
        balls.append(Ball(posRadius: SIMD4(buddy.x, buddy.y, 0.06, 1),
                          color: SIMD4(0.40, 0.85, 0.80, 1)))
        for b in bursts {
            let t = b.age / 1.4
            balls.append(Ball(posRadius: SIMD4(b.pos.x, b.pos.y, 0.03 + 0.08 * t, (1 - t) * (1 - t)),
                              color: SIMD4(b.color, 1)))
        }

        var u = Uniforms()
        u.resolution = viewSize
        u.time = time
        u.connected = connected ? 1 : 0
        u.glow0 = SIMD4(glows[0], glows[1], glows[2], glows[3])
        u.glowCross = glows[4]
        u.ballCount = Int32(balls.count)

        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        balls.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        enc.setFragmentTexture(glyphTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

// MARK: - Controller hookup

if #available(macOS 11.3, *) {
    // Keep receiving input even when the window isn't focused (handy in the
    // playground live view, which runs in a helper process).
    GCController.shouldMonitorBackgroundEvents = true
}
GCController.startWirelessControllerDiscovery(completionHandler: nil)
NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { note in
    let name = (note.object as? GCController)?.vendorName ?? "gamepad"
    print("🎮 connected: \(name)")
}
NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { note in
    let name = (note.object as? GCController)?.vendorName ?? "gamepad"
    print("🎮 disconnected: \(name)")
}
if let existing = GCController.controllers().first {
    print("🎮 already connected: \(existing.vendorName ?? "gamepad")")
} else {
    print("🎮 waiting for a controller… (plug in or pair your DualSense)")
}

// MARK: - View + bootstrap

let device = MTLCreateSystemDefaultDevice()!
let view = MTKView(frame: NSRect(x: 0, y: 0, width: 820, height: 520), device: device)
view.preferredFramesPerSecond = 60
let renderer = Renderer(device: device, pixelFormat: view.colorPixelFormat)
view.delegate = renderer
renderer.mtkView(view, drawableSizeWillChange: view.drawableSize)

#if canImport(PlaygroundSupport)
PlaygroundPage.current.needsIndefiniteExecution = true
PlaygroundPage.current.liveView = view
#else
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: view.frame,
                      styleMask: [.titled, .closable, .miniaturizable, .resizable],
                      backing: .buffered, defer: false)
window.title = "Metaball Playground — △ ○ ▩ ▦ ✖︎"
window.contentView = view
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
#endif
