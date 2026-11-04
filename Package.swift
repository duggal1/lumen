// swift-tools-version: 6.0
import PackageDescription

func lib(_ n: String, _ deps: [String] = [], resources: [Resource]? = nil) -> Target {
    .target(name: n, dependencies: deps.map { .byName(name: $0) }, resources: resources)
}
let all = ["LumenCore", "LumenProject", "LumenDirector", "LumenCapture", "LumenRender", "LumenAudio", "LumenExport"]

let package = Package(
    name: "Lumen",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Lumen", targets: ["LumenApp"]),
        .executable(name: "lumen-cli", targets: ["LumenCLI"]),
    ],
    dependencies: [.package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")],
    targets: [
        .testTarget(name: "LumenTests", dependencies: ["LumenCapture", "LumenCore", "LumenProject", "LumenDirector", "LumenRender", "LumenAudio", "LumenExport"]),
        lib("LumenCore"),
        lib("LumenProject", ["LumenCore"]),
        lib("LumenDirector", ["LumenCore", "LumenProject"]),
        lib("LumenCapture", ["LumenCore", "LumenProject"]),
        lib("LumenRender", ["LumenCore", "LumenProject", "LumenDirector"], resources: [.process("Shaders")]),
        lib("LumenAudio", ["LumenCore", "LumenProject", "LumenDirector"]),
        lib("LumenExport", ["LumenCore", "LumenProject", "LumenDirector", "LumenRender", "LumenAudio"]),
        lib("LumenUI", all),
        .executableTarget(name: "LumenApp", dependencies: ["LumenUI"]),
        .executableTarget(name: "LumenCLI", dependencies: [
            "LumenProject", "LumenDirector", "LumenRender", "LumenAudio", "LumenExport",
            .product(name: "ArgumentParser", package: "swift-argument-parser")]),
    ]
)