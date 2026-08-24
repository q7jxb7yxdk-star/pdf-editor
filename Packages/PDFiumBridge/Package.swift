// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PDFiumBridge",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "PDFiumBridge", targets: ["CPDFiumBridge"]),
    ],
    targets: [
        .binaryTarget(
            name: "PDFium",
            path: "Vendor/PDFium.xcframework"
        ),
        .target(
            name: "CPDFiumBridge",
            dependencies: ["PDFium"],
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "CPDFiumBridgeTests",
            dependencies: ["CPDFiumBridge"]
        ),
    ]
)
