//
//  AVAData32.swift
//  web3.swift
//
//  Created by IntrodexMac on 6/12/2565 BE.
//

import Foundation

public struct AVAData32: ABIType {
    
    public static var rawType: ABIRawType {
        .FixedBytes(32)
    }
    
    public static var parser: ParserFunction = { data in
        let first = data.first ?? ""
        return try ABIDecoder.decode(first,
                                     to: Data.self)
    }
    
    public let rawValue: Data
    
    public init(data: Data) {
        self.rawValue = data
    }
    
}



