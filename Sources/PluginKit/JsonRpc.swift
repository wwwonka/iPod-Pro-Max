import Foundation

/// Maximum allowed UTF-8 line length (16 MiB) on the JSON-RPC stdio transport.
public let pluginMaxLineBytes = 16 * 1024 * 1024

public enum JsonRpcID: Codable, Sendable, Hashable {
    case int(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "JSON-RPC id must be Int or String")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        }
    }

    public var stringKey: String {
        switch self {
        case .int(let i): return String(i)
        case .string(let s): return s
        }
    }
}

public struct JsonRpcErrorData: Codable, Sendable, Equatable {
    public var code: String
    public var retryAfterSeconds: Int?

    public init(code: String, retryAfterSeconds: Int? = nil) {
        self.code = code
        self.retryAfterSeconds = retryAfterSeconds
    }
}

public struct JsonRpcErrorObject: Codable, Sendable, Equatable {
    public var code: Int
    public var message: String
    public var data: JsonRpcErrorData?

    public init(code: Int, message: String, data: JsonRpcErrorData? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public struct JsonRpcEnvelope: Codable, Sendable {
    public var jsonrpc: String
    public var id: JsonRpcID?
    public var method: String?
    public var params: JSONValue?
    public var result: JSONValue?
    public var error: JsonRpcErrorObject?

    public init(
        jsonrpc: String = "2.0",
        id: JsonRpcID? = nil,
        method: String? = nil,
        params: JSONValue? = nil,
        result: JSONValue? = nil,
        error: JsonRpcErrorObject? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }
}

public enum JsonRpcCodec {
    public static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return enc
    }()

    public static let decoder = JSONDecoder()

    public static func encodeValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try encoder.encode(value)
        return try decoder.decode(JSONValue.self, from: data)
    }

    public static func decodeValue<T: Decodable>(_ type: T.Type, from value: JSONValue?) throws -> T {
        let target = value ?? .object([:])
        let data = try encoder.encode(target)
        return try decoder.decode(type, from: data)
    }

    public static func encodeLine(_ envelope: JsonRpcEnvelope) throws -> Data {
        var data = try encoder.encode(envelope)
        data.append(0x0A)
        return data
    }
}
