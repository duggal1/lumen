// swift-tools-version: 6.0
import PackageDescription

func lib(_ n: String, _ deps: [String] = [], resources: [Resource]? = nil) -> Target {
    .target(name: n, dependencies: deps.map { .byName(name: $0) }, resources: resources)
}
import Foundation
let moonshineDir = Context.packageDirectory + "/Vendor/moonshine"
let hasMoonshine = FileManager.default.fileExists(atPath: Context.packageDirectory + "/Sources/CMoonshine/include/moonshine-c-api.h")
    && FileManager.default.fileExists(atPath: moonshineDir + "/lib/libmoonshine.dylib")
let all = ["LumenCore", "LumenProject", "LumenDirector", "LumenCapture", "LumenRender", "LumenAudio", "LumenAnalysis", "LumenExport", "LumenSpeech"]

let package = Package(
    name: "Lumen",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Lumen", targets: ["LumenApp"]),
        .executable(name: "lumen-cli", targets: ["LumenCLI"]),
    ],
    dependencies: [.package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")],
    targets: [
        .testTarget(name: "LumenTests", dependencies: ["LumenCapture", "LumenCore", "LumenProject", "LumenDirector", "LumenRender", "LumenAudio", "LumenAnalysis", "LumenExport", "LumenUI", "LumenSpeech"], resources: [.copy("Fixtures")] ),
        lib("LumenCore"),
        lib("LumenProject", ["LumenCore"]),
        lib("LumenDirector", ["LumenCore", "LumenProject"]),
        lib("LumenAnalysis", ["LumenCore", "LumenProject"]),
        lib("LumenCapture", ["LumenCore", "LumenProject", "LumenDirector"]),
        lib("LumenRender", ["LumenCore", "LumenProject", "LumenDirector"], resources: [.process("Shaders")]),
        .target(name: "CRNNoise", path: "Sources/CRNNoise", publicHeadersPath: "include"),
        lib("LumenAudio", ["LumenCore", "LumenProject", "LumenDirector", "CRNNoise"]),
        .target(name: "CMoonshine", path: "Sources/CMoonshine", publicHeadersPath: "include",
                linkerSettings: [.unsafeFlags(["-L\(moonshineDir)/lib",
                                               "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                               "-Xlinker", "-rpath", "-Xlinker", "\(moonshineDir)/lib"]),
                                 .linkedLibrary("moonshine")]),
        lib("LumenSpeech", ["LumenCore", "LumenProject", "LumenAudio", "CMoonshine"]),
        lib("LumenExport", ["LumenCore", "LumenProject", "LumenDirector", "LumenAnalysis", "LumenRender", "LumenAudio"]),
        lib("LumenUI", all),
        .executableTarget(name: "LumenApp", dependencies: ["LumenUI"]),
        .executableTarget(name: "LumenCLI", dependencies: [
            "LumenProject", "LumenDirector", "LumenRender", "LumenAudio", "LumenExport", "LumenSpeech",
            .product(name: "ArgumentParser", package: "swift-argument-parser")]),
    ]
)
