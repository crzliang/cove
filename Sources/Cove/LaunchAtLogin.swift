import Foundation
import ServiceManagement

/// 开机自启。
///
/// 用 macOS 13+ 的 `SMAppService.mainApp`：注册的是「本 app 自身」，
/// 不需要额外写 plist、不需要 helper、不需要额外签名配置。
///
/// 注意：只有在真正的 `.app` bundle 里才能注册。开发时用 `swift run`
/// 或直接跑 `.build/debug/Cove` 会失败（没有 bundle identifier），
/// 所以 `isAvailable` 要先判断一下，UI 据此禁用该开关。
enum LaunchAtLogin {

    static var isAvailable: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 当前状态的可读描述，用于在 UI 上解释为什么开关是灰的
    static var statusDescription: String {
        guard isAvailable else { return "需以 .app 方式运行（用 scripts/bundle.sh 打包后可用）" }
        switch SMAppService.mainApp.status {
        case .enabled:          return "已启用"
        case .notRegistered:    return "未启用"
        case .notFound:         return "系统未找到该应用，请先移动到 /Applications"
        case .requiresApproval: return "等待系统设置中批准（系统设置 → 通用 → 登录项）"
        @unknown default:       return "未知状态"
        }
    }

    static func set(_ enabled: Bool) throws {
        guard isAvailable else { throw LaunchAtLoginError.notBundled }
        if enabled {
            // 已在别处注册过会抛错，先解注册保证幂等
            try? SMAppService.mainApp.unregister()
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

enum LaunchAtLoginError: Error, CustomStringConvertible {
    case notBundled

    var description: String {
        switch self {
        case .notBundled:
            return "开机自启需要在 .app 中运行。请先执行 scripts/bundle.sh 并打开 build/Cove.app"
        }
    }
}
