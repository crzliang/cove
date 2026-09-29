import Foundation

/// 应用（普通用户）与特权助手（root）之间的协议。
///
/// 设计取舍：不用 Swift 的 associated value enum 直接编解码，而是一个扁平的
/// 结构体 + `cmd` 判别字段。理由是助手的生命周期独立于 GUI —— 升级 GUI 时
/// 老版本助手可能还在跑，扁平结构更好做向前/向后兼容。
public enum Helper {

    /// 助手的 launchd label，同时用于 plist 文件名
    public static let label = "local.cove.helper"

    /// 助手二进制在系统里的固定位置。
    /// 放在 /Library/PrivilegedHelperTools 而不是 app bundle 内，
    /// 这样 app 被移动或删除时助手仍能正常工作。
    public static let installedPath = "/Library/PrivilegedHelperTools/\(label)"

    /// launchd 配置文件位置
    public static let plistPath = "/Library/LaunchDaemons/\(label).plist"

    /// 控制 socket 所在目录（root 所有，管理员组可访问）
    public static let socketDirectory = "/var/run/local.cove"

    /// 控制 socket
    public static let socketPath = "\(socketDirectory)/helper.sock"

    /// 协议版本。GUI 与助手不一致时提示重新安装助手。
    public static let protocolVersion = 2

    // MARK: - 请求

    public enum Command: String, Codable {
        case ping            // 探活 + 版本协商
        case startKernel     // 以 root 启动 mihomo
        case stopKernel      // 停止内核
        case kernelStatus    // 查询内核是否还活着
        case setSystemProxy  // 开关系统代理
        case stageKernel     // 把用户侧内核副本安装到助手目录（免 osascript）
        case uninstall       // 自我卸载（移除 plist 与二进制）
    }

    public struct Request: Codable, Sendable {
        public var cmd: String
        public var protocolVersion: Int?
        public var config: String?
        public var dataDir: String?
        public var uiDir: String?
        public var logPath: String?
        public var port: Int?
        public var secret: String?
        public var enabled: Bool?
        /// `stageKernel`：用户侧可读的 mihomo 路径（Application Support 或 app bundle）
        public var kernelSource: String?

        public init(cmd: Command) { self.cmd = cmd.rawValue }

        public var command: Command? { Command(rawValue: cmd) }
    }

    // MARK: - 响应

    public struct Response: Codable, Sendable {
        public var ok: Bool
        public var error: String?
        public var pid: Int?
        public var running: Bool?
        public var helperProtocolVersion: Int?
        public var detail: String?

        public init(ok: Bool,
                    error: String? = nil,
                    pid: Int? = nil,
                    running: Bool? = nil,
                    helperProtocolVersion: Int? = nil,
                    detail: String? = nil) {
            self.ok = ok
            self.error = error
            self.pid = pid
            self.running = running
            self.helperProtocolVersion = helperProtocolVersion
            self.detail = detail
        }

        public static func failure(_ message: String) -> Response {
            Response(ok: false, error: message)
        }
    }

    // MARK: - 编解码

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)   // 换行分隔，便于对端按行读取
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        try JSONDecoder().decode(type, from: line)
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case notInstalled
        case connectionFailed(String)
        case helper(String)
        case protocolMismatch(Int)

        public var description: String {
            switch self {
            case .notInstalled:
                return "特权助手未安装"
            case .connectionFailed(let m):
                return "无法连接特权助手：\(m)"
            case .helper(let m):
                return "助手返回错误：\(m)"
            case .protocolMismatch(let v):
                return "助手协议版本不匹配（助手 \(v)，应用 \(protocolVersion)），请重新安装助手"
            }
        }
    }
}
