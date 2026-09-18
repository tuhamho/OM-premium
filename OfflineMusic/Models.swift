import Foundation
import SwiftUI

struct Song: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var artist: String
    var album: String
    var albumArtist: String = ""
    var genre: String = ""
    var year: Int?
    var duration: Double = 0
    var fileName: String
    var artworkData: Data?
    var importedAt: Date = .now
    var lastPlayed: Date?
    var playCount: Int = 0
    var isFavorite: Bool = false

    var displayArtist: String { artist.isEmpty ? "Unknown Artist" : artist }
    var displayAlbum: String { album.isEmpty ? "Unknown Album" : album }
    var durationText: String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct Playlist: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var songIDs: [UUID] = []
    var createdAt: Date = .now
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
