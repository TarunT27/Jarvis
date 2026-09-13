// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "Jarvis", platforms: [.macOS(.v26)], products: [
    .executable(name: "Jarvis", targets: ["JarvisApp"]),
    .executable(name: "JarvisBroker", targets: ["JarvisBroker"])
], targets: [
    .systemLibrary(name: "CSQLite"),
    .target(name: "JarvisCore", dependencies: ["CSQLite"]),
    .executableTarget(name: "JarvisApp", dependencies: ["JarvisCore"]),
    .executableTarget(name: "JarvisBroker", dependencies: ["JarvisCore"]),
    .testTarget(name: "JarvisCoreTests", dependencies: ["JarvisCore"])
], swiftLanguageModes: [.v5])
