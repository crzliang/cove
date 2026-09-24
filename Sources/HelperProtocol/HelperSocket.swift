import Foundation
import Darwin

/// unix socket 的收发原语。应用与助手共用，避免两边各写一份读行逻辑。
public enum HelperSocket {

    /// 把路径填进 `sockaddr_un` 并回调，绕开 Swift 处理 C 定长数组的麻烦。
    public static func withAddress(_ path: String,
                                   _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else { return -1 }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// 按字节读到换行。消息都很小且不频繁，没必要上缓冲。
    public static func readLine(_ fd: Int32, limit: Int = 1 << 20) -> Data? {
        var out = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n == 0 { return out.isEmpty ? nil : out }
            if n < 0 {
                if errno == EINTR { continue }
                return out.isEmpty ? nil : out
            }
            if byte == 0x0A { return out }
            out.append(byte)
            if out.count > limit { return nil }
        }
    }

    public static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base.advanced(by: offset), raw.count - offset)
                if n <= 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += n
            }
        }
    }

    /// 连接助手。失败时返回 -1。
    /// 名字不叫 `connect` —— 会和 Darwin 的全局 `connect` 撞名导致递归调用自己。
    public static func openConnection(to path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        let rc = withAddress(path) { Darwin.connect(fd, $0, $1) }
        if rc != 0 {
            close(fd)
            return -1
        }
        return fd
    }

    /// 一问一答。
    public static func call(_ request: Helper.Request) throws -> Helper.Response {
        let fd = openConnection(to: Helper.socketPath)
        guard fd >= 0 else {
            throw Helper.Error.connectionFailed(
                FileManager.default.fileExists(atPath: Helper.socketPath)
                ? "socket 存在但连接被拒绝（助手可能没在运行）"
                : "socket 不存在（助手未安装或未启动）")
        }
        defer { close(fd) }

        writeAll(fd, try Helper.encode(request))
        guard let line = readLine(fd), !line.isEmpty else {
            throw Helper.Error.connectionFailed("助手没有返回响应")
        }
        let response = try Helper.decode(Helper.Response.self, from: line)
        guard response.ok else {
            throw Helper.Error.helper(response.error ?? "未知错误")
        }
        return response
    }
}
