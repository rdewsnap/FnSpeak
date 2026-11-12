// swift-tools-version:5.9
import PackageDescription

// Prototype only: transcribes the bench clips with Apple's built-in speech
// recognition so fnspeak-bench can score it next to Whisper. Not part of the app.
let package = Package(
    name: "apple-speech",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "apple-speech",
            path: "Sources/apple-speech",
            linkerSettings: [
                // A command line tool needs its Info.plist inside the binary
                // for the speech recognition permission prompt to work.
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Info.plist"])
            ]
        )
    ]
)
