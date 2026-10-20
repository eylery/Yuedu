import Foundation

/// A deliberately bounded Legado rule adapter. It compiles rules to data for a
/// fixed DOM program; neither imported rules nor downloaded scripts are executed.
enum LegadoRule {
    struct Step {
        let selector: String
        let index: Int?
        var arguments: [String: Any] {
            var value: [String: Any] = ["selector": selector]
            if let index { value["index"] = index }
            return value
        }
    }

    struct Parsed {
        let jsonPath: String?
        let steps: [Step]
        let attribute: String
        let replacement: Replacement?
        var isJSON: Bool { jsonPath != nil }
        var arguments: [String: Any] { ["steps": steps.map(\.arguments), "attribute": attribute] }
        func replace(_ text: String) throws -> String { try replacement?.apply(to: text) ?? text }
    }

    struct Replacement {
        let expression: NSRegularExpression
        let template: String

        func apply(to text: String) throws -> String {
            guard text.utf16.count <= 2_000_000 else { throw SourceError.unsupported("正则替换文本超过 200 万字符") }
            let started = Date.timeIntervalSinceReferenceDate
            var matches: [NSTextCheckingResult] = []
            var exceeded = false
            expression.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(text.startIndex..., in: text)) { match, _, stop in
                if matches.count >= 100_000 || Date.timeIntervalSinceReferenceDate - started > 1 {
                    exceeded = true
                    stop.pointee = true
                    return
                }
                if let match { matches.append(match) }
            }
            guard !exceeded else { throw SourceError.unsupported("正则替换过于复杂或匹配过多，已停止处理") }
            let input = text as NSString
            var result = ""
            var position = 0
            var outputLength = 0
            for match in matches {
                let unchanged = NSRange(location: position, length: match.range.location - position)
                let replacement = expression.replacementString(for: match, in: text, offset: 0, template: template)
                outputLength += unchanged.length + replacement.utf16.count
                guard outputLength <= 2_000_000 else { throw SourceError.unsupported("正则替换结果超过 200 万字符") }
                result += input.substring(with: unchanged)
                result += replacement
                position = NSMaxRange(match.range)
            }
            guard outputLength + input.length - position <= 2_000_000 else { throw SourceError.unsupported("正则替换结果超过 200 万字符") }
            result += input.substring(from: position)
            return result
        }
    }

    private static let attributes: Set<String> = ["text", "owntext", "textnodes", "html", "href", "src", "content", "value", "title", "alt", "name", "rel", "charset"]

    static func validate(_ rule: String) throws { _ = try parse(rule) }
    static func validateList(_ rule: String) throws { _ = try parse(rule, isList: true) }
    static func validateReplacement(_ rule: String) throws { _ = try replacementOnly(rule) }
    static func replace(_ text: String, using rule: String) throws -> String { try replacementOnly(rule).apply(to: text) }

    static func validatedHeaders(_ headers: [String: String]) throws -> [String: String] {
        let allowed: Set<String> = ["user-agent", "referer", "origin", "accept", "accept-language", "accept-encoding", "cache-control", "content-type", "x-requested-with"]
        var seen = Set<String>()
        for (key, value) in headers {
            guard allowed.contains(key.lowercased()), seen.insert(key.lowercased()).inserted else { throw SourceError.unsupported("请求头 \(key)") }
            guard value.utf8.count <= 8192, !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw SourceError.invalid("请求头 \(key) 含控制字符或过长。") }
            let lowered = value.lowercased()
            guard !["@js:", "<js", "{{", "}}"].contains(where: lowered.contains) else { throw SourceError.unsupported("动态请求头 \(key)") }
        }
        return headers
    }

    static func parse(_ raw: String, isList: Bool = false) throws -> Parsed {
        let rule = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rule.count <= 16_384 else { throw SourceError.unsupported("规则长度超过 16 KB") }
        try rejectDynamic(rule)
        let pieces = rule.components(separatedBy: "##")
        guard pieces.count <= 3 else { throw SourceError.unsupported("多段正则替换或仅取首个匹配语法") }
        var base = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = pieces.count > 1 ? try makeReplacement(pattern: pieces[1], template: pieces.count == 3 ? pieces[2] : "") : nil
        if isList, replacement != nil { throw SourceError.unsupported("列表规则中的正则替换") }
        if base.lowercased().hasPrefix("@json:") {
            base = String(base.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard base.hasPrefix("$") else { throw SourceError.unsupported("@json: 后必须是以 $ 开头的 JSONPath") }
        }
        if base.hasPrefix("$") {
            _ = try SimpleJSONPath.tokens(base)
            return Parsed(jsonPath: base, steps: [], attribute: "text", replacement: replacement)
        }
        if base.lowercased().hasPrefix("@css:") { base = String(base.dropFirst(5)) }
        guard !base.contains("&&"), !base.contains("||"), !base.hasPrefix("-"), !base.contains("@json:") else { throw SourceError.unsupported("组合、反向或混合规则") }
        var parts = try splitChain(base)
        var attribute = "text"
        if let last = parts.last, attributes.contains(last.lowercased()) || last.lowercased().hasPrefix("data-") {
            if isList { throw SourceError.unsupported("列表规则不能以文本或属性提取结尾") }
            attribute = parts.removeLast().lowercased()
        }
        if parts.count == 1, parts[0].isEmpty { parts = [] }
        if isList, parts.isEmpty { throw SourceError.invalid("列表选择器不能为空。") }
        let steps = try parts.map { try selector($0) }
        return Parsed(jsonPath: nil, steps: steps, attribute: attribute, replacement: replacement)
    }

    private static func rejectDynamic(_ rule: String) throws {
        let lowered = rule.lowercased()
        if ["@js:", "<js", "javascript:", "@xpath:", "@put:", "@get:", "{{", "}}"].contains(where: lowered.contains) || rule.hasPrefix("/") {
            throw SourceError.unsupported("JavaScript、XPath 或动态变量规则")
        }
    }

    private static func replacementOnly(_ rule: String) throws -> Replacement {
        try rejectDynamic(rule)
        let parts = rule.components(separatedBy: "##")
        guard parts.first == "", (2...3).contains(parts.count) else { throw SourceError.unsupported("正文替换请使用 ##正则 或 ##正则##替换文本") }
        return try makeReplacement(pattern: parts[1], template: parts.count == 3 ? parts[2] : "")
    }

    private static func makeReplacement(pattern: String, template: String) throws -> Replacement {
        guard !pattern.isEmpty, pattern.count <= 2048, template.count <= 8192 else { throw SourceError.unsupported("空正则或过长的正则替换") }
        guard template.range(of: #",\s*\{"#, options: .regularExpression) == nil else { throw SourceError.unsupported("正则替换生成的自定义请求选项") }
        do { return Replacement(expression: try NSRegularExpression(pattern: pattern), template: template) }
        catch { throw SourceError.unsupported("无效或不兼容的正则表达式") }
    }

    /// Split @ only outside quoted attribute selectors and functional CSS syntax.
    private static func splitChain(_ rule: String) throws -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var brackets = 0
        var parentheses = 0
        for character in rule {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { current.append(character); escaped = true; continue }
            if let active = quote {
                current.append(character)
                if character == active { quote = nil }
                continue
            }
            if character == "\"" || character == "'" { quote = character }
            else if character == "[" { brackets += 1 }
            else if character == "]" { brackets -= 1 }
            else if character == "(" { parentheses += 1 }
            else if character == ")" { parentheses -= 1 }
            guard brackets >= 0, parentheses >= 0 else { throw SourceError.unsupported("选择器括号不匹配") }
            if character == "@", brackets == 0, parentheses == 0 {
                parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else { current.append(character) }
        }
        guard quote == nil, brackets == 0, parentheses == 0, !escaped else { throw SourceError.unsupported("选择器引号或括号不匹配") }
        parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return parts
    }

    private static func selector(_ raw: String) throws -> Step {
        guard !raw.isEmpty else { throw SourceError.unsupported("空的 @ 选择器步骤") }
        let lowered = raw.lowercased()
        if ["text.", "children", "all"].contains(lowered) || lowered.hasPrefix("text.") || [":contains", ":matches", ":eq(", ":lt(", ":gt(", "!"].contains(where: lowered.contains) {
            throw SourceError.unsupported("Jsoup 特殊选择器或排除语法")
        }
        // Jsoup's ~= is regex matching, while WebKit uses whitespace-token
        // matching. Reject the ambiguous operator rather than changing its meaning.
        if raw.range(of: #"\[[^\]]*~="#, options: .regularExpression) != nil {
            throw SourceError.unsupported("属性正则选择器")
        }
        var value = raw
        var index: Int?
        if let range = value.range(of: #"(?:\.-?\d+|\[-?\d+\])$"#, options: .regularExpression) {
            let suffix = String(value[range])
            let number = suffix.hasPrefix(".") ? String(suffix.dropFirst()) : String(suffix.dropFirst().dropLast())
            guard let parsed = Int(number), (-20_000...20_000).contains(parsed) else { throw SourceError.unsupported("选择器索引超出范围") }
            index = parsed
            value.removeSubrange(range)
        }
        if value.range(of: #"\.\-?\d+(?:[:!]|$)"#, options: .regularExpression) != nil {
            throw SourceError.unsupported("选择器切片或多个索引")
        }
        if value.hasPrefix("class.") { value = "." + value.dropFirst(6) }
        else if value.hasPrefix("id.") { value = "#" + value.dropFirst(3) }
        else if value.hasPrefix("tag.") { value = String(value.dropFirst(4)) }
        guard !value.isEmpty, !value.contains("{"), !value.contains("}"), !value.contains(";") else { throw SourceError.unsupported("无效的 CSS 选择器") }
        return Step(selector: value, index: index)
    }

    static let extractionJavaScript = #"""
    function removeUnsafe(node) { node.querySelectorAll('script,style,noscript,iframe,object,embed').forEach(el => el.remove()); }
    function text(node) {
      const clone = node.cloneNode(true);
      if (clone.querySelectorAll) {
        clone.querySelectorAll('br').forEach(el => el.replaceWith('\n'));
        clone.querySelectorAll('p,div,li,h1,h2,h3,section').forEach(el => el.append('\n'));
      }
      return (clone.textContent || '').replace(/\u00a0/g,' ').replace(/[ \t]+\n/g,'\n').replace(/\n[ \t]+/g,'\n').replace(/\n{3,}/g,'\n\n').trim();
    }
    function select(start, steps) {
      let items = [start];
      for (const step of steps) {
        let selected = [];
        for (const item of items) {
          const nodes = step.selector === ':scope' ? [item] : Array.from(item.querySelectorAll(step.selector));
          if (step.index !== undefined) {
            const i = step.index < 0 ? nodes.length + step.index : step.index;
            if (i >= 0 && i < nodes.length) selected.push(nodes[i]);
          } else { selected.push(...nodes); }
        }
        items = Array.from(new Set(selected));
        if (items.length > 20000) throw new Error('匹配结果超过 20000 条');
      }
      return items;
    }
    function field(item, rule) {
      return select(item, rule.steps).map(node => {
        if (rule.attribute === 'html') {
          if (node.innerHTML !== undefined) return node.innerHTML;
          const fragment = document.createElement('template');
          fragment.content.append(node.cloneNode(true));
          return fragment.innerHTML;
        }
        if (rule.attribute === 'text') return text(node);
        if (rule.attribute === 'owntext' || rule.attribute === 'textnodes') {
          const strings = Array.from(node.childNodes).filter(n => n.nodeType === 3).map(n => n.textContent);
          return (rule.attribute === 'textnodes' ? strings.map(s => s.trim()).filter(Boolean).join('\n') : strings.join('')).trim();
        }
        return node.getAttribute ? (node.getAttribute(rule.attribute) || '') : '';
      }).filter(Boolean).join('\n').trim();
    }
    if (mode === 'plainHTMLRows') {
      return rows.map(row => {
        const result = {...row};
        for (const key of htmlFields) {
          const fragment = document.createElement('template');
          fragment.innerHTML = result[key] || '';
          removeUnsafe(fragment.content);
          result[key] = text(fragment.content);
        }
        return result;
      });
    }
    const template = document.createElement('template');
    template.innerHTML = html;
    const root = template.content;
    removeUnsafe(root);
    const nodes = list ? select(root, list.steps) : [root];
    return nodes.map(node => Object.fromEntries(Object.entries(fields).map(([key, rule]) => [key,field(node,rule)])));
    """#
}
