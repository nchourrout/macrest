import Foundation

/// Connect protocol framing for Backrest's server-streaming calls (`GetLogs`).
/// A unary call is plain JSON; a stream wraps each message in an envelope of
/// one flags byte and a big-endian u32 length, and ends on an envelope whose
/// flags carry 0x02, holding `{}` or `{"error":{...}}`.
public enum ConnectStream {
    public static let contentType = "application/connect+json"

    public static func envelope(_ message: Data) -> Data {
        var out = Data([0])
        var length = UInt32(message.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(message)
        return out
    }

    public struct Decoded: Sendable, Equatable {
        public var messages: [Data] = []
        public var error: String?
    }

    public static func decode(_ data: Data) -> Decoded {
        var result = Decoded()
        let bytes = [UInt8](data)
        var i = 0
        while i + 5 <= bytes.count {
            let flags = bytes[i]
            let length = bytes[(i + 1)...(i + 4)].reduce(0) { ($0 << 8) | Int($1) }
            let start = i + 5
            guard start + length <= bytes.count else {
                result.error = "the log stream was cut short"
                break
            }
            let payload = Data(bytes[start..<start + length])
            if flags & 0x02 != 0 {
                let end = try? JSONDecoder().decode(JSONValue.self, from: payload)
                result.error = end?["error"].map { $0["message"]?.string ?? $0["code"]?.string ?? "stream error" }
            } else {
                result.messages.append(payload)
            }
            i = start + length
        }
        return result
    }

    /// `GetLogs` messages are `{"value": <base64 bytes>}`: the log in chunks.
    public static func logText(_ data: Data) -> (text: String, error: String?) {
        let decoded = decode(data)
        var bytes = Data()
        for message in decoded.messages {
            if let value = (try? JSONDecoder().decode(JSONValue.self, from: message))?["value"]?.string,
               let chunk = Data(base64Encoded: value) {
                bytes.append(chunk)
            }
        }
        return (String(decoding: bytes, as: UTF8.self), decoded.error)
    }
}
