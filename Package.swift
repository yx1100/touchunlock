// swift-tools-version: 6.0
import Foundation
import PackageDescription

/// 链接器参数里的相对路径按调用目录解析，这里推成绝对路径，
/// 免得从别的目录（例如 Xcode）构建时找不到要内嵌的 Info.plist。
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "TouchUnlock",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DurianCore", targets: ["DurianCore"]),
    ],
    targets: [
        .target(name: "DurianCore"),
        // 命令行真机探测工具。内嵌 Info.plist 以便 CoreBluetooth 弹出蓝牙授权。
        .executableTarget(
            name: "touchprobe",
            dependencies: ["DurianCore"],
            exclude: ["Info.plist"],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist", "-Xlinker", "\(packageRoot)/Sources/touchprobe/Info.plist",
            ])]
        ),
        .testTarget(name: "DurianCoreTests", dependencies: ["DurianCore"]),
    ],
    swiftLanguageModes: [.v5]
)
