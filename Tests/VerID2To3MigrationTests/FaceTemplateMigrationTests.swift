import XCTest
import FaceRecognitionDlib
import FaceRecognitionArcFaceCore
import FaceRecognitionArcFaceCloud
import VerIDCommonTypes
@testable import VerID2To3Migration

final class FaceTemplateMigrationTests: XCTestCase {
    
    let migration = FaceTemplateMigration()
    
    let testFaceTemplates: [String: [String]] = [
        "subject1": [
            "CgsBC3Byb3RvDIIZEAAQAYAAAABGabc4FUFGSdxP4USmRTktyNPeCTAhwSUZ3Mq/ASI7zj2nFLsx8dLPswk6otFAPeIQJ9lgJbInJVx/Lqgz79E2ssRBOrDF7kDSAVI5Js0dN7Q/vsdc0MzkL78G2bbRQzkv5fNSA+1MVw2t8ZgvPRFPxNcmTj3mfTSo+yzlG7wpq9StziYJdXVpZAwhgNp9OEzMcORFlGzYez1zrAE=",
            "CgsBC3Byb3RvDIIZEAAQAYAAAAAAfrE4HzAgNIBU2Q6lVkj7wBS/Eu42tx4rvR7M8B0xzGaBE6f1wcuwtdVBu+BYM8kpMuNMFsgcEXJKJc8lA+A7BvZLIsG+J0vlPD7vIeg/Cec0q70s17i7NrTy6aqpXFVA2yQ6vRZXPPq3PJY4K+9Czt4iLjrYbzWc1icBLBRDsMqhyzMJdXVpZAwhbQESeTuJUDEpsoeC66G+FwE=",
            "CgsBC3Byb3RvDIIZEAAQAYAAAABhxM44Thf7Ew9d6e0i+R1RzSj1CwoyxMIMB9Hx1Wbu9VK+wbQx/AjI1OVK7A9BT9Ub7QpGR+Aj+V5mLIDPLDVf480iVLvc4BHwI0Mw8OFEHPQ5yuQ36vHaIBcSIvb6PUgmJe5N1csbIgvJOq4FRyI4shoEaUneTBLB7RvvL8Q1vcC5LSMJdXVpZAwhSIUACdvEny4HeBjhUSgFgwE=",
            "CgsBC3Byb3RvDIIZGAAQAYAAAADZtMo616TpgEG6sg0/CYlZ4M85uQfJwS8HuMg7oOkE28wlLbkh9OBXBlsrYuEH4wm3luzVuk4cps3YtkjJUiTp6R8+OtI3G6E/FB0Lng/LKablO7TXFb3y7VAu/d0RYC3BLvy1XJ7W9foYz0/QuSzcSgU5kBQTwLYxaUCY3FDH0PJTBbYJdXVpZAwh3geQw7/S2nBtHvbCde5sFgE="
        ],
        "subject2": [
            "CgsBC3Byb3RvDIIZGAAQAYAAAAA1fqo6NsnjqZifFVPg0CKlmk0wtu1bJ9rQ/0mvX8AYjyo5KxRPOTpTfy3nlftLOKReMKkRxp0a0Cv7A0xYIzf80lLFIbcKKMj21FE+1cxLIjXOVzrBtOoiF7hn+eEyHN3URdkTja4xc6sTZiPUUrcTAu/m1MY0JNguLR8trS3VxTrWp2kJdXVpZAwhqs8iJmqSX5dTH7Qqk2t/oQE="
        ]
    ]
    
    func testConvertFaceTemplates() throws {
        let templates = self.testFaceTemplates.flatMap { (key, val) in
            val.compactMap { Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let converted = try self.migration.convertFaceTemplates(templates)
        XCTAssertEqual(templates.count, converted.count)
    }
    
    func testCompareConvertedFaceTemplates() async throws {
        let templates: [(String,Data)] = self.testFaceTemplates.flatMap { (key, val) in
            val.compactMap {
                guard let data = Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    return nil
                }
                return (key, data)
            }
        }
        var v16s: [(String,FaceTemplateDlib)] = []
        var v24s: [(String,FaceTemplate<V24,[Float]>)] = []
        for (subject, template) in templates {
            do {
                let v16: FaceTemplateDlib = try self.migration.convertFaceTemplate(template)
                v16s.append((subject, v16))
            } catch {
                let v24: FaceTemplate<V24,[Float]> = try self.migration.convertFaceTemplate(template)
                v24s.append((subject, v24))
            }
        }
        let faceRecognitionDlib = try FaceRecognitionDlib()
        for i in 0..<v16s.count-1 {
            for j in 1..<v16s.count {
                if v16s[i].1 != v16s[j].1, let score = try await faceRecognitionDlib.compareFaceRecognitionTemplates([v16s[i].1], to: v16s[j].1).first {
                    if v16s[i].0 == v16s[j].0 {
                        XCTAssertGreaterThanOrEqual(score, faceRecognitionDlib.defaultThreshold)
                    } else {
                        XCTAssertLessThan(score, faceRecognitionDlib.defaultThreshold)
                    }
                }
            }
        }
        let faceRecognitionArcFace = FaceRecognitionArcFace(apiKey: "", url: URL(string: "https://github.com")!)
        for i in 0..<v24s.count-1 {
            for j in 1..<v24s.count {
                if v24s[i].1 != v24s[j].1, let score = try await faceRecognitionArcFace.compareFaceRecognitionTemplates([v24s[i].1], to: v24s[j].1).first {
                    if v24s[i].0 == v24s[j].0 {
                        XCTAssertGreaterThanOrEqual(score, faceRecognitionArcFace.defaultThreshold)
                    } else {
                        XCTAssertLessThan(score, faceRecognitionArcFace.defaultThreshold)
                    }
                }
            }
        }
    }
    
    func testConvertFaceTemplatesByVersion() throws {
        let templates = self.testFaceTemplates.flatMap { (key, val) in
            val.compactMap { Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let v16s: [FaceTemplateDlib] = try self.migration.convertFaceTemplatesByVersion(templates)
        let v24s: [FaceTemplate<V24,[Float]>] = try self.migration.convertFaceTemplatesByVersion(templates)
        XCTAssertEqual(templates.count, v16s.count + v24s.count)
    }
}
