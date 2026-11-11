// swift-tools-version: 6.2
import PackageDescription

// Отдельный локальный пакет: переводы доступны приложению без сетевых зависимостей.
let package = Package(
    name: "PlannerLocalization",
    defaultLocalization: "ru",
    platforms: [.macOS(.v26)],
    products: [.library(name: "PlannerLocalization", targets: ["PlannerLocalization"])],
    targets: [
        .target(name: "PlannerLocalization", resources: [.process("Resources")]),
        .testTarget(name: "PlannerLocalizationTests", dependencies: ["PlannerLocalization"])
    ]
)
