// swift-tools-version:6.0
import PackageDescription

// Build with scripts/build-mac.sh: it compiles the Rust core, generates the
// UniFFI bindings into Sources/, and assembles Flowstate.app.
let rustLibDir = Context.packageDirectory + "/.rust-libs"

let package = Package(
    name: "Flowstate",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "flowstate_ffiFFI", path: "Sources/flowstate_ffiFFI"),
        .executableTarget(
            name: "Flowstate",
            dependencies: ["flowstate_ffiFFI"],
            path: "Sources/Flowstate",
            linkerSettings: [
                .unsafeFlags([
                    "-L", rustLibDir, "-lflowstate_ffi",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
