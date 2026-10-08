// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CodelightPro",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CodelightPro",
            path: "Sources/CodelightPro",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
