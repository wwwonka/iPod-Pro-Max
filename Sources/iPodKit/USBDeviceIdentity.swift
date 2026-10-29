//
//  USBDeviceIdentity.swift
//  iPod Pro Max
//
//  The USB device behind a mounted iPod (found per OS by DeviceKit), and what it tells about the model.
//

import Foundation

public struct USBDeviceIdentity: Sendable, Hashable {
    public let vendorID: Int
    public let productID: Int
    public let serialNumber: String?
    public let productName: String?

    public var isApple: Bool { vendorID == 0x05AC }

    /// On the classic and nano 3G/4G the USB serial number is the FireWire GUID (16 hex digits).
    public var firewireGUIDFromSerial: String? {
        guard let s = serialNumber?.trimmingCharacters(in: .whitespaces), s.count == 16,
              s.allSatisfy(\.isHexDigit) else { return nil }
        return s
    }

    /// Generation by Apple USB product id (from the USB ID repository and libgpod/podsleuth).
    public var generation: IPodGeneration? {
        guard isApple else { return nil }
        switch productID {
        case 0x1201: return .third
        case 0x1202: return .second
        case 0x1203: return .fourth
        case 0x1204: return .photo
        case 0x1205: return .mini1
        case 0x1206: return .mini2
        case 0x1207: return .fourth
        case 0x1208: return .photo
        case 0x1209: return .video1
        case 0x120A: return .nano1
        case 0x1240, 0x1260: return .nano2
        case 0x1261: return .classic1
        case 0x1262: return .nano3
        case 0x1263: return .nano4
        case 0x1265: return .nano5
        case 0x1266: return .nano6
        case 0x1267: return .nano7
        case 0x1300: return .shuffle1
        case 0x1301: return .shuffle2
        case 0x1302: return .shuffle3
        case 0x1303: return .shuffle4
        case 0x1290, 0x1292, 0x1294, 0x1297, 0x129A, 0x129C, 0x12A0: return .iphone
        case 0x1291, 0x1293, 0x1299, 0x129E, 0x129F: return .touch
        default: return nil
        }
    }

    public init(vendorID: Int, productID: Int, serialNumber: String?, productName: String?) {
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.productName = productName
    }
}
