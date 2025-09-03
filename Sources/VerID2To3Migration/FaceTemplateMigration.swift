import Foundation
import VerIDCommonTypes
import FaceRecognitionArcFaceCore
import FaceRecognitionDlib
import Compression
import Accelerate

public class FaceTemplateMigration {
    
    public static let `default` = FaceTemplateMigration()
    
    private let fpvcDecoder: FPVCDecoder = FPVCDecoder()
    
    public func convertFaceTemplates(_ legacyFaceTemplates: [Data]) throws -> [any FaceTemplateProtocol] {
        return try legacyFaceTemplates.reduce(into: [any FaceTemplateProtocol]()) { result, template in
            do {
                let v16: FaceTemplate<V16,[Float]> = try self.convertFaceTemplate(template)
                result.append(v16)
            } catch {
                let v24: FaceTemplate<V24,[Float]> = try self.convertFaceTemplate(template)
                result.append(v24)
            }
        }
    }
    
    public func convertFaceTemplatesByVersion<T: FaceTemplateVersion>(_ legacyFaceTemplates: [Data]) throws -> [FaceTemplate<T,[Float]>] {
        return try legacyFaceTemplates.compactMap { template in
            let rawBytes = try self.rawBytesFromTemplate(template)
            if Int(rawBytes[0]) != T.id {
                return nil
            }
            return try self.convertRawTemplateBytes(rawBytes)
        }
    }
    
    public func convertFaceTemplate<V: FaceTemplateVersion>(_ input: Data) throws -> FaceTemplate<V, [Float]> {
        let data = try self.rawBytesFromTemplate(input)
        return try self.convertRawTemplateBytes(data)
    }
    
    public func versionOfLegacyFaceTemplate(_ faceTemplate: Data) throws -> Int {
        let data = try self.rawBytesFromTemplate(faceTemplate)
        return Int(data[0])
    }
    
    private func rawBytesFromTemplate(_ faceTemplate: Data) throws -> Data {
        var data = faceTemplate
        while self.isCompressed(data) {
            data = try self.removeCompression(data)
        }
        if !self.isPrototype(data) {
            if let b0 = data.first, b0 == UInt8(ascii: "{") || b0 == UInt8(ascii: "\"") {
                let v2Prototype = try JSONDecoder().decode(V2Prototype.self, from: data)
                return try self.rawBytesFromTemplate(v2Prototype.proto)
            }
            if let b0 = data.first, b0 < 32 {
                let v2Prototype = try AMF3Decoder().decode(V2Prototype.self, from: data)
                return try self.rawBytesFromTemplate(v2Prototype.proto)
            }
        }
        return data
    }
    
    private func convertRawTemplateBytes<V: FaceTemplateVersion>(_ data: Data) throws -> FaceTemplate<V, [Float]> {
        if data.isEmpty {
            throw FaceTemplateMigrationError.emptyTemplateData
        }
        let version = Int(data[0])
        guard version == V.id else {
            throw FaceTemplateMigrationError.faceTemplateVersionMismatch(expected: V.id, actual: version)
        }
        let vec = try self.fpvcDecoder.deserializeFPVC(data)
        if vec.isEmpty {
            throw FaceTemplateMigrationError.vectorDeserializationFailed
        }
        var floats = vec.values.map { Float($0) * vec.coeff }
        self.normalize(&floats)
        return FaceTemplate(data: floats)
    }
    
    private func isPrototype(_ src: Data) -> Bool {
        guard src.count >= 4 else { return false }
        let p0 = src[0], p1 = src[1], p2 = src[2], p3 = src[3]
        if p0 > 16 && p0 < 120 && p1 == 1 && src.count == 132 { return true }
        let mask: UInt8 = 0xEC
        return p0 != 0 && p2 != 0 && (p2 & mask) == 0 && p3 != 0 && p3 <= 2
    }
    
    private func isCompressed(_ src: Data) -> Bool {
        guard src.count >= 2 else { return false }
        let b0 = src[0], b1 = src[1]
        let cmfOk = (b0 & 0x0F) == 8
        let header = UInt32(b0) &* 256 &+ UInt32(b1)
        return cmfOk && (header % 31 == 0)
    }
    
    private func removeCompression(_ src: Data) throws -> Data {
        guard !src.isEmpty else {
            throw FaceTemplateMigrationError.emptyTemplateData
        }
        
        // Heap dummies to satisfy memberwise init on iOS (no dangling)
        let dummyDst = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        dummyDst.initialize(to: 0)
        let dummySrcMut = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        dummySrcMut.initialize(to: 0)
        let dummySrc = UnsafePointer<UInt8>(dummySrcMut)
        defer {
            dummyDst.deinitialize(count: 1); dummyDst.deallocate()
            dummySrcMut.deinitialize(count: 1); dummySrcMut.deallocate()
        }
        
        var stream = compression_stream(
            dst_ptr: dummyDst, dst_size: 0,
            src_ptr: dummySrc,  src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else {
            throw FaceTemplateMigrationError.decompressionFailed
        }
        defer { compression_stream_destroy(&stream) }
        
        let chunkSize = max(1, src.count)
        var out = Data(); out.reserveCapacity(chunkSize)
        
        try src.withUnsafeBytes { rawIn in
            guard let inBase = rawIn.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw FaceTemplateMigrationError.decompressionFailed
            }
            stream.src_ptr  = inBase
            stream.src_size = rawIn.count
            
            var buffer = [UInt8](repeating: 0, count: chunkSize)
            
            while true {
                let status: compression_status = buffer.withUnsafeMutableBytes { rawOut in
                    let outBase = rawOut.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    stream.dst_ptr  = outBase
                    stream.dst_size = rawOut.count
                    return compression_stream_process(&stream, 0)
                }
                let produced = chunkSize - stream.dst_size
                
                switch status {
                case COMPRESSION_STATUS_OK:
                    // C++: if (avail_out != 0) => premature end (error)
                    if produced != chunkSize {
                        throw FaceTemplateMigrationError.decompressionFailed
                    }
                    buffer.withUnsafeBytes {
                        out.append($0.bindMemory(to: UInt8.self).baseAddress!, count: produced)
                    }
                    continue
                case COMPRESSION_STATUS_END:
                    if produced > 0 {
                        buffer.withUnsafeBytes {
                            out.append($0.bindMemory(to: UInt8.self).baseAddress!, count: produced)
                        }
                    }
                    return
                default:
                    throw FaceTemplateMigrationError.decompressionFailed
                }
            }
        }
        
        return out
    }
    
    private func norm(_ template: [Float]) -> Float {
        let n = vDSP_Length(template.count)
        var norm: Float = 0.0
        vDSP_svesq(template, 1, &norm, n)
        return sqrt(norm)
    }
    
    private func normalize(_ x: inout [Float]) {
        let n = norm(x)
        if n > 0 {
            let inv = 1/n
            vDSP_vsmul(x, 1, [inv], &x, 1, vDSP_Length(x.count))
        }
    }
}

public enum FaceTemplateMigrationError: LocalizedError {
    case unsupportedFaceTemplateVersion(Int)
    case emptyTemplateData
    case decompressionFailed
    case vectorDeserializationFailed
    case base64DecodingFailure
    case faceTemplateVersionMismatch(expected: Int, actual: Int)
    
    public var errorDescription: String? {
        switch self {
        case .unsupportedFaceTemplateVersion(let version):
            return NSLocalizedString("Unsupported face template version \(version)", comment: "")
        case .emptyTemplateData:
            return NSLocalizedString("Face template data is empty", comment: "")
        case .decompressionFailed:
            return NSLocalizedString("Face template data decompression failed", comment: "")
        case .vectorDeserializationFailed:
            return NSLocalizedString("Failed to deserialize vector", comment: "")
        case .base64DecodingFailure:
            return NSLocalizedString("Failed to decode base64 string", comment: "")
        case .faceTemplateVersionMismatch(expected: let expected, actual: let actual):
            return NSLocalizedString("Expected version \(expected) template but got version \(actual)", comment: "")
        }
    }
}
