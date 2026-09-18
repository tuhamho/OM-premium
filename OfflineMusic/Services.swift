import Foundation
import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

@MainActor final class MusicStore: ObservableObject {
    @Published var songs: [Song] = []
    @Published var playlists: [Playlist] = []
    @Published var recentlyPlayed: [UUID] = []
    @Published var currentSongID: UUID?
    @Published var savedPosition: Double = 0
    @Published var resumeSession = true
    @Published var oledTheme = false
    @Published var accent = Color.lime
    @Published var isScanning = false
    @Published var scanProgress = 0
    @Published var scanTotal = 0
    @Published var scanMessage = ""
    @Published var debugLines: [String] = []
    @Published var isDebuggingSong = false
    @Published var showDebugPanel = false
    @Published var isFetchingArtwork = false
    @Published var artworkFetchProgress = 0
    @Published var artworkFetchTotal = 0
    @Published var artworkFetchSummary = ""

    private let stateURL: URL
    private let fm = FileManager.default
    private weak var player: AudioPlayerService?

    init() {
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        stateURL = support.appendingPathComponent("library.json")
    }

    var audioDirectory: URL {
        let dir = documentsDirectory.appendingPathComponent("Audio")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var documentsDirectory: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    func documentURL(for fileName: String) -> URL {
        let url = documentsDirectory.appendingPathComponent(fileName)
        if fm.fileExists(atPath: url.path) { return url }
        return audioDirectory.appendingPathComponent(fileName)
    }

    private func relativeDocumentPath(for url: URL) -> String {
        let prefix = documentsDirectory.path.hasSuffix("/") ? documentsDirectory.path : documentsDirectory.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    func load() async {
        guard let data = try? Data(contentsOf: stateURL), let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        songs = state.songs; playlists = state.playlists; recentlyPlayed = state.recentlyPlayed; currentSongID = state.currentSongID; savedPosition = state.savedPosition
        for index in songs.indices where songs[index].artworkData == nil {
            songs[index].artworkData = await ArtworkCache.shared.data(for: songs[index].id.uuidString)
        }
    }

    func save() {
        let state = PersistedState(songs: songs, playlists: playlists, recentlyPlayed: recentlyPlayed, currentSongID: currentSongID, savedPosition: savedPosition)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }

    func attach(player: AudioPlayerService) {
        self.player = player
    }

    func startSongDebug(_ song: Song) {
        showDebugPanel = true
        Task { await identifyAndFetchArtwork(for: song.id) }
    }

    func importFiles(_ urls: [URL]) async -> Int {
        var imported = 0
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }
            let name = url.lastPathComponent
            if songs.contains(where: { $0.fileName == name }) { continue }
            let destination = audioDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
            do {
                try fm.copyItem(at: url, to: destination)
                let asset = AVURLAsset(url: destination)
                var metadata = try await MetadataService.read(asset: asset, fileName: name)
                metadata.artworkData = ArtworkCache.resizedArtwork(metadata.artworkData)
                metadata.fileName = relativeDocumentPath(for: destination)
                songs.append(metadata)
                if let artwork = metadata.artworkData { await ArtworkCache.shared.store(artwork, for: metadata.id.uuidString) }
                imported += 1
            } catch { continue }
        }
        save()
        return imported
    }

    func rescanDocuments() async {
        guard !isScanning else { return }

        isScanning = true
        scanProgress = 0
        scanTotal = 0
        scanMessage = ""

        let documentsURL = documentsDirectory
        print("Documents:", documentsURL.path)

        let audioFiles = await Task.detached(priority: .utility) {
            Self.enumerateAudioFiles(in: documentsURL)
        }.value

        print("Audio files found:", audioFiles.count)
        scanTotal = audioFiles.count

        let foundPaths = Set(audioFiles.map { relativeDocumentPath(for: $0) })
        let missingIDs = songs.compactMap { song in
            foundPaths.contains(song.fileName) || fm.fileExists(atPath: documentURL(for: song.fileName).path) ? nil : song.id
        }
        if !missingIDs.isEmpty {
            songs.removeAll { missingIDs.contains($0.id) }
            recentlyPlayed.removeAll { missingIDs.contains($0) }
            playlists.indices.forEach { index in
                playlists[index].songIDs.removeAll { missingIDs.contains($0) }
            }
        }

        let knownPaths = Set(songs.map(\.fileName))
        var importedCount = 0
        for url in audioFiles {
            scanProgress += 1
            let relativePath = relativeDocumentPath(for: url)

            do {
                var metadata = try await MetadataService.read(
                    asset: AVURLAsset(url: url),
                    fileName: url.lastPathComponent
                )
                metadata.artworkData = ArtworkCache.resizedArtwork(metadata.artworkData)
                metadata.fileName = relativePath
                if let index = songs.firstIndex(where: { $0.fileName == relativePath || (!knownPaths.contains(relativePath) && $0.fileName == url.lastPathComponent) }) {
                    let existing = songs[index]
                    metadata.id = existing.id
                    metadata.importedAt = existing.importedAt
                    metadata.lastPlayed = existing.lastPlayed
                    metadata.playCount = existing.playCount
                    metadata.isFavorite = existing.isFavorite
                    if metadata.artworkData == nil { metadata.artworkData = existing.artworkData }
                    songs[index] = metadata
                } else {
                    songs.append(metadata)
                    importedCount += 1
                }
                if let artwork = metadata.artworkData {
                    await ArtworkCache.shared.store(artwork, for: metadata.id.uuidString)
                }
            } catch {
                print("Metadata failed for \(url.lastPathComponent):", error)
            }
        }

        save()
        isScanning = false
        scanMessage = "Scan complete — \(songs.count) songs found"
        print("Library songs:", songs.count, "(imported:", importedCount, ")")
    }

    func identifyAndFetchArtwork(for id: UUID) async {
        guard !isDebuggingSong else { return }
        guard let index = songs.firstIndex(where: { $0.id == id }) else { return }
        isDebuggingSong = true
        debugLines = ["Parsing filename...", "File: \(songs[index].fileName)"]
        defer { isDebuggingSong = false }

        let song = songs[index]
        let hasEmbeddedArtwork = song.artworkData != nil
        let result = await ArtworkLookupService.shared.lookup(for: song)
        debugLines.append(contentsOf: result.logs)

        guard result.candidate != nil || result.artwork != nil else {
            debugLines.append("Song not changed")
            return
        }

        await applyArtworkResult(result, for: song.id, preserveEmbeddedArtwork: hasEmbeddedArtwork)
        debugLines.append("Song updated")
        debugLines.append("Saved successfully")
    }

    func fetchMissingArtwork() async {
        guard !isFetchingArtwork else { return }
        let ids = songs.filter { $0.artworkData == nil }.map(\.id)
        isFetchingArtwork = true
        artworkFetchProgress = 0
        artworkFetchTotal = ids.count
        artworkFetchSummary = ""
        var musicBrainzCount = 0
        var appleCount = 0
        var noneCount = 0

        for id in ids {
            guard let song = songs.first(where: { $0.id == id }) else { continue }
            let result = await ArtworkLookupService.shared.lookup(for: song)
            if result.artwork != nil {
                if result.source == .musicBrainz { musicBrainzCount += 1 }
                if result.source == .apple { appleCount += 1 }
                await applyArtworkResult(result, for: id, preserveEmbeddedArtwork: false)
            } else {
                noneCount += 1
            }
            artworkFetchProgress += 1
        }

        isFetchingArtwork = false
        artworkFetchSummary = "MusicBrainz artwork: \(musicBrainzCount) • Apple fallback: \(appleCount) • No artwork: \(noneCount)"
    }

    private func applyArtworkResult(_ result: ArtworkLookupResult, for id: UUID, preserveEmbeddedArtwork: Bool) async {
        guard let index = songs.firstIndex(where: { $0.id == id }) else { return }
        var updated = songs[index]
        if result.applyFilenameMetadata, let candidate = result.candidate {
            updated.title = candidate.title
            updated.artist = candidate.artist
        }
        if updated.album == "Unknown Album", let album = result.album { updated.album = album }
        if result.applyFilenameMetadata, let albumArtist = result.albumArtist { updated.albumArtist = albumArtist }
        if updated.albumArtist.isEmpty || updated.albumArtist == "Unknown Artist", let albumArtist = result.albumArtist { updated.albumArtist = albumArtist }
        if let artwork = result.artwork, !preserveEmbeddedArtwork {
            await ArtworkCache.shared.store(artwork, for: updated.id.uuidString)
            updated.artworkData = artwork
        }

        songs[index] = updated
        objectWillChange.send()
        save()
        player?.syncCurrentSong(updated)
    }

    func testMusicBrainzConnection() async {
        showDebugPanel = true
        isDebuggingSong = true
        debugLines = ["Testing MusicBrainz Connection..."]
        let result = await ArtworkLookupService.shared.testConnection()
        debugLines.append(contentsOf: result)
        isDebuggingSong = false
    }

    nonisolated private static func enumerateAudioFiles(in documentsURL: URL) -> [URL] {
        let supportedExtensions = Set(["mp3", "m4a", "aac", "wav", "caf", "aiff"])
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: documentsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  supportedExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { return nil }
            return url
        }
    }

    func toggleFavorite(_ song: Song) { update(song.id) { $0.isFavorite.toggle() }; save() }
    func update(_ id: UUID, _ change: (inout Song) -> Void) {
        guard let i = songs.firstIndex(where: { $0.id == id }) else { return }
        change(&songs[i])
        objectWillChange.send()
    }
    func song(_ id: UUID?) -> Song? { songs.first { $0.id == id } }
    var artistGroups: [ArtistGroup] {
        let grouped = Dictionary(grouping: songs) { artistKey(for: $0.displayArtist) }
        return grouped.map { key, songs in
            let sortedSongs = sortSongs(songs)
            return ArtistGroup(
                id: key,
                name: displayArtistName(from: songs),
                songs: sortedSongs
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var albumGroups: [AlbumGroup] {
        let grouped = Dictionary(grouping: songs) { song in
            let artist = song.albumArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? song.displayArtist : song.albumArtist
            return "\(artistKey(for: artist))\u{1F}\(albumKey(for: song.displayAlbum))"
        }
        return grouped.map { key, songs in
            let first = songs[0]
            let artist = first.albumArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? first.displayArtist : first.albumArtist
            return AlbumGroup(
                id: key,
                name: displayAlbumName(from: songs),
                artist: artist.trimmingCharacters(in: .whitespacesAndNewlines),
                songs: sortSongs(songs)
            )
        }
        .sorted {
            let albumOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            return albumOrder == .orderedSame
                ? $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending
                : albumOrder == .orderedAscending
        }
    }

    func songs(forArtist name: String) -> [Song] {
        let key = artistKey(for: name)
        return sortSongs(songs.filter { artistKey(for: $0.displayArtist) == key })
    }

    private func artistKey(for value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? "Unknown Artist" : trimmed
        return display.precomposedStringWithCanonicalMapping.lowercased(with: .current)
    }

    private func albumKey(for value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? "Unknown Album" : trimmed
        return display.precomposedStringWithCanonicalMapping.lowercased(with: .current)
    }

    private func displayArtistName(from songs: [Song]) -> String {
        let value = songs.first?.displayArtist.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Unknown Artist" : value
    }

    private func displayAlbumName(from songs: [Song]) -> String {
        let value = songs.first?.displayAlbum.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Unknown Album" : value
    }

    private func sortSongs(_ values: [Song]) -> [Song] {
        values.sorted {
            let albumOrder = $0.displayAlbum.localizedCaseInsensitiveCompare($1.displayAlbum)
            if albumOrder != .orderedSame { return albumOrder == .orderedAscending }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }
    func markPlayed(_ id: UUID) { update(id) { $0.playCount += 1; $0.lastPlayed = .now }; recentlyPlayed.removeAll { $0 == id }; recentlyPlayed.insert(id, at: 0); recentlyPlayed = Array(recentlyPlayed.prefix(30)); currentSongID = id; save() }
    func delete(_ song: Song) { try? fm.removeItem(at: documentURL(for: song.fileName)); songs.removeAll { $0.id == song.id }; playlists.indices.forEach { playlists[$0].songIDs.removeAll { $0 == song.id } }; save() }
    func addPlaylist(name: String) { playlists.append(Playlist(name: name)); save() }
    func songs(in playlist: Playlist) -> [Song] { playlist.songIDs.compactMap(song) }
}

private struct PersistedState: Codable { var songs: [Song]; var playlists: [Playlist]; var recentlyPlayed: [UUID]; var currentSongID: UUID?; var savedPosition: Double }

struct MetadataService {
    static func read(asset: AVURLAsset, fileName: String) async throws -> Song {
        let duration = try await asset.load(.duration).seconds
        let commonItems = try await asset.load(.commonMetadata)
        let formatItems = try await asset.load(.metadata)
        let items = formatItems + commonItems

        func value(_ identifier: AVMetadataIdentifier) -> String {
            items.first(where: { $0.identifier == identifier })?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        func value(containing text: String) -> String {
            items.first {
                $0.identifier?.rawValue.localizedCaseInsensitiveContains(text) == true
            }?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        let fallback = filenameCandidates(for: fileName).first ?? FilenameCandidate(artist: "Unknown Artist", title: "Unknown Title")
        let title = value(.commonIdentifierTitle).isEmpty ? fallback.title : value(.commonIdentifierTitle)
        let artist = value(.commonIdentifierArtist).isEmpty ? fallback.artist : value(.commonIdentifierArtist)
        let album = value(.commonIdentifierAlbumName).isEmpty ? "Unknown Album" : value(.commonIdentifierAlbumName)
        let albumArtist = value(containing: "albumartist").isEmpty ? artist : value(containing: "albumartist")
        let artwork = items.first {
            $0.commonKey == .commonKeyArtwork || ($0.identifier?.rawValue.localizedCaseInsensitiveContains("artwork") == true)
        }?.dataValue

        return Song(
            title: title.isEmpty ? "Unknown Title" : title,
            artist: artist.isEmpty ? "Unknown Artist" : artist,
            album: album,
            albumArtist: albumArtist,
            duration: duration.isFinite ? duration : 0,
            fileName: fileName,
            artworkData: artwork
        )
    }

    static func filenameCandidates(for fileName: String) -> [FilenameCandidate] {
        var name = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        name = name.replacingOccurrences(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}-"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"\[[^\]]*\]|\([^\)]*\)|\{[^\}]*\}"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"^\s*\d+\s*[-_.]\s*"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"(?i)\b(official\s+lyrics?\s+video|official\s+music\s+video|official\s+visuali[sz]er|official\s+mv|official\s+audio|official\s+video|visuali[sz]er|lyrics?|lyric\s+video|mv|audio|video|hd|4k)\b"#, with: "", options: .regularExpression)
        name = trimFilenameJunk(name)

        let separators = [" - ", " – ", " — ", " | "]
        for separator in separators {
            if let range = name.range(of: separator) {
                let first = trimFilenameJunk(String(name[..<range.lowerBound]))
                let second = trimFilenameJunk(String(name[range.upperBound...]))
                if !first.isEmpty && !second.isEmpty {
                    return [
                        FilenameCandidate(artist: first, title: second),
                        FilenameCandidate(artist: second, title: first)
                    ]
                }
            }
        }
        return [FilenameCandidate(artist: "Unknown Artist", title: name.isEmpty ? "Unknown Title" : name)]
    }

    private static func trimFilenameJunk(_ value: String) -> String {
        var result = value
        result = result.replacingOccurrences(of: #"(?i)\b(official\s+lyrics?\s+video|official\s+music\s+video|official\s+visuali[sz]er|official\s+mv|official\s+audio|official\s+video|visuali[sz]er|lyrics?|lyric\s+video|mv|audio|video|hd|4k)\b"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        result = result.replacingOccurrences(of: #"[|#_•:;]+$"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"^[|#_•:;]+"#, with: "", options: .regularExpression)
        return result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct FilenameCandidate: Sendable {
    let artist: String
    let title: String
}

actor ArtworkCache {
    static let shared = ArtworkCache()
    private let directory: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = base.appendingPathComponent("ArtworkCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func data(for key: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(key).appendingPathExtension("jpg"))
    }

    func store(_ data: Data, for key: String) {
        let url = directory.appendingPathComponent(key).appendingPathExtension("jpg")
        try? data.write(to: url, options: .atomic)
        print("Artwork cache path:", url.path)
    }

    nonisolated static func resizedArtwork(_ data: Data?, maxDimension: CGFloat = 600) -> Data? {
        guard let data, let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.jpegData(withCompressionQuality: 0.88) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

actor ArtworkLookupService {
    static let shared = ArtworkLookupService()
    private var lastMusicBrainzRequest = Date.distantPast
    private var debugLogs: [String] = []

    func lookup(for song: Song) async -> ArtworkLookupResult {
        debugLogs = ["Searching MusicBrainz..."]
        guard song.title != "Unknown Title" else {
            debugLogs.append("No usable title")
            return ArtworkLookupResult(candidate: nil, album: nil, albumArtist: nil, artwork: nil, applyFilenameMetadata: false, source: .none, logs: debugLogs)
        }
        let match = await matchingRelease(for: song)
        var artwork: Data?
        if let match {
            for releaseID in match.releaseIDs {
                guard let url = URL(string: "https://coverartarchive.org/release/\(releaseID)/front-500") else { continue }
                print("Cover Art Archive URL:", url.absoluteString)
                debugLogs.append("Fetching cover art release \(releaseID)...")
                debugLogs.append("Cover Art Archive URL: \(url.absoluteString)")
                var request = URLRequest(url: url)
                request.setValue("OfflineMusic/1.0 (local music library)", forHTTPHeaderField: "User-Agent")
                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    print("Artwork HTTP status:", status)
                    debugLogs.append("Artwork HTTP status: \(status)")
                    if status == 200 {
                        artwork = ArtworkCache.resizedArtwork(data)
                        print("Artwork decoding:", artwork == nil ? "failed" : "succeeded")
                        debugLogs.append(artwork == nil ? "Image decode failed" : "Artwork decoded")
                        if artwork != nil { break }
                    }
                } catch {
                    print("Artwork lookup failed:", error)
                    debugLogs.append("Cover Art Archive error: \(error.localizedDescription)")
                }
            }
        }
        if let match {
            debugLogs.append(artwork == nil ? "MusicBrainz match found, artwork missing" : "MusicBrainz artwork found")
            print("MusicBrainz selected recording score:", match.score, "candidate:", match.candidate.artist, "/", match.candidate.title)
        } else {
            debugLogs.append("No acceptable MusicBrainz candidate")
        }

        if artwork == nil {
            if let apple = await AppleArtworkService.shared.lookup(for: song) {
                artwork = apple.artwork
                debugLogs.append(contentsOf: apple.logs)
                return ArtworkLookupResult(candidate: match?.candidate, album: match?.album, albumArtist: match?.albumArtist, artwork: artwork, applyFilenameMetadata: match?.applyFilenameMetadata ?? false, source: .apple, logs: debugLogs)
            }
            debugLogs.append("Apple fallback found no confident artwork")
        }

        return ArtworkLookupResult(candidate: match?.candidate, album: match?.album, albumArtist: match?.albumArtist, artwork: artwork, applyFilenameMetadata: match?.applyFilenameMetadata ?? false, source: artwork == nil ? .none : .musicBrainz, logs: debugLogs)
    }

    func testConnection() async -> [String] {
        let query = "artist:\"The Beatles\" AND recording:\"Yesterday\""
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/recording/")
        components?.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "fmt", value: "json"), URLQueryItem(name: "limit", value: "1")]
        guard let url = components?.url else { return ["Could not create test URL"] }
        let userAgent = "OfflineMusic/1.0 (local music library)"
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let decoded = (try? JSONDecoder().decode(MusicBrainzResponse.self, from: data)) != nil
            let decodedText = decoded ? "yes" : "no"
            return ["Request URL: \(url.absoluteString)", "User-Agent sent: \(userAgent)", "HTTP status: \(status)", "Response received: yes (\(data.count) bytes)", "JSON decoded: \(decodedText)"]
        } catch {
            return ["Request URL: \(url.absoluteString)", "User-Agent sent: \(userAgent)", "Response received: no", "Network error: \(error.localizedDescription)"]
        }
    }

    private func matchingRelease(for song: Song) async -> MusicBrainzMatch? {
        let parsedCandidates = MetadataService.filenameCandidates(for: song.fileName)
        let current = FilenameCandidate(artist: song.artist, title: song.title)
        let filenameFallback = current.artist == "Unknown Artist" || parsedCandidates.contains(where: { normalized($0.artist) == normalized(current.artist) && normalized($0.title) == normalized(current.title) })
        let candidates = filenameFallback ? parsedCandidates : [current]

        var matches: [MusicBrainzMatch] = []
        for candidate in candidates {
            if let match = await searchMusicBrainz(for: candidate, duration: song.duration) {
                matches.append(match)
            }
        }
        guard var best = matches.max(by: { $0.confidence < $1.confidence }) else {
            debugLogs.append("No MusicBrainz candidate passed the confidence threshold")
            return nil
        }
        let secondBest = matches.filter { $0.candidate.artist != best.candidate.artist || $0.candidate.title != best.candidate.title }.max(by: { $0.confidence < $1.confidence })
        if let secondBest {
            debugLogs.append("Best candidate: \(best.score), second-best: \(secondBest.score)")
        } else {
            debugLogs.append("Best candidate: \(best.score), second-best: none")
        }
        guard secondBest == nil || best.confidence - secondBest!.confidence >= 12 else {
            debugLogs.append("Result rejected: candidates were too close")
            return nil
        }
        print("MusicBrainz selected candidate:", best.candidate.artist, "/", best.candidate.title, "score:", best.score, "release IDs:", best.releaseIDs)
        debugLogs.append("Selected: \(best.candidate.artist) - \(best.candidate.title)")
        let releaseList = best.releaseIDs.joined(separator: ", ")
        debugLogs.append("Release IDs: \(releaseList)")
        best.applyFilenameMetadata = filenameFallback
        return best
    }

    private func searchMusicBrainz(for candidate: FilenameCandidate, duration: Double) async -> MusicBrainzMatch? {
        let artist = candidate.artist == "Unknown Artist" ? "" : candidate.artist
        let query = artist.isEmpty ? "recording:\"\(candidate.title)\"" : "artist:\"\(artist)\" AND recording:\"\(candidate.title)\""
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/recording/")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "5")
        ]
        guard let url = components?.url else { return nil }

        let wait = max(0, 1.0 - Date().timeIntervalSince(lastMusicBrainzRequest))
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        lastMusicBrainzRequest = Date()

        var request = URLRequest(url: url)
        let userAgent = "OfflineMusic/1.0 (local music library)"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        debugLogs.append("MusicBrainz request URL: \(url.absoluteString)")
        debugLogs.append("User-Agent sent: \(userAgent)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            debugLogs.append("MusicBrainz network error: \(error.localizedDescription)")
            return nil
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        debugLogs.append("MusicBrainz HTTP status: \(status)")
        debugLogs.append("MusicBrainz response bytes: \(data.count)")
        guard status == 200 else { return nil }
        guard let result = try? JSONDecoder().decode(MusicBrainzResponse.self, from: data) else {
            debugLogs.append("MusicBrainz JSON decode failed")
            return nil
        }
        debugLogs.append("MusicBrainz recordings returned: \(result.recordings.count)")
        if let highestScore = result.recordings.compactMap(\.score).max(), highestScore < 90 {
            debugLogs.append("Best candidate: \(highestScore), required: 90, result rejected")
        }

        for recording in result.recordings.prefix(5) {
            let artist = recording.artistCredit?.compactMap { $0.name ?? $0.artist?.name }.joined(separator: ", ") ?? "Unknown Artist"
            let releases = recording.releases?.compactMap(\.id).joined(separator: ", ") ?? "none"
            let duration = recording.length.map { "\(Double($0) / 1000)s" } ?? "unknown duration"
            let candidateTitle = recording.title ?? ""
            debugLogs.append("Candidate: \(candidateTitle) — \(artist), score \(recording.score ?? 0), releases \(releases), duration \(duration)")
        }

        let title = normalized(candidate.title)
        let normalizedArtist = normalized(candidate.artist)
        let matches = result.recordings
            .compactMap { recording -> MusicBrainzMatch? in
                let resultTitle = normalized(recording.title ?? "")
                let resultArtist = normalized(recording.artistCredit?.compactMap { $0.name ?? $0.artist?.name }.joined(separator: " ") ?? "")
                let titleSimilarity = similarity(resultTitle, title)
                let artistSimilarity = normalizedArtist == "unknownartist" ? 1 : similarity(resultArtist, normalizedArtist)
                guard (recording.score ?? 0) >= 90, titleSimilarity >= 0.8, artistSimilarity >= 0.8,
                      let release = recording.releases?.first else { return nil }
                var confidence = Double(recording.score ?? 0) + titleSimilarity * 20 + artistSimilarity * 20
                if let length = recording.length, duration > 0 {
                    let difference = abs(Double(length) / 1000 - duration)
                    if difference <= 5 { confidence += 10 }
                    if difference > 30 { confidence -= 10 }
                }
                let releaseIDs = recording.releases?.compactMap(\.id) ?? []
                print("MusicBrainz candidate:", candidate.artist, "/", candidate.title, "score:", recording.score ?? 0, "recording:", recording.title ?? "", "release IDs:", releaseIDs)
                let albumArtist = release.artistCredit?.compactMap { $0.name ?? $0.artist?.name }.joined(separator: " ")
                return MusicBrainzMatch(candidate: candidate, releaseIDs: releaseIDs, score: recording.score ?? 0, confidence: confidence, album: release.title, albumArtist: albumArtist)
            }
        return matches.max(by: { $0.confidence < $1.confidence })
    }

    private func similarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if lhs == rhs { return 1 }
        if lhs.contains(rhs) || rhs.contains(lhs) { return 0.9 }
        return 0
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }
}

struct ArtworkLookupResult {
    let candidate: FilenameCandidate?
    let album: String?
    let albumArtist: String?
    let artwork: Data?
    let applyFilenameMetadata: Bool
    let source: ArtworkSource
    let logs: [String]
}

enum ArtworkSource: Equatable {
    case none
    case musicBrainz
    case apple
}

actor AppleArtworkService {
    static let shared = AppleArtworkService()
    private var lastRequest = Date.distantPast

    func lookup(for song: Song) async -> AppleArtworkResult? {
        let artist = song.artist == "Unknown Artist" ? "" : song.artist
        let query = [artist, song.title].filter { !$0.isEmpty }.joined(separator: " ")
        guard !query.isEmpty else { return nil }

        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "country", value: "VN")
        ]
        guard let url = components?.url else { return nil }

        var logs = ["Apple fallback query: \(query)", "Apple request URL: \(url.absoluteString)"]
        let wait = max(0, 1.0 - Date().timeIntervalSince(lastRequest))
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        lastRequest = Date()
        var request = URLRequest(url: url)
        request.setValue("OfflineMusic/1.0 (local music library)", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            logs.append("Apple request failed: \(error.localizedDescription)")
            print(logs.joined(separator: "\n"))
            return nil
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        logs.append("Apple HTTP status: \(status)")
        guard status == 200, let decoded = try? JSONDecoder().decode(AppleSearchResponse.self, from: data) else {
            logs.append("Apple response could not be decoded")
            print(logs.joined(separator: "\n"))
            return nil
        }
        logs.append("Apple results: \(decoded.results.count)")

        let expectedTitle = normalized(song.title)
        let expectedArtist = normalized(artist)
        let candidates = decoded.results.compactMap { result -> (AppleTrack, Double)? in
            guard let resultTitle = result.trackName, let resultArtist = result.artistName else { return nil }
            let titleScore = similarity(normalized(resultTitle), expectedTitle)
            let artistScore = expectedArtist.isEmpty ? 1 : similarity(normalized(resultArtist), expectedArtist)
            let durationScore: Double
            if song.duration > 0, let milliseconds = result.trackTimeMillis {
                let difference = abs(Double(milliseconds) / 1000 - song.duration)
                durationScore = difference <= 5 ? 1 : max(0, 1 - difference / 60)
            } else {
                durationScore = 0.5
            }
            let confidence = titleScore * 0.55 + artistScore * 0.35 + durationScore * 0.10
            return (result, confidence)
        }
        guard let best = candidates.max(by: { $0.1 < $1.1 }), best.1 >= 0.78 else {
            logs.append("Apple result rejected: no confident match")
            print(logs.joined(separator: "\n"))
            return nil
        }

        let selected = best.0
        let selectedTitle = selected.trackName ?? ""
        let selectedArtist = selected.artistName ?? ""
        logs.append("Apple selected: \(selectedTitle) — \(selectedArtist)")
        logs.append(String(format: "Apple confidence: %.0f%%", best.1 * 100))
        guard let artworkURL = selected.artworkURL else {
            logs.append("Apple selected result has no artwork URL")
            print(logs.joined(separator: "\n"))
            return nil
        }
        logs.append("Apple artwork URL: \(artworkURL.absoluteString)")
        do {
            let (artworkData, artworkResponse) = try await URLSession.shared.data(from: artworkURL)
            let artworkStatus = (artworkResponse as? HTTPURLResponse)?.statusCode ?? -1
            logs.append("Apple artwork HTTP status: \(artworkStatus)")
            guard artworkStatus == 200 else { return nil }
            let resized = ArtworkCache.resizedArtwork(artworkData)
            logs.append(resized == nil ? "Apple artwork decoding failed" : "Apple artwork downloaded")
            print(logs.joined(separator: "\n"))
            guard let resized else { return nil }
            return AppleArtworkResult(artwork: resized, logs: logs)
        } catch {
            logs.append("Apple artwork download failed: \(error.localizedDescription)")
            print(logs.joined(separator: "\n"))
            return nil
        }
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }

    private func similarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if lhs == rhs { return 1 }
        if lhs.contains(rhs) || rhs.contains(lhs) { return 0.9 }
        return 0
    }
}

struct AppleArtworkResult {
    let artwork: Data
    let logs: [String]
}

private struct AppleSearchResponse: Decodable {
    let results: [AppleTrack]
}

private struct AppleTrack: Decodable {
    let trackName: String?
    let artistName: String?
    let trackTimeMillis: Int?
    let artworkUrl100: String?

    var artworkURL: URL? {
        guard let artworkUrl100 else { return nil }
        return URL(string: artworkUrl100.replacingOccurrences(of: "100x100bb", with: "1200x1200bb"))
    }
}

private struct MusicBrainzMatch {
    let candidate: FilenameCandidate
    let releaseIDs: [String]
    let score: Int
    let confidence: Double
    let album: String?
    let albumArtist: String?
    var applyFilenameMetadata = false
}

private struct MusicBrainzResponse: Decodable {
    let recordings: [MusicBrainzRecording]
}

private struct MusicBrainzRecording: Decodable {
    let title: String?
    let score: Int?
    let length: Int?
    let artistCredit: [MusicBrainzArtistCredit]?
    let releases: [MusicBrainzRelease]?

    enum CodingKeys: String, CodingKey {
        case title
        case score
        case length
        case artistCredit = "artist-credit"
        case releases
    }
}

private struct MusicBrainzArtistCredit: Decodable {
    let name: String?
    let artist: MusicBrainzArtist?
}

private struct MusicBrainzArtist: Decodable {
    let name: String?
}

private struct MusicBrainzRelease: Decodable {
    let id: String
    let title: String?
    let artistCredit: [MusicBrainzArtistCredit]?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case artistCredit = "artist-credit"
    }
}

@MainActor final class AudioPlayerService: ObservableObject {
    @Published private(set) var currentSong: Song?
    @Published private(set) var isPlaying = false
    @Published var elapsed: Double = 0
    @Published var duration: Double = 0
    @Published var queue: [Song] = []
    @Published var repeatMode: RepeatMode = .off
    @Published var shuffle = false
    @Published var speed: Float = 1

    private var player: AVPlayer?
    private weak var store: MusicStore?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var history: [UUID] = []

    func configure(with store: MusicStore) {
        self.store = store
        if store.resumeSession, let restored = store.song(store.currentSongID) { currentSong = restored; duration = restored.duration; elapsed = store.savedPosition }
        configureAudioSession(); configureRemoteCommands()
    }
    func syncCurrentSong(_ song: Song) {
        guard currentSong?.id == song.id else { return }
        currentSong = song
        updateNowPlaying()
    }
    private func configureAudioSession() { try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: []); try? AVAudioSession.sharedInstance().setActive(true) }

    func play(_ song: Song, from list: [Song]? = nil) {
        if currentSong?.id == song.id { if !isPlaying { player?.play(); isPlaying = true }; return }
        if let list { queue = list }
        currentSong = song; duration = song.duration; store?.markPlayed(song.id); elapsed = 0
        let url = store?.documentURL(for: song.fileName)
        guard let url else { return }
        player?.pause(); if let timeObserver { player?.removeTimeObserver(timeObserver) }
        let item = AVPlayerItem(url: url); player = AVPlayer(playerItem: item); player?.rate = speed
        timeObserver = player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in self?.elapsed = time.seconds }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in self?.advance() }
        updateNowPlaying(); player?.play(); isPlaying = true
    }
    func toggle() { isPlaying ? pause() : resume() }
    func pause() { player?.pause(); isPlaying = false; store?.savedPosition = elapsed; store?.save(); updateNowPlaying() }
    func resume() { player?.play(); isPlaying = true; updateNowPlaying() }
    func seek(to value: Double) { player?.seek(to: CMTime(seconds: value, preferredTimescale: 600)); elapsed = value; updateNowPlaying() }
    func previous() { if elapsed > 3 { seek(to: 0); return }; guard let id = history.last, let song = store?.song(id) else { seek(to: 0); return }; play(song) }
    func next() { advance() }
    private func advance() { guard let current = currentSong else { return }; if repeatMode == .one { seek(to: 0); resume(); return }; if let index = queue.firstIndex(where: { $0.id == current.id }), index + 1 < queue.count { history.append(current.id); play(queue[index + 1]) } else if repeatMode == .all, let first = queue.first { play(first) } else { pause(); seek(to: 0) } }
    func addToQueue(_ song: Song) { if !queue.contains(song) { queue.append(song) } }
    func setRate(_ rate: Float) { speed = rate; player?.rate = isPlaying ? rate : 0; if !isPlaying { player?.pause() } }
    private func updateNowPlaying() { guard let song = currentSong else { return }; var info: [String: Any] = [MPMediaItemPropertyTitle: song.title, MPMediaItemPropertyArtist: song.displayArtist, MPMediaItemPropertyAlbumTitle: song.displayAlbum, MPMediaItemPropertyPlaybackDuration: max(duration, song.duration), MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed, MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0]; if let data = song.artworkData, let image = UIImage(data: data) { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image } }; MPNowPlayingInfoCenter.default().nowPlayingInfo = info }
    private func configureRemoteCommands() { let c = MPRemoteCommandCenter.shared(); c.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }; c.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }; c.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }; c.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }; c.changePlaybackPositionCommand.addTarget { [weak self] event in if let e = event as? MPChangePlaybackPositionCommandEvent { self?.seek(to: e.positionTime) }; return .success } }
}
