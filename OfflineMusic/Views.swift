import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum SpotufyUI {
    static let smallRadius: CGFloat = 10
    static let mediumRadius: CGFloat = 16
    static let largeRadius: CGFloat = 24
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 14
    static let spacingL: CGFloat = 22
    static let homeArtwork: CGFloat = 148
    static let rowArtwork: CGFloat = 54
}

private struct SpotufyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.82), value: configuration.isPressed)
    }
}

private extension View {
    func spotufyPressStyle() -> some View { buttonStyle(SpotufyPressStyle()) }
}

struct RootView: View {
    @EnvironmentObject private var store: MusicStore
    @State private var tab = 0
    @State private var showNowPlaying = false
    @State private var loggedFirstFrame = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case 1: LibraryView()
                case 2: PlaylistsView()
                case 3: SettingsView()
                default: HomeView { tab = 1 }
                }
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.18), value: tab)
            .safeAreaPadding(.bottom, store.currentSongID == nil ? 62 : 126)
            RootPlayerBar(tab: $tab) { showNowPlaying = true }
        }
        .background((store.oledTheme ? Color.black : (store.theme == .light ? Color(.systemGroupedBackground) : Color.ink)).ignoresSafeArea())
        .sheet(isPresented: $showNowPlaying) { NowPlayingView() }
        .sheet(isPresented: $store.showDebugPanel) { DebugStatusView() }
        .onAppear {
            guard !loggedFirstFrame else { return }
            loggedFirstFrame = true
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - PerformanceDiagnostics.launchStartedAt) / 1_000_000
            print(String(format: "STARTUP PERF first usable frame: %.1fms", elapsed))
        }
    }

}

private struct RootPlayerBar: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: AudioPlayerService
    @Binding var tab: Int
    let openNowPlaying: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let song = player.currentSong {
                MiniPlayer(song: song, open: openNowPlaying)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            HStack {
                tabButton("house.fill", "Home", 0)
                tabButton("music.note.list", "Library", 1)
                tabButton("rectangle.stack.fill", "Playlists", 2)
                tabButton("gearshape.fill", "Settings", 3)
            }
            .padding(.top, 10).padding(.bottom, 8)
            .background(.regularMaterial)
        }
    }

    private func tabButton(_ icon: String, _ text: String, _ value: Int) -> some View {
        Button {
            let previous = tab
            let started = DispatchTime.now().uptimeNanoseconds
            tab = value
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            let elapsedText = String(format: "%.1f", elapsed)
            print("TAB PERF \(previous) -> \(value): \(elapsedText)ms")
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 19, weight: .semibold))
                Text(text).font(.caption2)
            }
            .foregroundStyle(tab == value ? store.accentChoice.color : .secondary)
            .scaleEffect(tab == value ? 1.04 : 1)
            .animation(.easeInOut(duration: 0.18), value: tab)
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel(text)
        .spotufyPressStyle()
    }
}

struct HomeView: View {
    @EnvironmentObject private var store: MusicStore
    let openLibrary: () -> Void

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        return hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    HStack(spacing: 9) {
                        Image("SpotufyBrandIcon")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 30, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityHidden(true)
                        Text("Spotúfy")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(store.accentChoice.color)
                        Spacer()
                        Button { } label: {
                            Image(systemName: "bell")
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 34, height: 34)
                                .background(.thinMaterial)
                                .clipShape(Circle())
                        }
                        .accessibilityLabel("Notifications")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(greeting)
                            .font(.system(size: 32, weight: .bold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                    if store.songs.isEmpty {
                        EmptyState(title: "Your music, your way", message: "Import local audio files to start building your library.", icon: "waveform")
                    } else {
                        quickPicks
                        section("Recently Played", songs: store.homeRecentlyPlayedSongs)
                        section("Recently Added", songs: store.homeRecentlyAddedSongs)
                        section("Albums", songs: store.homeAlbumSongs)
                        section("Favorites", songs: store.homeFavoriteSongs)
                    }
                }
                .padding(.horizontal, 20)
            }
            .background(Color(.systemBackground))
            .onAppear {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - PerformanceDiagnostics.launchStartedAt) / 1_000_000
                print(String(format: "HOME PERF open: %.1fms", elapsed))
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, songs: [Song]) -> some View {
        if !songs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title).font(.title3.bold())
                    Spacer()
                    Button("See All", action: openLibrary)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .spotufyPressStyle()
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: SpotufyUI.spacingM) {
                        ForEach(songs, id: \.id) { song in
                            SongCard(song: song) {
                                let started = DispatchTime.now().uptimeNanoseconds
                                store.play(song, from: songs)
                                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                                print(String(format: "HOME PERF song tap: %.1fms", elapsed))
                            }
                        }
                    }
                }
            }
        }
    }

    private var quickPicks: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            quickPick("Favorites", icon: "heart.fill", songs: store.homeFavoriteSongs)
            quickPick("Recently Added", icon: "clock.fill", songs: store.homeRecentlyAddedSongs)
            quickPick("Most Played", icon: "chart.bar.fill", songs: store.homeMostPlayedSongs)
            quickPick("Recently Played", icon: "play.fill", songs: store.homeRecentlyPlayedSongs)
        }
    }

    private func quickPick(_ title: String, icon: String, songs: [Song]) -> some View {
        Button {
            if let first = songs.first { store.play(first, from: songs) }
        } label: {
            HStack(spacing: 9) {
                ArtworkView(song: songs.first, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Image(systemName: icon).font(.caption).foregroundStyle(store.accentChoice.color)
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 62)
            .background(Color.cardLight.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: SpotufyUI.smallRadius))
        }
        .buttonStyle(.plain)
        .spotufyPressStyle()
    }
}

struct LibraryView: View {
    @EnvironmentObject private var store: MusicStore
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
                                SongRow(song: song) {
                                    let started = DispatchTime.now().uptimeNanoseconds
                                    store.play(song, from: filtered)
                                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                                    print(String(format: "LIBRARY PERF song tap: %.1fms", elapsed))
                                }
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
            .background(Color(.systemBackground))
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
                                ArtworkView(song: store.songs(in: playlist).first, size: 58)
                                VStack(alignment: .leading) {
                                    Text(playlist.name).font(.headline)
                                    Text("\(playlist.songIDs.count) songs")
                                        .foregroundStyle(Color.muted)
                                        .font(.subheadline)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .listRowBackground(Color.clear)
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
            .background(Color(.systemBackground))
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

                ForEach(songs, id: \.id) { song in
                    SongRow(song: song) { player.play(song, from: songs) }
                }
            }
            .padding(20)
        }
        .background(Color(.systemBackground))
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
                HStack {
                    Button {
                        if let first = group.songs.first { player.play(first, from: group.songs) }
                    } label: {
                        Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        let shuffled = group.songs.shuffled()
                        if let first = shuffled.first {
                            player.shuffle = true
                            player.play(first, from: shuffled)
                        }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                ForEach(group.songs, id: \.id) { song in
                    SongRow(song: song) { player.play(song, from: group.songs) }
                }
            }
            .padding(20)
        }
        .background(Color(.systemBackground))
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
                ForEach(songs, id: \.id) { song in
                    SongRow(song: song) { player.play(song, from: songs) }
                }
            }
            .padding(20)
        }
        .background(Color(.systemBackground))
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var player: AudioPlayerService
    private let playbackSpeeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    @State private var showingResetConfirmation = false
    @State private var showingLyricsImporter = false
    @State private var showingUnmatchedLyrics = false

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
                    Picker("Theme", selection: Binding(
                        get: { store.theme },
                        set: {
                            store.theme = $0
                            store.save()
                        }
                    )) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.rawValue).tag(theme)
                        }
                    }
                    Picker("Accent Color", selection: Binding(
                        get: { store.accentChoice },
                        set: {
                            store.accentChoice = $0
                            store.accent = $0.color
                            store.save()
                        }
                    )) {
                        ForEach(AccentColorChoice.allCases) { choice in
                            Label(choice.rawValue, systemImage: "circle.fill")
                                .foregroundStyle(choice.color)
                                .tag(choice)
                        }
                    }
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

                    Button("Import Lyrics Files") {
                        showingLyricsImporter = true
                    }
                    .disabled(store.isImportingLyrics)

                    if store.isImportingLyrics {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView()
                            Text("Importing Lyrics")
                            Text("\(store.lyricsImportProgress) / \(store.lyricsImportTotal)")
                            if !store.lyricsImportCurrent.isEmpty {
                                Text("Current: \(store.lyricsImportCurrent)")
                                    .foregroundStyle(Color.muted)
                            }
                            Button("Cancel") { store.cancelLyricsImport() }
                        }
                    } else if !store.lyricsImportSummary.isEmpty {
                        Text(store.lyricsImportSummary)
                            .foregroundStyle(Color.muted)
                        if !store.unmatchedLyricsFiles.isEmpty {
                            Button("View Unmatched Files") {
                                showingUnmatchedLyrics = true
                            }
                        }
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
            .background(store.oledTheme ? Color.black : (store.theme == .light ? Color(.systemGroupedBackground) : Color.ink))
            .tint(store.accentChoice.color)
            .onChange(of: store.oledTheme) { _, _ in store.save() }
            .onChange(of: store.resumeSession) { _, _ in store.save() }
            .navigationTitle("Settings")
            .alert("Reset downloaded metadata and artwork?", isPresented: $showingResetConfirmation) {
                Button("Reset", role: .destructive) {
                    Task { await store.resetDownloadedMetadataAndArtwork() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Embedded tags, audio files, playlists, favorites, history, and song IDs will be preserved.")
            }
            .fileImporter(
                isPresented: $showingLyricsImporter,
                allowedContentTypes: lyricsImportTypes,
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task { await store.importLyricsFiles(urls) }
                case .failure(let error):
                    store.lyricsImportSummary = "Lyrics import failed: \(error.localizedDescription)"
                }
            }
            .sheet(isPresented: $showingUnmatchedLyrics) {
                UnmatchedLyricsView(files: store.unmatchedLyricsFiles)
            }
        }
    }

    private var lyricsImportTypes: [UTType] {
        [UTType(filenameExtension: "lrc") ?? .plainText, .plainText]
    }

    private func speedLabel(for speed: Float) -> String {
        speed == 1.0 ? "1x" : String(format: "%.2gx", speed)
    }
}

struct UnmatchedLyricsView: View {
    @Environment(\.dismiss) private var dismiss
    let files: [String]

    var body: some View {
        NavigationStack {
            List(files, id: \.self) { file in
                Text(file)
            }
            .navigationTitle("Unmatched Lyrics")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
                    Text(player.currentSong?.title ?? "Nothing playing")
                        .font(.title.bold())
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    Text(player.currentSong?.displayArtist ?? "").foregroundStyle(Color.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Slider(value: Binding(get: { player.elapsed }, set: { player.seek(to: $0) }), in: 0...max(player.currentSong?.duration ?? 1, 1))
                HStack {
                    Text(time(player.elapsed)); Spacer(); Text(time(player.currentSong?.duration ?? 0))
                }
                .font(.caption).foregroundStyle(Color.muted)
                HStack {
                    Button { player.shuffle.toggle() } label: { Image(systemName: "shuffle").font(.title3) }.foregroundStyle(player.shuffle ? store.accentChoice.color : .secondary)
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
                        .foregroundStyle(player.repeatMode == .off ? .secondary : store.accentChoice.color)
                }
                .padding(.horizontal, 8)
                HStack {
                    Button { showLyrics = true } label: { Label("Lyrics", systemImage: "quote.bubble") }
                    Spacer()
                    Button { showSleepTimer = true } label: { Label(store.sleepTimer.remainingText ?? "Sleep Timer", systemImage: "moon.zzz") }
                }
                Spacer()
            }
            .padding(24)
            .background {
                if store.oledTheme {
                    Color.black
                } else if store.theme == .light {
                    Color(.systemBackground)
                } else {
                    LinearGradient(colors: [Color.ink, Color.black], startPoint: .top, endPoint: .bottom)
                }
            }
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
    @State private var showingLyricsDebug = false
    @StateObject private var speech = LyricsSpeechManager()

    private var songID: UUID? { player.currentSong?.id }
    private var lyricsLoadKey: String {
        "\(songID?.uuidString ?? "none")-\(store.lyricsRevision.uuidString)"
    }
    private var song: Song? { store.song(songID) }
    private var displayedLyrics: LocalLyrics? {
        if let manual = song?.manualLyrics, let value = LocalLyrics.plain(manual) { return value }
        return localLyrics
    }
    private var fileOffset: Double { localLyrics?.fileProvidedOffset ?? 0 }
    private var userOffset: Double { song?.lyricsOffset ?? 0 }
    private var effectiveElapsed: Double { player.elapsed - fileOffset - userOffset }
    private var currentLineID: UUID? {
        displayedLyrics?.syncedLines.last(where: { $0.time <= effectiveElapsed })?.id
    }
    private var currentLine: SyncedLyricLine? {
        displayedLyrics?.syncedLines.last(where: { $0.time <= effectiveElapsed })
    }
    private var currentWord: SyncedLyricWord? {
        currentLine?.words.last(where: { $0.startTime <= effectiveElapsed })
    }
    private var debugText: String {
        let line = currentLine.map { String(format: "%.2f", $0.lineTime) } ?? "none"
        let word = currentWord?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "none"
        return "Lyrics type: \(localLyrics?.isEnhanced == true ? "Enhanced LRC" : "Plain LRC")\nAudio elapsed: \(String(format: "%.2f", player.elapsed))\nFile offset: \(signed(fileOffset))\nUser offset: \(signed(userOffset))\nEffective elapsed: \(String(format: "%.2f", effectiveElapsed))\nCurrent line timestamp: \(line)\nCurrent word: \(word)"
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
                            timingControls(lyrics)
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
                            if let songID, song?.importedLyricsFileName != nil {
                                Button("Remove Imported Lyrics", role: .destructive) {
                                    store.removeImportedLyrics(for: songID)
                                }
                            }
                            Button("Lyrics Debug Info") { showingLyricsDebug = true }
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
            .task(id: lyricsLoadKey) {
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
            .alert("Lyrics Debug Info", isPresented: $showingLyricsDebug) {
                Button("Done", role: .cancel) {}
            } message: {
                Text(debugText).font(.caption.monospaced())
            }
        }
    }

    @ViewBuilder
    private func timingControls(_ lyrics: LocalLyrics) -> some View {
        VStack(spacing: 6) {
            Text("Lyrics Timing").font(.caption.bold()).foregroundStyle(Color.muted)
            HStack {
                Button("-0.5s") { adjustOffset(by: -0.5) }
                Spacer()
                Text("Offset: \(signed(userOffset))")
                    .font(.caption.monospaced())
                Spacer()
                Button("+0.5s") { adjustOffset(by: 0.5) }
            }
            .buttonStyle(.bordered)
            HStack {
                Button("-0.1s") { adjustOffset(by: -0.1) }
                Button("Reset") { adjustOffset(to: 0) }
                Button("+0.1s") { adjustOffset(by: 0.1) }
            }
            .buttonStyle(.bordered)
            Text("File offset: \(signed(fileOffset))")
                .font(.caption2.monospaced())
                .foregroundStyle(Color.muted)
            Text("Positive offset delays lyrics; effective time = audio − file offset − user offset")
                .font(.caption2)
                .foregroundStyle(Color.muted)
                .multilineTextAlignment(.center)
            if let lastTimestamp = lyrics.syncedLines.last?.lineTime {
                Text("Audio: \(song?.durationText ?? "0:00") • Last lyric: \(String(format: "%.1fs", lastTimestamp))")
                    .font(.caption2)
                    .foregroundStyle(Color.muted)
                if let duration = song?.duration, duration > 0, abs(duration - lastTimestamp) > 15 {
                    Text("Lyrics timing may not match this audio version.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Button("Sync Current Line") { syncCurrentLine(lyrics) }
                .buttonStyle(.borderedProminent)
                .tint(.lime)
                .disabled(currentLine == nil || songID == nil)
        }
        .padding(.horizontal)
    }

    private func adjustOffset(by value: Double) {
        adjustOffset(to: userOffset + value)
    }

    private func adjustOffset(to value: Double) {
        guard let songID else { return }
        store.updateLyricsOffset(for: songID, value: value)
    }

    private func syncCurrentLine(_ lyrics: LocalLyrics) {
        guard let songID, let line = currentLine else { return }
        let requiredTotalOffset = player.elapsed - line.lineTime
        let requiredUserOffset = requiredTotalOffset - lyrics.fileProvidedOffset
        store.updateLyricsOffset(for: songID, value: requiredUserOffset)
    }

    private func signed(_ value: Double) -> String {
        String(format: "%+.2fs", value)
    }

    @ViewBuilder
    private func syncedLyricsView(_ lyrics: LocalLyrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(lyrics.syncedLines) { line in
                        Button {
                            player.seek(to: line.time + fileOffset + userOffset)
                            autoFollow = true
                        } label: {
                            if line.hasWordTiming {
                                HStack(spacing: 0) {
                                    ForEach(line.words) { word in
                                        KaraokeWordView(word: word, elapsed: effectiveElapsed)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .font(line.id == currentLineID ? .title3.bold() : .body)
                                .padding(.horizontal)
                            } else {
                                Text(line.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .font(line.id == currentLineID ? .title3.bold() : .body)
                                    .foregroundStyle(line.id == currentLineID ? Color.lime : .white.opacity(0.72))
                                    .padding(.horizontal)
                            }
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

struct KaraokeWordView: View {
    let word: SyncedLyricWord
    let elapsed: Double

    private var progress: Double {
        guard elapsed >= word.startTime else { return 0 }
        guard let endTime = word.endTime, endTime > word.startTime else { return 1 }
        return min(max((elapsed - word.startTime) / (endTime - word.startTime), 0), 1)
    }

    var body: some View {
        Text(word.text)
            .foregroundStyle(.white.opacity(0.30))
            .overlay {
                GeometryReader { proxy in
                    Text(word.text)
                        .foregroundStyle(Color.lime)
                        .frame(width: proxy.size.width * progress, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipped()
                }
            }
            .animation(.linear(duration: 0.08), value: progress)
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
            VStack(spacing: 8) {
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
                ProgressView(value: player.currentSong?.duration == nil ? 0 : player.elapsed, total: max(player.currentSong?.duration ?? 1, 1))
                    .tint(.primary)
                    .scaleEffect(y: 0.35)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: SpotufyUI.mediumRadius))
            .overlay {
                RoundedRectangle(cornerRadius: SpotufyUI.mediumRadius)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .spotufyPressStyle()
    }
}

struct SongCard: View {
    let song: Song
    var play: () -> Void

    var body: some View {
        Button(action: play) {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkView(song: song, size: SpotufyUI.homeArtwork)
                Text(song.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(song.displayArtist).font(.caption).foregroundStyle(Color.muted).lineLimit(1)
            }
            .frame(width: SpotufyUI.homeArtwork, alignment: .leading)
        }
        .buttonStyle(.plain)
        .songActions(for: song, play: play)
        .spotufyPressStyle()
    }
}

struct SongRow: View {
    let song: Song
    var play: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                ArtworkView(song: song, size: SpotufyUI.rowArtwork)
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title).foregroundStyle(.primary).lineLimit(1)
                    Text("\(song.displayArtist) • \(song.displayAlbum)").font(.caption).foregroundStyle(Color.muted).lineLimit(1)
                }
                Spacer()
                Text(song.durationText).font(.caption).foregroundStyle(Color.muted)
            }
        }
        .listRowBackground(Color.clear)
        .buttonStyle(.plain)
        .songActions(for: song, play: play)
        .spotufyPressStyle()
    }
}

private struct SongActionsModifier: ViewModifier {
    @EnvironmentObject private var store: MusicStore
    let song: Song
    let play: () -> Void
    @State private var showingEditor = false
    @State private var showingPlaylistPicker = false

    init(song: Song, play: @escaping () -> Void) {
        self.song = song
        self.play = play
    }

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button(action: play) {
                    Label("Play", systemImage: "play.fill")
                }
                Button { store.playNext(song) } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button { store.addToQueue(song) } label: {
                    Label("Add to Queue", systemImage: "text.badge.plus")
                }
                Button { showingPlaylistPicker = true } label: {
                    Label("Add to Playlist", systemImage: "rectangle.stack.badge.plus")
                }
                Button { store.toggleFavorite(song) } label: {
                    Label(song.isFavorite ? "Remove Favorite" : "Favorite", systemImage: song.isFavorite ? "heart.slash" : "heart")
                }
                Button { showingEditor = true } label: {
                    Label("Edit Info", systemImage: "pencil")
                }
                if let artistGroup = store.artistGroups.first(where: { $0.songs.contains(where: { $0.id == song.id }) }) {
                    NavigationLink {
                        ArtistDetailView(artist: artistGroup.name)
                    } label: {
                        Label("View Artist", systemImage: "person")
                    }
                }
                if let albumGroup = store.albumGroups.first(where: { $0.songs.contains(where: { $0.id == song.id }) }) {
                    NavigationLink {
                        AlbumDetailView(group: albumGroup)
                    } label: {
                        Label("View Album", systemImage: "square.stack")
                    }
                }
                Button { store.startSongDebug(song) } label: {
                    Label("Identify & Fetch Artwork", systemImage: "wand.and.stars")
                }
            }
            .sheet(isPresented: $showingEditor) {
                SongEditorView(song: store.song(song.id) ?? song)
            }
            .sheet(isPresented: $showingPlaylistPicker) {
                PlaylistPickerView(songID: song.id)
            }
    }
}

private extension View {
    func songActions(for song: Song, play: @escaping () -> Void) -> some View {
        modifier(SongActionsModifier(song: song, play: play))
    }
}

struct SongEditorView: View {
    @EnvironmentObject private var store: MusicStore
    @Environment(\.dismiss) private var dismiss
    let songID: UUID
    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var albumArtist: String

    init(song: Song) {
        songID = song.id
        _title = State(initialValue: song.title)
        _artist = State(initialValue: song.artist)
        _album = State(initialValue: song.album)
        _albumArtist = State(initialValue: song.albumArtist)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                TextField("Artist", text: $artist)
                TextField("Album", text: $album)
                TextField("Album Artist", text: $albumArtist)
            }
            .navigationTitle("Edit Info")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        store.updateSongMetadata(for: songID, title: title, artist: artist, album: album, albumArtist: albumArtist)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct PlaylistPickerView: View {
    @EnvironmentObject private var store: MusicStore
    @Environment(\.dismiss) private var dismiss
    let songID: UUID

    var body: some View {
        NavigationStack {
            List(store.playlists) { playlist in
                Button {
                    store.addSong(songID, to: playlist.id)
                    dismiss()
                } label: {
                    HStack {
                        Text(playlist.name)
                        Spacer()
                        if playlist.songIDs.contains(songID) { Image(systemName: "checkmark") }
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
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

private final class ArtworkImageCache {
    static let shared = ArtworkImageCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 256
        cache.totalCostLimit = 80 * 1024 * 1024
    }

    static func key(for song: Song?) -> String {
        guard let song else { return "none" }
        return "\(song.id.uuidString)-\(song.artworkData?.count ?? 0)"
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}

struct ArtworkView: View {
    let song: Song?
    let size: CGFloat
    @State private var decodedImage: UIImage?
    @State private var loadedArtworkKey: String?

    var body: some View {
        let key = artworkKey
        let stateImage = loadedArtworkKey == key ? decodedImage : nil
        let image = stateImage ?? ArtworkImageCache.shared.image(for: key)
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: placeholderColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay { Image(systemName: "music.note").font(.system(size: size * 0.28)).foregroundStyle(.white.opacity(0.7)) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 100 ? 16 : 8))
        .task(id: artworkKey) {
            let key = artworkKey
            if let cached = ArtworkImageCache.shared.image(for: key) {
                decodedImage = cached
                loadedArtworkKey = key
                return
            }
            if loadedArtworkKey != key {
                decodedImage = nil
            }
            guard let data = song?.artworkData else { return }
            await Task.yield()
            guard !Task.isCancelled, let image = UIImage(data: data) else { return }
            ArtworkImageCache.shared.insert(image, for: key)
            decodedImage = image
            loadedArtworkKey = key
        }
    }

    private var artworkKey: String {
        ArtworkImageCache.key(for: song)
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
