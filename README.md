# Querywell

A native macOS (14+) database client built with Swift 6, SwiftUI and AppKit.
See ARCHITECTURE.md and DECISIONS.md for design notes.

## Requirements

- macOS 14+, Xcode 26+ (Swift 6)
- XcodeGen: `brew install xcodegen`

## Build and test

    scripts/ci.sh          # full build + tests, warnings are errors
    scripts/ci.sh --skip-xcode      # package only
    scripts/ci.sh --skip-package    # app only

## Open in Xcode

    xcodegen generate && open Querywell.xcodeproj
