import Foundation
import MacTallyLampCore
import MacTallyLampMCP

// The MCP helper an agent starts, one per agent session. It speaks MCP over stdin and stdout,
// and reaches the running Tally Lamp app over its socket. When the agent ends, stdin closes,
// the helper exits, and the app sees the connection close and lets go of the screen for it.
//
//   mac-tally-lamp-mcp                      # the app's usual data folder
//   mac-tally-lamp-mcp --data-folder <path> # an app started with the same --data-folder

/// Writes whole lines to stdout, one at a time, from any task.
final class StandardOutput: @unchecked Sendable {
    private let lock = NSLock()

    func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

let arguments = CommandLine.arguments
let dataOverride = AppPaths.dataFolderOverride(arguments: arguments)
let socket = AppPaths.socket(in: AppPaths.dataFolder(arguments: arguments))
let folder = FileManager.default.currentDirectoryPath
let identity = AgentIdentity(name: AgentIdentity.name(forFolder: folder), folder: folder, processID: getppid())
let executable = Bundle.main.executableURL ?? URL(filePath: arguments[0])
let app = AppLauncher.containingApp(of: executable)
let version = (app.flatMap { Bundle(url: $0) }?.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "development"

let lamp = LampConnection(socketPath: socket.path, identity: identity, launchApp: {
    guard let app else { return false }
    return AppLauncher.launch(app, arguments: dataOverride.map { [AppPaths.dataFolderArgument, $0.path] } ?? [])
})
let standardOutput = StandardOutput()
let server = MCPServer(lamp: lamp, version: version, output: { standardOutput.write($0) })

for try await line in FileHandle.standardInput.bytes.lines {
    await server.receive(line)
}
// stdin closed: the agent is gone. Exiting closes the socket, which lets go of the screen.
exit(0)
