import Foundation

/// Who an agent session is, as its MCP helper reports it when it connects.
public struct AgentIdentity: Codable, Sendable, Equatable {
    /// The name the lamp and the menu show, such as `mac-os-agent (wt-03)`. By default it comes
    /// from the session's working folder. An agent can give another with `request_screen`.
    public var name: String
    /// The MCP client's own name and version from `initialize`, such as `claude-code 2.1.0`.
    public var client: String?
    /// The session's working folder.
    public var folder: String?
    /// The agent's process: the parent of the MCP helper.
    public var processID: Int32?

    public init(name: String, client: String? = nil, folder: String? = nil, processID: Int32? = nil) {
        self.name = name
        self.client = client
        self.folder = folder
        self.processID = processID
    }

    /// The name for a session that has not said who it is yet.
    public static let unnamed = "agent"

    /// A short name for a session working in `folder`: the project folder's name, and the
    /// worktree's name after it when the folder is a worktree inside the project.
    ///
    /// - `~/dev/mac-os-agent` is `mac-os-agent`.
    /// - `~/dev/mac-os-agent/.wt/wt-03` is `mac-os-agent (wt-03)`.
    /// - `~/dev/tau/.claude/worktrees/fix-x` is `tau (fix-x)`.
    public static func name(forFolder folder: String?) -> String {
        guard let folder, !folder.isEmpty else { return unnamed }
        let parts = URL(filePath: folder).standardizedFileURL.pathComponents.filter { $0 != "/" }
        guard let last = parts.last else { return unnamed }

        // A worktree folder `<repo>/.wt/<name>/…` or `<repo>/.claude/worktrees/<name>/…`.
        for (marker, depth) in [([".wt"], 1), ([".claude", "worktrees"], 2)] {
            guard let start = firstIndex(of: marker, in: parts), start > 0, start + depth < parts.count else { continue }
            let repo = parts[start - 1]
            let worktree = parts[start + depth]
            return "\(repo) (\(worktree))"
        }
        return last
    }

    private static func firstIndex(of marker: [String], in parts: [String]) -> Int? {
        guard parts.count >= marker.count else { return nil }
        for index in 0...(parts.count - marker.count) where Array(parts[index..<index + marker.count]) == marker {
            return index
        }
        return nil
    }
}
