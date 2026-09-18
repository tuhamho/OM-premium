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

    private let stateURL: URL
    private let fm = FileManager.default

    init() {
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        stateURL = support.appendingPathComponent("library.json")
    }

    var audioDirectory: URL {
        let dir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Audio")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func load() async {
        guard let data = try? Data(contentsOf: stateURL), let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        songs = state.songs; playlists = state.playlists; recentlyPlayed = state.recentlyPlayed; currentSongID = state.currentSongID; savedPosition = state.savedPosition
    }

    func save() {
        let state = PersistedState(songs: songs, playlists: playlists, recentlyPlayed: recentlyPlayed, currentSongID: currentSongID, savedPosition: savedPosition)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL, options: .atomic) }
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
                metadata.fileName = destination.lastPathComponent
                songs.append(metadata)
                imported += 1
            } catch { continue }
        }
        save(); return imported
    }

    func toggleFavorite(_ song: Song) { update(song.id) { $0.isFavorite.toggle() }; save() }
    func update(_ id: UUID, _ change: (inout Song) -> Void) { guard let i = songs.firstIndex(where: { $0.id == id }) else { return }; change(&songs[i]) }
    func song(_ id: UUID?) -> Song? { songs.first { $0.id == id } }
    func markPlayed(_ id: UUID) { update(id) { $0.playCount += 1; $0.lastPlayed = .now }; recentlyPlayed.removeAll { $0 == id }; recentlyPlayed.insert(id, at: 0); recentlyPlayed = Array(recentlyPlayed.prefix(30)); currentSongID = id; save() }
    func delete(_ song: Song) { try? fm.removeItem(at: audioDirectory.appendingPathComponent(song.fileName)); songs.removeAll { $0.id == song.id }; playlists.indices.forEach { playlists[$0].songIDs.removeAll { $0 == song.id } }; save() }
    func addPlaylist(name: String) { playlists.append(Playlist(name: name)); save() }
    func songs(in playlist: Playlist) -> [Song] { playlist.songIDs.compactMap(song) }
}

private struct PersistedState: Codable { var songs: [Song]; var playlists: [Playlist]; var recentlyPlayed: [UUID]; var currentSongID: UUID?; var savedPosition: Double }

struct MetadataService {
    static func read(asset: AVURLAsset, fileName: String) async throws -> Song {
        let duration = try await asset.load(.duration).seconds
        let items = try await asset.load(.commonMetadata)
        func value(_ identifier: AVMetadataIdentifier) -> String { items.first(where: { $0.identifier == identifier })?.stringValue ?? "" }
        let title = value(.commonIdentifierTitle).isEmpty ? URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent : value(.commonIdentifierTitle)
        return Song(
        title: title,
        artist: value(.commonIdentifierArtist),
        album: value(.commonIdentifierAlbumName),
        albumArtist: value(.commonIdentifierArtist),
        duration: duration.isFinite ? duration : 0,
        fileName: fileName,
        artworkData: items.first(where: { $0.commonKey == .commonKeyArtwork })?.dataValue
        )
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
    private func configureAudioSession() { try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: []); try? AVAudioSession.sharedInstance().setActive(true) }

    func play(_ song: Song, from list: [Song]? = nil) {
        if currentSong?.id == song.id { if !isPlaying { player?.play(); isPlaying = true }; return }
        if let list { queue = list }
        currentSong = song; duration = song.duration; store?.markPlayed(song.id); elapsed = 0
        let url = store?.audioDirectory.appendingPathComponent(song.fileName)
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
