//
//  FPVCDecoder.swift
//
//
//  Created by Jakub Dolejs on 01/09/2025.
//

import Foundation

class FPVCDecoder {
    
    func deserializeFPVC(_ data: Data) throws -> FP16Vec {
        var remaining = data.count
        if remaining < 4 {
            throw FaceTemplateMigrationError.vectorDeserializationFailed
        }
        
        // byte access
        let u8 = data
        
        // u8[0] is version (not used here)
        let nels_head = Int(u8[1])
        
        // Special short format: 1 vector, 128 x int8 + BF16 coeff
        if nels_head == 1 && remaining >= 132 {
            var v = FP16Vec()
            v.values = [Int16](repeating: 0, count: 128)
            
            // 128 int8 starting at byte 4
            for i in 0..<128 {
                v.values[i] = Int16(Int8(bitPattern: u8[4 + i]))
            }
            // coeff is BF16 at bytes 2..3 (little-endian), expanded by << 16
            let bf16 = readLEUInt16(u8, at: 2)
            v.coeff = bfloat16ToFloat(bf16)
            if !(v.coeff >= 0) {
                throw FaceTemplateMigrationError.vectorDeserializationFailed
            }
            return v
        }
        
        let type = Int(u8[2])
        let nvecs = Int(u8[3])
        guard nvecs == 1 else {
            throw FaceTemplateMigrationError.vectorDeserializationFailed
        }
        
        var offset = 4
        remaining -= 4
        var result = FP16Vec()
        
        var nels = nels_head
        if nels == 0 {
            if remaining < 4 {
                throw FaceTemplateMigrationError.vectorDeserializationFailed
            }
            let nels32 = readLEUInt32(u8, at: offset)
            if nels32 == 0 {
                throw FaceTemplateMigrationError.vectorDeserializationFailed
            }
            nels = Int(nels32)
            offset += 4
            remaining -= 4
        }
        
        var nBytes = 0
        switch type {
        case 0x10:
            nBytes = fpvcVectorSerializeSize(nels)
            if remaining < nBytes {
                throw FaceTemplateMigrationError.vectorDeserializationFailed
            }
            let slice = u8[offset ..< offset + nBytes]
            let fpvc = try fpvcVectorDeserialize(Data(slice), nels: nels)
            let fp16 = toFP16Vec(fpvc)
            result = fp16
            
        case 0x11:
            nBytes = fp16vec_12_bytes(nels)
            if remaining < nBytes {
                throw FaceTemplateMigrationError.vectorDeserializationFailed
            }
            let slice = u8[offset ..< offset + nBytes]
            let fp16 = try deserialize_fp16vec_12(Data(slice), nels: nels)
            result = fp16
            
        case 0x12:
            nBytes = fp16vec_16_bytes(nels)
            if remaining < nBytes {
                throw FaceTemplateMigrationError.vectorDeserializationFailed
            }
            let slice = u8[offset ..< offset + nBytes]
            let fp16 = try deserialize_fp16vec_16(Data(slice), nels: nels)
            result = fp16
            
        default:
            throw FaceTemplateMigrationError.vectorDeserializationFailed
        }
        
        assert((nBytes & 3) == 0)
        offset += nBytes
        remaining -= nBytes
        assert(result.count == nels)
        
        // If bytes remain, C++ only logs a warning; we ignore (no throw)
        return result
    }
    
    @inline(__always)
    private func fpvcVectorSerializeSize(_ nels: Int) -> Int {
        let padded = (nels + 3) & ~3
        return 4 + padded
    }
    
    /// C++: fpvc_vector_deserialize(const void* src, size_t vector_size)
    private func fpvcVectorDeserialize(_ blob: Data, nels: Int) throws -> FPVCVector {
        var r = FPVCVector()
        guard blob.count >= 4 + nels else {
            throw FaceTemplateMigrationError.vectorDeserializationFailed
        }
        r.coeff = readFloatLE(blob, at: 0)
        if !(r.coeff >= 0) {
            throw FaceTemplateMigrationError.vectorDeserializationFailed
        }
        // only the first `nels` code bytes are actual data; padding may follow
        r.codes = Array(blob[4 ..< 4 + nels])
        return r
    }
    
    /// C++: to_fp16vec(const fpvc_vector_type&)
    private func toFP16Vec(_ v: FPVCVector) -> FP16Vec {
        var r = FP16Vec()
        r.coeff = v.coeff
        r.values = v.codes.map { Int16(fpvc_s16_decompress_table[Int($0)]) }
        return r
    }
    
    /// C++: fp16vec_12_bytes(size_t nels)
    @inline(__always)
    private func fp16vec_12_bytes(_ nels: Int) -> Int {
        // 4 bytes coeff + packed 12-bit ints, padded to multiple of 4.
        // pairs: 3 bytes per 2 values; odd tail: 2 bytes
        let pairs = nels / 2
        let tail = (nels & 1)
        let dataBytes = pairs * 3 + (tail == 1 ? 2 : 0)
        let padded = (dataBytes + 3) & ~3
        return 4 + padded
    }
    
    /// C++: deserialize_fp16vec_12(const void* src, size_t vector_size)
    private func deserialize_fp16vec_12(_ blob: Data, nels: Int) throws -> FP16Vec {
        var r = FP16Vec()
        guard blob.count >= 4 else {
            throw FaceTemplateMigrationError.vectorDeserializationFailed
        }
        r.coeff = readFloatLE(blob, at: 0)
        if !(r.coeff >= 0) {
            throw FaceTemplateMigrationError.vectorDeserializationFailed
        }
        r.values = [Int16](repeating: 0, count: nels)
        
        var p = 4
        var i = 0
        while (nels - i) >= 2 {
            // x0: ((p[1]<<12) + (p[0]<<4)) >> 4 (arith)
            let comb0 = (UInt16(blob[p+1]) << 12) | (UInt16(blob[p+0]) << 4)
            r.values[i] = Int16(bitPattern: comb0) >> 4
            // x1: ((p[2]<<8) + p[1]) >> 4 (arith)
            let comb1 = (UInt16(blob[p+2]) << 8) | UInt16(blob[p+1])
            r.values[i+1] = Int16(bitPattern: comb1) >> 4
            
            p += 3
            i += 2
        }
        if i < nels {
            let comb0 = (UInt16(blob[p+1]) << 12) | (UInt16(blob[p+0]) << 4)
            r.values[i] = Int16(bitPattern: comb0) >> 4
            // padding may follow; OK
        }
        return r
    }
    
    /// C++: fp16vec_16_bytes(size_t nels)
    @inline(__always)
    private func fp16vec_16_bytes(_ nels: Int) -> Int {
        // 4 bytes coeff + 2*nels + (if odd, 2 bytes pad)
        return 4 + 2 * nels + ((nels & 1) == 1 ? 2 : 0)
    }
    
    /// C++: deserialize_fp16vec_16(const void* src, size_t vector_size)
    private func deserialize_fp16vec_16(_ blob: Data, nels: Int) throws -> FP16Vec {
        var r = FP16Vec()
        guard blob.count >= 4 + 2 * nels else {
            throw FaceTemplateMigrationError.vectorDeserializationFailed
        }
        r.coeff = readFloatLE(blob, at: 0)
        if !(r.coeff >= 0) {
            throw FaceTemplateMigrationError.vectorDeserializationFailed
        }
        r.values = [Int16](repeating: 0, count: nels)
        var off = 4
        for i in 0..<nels {
            r.values[i] = readLEInt16(blob, at: off)
            off += 2
        }
        return r
    }
    
    private let fpvc_s16_decompress_table: [Int16] = [
        0, 1, 4, 8, 16, 24, 32, 40,
        48, 56, 64, 72, 80, 88, 96, 104,
        113, 122, 131, 140, 149, 158, 167, 176,
        185, 194, 204, 214, 224, 234, 244, 254,
        264, 274, 285, 296, 307, 318, 329, 340,
        352, 364, 376, 388, 400, 413, 426, 439,
        452, 466, 480, 494, 509, 524, 540, 556,
        572, 588, 604, 620, 636, 652, 668, 684,
        700, 716, 732, 748, 764, 780, 796, 812,
        828, 844, 860, 876, 892, 908, 924, 940,
        956, 972, 988, 1004, 1020, 1036, 1052, 1068,
        1084, 1100, 1116, 1132, 1148, 1164, 1180, 1196,
        1212, 1228, 1244, 1260, 1276, 1292, 1308, 1324,
        1340, 1356, 1372, 1388, 1404, 1420, 1436, 1452,
        1468, 1484, 1500, 1516, 1532, 1548, 1564, 1580,
        1596, 1612, 1628, 1644, 1660, 1676, 1692, 1708,
        -1708, -1692, -1676, -1660, -1644, -1628, -1612, -1596,
        -1580, -1564, -1548, -1532, -1516, -1500, -1484, -1468,
        -1452, -1436, -1420, -1404, -1388, -1372, -1356, -1340,
        -1324, -1308, -1292, -1276, -1260, -1244, -1228, -1212,
        -1196, -1180, -1164, -1148, -1132, -1116, -1100, -1084,
        -1068, -1052, -1036, -1020, -1004, -988, -972, -956,
        -940, -924, -908, -892, -876, -860, -844, -828,
        -812, -796, -780, -764, -748, -732, -716, -700,
        -684, -668, -652, -636, -620, -604, -588, -572,
        -556, -540, -524, -509, -494, -480, -466, -452,
        -439, -426, -413, -400, -388, -376, -364, -352,
        -340, -329, -318, -307, -296, -285, -274, -264,
        -254, -244, -234, -224, -214, -204, -194, -185,
        -176, -167, -158, -149, -140, -131, -122, -113,
        -104, -96, -88, -80, -72, -64, -56, -48,
        -40, -32, -24, -16, -8, -4, -1, 0
    ]
    
    // MARK: - Byte reading helpers (LE) + BF16 → Float
    
    @inline(__always)
    private func readLEUInt16(_ data: Data, at offset: Int) -> UInt16 {
        let lo = UInt16(data[offset])
        let hi = UInt16(data[offset+1]) << 8
        return hi | lo
    }
    
    @inline(__always)
    private func readLEUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset+0])
        let b1 = UInt32(data[offset+1]) << 8
        let b2 = UInt32(data[offset+2]) << 16
        let b3 = UInt32(data[offset+3]) << 24
        return b0 | b1 | b2 | b3
    }
    
    @inline(__always)
    private func readLEInt16(_ data: Data, at offset: Int) -> Int16 {
        let u = readLEUInt16(data, at: offset)
        return Int16(bitPattern: u)
    }
    
    @inline(__always)
    private func readFloatLE(_ data: Data, at offset: Int) -> Float {
        let bits = readLEUInt32(data, at: offset)
        return Float(bitPattern: bits)
    }
    
    // BF16 (upper 16 bits of IEEE754 float32) → Float
    @inline(__always)
    private func bfloat16ToFloat(_ upper16: UInt16) -> Float {
        let bits = UInt32(upper16) << 16
        return Float(bitPattern: bits)
    }
}

struct FP16Vec {
    public var coeff: Float = 0
    public var values: [Int16] = []
    public var count: Int { values.count }
    public var isEmpty: Bool { values.isEmpty }
}

struct FPVCVector {
    public var coeff: Float = 0
    public var codes: [UInt8] = []
    public var isEmpty: Bool { codes.isEmpty }
}
