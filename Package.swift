// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "mac-tally-lamp",
    platforms: [.macOS(.v27)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        // Who has the screen and who waits, the messages between the app and the MCP helper,
        // and the local socket they travel over. No UI. Every rule lives here and is tested.
        .target(name: "MacTallyLampCore"),
        // The MCP server that agents start: JSON-RPC over stdin and stdout, and its three
        // tools. It talks to the running app through the socket. No UI.
        .target(name: "MacTallyLampMCP", dependencies: ["MacTallyLampCore"]),
        // The app: the menu bar item, the lamp, and Settings.
        .executableTarget(
            name: "mac-tally-lamp",
            dependencies: ["MacTallyLampCore", .product(name: "Sparkle", package: "Sparkle")]
        ),
        // The MCP helper. `scripts/bundle.sh` puts it in the app bundle next to the app.
        .executableTarget(name: "mac-tally-lamp-mcp", dependencies: ["MacTallyLampMCP"]),
        .testTarget(name: "MacTallyLampCoreTests", dependencies: ["MacTallyLampCore"]),
        .testTarget(name: "MacTallyLampMCPTests", dependencies: ["MacTallyLampMCP", "MacTallyLampCore"]),
    ]
)
