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
    @Published var enrichmentCurrentSong = ""
    @Published var enrichmentStatus = ""
    @Published var isFetchingLyrics = false
    @Published var lyricsFetchProgress = 0
    @Published var lyricsFetchTotal = 0
    @Published var lyricsFetchCurrent = ""
    @Published var lyricsFetchSummary = ""
    @Published var isImportingLyrics = false
    @Published var lyricsImportProgress = 0
    @Published var lyricsImportTotal = 0
    @Published var lyricsImportCurrent = ""
    @Published var lyricsImportSummary = ""
    @Published var unmatchedLyricsFiles: [String] = []
    @Published private(set) var lyricsRevision = UUID()

    private let stateURL: URL
    private let fm = FileManager.default
    private weak var player: AudioPlayerService?
    private var enrichmentRunID = UUID()
    let sleepTimer = SleepTimerManager()

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

    var importedLyricsDirectory: URL {
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lyrics", isDirectory: true)
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

    private func fingerprint(for url: URL, relativePath: String) -> SongFileFingerprint? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let fileSize = values.fileSize,
              let modificationDate = values.contentModificationDate else { return nil }
        return SongFileFingerprint(relativePath: relativePath, fileSize: Int64(fileSize), modificationDate: modificationDate)
    }

    func load() async {
        guard let data = try? Data(contentsOf: stateURL), let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        songs = state.songs; playlists = state.playlists; recentlyPlayed = state.recentlyPlayed; currentSongID = state.currentSongID; savedPosition = state.savedPosition
        let artworkVersion = state.artworkMatchingVersion
        Task { @MainActor [weak self] in
            await self?.restoreArtworkAfterLaunch(version: artworkVersion)
        }
    }

    private func restoreArtworkAfterLaunch(version: Int?) async {
        let needsArtworkMigration = version != ArtworkMatchingConfiguration.version
        if needsArtworkMigration {
            for index in songs.indices where songs[index].artworkData != nil {
                let url = documentURL(for: songs[index].fileName)
                let hasEmbedded = await MetadataService.hasEmbeddedArtwork(asset: AVURLAsset(url: url))
                if !hasEmbedded {
                    songs[index].artworkData = nil
                } else if let artwork = songs[index].artworkData {
                    await ArtworkCache.shared.store(artwork, for: songs[index].id.uuidString)
                }
            }
            save()
        }
        for index in songs.indices where songs[index].artworkData == nil {
            if let artwork = await ArtworkCache.shared.data(for: songs[index].id.uuidString) {
                songs[index].artworkData = artwork
            }
        }
        objectWillChange.send()
    }

    func save() {
        let state = PersistedState(songs: songs, playlists: playlists, recentlyPlayed: recentlyPlayed, currentSongID: currentSongID, savedPosition: savedPosition, artworkMatchingVersion: ArtworkMatchingConfiguration.version)
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
                metadata.fileFingerprint = fingerprint(for: destination, relativePath: metadata.fileName)
                songs.append(metadata)
                if let artwork = metadata.artworkData { await ArtworkCache.shared.store(artwork, for: metadata.id.uuidString) }
                imported += 1
            } catch { continue }
        }
        save()
        return imported
    }

    func reconcileDocumentsInBackground() async {
        guard !isScanning else { return }
        if songs.isEmpty {
            await rescanDocuments()
            return
        }

        let startedAt = Date()
        let documentsURL = documentsDirectory
        let audioFiles = await Task.detached(priority: .utility) {
            Self.enumerateAudioFiles(in: documentsURL)
        }.value
        let currentPaths = Set(audioFiles.map { relativeDocumentPath(for: $0) })
        let knownPaths = Set(songs.map(\.fileName))
        let removedIDs = songs.compactMap { song in
            currentPaths.contains(song.fileName) || fm.fileExists(atPath: documentURL(for: song.fileName).path) ? nil : song.id
        }
        if !removedIDs.isEmpty {
            removeSongs(removedIDs)
        }

        var unchanged = 0
        var added = 0
        var modified = 0
        var metadataRereads = 0

        for url in audioFiles {
            let relativePath = relativeDocumentPath(for: url)
            guard let currentFingerprint = fingerprint(for: url, relativePath: relativePath) else { continue }
            let index = songs.firstIndex(where: {
                $0.fileName == relativePath || (!knownPaths.contains(relativePath) && $0.fileName == url.lastPathComponent)
            })

            if let index, songs[index].fileFingerprint == currentFingerprint {
                unchanged += 1
                continue
            }

            do {
                var metadata = try await MetadataService.read(asset: AVURLAsset(url: url), fileName: url.lastPathComponent)
                metadata.fileName = relativePath
                metadata.fileFingerprint = currentFingerprint
                metadata.artworkData = ArtworkCache.resizedArtwork(metadata.artworkData)
                metadataRereads += 1

                if let index {
                    let existing = songs[index]
                    metadata.id = existing.id
                    metadata.importedAt = existing.importedAt
                    metadata.lastPlayed = existing.lastPlayed
                    metadata.playCount = existing.playCount
                    metadata.isFavorite = existing.isFavorite
                    metadata.musicBrainzReleaseID = existing.musicBrainzReleaseID
                    metadata.manualLyrics = existing.manualLyrics
                    metadata.cachedOnlineLyrics = existing.cachedOnlineLyrics
                    metadata.importedLyricsFileName = existing.importedLyricsFileName
                    metadata.lyricsOffset = existing.lyricsOffset
                    if metadata.artworkData == nil { metadata.artworkData = existing.artworkData }
                    songs[index] = metadata
                    if player?.currentSong?.id == metadata.id { player?.syncCurrentSong(metadata) }
                    modified += 1
                } else {
                    songs.append(metadata)
                    added += 1
                }
            } catch {
                print("Background metadata failed for \(url.lastPathComponent):", error)
            }
        }

        if !removedIDs.isEmpty || added > 0 || modified > 0 {
            save()
            objectWillChange.send()
        }
        let duration = Date().timeIntervalSince(startedAt)
        let durationText = String(format: "%.2fs", duration)
        print("Startup library: Persisted songs: \(knownPaths.count), Filesystem audio files: \(audioFiles.count), Unchanged: \(unchanged), Added: \(added), Modified: \(modified), Removed: \(removedIDs.count), Metadata rereads: \(metadataRereads), Startup sync duration: \(durationText)")
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
        if !missingIDs.isEmpty { removeSongs(missingIDs) }

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
                metadata.fileFingerprint = fingerprint(for: url, relativePath: relativePath)
                if let index = songs.firstIndex(where: { $0.fileName == relativePath || (!knownPaths.contains(relativePath) && $0.fileName == url.lastPathComponent) }) {
                    let existing = songs[index]
                    metadata.id = existing.id
                    metadata.importedAt = existing.importedAt
                    metadata.lastPlayed = existing.lastPlayed
                    metadata.playCount = existing.playCount
                    metadata.isFavorite = existing.isFavorite
                    metadata.musicBrainzReleaseID = existing.musicBrainzReleaseID
                    metadata.manualLyrics = existing.manualLyrics
                    metadata.cachedOnlineLyrics = existing.cachedOnlineLyrics
                    metadata.importedLyricsFileName = existing.importedLyricsFileName
                    metadata.lyricsOffset = existing.lyricsOffset
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

    private func removeSongs(_ ids: [UUID]) {
        let removed = Set(ids)
        songs.removeAll { removed.contains($0.id) }
        recentlyPlayed.removeAll { removed.contains($0) }
        playlists.indices.forEach { index in
            playlists[index].songIDs.removeAll { removed.contains($0) }
        }
        if let player {
            player.queue.removeAll { removed.contains($0.id) }
            if let currentID = player.currentSong?.id, removed.contains(currentID) { player.pause() }
        }
        if currentSongID.map(removed.contains) == true { currentSongID = nil }
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

        _ = await applyArtworkResult(result, for: song.id, preserveExistingArtwork: hasEmbeddedArtwork)
        debugLines.append("Song updated")
        debugLines.append("Saved successfully")
    }

    func startMetadataArtworkEnrichment() {
        guard !isFetchingArtwork else { return }
        let ids = songs.filter { needsEnrichment($0) }.map(\.id)
        isFetchingArtwork = true
        artworkFetchProgress = 0
        artworkFetchTotal = ids.count
        artworkFetchSummary = ""
        enrichmentCurrentSong = ""
        enrichmentStatus = "Queued"
        let runID = UUID()
        enrichmentRunID = runID
        Task { @MainActor [weak self] in
            await self?.runMetadataArtworkEnrichment(ids: ids, runID: runID)
        }
    }

    func cancelMetadataArtworkEnrichment() {
        guard isFetchingArtwork else { return }
        enrichmentStatus = "Cancelled"
        enrichmentRunID = UUID()
        isFetchingArtwork = false
        artworkFetchSummary = "Enrichment cancelled"
    }

    private func runMetadataArtworkEnrichment(ids: [UUID], runID: UUID) async {
        var processed = 0
        var metadataUpdated = 0
        var embeddedArtwork = 0
        var musicBrainzArtwork = 0
        var appleArtwork = 0
        var needsReview = 0
        var notFound = 0
        var failed = 0

        for id in ids {
            guard isFetchingArtwork, enrichmentRunID == runID, let song = songs.first(where: { $0.id == id }) else { break }
            processed += 1
            artworkFetchProgress += 1
            enrichmentCurrentSong = "\(song.displayArtist) - \(song.title)"
            enrichmentStatus = "MusicBrainz match"

            if song.artworkData != nil {
                let url = documentURL(for: song.fileName)
                if await MetadataService.hasEmbeddedArtwork(asset: AVURLAsset(url: url)) {
                    embeddedArtwork += 1
                }
            }
            let result = await ArtworkLookupService.shared.lookup(for: song)
            guard isFetchingArtwork, enrichmentRunID == runID else { break }

            enrichmentStatus = "Fetching artwork"
            let update = await applyArtworkResult(
                result,
                for: id,
                preserveExistingArtwork: song.artworkData != nil
            )
            if update.metadataChanged { metadataUpdated += 1 }
            if result.source == .musicBrainz && update.artworkApplied { musicBrainzArtwork += 1 }
            if result.source == .apple && update.artworkApplied { appleArtwork += 1 }

            if result.logs.contains(where: { $0.localizedCaseInsensitiveContains("temporarily unavailable") || $0.localizedCaseInsensitiveContains("network error") }) {
                failed += 1
            } else if result.candidate == nil && result.artwork == nil {
                needsReview += 1
            } else if result.artwork == nil && !update.metadataChanged {
                notFound += 1
            }
            enrichmentStatus = "Done"
        }

        guard enrichmentRunID == runID else { return }
        let wasCancelled = !isFetchingArtwork
        isFetchingArtwork = false
        enrichmentStatus = wasCancelled ? "Cancelled" : "Complete"
        artworkFetchSummary = "Processed: \(processed) • Metadata updated: \(metadataUpdated) • Artwork from embedded tags: \(embeddedArtwork) • Artwork from MusicBrainz: \(musicBrainzArtwork) • Artwork from Apple fallback: \(appleArtwork) • Needs review: \(needsReview) • Not found: \(notFound) • Failed: \(failed)"
    }

    private func needsEnrichment(_ song: Song) -> Bool {
        let artist = song.displayArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let goodArtist = !artist.isEmpty && artist.caseInsensitiveCompare("Unknown Artist") != .orderedSame
        let goodTitle = !title.isEmpty && title.caseInsensitiveCompare("Unknown Title") != .orderedSame
        let filenameDerivedAndReversed = MetadataService.filenameCandidates(for: song.fileName).first.map {
            normalizedMetadata(song.artist) == normalizedMetadata($0.title) && normalizedMetadata(song.title) == normalizedMetadata($0.artist)
        } ?? false
        return !goodArtist || !goodTitle || song.artworkData == nil || filenameDerivedAndReversed
    }

    private func normalizedMetadata(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func applyArtworkResult(_ result: ArtworkLookupResult, for id: UUID, preserveExistingArtwork: Bool) async -> (metadataChanged: Bool, artworkApplied: Bool) {
        guard let index = songs.firstIndex(where: { $0.id == id }) else { return (false, false) }
        var updated = songs[index]
        let original = updated
        if result.applyFilenameMetadata, let candidate = result.candidate {
            updated.title = candidate.title
            updated.artist = candidate.artist
        }
        if updated.album == "Unknown Album", let album = result.album { updated.album = album }
        if let releaseID = result.albumReleaseID,
           let album = result.album,
           !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.musicBrainzReleaseID = releaseID
        }
        if result.applyFilenameMetadata, let albumArtist = result.albumArtist { updated.albumArtist = albumArtist }
        if updated.albumArtist.isEmpty || updated.albumArtist == "Unknown Artist", let albumArtist = result.albumArtist { updated.albumArtist = albumArtist }
        var artworkApplied = false
        if let artwork = result.artwork, !preserveExistingArtwork {
            await ArtworkCache.shared.store(artwork, for: updated.id.uuidString)
            updated.artworkData = artwork
            artworkApplied = true
        }

        songs[index] = updated
        objectWillChange.send()
        save()
        player?.syncCurrentSong(updated)
        return (updated.title != original.title || updated.artist != original.artist || updated.album != original.album || updated.albumArtist != original.albumArtist, artworkApplied)
    }

    func resetDownloadedMetadataAndArtwork() async {
        guard !isScanning, !isFetchingArtwork else { return }
        await ArtworkCache.shared.reset()

        for index in songs.indices {
            let existing = songs[index]
            let url = documentURL(for: existing.fileName)
            guard fm.fileExists(atPath: url.path) else { continue }
            guard var local = try? await MetadataService.read(asset: AVURLAsset(url: url), fileName: url.lastPathComponent) else { continue }
            local.id = existing.id
            local.fileName = existing.fileName
            local.importedAt = existing.importedAt
            local.lastPlayed = existing.lastPlayed
            local.playCount = existing.playCount
            local.isFavorite = existing.isFavorite
            local.importedLyricsFileName = existing.importedLyricsFileName
            local.lyricsOffset = existing.lyricsOffset
            songs[index] = local
        }
        save()
        objectWillChange.send()
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

    func localLyrics(for id: UUID) async -> LocalLyrics? {
        guard let song = songs.first(where: { $0.id == id }) else { return nil }
        let importedURL = song.importedLyricsFileName.map { importedLyricsDirectory.appendingPathComponent($0) }
        return await LocalLyricsResolver.shared.resolve(
            song: song,
            fileURL: documentURL(for: song.fileName),
            importedURL: importedURL
        )
    }

    func importLyricsFiles(_ urls: [URL]) async {
        guard !isImportingLyrics else { return }
        isImportingLyrics = true
        lyricsImportProgress = 0
        lyricsImportTotal = urls.count
        lyricsImportCurrent = ""
        lyricsImportSummary = ""
        unmatchedLyricsFiles = []

        var imported = 0
        var matched = 0
        var failed = 0
        var unmatched: [String] = []

        for url in urls {
            guard isImportingLyrics else { break }
            lyricsImportProgress += 1
            lyricsImportCurrent = url.lastPathComponent
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            let fileExtension = url.pathExtension.lowercased()
            guard fileExtension == "lrc" || fileExtension == "txt" else {
                failed += 1
                continue
            }

            let destination = importedLyricsDirectory.appendingPathComponent(url.lastPathComponent)
            do {
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.copyItem(at: url, to: destination)
                imported += 1

                let candidates = matchingSongs(forLyricsFile: url)
                if candidates.count == 1, let index = songs.firstIndex(where: { $0.id == candidates[0].id }) {
                    songs[index].importedLyricsFileName = url.lastPathComponent
                    matched += 1
                } else {
                    unmatched.append(url.lastPathComponent)
                }
            } catch {
                failed += 1
            }
            await Task.yield()
        }

        let cancelled = !isImportingLyrics
        unmatchedLyricsFiles = unmatched
        lyricsImportSummary = cancelled
            ? "Lyrics import cancelled • Imported: \(imported) • Matched: \(matched) • Unmatched: \(unmatched.count) • Failed: \(failed)"
            : "Lyrics Import Complete • Imported: \(imported) • Matched: \(matched) • Unmatched: \(unmatched.count) • Failed: \(failed)"
        isImportingLyrics = false
        lyricsImportCurrent = ""
        lyricsRevision = UUID()
        save()
        objectWillChange.send()
    }

    func cancelLyricsImport() {
        isImportingLyrics = false
        lyricsImportSummary = "Lyrics import cancelled"
    }

    func removeImportedLyrics(for id: UUID) {
        guard let index = songs.firstIndex(where: { $0.id == id }) else { return }
        if let fileName = songs[index].importedLyricsFileName {
            let url = importedLyricsDirectory.appendingPathComponent(fileName)
            try? fm.removeItem(at: url)
        }
        songs[index].importedLyricsFileName = nil
        lyricsRevision = UUID()
        save()
        objectWillChange.send()
    }

    private func matchingSongs(forLyricsFile url: URL) -> [Song] {
        let basename = url.deletingPathExtension().lastPathComponent
        let exact = songs.filter {
            URL(fileURLWithPath: $0.fileName).deletingPathExtension().lastPathComponent
                .caseInsensitiveCompare(basename) == .orderedSame
        }
        if !exact.isEmpty { return exact }

        let normalized = normalizedLyricsName(basename)
        return songs.filter {
            normalizedLyricsName(URL(fileURLWithPath: $0.fileName).deletingPathExtension().lastPathComponent) == normalized
        }
    }

    private func normalizedLyricsName(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
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
            let album = albumKey(for: song.displayAlbum)
            if let releaseID = song.musicBrainzReleaseID, !releaseID.isEmpty {
                return "mb:\(releaseID)"
            }
            return album == "unknown album" ? album : "\(artistKey(for: artist))\u{1F}\(album)"
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
        let trimmed = cleanedGroupingName(value)
        let display = trimmed.isEmpty ? "Unknown Artist" : trimmed
        return display.precomposedStringWithCanonicalMapping.lowercased(with: .current)
    }

    private func albumKey(for value: String) -> String {
        let trimmed = cleanedGroupingName(value)
        let display = trimmed.isEmpty ? "Unknown Album" : trimmed
        return display.precomposedStringWithCanonicalMapping.lowercased(with: .current)
    }

    private func cleanedGroupingName(_ value: String) -> String {
        value
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"_:|–—-•;")))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private func displayArtistName(from songs: [Song]) -> String {
        let value = cleanedGroupingName(songs.first?.displayArtist ?? "")
        return value.isEmpty ? "Unknown Artist" : value
    }

    private func displayAlbumName(from songs: [Song]) -> String {
        let value = cleanedGroupingName(songs.first?.displayAlbum ?? "")
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
    func addSong(_ songID: UUID, to playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }),
              songs.contains(where: { $0.id == songID }) else { return }
        if !playlists[index].songIDs.contains(songID) {
            playlists[index].songIDs.append(songID)
            save()
            objectWillChange.send()
        }
    }

    func updateSongMetadata(for id: UUID, title: String, artist: String, album: String, albumArtist: String) {
        guard let index = songs.firstIndex(where: { $0.id == id }) else { return }
        songs[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        songs[index].artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        songs[index].album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        songs[index].albumArtist = albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
        objectWillChange.send()
        player?.syncCurrentSong(songs[index])
    }
    func songs(in playlist: Playlist) -> [Song] { playlist.songIDs.compactMap(song) }

    var recentlyAddedSongs: [Song] { songs.sorted { $0.importedAt > $1.importedAt } }
    var mostPlayedSongs: [Song] { songs.sorted { $0.playCount > $1.playCount } }
    var favoriteSongs: [Song] { songs.filter(\.isFavorite) }
    var recentlyPlayedSongs: [Song] { recentlyPlayed.compactMap(song) }

    func updateLyrics(for id: UUID, manualLyrics: String?) {
        guard let index = songs.firstIndex(where: { $0.id == id }) else { return }
        songs[index].manualLyrics = manualLyrics?.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
        objectWillChange.send()
        player?.syncCurrentSong(songs[index])
    }

    func updateLyricsOffset(for id: UUID, value: Double) {
        guard let index = songs.firstIndex(where: { $0.id == id }) else { return }
        songs[index].lyricsOffset = min(max(value, -15), 15)
        save()
        lyricsRevision = UUID()
        objectWillChange.send()
    }

    func findLyrics(for id: UUID, refresh: Bool = false) async -> [String] {
        guard let index = songs.firstIndex(where: { $0.id == id }) else { return ["Song not found"] }
        let song = songs[index]
        guard song.manualLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
            return ["Manual lyrics override is active"]
        }
        if !refresh, let cached = song.cachedOnlineLyrics, !cached.isEmpty {
            return ["Cached lyrics used", "Lyrics characters: \(cached.count)"]
        }
        let result = await LyricsLookupService.shared.lookup(for: song)
        if let lyrics = result.lyrics {
            songs[index].cachedOnlineLyrics = lyrics
            save()
            objectWillChange.send()
        }
        return result.logs
    }

    func clearCachedLyrics(for id: UUID) {
        guard let index = songs.firstIndex(where: { $0.id == id }) else { return }
        songs[index].cachedOnlineLyrics = nil
        save()
        objectWillChange.send()
    }

    func startMissingLyricsFetch() {
        guard !isFetchingLyrics else { return }
        let ids = songs.filter { $0.manualLyrics?.isEmpty != false && $0.embeddedLyrics?.isEmpty != false && $0.cachedOnlineLyrics?.isEmpty != false }.map(\.id)
        isFetchingLyrics = true
        lyricsFetchProgress = 0
        lyricsFetchTotal = ids.count
        lyricsFetchSummary = ""
        Task { @MainActor [weak self] in await self?.runMissingLyricsFetch(ids: ids) }
    }

    func cancelMissingLyricsFetch() {
        isFetchingLyrics = false
        lyricsFetchSummary = "Lyrics fetch cancelled"
    }

    private func runMissingLyricsFetch(ids: [UUID]) async {
        var found = 0
        var notFound = 0
        var failed = 0
        for id in ids {
            guard isFetchingLyrics, let index = songs.firstIndex(where: { $0.id == id }) else { break }
            lyricsFetchProgress += 1
            lyricsFetchCurrent = "\(songs[index].displayArtist) - \(songs[index].title)"
            let result = await LyricsLookupService.shared.lookup(for: songs[index])
            guard isFetchingLyrics else { break }
            if let lyrics = result.lyrics {
                songs[index].cachedOnlineLyrics = lyrics
                found += 1
                save()
                objectWillChange.send()
            } else if result.logs.contains(where: { $0.localizedCaseInsensitiveContains("error") }) {
                failed += 1
            } else {
                notFound += 1
            }
        }
        let cancelled = !isFetchingLyrics
        isFetchingLyrics = false
        lyricsFetchSummary = cancelled ? "Lyrics fetch cancelled" : "Found: \(found) • Not found: \(notFound) • Failed: \(failed)"
    }
}

enum SleepTimerOption: String, CaseIterable, Identifiable {
    case off = "Off"
    case minutes15 = "15 minutes"
    case minutes30 = "30 minutes"
    case minutes45 = "45 minutes"
    case minutes60 = "60 minutes"
    case endOfSong = "End of current song"

    var id: String { rawValue }
    var duration: TimeInterval? {
        switch self {
        case .off, .endOfSong: return nil
        case .minutes15: return 15 * 60
        case .minutes30: return 30 * 60
        case .minutes45: return 45 * 60
        case .minutes60: return 60 * 60
        }
    }
}

@MainActor final class SleepTimerManager: ObservableObject {
    @Published private(set) var option: SleepTimerOption = .off
    @Published private(set) var remaining: TimeInterval?
    private var task: Task<Void, Never>?
    private var pausePlayback: (() -> Void)?

    func attach(pausePlayback: @escaping () -> Void) {
        self.pausePlayback = pausePlayback
    }

    func set(_ option: SleepTimerOption) {
        task?.cancel()
        self.option = option
        remaining = option.duration
        guard let duration = option.duration else { return }
        task = Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(duration)
            while !Task.isCancelled {
                let value = deadline.timeIntervalSinceNow
                guard value > 0 else { break }
                self?.remaining = value
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            self?.remaining = 0
            self?.option = .off
            self?.pausePlayback?()
        }
    }

    func currentSongEnded() -> Bool {
        guard option == .endOfSong else { return false }
        option = .off
        remaining = nil
        pausePlayback?()
        return true
    }

    var remainingText: String? {
        guard let remaining else { return nil }
        return String(format: "%02d:%02d", Int(remaining) / 60, Int(remaining) % 60)
    }
}

struct LyricsLookupResult {
    let lyrics: String?
    let logs: [String]
}

actor LocalLyricsResolver {
    static let shared = LocalLyricsResolver()

    private struct CacheRecord: Codable {
        let sourcePath: String
        let modificationDate: Date
        let lyrics: LocalLyrics
    }

    private let fileManager = FileManager.default
    private let cacheDirectory: URL

    init() {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        cacheDirectory = support.appendingPathComponent("LyricsCache", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func resolve(song: Song, fileURL: URL, importedURL: URL?) -> LocalLyrics? {
        if let manual = nonEmpty(song.manualLyrics) {
            return parse(manual)
        }

        let sidecar = sidecarURL(for: fileURL, extension: "lrc")
        let plainSidecarLyrics = sidecar.flatMap { readCachedOrParse(songID: song.id, url: $0) }
        if let plainSidecarLyrics, plainSidecarLyrics.isSynced {
            return plainSidecarLyrics
        }

        if let importedURL,
           importedURL.pathExtension.caseInsensitiveCompare("lrc") == .orderedSame,
           let importedLyrics = readCachedOrParse(songID: song.id, url: importedURL),
           importedLyrics.isSynced {
            return importedLyrics
        }

        if let embedded = nonEmpty(song.embeddedLyrics) {
            return parse(embedded)
        }

        if let plainSidecarLyrics {
            return plainSidecarLyrics
        }

        if let importedURL,
           importedURL.pathExtension.caseInsensitiveCompare("lrc") == .orderedSame,
           let importedLyrics = readCachedOrParse(songID: song.id, url: importedURL) {
            return importedLyrics
        }

        if let textSidecar = sidecarURL(for: fileURL, extension: "txt"),
           let result = readCachedOrParse(songID: song.id, url: textSidecar) {
            return result
        }
        if let importedURL,
           importedURL.pathExtension.caseInsensitiveCompare("txt") == .orderedSame,
           let result = readCachedOrParse(songID: song.id, url: importedURL) {
            return result
        }
        return nil
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func sidecarURL(for audioURL: URL, extension fileExtension: String) -> URL? {
        let base = audioURL.deletingPathExtension()
        let exact = base.appendingPathExtension(fileExtension)
        if fileManager.fileExists(atPath: exact.path) { return exact }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: base.deletingLastPathComponent(),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let baseName = base.lastPathComponent
        return entries.first { url in
            url.pathExtension.caseInsensitiveCompare(fileExtension) == .orderedSame &&
            url.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(baseName) == .orderedSame
        }
    }

    private func readCachedOrParse(songID: UUID, url: URL) -> LocalLyrics? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let modificationDate = values.contentModificationDate else { return nil }
        let cacheURL = cacheDirectory.appendingPathComponent("\(songID.uuidString).json")
        if let data = try? Data(contentsOf: cacheURL),
           let record = try? JSONDecoder().decode(CacheRecord.self, from: data),
           record.sourcePath == url.path,
           record.modificationDate == modificationDate {
            return record.lyrics
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { return nil }
        guard let lyrics = parse(text) else { return nil }
        let record = CacheRecord(sourcePath: url.path, modificationDate: modificationDate, lyrics: lyrics)
        if let encoded = try? JSONEncoder().encode(record) {
            try? encoded.write(to: cacheURL, options: .atomic)
        }
        print("Local lyrics loaded: \(url.lastPathComponent), lines: \(lyrics.syncedLines.count), cache: \(cacheURL.path)")
        return lyrics
    }

    private func parse(_ source: String) -> LocalLyrics? {
        let timestampPattern = #"(\d+):(?:(\d{1,2}):)?(\d{1,2})(?:[\.:](\d{1,3}))?"#
        guard let lineRegex = try? NSRegularExpression(pattern: "\\[\(timestampPattern)\\]"),
              let wordRegex = try? NSRegularExpression(pattern: "<\(timestampPattern)>"),
              let offsetRegex = try? NSRegularExpression(pattern: #"^\[offset:([+-]?\d+)\]$"#, options: .caseInsensitive) else {
            return LocalLyrics.plain(source)
        }
        var parsedLines: [(lineTime: TimeInterval, words: [SyncedLyricWord], text: String)] = []
        var plainLines: [String] = []
        var fileOffset: TimeInterval = 0

        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let offsetMatch = offsetRegex.firstMatch(in: line, range: range),
               let valueRange = Range(offsetMatch.range(at: 1), in: line),
               let milliseconds = Double(line[valueRange]) {
                fileOffset = milliseconds / 1000
                continue
            }

            let matches = lineRegex.matches(in: line, range: range)
            if matches.isEmpty {
                if !isMetadataTag(line) { plainLines.append(line) }
                continue
            }

            let lyricText = lineRegex.stringByReplacingMatches(in: line, options: [], range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lyricText.isEmpty else { continue }

            for match in matches {
                guard let lineTime = timestamp(from: match, in: line) else { continue }
                let wordMatches = wordRegex.matches(in: lyricText, range: NSRange(lyricText.startIndex..<lyricText.endIndex, in: lyricText))
                var words: [SyncedLyricWord] = []
                for (index, wordMatch) in wordMatches.enumerated() {
                    guard let startTime = timestamp(from: wordMatch, in: lyricText),
                          let tagRange = Range(wordMatch.range, in: lyricText) else { continue }
                    let contentStart = tagRange.upperBound
                    let contentEnd: String.Index
                    if index + 1 < wordMatches.count, let nextRange = Range(wordMatches[index + 1].range, in: lyricText) {
                        contentEnd = nextRange.lowerBound
                    } else {
                        contentEnd = lyricText.endIndex
                    }
                    let wordText = String(lyricText[contentStart..<contentEnd])
                    guard !wordText.isEmpty else { continue }
                    words.append(SyncedLyricWord(text: wordText, startTime: startTime))
                }
                parsedLines.append((lineTime: lineTime, words: words, text: lyricText.replacingOccurrences(of: #"<\d+:.+?>"#, with: "", options: .regularExpression)))
            }
        }

        if !parsedLines.isEmpty {
            let sorted = parsedLines.sorted { $0.lineTime < $1.lineTime }
            let lines = sorted.enumerated().map { index, item in
                let nextLineTime = index + 1 < sorted.count ? sorted[index + 1].lineTime : nil
                let completedWords = item.words.enumerated().map { wordIndex, word in
                    let nextWordTime = wordIndex + 1 < item.words.count ? item.words[wordIndex + 1].startTime : nextLineTime
                    return SyncedLyricWord(id: word.id, text: word.text, startTime: word.startTime, endTime: nextWordTime)
                }
                return SyncedLyricLine(lineTime: item.lineTime, words: completedWords, plainText: item.text)
            }
            return LocalLyrics(syncedLines: lines, plainText: lines.map(\.text).joined(separator: "\n"), fileProvidedOffset: fileOffset)
        }
        guard let plain = LocalLyrics.plain(plainLines.joined(separator: "\n")) else { return nil }
        return LocalLyrics(syncedLines: plain.syncedLines, plainText: plain.text, fileProvidedOffset: fileOffset)
    }

    private func timestamp(from match: NSTextCheckingResult, in line: String) -> TimeInterval? {
        func component(_ index: Int) -> String? {
            guard match.range(at: index).location != NSNotFound,
                  let range = Range(match.range(at: index), in: line) else { return nil }
            return String(line[range])
        }
        guard let first = Double(component(1) ?? ""), let last = Double(component(3) ?? "") else { return nil }
        let hasHours = component(2) != nil
        let hours = hasHours ? first : 0
        let minutes = hasHours ? (Double(component(2) ?? "0") ?? 0) : first
        let fractionText = component(4) ?? "0"
        let fraction = (Double(fractionText) ?? 0) / pow(10, Double(fractionText.count))
        return hours * 3600 + minutes * 60 + last + fraction
    }

    private func isMetadataTag(_ line: String) -> Bool {
        line.range(of: #"^\[(ar|ti|al|by|offset|re|ve|length|tool|id):"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

actor LyricsLookupService {
    static let shared = LyricsLookupService()

    func lookup(for song: Song) async -> LyricsLookupResult {
        let artist = song.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty, artist.caseInsensitiveCompare("Unknown Artist") != .orderedSame,
              !title.isEmpty, title.caseInsensitiveCompare("Unknown Title") != .orderedSame else {
            return LyricsLookupResult(lyrics: nil, logs: ["Lyrics lookup skipped: artist or title is unknown"])
        }

        var components = URLComponents(string: "https://lrclib.net/api/get")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "album_name", value: song.displayAlbum == "Unknown Album" ? nil : song.displayAlbum),
            URLQueryItem(name: "duration", value: song.duration > 0 ? String(Int(song.duration.rounded())) : nil)
        ].filter { $0.value != nil }
        guard let url = components?.url else { return LyricsLookupResult(lyrics: nil, logs: ["Lyrics URL could not be created"]) }

        var logs = ["Lyrics query title: \(title)", "Lyrics query artist: \(artist)", "Lyrics request: \(url.absoluteString)"]
        var request = URLRequest(url: url)
        request.setValue("OfflineMusic/1.0 (https://github.com/tuhamho/OM-premium)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            logs.append("Lyrics HTTP status: \(status)")
            guard status == 200, let decoded = try? JSONDecoder().decode(LRCLIBResponse.self, from: data),
                  let plainLyrics = decoded.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !plainLyrics.isEmpty else {
                logs.append("Lyrics result: not found or invalid")
                return LyricsLookupResult(lyrics: nil, logs: logs)
            }

            let matchedTitle = decoded.trackName ?? ""
            let matchedArtist = decoded.artistName ?? ""
            let titleScore = similarity(normalize(matchedTitle), normalize(title))
            let artistScore = similarity(normalize(matchedArtist), normalize(artist))
            let durationDifference = decoded.duration.map { abs($0 - song.duration) }
            logs.append("Results found: 1")
            logs.append("Selected match: \(matchedTitle) — \(matchedArtist)")
            logs.append(String(format: "Title similarity: %.2f, artist similarity: %.2f", titleScore, artistScore))
            logs.append(durationDifference.map { String(format: "Duration difference: %.1fs", $0) } ?? "Duration difference: unavailable")
            guard titleScore >= 0.90, artistScore >= 0.85, durationDifference.map({ $0 <= 10 }) ?? true else {
                logs.append("Lyrics rejected: confidence too low")
                return LyricsLookupResult(lyrics: nil, logs: logs)
            }
            logs.append("Lyrics characters: \(plainLyrics.count)")
            logs.append("Cache saved yes")
            return LyricsLookupResult(lyrics: plainLyrics, logs: logs)
        } catch {
            logs.append("Lyrics network error: \(error.localizedDescription)")
            return LyricsLookupResult(lyrics: nil, logs: logs)
        }
    }

    private func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }

    private func similarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if lhs == rhs { return 1 }
        if lhs.contains(rhs) || rhs.contains(lhs) { return 0.9 }
        return 0
    }
}

private struct LRCLIBResponse: Decodable {
    let trackName: String?
    let artistName: String?
    let duration: Double?
    let plainLyrics: String?
}

@MainActor final class LyricsSpeechManager: ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()
    @Published private(set) var isSpeaking = false

    func read(_ lyrics: String, pauseMusic: @escaping () -> Void) {
        pauseMusic()
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: lyrics)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func pause() { synthesizer.pauseSpeaking(at: .immediate) }
    func resume() { synthesizer.continueSpeaking() }
    func stop() { synthesizer.stopSpeaking(at: .immediate); isSpeaking = false }
}

private struct PersistedState: Codable {
    var songs: [Song]
    var playlists: [Playlist]
    var recentlyPlayed: [UUID]
    var currentSongID: UUID?
    var savedPosition: Double
    var artworkMatchingVersion: Int?
}

struct MetadataService {
    private static func rawDescription(_ item: AVMetadataItem) -> String {
        let identifier = item.identifier?.rawValue ?? "nil"
        let key = item.key.map { String(describing: $0) } ?? "nil"
        let keySpace = item.keySpace?.rawValue ?? "nil"
        return "identifier=\(identifier) key=\(key) keySpace=\(keySpace)"
    }

    private static func matches(_ item: AVMetadataItem, _ terms: [String]) -> Bool {
        let text = "\(item.identifier?.rawValue ?? "") \(item.key.map { String(describing: $0) } ?? "") \(item.keySpace?.rawValue ?? "")".lowercased()
        return terms.contains { text.contains($0.lowercased()) }
    }

    private static func textValue(_ item: AVMetadataItem) -> String {
        item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func firstText(in items: [AVMetadataItem], commonIdentifier: AVMetadataIdentifier?, terms: [String]) -> String {
        if let commonIdentifier,
           let value = items.first(where: { $0.identifier == commonIdentifier }).map(textValue), !value.isEmpty {
            return value
        }
        return items.first(where: { matches($0, terms) }).map(textValue) ?? ""
    }

    private static func number(_ value: String) -> Int? {
        Int(value.split(separator: "/", maxSplits: 1).first ?? Substring(value))
    }

    static func hasEmbeddedArtwork(asset: AVURLAsset) async -> Bool {
        guard let items = try? await asset.load(.metadata),
              let commonItems = try? await asset.load(.commonMetadata) else { return false }
        return (items + commonItems).contains {
            $0.commonKey == .commonKeyArtwork || matches($0, ["artwork", "apic", "covr"])
        }
    }

    static func read(asset: AVURLAsset, fileName: String) async throws -> Song {
        let duration = try await asset.load(.duration).seconds
        let commonItems = try await asset.load(.commonMetadata)
        let formatItems = try await asset.load(.metadata)
        let items = formatItems + commonItems

        let reliableFallback = reliableFilenameCandidate(for: fileName)
        let fallbackTitle = reliableFallback?.title ?? cleanedFilename(for: fileName)
        let fallbackArtist = reliableFallback?.artist ?? "Unknown Artist"
        print("Metadata audit: \(fileName)")
        for item in items {
            print("  \(rawDescription(item)) value=\(textValue(item)) data=\(item.dataValue != nil ? "yes" : "no") type=\(String(describing: type(of: item.value)))")
        }
        let embeddedTitle = firstText(in: items, commonIdentifier: .commonIdentifierTitle, terms: ["tit2", "title"])
        let embeddedArtist = firstText(in: items, commonIdentifier: .commonIdentifierArtist, terms: ["tpe1", "artist", "performer", "contributing"])
        let embeddedAlbum = firstText(in: items, commonIdentifier: .commonIdentifierAlbumName, terms: ["talb", "album"])
        let albumArtist = firstText(in: items, commonIdentifier: nil, terms: ["tpe2", "albumartist", "album artist"])
        let genre = items.first(where: { matches($0, ["tcon", "genre"]) }).map(textValue) ?? ""
        let trackNumber = items.first(where: { matches($0, ["trck", "tracknumber", "track number"]) }).flatMap { number(textValue($0)) }
        let discNumber = items.first(where: { matches($0, ["tpos", "discnumber", "disc number"]) }).flatMap { number(textValue($0)) }
        let yearText = items.first(where: { matches($0, ["tdrc", "tyer", "year", "date"]) }).map(textValue) ?? ""
        let year = Int(String(yearText.prefix(4)))
        let lyrics = items.first(where: { matches($0, ["uslt", "lyrics", "unsynchronized"]) }).map(textValue) ?? ""
        let artwork = items.first {
            $0.commonKey == .commonKeyArtwork || matches($0, ["artwork", "apic", "covr"])
        }?.dataValue

        return Song(
            title: embeddedTitle.isEmpty ? fallbackTitle : embeddedTitle,
            artist: embeddedArtist.isEmpty ? fallbackArtist : embeddedArtist,
            album: embeddedAlbum.isEmpty ? "Unknown Album" : embeddedAlbum,
            albumArtist: albumArtist.isEmpty ? (embeddedArtist.isEmpty ? fallbackArtist : embeddedArtist) : albumArtist,
            embeddedLyrics: lyrics.isEmpty ? nil : lyrics,
            trackNumber: trackNumber,
            discNumber: discNumber,
            genre: genre,
            duration: duration.isFinite ? duration : 0,
            fileName: fileName,
            artworkData: artwork
        )
    }

    static func filenameCandidates(for fileName: String) -> [FilenameCandidate] {
        let name = cleanedFilename(for: fileName)
        return filenameCandidates(from: name)
    }

    static func reliableFilenameCandidate(for fileName: String) -> FilenameCandidate? {
        let candidates = filenameCandidates(for: fileName)
        guard let first = candidates.first, candidates.count > 1 else { return nil }
        let firstWordCount = first.artist.split(whereSeparator: { $0 == " " }).count
        let secondWordCount = first.title.split(whereSeparator: { $0 == " " }).count
        if first.artist.contains(".") || (firstWordCount == 1 && secondWordCount >= 2) {
            return first
        }
        return nil
    }

    static func cleanedFilename(for fileName: String) -> String {
        var name = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        name = name.replacingOccurrences(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}-"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"\[[^\]]*\]|\([^\)]*\)|\{[^\}]*\}"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"^\s*\d+\s*[-_.]\s*"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"(?i)\b(official\s+lyrics?\s+video|official\s+music\s+video|official\s+visuali[sz]er|official\s+mv|official\s+audio|official\s+video|visuali[sz]er|lyrics?|lyric\s+video|mv|audio|video|hd|4k)\b"#, with: "", options: .regularExpression)
        return trimFilenameJunk(name)
    }

    private static func filenameCandidates(from name: String) -> [FilenameCandidate] {

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
        result = result.replacingOccurrences(of: #"[|#_•:;"'–—_-]+$"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"^[|#_•:;"'–—_-]+"#, with: "", options: .regularExpression)
        return result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct FilenameCandidate: Sendable {
    let artist: String
    let title: String
}

enum ArtworkMatchingConfiguration {
    static let version = 3
}

actor ArtworkCache {
    static let shared = ArtworkCache()
    private let directory: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = base
            .appendingPathComponent("ArtworkCache", isDirectory: true)
            .appendingPathComponent("v\(ArtworkMatchingConfiguration.version)", isDirectory: true)
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

    func reset() {
        let base = directory.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: base)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("Artwork cache reset: matching version \(ArtworkMatchingConfiguration.version)")
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

enum MusicBrainzConfiguration {
    static let userAgent = "OfflineMusic/1.0 (https://github.com/tuhamho/OM-premium)"
}

struct MusicBrainzHTTPResult {
    let data: Data
    let response: HTTPURLResponse?
    let diagnostics: [String]
    let errorDescription: String?
}

actor MusicBrainzRequestGate {
    private var available = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if available {
            available = false
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            available = true
        }
    }
}

actor MusicBrainzRequestScheduler {
    static let shared = MusicBrainzRequestScheduler()

    private let minimumStartInterval: TimeInterval = 1.15
    private let requestGate = MusicBrainzRequestGate()
    private var lastRequestStart: Date?
    private var requestNumber = 0

    func request(url: URL) async -> MusicBrainzHTTPResult {
        await requestGate.acquire()
        let result = await performRequest(url: url)
        await requestGate.release()
        return result
    }

    private func performRequest(url: URL) async -> MusicBrainzHTTPResult {
        var diagnostics: [String] = []

        for attempt in 1...5 {
            let sincePrevious = lastRequestStart.map { Date().timeIntervalSince($0) }
            let throttleWait = sincePrevious.map { max(0, minimumStartInterval - $0) } ?? 0
            if throttleWait > 0 {
                diagnostics.append(String(format: "Waiting for MusicBrainz throttle (%.2fs)...", throttleWait))
                try? await Task.sleep(nanoseconds: UInt64(throttleWait * 1_000_000_000))
            }

            requestNumber += 1
            let currentRequestNumber = requestNumber
            lastRequestStart = Date()
            diagnostics.append("Request \(currentRequestNumber), attempt \(attempt)")
            if let sincePrevious {
                diagnostics.append(String(format: "Previous request: %.2fs ago", sincePrevious))
            } else {
                diagnostics.append("Previous request: none")
            }

            var request = URLRequest(url: url)
            request.setValue(MusicBrainzConfiguration.userAgent, forHTTPHeaderField: "User-Agent")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let httpResponse = response as? HTTPURLResponse
                let status = httpResponse?.statusCode ?? -1
                diagnostics.append("HTTP status: \(status)")

                guard status == 503 || status == 429 else {
                    return MusicBrainzHTTPResult(data: data, response: httpResponse, diagnostics: diagnostics, errorDescription: nil)
                }

                let retryAfter = retryAfterSeconds(from: httpResponse)
                diagnostics.append(retryAfter.map { String(format: "Retry-After: %.2fs", $0) } ?? "Retry-After: none")
                guard attempt < 5 else {
                    let message = status == 503
                        ? "MusicBrainz temporarily unavailable (HTTP 503)"
                        : "MusicBrainz rate limited (HTTP 429)"
                    diagnostics.append(message)
                    return MusicBrainzHTTPResult(data: data, response: httpResponse, diagnostics: diagnostics, errorDescription: message)
                }

                let backoff = retryAfter ?? (pow(2.0, Double(attempt)) + Double.random(in: 0...0.25))
                diagnostics.append(String(format: "Waiting %.2fs before retry...", backoff))
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            } catch {
                let message = "MusicBrainz network error: \(error.localizedDescription)"
                diagnostics.append("HTTP status: unavailable")
                diagnostics.append(message)
                return MusicBrainzHTTPResult(data: Data(), response: nil, diagnostics: diagnostics, errorDescription: message)
            }
        }

        let message = "MusicBrainz request ended without a response"
        diagnostics.append(message)
        return MusicBrainzHTTPResult(data: Data(), response: nil, diagnostics: diagnostics, errorDescription: message)
    }

    private func retryAfterSeconds(from response: HTTPURLResponse?) -> TimeInterval? {
        guard let value = response?.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let seconds = Double(value) { return max(0, seconds) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}

actor ArtworkLookupService {
    static let shared = ArtworkLookupService()
    private var debugLogs: [String] = []

    func lookup(for song: Song) async -> ArtworkLookupResult {
        debugLogs = ["Searching MusicBrainz..."]
        guard song.title != "Unknown Title" else {
            debugLogs.append("No usable title")
            return ArtworkLookupResult(candidate: nil, album: nil, albumArtist: nil, albumReleaseID: nil, artwork: nil, applyFilenameMetadata: false, source: .none, logs: debugLogs)
        }
        let lookup = await matchingRelease(for: song)
        let match = lookup.match
        var artwork: Data?
        if let match {
            debugLogs.append("Song: \(song.title) — \(song.displayArtist)")
            debugLogs.append("Matched recording: \(match.matchedTitle)")
            debugLogs.append("Matched artist: \(match.matchedArtist)")
            debugLogs.append("Match score: \(match.score)")
            debugLogs.append(match.durationDifference.map { String(format: "Duration difference: %.1fs", $0) } ?? "Duration difference: unavailable")
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
                        if artwork != nil {
                            debugLogs.append("Release \(releaseID) artwork accepted: selected recording release")
                            break
                        }
                        debugLogs.append("Release \(releaseID) artwork rejected: image could not be decoded")
                    } else {
                        debugLogs.append("Release \(releaseID) artwork rejected: HTTP \(status)")
                    }
                } catch {
                    print("Artwork lookup failed:", error)
                    debugLogs.append("Cover Art Archive error: \(error.localizedDescription)")
                }
            }
            if artwork == nil { debugLogs.append("Artwork rejected: no usable artwork from selected recording releases") }
        }
        if let match {
            debugLogs.append(artwork == nil ? "MusicBrainz match found, artwork missing" : "MusicBrainz artwork found")
            print("MusicBrainz selected recording score:", match.score, "candidate:", match.candidate.artist, "/", match.candidate.title)
        } else {
            debugLogs.append("No acceptable MusicBrainz candidate")
        }

        if artwork == nil && lookup.canUseAppleFallback {
            if let apple = await AppleArtworkService.shared.lookup(for: song, artistOverride: match?.matchedArtist, titleOverride: match?.matchedTitle) {
                artwork = apple.artwork
                debugLogs.append(contentsOf: apple.logs)
                return ArtworkLookupResult(candidate: match?.candidate, album: match?.album, albumArtist: match?.albumArtist, albumReleaseID: match?.releaseIDs.first, artwork: artwork, applyFilenameMetadata: match?.applyFilenameMetadata ?? false, source: .apple, logs: debugLogs)
            }
            debugLogs.append("Apple fallback found no confident artwork")
        } else if artwork == nil {
            debugLogs.append("Apple fallback skipped because MusicBrainz was temporarily unavailable")
        }

        return ArtworkLookupResult(candidate: match?.candidate, album: match?.album, albumArtist: match?.albumArtist, albumReleaseID: match?.releaseIDs.first, artwork: artwork, applyFilenameMetadata: match?.applyFilenameMetadata ?? false, source: artwork == nil ? .none : .musicBrainz, logs: debugLogs)
    }

    func testConnection() async -> [String] {
        let query = "artist:\"The Beatles\" AND recording:\"Yesterday\""
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/recording/")
        components?.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "fmt", value: "json"), URLQueryItem(name: "limit", value: "1")]
        guard let url = components?.url else { return ["Could not create test URL"] }
        let result = await MusicBrainzRequestScheduler.shared.request(url: url)
        var lines = ["Request URL: \(url.absoluteString)", "User-Agent sent: \(MusicBrainzConfiguration.userAgent)"]
        lines.append(contentsOf: result.diagnostics)
        let status = result.response?.statusCode ?? -1
        guard (200...299).contains(status) else {
            lines.append(result.errorDescription ?? "MusicBrainz request failed (HTTP \(status))")
            let responseReceived = result.response == nil ? "no" : "yes"
            lines.append("Response received: \(responseReceived)")
            return lines
        }
        let decoded = try? JSONDecoder().decode(MusicBrainzResponse.self, from: result.data)
        lines.append("Response received: yes (\(result.data.count) bytes)")
        let decodedText = decoded == nil ? "no" : "yes"
        lines.append("JSON decoded: \(decodedText)")
        if let decoded {
            lines.append("Recordings returned: \(decoded.recordings.count)")
        }
        return lines
    }

    private func matchingRelease(for song: Song) async -> MusicBrainzLookupResult {
        let parsedCandidates = MetadataService.filenameCandidates(for: song.fileName)
        let current = FilenameCandidate(artist: song.artist, title: song.title)
        let filenameFallback = current.artist == "Unknown Artist" || parsedCandidates.contains(where: { normalized($0.artist) == normalized(current.artist) && normalized($0.title) == normalized(current.title) })
        let candidates = filenameFallback ? parsedCandidates : [current]

        var matches: [MusicBrainzMatch] = []
        var receivedSuccessfulResponse = false
        for candidate in candidates {
            let result = await searchMusicBrainz(for: candidate, duration: song.duration)
            receivedSuccessfulResponse = receivedSuccessfulResponse || result.receivedSuccessfulResponse
            if let match = result.match {
                matches.append(match)
            }
        }
        guard var best = matches.max(by: { $0.confidence < $1.confidence }) else {
            debugLogs.append("No MusicBrainz candidate passed the confidence threshold")
            return MusicBrainzLookupResult(match: nil, canUseAppleFallback: receivedSuccessfulResponse)
        }
        let secondBest = matches.filter { $0.candidate.artist != best.candidate.artist || $0.candidate.title != best.candidate.title }.max(by: { $0.confidence < $1.confidence })
        if let secondBest {
            debugLogs.append("Best candidate: \(best.score), second-best: \(secondBest.score)")
        } else {
            debugLogs.append("Best candidate: \(best.score), second-best: none")
        }
        guard secondBest == nil || best.confidence - secondBest!.confidence >= 12 else {
            debugLogs.append("Result rejected: candidates were too close")
            return MusicBrainzLookupResult(match: nil, canUseAppleFallback: receivedSuccessfulResponse)
        }
        print("MusicBrainz selected candidate:", best.candidate.artist, "/", best.candidate.title, "score:", best.score, "release IDs:", best.releaseIDs)
        debugLogs.append("Selected: \(best.candidate.artist) - \(best.candidate.title)")
        let releaseList = best.releaseIDs.joined(separator: ", ")
        debugLogs.append("Release IDs: \(releaseList)")
        best.applyFilenameMetadata = filenameFallback
        return MusicBrainzLookupResult(match: best, canUseAppleFallback: receivedSuccessfulResponse)
    }

    private func searchMusicBrainz(for candidate: FilenameCandidate, duration: Double) async -> MusicBrainzSearchResult {
        let artist = candidate.artist == "Unknown Artist" ? "" : candidate.artist
        let query = artist.isEmpty ? "recording:\"\(candidate.title)\"" : "artist:\"\(artist)\" AND recording:\"\(candidate.title)\""
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/recording/")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "5")
        ]
        guard let url = components?.url else {
            return MusicBrainzSearchResult(match: nil, receivedSuccessfulResponse: false)
        }

        debugLogs.append("MusicBrainz request URL: \(url.absoluteString)")
        debugLogs.append("User-Agent sent: \(MusicBrainzConfiguration.userAgent)")

        let response = await MusicBrainzRequestScheduler.shared.request(url: url)
        debugLogs.append(contentsOf: response.diagnostics)
        let status = response.response?.statusCode ?? -1
        debugLogs.append("MusicBrainz response bytes: \(response.data.count)")
        guard (200...299).contains(status) else {
            if let errorDescription = response.errorDescription {
                debugLogs.append(errorDescription)
            } else {
                debugLogs.append("MusicBrainz request failed (HTTP \(status))")
            }
            return MusicBrainzSearchResult(
                match: nil,
                receivedSuccessfulResponse: false
            )
        }
        let data = response.data
        guard let result = try? JSONDecoder().decode(MusicBrainzResponse.self, from: data) else {
            debugLogs.append("MusicBrainz JSON decode failed")
            return MusicBrainzSearchResult(match: nil, receivedSuccessfulResponse: true)
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
                let artistIsUnknown = normalizedArtist == "unknownartist" || normalizedArtist.isEmpty
                let artistSimilarity = artistIsUnknown ? 0 : similarity(resultArtist, normalizedArtist)
                let durationDifference = recording.length.flatMap { length in
                    duration > 0 ? abs(Double(length) / 1000 - duration) : nil
                }
                let durationMatches = durationDifference.map { $0 <= 8 } ?? true
                let artistMatches = artistIsUnknown ? !resultArtist.isEmpty : artistSimilarity >= 0.85
                guard (recording.score ?? 0) >= 90, titleSimilarity >= 0.90, artistMatches, durationMatches,
                      let release = recording.releases?.first else { return nil }
                var confidence = Double(recording.score ?? 0) + titleSimilarity * 20 + artistSimilarity * 20
                if let difference = durationDifference {
                    if difference <= 8 { confidence += 10 }
                }
                let releaseIDs = recording.releases?.compactMap(\.id) ?? []
                print("MusicBrainz candidate:", candidate.artist, "/", candidate.title, "score:", recording.score ?? 0, "recording:", recording.title ?? "", "release IDs:", releaseIDs)
                let albumArtist = release.artistCredit?.compactMap { $0.name ?? $0.artist?.name }.joined(separator: " ")
                let matchedArtist = recording.artistCredit?.compactMap { $0.name ?? $0.artist?.name }.joined(separator: ", ") ?? candidate.artist
                let matchedTitle = recording.title ?? candidate.title
                let matchedCandidate = FilenameCandidate(artist: matchedArtist, title: matchedTitle)
                debugLogs.append(String(format: "Accepted candidate: title %.2f, artist %.2f", titleSimilarity, artistSimilarity))
                debugLogs.append(durationDifference.map { String(format: "Duration difference: %.1fs", $0) } ?? "Duration difference: unavailable")
                return MusicBrainzMatch(candidate: matchedCandidate, releaseIDs: releaseIDs, score: recording.score ?? 0, confidence: confidence, album: release.title, albumArtist: albumArtist, matchedTitle: matchedTitle, matchedArtist: matchedArtist, durationDifference: durationDifference)
            }
        return MusicBrainzSearchResult(
            match: matches.max(by: { $0.confidence < $1.confidence }),
            receivedSuccessfulResponse: true
        )
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
    let albumReleaseID: String?
    let artwork: Data?
    let applyFilenameMetadata: Bool
    let source: ArtworkSource
    let logs: [String]
}

private struct MusicBrainzSearchResult {
    let match: MusicBrainzMatch?
    let receivedSuccessfulResponse: Bool
}

private struct MusicBrainzLookupResult {
    let match: MusicBrainzMatch?
    let canUseAppleFallback: Bool
}

enum ArtworkSource: Equatable {
    case none
    case musicBrainz
    case apple
}

actor AppleArtworkService {
    static let shared = AppleArtworkService()
    private var lastRequest = Date.distantPast

    func lookup(for song: Song, artistOverride: String? = nil, titleOverride: String? = nil) async -> AppleArtworkResult? {
        let artist = artistOverride ?? (song.artist == "Unknown Artist" ? "" : song.artist)
        let title = titleOverride ?? song.title
        guard !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              artist.caseInsensitiveCompare("Unknown Artist") != .orderedSame else {
            print("Apple artwork rejected: artist is unknown")
            return nil
        }
        let query = [artist, title].filter { !$0.isEmpty }.joined(separator: " ")
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

        let expectedTitle = normalized(title)
        let expectedArtist = normalized(artist)
        let candidates = decoded.results.compactMap { result -> (AppleTrack, Double, Double, Double, Double?)? in
            guard let resultTitle = result.trackName, let resultArtist = result.artistName else { return nil }
            let titleScore = similarity(normalized(resultTitle), expectedTitle)
            let artistScore = similarity(normalized(resultArtist), expectedArtist)
            let durationDifference = song.duration > 0 ? result.trackTimeMillis.map { abs(Double($0) / 1000 - song.duration) } : nil
            guard titleScore >= 0.90, artistScore >= 0.85, durationDifference.map({ $0 <= 8 }) ?? true else { return nil }
            let durationScore = durationDifference.map { max(0, 1 - $0 / 8) } ?? 0.5
            let confidence = titleScore * 0.55 + artistScore * 0.35 + durationScore * 0.10
            return (result, confidence, titleScore, artistScore, durationDifference)
        }
        guard let best = candidates.max(by: { $0.1 < $1.1 }), best.1 >= 0.85 else {
            logs.append("Apple result rejected: no confident match")
            print(logs.joined(separator: "\n"))
            return nil
        }

        let selected = best.0
        let selectedTitle = selected.trackName ?? ""
        let selectedArtist = selected.artistName ?? ""
        logs.append("Apple selected: \(selectedTitle) — \(selectedArtist)")
        logs.append(String(format: "Apple confidence: %.0f%%", best.1 * 100))
        logs.append(String(format: "Apple title similarity: %.2f, artist similarity: %.2f", best.2, best.3))
        logs.append(best.4.map { String(format: "Apple duration difference: %.1fs", $0) } ?? "Apple duration difference: unavailable")
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
    let matchedTitle: String
    let matchedArtist: String
    let durationDifference: Double?
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
    @Published var speed: Float = UserDefaults.standard.object(forKey: "playbackSpeed") as? Float ?? 1

    private var player: AVPlayer?
    private weak var store: MusicStore?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var playbackContext: [Song] = []
    private var randomPlayedIDs: Set<UUID> = []
    private var playbackHistory: [UUID] = []
    private var historyIndex = -1
    private var manualQueueIDs: Set<UUID> = []

    func configure(with store: MusicStore) {
        self.store = store
        store.sleepTimer.attach { [weak self] in self?.pause() }
        if store.resumeSession, let restored = store.song(store.currentSongID) {
            currentSong = restored
            duration = restored.duration
            elapsed = store.savedPosition
            playbackContext = store.songs
            randomPlayedIDs = [restored.id]
            playbackHistory = [restored.id]
            historyIndex = 0
            queue = playbackContext
        }
        configureAudioSession(); configureRemoteCommands()
    }
    func syncCurrentSong(_ song: Song) {
        guard currentSong?.id == song.id else { return }
        currentSong = song
        updateNowPlaying()
    }
    private func configureAudioSession() { try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: []); try? AVAudioSession.sharedInstance().setActive(true) }

    func play(_ song: Song, from list: [Song]? = nil) {
        if currentSong?.id == song.id, list == nil {
            if !isPlaying { player?.play(); isPlaying = true }
            return
        }
        let context = deduplicated(list ?? [song])
        playbackContext = context.isEmpty ? [song] : context
        randomPlayedIDs = [song.id]
        playbackHistory = [song.id]
        historyIndex = 0
        manualQueueIDs.removeAll()
        queue = playbackContext
        load(song, recordHistory: false)
    }

    private func load(_ song: Song, recordHistory: Bool) {
        if recordHistory {
            if historyIndex < playbackHistory.count - 1 {
                playbackHistory = Array(playbackHistory.prefix(historyIndex + 1))
            }
            playbackHistory.append(song.id)
            historyIndex = playbackHistory.count - 1
        }
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
    func previous() {
        if elapsed > 3 { seek(to: 0); return }
        guard historyIndex > 0 else { seek(to: 0); return }
        historyIndex -= 1
        guard let song = store?.song(playbackHistory[historyIndex]) else { seek(to: 0); return }
        load(song, recordHistory: false)
    }
    func next() { advance() }
    private func advance() {
        guard let current = currentSong else { return }
        if store?.sleepTimer.currentSongEnded() == true { return }
        if repeatMode == .one { seek(to: 0); resume(); return }

        if let next = nextManualSong(after: current) {
            manualQueueIDs.remove(current.id)
            load(next, recordHistory: true)
            return
        }

        guard let next = nextRandomSong(excluding: current.id) else {
            pause()
            seek(to: 0)
            return
        }
        randomPlayedIDs.insert(next.id)
        load(next, recordHistory: true)
    }

    private func nextManualSong(after current: Song) -> Song? {
        guard let index = queue.firstIndex(where: { $0.id == current.id }) else {
            return queue.first(where: { manualQueueIDs.contains($0.id) })
        }
        return queue.dropFirst(index + 1).first(where: { manualQueueIDs.contains($0.id) })
    }

    private func nextRandomSong(excluding currentID: UUID) -> Song? {
        let candidates = playbackContext.filter { $0.id != currentID && !randomPlayedIDs.contains($0.id) }
        if let next = candidates.randomElement() { return next }
        randomPlayedIDs = [currentID]
        return playbackContext.filter { $0.id != currentID }.randomElement()
    }

    private func deduplicated(_ songs: [Song]) -> [Song] {
        var seen = Set<UUID>()
        return songs.filter { seen.insert($0.id).inserted }
    }

    func addToQueue(_ song: Song) {
        guard !queue.contains(where: { $0.id == song.id }) else { return }
        queue.append(song)
        manualQueueIDs.insert(song.id)
    }

    func playNext(_ song: Song) {
        queue.removeAll { $0.id == song.id }
        manualQueueIDs.remove(song.id)
        if let currentSong, let index = queue.firstIndex(where: { $0.id == currentSong.id }) {
            queue.insert(song, at: index + 1)
        } else {
            queue.insert(song, at: 0)
        }
        manualQueueIDs.insert(song.id)
    }

    func clearQueue() {
        manualQueueIDs.removeAll()
        if let currentSong { queue = [currentSong] } else { queue.removeAll() }
    }
    func setRate(_ rate: Float) { speed = rate; UserDefaults.standard.set(rate, forKey: "playbackSpeed"); player?.rate = isPlaying ? rate : 0; if !isPlaying { player?.pause() } }
    private func updateNowPlaying() { guard let song = currentSong else { return }; var info: [String: Any] = [MPMediaItemPropertyTitle: song.title, MPMediaItemPropertyArtist: song.displayArtist, MPMediaItemPropertyAlbumTitle: song.displayAlbum, MPMediaItemPropertyPlaybackDuration: max(duration, song.duration), MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed, MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0]; if let data = song.artworkData, let image = UIImage(data: data) { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image } }; MPNowPlayingInfoCenter.default().nowPlayingInfo = info }
    private func configureRemoteCommands() { let c = MPRemoteCommandCenter.shared(); c.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }; c.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }; c.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }; c.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }; c.changePlaybackPositionCommand.addTarget { [weak self] event in if let e = event as? MPChangePlaybackPositionCommandEvent { self?.seek(to: e.positionTime) }; return .success } }
}
