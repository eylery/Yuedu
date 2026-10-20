#!/usr/bin/env python3
"""Offline syntax smoke test for static text-source rules in macOS WebKit.

This never fetches source sites or evaluates source JavaScript. Only Yuedu's
bundled rules.js is evaluated, against synthetic HTML / JSON. No source rule,
header, name, URL, script, or request credential is included in the report.
"""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
SECTIONS = ("ruleSearch", "ruleBookInfo", "ruleToc", "ruleContent")
FIELDS = {
    "bookList", "name", "author", "bookUrl", "coverUrl", "intro", "kind",
    "lastChapter", "wordCount", "tocUrl", "chapterList", "chapterName",
    "chapterUrl", "nextTocUrl", "content", "nextContentUrl", "updateTime",
}
SCRIPT = re.compile(r"@(?:web)?js\s*:|<(?:web)?js\b", re.I)
VARIABLE = re.compile(r"@(?:put|get)\s*:", re.I)
TEMPLATE = re.compile(r"\{\{|\{\$")
MAX_BYTES = 50_000_000


def json_context(rule: str, section_rules: dict) -> bool:
    """Choose a synthetic context; this is not website or type validation."""
    text = rule.lstrip("+-").strip()
    if re.match(r"^(?:@json:|\$[.\[])", text, re.I):
        return True
    if re.match(r"^(?:@css:|@@|@xpath:|/)", text, re.I):
        return False
    # The corpus has both bare JSON paths and .[?(...)] array filters.
    if "[?(" in text and "@text" not in text and "@href" not in text:
        return True
    parent = section_rules.get("bookList") or section_rules.get("chapterList") or ""
    if not isinstance(parent, str) or SCRIPT.search(parent):
        return False
    parent = parent.lstrip("+-").strip()
    return bool(re.match(r"^(?:@json:|\$[.\[]|(?:data|books|items|rows|result|list)(?:[.\[]|$))", parent, re.I))


def collect(collection: list) -> tuple[list, dict]:
    fixtures = []
    counts = Counter()
    for index, source in enumerate(collection):
        if not isinstance(source, dict):
            counts["nonObjectEntries"] += 1
            continue
        if source.get("bookSourceType", 0) not in (0, "0"):
            counts["otherTypeSources"] += 1
            continue
        counts["textSources"] += 1
        for section in SECTIONS:
            rules = source.get(section)
            if not isinstance(rules, dict):
                continue
            for field, rule in rules.items():
                if field not in FIELDS or not isinstance(rule, str) or not rule.strip():
                    continue
                counts["candidateFields"] += 1
                if SCRIPT.search(rule):
                    counts["excludedScriptFields"] += 1
                    continue
                if VARIABLE.search(rule):
                    counts["excludedVariableFields"] += 1
                    continue
                if TEMPLATE.search(rule):
                    counts["excludedTemplateFields"] += 1
                    if "{$" in rule and "{{" not in rule:
                        counts["excludedLegacyJSONTemplates"] += 1
                    continue
                mode = "elements" if field in ("bookList", "chapterList") else "string"
                # List order prefixes belong to the host, not the rule parser.
                if mode == "elements":
                    rule = re.sub(r"^-?\+?", "", rule.strip(), count=1)
                context = "json" if json_context(rule, rules) else "html"
                counts[context + "Fixtures"] += 1
                fixtures.append({
                    "sourceIndex": index,
                    "section": section,
                    "field": field,
                    "rule": rule,
                    "mode": mode,
                    "context": context,
                })
    counts["selectedFields"] = len(fixtures)
    return fixtures, dict(counts)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("collection", type=Path, help="Local Legado JSON collection; never downloaded by this script.")
    parser.add_argument("--report", type=Path, help="Optionally save the sanitized JSON report.")
    parser.add_argument("--timeout", type=int, default=180, help="Whole local runner timeout in seconds (default: 180).")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("This checker requires macOS, system WebKit, and Xcode command-line tools.")
    if not 1 <= args.timeout <= 600:
        parser.error("--timeout must be between 1 and 600 seconds.")
    try:
        if args.collection.stat().st_size > MAX_BYTES:
            raise ValueError("Collection exceeds the 50 MB input limit.")
        data = args.collection.read_bytes()
        collection = json.loads(data)
        if isinstance(collection, dict):
            collection = [collection]
        if not isinstance(collection, list):
            raise ValueError("Collection must be a JSON object or array.")
        fixtures, counts = collect(collection)
        rules_path = ROOT / "Yuedu/Resources/Legado/rules.js"
        runner = ROOT / "scripts/smoke_legado_rules.swift"
        with tempfile.TemporaryDirectory(prefix="yuedu-rule-smoke-") as directory:
            temporary = Path(directory)
            fixture_path = temporary / "fixtures.json"
            fixture_path.write_text(json.dumps(fixtures, ensure_ascii=False), encoding="utf-8")
            fixture_path.chmod(0o600)
            process = subprocess.run(
                ["/usr/bin/xcrun", "swift", "-module-cache-path", str(temporary / "module-cache"),
                 str(runner), str(rules_path), str(fixture_path)],
                capture_output=True, text=True, timeout=args.timeout, check=False,
            )
        if process.returncode:
            # Compiler / WebKit stderr is deliberately not copied into reports.
            raise RuntimeError(f"Local WebKit runner did not complete (exit {process.returncode}). Run from a macOS terminal with Xcode command-line tools installed.")
        result = json.loads(process.stdout)
        if result.get("runnerError"):
            raise RuntimeError("Local WebKit initialization or fixture execution failed.")
        report = {
            "check": "static-rule-syntax-smoke",
            "generatedAtUTC": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "collectionBytes": len(data),
            "collectionSHA256": hashlib.sha256(data).hexdigest(),
            "rulesSHA256": hashlib.sha256(rules_path.read_bytes()).hexdigest(),
            "sourceEntries": len(collection),
            "counts": counts,
            "result": result,
            "limitations": [
                "Only synthetic HTML/JSON is used. Passing does not prove that rules match real websites or yield correct books/chapters.",
                "Source JavaScript, variables, and both {{...}} and {$...} templates are excluded. No site requests are made.",
                "Missing-node results may be empty; input-type inference is heuristic. This is a syntax smoke test, not full Legado conformance.",
                "Reports contain only counts, hashes, field paths, and fixed error categories; never raw rules, headers, scripts, URLs, or credentials.",
            ],
        }
        output = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(output, encoding="utf-8")
        sys.stdout.write(output)
        return 0 if result.get("errorCount") == 0 else 1
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        # JSON decoder exceptions can contain raw input; use a fixed diagnostic.
        if isinstance(error, json.JSONDecodeError):
            message = "Invalid JSON input or runner output. Raw data has not been printed."
        elif isinstance(error, subprocess.TimeoutExpired):
            message = "Local WebKit smoke test exceeded the time limit."
        else:
            message = str(error)
        print(json.dumps({"error": message}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
