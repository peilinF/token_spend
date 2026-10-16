import Foundation

enum CursorRPCError: Error, Equatable {
    case missingSession
    case invalidSession
    case unreadableSession
    case unauthorized
    case http(Int)
    case invalidResponse
}

struct CursorNativeSession: Equatable {
    let accessToken: String
    let expiresAt: Date

    static var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    static func read(databaseURL: URL = databaseURL, now: Date = Date()) throws -> CursorNativeSession {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        } catch {
            let nsError = error as NSError
            let missingFileCodes = [
                CocoaError.Code.fileNoSuchFile.rawValue,
                CocoaError.Code.fileReadNoSuchFile.rawValue,
            ]
            if nsError.domain == NSCocoaErrorDomain, missingFileCodes.contains(nsError.code) {
                throw CursorRPCError.missingSession
            }
            throw CursorRPCError.unreadableSession
        }
        let database: SQLiteDatabase
        do {
            database = try SQLiteDatabase(path: databaseURL.path, readonly: true)
        } catch {
            throw CursorRPCError.unreadableSession
        }
        var value: String?
        do {
            try database.query(
                "SELECT value FROM ItemTable WHERE key=? LIMIT 1",
                binds: [.text("cursorAuth/accessToken")]
            ) { row in
                value = row.text(0)
            }
        } catch {
            throw CursorRPCError.unreadableSession
        }
        guard let token = value, let expiry = expiryDate(inJWT: token),
              expiry.timeIntervalSince(now) > 30 else {
            throw CursorRPCError.invalidSession
        }
        return CursorNativeSession(accessToken: token, expiresAt: expiry)
    }

    private static func expiryDate(inJWT token: String) -> Date? {
        let components = token.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3 else { return nil }
        var payload = String(components[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - payload.count % 4) % 4
        payload += String(repeating: "=", count: padding)
        guard let data = Data(base64Encoded: payload),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let seconds = (object["exp"] as? NSNumber)?.doubleValue,
              seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

struct CursorRPC {
    static let host = "api2.cursor.sh"

    enum Method: String {
        case getSandUsageStatus = "GetSandUsageStatus"
        case getCurrentPeriodUsage = "GetCurrentPeriodUsage"
        case getFilteredUsageEvents = "GetFilteredUsageEvents"
    }

    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    private let accessToken: String
    private let transport: Transport

    init(session: CursorNativeSession, transport: @escaping Transport = CursorRPC.defaultTransport) {
        accessToken = session.accessToken
        self.transport = transport
    }

    func call(method: Method, body: Data = Data("{}".utf8)) async throws -> Data {
        guard let url = URL(string: "https://\(Self.host)/aiserver.v1.DashboardService/\(method.rawValue)") else {
            throw CursorRPCError.invalidResponse
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport(request)
        guard let response = response as? HTTPURLResponse,
              response.url?.scheme == "https",
              response.url?.host == Self.host else {
            throw CursorRPCError.invalidResponse
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw CursorRPCError.unauthorized
        }
        guard (200..<300).contains(response.statusCode) else {
            throw CursorRPCError.http(response.statusCode)
        }
        return data
    }

    private static let defaultTransport: Transport = { request in
        let delegate = FixedHostRedirectDelegate(host: host)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await session.data(for: request)
    }
}

private final class FixedHostRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private let host: String

    init(host: String) { self.host = host }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(
            request.url?.scheme == "https" && request.url?.host == host ? request : nil
        )
    }
}
