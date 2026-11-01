import AppKit
import ImageIO
import SwiftUI
import VisionKit

enum PreviewImageDecoder {
    static func decode(url: URL) throws -> CGImage {
        // ImageIO applies EXIF rotation/mirroring once; display and OCR use the same pixels.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return image
    }
}

@MainActor
final class ImageTextPreviewModel: ObservableObject {
    private static let analyzer = ImageAnalyzer()
    @Published private(set) var image: NSImage?
    @Published private(set) var analysis: ImageAnalysis?
    @Published private(set) var isLoading = false
    @Published private(set) var message = ""
    @Published private(set) var canRetry = false
    private var requestID = UUID()

    var transcript: String { analysis?.transcript ?? "" }

    func load(url: URL) async {
        let id = UUID()
        requestID = id
        image = nil
        analysis = nil
        canRetry = false
        isLoading = true
        message = "正在读取图片…"
        defer {
            if requestID == id { isLoading = false }
        }
        do {
            let decoding = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try PreviewImageDecoder.decode(url: url)
            }
            let bitmap = try await withTaskCancellationHandler {
                try await decoding.value
            } onCancel: {
                decoding.cancel()
            }
            try Task.checkCancellation()
            guard requestID == id else { return }
            image = NSImage(cgImage: bitmap, size: .zero)
            guard ImageAnalyzer.isSupported else {
                message = "此设备不支持实况文本。"
                return
            }
            message = "正在识别文字…"
            // Apple's macOS Live Text guide recommends one shared analyzer.
            // Leave locales unset to respect the user's preferred languages.
            let result = try await Self.analyzer.analyze(
                bitmap, orientation: .up, configuration: .init(.text)
            )
            try Task.checkCancellation()
            guard requestID == id else { return }
            analysis = result
            message = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "未识别到文字。" : ""
        } catch {
            guard !Task.isCancelled, requestID == id else { return }
            message = image == nil ? "无法读取图片：\(error.localizedDescription)"
                : "文字识别失败：\(error.localizedDescription)"
            canRetry = true
        }
    }
}

struct LiveTextImageView: NSViewRepresentable {
    let image: NSImage
    let analysis: ImageAnalysis?

    final class Coordinator {
        let overlay = ImageAnalysisOverlayView()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let overlay = context.coordinator.overlay
        overlay.frame = view.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.trackingImageView = view
        overlay.preferredInteractionTypes = .textSelection
        view.addSubview(overlay)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image !== image { view.image = image }
        let overlay = context.coordinator.overlay
        if overlay.analysis !== analysis { overlay.analysis = analysis }
    }

    static func dismantleNSView(_ view: NSImageView, coordinator: Coordinator) {
        coordinator.overlay.analysis = nil
        coordinator.overlay.trackingImageView = nil
    }
}

struct ImageTextPreview: View {
    let url: URL
    @StateObject private var model = ImageTextPreviewModel()

    var body: some View {
        VStack(spacing: 0) {
            if let image = model.image {
                LiveTextImageView(image: image, analysis: model.analysis)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else {
                QuickLookContainer(url: url)
            }
        }
        .task(id: url) {
            await model.load(url: url)
        }
    }
}
