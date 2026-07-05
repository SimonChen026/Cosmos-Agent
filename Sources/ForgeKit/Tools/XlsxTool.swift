import Foundation

struct XlsxTool: AgentTool {
    var spec: ToolSpec {
        ToolSpec(
            name: "create_xlsx",
            description: "Create a real Microsoft Excel .xlsx file from a table of rows. To overwrite an existing file you must read_file it first.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute, ~/ or workspace-relative path for the output .xlsx file."],
                    "sheetName": ["type": "string", "description": "Worksheet tab name (default \"Sheet1\")."],
                    "rows": [
                        "type": "array",
                        "description": "Table rows; each inner array is one row of cell values. Values that parse as numbers become numeric cells, otherwise text cells.",
                        "items": [
                            "type": "array",
                            "items": ["type": "string"],
                        ],
                    ],
                ],
                "required": ["path", "rows"],
            ]
        )
    }

    var permissionClass: PermissionClass { .write }

    func summarize(input: JSONValue) -> String {
        let path = input["path"]?.stringValue ?? "?"
        let rows = input["rows"]?.arrayValue ?? []
        let cols = rows.first?.arrayValue?.count ?? 0
        return "create \((path as NSString).lastPathComponent) (\(rows.count) rows × \(cols) cols)"
    }

    func execute(input: JSONValue, context: ToolContext) async -> ToolOutput {
        guard let path = input["path"]?.stringValue, !path.isEmpty else {
            return .error("create_xlsx: missing required parameter `path`.")
        }
        guard let rowsInput = input["rows"]?.arrayValue else {
            return .error("create_xlsx: missing required parameter `rows`.")
        }
        let sheetName = input["sheetName"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Sheet1"

        let rows: [[String]] = rowsInput.map { row in
            (row.arrayValue ?? []).map { $0.stringValue ?? "" }
        }

        let url = Util.resolvePath(path, workspace: context.workspaceRoot)
        let canonical = url.standardizedFileURL.path
        let fm = FileManager.default

        if fm.fileExists(atPath: url.path) {
            guard context.session.wasRead(canonical) else {
                return .error("\(url.path) already exists. read_file it first, then overwrite or edit_file it.")
            }
        }

        let stagingRoot = fm.temporaryDirectory.appendingPathComponent("forge-xlsx-\(UUID().uuidString)")
        do {
            try buildPackage(at: stagingRoot, sheetName: sheetName, rows: rows, fm: fm)
        } catch {
            try? fm.removeItem(at: stagingRoot)
            return .error("Could not stage xlsx package: \(error.localizedDescription)")
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

        let zipResult = await runZip(stagingRoot: stagingRoot, outputURL: url)
        try? fm.removeItem(at: stagingRoot)
        if let error = zipResult {
            return .error("zip failed while creating \(url.path): \(error)")
        }

        context.session.markRead(canonical)

        let display = Util.displayPath(url, workspace: context.workspaceRoot)
        let cols = rows.first?.count ?? 0
        return ToolOutput(
            content: "Wrote \(display) (\(rows.count) rows × \(cols) cols)",
            displayHint: .fileContent(path: display)
        )
    }

    // MARK: - Package assembly

    private func buildPackage(at root: URL, sheetName: String, rows: [[String]], fm: FileManager) throws {
        let xlDir = root.appendingPathComponent("xl")
        let xlRelsDir = xlDir.appendingPathComponent("_rels")
        let worksheetsDir = xlDir.appendingPathComponent("worksheets")
        let rootRelsDir = root.appendingPathComponent("_rels")
        let docPropsDir = root.appendingPathComponent("docProps")

        for dir in [root, xlDir, xlRelsDir, worksheetsDir, rootRelsDir, docPropsDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        try write(contentTypesXML(), to: root.appendingPathComponent("[Content_Types].xml"))
        try write(rootRelsXML(), to: rootRelsDir.appendingPathComponent(".rels"))
        try write(workbookXML(sheetName: sheetName), to: xlDir.appendingPathComponent("workbook.xml"))
        try write(workbookRelsXML(), to: xlRelsDir.appendingPathComponent("workbook.xml.rels"))
        try write(worksheetXML(rows: rows), to: worksheetsDir.appendingPathComponent("sheet1.xml"))
        try write(coreXML(), to: docPropsDir.appendingPathComponent("core.xml"))
        try write(appXML(sheetName: sheetName), to: docPropsDir.appendingPathComponent("app.xml"))
    }

    private func write(_ content: String, to url: URL) throws {
        try Data(content.utf8).write(to: url, options: .atomic)
    }

    private func contentTypesXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
        </Types>
        """
    }

    private func rootRelsXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
        </Relationships>
        """
    }

    private func workbookXML(sheetName: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets>
        <sheet name="\(xmlEscape(sheetName))" sheetId="1" r:id="rId1"/>
        </sheets>
        </workbook>
        """
    }

    private func workbookRelsXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        </Relationships>
        """
    }

    private func worksheetXML(rows: [[String]]) -> String {
        var sheetData = ""
        for (rowIndex, row) in rows.enumerated() {
            let rowNumber = rowIndex + 1
            sheetData += "<row r=\"\(rowNumber)\">"
            for (colIndex, value) in row.enumerated() {
                let ref = "\(columnLetter(colIndex))\(rowNumber)"
                if let number = Double(value), value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, !value.isEmpty {
                    sheetData += "<c r=\"\(ref)\"><v>\(formatNumber(number))</v></c>"
                } else {
                    sheetData += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(value))</t></is></c>"
                }
            }
            sheetData += "</row>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <sheetData>\(sheetData)</sheetData>
        </worksheet>
        """
    }

    private func coreXML() -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created>
        <dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified>
        </cp:coreProperties>
        """
    }

    private func appXML(sheetName: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
        <Application>Forge</Application>
        <TitlesOfParts>
        <vt:vector size="1" baseType="lpstr">
        <vt:lpstr>\(xmlEscape(sheetName))</vt:lpstr>
        </vt:vector>
        </TitlesOfParts>
        </Properties>
        """
    }

    // MARK: - Cell helpers

    private func columnLetter(_ index: Int) -> String {
        var n = index
        var letters = ""
        repeat {
            letters = String(UnicodeScalar(UInt8(65 + n % 26))) + letters
            n = n / 26 - 1
        } while n >= 0
        return letters
    }

    private func formatNumber(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    private func xmlEscape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    // MARK: - Zipping

    private func runZip(stagingRoot: URL, outputURL: URL) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.arguments = ["-X", "-r", outputURL.path, "."]
            process.currentDirectoryURL = stagingRoot
            process.standardInput = FileHandle.nullDevice

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    cont.resume(returning: nil)
                } else {
                    let data = (try? pipe.fileHandleForReading.readToEnd()) ?? nil
                    let message = data.map { String(decoding: $0, as: UTF8.self) } ?? "unknown error"
                    cont.resume(returning: "exit code \(proc.terminationStatus): \(message)")
                }
            }

            do {
                try process.run()
            } catch {
                cont.resume(returning: error.localizedDescription)
            }
        }
    }
}
