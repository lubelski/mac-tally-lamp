import Foundation

/// Where the app keeps what it needs at run time, and where the MCP helper finds the app.
public enum AppPaths {
    public static let folderName = "mac-tally-lamp"
    public static let bundleIdentifier = "dev.lubelski.mac-tally-lamp"
    /// The helper's file name, next to the app's binary in `Contents/MacOS`.
    public static let helperName = "mac-tally-lamp-mcp"
    public static let dataFolderArgument = "--data-folder"

    /// `~/Library/Application Support/mac-tally-lamp/`, or the folder after `--data-folder`.
    public static func dataFolder(arguments: [String] = CommandLine.arguments) -> URL {
        if let folder = dataFolderOverride(arguments: arguments) { return folder }
        return URL.applicationSupportDirectory.appending(path: folderName, directoryHint: .isDirectory)
    }

    public static func dataFolderOverride(arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: dataFolderArgument), index + 1 < arguments.count else { return nil }
        return URL(filePath: (arguments[index + 1] as NSString).expandingTildeInPath, directoryHint: .isDirectory)
    }

    /// The socket the app listens on and the helper connects to.
    public static func socket(in dataFolder: URL) -> URL {
        dataFolder.appending(path: "lamp.sock", directoryHint: .notDirectory)
    }
}
