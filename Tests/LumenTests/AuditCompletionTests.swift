import Foundation
import Testing
import LumenProject
import LumenAudio

@Test func legacyBlendMasksMigrateToPixelation() throws {
    let decoded = try JSONDecoder().decode(MaskMode.self, from: Data("\"blend\"".utf8))
    #expect(decoded == .pixelate)
    #expect(!MaskMode.allCases.map(\.rawValue).contains("blend"))
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(MaskMode.self, from: Data("\"unknown\"".utf8))
    }
}

@Test func denoisingPreservesPartialFrameLengthAndFiniteOutput() {
    let samples = (0..<1001).map { Float(sin(Double($0) * 0.03) * 0.01) }
    let output = RNNoiseDenoiser(strength: 0.5).process(samples)
    #expect(output.count == samples.count)
    #expect(output.allSatisfy { $0.isFinite })
    #expect(RNNoiseDenoiser(strength: 0).process(samples) == samples)
}
