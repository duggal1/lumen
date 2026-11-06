import Metal
import Foundation

public enum FXError: Error {
    case noDevice, noEncoder, noTexture, noPipeline(String), library(String)
}

/// Owns the Metal device and compiled kernel library for the FX pipeline.
public final class FXKernels {
    public let device: MTLDevice
    private let library: MTLLibrary

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
        guard let fn = library.makeFunction(name: name) else { throw FXError.noPipeline(name) }
        return try device.makeComputePipelineState(function: fn)
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
