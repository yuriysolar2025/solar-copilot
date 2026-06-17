// swift-tools-version:5.9
import PackageDescription

// SolarCopilot — нативный macOS menubar-копилот (Фаза 1: каркас + аудио → whisper).
// Сборка: ./build.sh  (swift build + упаковка в .app). Полный Xcode не нужен.
let package = Package(
    name: "SolarCopilot",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SolarCopilot",
            path: "Sources/SolarCopilot"
        )
    ]
)
