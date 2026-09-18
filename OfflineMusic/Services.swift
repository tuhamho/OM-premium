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

    private let stateURL: URL
    private let fm = FileManager.default

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

    func importFiles(_ urls: [URL]) async -> Int {
        var imported = 0
        var artworkCandidates: [UUID] = []
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
                if metadata.artworkData == nil { artworkCandidates.append(metadata.id) }
                imported += 1
            } catch { continue }
        }
        save()
        if !artworkCandidates.isEmpty { Task { await enrichArtwork(for: artworkCandidates) } }
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
        var artworkCandidates: [UUID] = []
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
                } else {
                    artworkCandidates.append(metadata.id)
                }
            } catch {
                print("Metadata failed for \(url.lastPathComponent):", error)
            }
        }

        save()
        isScanning = false
        scanMessage = "Scan complete — \(songs.count) songs found"
        print("Library songs:", songs.count, "(imported:", importedCount, ")")

        if !artworkCandidates.isEmpty {
            Task { await enrichArtwork(for: artworkCandidates) }
        }
    }

    private func enrichArtwork(for ids: [UUID]) async {
        for id in ids {
            guard let song = songs.first(where: { $0.id == id }), song.artworkData == nil else { continue }
            guard let result = await ArtworkLookupService.shared.lookup(for: song) else { continue }
            if let artwork = result.artwork { await ArtworkCache.shared.store(artwork, for: song.id.uuidString) }
            update(song.id) {
                $0.artist = result.candidate.artist
                $0.title = result.candidate.title
                if let artwork = result.artwork { $0.artworkData = artwork }
            }
            save()
        }
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
    func update(_ id: UUID, _ change: (inout Song) -> Void) { guard let i = songs.firstIndex(where: { $0.id == id }) else { return }; change(&songs[i]) }
    func song(_ id: UUID?) -> Song? { songs.first { $0.id == id } }
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
        name = name.replacingOccurrences(of: #"(?i)\b(official\s+audio|official\s+video|lyric\s+video|lyrics|mv|audio|hd|4k)\b"#, with: "", options: .regularExpression)
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
        result = result.replacingOccurrences(of: #"(?i)\b(official\s+audio|official\s+video|lyric\s+video|lyrics|mv|audio|video|hd|4k)\b"#, with: "", options: .regularExpression)
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
        try? data.write(to: directory.appendingPathComponent(key).appendingPathExtension("jpg"), options: .atomic)
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

    func lookup(for song: Song) async -> ArtworkLookupResult? {
        guard song.title != "Unknown Title" else { return nil }
        guard let match = await matchingRelease(for: song) else { return nil }
        var artwork: Data?
        if let url = URL(string: "https://coverartarchive.org/release/\(match.releaseID)/front-500") {
            var request = URLRequest(url: url)
            request.setValue("OfflineMusic/1.0 (local music library)", forHTTPHeaderField: "User-Agent")
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                artwork = ArtworkCache.resizedArtwork(data)
            }
        }
        return ArtworkLookupResult(candidate: match.candidate, artwork: artwork)
    }

    private func matchingRelease(for song: Song) async -> MusicBrainzMatch? {
        let parsedCandidates = MetadataService.filenameCandidates(for: song.fileName)
        let current = FilenameCandidate(artist: song.artist, title: song.title)
        let candidates = parsedCandidates.count > 1 && parsedCandidates.contains(where: { normalized($0.artist) == normalized(current.artist) && normalized($0.title) == normalized(current.title) })
            ? parsedCandidates
            : [current]

        var matches: [MusicBrainzMatch] = []
        for candidate in candidates {
            if let match = await searchMusicBrainz(for: candidate, duration: song.duration) {
                matches.append(match)
            }
        }
        guard let best = matches.max(by: { $0.confidence < $1.confidence }) else { return nil }
        let secondBest = matches.filter { $0.candidate.artist != best.candidate.artist || $0.candidate.title != best.candidate.title }.max(by: { $0.confidence < $1.confidence })
        guard secondBest == nil || best.confidence - secondBest!.confidence >= 12 else { return nil }
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
        request.setValue("OfflineMusic/1.0 (local music library)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try? JSONDecoder().decode(MusicBrainzResponse.self, from: data) else { return nil }

        let title = normalized(candidate.title)
        let normalizedArtist = normalized(candidate.artist)
        let matches = result.recordings
            .compactMap { recording -> MusicBrainzMatch? in
                let resultTitle = normalized(recording.title ?? "")
                let resultArtist = normalized(recording.artistCredit?.compactMap { $0.name ?? $0.artist?.name }.joined(separator: " ") ?? "")
                let titleSimilarity = similarity(resultTitle, title)
                let artistSimilarity = normalizedArtist == "unknownartist" ? 1 : similarity(resultArtist, normalizedArtist)
                guard (recording.score ?? 0) >= 90, titleSimilarity >= 0.8, artistSimilarity >= 0.8,
                      let releaseID = recording.releases?.first?.id else { return nil }
                var confidence = Double(recording.score ?? 0) + titleSimilarity * 20 + artistSimilarity * 20
                if let length = recording.length, duration > 0 {
                    let difference = abs(Double(length) / 1000 - duration)
                    if difference <= 5 { confidence += 10 }
                    if difference > 30 { confidence -= 10 }
                }
                return MusicBrainzMatch(candidate: candidate, releaseID: releaseID, confidence: confidence)
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
    let candidate: FilenameCandidate
    let artwork: Data?
}

private struct MusicBrainzMatch {
    let candidate: FilenameCandidate
    let releaseID: String
    let confidence: Double
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
