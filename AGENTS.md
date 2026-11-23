# Repository Guidelines

## Project Structure

MacB is a Swift/AppKit menu-bar launcher for macOS 14 and later. The Swift Package Manager targets live under `Sources/`.

- `MacB/` wires the app together. Put capture actions in `Actions/` and radial menu views and interaction logic in `RadialMenu/`.
- `MacBKit/` holds shared code for hotkeys, configuration, permissions, and radial layout.
- `MacBClipboard/` owns clipboard history, numbered slots, persistence, and the clipboard panel.
- `MacBSelfTest/` contains the test runner and feature suites.

`Resources/Info.plist` defines app bundle metadata. The packaging script generates the app icon from `Sources/MacB/IconCommand.swift`.

## Build, Run, and Test

Run these commands from the repository root with Xcode Command Line Tools and a Swift 5.9 or later toolchain.

- `swift build` compiles the debug targets.
- `.build/debug/MacBSelfTest` runs the full suite after building. A failed check produces exit code 1.
- `Scripts/build-app.sh --run` builds and signs `build/MacB.app`, then restarts the menu-bar app. Omit `--run` to package it without launching.
- `.build/debug/MacB --snapshot /tmp/macb-shots` renders PNGs for inspecting radial menu, toast, and shortcut settings changes.

## Coding Style

Use four-space indentation, UpperCamelCase for Swift types, and lowerCamelCase for functions and properties. Name feature files after their primary type, such as `ClipboardStore.swift`. Match existing Korean terminology when editing menu labels, permission prompts, or README examples.

## Testing Guidelines

Add checks to the relevant `*Tests.swift` file using `TestRunner`, `expect`, or `expectEqual`. When adding a suite, call its `run…Tests` function from `Sources/MacBSelfTest/main.swift` so the executable runs it. Use temporary directories for persistence tests and a dedicated pasteboard for clipboard tests.

## Commits and Pull Requests

Use a short, imperative commit subject that names the behavior changed, such as `Restore clipboard selection after filtering`. In a pull request, describe the user-visible effect, link any related issue, and report the self-test result. For visual changes, attach a snapshot that shows the affected state.
