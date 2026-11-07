import Metal
import Foundation

public enum FXError: Error {
    case noDevice, noEncoder, noTexture, noPipeline(String), library(String)
}

/// Owns the Metal device and compiled kernel library for the FX pipeline.
public final class FXKernels {
    public let device: MTLDevice
    private let library: MTLLibrary
    // SwiftPM copies .metal shader resources instead of compiling them into
    // default.metallib. Load supplementary kernels when first requested.
    private let pipelineLock = NSLock()
    private var extraLibraries: [String: MTLLibrary] = [:]
    private var pipelines: [String: MTLComputePipelineState] = [:]

    public init(device: MTLDevice) throws {
        self.device = device
        if let lib = try? device.makeDefaultLibrary(bundle: .module) {
            library = lib
        } else if let url = Bundle.module.url(forResource: "Shaders", withExtension: "metal"),
                  let source = try? String(contentsOf: url, encoding: .utf8) {
            library = try device.makeLibrary(source: source, options: nil)
        } else {
            throw FXError.library("Missing default.metallib and Shaders.metal")
        }
    }

    public func pipeline(_ name: String) throws -> MTLComputePipelineState {
        try pipelineLock.withLock {
            if let existing = pipelines[name] { return existing }

            var function = library.makeFunction(name: name)
            if function == nil {
                // Only compile each Metal source once; cache the pipeline state
                // as well so the 60fps render loop never recompiles shaders.
                let sources = name.hasPrefix("up_") ? ["Upscale"] : ["Content", "Upscale"]
                for source in sources {
                    let lib: MTLLibrary
                    if let existing = extraLibraries[source] {
                        lib = existing
                    } else {
                        guard let url = Bundle.module.url(forResource: source, withExtension: "metal"),
                              let text = try? String(contentsOf: url, encoding: .utf8) else {
                            throw FXError.library("Missing \(source).metal resource")
                        }
                        lib = try device.makeLibrary(source: text, options: nil)
                        extraLibraries[source] = lib
                    }
                    if let found = lib.makeFunction(name: name) {
                        function = found
                        break
                    }
                }
            }

            guard let function else { throw FXError.noPipeline(name) }
            let state = try device.makeComputePipelineState(function: function)
            pipelines[name] = state
            return state
        }
    }

    public func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState,
                         width: Int, height: Int) {
        encoder.setComputePipelineState(pipeline)
        let tg = MTLSize(width: min(16, pipeline.threadExecutionWidth),
                        height: min(16, max(1, pipeline.maxTotalThreadsPerThreadgroup / max(1, pipeline.threadExecutionWidth))),
                        depth: 1)
        let grid = MTLSize(width: width, height: height, depth: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: tg)
    }
}
