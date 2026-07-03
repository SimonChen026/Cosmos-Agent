import Foundation

/// Regex-based difficulty classifier: routes a user message to a provider
/// tier. Rules run in order, first match wins; when nothing matches, cheap
/// heuristics (code fences, message length) decide.
enum DifficultyRouter {

    static func tier(for text: String, rules: [RoutingRule]) -> String {
        let range = NSRange(text.startIndex..., in: text)
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            if regex.firstMatch(in: text, range: range) != nil {
                return rule.tier
            }
        }
        if text.contains("```") || text.count > 500 { return "strong" }
        if text.count < 60 { return "fast" }
        return "balanced"
    }

    /// Providers of the requested tier, falling back to the nearest tier
    /// when none is configured. Never returns empty for non-empty input.
    static func candidates(tier: String, from providers: [Provider]) -> [Provider] {
        let preference: [String]
        switch tier {
        case "fast": preference = ["fast", "balanced", "strong"]
        case "strong": preference = ["strong", "balanced", "fast"]
        default: preference = ["balanced", "strong", "fast"]
        }
        for wanted in preference {
            let matches = providers.filter { $0.tier == wanted }
            if !matches.isEmpty { return matches }
        }
        return providers
    }
}
