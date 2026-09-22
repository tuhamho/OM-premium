# Spotúfy

Spotúfy is a premium, local-first music player for iPhone. It is built with SwiftUI, AVFoundation, and MediaPlayer for reliable offline playback, background audio, and lock-screen controls.

## App preview

The current app includes a dark OLED-friendly interface with four primary areas:

- **Home** — quick picks, Discover from Your Library, recently played, recently added, albums, and favorites.
- **Library** — searchable Songs, Artists, Albums, and Favorites views with artwork and metadata.
- **Playlists** — create playlists and manage local songs.
- **Settings** — playback speed, resume previous session, theme/accent controls, library tools, and insights.

## Screenshots

<table>
  <tr>
    <td align="center" valign="top"><h2>🏠 HOME</h2><strong>Quick picks & Discover</strong><br><img src="docs/screenshots/anh1.png" alt="Home" width="220"></td>
    <td align="center" valign="top"><h2>🎵 SONGS</h2><strong>Searchable library</strong><br><img src="docs/screenshots/anh2.png" alt="Library songs" width="220"></td>
    <td align="center" valign="top"><h2>👥 ARTISTS</h2><strong>Browse by artist</strong><br><img src="docs/screenshots/anh3.png" alt="Library artists" width="220"></td>
  </tr>
  <tr>
    <td align="center" valign="top"><h2>💿 ALBUMS</h2><strong>Album collections</strong><br><img src="docs/screenshots/anh4.png" alt="Library albums" width="220"></td>
    <td align="center" valign="top"><h2>♥ FAVORITES</h2><strong>Your favorite tracks</strong><br><img src="docs/screenshots/anh5.png" alt="Library favorites" width="220"></td>
    <td align="center" valign="top"><h2>📚 PLAYLISTS</h2><strong>Organize your music</strong><br><img src="docs/screenshots/anh6.png" alt="Playlists" width="220"></td>
  </tr>
  <tr>
    <td align="center" valign="top"><h2>⚙ SETTINGS</h2><strong>Playback & appearance</strong><br><img src="docs/screenshots/anh7.png" alt="Settings" width="220"></td>
    <td align="center" valign="top"><h2>📊 INSIGHTS</h2><strong>Library statistics</strong><br><img src="docs/screenshots/anh8.png" alt="Library insights" width="220"></td>
    <td align="center" valign="top"><h2>▶ NOW PLAYING</h2><strong>Playback controls</strong><br><img src="docs/screenshots/anh9.png" alt="Now playing" width="220"></td>
  </tr>
</table>

## Highlights

- Offline playback from the app's Documents directory.
- Background audio and Control Center / lock-screen controls.
- Queue management with Play Next, Add to Queue, shuffle, repeat, and previous-track history.
- Rolling **Discover from Your Library** recommendations.
- Embedded MP3/M4A metadata and artwork extraction.
- Filename metadata fallback with Vietnamese diacritic-insensitive search.
- MusicBrainz, Cover Art Archive, and Apple/iTunes artwork fallback with local caching.
- Artist and album grouping derived from the live library.
- Playlists, favorites, listening history, lyrics, and synchronized local `.lrc` files.
- Library statistics and listening insights.
- File Sharing support through the iOS Documents directory.

## Requirements

- Xcode 26
- iOS 17.0 or later
- A macOS environment for building the iOS target

The app is designed to run well on iPhone 11 and newer devices that support iOS 17.

## Build locally

Open `OfflineMusic.xcodeproj` in Xcode and select the **Offline Music** scheme.

For a device Release build without Apple Developer signing:

```sh
xcodebuild \
  -project OfflineMusic.xcodeproj \
  -scheme "Offline Music" \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build \
  ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
```

The GitHub Actions workflow in `.github/workflows/build-ios.yml` builds the device app and packages the resulting `.app` as an IPA artifact.

## Local music and File Sharing

Imported audio is stored under the app's Documents directory so it can be managed through iTunes, Finder, 3uTools, or Windows File Sharing. Supported formats include MP3, M4A, AAC, WAV, CAF, and AIFF.

## Project structure

```text
OfflineMusic/
├── Models.swift       # Songs, playlists, lyrics, themes, and search models
├── Services.swift     # MusicStore, metadata, artwork, scanning, and playback services
├── Views.swift        # SwiftUI screens and reusable song views
└── Assets.xcassets/   # App icon and brand assets
```

## License

This repository is an independent personal project. Add a license before distributing it publicly.
