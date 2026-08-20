import AppKit

/// Whether we're allowed to send Apple Events to Spotify.
///
/// Two things need it: the now-playing snapshot at launch, and album art.
/// Neither is load-bearing — playback notifications carry everything the audio
/// pipeline depends on — but both fail silently without it, which reads as the
/// app being broken rather than un-permitted.
///
/// Status is *inferred from the Apple Events we already send* rather than
/// queried. `AEDeterminePermissionToAutomateTarget` looks like the right API,
/// but it blocks indefinitely here — with `askUserIfNeeded` either true or
/// false — so calling it would hang a thread for nothing. Sending a real event
/// is also what makes macOS show its consent prompt in the first place, so the
/// natural path both asks and answers.
enum AutomationPermission {
    enum Status: Equatable {
        case unknown
        case granted
        case denied
    }

    /// AppleScript's "not authorised to send Apple events" error.
    static let notPermitted = -1743

    /// Opens System Settings on the Automation pane.
    static func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
