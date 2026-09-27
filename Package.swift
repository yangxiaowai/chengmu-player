// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Cinema",
    platforms: [.macOS("15.0")],
    products: [.library(name: "CinemaCore", targets: ["CinemaCore"]), .executable(name: "Cinema", targets: ["CinemaApp"])],
    targets: [
        .target(name: "CinemaCore"),
        .executableTarget(name: "CinemaApp", dependencies: ["CinemaCore"]),
        .testTarget(name: "CinemaCoreTests", dependencies: ["CinemaCore"])
    ],
    swiftLanguageVersions: [.v5]
)
