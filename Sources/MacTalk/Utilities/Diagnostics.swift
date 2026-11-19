import Foundation

/// Plain-text diagnostics at ~/Library/Logs/MacTalk/mactalk.log (no tokens or message contents).
enum Diagnostics {
    private static let queue = DispatchQueue(label: "app.mactalk.diagnostics")
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MacTalk")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mactalk.log")
    }()

    static func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
                if (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 > 2_000_000 { try? Data().write(to: url) }
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
