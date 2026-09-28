import Darwin
import Foundation

/// Keep the descriptor open for the daemon's lifetime. Do not unlink the file:
/// another process must always lock the same inode, including after a crash.
final class SingleInstanceLock {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Inverso/daemon.lock")
    }

    enum LockError: Error, CustomStringConvertible {
        case alreadyRunning
        case system(operation: String, code: Int32)

        var description: String {
            switch self {
            case .alreadyRunning:
                return "another inverso daemon is already running for this user"
            case let .system(operation, code):
                return "could not \(operation) daemon lock: \(String(cString: strerror(code)))"
            }
        }
    }

    private let descriptor: Int32

    /// With waitIfHeld, a held lock is reported once and then waited for. Under
    /// launchd, exiting instead would relaunch this daemon every ten seconds.
    init(url: URL, waitIfHeld: Bool = false, onWait: () -> Void = {}) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw LockError.system(operation: "open", code: errno) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            var code = errno
            if code == EWOULDBLOCK && waitIfHeld {
                onWait()
                // SIGTERM from launchctl still ends a waiting process.
                repeat {
                    code = flock(fd, LOCK_EX) == 0 ? 0 : errno
                } while code == EINTR
            }
            if code != 0 {
                close(fd)
                if code == EWOULDBLOCK { throw LockError.alreadyRunning }
                throw LockError.system(operation: "acquire", code: code)
            }
        }
        descriptor = fd
    }

    deinit {
        close(descriptor)
    }
}
