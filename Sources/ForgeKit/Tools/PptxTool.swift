import Foundation

struct PptxTool: AgentTool {
    var spec: ToolSpec {
        ToolSpec(
            name: "create_pptx",
            description: "Create a Microsoft PowerPoint .pptx file from a list of slides, each with a title and bullet points. To overwrite an existing file you must read_file it first.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute, ~/ or workspace-relative path for the .pptx file."],
                    "slides": [
                        "type": "array",
                        "description": "Ordered list of slides.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "title": ["type": "string", "description": "Slide title."],
                                "bullets": [
                                    "type": "array",
                                    "description": "Bullet point strings for the slide body.",
                                    "items": ["type": "string"],
                                ],
                            ],
                            "required": ["title", "bullets"],
                        ],
                    ],
                ],
                "required": ["path", "slides"],
            ]
        )
    }

    var permissionClass: PermissionClass { .write }

    func summarize(input: JSONValue) -> String {
        let path = input["path"]?.stringValue ?? "?"
        let n = input["slides"]?.arrayValue?.count ?? 0
        return "create \((path as NSString).lastPathComponent) (\(n) slides)"
    }

    func execute(input: JSONValue, context: ToolContext) async -> ToolOutput {
        guard let path = input["path"]?.stringValue, !path.isEmpty else {
            return .error("create_pptx: missing required parameter `path`.")
        }
        guard let slidesInput = input["slides"]?.arrayValue, !slidesInput.isEmpty else {
            return .error("create_pptx: missing required parameter `slides` (non-empty array).")
        }

        var slides: [Slide] = []
        for (i, item) in slidesInput.enumerated() {
            guard let title = item["title"]?.stringValue else {
                return .error("create_pptx: slides[\(i)] missing required field `title`.")
            }
            let bullets = item["bullets"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            slides.append(Slide(title: title, bullets: bullets))
        }

        let url = Util.resolvePath(path, workspace: context.workspaceRoot)
        let canonical = url.standardizedFileURL.path
        let fm = FileManager.default

        if fm.fileExists(atPath: url.path) {
            guard context.session.wasRead(canonical) else {
                return .error("\(url.path) already exists. read_file it first, then overwrite or edit_file it.")
            }
        }

        do {
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return .error("Could not create directory for \(url.path): \(error.localizedDescription)")
        }

        let stagingDir = fm.temporaryDirectory.appendingPathComponent("pptx-\(UUID().uuidString)")
        do {
            try PptxBuilder.writePackage(slides: slides, to: stagingDir)
        } catch {
            try? fm.removeItem(at: stagingDir)
            return .error("Could not assemble .pptx package: \(error.localizedDescription)")
        }

        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }

        let zipResult = await runZip(sourceDir: stagingDir, outputPath: url.path)
        try? fm.removeItem(at: stagingDir)

        switch zipResult {
        case .failure(let message):
            return .error("Could not zip .pptx package: \(message)")
        case .success:
            break
        }

        context.session.markRead(canonical)
        let display = Util.displayPath(url, workspace: context.workspaceRoot)
        return ToolOutput(
            content: "Created \(display) (\(slides.count) slide\(slides.count == 1 ? "" : "s"))",
            displayHint: .fileContent(path: display)
        )
    }

    private enum ZipResult {
        case success
        case failure(String)
    }

    private func runZip(sourceDir: URL, outputPath: String) async -> ZipResult {
        await withCheckedContinuation { (cont: CheckedContinuation<ZipResult, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.arguments = ["-X", "-r", outputPath, "."]
            process.currentDirectoryURL = sourceDir

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice

            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    cont.resume(returning: .success)
                } else {
                    let data = (try? pipe.fileHandleForReading.readToEnd()) ?? nil
                    let output = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                    cont.resume(returning: .failure("zip exited \(proc.terminationStatus): \(output)"))
                }
            }

            do {
                try process.run()
            } catch {
                cont.resume(returning: .failure(error.localizedDescription))
            }
        }
    }
}

// MARK: - Slide model

private struct Slide {
    var title: String
    var bullets: [String]
}

// MARK: - OOXML package assembly

private enum PptxBuilder {
    static func writePackage(slides: [Slide], to dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        try write(contentTypesXML(slideCount: slides.count), to: dir, "[Content_Types].xml")

        try write(rootRelsXML(), to: dir, "_rels/.rels")

        try write(presentationXML(slideCount: slides.count), to: dir, "ppt/presentation.xml")
        try write(presentationRelsXML(slideCount: slides.count), to: dir, "ppt/_rels/presentation.xml.rels")

        try write(slideMasterXML(), to: dir, "ppt/slideMasters/slideMaster1.xml")
        try write(slideMasterRelsXML(), to: dir, "ppt/slideMasters/_rels/slideMaster1.xml.rels")

        try write(slideLayoutXML(), to: dir, "ppt/slideLayouts/slideLayout1.xml")
        try write(slideLayoutRelsXML(), to: dir, "ppt/slideLayouts/_rels/slideLayout1.xml.rels")

        try write(themeXML(), to: dir, "ppt/theme/theme1.xml")

        for (i, slide) in slides.enumerated() {
            let n = i + 1
            try write(slideXML(slide), to: dir, "ppt/slides/slide\(n).xml")
            try write(slideRelsXML(), to: dir, "ppt/slides/_rels/slide\(n).xml.rels")
        }

        try write(coreXML(), to: dir, "docProps/core.xml")
        try write(appXML(slideCount: slides.count), to: dir, "docProps/app.xml")
    }

    private static func write(_ content: String, to dir: URL, _ relativePath: String) throws {
        let url = dir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    // MARK: XML parts

    private static func contentTypesXML(slideCount: Int) -> String {
        var overrides = ""
        overrides += "<Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/>"
        overrides += "<Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/>"
        overrides += "<Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/>"
        overrides += "<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>"
        for i in 1...max(slideCount, 1) where i <= slideCount {
            overrides += "<Override PartName=\"/ppt/slides/slide\(i).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
        }
        overrides += "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>"
        overrides += "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>"

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>\(overrides)</Types>
        """
    }

    private static func rootRelsXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>
        """
    }

    private static func presentationXML(slideCount: Int) -> String {
        var sldIdLst = ""
        for i in 0..<slideCount {
            let sldId = 256 + i
            let rId = "rId\(i + 2)" // rId1 reserved for slideMaster
            sldIdLst += "<p:sldId id=\"\(sldId)\" r:id=\"\(rId)\"/>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst>\(sldIdLst)</p:sldIdLst><p:sldSz cx="12192000" cy="6858000" type="screen16x9"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>
        """
    }

    private static func presentationRelsXML(slideCount: Int) -> String {
        var rels = "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/>"
        for i in 0..<slideCount {
            let rId = "rId\(i + 2)"
            rels += "<Relationship Id=\"\(rId)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\(i + 1).xml\"/>"
        }
        let themeRId = "rId\(slideCount + 2)"
        rels += "<Relationship Id=\"\(themeRId)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme\" Target=\"theme/theme1.xml\"/>"
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)</Relationships>
        """
    }

    private static func slideMasterXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr><p:sp><p:nvSpPr><p:cNvPr id="2" name="Title Placeholder"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang="en-US"/></a:p></p:txBody></p:sp><p:sp><p:nvSpPr><p:cNvPr id="3" name="Body Placeholder"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang="en-US"/></a:p></p:txBody></p:sp></p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>
        """
    }

    private static func slideMasterRelsXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/></Relationships>
        """
    }

    private static func slideLayoutXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="title" preserve="1"><p:cSld name="Title and Content"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr><p:sp><p:nvSpPr><p:cNvPr id="2" name="Title Placeholder"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang="en-US"/></a:p></p:txBody></p:sp><p:sp><p:nvSpPr><p:cNvPr id="3" name="Body Placeholder"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang="en-US"/></a:p></p:txBody></p:sp></p:spTree></p:cSld><p:clrMapOvr><a:overrideClrMapping bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/></p:clrMapOvr></p:sldLayout>
        """
    }

    private static func slideLayoutRelsXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>
        """
    }

    private static func slideXML(_ slide: Slide) -> String {
        var bodyParagraphs = ""
        if slide.bullets.isEmpty {
            bodyParagraphs = "<a:p><a:endParaRPr lang=\"en-US\"/></a:p>"
        } else {
            for bullet in slide.bullets {
                bodyParagraphs += "<a:p><a:r><a:rPr lang=\"en-US\" dirty=\"0\"/><a:t>\(xmlEscape(bullet))</a:t></a:r></a:p>"
            }
        }

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr><p:sp><p:nvSpPr><p:cNvPr id="2" name="Title"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="en-US" dirty="0"/><a:t>\(xmlEscape(slide.title))</a:t></a:r></a:p></p:txBody></p:sp><p:sp><p:nvSpPr><p:cNvPr id="3" name="Content"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>\(bodyParagraphs)</p:txBody></p:sp></p:spTree></p:cSld><p:clrMapOvr><a:overrideClrMapping bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/></p:clrMapOvr></p:sld>
        """
    }

    private static func slideRelsXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/></Relationships>
        """
    }

    private static func themeXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Forge Theme"><a:themeElements><a:clrScheme name="Forge"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="44546A"/></a:dk2><a:lt2><a:srgbClr val="E7E6E6"/></a:lt2><a:accent1><a:srgbClr val="4472C4"/></a:accent1><a:accent2><a:srgbClr val="ED7D31"/></a:accent2><a:accent3><a:srgbClr val="A5A5A5"/></a:accent3><a:accent4><a:srgbClr val="FFC000"/></a:accent4><a:accent5><a:srgbClr val="5B9BD5"/></a:accent5><a:accent6><a:srgbClr val="70AD47"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme><a:fontScheme name="Forge"><a:majorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme><a:fmtScheme name="Forge"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>
        """
    }

    private static func coreXML() -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>Presentation</dc:title><dc:creator>Forge</dc:creator><cp:lastModifiedBy>Forge</cp:lastModifiedBy><dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified></cp:coreProperties>
        """
    }

    private static func appXML(slideCount: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>Forge</Application><Slides>\(slideCount)</Slides><PresentationFormat>Widescreen</PresentationFormat></Properties>
        """
    }

    private static func xmlEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(c)
            }
        }
        return out
    }
}
