import Foundation
import WebKit

// MARK: - Export Generator Protocol

protocol ExportGenerator {
    func generate(from document: ExportDocument) throws -> Data
}

// MARK: - Export Errors

enum ExportError: LocalizedError {
    case noContent
    case noSegments
    case pdfRenderingFailed
    case docxPackagingFailed

    var errorDescription: String? {
        switch self {
        case .noContent: return "No hay contenido para exportar"
        case .noSegments: return "No hay segmentos con timestamps para este formato"
        case .pdfRenderingFailed: return "Error al generar el PDF"
        case .docxPackagingFailed: return "Error al generar el archivo DOCX"
        }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - CSV Generator
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct CSVExportGenerator: ExportGenerator {
    /// When false, outputs only Text+Favorite columns (simple mode).
    var includeTimestamps: Bool = true

    func generate(from document: ExportDocument) throws -> Data {
        guard !document.isEmpty else { throw ExportError.noContent }

        var csv = "\u{FEFF}" // UTF-8 BOM for Excel/Windows compatibility

        if document.segments.isEmpty {
            // Plain text fallback: single column
            csv += "Text\r\n"
            csv += csvEscape(document.plainText) + "\r\n"
        } else if !includeTimestamps {
            // Simple mode: Text + Favorite only
            csv += "Text,Favorite\r\n"
            for segment in document.segments {
                var fields: [String] = []
                fields.append(csvEscape(segment.text))
                fields.append(segment.isFavorite ? "Yes" : "")
                csv += fields.joined(separator: ",") + "\r\n"
            }
        } else {
            // Structured mode: full timestamp + speaker + favorite columns
            var headers: [String] = []
            headers.append("Start")
            headers.append("End")
            headers.append("Duration")
            if document.hasSpeakers {
                headers.append("Speaker")
            }
            headers.append("Text")
            headers.append("Favorite")

            csv += headers.joined(separator: ",") + "\r\n"

            // Rows
            for segment in document.segments {
                var fields: [String] = []
                fields.append(csvEscape(segment.formattedStartTime))
                fields.append(csvEscape(segment.formattedEndTime))
                fields.append(csvEscape(segment.formattedDuration))
                if document.hasSpeakers {
                    let speaker = segment.speaker.map { "Speaker \($0 + 1)" } ?? ""
                    fields.append(csvEscape(speaker))
                }
                fields.append(csvEscape(segment.text))
                fields.append(segment.isFavorite ? "Yes" : "")
                csv += fields.joined(separator: ",") + "\r\n"
            }
        }

        guard let data = csv.data(using: .utf8) else { throw ExportError.noContent }
        return data
    }

    /// RFC 4180 compliant CSV field escaping
    private func csvEscape(_ field: String) -> String {
        let needsQuoting = field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r")
        if needsQuoting {
            let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return field
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - HTML Generator
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct HTMLExportGenerator: ExportGenerator {
    /// If true, includes @page CSS rules for PDF headers/footers
    var includePrintStyles: Bool = false

    func generate(from document: ExportDocument) throws -> Data {
        guard !document.isEmpty else { throw ExportError.noContent }

        let html = buildHTML(from: document)
        guard let data = html.data(using: .utf8) else { throw ExportError.noContent }
        return data
    }

    func buildHTML(from document: ExportDocument) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short

        let formattedDate = dateFormatter.string(from: document.createdAt)
        let formattedDuration = formatDuration(document.duration)

        var html = """
        <!DOCTYPE html>
        <html lang="\(document.language)">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>\(escapeHTML(document.title))</title>
            <style>
                \(cssStyles(for: document))
            </style>
        </head>
        <body>
            <div class="container">
                <header class="doc-header">
                    <h1>\(escapeHTML(document.title))</h1>
                    <div class="meta">
                        <span class="meta-item">📅 \(formattedDate)</span>
                        <span class="meta-item">⏱ \(formattedDuration)</span>
                        <span class="meta-item">🌐 \(escapeHTML(document.language.uppercased()))</span>
                        <span class="meta-item">🤖 \(escapeHTML(document.modelName))</span>
                    </div>
                </header>

                <main class="content">
        """

        if document.segments.isEmpty {
            // Plain text mode
            html += """
                        <div class="plain-text">
                            \(formatPlainTextAsHTML(document.plainText))
                        </div>
            """
        } else if document.hasSpeakers {
            // Speaker-grouped mode
            html += buildSpeakerHTML(from: document)
        } else {
            // Segment table mode (no speakers)
            html += buildSegmentTableHTML(from: document)
        }

        html += """
                </main>

                <footer class="doc-footer">
                    <p>Exported from Transcriptor X</p>
                </footer>
            </div>
        </body>
        </html>
        """

        return html
    }

    // MARK: - CSS

    private func cssStyles(for document: ExportDocument) -> String {
        var css = """
        * { margin: 0; padding: 0; box-sizing: border-box; }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', sans-serif;
            background: #0a0a0f;
            color: #e8e8ec;
            line-height: 1.7;
            -webkit-font-smoothing: antialiased;
        }

        .container {
            max-width: 860px;
            margin: 0 auto;
            padding: 48px 32px;
        }

        .doc-header {
            margin-bottom: 40px;
            padding-bottom: 24px;
            border-bottom: 1px solid rgba(255,255,255,0.08);
        }

        .doc-header h1 {
            font-size: 28px;
            font-weight: 700;
            color: #ffffff;
            margin-bottom: 12px;
            letter-spacing: -0.02em;
        }

        .meta {
            display: flex;
            flex-wrap: wrap;
            gap: 16px;
        }

        .meta-item {
            font-size: 13px;
            color: #8e8e93;
            background: rgba(255,255,255,0.04);
            padding: 4px 12px;
            border-radius: 20px;
        }

        .content {
            margin-bottom: 48px;
        }

        .plain-text {
            font-size: 15px;
            line-height: 1.8;
            color: #d1d1d6;
            white-space: pre-wrap;
        }

        .plain-text p {
            margin-bottom: 16px;
        }

        /* Segment Table */
        .segment-table {
            width: 100%;
            border-collapse: collapse;
        }

        .segment-table th {
            text-align: left;
            font-size: 11px;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            color: #636366;
            padding: 8px 12px;
            border-bottom: 1px solid rgba(255,255,255,0.08);
        }

        .segment-table td {
            padding: 10px 12px;
            font-size: 14px;
            vertical-align: top;
            border-bottom: 1px solid rgba(255,255,255,0.03);
        }

        .segment-table tr:hover {
            background: rgba(255,255,255,0.02);
        }

        .time-cell {
            color: #8e8e93;
            font-family: 'SF Mono', 'Menlo', monospace;
            font-size: 12px;
            white-space: nowrap;
        }

        .text-cell {
            color: #e8e8ec;
        }

        /* Speaker blocks */
        .speaker-block {
            margin-bottom: 24px;
        }

        .speaker-label {
            display: inline-block;
            font-size: 12px;
            font-weight: 700;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            padding: 3px 10px;
            border-radius: 6px;
            margin-bottom: 8px;
        }

        .speaker-segment {
            padding: 6px 0 6px 16px;
            border-left: 2px solid rgba(255,255,255,0.06);
            margin-bottom: 4px;
        }

        .speaker-segment .timestamp {
            font-family: 'SF Mono', 'Menlo', monospace;
            font-size: 11px;
            color: #636366;
            margin-right: 8px;
        }

        .speaker-segment .text {
            font-size: 14px;
            color: #d1d1d6;
        }

        /* Speaker colors */
        .speaker-0 { color: #5AC8FA; background: rgba(90,200,250,0.12); }
        .speaker-1 { color: #FF9F0A; background: rgba(255,159,10,0.12); }
        .speaker-2 { color: #30D158; background: rgba(48,209,88,0.12); }
        .speaker-3 { color: #BF5AF2; background: rgba(191,90,242,0.12); }
        .speaker-4 { color: #FF375F; background: rgba(255,55,95,0.12); }
        .speaker-5 { color: #64D2FF; background: rgba(100,210,255,0.12); }
        .speaker-border-0 { border-left-color: #5AC8FA; }
        .speaker-border-1 { border-left-color: #FF9F0A; }
        .speaker-border-2 { border-left-color: #30D158; }
        .speaker-border-3 { border-left-color: #BF5AF2; }
        .speaker-border-4 { border-left-color: #FF375F; }
        .speaker-border-5 { border-left-color: #64D2FF; }

        .doc-footer {
            text-align: center;
            padding-top: 24px;
            border-top: 1px solid rgba(255,255,255,0.06);
            font-size: 12px;
            color: #48484a;
        }
        """

        if includePrintStyles {
            css += """

            @page {
                size: A4;
                margin: 2cm 2.5cm;
                @top-center {
                    content: "\(escapeHTML(document.title))";
                    font-size: 9px;
                    color: #999;
                }
                @bottom-center {
                    content: counter(page) " / " counter(pages);
                    font-size: 9px;
                    color: #999;
                }
            }

            @media print {
                body { background: white; color: #1c1c1e; }
                .doc-header { border-bottom-color: #e5e5ea; }
                .doc-header h1 { color: #1c1c1e; }
                .meta-item { background: #f2f2f7; color: #3a3a3c; }
                .segment-table td { border-bottom-color: #e5e5ea; }
                .segment-table th { border-bottom-color: #c7c7cc; color: #3a3a3c; }
                .text-cell { color: #1c1c1e; }
                .plain-text { color: #1c1c1e; }
                .time-cell { color: #636366; }
                .speaker-segment .text { color: #1c1c1e; }
                .doc-footer { border-top-color: #e5e5ea; color: #aeaeb2; }
                .segment-table tr:hover { background: transparent; }
            }
            """
        }

        return css
    }

    // MARK: - Content Builders

    private func buildSegmentTableHTML(from document: ExportDocument) -> String {
        var html = """
                    <table class="segment-table">
                        <thead>
                            <tr>
                                <th>Time</th>
                                <th>Text</th>
                            </tr>
                        </thead>
                        <tbody>
        """

        for segment in document.segments {
            html += """
                            <tr>
                                <td class="time-cell">\(segment.formattedStartTime)</td>
                                <td class="text-cell">\(escapeHTML(segment.text))</td>
                            </tr>
            """
        }

        html += """
                        </tbody>
                    </table>
        """
        return html
    }

    private func buildSpeakerHTML(from document: ExportDocument) -> String {
        var html = ""
        var currentSpeaker: Int? = nil

        for segment in document.segments {
            if segment.speaker != currentSpeaker {
                // Close previous block
                if currentSpeaker != nil {
                    html += "            </div>\n"
                }
                currentSpeaker = segment.speaker
                let speakerIndex = currentSpeaker ?? 0
                let colorClass = "speaker-\(speakerIndex % 6)"
                let borderClass = "speaker-border-\(speakerIndex % 6)"

                html += """
                        <div class="speaker-block">
                            <span class="speaker-label \(colorClass)">Speaker \(speakerIndex)</span>
                """
                _ = borderClass // used below per segment
            }

            let borderClass = "speaker-border-\((segment.speaker ?? 0) % 6)"
            html += """
                            <div class="speaker-segment \(borderClass)">
                                <span class="timestamp">\(segment.formattedStartTime)</span>
                                <span class="text">\(escapeHTML(segment.text))</span>
                            </div>
            """
        }

        // Close last block
        if currentSpeaker != nil {
            html += "            </div>\n"
        }

        return html
    }

    // MARK: - Utilities

    private func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func formatPlainTextAsHTML(_ text: String) -> String {
        let paragraphs = text.components(separatedBy: "\n\n")
        return paragraphs.map { "<p>\(escapeHTML($0))</p>" }.joined(separator: "\n")
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - PDF Generator
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class PDFExportGenerator {
    /// Generate PDF data asynchronously using WKWebView rendering
    @MainActor
    func generate(from document: ExportDocument) async throws -> Data {
        guard !document.isEmpty else { throw ExportError.noContent }

        // Generate HTML with print-optimized styles
        var htmlGenerator = HTMLExportGenerator()
        htmlGenerator.includePrintStyles = true
        let html = htmlGenerator.buildHTML(from: document)

        // Create an off-screen WKWebView
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 595, height: 842), configuration: config)

        // Load HTML and wait for it to finish
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = PDFNavigationDelegate { result in
                switch result {
                case .success(let data):
                    continuation.resume(returning: data)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            // Retain delegate
            objc_setAssociatedObject(webView, "pdfDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            webView.navigationDelegate = delegate
            webView.loadHTMLString(html, baseURL: nil)
        }
    }
}

/// Navigation delegate that triggers PDF creation once the page finishes loading
private class PDFNavigationDelegate: NSObject, WKNavigationDelegate {
    let completion: (Result<Data, Error>) -> Void

    init(completion: @escaping (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Small delay to ensure CSS is fully applied
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let pdfConfig = WKPDFConfiguration()
            pdfConfig.rect = NSRect(x: 0, y: 0, width: 595.28, height: 841.89) // A4

            webView.createPDF(configuration: pdfConfig) { [weak self] result in
                switch result {
                case .success(let data):
                    self?.completion(.success(data))
                case .failure(let error):
                    self?.completion(.failure(error))
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completion(.failure(ExportError.pdfRenderingFailed))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        completion(.failure(ExportError.pdfRenderingFailed))
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - DOCX Generator
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct DOCXExportGenerator: ExportGenerator {
    func generate(from document: ExportDocument) throws -> Data {
        guard !document.isEmpty else { throw ExportError.noContent }

        // Create temporary directory for DOCX structure
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("docx_\(UUID().uuidString)")

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            // Create directory structure
            let relsDir = tempDir.appendingPathComponent("_rels")
            let wordDir = tempDir.appendingPathComponent("word")
            let wordRelsDir = wordDir.appendingPathComponent("_rels")
            try FileManager.default.createDirectory(at: relsDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: wordRelsDir, withIntermediateDirectories: true)

            // 1. [Content_Types].xml
            try contentTypesXML().write(
                to: tempDir.appendingPathComponent("[Content_Types].xml"),
                atomically: true, encoding: .utf8
            )

            // 2. _rels/.rels
            try relsXML().write(
                to: relsDir.appendingPathComponent(".rels"),
                atomically: true, encoding: .utf8
            )

            // 3. word/_rels/document.xml.rels
            try wordRelsXML().write(
                to: wordRelsDir.appendingPathComponent("document.xml.rels"),
                atomically: true, encoding: .utf8
            )

            // 4. word/styles.xml
            try stylesXML().write(
                to: wordDir.appendingPathComponent("styles.xml"),
                atomically: true, encoding: .utf8
            )

            // 5. word/document.xml
            try documentXML(from: document).write(
                to: wordDir.appendingPathComponent("document.xml"),
                atomically: true, encoding: .utf8
            )

            // Create ZIP
            let zipURL = tempDir.appendingPathComponent("export.docx")
            let success = createZip(from: tempDir, to: zipURL, excluding: ["export.docx"])
            guard success else { throw ExportError.docxPackagingFailed }

            return try Data(contentsOf: zipURL)
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.docxPackagingFailed
        }
    }

    // MARK: - XML Parts

    private func contentTypesXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
            <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        </Types>
        """
    }

    private func relsXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """
    }

    private func wordRelsXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """
    }

    private func stylesXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <w:style w:type="paragraph" w:styleId="Title">
                <w:name w:val="Title"/>
                <w:pPr><w:spacing w:after="240"/></w:pPr>
                <w:rPr>
                    <w:b/><w:sz w:val="52"/><w:szCs w:val="52"/>
                    <w:color w:val="1C1C1E"/>
                </w:rPr>
            </w:style>
            <w:style w:type="paragraph" w:styleId="Metadata">
                <w:name w:val="Metadata"/>
                <w:pPr><w:spacing w:after="60"/></w:pPr>
                <w:rPr>
                    <w:sz w:val="20"/><w:szCs w:val="20"/>
                    <w:color w:val="8E8E93"/>
                </w:rPr>
            </w:style>
            <w:style w:type="paragraph" w:styleId="SpeakerLabel">
                <w:name w:val="Speaker Label"/>
                <w:pPr><w:spacing w:before="240" w:after="80"/></w:pPr>
                <w:rPr>
                    <w:b/><w:sz w:val="22"/><w:szCs w:val="22"/>
                    <w:color w:val="5AC8FA"/>
                </w:rPr>
            </w:style>
            <w:style w:type="paragraph" w:styleId="Timestamp">
                <w:name w:val="Timestamp"/>
                <w:pPr><w:spacing w:after="40"/></w:pPr>
                <w:rPr>
                    <w:sz w:val="18"/><w:szCs w:val="18"/>
                    <w:color w:val="636366"/>
                    <w:rFonts w:ascii="Menlo" w:hAnsi="Menlo"/>
                </w:rPr>
            </w:style>
            <w:style w:type="paragraph" w:styleId="BodyText">
                <w:name w:val="Body Text"/>
                <w:pPr><w:spacing w:after="120"/></w:pPr>
                <w:rPr>
                    <w:sz w:val="24"/><w:szCs w:val="24"/>
                    <w:color w:val="1C1C1E"/>
                </w:rPr>
            </w:style>
        </w:styles>
        """
    }

    private func documentXML(from document: ExportDocument) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short
        let formattedDate = dateFormatter.string(from: document.createdAt)

        var body = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <w:body>
        """

        // Title
        body += paragraph(text: escapeXML(document.title), style: "Title")

        // Metadata
        body += paragraph(text: "📅 \(formattedDate)", style: "Metadata")
        body += paragraph(text: "🌐 \(document.language.uppercased()) · 🤖 \(escapeXML(document.modelName))", style: "Metadata")

        // Separator (empty paragraph)
        body += "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"4\" w:space=\"1\" w:color=\"E5E5EA\"/></w:pBdr></w:pPr></w:p>"

        if document.segments.isEmpty {
            // Plain text
            let paragraphs = document.plainText.components(separatedBy: "\n\n")
            for para in paragraphs {
                let trimmed = para.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    body += paragraph(text: escapeXML(trimmed), style: "BodyText")
                }
            }
        } else if document.hasSpeakers {
            // Speaker-grouped
            var currentSpeaker: Int? = nil
            for segment in document.segments {
                if segment.speaker != currentSpeaker {
                    currentSpeaker = segment.speaker
                    body += paragraph(text: "Speaker \(currentSpeaker ?? 0)", style: "SpeakerLabel")
                }
                // Timestamp + text in a single paragraph with mixed runs
                body += timestampTextParagraph(
                    timestamp: segment.formattedStartTime,
                    text: escapeXML(segment.text)
                )
            }
        } else {
            // Segments without speakers
            for segment in document.segments {
                body += timestampTextParagraph(
                    timestamp: segment.formattedStartTime,
                    text: escapeXML(segment.text)
                )
            }
        }

        body += """
            </w:body>
        </w:document>
        """
        return body
    }

    // MARK: - XML Helpers

    private func paragraph(text: String, style: String) -> String {
        """
        <w:p>
            <w:pPr><w:pStyle w:val="\(style)"/></w:pPr>
            <w:r><w:t xml:space="preserve">\(text)</w:t></w:r>
        </w:p>
        """
    }

    private func timestampTextParagraph(timestamp: String, text: String) -> String {
        """
        <w:p>
            <w:pPr><w:pStyle w:val="BodyText"/></w:pPr>
            <w:r>
                <w:rPr>
                    <w:sz w:val="18"/><w:szCs w:val="18"/>
                    <w:color w:val="636366"/>
                    <w:rFonts w:ascii="Menlo" w:hAnsi="Menlo"/>
                </w:rPr>
                <w:t xml:space="preserve">[\(timestamp)] </w:t>
            </w:r>
            <w:r><w:t xml:space="preserve">\(text)</w:t></w:r>
        </w:p>
        """
    }

    private func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    // MARK: - ZIP Packaging

    private func createZip(from directory: URL, to zipURL: URL, excluding: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-c", "-k", "--sequesterRsrc", "--keepParent",
            directory.path,
            zipURL.path
        ]

        // We need a more targeted approach: zip only the DOCX parts
        let zipProcess = Process()
        zipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zipProcess.currentDirectoryURL = directory
        zipProcess.arguments = ["-r", "-q", zipURL.path,
                                "[Content_Types].xml", "_rels", "word"]

        do {
            try zipProcess.run()
            zipProcess.waitUntilExit()
            return zipProcess.terminationStatus == 0
        } catch {
            return false
        }
    }
}
