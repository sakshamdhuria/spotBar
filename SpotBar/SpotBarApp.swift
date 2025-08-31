import SwiftUI
import AppKit

// Truncate with ellipsis (safer than hard-coding in the UI)
@inline(__always)
func truncated(_ s: String, to limit: Int) -> String {
    if s.count <= limit { return s }
    let end = s.index(s.startIndex, offsetBy: limit)
    return String(s[..<end]) + "…"
}


@main
struct SpotBarApp: App {
    @StateObject private var spotify = SpotifyBridge()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(spotify: spotify)
        } label: {
            Group {
                if spotify.shouldUseIconLabel {
                    Image(systemName: "music.note")
                        .help(spotify.menuTitle)  // tooltip shows full title
                } else {
                    // show truncated text
                    Text(spotify.compactMenuTitle(maxChars: 24))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(minWidth: 60, maxWidth: 160, alignment: .leading)
                        .help(spotify.menuTitle)  // tooltip shows full title
                }
            }
        }
        // .menuBarExtraStyle(.window) // keep this off for stability
    }
}


struct MenuContent: View {
    @ObservedObject var spotify: SpotifyBridge

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Row 1: Song title
            Text(titleText)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)

            // Row 2: Artist
            Text(artistText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            // Row 3: State (Paused/Playing)
            Text(stateText)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary)
                .clipShape(Capsule())
            // Row 4: Controls (single row, compact)
            // Row 4: Controls (force horizontal)
            HStack(alignment: .center, spacing: 20) {
                Button(action: spotify.previousTrack) {
                    Image(systemName: "backward.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                }

                Button(action: spotify.playPause) {
                    Image(systemName: "playpause.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                }

                Button(action: spotify.nextTrack) {
                    Image(systemName: "forward.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity) // force row layout
            .padding(.vertical, 6)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))


            Divider()

            // Row 5: Quit / Open Spotify (no extra space)
            HStack(spacing: 16) {
                Button {
                    spotify.openSpotify()
                } label: {
                    Label("Open Spotify", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit SpotBar", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.bordered)
            }

        }
        .padding(12)
        .frame(width: 420)
        .onAppear { spotify.startUpdating() }
    }

    // MARK: - Derived text helpers
    private var titleText: String {
        spotify.menuTitle.replacingOccurrences(of: "⏸ ", with: "")
    }
    private var artistText: String {
        extractArtist(spotify.nowPlayingDetail)
    }
    private var stateText: String {
        extractState(spotify.nowPlayingDetail)
    }

    // Existing helpers you already had
    private func extractState(_ s: String) -> String {
        if let line = s.split(separator: "\n").first, line.lowercased().contains("state:") {
            return line.replacingOccurrences(of: "State:", with: "").trimmingCharacters(in: .whitespaces)
        }
        return "—"
    }
    private func extractArtist(_ s: String) -> String {
        guard let line = s.split(separator: "\n").first(where: { $0.lowercased().hasPrefix("artist:") }) else { return "—" }
        return line.replacingOccurrences(of: "Artist:", with: "").trimmingCharacters(in: .whitespaces)
    }
}


final class SpotifyBridge: ObservableObject {
    @Published var menuTitle: String = "Spotify: Not running"
    @Published var nowPlayingDetail: String = "—"
    @Published var artwork: NSImage? = nil
    // If the label gets too long, we’ll show an icon instead of text.
    // Tune threshold to taste.
    var shouldUseIconLabel: Bool {
        // strip the pause prefix so it doesn't inflate length
        let t = menuTitle.replacingOccurrences(of: "⏸ ", with: "")
        return t.count > 28
    }

    // A compact version used when we *do* keep text
    func compactMenuTitle(maxChars: Int = 24) -> String {
        let t = menuTitle.replacingOccurrences(of: "⏸ ", with: "")
        return truncated(t, to: maxChars)
    }

    private var timer: Timer?

    // Start/stop polling
    func startUpdating(pollSeconds: TimeInterval = 1.5) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollSeconds, repeats: true) { [weak self] _ in
            self?.refreshNowPlaying()
        }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
        refreshNowPlaying()
    }

    deinit { timer?.invalidate() }

    // Menu actions
    func playPause()     { _ = runAS(#"tell application "Spotify" to playpause"#) }
    func nextTrack()     { _ = runAS(#"tell application "Spotify" to next track"#) }
    func previousTrack() { _ = runAS(#"tell application "Spotify" to previous track"#) }

    // Reliable running check using bundle id (no System Events)
    private func isSpotifyRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.spotify.client" }
    }

    // Poll Spotify state + metadata
    func refreshNowPlaying() {
        if !isSpotifyRunning() {
            DispatchQueue.main.async {
                self.menuTitle = "♫ SpotBar"
                self.nowPlayingDetail = "Spotify not running."
                self.artwork = nil
            }
            return
        }

        guard let state = runAS(#"tell application "Spotify" to player state as string"#) else {
            DispatchQueue.main.async {
                self.menuTitle = "Permission needed"
                self.nowPlayingDetail = "Enable Automation for SpotBar → Spotify."
                self.artwork = nil
            }
            return
        }

        if state == "playing" || state == "paused" {
            let name   = runAS(#"tell application "Spotify" to name of current track as string"#) ?? "Unknown Track"
            let artist = runAS(#"tell application "Spotify" to artist of current track as string"#) ?? "Unknown Artist"
            // Some Spotify builds expose artwork url; if nil, we just skip artwork
            let artURL = runAS(#"tell application "Spotify" to artwork url of current track as string"#)

            let title  = "\(name) – \(artist)"
            DispatchQueue.main.async {
                self.menuTitle = (state == "paused") ? "⏸ \(title)" : title
                self.nowPlayingDetail = "State: \(state.capitalized)\nTrack: \(name)\nArtist: \(artist)"

                if let s = artURL, let url = URL(string: s), let data = try? Data(contentsOf: url), let img = NSImage(data: data) {
                    self.artwork = img
                } else {
                    self.artwork = nil
                }
            }
        } else {
            DispatchQueue.main.async {
                self.menuTitle = "♫ SpotBar"
                self.nowPlayingDetail = "Player is stopped."
                self.artwork = nil
            }
        }
    }
    
    // Open/bring Spotify to front
    func openSpotify() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
        } else {
            // Fallback via AppleScript if needed
            _ = runAS(#"tell application "Spotify" to activate"#)
        }
    }


    // AppleScript helper with friendly permission hint
    @discardableResult
    private func runAS(_ script: String) -> String? {
        let asObj = NSAppleScript(source: script)
        var errorDict: NSDictionary?
        let output = asObj?.executeAndReturnError(&errorDict)
        if let err = errorDict, err.count > 0 {
            DispatchQueue.main.async {
                self.menuTitle = "Spotify: Permission needed"
                self.nowPlayingDetail =
                "Allow SpotBar to control Spotify:\nSystem Settings → Privacy & Security → Automation → SpotBar → Spotify."
            }
            // Uncomment for debugging:
            // print("AppleScript error: \(err)")
            return nil
        }
        return output?.stringValue ?? output?.description
    }
}
