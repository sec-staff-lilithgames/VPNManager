//
//  VPNModels.swift
//  VPN Manager
//
//  Created by Siberia_1337 on 11/12/25.
//

import Foundation
import SystemConfiguration

struct SystemVPNService: Equatable {
    let id: String
    let name: String
    let interfaceDescription: String
    let interfaceBSDName: String?
    
    static func == (lhs: SystemVPNService, rhs: SystemVPNService) -> Bool {
        return lhs.id == rhs.id
    }
}