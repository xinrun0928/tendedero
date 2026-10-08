import AppKit

/// Watches the pasteboard for images and reports new ones, so a capture made
/// with Snipaste or anything else that only copies to the clipboard still
/// hangs on the line. macOS offers no pasteboard-change notification, so the
/// change count is polled, the standard trick.
final class ClipboardWatcher {
    private let onNew: (URL) -> Void
    private var timer: Timer?
    private var lastChangeCount: Int

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp"]

    init(onNew: @escaping (URL) -> Void) {
        self.onNew = onNew
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        guard timer == nil else { return }
        // Whatever sits in the pasteboard now predates the switch; only
        // copies made after it count.
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func scan() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        // A copied file: hang the file itself, never a second copy of it.
        // This also covers Copy on a photo already on the line, which puts
        // its own file URL on the pasteboard.
        if let url = fileURL(pb) {
            if FileManager.default.fileExists(atPath: url.path),
               Self.imageExtensions.contains(url.pathExtension.lowercased()) {
                onNew(url)
            }
            return
        }

        // Otherwise an image payload with no file behind it.
        guard NSImage(pasteboard: pb) != nil, let (data, ext) = imageData(pb) else { return }
        let folder = Inbox.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = uniqueURL(in: folder, ext: ext)
        do {
            try data.write(to: url, options: .atomic)
            onNew(url)
        } catch {
            NSLog("Tendedero: cannot save clipboard image: \(error.localizedDescription)")
        }
    }

    private func fileURL(_ pb: NSPasteboard) -> URL? {
        if let raw = pb.string(forType: .fileURL), let url = URL(string: raw), url.isFileURL {
            return url
        }
        let objects = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return objects?.first as? URL
    }

    /// The raw bytes when the pasteboard carries them, so a PNG stays a PNG.
    private func imageData(_ pb: NSPasteboard) -> (Data, String)? {
        if let png = pb.data(forType: .png) { return (png, "png") }
        if let tiff = pb.data(forType: .tiff) { return (tiff, "tiff") }
        if let jpeg = pb.data(forType: NSPasteboard.PasteboardType("public.jpeg")) { return (jpeg, "jpg") }
        guard let image = NSImage(pasteboard: pb),
              let tiff = image.tiffRepresentation else { return nil }
        return (tiff, "tiff")
    }

    private func uniqueURL(in folder: URL, ext: String) -> URL {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        var candidate = folder.appendingPathComponent("Clipboard \(stamp)").appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("Clipboard \(stamp) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}
