//
//  AMF3Decoder.swift
//  
//
//  Created by Jakub Dolejs on 02/09/2025.
//

import Foundation

struct AMF3Decoder {
    init() {}
    
    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        var reader = AMF3Reader(data)
        let root = try reader.readRootValue()
        let decoder = _AMF3Decoder(storage: [root], codingPath: [], userInfo: [:])
        return try T(from: decoder)
    }
}

// MARK: Internal value model we expose to Decodable containers

fileprivate enum AMF3Value {
    case object([String: AMF3Value])
    case string(String)
    case byteArray(Data)
    case null
}

// MARK: - Reader: parses exactly what we need

fileprivate struct AMF3Reader {
    var d: Data
    var i: Int = 0
    var stringRefs: [String] = []
    var byteArrayRefs: [Data] = []
    
    init(_ d: Data) { self.d = d }
    
    mutating func readRootValue() throws -> AMF3Value {
        guard i < d.count else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "AMF3 truncated")) }
        let marker = d[i]; i += 1
        switch marker {
        case 0x0A:  // object (dynamic traits)
            return try readObject()
        case 0x06:  // string
            return .string(try readStringNoMarkerConsumedAfterMarker())
        case 0x0C:  // bytearray
            return .byteArray(try readByteArrayNoMarkerConsumedAfterMarker())
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: String(format: "AMF3 unsupported root marker 0x%02X", marker)))
        }
    }
    
    // --- object (only inline traits; sealed+dynamic supported; stores supported values) ---
    mutating func readObject() throws -> AMF3Value {
        let trait = try readU29()
        // must be inline traits
        guard (trait & 0x01) != 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "AMF3 trait reference not supported"))
        }
        let inlineTraits = (trait & 0x02) != 0
        let isDynamic    = (trait & 0x08) != 0
        let sealedCount  = trait >> 4
        
        _ = try readNameNoMarker() // class name, ignore
        
        var dict: [String: AMF3Value] = [:]
        if inlineTraits && sealedCount > 0 {
            var names: [String] = []
            names.reserveCapacity(sealedCount)
            for _ in 0..<sealedCount { names.append(try readNameNoMarker()) }
            for n in names {
                if let v = try readSupportedValue() { dict[n] = v }
                else { _ = try skipUnsupportedValue() }
            }
        }
        
        if isDynamic {
            while true {
                let key = try readNameNoMarker()
                if key.isEmpty { break } // terminator
                if let v = try readSupportedValue() { dict[key] = v }
                else { _ = try skipUnsupportedValue() }
            }
        }
        
        return .object(dict)
    }
    
    // --- supported values for our use-cases (string, bytearray) ---
    mutating func readSupportedValue() throws -> AMF3Value? {
        guard i < d.count else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "AMF3 truncated")) }
        let marker = d[i]; i += 1
        switch marker {
        case 0x06: return .string(try readStringNoMarkerConsumedAfterMarker())
        case 0x0C: return .byteArray(try readByteArrayNoMarkerConsumedAfterMarker())
        case 0x01: return .null // null
        default:
            // unsupported marker at this path — tell caller to skip it
            i -= 1
            return nil
        }
    }
    
    mutating func skipUnsupportedValue() throws -> Bool {
        // Basic skip: read marker then best-effort skip known payloads; otherwise fail.
        let marker = d[i]; i += 1
        switch marker {
        case 0x06: _ = try readStringNoMarkerConsumedAfterMarker(); return true
        case 0x0C: _ = try readByteArrayNoMarkerConsumedAfterMarker(); return true
        case 0x01: return true // null
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: String(format: "AMF3 unsupported marker 0x%02X", marker)))
        }
    }
    
    // --- primitives ---
    
    // U29 (29-bit) variable-length int
    mutating func readU29() throws -> Int {
        func next() throws -> UInt8 {
            guard i < d.count else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "AMF3 truncated")) }
            defer { i += 1 }
            return d[i]
        }
        var value = 0
        var b = try next()
        if (b & 0x80) == 0 { return Int(b) }
        value = Int(b & 0x7F) << 7
        
        b = try next()
        if (b & 0x80) == 0 { return value | Int(b) }
        value = (value | Int(b & 0x7F)) << 7
        
        b = try next()
        if (b & 0x80) == 0 { return value | Int(b) }
        
        b = try next() // 4th byte: all 8 bits
        return (value << 8) | Int(b)
    }
    
    // name/strings *without* a leading marker
    mutating func readNameNoMarker() throws -> String {
        let u = try readU29()
        if (u & 1) == 0 {
            let idx = u >> 1
            guard idx < stringRefs.count else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "AMF3 bad string ref"))
            }
            return stringRefs[idx]
        }
        let len = u >> 1
        guard len >= 0, i + len <= d.count else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "AMF3 truncated string"))
        }
        if len == 0 { return "" }
        let s = String(decoding: d[i ..< i+len], as: UTF8.self)
        i += len
        stringRefs.append(s)
        return s
    }
    
    // string with marker already consumed
    mutating func readStringNoMarkerConsumedAfterMarker() throws -> String {
        let u = try readU29()
        if (u & 1) == 0 {
            let idx = u >> 1
            guard idx < stringRefs.count else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "AMF3 bad string ref"))
            }
            return stringRefs[idx]
        }
        let len = u >> 1
        guard len >= 0, i + len <= d.count else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "AMF3 truncated string"))
        }
        if len == 0 { return "" }
        let s = String(decoding: d[i ..< i+len], as: UTF8.self)
        i += len
        stringRefs.append(s)
        return s
    }
    
    // bytearray with marker already consumed
    mutating func readByteArrayNoMarkerConsumedAfterMarker() throws -> Data {
        let u = try readU29()
        if (u & 1) == 0 {
            let idx = u >> 1
            guard idx < byteArrayRefs.count else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "AMF3 bad bytearray ref"))
            }
            return byteArrayRefs[idx]
        }
        let len = u >> 1
        guard len >= 0, i + len <= d.count else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "AMF3 truncated bytearray"))
        }
        let bytes = Data(d[i ..< i+len])
        i += len
        byteArrayRefs.append(bytes)
        return bytes
    }
}

// MARK: - Decoder + containers

fileprivate struct _AMF3Decoder: Decoder {
    var storage: [AMF3Value]
    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey : Any]
    
    func container<Key>(keyedBy: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let obj) = storage.last! else {
            throw typeMismatch(KeyedDecodingContainer<Key>.self, "Expected object")
        }
        let c = AMF3KeyedContainer<Key>(obj: obj, codingPath: codingPath, userInfo: userInfo)
        return KeyedDecodingContainer(c)
    }
    
    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw typeMismatch(UnkeyedDecodingContainer.self, "Unkeyed containers not supported")
    }
    
    func singleValueContainer() throws -> SingleValueDecodingContainer {
        AMF3SingleValueContainer(value: storage.last!, codingPath: codingPath, userInfo: userInfo)
    }
    
    private func typeMismatch<T>(_ t: T.Type, _ msg: String) -> DecodingError {
        .typeMismatch(t, .init(codingPath: codingPath, debugDescription: msg))
    }
}

fileprivate struct AMF3KeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let obj: [String: AMF3Value]
    let codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey : Any]
    
    var allKeys: [Key] { obj.keys.compactMap(Key.init(stringValue:)) }
    
    func contains(_ key: Key) -> Bool { obj[key.stringValue] != nil }
    
    func decodeNil(forKey key: Key) throws -> Bool {
        if case .null? = obj[key.stringValue] { return true }
        return obj[key.stringValue] == nil
    }
    
    func decode(_ type: Data.Type, forKey key: Key) throws -> Data {
        guard let v = obj[key.stringValue] else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "Missing key"))
        }
        switch v {
        case .byteArray(let d): return d
        case .string(let s):
            guard let d = Data(base64Encoded: s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: codingPath + [key], debugDescription: "Invalid base64"))
            }
            return d
        default:
            throw DecodingError.typeMismatch(Data.self, .init(codingPath: codingPath + [key], debugDescription: "Expected bytearray or base64 string"))
        }
    }
    
    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        guard let v = obj[key.stringValue] else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "Missing key"))
        }
        switch v {
        case .string(let s): return s
        default:
            throw DecodingError.typeMismatch(String.self, .init(codingPath: codingPath + [key], debugDescription: "Expected string"))
        }
    }
    
    // Add others as needed (Bool, Int…), currently unsupported:
    func decode<T>(_ type: T.Type, forKey key: Key) throws -> T where T : Decodable {
        if T.self == Data.self {
            // handled by concrete overload above
            return try unsafeBitCast(decode(Data.self, forKey: key), to: T.self)
        }
        if T.self == String.self {
            return try unsafeBitCast(decode(String.self, forKey: key), to: T.self)
        }
        throw DecodingError.typeMismatch(T.self, .init(codingPath: codingPath + [key], debugDescription: "Type not supported by AMF3 shim"))
    }
    
    // Required by protocol but unused here:
    func nestedContainer<NestedKey>(keyedBy: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> { throw unsupported(key) }
    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer { throw unsupported(key) }
    func superDecoder() throws -> Decoder { throw unsupported(nil) }
    func superDecoder(forKey key: Key) throws -> Decoder { throw unsupported(key) }
    
    private func unsupported(_ key: CodingKey?) -> Error {
        DecodingError.typeMismatch(Any.self, .init(codingPath: codingPath + (key.map{[$0]} ?? []), debugDescription: "Not supported by AMF3 shim"))
    }
}

fileprivate struct AMF3SingleValueContainer: SingleValueDecodingContainer {
    let value: AMF3Value
    let codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey : Any]
    
    func decodeNil() -> Bool { if case .null = value { return true } else { return false } }
    
    func decode(_ type: Data.Type) throws -> Data {
        switch value {
        case .byteArray(let d): return d
        case .string(let s):
            guard let d = Data(base64Encoded: s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Invalid base64"))
            }
            return d
        default:
            throw DecodingError.typeMismatch(Data.self, .init(codingPath: codingPath, debugDescription: "Expected bytearray or base64 string"))
        }
    }
    
    func decode(_ type: String.Type) throws -> String {
        guard case .string(let s) = value else {
            throw DecodingError.typeMismatch(String.self, .init(codingPath: codingPath, debugDescription: "Expected string"))
        }
        return s
    }
    
    func decode<T>(_ type: T.Type) throws -> T where T : Decodable {
        if T.self == Data.self {
            return try unsafeBitCast(decode(Data.self), to: T.self)
        }
        if T.self == String.self {
            return try unsafeBitCast(decode(String.self), to: T.self)
        }
        throw DecodingError.typeMismatch(T.self, .init(codingPath: codingPath, debugDescription: "Type not supported by AMF3 shim"))
    }
}
