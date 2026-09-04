import Foundation

/// Central registry for every `UserDefaults` key and `UsageStore.meta` key.
/// String values are frozen: renaming a value orphans existing installs.
enum PrefKeys {
    static let period = "period"
    static let mode = "mode"
    static let widgetScale = "widget_scale"
    static let quotaDisplay = "quota_display"
    static let animationFPS = "animation_fps"
    static let waitThreshold = "wait_threshold"
    static let cursorActiveInterval = "cursor_active_interval"
    static let diagEnabled = "diag_enabled"
    /// USD per 1M tokens used to estimate codex cost when the source
    /// reports none. 0 (default) = off, show no estimate.
    static let priceInputPer1M = "price_input_per_1m"
    static let priceOutputPer1M = "price_output_per_1m"
    /// Default off. When on, posts a local notification once per day when
    /// codex weekly quota drops below 20% or cursor monthly usage tops 80%.
    static let quotaAlertEnabled = "quota_alert_enabled"
    static let quotaAlertDay = "quota_alert_day"
    static func color(for tool: Tool) -> String { "color_\(tool.rawValue)" }
}

enum StoreKeys {
    static let opencodeWatermark = "oc_wm"
    static let codexRateLimits = "codex_rate_limits"
    static let cursorQuota = "cursor_quota"
    static let cursorLastSync = "cursor_last_sync"
    static let cursorLastTs = "cursor_last_ts"
    static let cursorKeyV2 = "cursor_key_v2"
    static let cursorAccountId = "cursor_account_id"
    static func codexSig(_ path: String) -> String { "codex_sig:" + path }
    static func codexOff(_ path: String) -> String { "codex_off:" + path }
}

/// Extension point for new tools (claude, gemini, …).
/// Conforming types get reconcile/health plumbing for free; `refresh` keeps
/// a per-source signature on purpose (local poll vs async network differ).
protocol ToolSource {
    static var tool: Tool { get }
    static func reconcile(store: UsageStore) throws
    static func isActive(within interval: TimeInterval) -> Bool
}

extension OpenCodeSource: ToolSource {
    static var tool: Tool { .opencode }
}

extension CodexSource: ToolSource {
    static var tool: Tool { .codex }
}
