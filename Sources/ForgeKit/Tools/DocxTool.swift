import Foundation

struct DocxTool: AgentTool {
    var spec: ToolSpec {
        ToolSpec(
            name: "create_docx",
            description: "Create a real Microsoft Word .docx file from a list of paragraphs. A paragraph starting with \"# \" renders as Heading 1, \"## \" as Heading 2, \"- \" as a bullet list item, anything else as a normal paragraph. To overwrite an existing file you must read_file it first.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute, ~/ or workspace-relative path for the .docx file."],
                    "title": ["type": "string", "description": "Optional document title (stored in document properties)."],
                    "paragraphs": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Paragraph strings. \"# \" = Heading 1, \"## \" = Heading 2, \"- \" = bullet, else normal text.",
                    ],
                ],
                "required": ["path", "paragraphs"],
            ]
        )
    }

    var permissionClass: PermissionClass { .write }

    func summarize(input: JSONValue) -> String {
        let name = (input["path"]?.stringValue ?? "?" as String)
        let base = (name as NSString).lastPathComponent
        let n = input["paragraphs"]?.arrayValue?.count ?? 0
        return "create \(base) (\(n) paragraph\(n == 1 ? "" : "s"))"
    }

    func execute(input: JSONValue, context: ToolContext) async -> ToolOutput {
        guard let path = input["path"]?.stringValue, !path.isEmpty else {
            return .error("create_docx: missing required parameter `path`.")
        }
        guard let paragraphValues = input["paragraphs"]?.arrayValue else {
            return .error("create_docx: missing required parameter `paragraphs` (array).")
        }
        let paragraphs = paragraphValues.compactMap { $0.stringValue }
        let title = input["title"]?.stringValue ?? ""

        let url = Util.resolvePath(path, workspace: context.workspaceRoot)
        let canonical = url.standardizedFileURL.path
        let fm = FileManager.default

        if fm.fileExists(atPath: url.path) {
            guard context.session.wasRead(canonical) else {
                return .error("\(url.path) already exists. read_file it first, then overwrite or edit_file it.")
            }
        }

        let stagingRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("forge-docx-\(UUID().uuidString)")

        do {
            try Self.buildPackage(at: stagingRoot, title: title, paragraphs: paragraphs)
        } catch {
            try? fm.removeItem(at: stagingRoot)
            return .error("Could not assemble docx contents: \(error.localizedDescription)")
        }

        do {
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
        } catch {
            try? fm.removeItem(at: stagingRoot)
            return .error("Could not prepare \(url.path): \(error.localizedDescription)")
        }

        let zipResult = Self.runZip(sourceDir: stagingRoot, outputPath: url.path)
        try? fm.removeItem(at: stagingRoot)

        switch zipResult {
        case .failure(let message):
            return .error("Failed to zip docx package: \(message)")
        case .success:
            break
        }

        context.session.markRead(canonical)

        let display = Util.displayPath(url, workspace: context.workspaceRoot)
        return ToolOutput(
            content: "Created \(display) (\(paragraphs.count) paragraph\(paragraphs.count == 1 ? "" : "s"))",
            displayHint: .fileContent(path: display)
        )
    }

    // MARK: - Package assembly

    private enum ZipResult {
        case success
        case failure(String)
    }

    private static func buildPackage(at root: URL, title: String, paragraphs: [String]) throws {
        let fm = FileManager.default
        let relsDir = root.appendingPathComponent("_rels")
        let wordDir = root.appendingPathComponent("word")
        let wordRelsDir = wordDir.appendingPathComponent("_rels")
        let docPropsDir = root.appendingPathComponent("docProps")

        for dir in [root, relsDir, wordDir, wordRelsDir, docPropsDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        try Data(contentTypesXML.utf8).write(to: root.appendingPathComponent("[Content_Types].xml"))
        try Data(rootRelsXML.utf8).write(to: relsDir.appendingPathComponent(".rels"))
        try Data(documentXML(title: title, paragraphs: paragraphs).utf8)
            .write(to: wordDir.appendingPathComponent("document.xml"))
        try Data(documentRelsXML.utf8).write(to: wordRelsDir.appendingPathComponent("document.xml.rels"))
        try Data(coreXML(title: title).utf8).write(to: docPropsDir.appendingPathComponent("core.xml"))
        try Data(appXML.utf8).write(to: docPropsDir.appendingPathComponent("app.xml"))
    }

    private static func runZip(sourceDir: URL, outputPath: String) -> ZipResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-X", "-r", outputPath, "."]
        process.currentDirectoryURL = sourceDir

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .failure("Failed to launch /usr/bin/zip: \(error.localizedDescription)")
        }
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? nil
            let output = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            return .failure("zip exited with code \(process.terminationStatus): \(output)")
        }
        return .success
    }

    // MARK: - XML templates

    private static func xmlEscape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&apos;")
        return out
    }

    private static func paragraphXML(_ text: String) -> String {
        if text.hasPrefix("# ") {
            let body = String(text.dropFirst(2))
            return """
            <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t xml:space="preserve">\(xmlEscape(body))</w:t></w:r></w:p>
            """
        }
        if text.hasPrefix("## ") {
            let body = String(text.dropFirst(3))
            return """
            <w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t xml:space="preserve">\(xmlEscape(body))</w:t></w:r></w:p>
            """
        }
        if text.hasPrefix("- ") {
            let body = String(text.dropFirst(2))
            return """
            <w:p><w:pPr><w:pStyle w:val="ListParagraph"/><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t xml:space="preserve">\(xmlEscape(body))</w:t></w:r></w:p>
            """
        }
        return """
        <w:p><w:r><w:t xml:space="preserve">\(xmlEscape(text))</w:t></w:r></w:p>
        """
    }

    private static func documentXML(title: String, paragraphs: [String]) -> String {
        let body = paragraphs.map(paragraphXML).joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>
        \(body)
        <w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>
        </w:body>
        </w:document>
        """
    }

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
    <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
    </Types>
    """

    private static let rootRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
    <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
    </Relationships>
    """

    private static let documentRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    </Relationships>
    """

    private static func coreXML(title: String) -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <dc:title>\(xmlEscape(title))</dc:title>
        <dc:creator>Forge</dc:creator>
        <cp:lastModifiedBy>Forge</cp:lastModifiedBy>
        <dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created>
        <dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified>
        </cp:coreProperties>
        """
    }

    private static let appXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
    <Application>Forge</Application>
    </Properties>
    """
}
