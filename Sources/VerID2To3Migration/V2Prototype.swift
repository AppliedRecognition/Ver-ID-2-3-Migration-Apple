//
//  V2Prototype.swift
//
//
//  Created by Jakub Dolejs on 01/09/2025.
//

import Foundation

struct V2Prototype: Decodable {
    
    let proto: Data
    
    enum CodingKeys: CodingKey {
        case proto
    }
    
    init(from decoder: Decoder) throws {
        let protoStr: String
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            do {
                self.proto = try container.decode(Data.self, forKey: .proto)
                return
            } catch {
                protoStr = try container.decode(String.self, forKey: .proto)
            }
        } catch {
            let container = try decoder.singleValueContainer()
            do {
                self.proto = try container.decode(Data.self)
                return
            } catch {
                protoStr = try container.decode(String.self)
            }
        }
        guard let data = Data(base64Encoded: protoStr) else {
            throw FaceTemplateMigrationError.base64DecodingFailure
        }
        self.proto = data
    }
}
