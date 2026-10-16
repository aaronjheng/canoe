import AVKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// AVKit and PDFKit bridges for the response Preview pane: the viewer hands
/// over a staged file URL (the body written to a temp file, see the staging
/// in `ResponseViewerView`) and the native player or PDF renderer takes it
/// from there. Both read from disk on demand, so multi-megabyte media never
/// sits decoded in memory the way a bitmap preview would.
///
/// Neither view hosts a text field, so the shared field-editor focus ring
/// (see `AppKitFocusRing`) never applies to them.

/// `AVPlayerView` for audio and video responses: the system player chrome
/// (transport controls, scrubber, volume, PiP for video). Audio renders the
/// same controls on a plain background - no video surface to draw.
struct MediaPlayerPreview: NSViewRepresentable {
    /// Staged body file to play.
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        // Swap the player only when the file actually changed: rebuilding it
        // on every update would restart playback from zero.
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            view.player?.pause()
            view.player = AVPlayer(url: url)
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }

    /// Whether the system can decode this Content-Type at all (AVFoundation
    /// has no Ogg Vorbis / WebM / Matroska support, for instance). Unknown or
    /// missing types pass: the player then gets to try, and Content-Type
    /// labels are frequently sloppy anyway.
    static func isPlayable(mimeType: String?) -> Bool {
        let mime = (mimeType ?? "").lowercased()
        guard mime.hasPrefix("audio/") || mime.hasPrefix("video/") else { return true }
        return AVURLAsset.isPlayableExtendedMIMEType(mime)
    }

    /// Filename extension for the staged file, derived from the response's
    /// Content-Type (a hint for the demuxer; the container is sniffed too).
    static func fileExtension(forMimeType mimeType: String?) -> String {
        UTType(mimeType: (mimeType ?? "").lowercased())?.preferredFilenameExtension ?? "bin"
    }
}

/// PDFKit's `PDFView` for PDF responses: continuous scrolling, zoom, and
/// sidebar navigation out of the box, rendering pages on demand from the
/// staged file instead of rasterizing the whole document up front.
struct PDFPreview: NSViewRepresentable {
    /// Staged body file to render.
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        // Fit the page to the pane; users zoom with pinch / ⌘± like Preview.
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        // Reload only when the file changed; `PDFDocument` has no identity to
        // diff, so compare by URL.
        if view.document?.documentURL?.standardizedFileURL != url.standardizedFileURL {
            view.document = PDFDocument(url: url)
        }
    }
}
