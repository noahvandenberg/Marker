import AppKit
import UniformTypeIdentifiers

/// A plain-text Markdown document.
///
/// Reads and writes bytes with as little interpretation as possible: the file's
/// original encoding and line endings survive a round trip untouched.
final class MarkdownDocument: NSDocument {

    enum LineEnding: String {
        case lf = "\n"
        case crlf = "\r\n"
    }

    private(set) var text: String = ""
    private var encoding: String.Encoding = .utf8
    private var lineEnding: LineEnding = .lf
    private var hadTrailingNewline = true

    weak var editor: EditorViewController?

    override class var autosavesInPlace: Bool { true }
    override class var preservesVersions: Bool { true }

    // MARK: - Window management

    override func makeWindowControllers() {
        let controller = DocumentWindowController()
        addWindowController(controller)
    }

    // MARK: - Reading

    override func read(from data: Data, ofType typeName: String) throws {
        var usedEncoding: String.Encoding = .utf8
        var contents: String?

        if let utf8 = String(data: data, encoding: .utf8) {
            contents = utf8
            usedEncoding = .utf8
        } else {
            var probed: NSString?
            let raw = NSString.stringEncoding(for: data,
                                              encodingOptions: nil,
                                              convertedString: &probed,
                                              usedLossyConversion: nil)
            if let probed, raw != 0 {
                contents = probed as String
                usedEncoding = String.Encoding(rawValue: raw)
            }
        }

        guard let contents else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSFileReadInapplicableStringEncodingError,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "This file isn’t text that Marker can read."])
        }

        encoding = usedEncoding
        lineEnding = contents.contains("\r\n") ? .crlf : .lf
        hadTrailingNewline = contents.hasSuffix("\n") || contents.isEmpty
        text = contents.replacingOccurrences(of: "\r\n", with: "\n")
    }

    // MARK: - Writing

    override func data(ofType typeName: String) throws -> Data {
        var output = text
        if hadTrailingNewline, !output.isEmpty, !output.hasSuffix("\n") {
            output += "\n"
        }
        if lineEnding == .crlf {
            output = output.replacingOccurrences(of: "\n", with: "\r\n")
        }
        guard let data = output.data(using: encoding)
                ?? output.data(using: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSFileWriteInapplicableStringEncodingError,
                          userInfo: nil)
        }
        return data
    }

    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        ["net.daringfireball.markdown", "public.plain-text"]
    }

    override class func isNativeType(_ type: String) -> Bool { true }

    // MARK: - Text plumbing

    /// Called by the editor as the user types.
    func updateText(_ newText: String) {
        guard newText != text else { return }
        text = newText
        updateChangeCount(.changeDone)
    }

    /// Pushes freshly read contents into an already-open editor (revert, etc.).
    func pushTextToEditor() {
        editor?.setText(text)
    }

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        pushTextToEditor()
    }

    // MARK: - Export

    @IBAction func exportHTML(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = (displayName as NSString)
            .deletingPathExtension.appending(".html")
        panel.canCreateDirectories = true

        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let html = HTMLExporter.export(markdown: self.text, title: self.displayName)
            do {
                try html.data(using: .utf8)?.write(to: url)
            } catch {
                self.presentError(error)
            }
        }

        if let window = windowControllers.first?.window {
            panel.beginSheetModal(for: window, completionHandler: complete)
        } else {
            complete(panel.runModal())
        }
    }
}
