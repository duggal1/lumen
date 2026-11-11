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
