//
//  MetalFramebufferView.swift
//  HDSimpleNES
//
//  MTKView that displays the NES 256×240 RGBA8 framebuffer. The pipeline is a single fullscreen
//  triangle sampling the source texture with nearest-neighbor filtering — right for pixel art.
//

import MetalKit

final class MetalFramebufferView: MTKView {

    /// Called each draw() to fetch the current framebuffer. Return nil to skip this frame (previous
    /// texture contents are retained). Runs on the main thread.
    var framebufferProvider: (() -> UnsafePointer<UInt32>?)?

    private let textureWidth: Int
    private let textureHeight: Int

    private var srcTexture: MTLTexture?
    private var pipeline: MTLRenderPipelineState?
    private var commandQueue: MTLCommandQueue?
    private var sampler: MTLSamplerState?

    // Runtime-compiled shader — a fullscreen triangle covering UV [0,1]×[0,1].
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut vs_fullscreen(uint vid [[vertex_id]]) {
        // Big triangle trick: three verts covering the whole clip space.
        //   vid 0 → (-1, -1)   vid 1 → (-1, 3)   vid 2 → (3, -1)
        float2 p = float2(vid == 2 ? 3.0 : -1.0, vid == 1 ? 3.0 : -1.0);
        VertexOut o;
        o.position = float4(p, 0, 1);
        // Flip V so the NES framebuffer (top-left origin) maps correctly to Metal's
        // (bottom-left origin) clip space.
        o.uv = float2((p.x + 1.0) * 0.5, 1.0 - (p.y + 1.0) * 0.5);
        return o;
    }

    fragment float4 fs_blit(VertexOut in [[stage_in]],
                            texture2d<float> tex [[texture(0)]],
                            sampler s [[sampler(0)]]) {
        return tex.sample(s, in.uv);
    }
    """

    init(width: Int, height: Int) {
        self.textureWidth = width
        self.textureHeight = height

        let dev = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: dev)

        colorPixelFormat = .rgba8Unorm
        framebufferOnly = true
        isPaused = true                        // We drive draw() manually from CADisplayLink.
        enableSetNeedsDisplay = false
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        autoResizeDrawable = true

        guard let device = dev else { return }
        commandQueue = device.makeCommandQueue()

        // Source texture — 256×240 RGBA8 refreshed every frame from the emulator.
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        td.usage = [.shaderRead]
        td.storageMode = .shared
        srcTexture = device.makeTexture(descriptor: td)

        // Nearest-neighbor: NES pixels should stay crisp when scaled up.
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .nearest
        sd.magFilter = .nearest
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)

        // Runtime-compile the shader so we don't need to add a .metal file to the target.
        do {
            let lib = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let pdesc = MTLRenderPipelineDescriptor()
            pdesc.vertexFunction = lib.makeFunction(name: "vs_fullscreen")
            pdesc.fragmentFunction = lib.makeFunction(name: "fs_blit")
            pdesc.colorAttachments[0].pixelFormat = colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: pdesc)
        } catch {
            NSLog("[HDSimpleNES] Metal pipeline creation failed: %@", error.localizedDescription)
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func draw(_ rect: CGRect) {
        guard
            let texture = srcTexture,
            let pipeline = pipeline,
            let commandQueue = commandQueue,
            let sampler = sampler,
            let drawable = currentDrawable,
            let rpDesc = currentRenderPassDescriptor
        else { return }

        // Upload the framebuffer for this frame (if any). If the provider returns nil we still
        // blit the last-known texture — smoother than flashing black.
        if let pixels = framebufferProvider?() {
            texture.replace(
                region: MTLRegionMake2D(0, 0, textureWidth, textureHeight),
                mipmapLevel: 0,
                withBytes: pixels,
                bytesPerRow: textureWidth * 4
            )
        }

        guard
            let cmdBuffer = commandQueue.makeCommandBuffer(),
            let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: rpDesc)
        else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        cmdBuffer.present(drawable)
        cmdBuffer.commit()
    }
}
