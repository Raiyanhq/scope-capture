// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SCOPECaptureCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "SCOPECaptureCore", targets: ["SCOPECaptureCore"])],
    targets: [
        .target(name: "SCOPECaptureCore", path: "Sources/Core"),
        .testTarget(name: "SCOPECaptureCoreTests", dependencies: ["SCOPECaptureCore"], path: "Tests")
    ]
)
