// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "VerID2To3Migration",
    platforms: [.iOS(.v15)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "VerID2To3Migration",
            targets: ["VerID2To3Migration"]),
    ],
    dependencies: [
        .package(url: "https://github.com/AppliedRecognition/Face-Recognition-ArcFace-Apple.git", .upToNextMajor(from: "1.1.1")),
        .package(url: "https://github.com/AppliedRecognition/Face-Recognition-Dlib-Apple.git", .upToNextMajor(from: "1.1.2"))
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "VerID2To3Migration",
            dependencies: [
                .product(name: "FaceRecognitionDlib", package: "Face-Recognition-Dlib-Apple"),
                .product(name: "FaceRecognitionArcFaceCore", package: "Face-Recognition-ArcFace-Apple")
            ]),
        .testTarget(
            name: "VerID2To3MigrationTests",
            dependencies: [
                "VerID2To3Migration",
                .product(name: "FaceRecognitionDlib", package: "Face-Recognition-Dlib-Apple"),
                .product(name: "FaceRecognitionArcFaceCore", package: "Face-Recognition-ArcFace-Apple"),
                .product(name: "FaceRecognitionArcFaceCloud", package: "Face-Recognition-ArcFace-Apple")
            ]),
    ]
)
