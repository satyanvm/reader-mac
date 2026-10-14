import Foundation

/// The `position` JSON from the server contract (docs/position-sync.md), byte-compatible with the
/// Android app: fractions are written as the `Double` value of the `Float`, the way org.json does.
public enum PositionJSON {
    public static func object(_ p: ReadingPosition) -> [String: Any] {
        [
            "documentId": p.documentId,
            "pageIndex": p.pageIndex,
            "pageOffset": Double(p.pageOffset),
            "horizontalOffset": Double(p.horizontalOffset),
            "zoom": Double(p.zoom),
            "pageCount": p.pageCount,
            "hlc": p.stamp.hlc,
            "deviceId": p.stamp.deviceId,
            "schemaVersion": p.schemaVersion,
        ]
    }

    public static func encode(_ p: ReadingPosition) throws -> Data {
        try JSONSerialization.data(withJSONObject: object(p), options: [.sortedKeys])
    }

    public struct DecodeError: Error, CustomStringConvertible {
        public let description: String
    }

    public static func decode(_ data: Data) throws -> ReadingPosition {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeError(description: "position is not a JSON object")
        }
        return try decode(o)
    }

    /// Same required/optional fields and defaults as Android's `HttpSyncApi.fromJson`.
    public static func decode(_ o: [String: Any]) throws -> ReadingPosition {
        func req<T>(_ key: String, _ get: (Any) -> T?) throws -> T {
            guard let raw = o[key], let v = get(raw) else { throw DecodeError(description: "missing or bad \(key)") }
            return v
        }
        func opt<T>(_ key: String, _ get: (Any) -> T?, _ fallback: T) -> T {
            o[key].flatMap(get) ?? fallback
        }
        let string: (Any) -> String? = { $0 as? String }
        let int: (Any) -> Int? = { ($0 as? NSNumber).map { $0.intValue } }
        let int64: (Any) -> Int64? = { ($0 as? NSNumber).map { $0.int64Value } }
        let float: (Any) -> Float? = { ($0 as? NSNumber).map { Float($0.doubleValue) } }
        return ReadingPosition(
            documentId: try req("documentId", string),
            pageIndex: try req("pageIndex", int),
            pageOffset: try req("pageOffset", float),
            horizontalOffset: opt("horizontalOffset", float, 0),
            zoom: opt("zoom", float, 1),
            pageCount: try req("pageCount", int),
            stamp: Stamp(hlc: try req("hlc", int64), deviceId: try req("deviceId", string)),
            schemaVersion: opt("schemaVersion", int, ReadingPosition.schemaVersion)
        )
    }
}
