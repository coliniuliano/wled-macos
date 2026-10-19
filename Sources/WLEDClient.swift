import Foundation

enum WLEDError: LocalizedError {
    case badStatus(Int)
    case badURL(String)
    /// WLED serves JSON through one shared buffer and answers 503 when it
    /// cannot take the lock. It means "ask again", not "something is wrong".
    case busy

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "HTTP \(code)"
        case .badURL(let host):    return "Bad address: \(host)"
        case .busy:                return "Controller busy"
        }
    }
}

/// Stateless HTTP client for WLED's JSON API. No auth, no SDK — two calls
/// cover everything in Phase 1.
enum WLEDClient {

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // LAN devices are either there or they aren't; long timeouts just make
        // the menu feel broken while it waits on an unplugged controller.
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 5
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private static func url(_ host: String, _ path: String) throws -> URL {
        guard let url = URL(string: "http://\(host)\(path)") else {
            throw WLEDError.badURL(host)
        }
        return url
    }

    /// `GET /json` — state, info, effects and palettes in one shot.
    static func fetchAll(host: String) async throws -> WLEDFullResponse {
        try await retryingWhileBusy {
            let (data, response) = try await session.data(from: try url(host, "/json"))
            try check(response)
            return try JSONDecoder().decode(WLEDFullResponse.self, from: data)
        }
    }

    /// A 503 from WLED is a lock contention, so a short backoff clears it.
    /// Anything else is a real failure and propagates immediately.
    private static func retryingWhileBusy<T>(
        _ work: () async throws -> T
    ) async throws -> T {
        var delay: UInt64 = 120_000_000
        for _ in 0..<3 {
            do {
                return try await work()
            } catch WLEDError.busy {
                try? await Task.sleep(nanoseconds: delay)
                delay *= 2
            }
        }
        throw WLEDError.busy
    }

    /// `POST /json/state` — the single write endpoint for power, brightness,
    /// effect, palette and presets.
    static func setState(host: String, _ body: [String: Any]) async throws {
        var request = URLRequest(url: try url(host, "/json/state"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        try await retryingWhileBusy {
            let (_, response) = try await session.data(for: request)
            try check(response)
        }
    }

    /// `GET /presets.json` — a dict keyed by slot number. Unused slots are
    /// literally empty objects, so we parse loosely with JSONSerialization
    /// rather than fighting Codable over "an object that may have no keys".
    static func fetchPresets(host: String) async throws -> [Preset] {
        let (data, response) = try await session.data(from: try url(host, "/presets.json"))
        try check(response)

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var presets: [Preset] = []
        for (key, value) in root {
            // Slot 0 is WLED's scratch slot and is never user-selectable.
            guard let slot = Int(key), slot > 0,
                  let body = value as? [String: Any], !body.isEmpty
            else { continue }

            let isPlaylist = body["playlist"] != nil
            let name = (body["n"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "Preset \(slot)"
            presets.append(Preset(id: slot, name: name, isPlaylist: isPlaylist))
        }
        return presets.sorted { $0.id < $1.id }
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 503 { throw WLEDError.busy }
        guard (200..<300).contains(http.statusCode) else {
            throw WLEDError.badStatus(http.statusCode)
        }
    }
}
