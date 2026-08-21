import Foundation

final class LockedISO8601 {
    private let formatter: ISO8601DateFormatter
    private let lock = NSLock()

    init(fractionalSeconds: Bool) {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
    }

    func date(from string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return formatter.date(from: string)
    }
}

enum Formatters {
    static let isoFractional = LockedISO8601(fractionalSeconds: true)
    static let isoPlain = LockedISO8601(fractionalSeconds: false)
}
