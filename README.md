# Ver-ID 2 to 3 migration

Utility that helps migrating from Ver-ID SDK version 2.* to Ver-ID SDK version 3+.

## Background

Ver-ID SDK version 2 serializes face templates in a custom format. Ver-ID SDK version 3 no longer stores the face templates and it leaves the face template serialization to the SDK consumer. The face templates conform to the `Codable` protocol, allowing clients to use encoders/decoders like `JSONEncoder`/`JSONDecoder` that are built-in to iOS.

This utility helps decoding the version 2 face templates to the data structures used in the Ver-ID SDK 3 face recognition classes.

## Installation

The utility is distributed using Swift Package Manager. Simply include `https://github.com/AppliedRecognition/Ver-ID-2-3-Migration-Apple.git` as a package dependency and specify the latest version.

The utility was designed to avoid having to include Ver-ID 2 SDK dependencies. This way, if your face templates reside in the cloud, you'll be able to bring them in to your new app without having to include the sizeable Ver-ID 2 dependency.

## Usage

### Imports

```swift
// Ver-ID 2 import (optional, only if migrating templates 
// entirely on the device and are retrieving them from
// a Ver-ID 2 instance
import VerIDCore

// Ver-ID 3 imports
import VerIDCommonTypes
import VerID2To3Migration
import FaceRecognitionArcFaceCore // For v24 face templates
import FaceRecognitionDlib // For v16 face templates
```

### Converting v16 (Dlib) and v24 (ArcFace) in one call

```swift
// Get templates from Ver-ID 2
let templates: [Data] = try verID.userManagement.faces().map { 
    $0.recognitionData 
}

// Convert all templates
let converted: [any FaceTemplateProtocol] = 
    try FaceTemplateMigration.default.convertFaceTemplates(templates)

// Filter templates by version
let v16Templates = converted.filter { $0.version == 16 }
let v24Templates = converted.filter { $0.version == 24 }
```

### Converting face templates by version

```swift
// Get v24 templates from Ver-ID 2
let templates: [Data] = try verID.userManagement.faces().compactMap { 
    if $0.faceTemplateVersion == .V24 {
        return $0.recognitionData 
    } else {
        return nil
    }
}

// Convert v24 templates
// Note that face templates with other versions will be ignored
let v24Templates: [FaceTemplate<V24,[Float]>] = 
    try FaceTemplateMigration.default.convertFaceTemplatesByVersion(templates)
```

### Converting a single face template

```swift
let template: Recognizable // Your Ver-ID 2 template

if template.faceTemplateVersion == .V16 {
    let v16Template: FaceTemplate<V16,[Float]> = 
        try FaceTemplateMigration.default.convertFaceTemplate(template.data)
} else if template.faceTemplateVersion == .V24 {
    let v24Template: FaceTemplate<V24,[Float]> =
        try FaceTemplateMigration.default.convertFaceTemplate(template.data)
}
```