#!/usr/bin/env python3
"""Static source-format inventory. Reads JSON/text only; never runs imported JS.

Usage: python3 scripts/analyze_source_collection.py [collection.json] [output-dir]
Counts describe lexical evidence, not successful execution or live-site reachability.
No request headers, credentials, keys, complete rules or script bodies are exported.
"""
from __future__ import annotations
import collections
import hashlib
import json
import pathlib
import re
import sys
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT = ROOT / "build/SourceImportInvestigation/collection.json"
RULE_SECTIONS = {"ruleSearch", "ruleBookInfo", "ruleToc", "ruleContent", "ruleExplore"}
DIRECT_JS = {"jsLib", "loginCheckJs", "coverDecodeJs", "loginUrl", "callBackJs", "webJs", "formatJs", "preUpdateJs", "imageDecode"}
NAMESPACES = ("java", "source", "book", "chapter", "cookie", "cache")


def walk_strings(value, path=""):
    if isinstance(value, str):
        yield path, value
    elif isinstance(value, dict):
        for key, child in value.items():
            yield from walk_strings(child, f"{path}.{key}" if path else key)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from walk_strings(child, f"{path}[{index}]")


def mask_js(text, mask_strings=True):
    """Offset-preserving lexical mask, including comments/string/regex literals.

    This is not a JS parser. Template literals are kept as a conservative raw-code
    view, and slash classification is heuristic. Raw and masked API counts are both
    retained, so consumers can inspect uncertain references in the input file.
    """
    chars = list(text)
    i, previous = 0, ""
    while i < len(text):
        start = i
        if text.startswith("//", i):
            end = text.find("\n", i + 2)
            i = len(text) if end < 0 else end
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = len(text) if end < 0 else end + 2
        elif text[i] in "\"'":
            quote = text[i]
            i += 1
            while i < len(text):
                if text[i] == "\\": i += 2; continue
                if text[i] == quote: i += 1; break
                i += 1
            if not mask_strings:
                previous = "literal"
                continue
        elif text[i] == "/" and previous in ("", "=", "(", "[", ":", ",", "!", "&", "|", "?", "return", "=>"):
            i += 1
            bracket = False
            while i < len(text) and text[i] != "\n":
                if text[i] == "\\": i += 2; continue
                if text[i] == "[": bracket = True
                if text[i] == "]": bracket = False
                if text[i] == "/" and not bracket: i += 1; break
                i += 1
            while i < len(text) and text[i].isalpha(): i += 1
            if not mask_strings: continue
        else:
            match = re.match(r"[A-Za-z_$][\w$]*|=>", text[i:])
            if match:
                previous = match.group()
                i += len(previous)
            else:
                if not text[i].isspace(): previous = text[i]
                i += 1
            continue
        for position in range(start, min(i, len(chars))):
            if chars[position] != "\n": chars[position] = " "
    return "".join(chars)


def js_segments(path, text):
    segments = []
    occupied = []
    for match in re.finditer(r"<js\b[^>]*>([\s\S]*?)(?:</js>|$)", text, re.I):
        segments.append(match.group(1)); occupied.append(match.span())
    for match in re.finditer(r"@js:", text, re.I):
        if not any(start <= match.start() < end for start, end in occupied):
            segments.append(text[match.end():]); break
    for match in re.finditer(r"\{\{([\s\S]*?)\}\}", text): segments.append(match.group(1))
    last = path.rsplit(".", 1)[-1]
    if last in DIRECT_JS and not segments and not re.match(r"^\s*https?://", text): segments.append(text)
    if path.endswith(".action") and not segments: segments.append(text)
    return segments


def outside_js(text):
    text = re.sub(r"<js\b[^>]*>[\s\S]*?(?:</js>|$)", "", text, flags=re.I)
    text = re.split(r"@js:", text, maxsplit=1, flags=re.I)[0]
    return re.sub(r"\{\{[\s\S]*?\}\}", "{{expression}}", text)


class Inventory:
    def __init__(self): self.values = {}
    def add(self, key, index, path, occurrences=1):
        item = self.values.setdefault(key, {"sources": set(), "fields": set(), "occurrences": 0})
        item["sources"].add(index); item["fields"].add((index, path)); item["occurrences"] += occurrences
    def export(self):
        return {key: {"source_count": len(v["sources"]), "field_count": len(v["fields"]), "occurrences": v["occurrences"],
                      "source_indices": sorted(v["sources"]), "examples": [{"source_index": i, "path": p} for i, p in sorted(v["fields"])[:8]]}
                for key, v in sorted(self.values.items())}


SYNTAX = {
    "javascript.at_js": r"@js:", "javascript.js_tag": r"<js\b", "variables.template": r"\{\{",
    "variables.put": r"@put:", "variables.get": r"@get:",
    "selector.css_prefix": r"@css:", "selector.json_prefix": r"@json:", "selector.xpath_prefix": r"@xpath:",
    "selector.legado_class": r"(?:^|[@&|%])\s*class\.", "selector.legado_tag": r"(?:^|[@&|%])\s*tag\.",
    "selector.legado_id": r"(?:^|[@&|%])\s*id\.", "selector.legado_text": r"(?:^|[@&|%])\s*text\.",
    "selector.children": r"(?:^|@)\s*children\b", "selector.positional_index": r"\.\d+(?=@|$|[!,:])|\[\d+\]",
    "selector.negative_index": r"\.-\d+|\[-\d+\]", "selector.slice": r"\[-?\d*:-?\d*[^\]]*\]|\.\d+:\d+",
    "selector.exclusion": r"!\d|\.-?\d+!", "selector.jsoup_contains": r":contains(?:Own)?\(",
    "selector.jsoup_matches": r":matches(?:Own)?\(", "selector.jsoup_position": r":(?:eq|lt|gt)\(",
    "selector.css_has": r":has\(", "selector.css_not": r":not\(", "selector.css_nth": r":nth-[a-z-]+\(",
    "selector.attribute_regex": r"\[[^\]]*~=", "selector.chain": r"@(?!css:|json:|xpath:|js:|put:|get:)[A-Za-z.#*:\[]",
    "selector.attribute_text": r"(?:^|@)text(?:##|$)", "selector.attribute_html": r"(?:^|@)html(?:##|$)",
    "selector.attribute_owntext": r"(?:^|@)ownText(?:##|$)", "selector.attribute_textnodes": r"(?:^|@)textNodes(?:##|$)",
    "selector.bare_attribute": r"^(?:text|html|ownText|textNodes|href|src|title|content)(?:##|$)",
    "combine.concatenate": r"&&", "combine.first_nonempty": r"\|\|", "combine.interleave": r"%%",
    "combine.reverse": r"^\s*-", "regex.replace": r"##", "regex.first_only": r"###",
    "regex.capture_replacement": r"##[^#]*##[^#]*\$\d", "regex.match_prefix": r"^\s*:",
    "jsonpath.root": r"\$[.\[]", "jsonpath.recursive": r"\$\.\.", "jsonpath.filter": r"\[\?\(",
    "jsonpath.wildcard": r"\[\*\]", "jsonpath.quoted_key": r"\[['\"][^\]]+['\"]\]",
    "jsonpath.union": r"\[(?:-?\d+\s*,\s*)+-?\d+\]", "jsonpath.slice": r"\[-?\d*:-?\d*[^\]]*\]",
    "jsonpath.function": r"\.(?:length|size|min|max|avg|sum|keys|first|last)\(\)",
    "xpath.absolute_or_descendant": r"^\s*(?://|/(?:html|body|div|p|a)(?:/|\[|$))",
    "xpath.axes": r"(?:ancestor|descendant|following|preceding|parent|self|child|attribute)(?:-sibling)?::",
    "xpath.text_or_attribute": r"/text\(\)|/@[a-zA-Z]",
}
JS_SYNTAX = {
    "eval": r"(?<![\w.])eval\s*\(", "function_constructor": r"new\s+Function\s*\(",
    "arrow_function": r"=>", "let_or_const": r"\b(?:let|const)\s+", "destructuring": r"\b(?:let|const|var)\s*\{",
    "template_literal": r"`", "optional_chaining": r"\?\.", "nullish": r"\?\?", "spread": r"\.\.\.",
    "async_or_await": r"\b(?:async|await)\b", "class_declaration": r"\bclass\s+[A-Za-z_$]", "with": r"\bwith\s*\(",
    "java_importer": r"\bJavaImporter\s*\(", "import_class_or_package": r"\b(?:importClass|importPackage)\s*\(",
    "java_type": r"\bJava\.type\s*\(", "try_catch": r"\bcatch\s*\(",
}


def main():
    source_path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT
    output_dir = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else source_path.parent
    data = source_path.read_bytes()
    all_sources = json.loads(data)
    if not isinstance(all_sources, list): all_sources = [all_sources]
    selected = [(i, value) for i, value in enumerate(all_sources) if isinstance(value, dict) and value.get("bookSourceType", 0) == 0]
    syntax, js_syntax, fields, api_raw, api_code, member_calls, static_classes, class_symbols = (Inventory() for _ in range(8))
    request_keys, request_shapes, header_keys, header_shapes, encodings, templates, login_controls = (Inventory() for _ in range(7))
    source_details, lengths = [], []
    api_pattern = re.compile(r"(?<![\w$.])(?:(?:this)\.)?(java|source|book|chapter|cookie|cache)\s*((?:\.\s*[A-Za-z_$][\w$]*|\[\s*['\"][A-Za-z_$][\w$]*['\"]\s*\])+)\s*(\()?")
    class_pattern = re.compile(r"(?<![\w$.])(?:Packages\.)?(?:(?:java\.(?:lang|io|security|util))|javax\.[A-Za-z_$][\w$]*|android\.[A-Za-z_$][\w$]*|org\.jsoup|io\.(?:legado|legato))(?:\s*\.\s*[A-Za-z_$][\w$]*)*")

    for index, source in selected:
        all_strings = list(walk_strings(source))
        for field in ("loginUi", "exploreUrl", "header"):
            if isinstance(source.get(field), str):
                try:
                    nested = json.loads(source[field])
                    all_strings += list(walk_strings(nested, field + ".embeddedJSON"))
                    if field == "loginUi" and isinstance(nested, list):
                        for control in nested:
                            if isinstance(control, dict): login_controls.add(str(control.get("type", "unspecified")), index, field)
                except (ValueError, TypeError): pass
        source_details.append({"source_index": index, "import_row": index + 1, "name": source.get("bookSourceName", ""),
                               "identifier_is_http": urllib.parse.urlsplit(source.get("bookSourceUrl", "")).scheme.lower() in ("http", "https"),
                               "compact_json_bytes": len(json.dumps(source, ensure_ascii=False, separators=(",", ":")).encode()),
                               "string_field_count": len(all_strings)})
        for key, value in source.items():
            if value is not None and value != "" and value != {} and value != []: fields.add(key, index, key)
        for path, text in all_strings:
            if not text: continue
            lengths.append({"source_index": index, "path": path, "characters": len(text), "utf8_bytes": len(text.encode()), "sha256": hashlib.sha256(text.encode()).hexdigest()})
            is_rule = path.split(".", 1)[0] in RULE_SECTIONS
            if is_rule:
                outside = outside_js(text)
                for name, pattern in SYNTAX.items():
                    target = text if name.startswith(("javascript.", "variables.")) else outside
                    matches = re.findall(pattern, target, re.I)
                    if matches: syntax.add(name, index, path, len(matches))
            if path in ("searchUrl", "exploreUrl"):
                if re.search(r",\s*\{", text): request_shapes.add("options_suffix", index, path)
                if re.search(r"<js\b|@js:", text, re.I): request_shapes.add("javascript", index, path)
                elif text.strip().startswith(("https://", "http://")): request_shapes.add("absolute_url", index, path)
                elif text.strip().startswith("/"): request_shapes.add("relative_url", index, path)
                else: request_shapes.add("other_expression_or_list", index, path)
                for match in re.finditer(r"[\"']?(method|body|charset|headers|header|webView|webJs|type|retry|serverID|browser|post|contentType)[\"']?\s*:", text, re.I):
                    request_keys.add(match.group(1), index, path)
                for method in re.findall(r"[\"']?method[\"']?\s*:\s*[\"']([A-Za-z]+)[\"']", text, re.I): request_shapes.add("method." + method.upper(), index, path)
            for expression in re.findall(r"\{\{([\s\S]*?)\}\}", text):
                expression = expression.strip()
                kind = expression if expression in {"key", "page", "baseUrl", "result", "searchKey", "searchPage"} else "JSONPath" if expression.startswith(("$.", "$[")) else "@get" if expression.startswith("@get:") else "JavaScript_or_other_expression"
                templates.add(kind, index, path)
            for match in re.finditer(r"(?i)(?<![\w-])(GB18030|GB2312|GBK|UTF[-_]?8|UTF[-_]?16(?:LE|BE)?|ISO[-_]?8859[-_]?1|ISO8859_1|ASCII)(?![\w-])", text): encodings.add(match.group(1).upper(), index, path)
            segments = js_segments(path, text)
            for segment in segments:
                code = mask_js(segment)
                for name, pattern in JS_SYNTAX.items():
                    matches = re.findall(pattern, code)
                    if matches: js_syntax.add(name, index, path, len(matches))
                for view, inventory in ((segment, api_raw), (code, api_code)):
                    for match in api_pattern.finditer(view):
                        namespace, suffix, call = match.groups()
                        parts = re.findall(r"[A-Za-z_$][\w$]*", suffix)
                        if namespace == "java" and parts[0] in {"lang", "io", "util", "security", "net", "nio", "math"}: continue
                        inventory.add(namespace + "." + ".".join(parts) + ("()" if call else ""), index, path)
                for match in re.finditer(r"\.\s*([A-Za-z_$][\w$]*)\s*\(", code): member_calls.add(match.group(1), index, path)
                for match in class_pattern.finditer(code): static_classes.add(re.sub(r"\s+", "", match.group()), index, path)
                if re.search(r"JavaImporter|Packages\.|java\.(?:lang|security|io)", code):
                    for match in re.finditer(r"(?<![\w$.])([A-Z][A-Za-z0-9_$]*)\s*(?:\(|\.\s*([A-Za-z_$][\w$]*)\s*\()", code):
                        name = match.group(1) + (("." + match.group(2)) if match.group(2) else "")
                        if match.group(1) not in {"String", "Number", "Boolean", "Array", "Object", "JSON", "Math", "Date", "RegExp", "Error", "Uint8Array", "Map", "Set"}: class_symbols.add(name, index, path)
        header = source.get("header")
        if not header: header_shapes.add("empty", index, "header")
        elif isinstance(header, dict):
            header_shapes.add("json_object", index, "header")
            for key in header: header_keys.add(key, index, "header")
        elif isinstance(header, str):
            if re.search(r"@js:|<js\b|\{\{", header, re.I): header_shapes.add("dynamic", index, "header")
            else:
                try:
                    parsed = json.loads(header)
                    header_shapes.add("json_object_string" if isinstance(parsed, dict) else "other_json_string", index, "header")
                    if isinstance(parsed, dict):
                        for key in parsed: header_keys.add(key, index, "header")
                except ValueError:
                    header_shapes.add("non_json_string", index, "header")
                    for key in re.findall(r"['\"]([A-Za-z][A-Za-z0-9-]*)['\"]\s*:", header): header_keys.add(key, index, "header")

    by_path = {}
    for entry in lengths:
        path = entry["path"]
        item = by_path.setdefault(path, {"fields": 0, "total_characters": 0, "max_characters": 0, "max_utf8_bytes": 0, "largest_source_index": entry["source_index"]})
        item["fields"] += 1; item["total_characters"] += entry["characters"]
        if entry["characters"] > item["max_characters"]: item["max_characters"] = entry["characters"]; item["largest_source_index"] = entry["source_index"]
        item["max_utf8_bytes"] = max(item["max_utf8_bytes"], entry["utf8_bytes"])
    report = {
        "schema_version": 1, "input": {"path": str(source_path.relative_to(ROOT)) if source_path.is_relative_to(ROOT) else str(source_path), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()},
        "methodology": ["Static JSON/text inspection only. No third-party JavaScript executed, no network requests.", "Source indices are zero-based indices in the original full collection; import_row is one-based.", "Capability counts overlap. API lexical counts mask comments/string/regex literals heuristically; raw counts are a superset for manual verification.", "Methods on local variables can share host namespace names. Member-call inventory is evidence for host-return-object shims, not proof of a host API.", "Dynamic property names, eval-generated code, downloaded JS libraries and runtime branches cannot be resolved statically.", "Sensitive values and complete script/rule bodies are omitted; references point to original source index and field path."],
        "population": {"all_sources": len(all_sources), "text_sources": len(selected), "excluded_sources": len(all_sources)-len(selected), "all_type_counts": dict(collections.Counter(str(x.get("bookSourceType", 0)) for x in all_sources if isinstance(x, dict)))},
        "top_level_nonempty_fields": fields.export(), "rule_syntax": syntax.export(), "javascript_syntax": js_syntax.export(),
        "namespace_api_lexical": api_code.export(), "namespace_api_raw": api_raw.export(), "member_calls_lexical": member_calls.export(),
        "static_java_android_class_references": static_classes.export(), "unqualified_class_symbols_in_java_import_context": class_symbols.export(),
        "request_shapes": request_shapes.export(), "request_option_keys": request_keys.export(), "header_shapes": header_shapes.export(), "header_names": header_keys.export(),
        "template_expressions": templates.export(), "encoding_mentions": encodings.export(), "login_ui_control_types": login_controls.export(),
        "boundaries": {"field_lengths": dict(sorted(by_path.items())), "largest_fields": sorted(lengths, key=lambda x:x["utf8_bytes"], reverse=True)[:30], "largest_sources": sorted(source_details, key=lambda x:x["compact_json_bytes"], reverse=True)[:15]},
        "sources": source_details,
    }
    output_dir.mkdir(parents=True, exist_ok=True)
    json_path = output_dir / "text-source-capabilities.json"
    json_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    lines = ["# 文字书源静态能力清单", "", f"输入 SHA-256：`{report['input']['sha256']}`。合集 {len(all_sources)} 项，文字源 {len(selected)} 项，排除其他类型 {len(all_sources)-len(selected)} 项。", "", "仅解析 JSON 和源码文本，未执行任何第三方 JavaScript、未联网。计数表示出现该语法的书源数量；同一书源可重复计入不同能力。API 的词法计数已尽力排除注释、字符串和正则字面量；动态生成代码及下载的 JS 无法静态确定。完整清单和原文件位置见同目录 JSON；未输出密钥、请求头值或完整脚本。", "", "## 语法与请求能力", "", "| 能力 | 书源数 | 字段数 |", "|---|---:|---:|"]
    for group in ["rule_syntax", "javascript_syntax", "request_shapes", "request_option_keys", "header_shapes", "encoding_mentions"]:
        for name, item in report[group].items(): lines.append(f"| {group}.{name} | {item['source_count']} | {item['field_count']} |")
    lines += ["", "## 脚本桥接 API", ""]
    for namespace in NAMESPACES:
        apis = [(key, value) for key,value in report["namespace_api_lexical"].items() if key.startswith(namespace + ".")]
        lines += [f"- **{namespace}**：" + "、".join(f"`{key[len(namespace)+1:]}`（{value['source_count']}）" for key,value in apis)]
    lines += ["", "## Java / Android 兼容层", ""]
    lines += ["- `" + key + "`：" + str(value["source_count"]) + " 源" for key,value in report["static_java_android_class_references"].items()]
    lines += ["", "## 分页、登录与边界", "", "分页字段与全部规则长度见 JSON 的 `boundaries.field_lengths`；登录、脚本库、请求调度等字段使用量见 `top_level_nonempty_fields`。"]
    for key in ["loginUrl", "loginUi", "loginCheckJs", "jsLib", "concurrentRate", "header", "enabledCookieJar", "enabledExplore"]:
        item = report["top_level_nonempty_fields"].get(key)
        if item: lines.append(f"- {key}：{item['source_count']} 源。")
    for item in report["boundaries"]["largest_fields"][:5]: lines.append(f"- 最大字段候选：源索引 {item['source_index']} / `{item['path']}`，{item['characters']:,} 字符、{item['utf8_bytes']:,} UTF-8 字节。")
    lines += ["", "静态支持语法不等于站点可用。登录、验证码、浏览器交互、第三方平台身份、字体解码、图片像素处理及 Java 返回对象行为都需要单独定义运行时边界。"]
    (output_dir / "text-source-capabilities.md").write_text("\n".join(lines) + "\n")
    print(json.dumps({"text_sources": len(selected), "namespace_api_entries": len(report["namespace_api_lexical"]), "static_class_entries": len(report["static_java_android_class_references"]), "report": str(json_path)}, ensure_ascii=False))


if __name__ == "__main__": main()
