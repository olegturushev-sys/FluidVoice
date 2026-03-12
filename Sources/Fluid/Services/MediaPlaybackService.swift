import Foundation

/// Service that provides controlled pause/resume functionality during transcription.
/// NOTE: MediaRemote functionality temporarily disabled - requires proper package integration.
@MainActor
final class MediaPlaybackService {
    static let shared = MediaPlaybackService()

    private init() {}

    // MARK: - Public API

    /// Pauses system media playback if something is currently playing.
    ///
    /// - Returns: `true` if we successfully paused playback, `false` if nothing was playing
    ///   or if we couldn't determine playback state.
    func pauseIfPlaying() async -> Bool {
        DebugLogger.shared.debug(
            "MediaPlaybackService: Media pause/resume temporarily disabled",
            source: "MediaPlaybackService"
        )
        return false
    }

    /// Resumes media playback only if we were the ones who paused it.
    ///
    /// - Parameter wePaused: `true` if `pauseIfPlaying()` returned `true` for this session.
    func resumeIfWePaused(_ wePaused: Bool) async {
        // No-op
    }
}
