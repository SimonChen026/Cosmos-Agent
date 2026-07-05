import Foundation

struct WebSearchTool: AgentTool {
    var spec: ToolSpec {
        ToolSpec(
            name: "web_search",
            description: "Search the public web (no API key required) and return a numbered list of results with title, URL and snippet.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Search query."],
                    "max_results": ["type": "integer", "description": "Max results to return (default 5, capped at 10)."],
                ],
                "required": ["query"],
            ]
        )
    }

    // No local filesystem mutation happens here, only an outbound HTTP GET
    // and text parsing — classified like grep/glob rather than .execute.
    var permissionClass: PermissionClass { .read }

    func summarize(input: JSONValue) -> String {
        "search: \(input["query"]?.stringValue ?? "?")"
    }

    func execute(input: JSONValue, context: ToolContext) async -> ToolOutput {
        guard let query = input["query"]?.stringValue, !query.isEmpty else {
            return .error("web_search: missing required parameter `query`.")
        }
        let maxResults = min(max(input["max_results"]?.intValue ?? 5, 1), 10)

        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else {
            return .error("web_search: could not build request URL for query.")
        }

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .error("web_search: request failed — \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            return .error("web_search: search endpoint returned HTTP \(code).")
        }

        guard let html = String(data: data, encoding: .utf8) else {
            return .error("web_search: could not decode response body.")
        }

        let results = Self.parseResults(html: html, maxResults: maxResults)
        if results.isEmpty {
            return ToolOutput(content: "No results found for \"\(query)\".")
        }

        var lines: [String] = []
        for (i, r) in results.enumerated() {
            lines.append("\(i + 1). \(r.title)\n   \(r.url)\n   \(r.snippet)\n")
        }
        return ToolOutput(content: lines.joined(separator: "\n"))
    }

    private struct Result {
        var title: String
        var url: String
        var snippet: String
    }

    private static func parseResults(html: String, maxResults: Int) -> [Result] {
        let titleRegex = try? NSRegularExpression(
            pattern: #"<a[^>]*class="result__a"[^>]*href="([^"]*)"[^>]*>(.*?)</a>"#,
            options: [.dotMatchesLineSeparators]
        )
        let snippetRegex = try? NSRegularExpression(
            pattern: #"<a[^>]*class="result__snippet"[^>]*>(.*?)</a>"#,
            options: [.dotMatchesLineSeparators]
        )
        guard let titleRegex, let snippetRegex else { return [] }

        let ns = html as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        // DuckDuckGo emits one result__a and one result__snippet per result
        // (organic or ad) in matching order, so zip them positionally before
        // filtering out ads — filtering titles alone first would desync the
        // two lists whenever an ad is dropped.
        var rawTitles: [(url: String, title: String)] = []
        titleRegex.enumerateMatches(in: html, range: fullRange) { match, _, _ in
            guard let match, match.numberOfRanges >= 3 else { return }
            let url = ns.substring(with: match.range(at: 1))
            let title = ns.substring(with: match.range(at: 2))
            rawTitles.append((url: decodeEntities(url), title: stripTags(title)))
        }

        var rawSnippets: [String] = []
        snippetRegex.enumerateMatches(in: html, range: fullRange) { match, _, _ in
            guard let match, match.numberOfRanges >= 2 else { return }
            rawSnippets.append(stripTags(ns.substring(with: match.range(at: 1))))
        }

        var results: [Result] = []
        for (i, t) in rawTitles.enumerated() {
            guard results.count < maxResults else { break }
            // Ad redirects go through duckduckgo.com/y.js — skip, not real destinations.
            guard !t.url.contains("duckduckgo.com/y.js") else { continue }
            let snippet = i < rawSnippets.count ? rawSnippets[i] : ""
            results.append(Result(title: t.title, url: t.url, snippet: snippet))
        }
        return results
    }

    private static func stripTags(_ text: String) -> String {
        let noTags = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return decodeEntities(noTags).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        let named: [(String, String)] = [
            ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "),
        ]
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        if let numericRegex = try? NSRegularExpression(pattern: #"&#(x?[0-9A-Fa-f]+);"#) {
            let mutable = NSMutableString(string: result)
            let matches = numericRegex.matches(in: result, range: NSRange(location: 0, length: mutable.length))
            for match in matches.reversed() {
                let code = mutable.substring(with: match.range(at: 1))
                let scalarValue: UInt32?
                if code.hasPrefix("x") || code.hasPrefix("X") {
                    scalarValue = UInt32(code.dropFirst(), radix: 16)
                } else {
                    scalarValue = UInt32(code)
                }
                guard let scalarValue, let scalar = Unicode.Scalar(scalarValue) else { continue }
                mutable.replaceCharacters(in: match.range, with: String(Character(scalar)))
            }
            result = mutable as String
        }
        return result
    }
}
