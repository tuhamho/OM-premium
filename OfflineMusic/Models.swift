import Foundation
import SwiftUI

enum SearchNormalization {
    static func value(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func matches(_ query: String, in fields: [String]) -> Bool {
        let normalizedQuery = value(query)
        guard !normalizedQuery.isEmpty else { return true }
        return fields.contains { value($0).contains(normalizedQuery) }
    }
}

struct SongSearchIndex: Hashable, Sendable {
    let songID: UUID
    let normalizedTitle: String
    let normalizedArtist: String
    let normalizedAlbum: String
    let normalizedAlbumArtist: String
    let normalizedGenre: String
    let normalizedFilename: String
    let combinedText: String
    let isFavorite: Bool

    init(song: Song) {
        songID = song.id
        normalizedTitle = SearchNormalization.value(song.title)
        normalizedArtist = SearchNormalization.value(song.displayArtist)
        normalizedAlbum = SearchNormalization.value(song.displayAlbum)
        normalizedAlbumArtist = SearchNormalization.value(song.albumArtist)
        normalizedGenre = SearchNormalization.value(song.genre)
        normalizedFilename = SearchNormalization.value(song.fileName)
        combinedText = [song.title, song.displayArtist, song.displayAlbum, song.albumArtist, song.genre, song.fileName]
            .map(SearchNormalization.value)
            .joined(separator: " ")
        isFavorite = song.isFavorite
    }
}

struct SongFileFingerprint: Codable, Hashable, Sendable {
    let relativePath: String
    let fileSize: Int64
    let modificationDate: Date
}

struct Song: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var artist: String
    var album: String
    var albumArtist: String = ""
    var musicBrainzReleaseID: String?
    var embeddedLyrics: String?
    var manualLyrics: String?
    var cachedOnlineLyrics: String?
    var importedLyricsFileName: String?
    var lyricsOffset: Double = 0
    var fileFingerprint: SongFileFingerprint?
    var trackNumber: Int?
    var discNumber: Int?
    var genre: String = ""
    var year: Int?
    var duration: Double = 0
    var fileName: String
    var artworkData: Data?
    var importedAt: Date = .now
    var lastPlayed: Date?
    var playCount: Int = 0
    var isFavorite: Bool = false

    init(id: UUID = UUID(), title: String, artist: String, album: String, albumArtist: String = "", musicBrainzReleaseID: String? = nil, embeddedLyrics: String? = nil, manualLyrics: String? = nil, cachedOnlineLyrics: String? = nil, importedLyricsFileName: String? = nil, lyricsOffset: Double = 0, fileFingerprint: SongFileFingerprint? = nil, trackNumber: Int? = nil, discNumber: Int? = nil, genre: String = "", year: Int? = nil, duration: Double = 0, fileName: String, artworkData: Data? = nil, importedAt: Date = .now, lastPlayed: Date? = nil, playCount: Int = 0, isFavorite: Bool = false) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.musicBrainzReleaseID = musicBrainzReleaseID
        self.embeddedLyrics = embeddedLyrics
        self.manualLyrics = manualLyrics
        self.cachedOnlineLyrics = cachedOnlineLyrics
        self.importedLyricsFileName = importedLyricsFileName
        self.lyricsOffset = lyricsOffset
        self.fileFingerprint = fileFingerprint
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.genre = genre
        self.year = year
        self.duration = duration
        self.fileName = fileName
        self.artworkData = artworkData
        self.importedAt = importedAt
        self.lastPlayed = lastPlayed
        self.playCount = playCount
        self.isFavorite = isFavorite
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, artist, album, albumArtist, musicBrainzReleaseID, embeddedLyrics, manualLyrics, cachedOnlineLyrics, importedLyricsFileName, lyricsOffset, fileFingerprint, trackNumber, discNumber, genre, year, duration, fileName, artworkData, importedAt, lastPlayed, playCount, isFavorite
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Unknown Title"
        artist = try container.decodeIfPresent(String.self, forKey: .artist) ?? "Unknown Artist"
        album = try container.decodeIfPresent(String.self, forKey: .album) ?? "Unknown Album"
        albumArtist = try container.decodeIfPresent(String.self, forKey: .albumArtist) ?? ""
        musicBrainzReleaseID = try container.decodeIfPresent(String.self, forKey: .musicBrainzReleaseID)
        embeddedLyrics = try container.decodeIfPresent(String.self, forKey: .embeddedLyrics)
        manualLyrics = try container.decodeIfPresent(String.self, forKey: .manualLyrics)
        cachedOnlineLyrics = try container.decodeIfPresent(String.self, forKey: .cachedOnlineLyrics)
        importedLyricsFileName = try container.decodeIfPresent(String.self, forKey: .importedLyricsFileName)
        lyricsOffset = try container.decodeIfPresent(Double.self, forKey: .lyricsOffset) ?? 0
        fileFingerprint = try container.decodeIfPresent(SongFileFingerprint.self, forKey: .fileFingerprint)
        trackNumber = try container.decodeIfPresent(Int.self, forKey: .trackNumber)
        discNumber = try container.decodeIfPresent(Int.self, forKey: .discNumber)
        genre = try container.decodeIfPresent(String.self, forKey: .genre) ?? ""
        year = try container.decodeIfPresent(Int.self, forKey: .year)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName) ?? ""
        artworkData = try container.decodeIfPresent(Data.self, forKey: .artworkData)
        importedAt = try container.decodeIfPresent(Date.self, forKey: .importedAt) ?? .now
        lastPlayed = try container.decodeIfPresent(Date.self, forKey: .lastPlayed)
        playCount = try container.decodeIfPresent(Int.self, forKey: .playCount) ?? 0
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encode(album, forKey: .album)
        try container.encode(albumArtist, forKey: .albumArtist)
        try container.encodeIfPresent(musicBrainzReleaseID, forKey: .musicBrainzReleaseID)
        try container.encodeIfPresent(embeddedLyrics, forKey: .embeddedLyrics)
        try container.encodeIfPresent(manualLyrics, forKey: .manualLyrics)
        try container.encodeIfPresent(cachedOnlineLyrics, forKey: .cachedOnlineLyrics)
        try container.encodeIfPresent(importedLyricsFileName, forKey: .importedLyricsFileName)
        try container.encode(lyricsOffset, forKey: .lyricsOffset)
        try container.encodeIfPresent(fileFingerprint, forKey: .fileFingerprint)
        try container.encodeIfPresent(trackNumber, forKey: .trackNumber)
        try container.encodeIfPresent(discNumber, forKey: .discNumber)
        try container.encode(genre, forKey: .genre)
        try container.encodeIfPresent(year, forKey: .year)
        try container.encode(duration, forKey: .duration)
        try container.encode(fileName, forKey: .fileName)
        try container.encodeIfPresent(artworkData, forKey: .artworkData)
        try container.encode(importedAt, forKey: .importedAt)
        try container.encodeIfPresent(lastPlayed, forKey: .lastPlayed)
        try container.encode(playCount, forKey: .playCount)
        try container.encode(isFavorite, forKey: .isFavorite)
    }

    var displayArtist: String { artist.isEmpty ? "Unknown Artist" : artist }
    var displayAlbum: String { album.isEmpty ? "Unknown Album" : album }
    var lyrics: String? {
        let manual = manualLyrics?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !manual.isEmpty { return manual }
        let embedded = embeddedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !embedded.isEmpty { return embedded }
        let cached = cachedOnlineLyrics?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cached.isEmpty ? nil : cached
    }
    var durationText: String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct SyncedLyricWord: Identifiable, Codable, Hashable {
    let id: UUID
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval?

    init(id: UUID = UUID(), text: String, startTime: TimeInterval, endTime: TimeInterval? = nil) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }
}

struct SyncedLyricLine: Identifiable, Codable, Hashable {
    let id: UUID
    let lineTime: TimeInterval
    let words: [SyncedLyricWord]
    let plainText: String

    init(id: UUID = UUID(), lineTime: TimeInterval, words: [SyncedLyricWord] = [], plainText: String) {
        self.id = id
        self.lineTime = lineTime
        self.words = words
        self.plainText = plainText
    }

    var time: TimeInterval { lineTime }
    var text: String { plainText }
    var hasWordTiming: Bool { !words.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case id, lineTime, time, words, plainText, text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        if let value = try container.decodeIfPresent(TimeInterval.self, forKey: .lineTime) {
            lineTime = value
        } else {
            lineTime = try container.decodeIfPresent(TimeInterval.self, forKey: .time) ?? 0
        }
        words = try container.decodeIfPresent([SyncedLyricWord].self, forKey: .words) ?? []
        if let value = try container.decodeIfPresent(String.self, forKey: .plainText) {
            plainText = value
        } else {
            plainText = try container.decodeIfPresent(String.self, forKey: .text) ?? words.map(\.text).joined()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(lineTime, forKey: .lineTime)
        try container.encode(words, forKey: .words)
        try container.encode(plainText, forKey: .plainText)
    }
}

struct LocalLyrics: Codable, Hashable {
    let syncedLines: [SyncedLyricLine]
    let plainText: String
    let fileProvidedOffset: TimeInterval

    init(syncedLines: [SyncedLyricLine], plainText: String, fileProvidedOffset: TimeInterval = 0) {
        self.syncedLines = syncedLines
        self.plainText = plainText
        self.fileProvidedOffset = fileProvidedOffset
    }

    var isSynced: Bool { !syncedLines.isEmpty }
    var isEnhanced: Bool { syncedLines.contains(where: \.hasWordTiming) }
    var text: String {
        if !plainText.isEmpty { return plainText }
        return syncedLines.map(\.text).joined(separator: "\n")
    }

    static func plain(_ value: String) -> LocalLyrics? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return LocalLyrics(syncedLines: [], plainText: text)
    }

    private enum CodingKeys: String, CodingKey {
        case syncedLines, plainText, fileProvidedOffset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        syncedLines = try container.decodeIfPresent([SyncedLyricLine].self, forKey: .syncedLines) ?? []
        plainText = try container.decodeIfPresent(String.self, forKey: .plainText) ?? ""
        fileProvidedOffset = try container.decodeIfPresent(TimeInterval.self, forKey: .fileProvidedOffset) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(syncedLines, forKey: .syncedLines)
        try container.encode(plainText, forKey: .plainText)
        try container.encode(fileProvidedOffset, forKey: .fileProvidedOffset)
    }
}

struct Playlist: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var songIDs: [UUID] = []
    var createdAt: Date = .now
}

struct ListeningEvent: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    let songID: UUID
    let startedAt: Date
    let endedAt: Date
    let listenedSeconds: Double
    let completed: Bool
    let qualified: Bool
    let wasFirstListen: Bool
}

enum ListeningStatsRange: String, CaseIterable, Identifiable {
    case today = "Today"
    case week = "7 Days"
    case month = "30 Days"
    var id: String { rawValue }
}

struct ListeningSongStat: Identifiable {
    let id: UUID
    let songID: UUID
    let plays: Int
    let listenedSeconds: Double
}

struct ListeningArtistStat: Identifiable {
    let id: String
    let name: String
    let plays: Int
    let listenedSeconds: Double
}

struct ListeningStatsSnapshot {
    var listenedSeconds: Double = 0
    var plays: Int = 0
    var uniqueSongCount: Int = 0
    var firstListenCount: Int = 0
    var topSongs: [ListeningSongStat] = []
    var topArtists: [ListeningArtistStat] = []
}

struct ArtistGroup: Identifiable {
    let id: String
    let name: String
    let songs: [Song]

    var representativeSong: Song? {
        songs.first(where: { $0.artworkData != nil }) ?? songs.first
    }
}

struct AlbumGroup: Identifiable {
    let id: String
    let name: String
    let artist: String
    let songs: [Song]

    var representativeSong: Song? {
        songs.first(where: { $0.artworkData != nil }) ?? songs.first
    }
}

enum RepeatMode: String, Codable, CaseIterable { case off, all, one }
enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case system = "System"
    case dark = "Dark"
    case light = "Light"
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

enum AccentColorChoice: String, Codable, CaseIterable, Identifiable {
    case green = "Green"
    case blue = "Blue"
    case purple = "Purple"
    case pink = "Pink"
    case orange = "Orange"
    case red = "Red"
    var id: String { rawValue }

    var color: Color {
        switch self {
        case .green: return .lime
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .orange: return .orange
        case .red: return .red
        }
    }
}

enum LibraryFilter: String, CaseIterable { case songs = "Songs", albums = "Albums", artists = "Artists", playlists = "Playlists", favorites = "Favorites" }
enum SortMode: String, CaseIterable { case recentlyAdded = "Recently Added", title = "Title", artist = "Artist", album = "Album", mostPlayed = "Most Played", duration = "Duration" }

extension Color {
    static let ink = Color(red: 0.071, green: 0.071, blue: 0.071)
    static let card = Color(red: 0.094, green: 0.094, blue: 0.094)
    static let cardLight = Color(red: 0.125, green: 0.125, blue: 0.125)
    static let lime = Color(red: 0.114, green: 0.725, blue: 0.329)
    static let muted = Color(red: 0.70, green: 0.70, blue: 0.70)
}
