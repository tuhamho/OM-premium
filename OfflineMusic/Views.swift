import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct RootView: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: AudioPlayerService
    @State private var tab = 0
    @State private var showNowPlaying = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case 1: LibraryView()
                case 2: PlaylistsView()
                case 3: SettingsView()
                default: HomeView()
                }
            }
            .safeAreaPadding(.bottom, player.currentSong == nil ? 62 : 126)
            VStack(spacing: 0) {
                if let song = player.currentSong {
                    MiniPlayer(song: song) { showNowPlaying = true }
                }
                HStack {
                    tabButton("house.fill", "Home", 0)
                    tabButton("music.note.list", "Library", 1)
                    tabButton("rectangle.stack.fill", "Playlists", 2)
                    tabButton("gearshape.fill", "Settings", 3)
                }
                .padding(.top, 10).padding(.bottom, 8)
                .background(.ultraThinMaterial)
            }
        }
        .background(Color.ink.ignoresSafeArea())
        .sheet(isPresented: $showNowPlaying) { NowPlayingView() }
    }

    private func tabButton(_ icon: String, _ text: String, _ value: Int) -> some View {
        Button { tab = value } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 19, weight: .semibold))
                Text(text).font(.caption2)
            }
            .foregroundStyle(tab == value ? Color.lime : .white.opacity(0.55))
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel(text)
    }
}

struct HomeView: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: AudioPlayerService

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        return hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
    }

    private var uniqueAlbums: [Song] {
        Dictionary(grouping: store.songs, by: { $0.displayAlbum }).compactMap { $0.value.first }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text(greeting)
                        .font(.largeTitle.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 12)
                    if store.songs.isEmpty {
                        EmptyState(title: "Your music, your way", message: "Import local audio files to start building your library.", icon: "waveform")
                    } else {
                        section("Recently Played", songs: store.recentlyPlayed.compactMap(store.song))
                        section("Recently Added", songs: Array(store.songs.sorted { $0.importedAt > $1.importedAt }.prefix(10)))
                        section("Albums", songs: uniqueAlbums)
                        section("Favorites", songs: store.songs.filter(\.isFavorite))
                    }
                }
                .padding(.horizontal, 20)
            }
            .background(Color.ink)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Image(systemName: "bell").foregroundStyle(.white)
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, songs: [Song]) -> some View {
        if !songs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.title3.bold())
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(songs) { song in
                            SongCard(song: song) { player.play(song, from: store.songs) }
                        }
                    }
                }
            }
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: AudioPlayerService
    @State private var search = ""
    @State private var filter: LibraryFilter = .songs
    @State private var sort: SortMode = .recentlyAdded
    @State private var importing = false

    private var filtered: [Song] {
        var result = store.songs
        if filter == .favorites { result = result.filter(\.isFavorite) }
        if !search.isEmpty {
            result = result.filter { "\($0.title) \($0.artist) \($0.album)".localizedCaseInsensitiveContains(search) }
        }
        switch sort {
        case .title: result.sort { $0.title < $1.title }
        case .artist: result.sort { $0.artist < $1.artist }
        case .album: result.sort { $0.album < $1.album }
        case .mostPlayed: result.sort { $0.playCount > $1.playCount }
        case .duration: result.sort { $0.duration > $1.duration }
        default: result.sort { $0.importedAt > $1.importedAt }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                if store.songs.isEmpty {
                    EmptyState(title: "Library is empty", message: "Use Import to add MP3, M4A, AAC, WAV, or FLAC files.", icon: "plus.circle")
                } else {
                    ForEach(filtered) { song in
                        SongRow(song: song) { player.play(song, from: filtered) }
                            .swipeActions {
                                Button(role: .destructive) { store.delete(song) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button { store.toggleFavorite(song) } label: {
                                    Label("Favorite", systemImage: song.isFavorite ? "heart.slash" : "heart")
                                }.tint(.pink)
                            }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.ink)
            .navigationTitle("Your Library")
            .searchable(text: $search, prompt: "Songs, artists, albums")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(LibraryFilter.allCases, id: \.self) { value in
                            Button(value.rawValue) { filter = value }
                        }
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(SortMode.allCases, id: \.self) { value in
                            Button(value.rawValue) { sort = value }
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importing = true } label: { Image(systemName: "plus") }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    Task { _ = await store.importFiles(urls) }
                }
            }
        }
    }
}

struct PlaylistsView: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: AudioPlayerService
    @State private var showingAdd = false
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.playlists) { playlist in
                        NavigationLink {
                            PlaylistDetail(playlist: playlist)
                        } label: {
                            HStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 58, height: 58)
                                    .overlay { Image(systemName: "music.note").font(.title2) }
                                VStack(alignment: .leading) {
                                    Text(playlist.name).font(.headline)
                                    Text("\(playlist.songIDs.count) songs")
                                        .foregroundStyle(Color.muted)
                                        .font(.subheadline)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        store.playlists.remove(atOffsets: offsets)
                        store.save()
                    }
                } header: {
                    Button { showingAdd = true } label: {
                        Label("New Playlist", systemImage: "plus.circle.fill")
                            .foregroundStyle(Color.lime)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.ink)
            .navigationTitle("Playlists")
            .alert("New Playlist", isPresented: $showingAdd) {
                TextField("Name", text: $name)
                Button("Create") {
                    if !name.isEmpty {
                        store.addPlaylist(name: name)
                        name = ""
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

struct PlaylistDetail: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: AudioPlayerService
    let playlist: Playlist

    var body: some View {
        let songs = store.songs(in: playlist)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                RoundedRectangle(cornerRadius: 24)
                    .fill(LinearGradient(colors: [.purple, .blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 220)
                    .overlay { Image(systemName: "music.note.list").font(.system(size: 70)).foregroundStyle(.white.opacity(0.8)) }
                Text(playlist.name).font(.largeTitle.bold())
                Text("\(songs.count) songs").foregroundStyle(Color.muted)
                HStack {
                    Button {
                        if let first = songs.first { player.play(first, from: songs) }
                    } label: {
                        Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.lime)
                    Button {
                        let shuffledSongs = songs.shuffled()
                        if let first = shuffledSongs.first {
                            player.shuffle = true
                            player.play(first, from: shuffledSongs)
                        }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                ForEach(songs) { song in
                    SongRow(song: song) { player.play(song, from: songs) }
                }
            }
            .padding(20)
        }
        .background(Color.ink)
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: AudioPlayerService
    private let playbackSpeeds: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        NavigationStack {
            Form {
                Section("Playback") {
                    Toggle("Resume previous session", isOn: $store.resumeSession)
                    Picker("Playback speed", selection: Binding(get: { player.speed }, set: { player.setRate($0) })) {
                        ForEach(playbackSpeeds, id: \.self) { speed in
                            Text(speedLabel(for: speed)).tag(speed)
                        }
                    }
                }
                Section("Appearance") {
                    Toggle("Pure black OLED theme", isOn: $store.oledTheme)
                }
                Section("Library") {
                    Button("Rescan files") {
                        Task {
                            await store.rescanDocuments()
                        }
                    }
                    .disabled(store.isScanning)

                    if store.isScanning {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView()
                            Text("Scanning music...")
                            Text("\(store.scanProgress) / \(store.scanTotal)")
                                .foregroundStyle(Color.muted)
                        }
                    } else if !store.scanMessage.isEmpty {
                        Text(store.scanMessage)
                            .foregroundStyle(Color.muted)
                    }

                    Button("Clear artwork cache") {}
                    Text("\(store.songs.count) songs • \(store.songs.reduce(0) { $0 + Int($1.duration) / 60 }) minutes")
                        .foregroundStyle(Color.muted)
                }
                Section("About") {
                    LabeledContent("Version", value: "1.0.0")
                    LabeledContent("Device", value: UIDevice.current.model)
                    LabeledContent("iOS", value: UIDevice.current.systemVersion)
                }
            }
            .scrollContentBackground(.hidden)
            .background(store.oledTheme ? Color.black : Color.ink)
            .navigationTitle("Settings")
        }
    }

    private func speedLabel(for speed: Float) -> String {
        speed == 1.0 ? "1x" : String(format: "%.2gx", speed)
    }
}

struct NowPlayingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: AudioPlayerService
    @State private var showQueue = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                ArtworkView(song: player.currentSong, size: 330).shadow(color: .black.opacity(0.4), radius: 20)
                VStack(alignment: .leading, spacing: 5) {
                    Text(player.currentSong?.title ?? "Nothing playing").font(.title.bold())
                    Text(player.currentSong?.displayArtist ?? "").foregroundStyle(Color.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Slider(value: Binding(get: { player.elapsed }, set: { player.seek(to: $0) }), in: 0...max(player.currentSong?.duration ?? 1, 1))
                HStack {
                    Text(time(player.elapsed)); Spacer(); Text(time(player.currentSong?.duration ?? 0))
                }
                .font(.caption).foregroundStyle(Color.muted)
                HStack {
                    Button { player.shuffle.toggle() } label: { Image(systemName: "shuffle").font(.title3) }.foregroundStyle(player.shuffle ? Color.lime : .white)
                    Spacer()
                    Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title2) }
                    Spacer()
                    Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 68)) }
                    Spacer()
                    Button { player.next() } label: { Image(systemName: "forward.fill").font(.title2) }
                    Spacer()
                    Button {
                        let modes = RepeatMode.allCases
                        let index = modes.firstIndex(of: player.repeatMode) ?? 0
                        player.repeatMode = modes[(index + 1) % modes.count]
                    } label: { Image(systemName: "repeat").font(.title3) }
                        .foregroundStyle(player.repeatMode == .off ? .white : Color.lime)
                }
                .padding(.horizontal, 8)
                Spacer()
            }
            .padding(24).background(Color.ink)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "chevron.down") } }
                ToolbarItem(placement: .principal) { Text("NOW PLAYING").font(.caption.bold()).tracking(2) }
                ToolbarItem(placement: .topBarTrailing) { Button { showQueue = true } label: { Image(systemName: "list.number") } }
            }
            .sheet(isPresented: $showQueue) { QueueView() }
        }
    }

    private func time(_ value: Double) -> String {
        String(format: "%d:%02d", Int(value) / 60, Int(value) % 60)
    }
}

struct QueueView: View {
    @EnvironmentObject private var player: AudioPlayerService

    var body: some View {
        NavigationStack {
            List {
                Section("Playing Now") {
                    if let song = player.currentSong { SongRow(song: song) {} }
                }
                Section("Next Up") {
                    ForEach(player.queue.filter { $0.id != player.currentSong?.id }) { song in
                        SongRow(song: song) { player.play(song) }
                            .swipeActions {
                                Button(role: .destructive) { player.queue.removeAll { $0.id == song.id } } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                    }
                    .onMove { offsets, destination in player.queue.move(fromOffsets: offsets, toOffset: destination) }
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden).background(Color.ink)
            .navigationTitle("Queue")
            .toolbar { EditButton() }
        }
    }
}

struct MiniPlayer: View {
    let song: Song
    var open: () -> Void
    @EnvironmentObject private var player: AudioPlayerService

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                ArtworkView(song: song, size: 44)
                VStack(alignment: .leading) {
                    Text(song.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(song.displayArtist).font(.caption).foregroundStyle(Color.muted).lineLimit(1)
                }
                Spacer()
                Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3) }.buttonStyle(.plain)
                Button { player.next() } label: { Image(systemName: "forward.fill") }.buttonStyle(.plain)
            }
            .padding(10).background(Color.cardLight)
        }
        .buttonStyle(.plain)
    }
}

struct SongCard: View {
    let song: Song
    var play: () -> Void

    var body: some View {
        Button(action: play) {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkView(song: song, size: 142)
                Text(song.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(song.displayArtist).font(.caption).foregroundStyle(Color.muted).lineLimit(1)
            }
            .frame(width: 142, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

struct SongRow: View {
    let song: Song
    var play: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                ArtworkView(song: song, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title).foregroundStyle(.white).lineLimit(1)
                    Text("\(song.displayArtist) • \(song.displayAlbum)").font(.caption).foregroundStyle(Color.muted).lineLimit(1)
                }
                Spacer()
                Text(song.durationText).font(.caption).foregroundStyle(Color.muted)
            }
        }
        .listRowBackground(Color.clear)
        .buttonStyle(.plain)
    }
}

struct ArtworkView: View {
    let song: Song?
    let size: CGFloat

    var body: some View {
        Group {
            if let data = song?.artworkData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [.indigo, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay { Image(systemName: "music.note").font(.system(size: size * 0.28)).foregroundStyle(.white.opacity(0.7)) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 100 ? 16 : 8))
    }
}

struct EmptyState: View {
    let title: String
    let message: String
    let icon: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 42)).foregroundStyle(Color.lime)
            Text(title).font(.title3.bold())
            Text(message).multilineTextAlignment(.center).foregroundStyle(Color.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }
}
