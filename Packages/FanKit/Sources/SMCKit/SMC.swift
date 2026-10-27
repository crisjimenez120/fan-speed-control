import CSMC
import Foundation
import IOKit

public enum SMCError: Error, CustomStringConvertible {
    case notOpen
    case keyNotFound(String)
    case ioError(String, kern_return_t)
    case unsupportedType(String)

    public var description: String {
        switch self {
        case .notOpen: "Could not open AppleSMC"
        case .keyNotFound(let k): "SMC key \(k) not found"
        case .ioError(let k, let r): "SMC I/O error on \(k): \(String(format: "0x%08x", r))"
        case .unsupportedType(let t): "Unsupported SMC data type \(t)"
        }
    }
}

public struct SMCValue: Sendable {
    public let key: String
    public let type: String
    public let bytes: [UInt8]

    /// Decodes the value as a number, for the common numeric SMC types.
    public var number: Double? {
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4.0
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256.0
        case "ui8 ":
            return bytes.first.map(Double.init)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        default:
            return nil
        }
    }
}

func fourCC(_ s: String) -> UInt32 {
    s.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
}

func fourCCString(_ v: UInt32) -> String {
    let bytes = [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
    return String(decoding: bytes, as: UTF8.self)
}

/// Thin wrapper around an AppleSMC user-client connection. Not thread-safe; use from one actor.
public final class SMC {
    private let conn: io_connect_t

    public init() throws {
        conn = csmc_open()
        if conn == 0 { throw SMCError.notOpen }
    }

    deinit { csmc_close(conn) }

    public func read(_ key: String) throws -> SMCValue {
        var info = CSMCKeyInfo()
        var buf = [UInt8](repeating: 0, count: 32)
        let r = buf.withUnsafeMutableBufferPointer { csmc_read(conn, fourCC(key), &info, $0.baseAddress) }
        if r == kIOReturnNotFound { throw SMCError.keyNotFound(key) }
        if r != kIOReturnSuccess { throw SMCError.ioError(key, r) }
        return SMCValue(key: key, type: fourCCString(info.dataType), bytes: Array(buf.prefix(Int(info.dataSize))))
    }

    public func number(_ key: String) -> Double? {
        try? read(key).number
    }

    public func write(_ key: String, bytes: [UInt8]) throws {
        let r = bytes.withUnsafeBufferPointer { csmc_write(conn, fourCC(key), $0.baseAddress, UInt32(bytes.count)) }
        if r == kIOReturnNotFound { throw SMCError.keyNotFound(key) }
        if r != kIOReturnSuccess { throw SMCError.ioError(key, r) }
    }

    /// Writes a number, encoding it in the key's native type.
    public func write(_ key: String, number: Double) throws {
        let type = try read(key).type
        let bytes: [UInt8]
        switch type {
        case "flt ":
            let bits = Float(number).bitPattern
            bytes = [UInt8(bits & 0xff), UInt8(bits >> 8 & 0xff), UInt8(bits >> 16 & 0xff), UInt8(bits >> 24 & 0xff)]
        case "fpe2":
            let v = UInt16(clamping: Int(number * 4))
            bytes = [UInt8(v >> 8), UInt8(v & 0xff)]
        case "ui8 ":
            bytes = [UInt8(clamping: Int(number))]
        case "ui16":
            let v = UInt16(clamping: Int(number))
            bytes = [UInt8(v >> 8), UInt8(v & 0xff)]
        default:
            throw SMCError.unsupportedType(type)
        }
        try write(key, bytes: bytes)
    }

    public func allKeys() -> [String] {
        guard let count = number("#KEY") else { return [] }
        var keys: [String] = []
        keys.reserveCapacity(Int(count))
        for i in 0..<UInt32(count) {
            var k: UInt32 = 0
            if csmc_key_at_index(conn, i, &k) == kIOReturnSuccess { keys.append(fourCCString(k)) }
        }
        return keys
    }
}

public struct HIDTemperature: Sendable {
    public let name: String
    public let celsius: Double
}

public enum HIDSensors {
    public static func temperatures() -> [HIDTemperature] {
        guard let array = csmc_copy_hid_temperatures()?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return array.compactMap { d in
            guard let name = d["name"] as? String, let v = d["value"] as? Double, v > 0, v < 150 else { return nil }
            return HIDTemperature(name: name, celsius: v)
        }
    }
}
