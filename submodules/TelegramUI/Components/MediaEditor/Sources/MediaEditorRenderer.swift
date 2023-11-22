import Foundation
import UIKit
import Metal
import MetalKit
import Photos
import SwiftSignalKit

final class VideoPixelBuffer {
    let pixelBuffer: CVPixelBuffer
    let rotation: TextureRotation
    let timestamp: CMTime
    
    init(
        pixelBuffer: CVPixelBuffer,
        rotation: TextureRotation,
        timestamp: CMTime
    ) {
        self.pixelBuffer = pixelBuffer
        self.rotation = rotation
        self.timestamp = timestamp
    }
}

final class RenderingContext {
    let device: MTLDevice
    let commandBuffer: MTLCommandBuffer
    
    init(
        device: MTLDevice,
        commandBuffer: MTLCommandBuffer
    ) {
        self.device = device
        self.commandBuffer = commandBuffer
    }
}

protocol RenderPass: AnyObject {
    func setup(device: MTLDevice, library: MTLLibrary)
    func process(input: MTLTexture, device: MTLDevice, commandBuffer: MTLCommandBuffer) -> MTLTexture?
}

protocol TextureSource {
    func connect(to renderer: MediaEditorRenderer)
    func invalidate()
}

protocol RenderTarget: AnyObject {
    var mtlDevice: MTLDevice? { get }
    
    var drawableSize: CGSize { get }
    var colorPixelFormat: MTLPixelFormat { get }
    var drawable: MTLDrawable? { get }
    var renderPassDescriptor: MTLRenderPassDescriptor? { get }
    
    func redraw()
}

final class MediaEditorRenderer {
    var textureSource: TextureSource? {
        didSet {
            self.textureSource?.connect(to: self)
        }
    }
    
    private var semaphore = DispatchSemaphore(value: 3)
    private var renderPasses: [RenderPass] = []
    
    private let mainVideoInputPass = VideoInputPass()
    private let additionalVideoInputPass = VideoInputPass()
    let videoFinishPass = VideoFinishPass()
    
    private let outputRenderPass = OutputRenderPass()
    private weak var renderTarget: RenderTarget? {
        didSet {
            self.outputRenderPass.renderTarget = self.renderTarget
        }
    }

    private var device: MTLDevice?
    private var library: MTLLibrary?
    private var commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    
    enum Input {
        case texture(MTLTexture, CMTime)
        case videoBuffer(VideoPixelBuffer)
        
        var timestamp: CMTime {
            switch self {
            case let .texture(_, timestamp):
                return timestamp
            case let .videoBuffer(videoBuffer):
                return videoBuffer.timestamp
            }
        }
    }
    
    private var currentMainInput: Input?
    private var currentAdditionalInput: Input?
    
//    private var currentTexture: MTLTexture?
//    private var currentAdditionalTexture: MTLTexture?
//    private var currentTime: CMTime = .zero
//    
//    private var currentPixelBuffer: VideoPixelBuffer?
//    private var currentAdditionalPixelBuffer: VideoPixelBuffer?
    
    public var onNextRender: (() -> Void)?
    
    var resultTexture: MTLTexture?
        
    public init() {
        
    }
    
    deinit {
        for _ in 0 ..< 3 {
            self.semaphore.signal()
        }
    }
    
    func addRenderPass(_ renderPass: RenderPass) {
        self.renderPasses.append(renderPass)
        if let device = self.renderTarget?.mtlDevice, let library = self.library {
            renderPass.setup(device: device, library: library)
        }
    }
    
    func addRenderChain(_ renderChain: MediaEditorRenderChain) {
        for renderPass in renderChain.renderPasses {
            self.addRenderPass(renderPass)
        }
    }
    
    private func setup() {
        guard let device = self.renderTarget?.mtlDevice else {
            return
        }
        
        CVMetalTextureCacheCreate(nil, nil, device, nil, &self.textureCache)
        
        let mainBundle = Bundle(for: MediaEditorRenderer.self)
        guard let path = mainBundle.path(forResource: "MediaEditorBundle", ofType: "bundle") else {
            return
        }
        guard let bundle = Bundle(path: path) else {
            return
        }
        
        guard let library = try? device.makeDefaultLibrary(bundle: bundle) else {
            return
        }
        self.library = library
        
        self.commandQueue = device.makeCommandQueue()
        self.commandQueue?.label = "Media Editor Command Queue"
        self.mainVideoInputPass.setup(device: device, library: library)
        self.additionalVideoInputPass.setup(device: device, library: library)
        self.videoFinishPass.setup(device: device, library: library)
        self.renderPasses.forEach { $0.setup(device: device, library: library) }
        self.outputRenderPass.setup(device: device, library: library)
    }
    
    func setupForComposer(composer: MediaEditorComposer) {
        guard let device = composer.device else {
            return
        }
        self.device = device
        CVMetalTextureCacheCreate(nil, nil, device, nil, &self.textureCache)
        
        let mainBundle = Bundle(for: MediaEditorRenderer.self)
        guard let path = mainBundle.path(forResource: "MediaEditorBundle", ofType: "bundle") else {
            return
        }
        guard let bundle = Bundle(path: path) else {
            return
        }
        
        guard let library = try? device.makeDefaultLibrary(bundle: bundle) else {
            return
        }
        self.library = library
        
        self.commandQueue = device.makeCommandQueue()
        self.commandQueue?.label = "Media Editor Command Queue"
        self.mainVideoInputPass.setup(device: device, library: library)
        self.additionalVideoInputPass.setup(device: device, library: library)
        self.videoFinishPass.setup(device: device, library: library)
        self.renderPasses.forEach { $0.setup(device: device, library: library) }
    }
    
    public var displayEnabled = true
    var skipEditingPasses = true
    var needsDisplay = false
        
    private func combinedTextureFromCurrentInputs(device: MTLDevice, commandBuffer: MTLCommandBuffer, textureCache: CVMetalTextureCache) -> MTLTexture? {
        var mainTexture: MTLTexture?
        var additionalTexture: MTLTexture?
        
        func textureFromInput(_ input: MediaEditorRenderer.Input, videoInputPass: VideoInputPass) -> MTLTexture? {
            switch input {
            case let .texture(texture, _):
                return texture
            case let .videoBuffer(videoBuffer):
                return videoInputPass.processPixelBuffer(videoBuffer, textureCache: textureCache, device: device, commandBuffer: commandBuffer)
            }
        }
        
        guard let mainInput = self.currentMainInput else {
            return nil
        }
        
        mainTexture = textureFromInput(mainInput, videoInputPass: self.mainVideoInputPass)
        if let additionalInput = self.currentAdditionalInput {
            additionalTexture = textureFromInput(additionalInput, videoInputPass: self.additionalVideoInputPass)
        }
        
        if let mainTexture, let additionalTexture {
            if let result = self.videoFinishPass.process(input: mainTexture, secondInput: additionalTexture, timestamp: mainInput.timestamp, device: device, commandBuffer: commandBuffer) {
                return result
            } else {
                return mainTexture
            }
        } else {
            return mainTexture
        }
    }
    
    func renderFrame() {
        let device: MTLDevice?
        if let renderTarget = self.renderTarget {
            device = renderTarget.mtlDevice
        } else if let currentDevice = self.device {
            device = currentDevice
        } else {
            device = nil
        }
        guard let device = device,
              let commandQueue = self.commandQueue,
              let textureCache = self.textureCache,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              var texture = self.combinedTextureFromCurrentInputs(device: device, commandBuffer: commandBuffer, textureCache: textureCache)
        else {
            self.didRenderFrame()
            return
        }

        if !self.skipEditingPasses {
            for renderPass in self.renderPasses {
                if let nextTexture = renderPass.process(input: texture, device: device, commandBuffer: commandBuffer) {
                    texture = nextTexture
                }
            }
        }
        self.resultTexture = texture
        
        if self.renderTarget == nil {
            commandBuffer.addCompletedHandler { [weak self] _ in
                if let self {
                    self.didRenderFrame()
                }
            }
        }
        commandBuffer.commit()
        
        if let renderTarget = self.renderTarget, self.displayEnabled {
            if self.needsDisplay {
                self.didRenderFrame()
            } else {
                self.needsDisplay = true
                renderTarget.redraw()
            }
        } else {
            commandBuffer.waitUntilCompleted()
        }
    }
    
    func displayFrame() {
        guard let renderTarget = self.renderTarget,
              let device = renderTarget.mtlDevice,
              let commandQueue = self.commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let texture = self.resultTexture
        else {
            self.needsDisplay = false
            self.didRenderFrame()
            return
        }
        commandBuffer.addCompletedHandler { [weak self] _ in
            if let self {
                self.didRenderFrame()
                
                if let onNextRender = self.onNextRender {
                    self.onNextRender = nil
                    Queue.mainQueue().after(0.016) {
                        onNextRender()
                    }
                }
            }
        }
        
        self.outputRenderPass.process(input: texture, device: device, commandBuffer: commandBuffer)
        
        commandBuffer.commit()
        self.needsDisplay = false
    }
    
    func willRenderFrame() {
        let timeout = self.renderTarget != nil ? DispatchTime.now() + 0.1 : .distantFuture
        let _ = self.semaphore.wait(timeout: timeout)
    }
    
    func didRenderFrame() {
        self.semaphore.signal()
    }
    
    func consume(
        main: MediaEditorRenderer.Input,
        additional: MediaEditorRenderer.Input?,
        render: Bool,
        displayEnabled: Bool = true
    ) {
        self.displayEnabled = displayEnabled
        
        if render {
            self.willRenderFrame()
        }
        
        self.currentMainInput = main
        self.currentAdditionalInput = additional
        
        if render {
            self.renderFrame()
        }
    }
    
//    func consumeTexture(_ texture: MTLTexture, render: Bool) {
//        if render {
//            self.willRenderFrame()
//        }
//        
//        self.currentTexture = texture
//        if render {
//            self.renderFrame()
//        }
//    }
//    
//    func consumeTexture(_ texture: MTLTexture, additionalTexture: MTLTexture?, time: CMTime, render: Bool) {
//        self.displayEnabled = false
//        
//        if render {
//            self.willRenderFrame()
//        }
//        
//        self.currentTexture = texture
//        self.currentAdditionalTexture = additionalTexture
//        self.currentTime = time
//        if render {
//            self.renderFrame()
//        }
//    }
//    
//    var previousPresentationTimestamp: CMTime?
//    func consumeVideoPixelBuffer(pixelBuffer: VideoPixelBuffer, additionalPixelBuffer: VideoPixelBuffer?, render: Bool) {
//        self.willRenderFrame()
//        
//        self.currentPixelBuffer = pixelBuffer
//        if additionalPixelBuffer == nil && self.currentAdditionalPixelBuffer != nil {
//        } else {
//            self.currentAdditionalPixelBuffer = additionalPixelBuffer
//        }
//        if render {
//            if self.previousPresentationTimestamp == pixelBuffer.timestamp {
//                self.didRenderFrame()
//            } else {
//                self.renderFrame()
//            }
//        }
//        self.previousPresentationTimestamp = pixelBuffer.timestamp
//    }
    
    func renderTargetDidChange(_ target: RenderTarget?) {
        self.renderTarget = target
        self.setup()
    }
    
    func renderTargetDrawableSizeDidChange(_ size: CGSize) {
        self.renderTarget?.redraw()
    }
    
    func finalRenderedImage(mirror: Bool = false) -> UIImage? {
        if let finalTexture = self.resultTexture, let device = self.renderTarget?.mtlDevice {
            return getTextureImage(device: device, texture: finalTexture, mirror: mirror)
        } else {
            return nil
        }
    }
}
