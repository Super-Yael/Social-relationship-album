import AppKit
import QuickLookThumbnailing
import QuickLookUI
import SwiftUI

enum MediaLayout {
    static func aspectRatio(pixelWidth: Int, pixelHeight: Int) -> CGFloat {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1 }
        return CGFloat(pixelWidth) / CGFloat(pixelHeight)
    }
}

@MainActor
private final class ThumbnailLoader: ObservableObject {
    @Published var image: NSImage?
    @Published var aspectRatio: CGFloat = 1
    private var representedPath = ""

    func load(url: URL, size: CGSize) {
        guard representedPath != url.path else { return }
        representedPath = url.path
        image = nil
        aspectRatio = 1
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let representation else { return }
            let thumbnail = representation.nsImage
            let thumbnailAspectRatio = MediaLayout.aspectRatio(
                pixelWidth: representation.cgImage.width,
                pixelHeight: representation.cgImage.height
            )
            Task { @MainActor in
                guard self?.representedPath == url.path else { return }
                self?.image = thumbnail
                self?.aspectRatio = thumbnailAspectRatio
            }
        }
    }
}

struct MediaThumbnailView: View {
    let item: MediaItem
    @StateObject private var loader = ThumbnailLoader()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            if item.kind == .video {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 34))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
                    .shadow(radius: 3)
            }
        }
        .aspectRatio(loader.aspectRatio, contentMode: .fit)
        .task(id: item.url.path) {
            loader.load(url: item.url, size: CGSize(width: 300, height: 300))
        }
    }
}

struct QuickLookContainer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        nsView.previewItem = url as NSURL
        nsView.refreshPreviewItem()
    }
}

struct MediaPreviewSheet: View {
    let item: MediaItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(item.url.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            QuickLookContainer(url: item.url)
        }
        .frame(minWidth: 900, minHeight: 650)
    }
}
