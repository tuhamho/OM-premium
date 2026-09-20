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

    init(id: UUID = UUID(), title: String, artist: String, album: String, albumArtist: String = "", musicBrainzReleaseID: String? = nil, embeddedLyrics: String? = nil, manualLyrics: String? = nil, cachedOnlineLyrics: String? = nil, trackNumber: Int? = nil, discNumber: Int? = nil, genre: String = "", year: Int? = nil, duration: Double = 0, fileName: String, artworkData: Data? = nil, importedAt: Date = .now, lastPlayed: Date? = nil, playCount: Int = 0, isFavorite: Bool = false) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.musicBrainzReleaseID = musicBrainzReleaseID
        self.embeddedLyrics = embeddedLyrics
        self.manualLyrics = manualLyrics
        self.cachedOnlineLyrics = cachedOnlineLyrics
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
        case id, title, artist, album, albumArtist, musicBrainzReleaseID, embeddedLyrics, manualLyrics, cachedOnlineLyrics, trackNumber, discNumber, genre, year, duration, fileName, artworkData, importedAt, lastPlayed, playCount, isFavorite
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

struct SyncedLyricLine: Identifiable, Codable, Hashable {
    let id: UUID
    let time: TimeInterval
    let text: String

    init(id: UUID = UUID(), time: TimeInterval, text: String) {
        self.id = id
        self.time = time
        self.text = text
    }
}

struct LocalLyrics: Codable, Hashable {
    let syncedLines: [SyncedLyricLine]
    let plainText: String

    var isSynced: Bool { !syncedLines.isEmpty }
    var text: String {
        if !plainText.isEmpty { return plainText }
        return syncedLines.map(\.text).joined(separator: "\n")
    }

    static func plain(_ value: String) -> LocalLyrics? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return LocalLyrics(syncedLines: [], plainText: text)
    }
}

struct Playlist: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var songIDs: [UUID] = []
    var createdAt: Date = .now
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
enum LibraryFilter: String, CaseIterable { case songs = "Songs", albums = "Albums", artists = "Artists", playlists = "Playlists", favorites = "Favorites" }
enum SortMode: String, CaseIterable { case recentlyAdded = "Recently Added", title = "Title", artist = "Artist", album = "Album", mostPlayed = "Most Played", duration = "Duration" }

extension Color {
    static let ink = Color(red: 0.071, green: 0.071, blue: 0.071)
    static let card = Color(red: 0.094, green: 0.094, blue: 0.094)
    static let cardLight = Color(red: 0.125, green: 0.125, blue: 0.125)
    static let lime = Color(red: 0.114, green: 0.725, blue: 0.329)
    static let muted = Color(red: 0.70, green: 0.70, blue: 0.70)
}
