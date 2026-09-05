import Foundation
let root = CommandLine.arguments[1]
let app = URL(fileURLWithPath: root).appendingPathComponent("Products/Applications/AirplayAtTheCrib.app")
let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
let archive: [String: Any] = [
    "ArchiveVersion": 2,
    "CreationDate": Date(),
    "Name": "AirplayAtTheCrib",
    "SchemeName": "AirplayAtTheCrib",
    "ApplicationProperties": [
        "ApplicationPath": "Applications/AirplayAtTheCrib.app",
        "CFBundleIdentifier": info["CFBundleIdentifier"]!,
        "CFBundleShortVersionString": info["CFBundleShortVersionString"]!,
        "CFBundleVersion": info["CFBundleVersion"]!,
        "SigningIdentity": "Developer ID Application: Harivansh Rathi (G2U3K77U5W)",
        "Team": "G2U3K77U5W",
        "Architectures": ["arm64", "x86_64"]
    ]
]
try PropertyListSerialization.data(fromPropertyList: archive, format: .xml, options: 0).write(to: URL(fileURLWithPath: root).appendingPathComponent("Info.plist"))
