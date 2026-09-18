# Offline Music

An original premium offline music player for iPhone, built with SwiftUI, AVFoundation, and MediaPlayer. The app is local-first: imported audio is copied into the app's Documents folder and library state is persisted as JSON.

## Requirements

- Xcode 26 on a macOS GitHub Actions runner
- iOS 17.0 or later (modern SwiftUI APIs; compatible with iPhone 11 on current iOS)

## Build

Open `OfflineMusic.xcodeproj` in Xcode and select the Offline Music scheme. The repository also includes `.github/workflows/build-ios.yml`, which builds an unsigned iPhoneOS archive and packages it as an IPA artifact.
