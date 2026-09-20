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
        .sheet(isPresented: $store.showDebugPanel) { DebugStatusView() }
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
            result = result.filter {
                SearchNormalization.matches(search, in: [
                    $0.title, $0.artist, $0.album, $0.albumArtist, $0.genre, $0.fileName
                ])
            }
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

    private var visibleArtistGroups: [ArtistGroup] {
        guard !search.isEmpty else { return store.artistGroups }
        return store.artistGroups.filter { group in
            group.name.localizedCaseInsensitiveContains(search) ||
            group.songs.contains { $0.title.localizedCaseInsensitiveContains(search) || $0.album.localizedCaseInsensitiveContains(search) }
        }
    }

    private var visibleAlbumGroups: [AlbumGroup] {
        guard !search.isEmpty else { return store.albumGroups }
        return store.albumGroups.filter {
            $0.name.localizedCaseInsensitiveContains(search) ||
            $0.artist.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.muted)
                    TextField("Search your library", text: $search)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !search.isEmpty {
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.muted)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.cardLight)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .padding(.top, 8)

                Picker("Library", selection: $filter) {
                    Text("Songs").tag(LibraryFilter.songs)
                    Text("Artists").tag(LibraryFilter.artists)
                    Text("Albums").tag(LibraryFilter.albums)
                    Text("Favorites").tag(LibraryFilter.favorites)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)

                List {
                    if store.songs.isEmpty {
                        EmptyState(title: "Library is empty", message: "Use Import to add MP3, M4A, AAC, WAV, or FLAC files.", icon: "plus.circle")
                    } else {
                        switch filter {
                        case .artists:
                            ForEach(visibleArtistGroups) { group in
                                NavigationLink {
                                    ArtistDetailView(artist: group.name)
                                } label: {
                                    ArtistGroupRow(group: group)
                                }
                            }
                        case .albums:
                            ForEach(visibleAlbumGroups) { group in
                                NavigationLink {
                                    AlbumDetailView(group: group)
                                } label: {
                                    AlbumGroupRow(group: group)
                                }
                            }
                        default:
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
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
            .background(Color.ink)
            .navigationTitle("Your Library")
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

struct ArtistGroupRow: View {
    let group: ArtistGroup

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(song: group.representativeSong, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(group.name).font(.headline)
                Text("\(group.songs.count) songs")
                    .font(.subheadline)
                    .foregroundStyle(Color.muted)
            }
            Spacer()
        }
    }
}

struct AlbumGroupRow: View {
    let group: AlbumGroup

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(song: group.representativeSong, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(group.name).font(.headline)
                Text(group.artist).font(.subheadline).foregroundStyle(Color.muted)
                Text("\(group.songs.count) songs").font(.caption).foregroundStyle(Color.muted)
            }
            Spacer()
        }
    }
}

struct ArtistDetailView: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: AudioPlayerService
    let artist: String

    private var songs: [Song] {
        store.songs(forArtist: artist)
    }

    private var representativeSong: Song? {
        songs.first(where: { $0.artworkData != nil }) ?? songs.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    ArtworkView(song: representativeSong, size: 112)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(artist).font(.title.bold())
                        Text("\(songs.count) songs").foregroundStyle(Color.muted)
                    }
                }

                HStack {
                    Button {
                        if let first = songs.first { player.play(first, from: songs) }
                    } label: {
                        Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.lime)

                    Button {
                        let shuffled = songs.shuffled()
                        if let first = shuffled.first {
                            player.shuffle = true
                            player.play(first, from: shuffled)
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
        .navigationTitle(artist)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AlbumDetailView: View {
    @EnvironmentObject private var player: AudioPlayerService
    let group: AlbumGroup

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    ArtworkView(song: group.representativeSong, size: 112)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.name).font(.title2.bold())
                        Text(group.artist).foregroundStyle(Color.muted)
                    }
                }
                ForEach(group.songs) { song in
                    SongRow(song: song) { player.play(song, from: group.songs) }
                }
            }
            .padding(20)
        }
        .background(Color.ink)
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
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
    private let playbackSpeeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    @State private var showingResetConfirmation = false

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
                    Button("Test MusicBrainz Connection") {
                        Task { await store.testMusicBrainzConnection() }
                    }
                    Button("Fetch Missing Metadata & Artwork") {
                        store.startMetadataArtworkEnrichment()
                    }
                    .disabled(store.isFetchingArtwork || store.songs.isEmpty)

                    if store.isFetchingArtwork {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView()
                            Text("Processing \(store.artworkFetchProgress) / \(store.artworkFetchTotal)")
                            if !store.enrichmentCurrentSong.isEmpty {
                                Text("Current song: \(store.enrichmentCurrentSong)")
                            }
                            Text("Status: \(store.enrichmentStatus)")
                                .foregroundStyle(Color.muted)
                            Button("Cancel") {
                                store.cancelMetadataArtworkEnrichment()
                            }
                        }
                    } else if !store.artworkFetchSummary.isEmpty {
                        Text(store.artworkFetchSummary)
                            .foregroundStyle(Color.muted)
                    }

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

                    Button("Reset Downloaded Metadata & Artwork") {
                        showingResetConfirmation = true
                    }
                    .disabled(store.isScanning || store.isFetchingArtwork)
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
            .alert("Reset downloaded metadata and artwork?", isPresented: $showingResetConfirmation) {
                Button("Reset", role: .destructive) {
                    Task { await store.resetDownloadedMetadataAndArtwork() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Embedded tags, audio files, playlists, favorites, history, and song IDs will be preserved.")
            }
        }
    }

    private func speedLabel(for speed: Float) -> String {
        speed == 1.0 ? "1x" : String(format: "%.2gx", speed)
    }
}

struct NowPlayingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: AudioPlayerService
    @EnvironmentObject private var store: MusicStore
    @State private var showQueue = false
    @State private var showLyrics = false
    @State private var showSleepTimer = false

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
                HStack {
                    Button { showLyrics = true } label: { Label("Lyrics", systemImage: "quote.bubble") }
                    Spacer()
                    Button { showSleepTimer = true } label: { Label(store.sleepTimer.remainingText ?? "Sleep Timer", systemImage: "moon.zzz") }
                }
                Spacer()
            }
            .padding(24).background(Color.ink)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "chevron.down") } }
                ToolbarItem(placement: .principal) { Text("NOW PLAYING").font(.caption.bold()).tracking(2) }
                ToolbarItem(placement: .topBarTrailing) { Button { showQueue = true } label: { Image(systemName: "list.number") } }
            }
            .sheet(isPresented: $showQueue) { QueueView() }
            .sheet(isPresented: $showLyrics) {
                LyricsView()
            }
            .sheet(isPresented: $showSleepTimer) { SleepTimerView() }
        }
    }

    private func time(_ value: Double) -> String {
        String(format: "%d:%02d", Int(value) / 60, Int(value) % 60)
    }
}

struct SleepTimerView: View {
    @EnvironmentObject private var store: MusicStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(SleepTimerOption.allCases) { option in
                    Button {
                        store.sleepTimer.set(option)
                        dismiss()
                    } label: {
                        HStack {
                            Text(option.rawValue)
                            Spacer()
                            if store.sleepTimer.option == option { Image(systemName: "checkmark") }
                        }
                    }
                }
                if let remaining = store.sleepTimer.remainingText {
                    Text("Remaining: \(remaining)").foregroundStyle(Color.muted)
                }
            }
            .navigationTitle("Sleep Timer")
        }
    }
}

struct LyricsView: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: AudioPlayerService
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var draft = ""
    @State private var localLyrics: LocalLyrics?
    @State private var isLoading = true
    @State private var autoFollow = true
    @StateObject private var speech = LyricsSpeechManager()

    private var songID: UUID? { player.currentSong?.id }
    private var song: Song? { store.song(songID) }
    private var displayedLyrics: LocalLyrics? {
        if let manual = song?.manualLyrics, let value = LocalLyrics.plain(manual) { return value }
        return localLyrics
    }
    private var currentLineID: UUID? {
        displayedLyrics?.syncedLines.last(where: { $0.time <= player.elapsed })?.id
    }

    var body: some View {
        NavigationStack {
            Group {
                if editing {
                    TextEditor(text: $draft).padding()
                } else if isLoading {
                    ProgressView("Loading lyrics...")
                } else if let lyrics = displayedLyrics {
                    VStack(spacing: 12) {
                        if lyrics.isSynced {
                            syncedLyricsView(lyrics)
                        } else {
                            ScrollView {
                                Text(lyrics.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding()
                            }
                        }
                        HStack {
                            Button("Read") { speech.read(lyrics.text, pauseMusic: { player.pause() }) }
                            Button("Pause") { speech.pause() }
                            Button("Resume") { speech.resume() }
                            Button("Stop") { speech.stop() }
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    VStack(spacing: 14) {
                        ContentUnavailableView("No lyrics available", systemImage: "quote.bubble")
                        Button("Add Lyrics Manually") { draft = ""; editing = true }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .navigationTitle(song?.title ?? "Lyrics")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editing ? "Save" : "Edit") {
                        if editing, let songID { store.updateLyrics(for: songID, manualLyrics: draft) }
                        editing.toggle()
                    }
                }
                if displayedLyrics != nil && !editing {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if let lyrics = displayedLyrics {
                                Button("Read Lyrics Aloud") { speech.read(lyrics.text, pauseMusic: { player.pause() }) }
                            }
                            Button("Stop Reading") { speech.stop() }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
                if editing, song?.manualLyrics != nil, let songID {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear Override") {
                            store.updateLyrics(for: songID, manualLyrics: nil)
                            draft = song?.embeddedLyrics ?? ""
                        }
                    }
                }
            }
            .task(id: songID) {
                editing = false
                autoFollow = true
                isLoading = true
                if let songID {
                    localLyrics = await store.localLyrics(for: songID)
                } else {
                    localLyrics = nil
                }
                draft = song?.manualLyrics ?? localLyrics?.text ?? ""
                isLoading = false
            }
            .onDisappear { speech.stop() }
        }
    }

    @ViewBuilder
    private func syncedLyricsView(_ lyrics: LocalLyrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(lyrics.syncedLines) { line in
                        Button {
                            player.seek(to: line.time)
                            autoFollow = true
                        } label: {
                            Text(line.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .font(line.id == currentLineID ? .title3.bold() : .body)
                                .foregroundStyle(line.id == currentLineID ? Color.lime : .white.opacity(0.72))
                                .padding(.horizontal)
                        }
                        .buttonStyle(.plain)
                        .id(line.id)
                    }
                }
                .padding(.vertical)
            }
            .simultaneousGesture(DragGesture().onChanged { _ in autoFollow = false })
            .onChange(of: currentLineID) { _, newID in
                guard autoFollow, let newID else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
            .overlay(alignment: .bottom) {
                if !autoFollow {
                    Button("Resume auto-scroll") { autoFollow = true }
                        .buttonStyle(.borderedProminent)
                        .tint(.lime)
                        .padding(.bottom, 8)
                }
            }
        }
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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") { player.clearQueue() }
                }
            }
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
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: AudioPlayerService

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
        .contextMenu {
            Button { player.playNext(song) } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button { player.addToQueue(song) } label: {
                Label("Add to Queue", systemImage: "text.badge.plus")
            }
            Button {
                store.startSongDebug(song)
            } label: {
                Label("Identify & Fetch Artwork", systemImage: "wand.and.stars")
            }
        }
    }
}

struct DebugStatusView: View {
    @EnvironmentObject private var store: MusicStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(store.debugLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.footnote.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if store.isDebuggingSong {
                        ProgressView("Working...")
                    }
                }
                .padding()
            }
            .background(Color.ink)
            .navigationTitle("Metadata Debug")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
                LinearGradient(colors: placeholderColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay { Image(systemName: "music.note").font(.system(size: size * 0.28)).foregroundStyle(.white.opacity(0.7)) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 100 ? 16 : 8))
    }

    private var placeholderColors: [Color] {
        let seed = ((song?.title ?? "Offline Music") + (song?.displayAlbum ?? ""))
            .unicodeScalars
            .reduce(0) { ($0 * 31 + Int($1.value)) % 5 }
        switch seed {
        case 0: return [.indigo, .purple, .pink]
        case 1: return [.blue, .cyan, .teal]
        case 2: return [.orange, .red, .pink]
        case 3: return [.green, .mint, .blue]
        default: return [.purple, .blue, .cyan]
        }
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
