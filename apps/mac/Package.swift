// swift-tools-version:6.0
import PackageDescription

// Build with scripts/build-mac.sh: it compiles the Rust core, generates the
// UniFFI bindings into Sources/, and assembles FnSpeak.app.
let rustLibDir = Context.packageDirectory + "/.rust-libs"

let package = Package(
    name: "FnSpeak",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "fnspeak_ffiFFI", path: "Sources/fnspeak_ffiFFI"),
        .executableTarget(
            name: "FnSpeak",
            dependencies: ["fnspeak_ffiFFI"],
            path: "Sources/FnSpeak",
            linkerSettings: [
                .unsafeFlags([
                    "-L", rustLibDir, "-lfnspeak_ffi",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
