// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PersonalAlbum",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "PersonalAlbum", targets: ["PersonalAlbum"])
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3"
        ),
        .executableTarget(
            name: "PersonalAlbum",
            dependencies: ["CSQLite"]
        ),
        .testTarget(
            name: "PersonalAlbumTests",
            dependencies: ["PersonalAlbum"]
        )
    ],
    swiftLanguageModes: [.v5]
)
