import Foundation
import Darwin

public enum SocketPath {
    public static var path: String {
        if let env = ProcessInfo.processInfo.environment["CODEDOCK_SOCKET_PATH"] {
            return env
        }
        return "/tmp/codedock-\(getuid()).sock"
    }
}
