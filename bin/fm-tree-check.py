#!/usr/bin/env python3
"""Report broken static references in Firstmate's instruction and script tree.

Usage: bin/fm-tree-check.py [--root REPO]

Scans AGENTS.md, .agents/skills/*/SKILL.md, and UTF-8 files under bin/.
Checks literal bin/ script paths, docs/ file paths, local Markdown links,
explicit skill paths and named skill load/invoke references.
Requires nonempty description front matter in each SKILL.md.
Paths containing shell variables, placeholders or globs are not static and
are skipped. URLs and link fragments are not fetched or anchor-validated.
Named external/plugin skills cannot be resolved without an installed catalog;
names with a colon are skipped. This is a heuristic reference check, not a
Markdown, YAML or shell parser. It never executes scanned code or writes files.
Exit 0: clean; 1: findings; 2: invalid invocation or unreadable input.
"""

import argparse
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit


NAME = r"/?[a-z][a-z0-9-]*"
SKILL_PATTERNS = [
    re.compile(r"\b(?:load|invoke)\s+(?:the\s+)?`(" + NAME + r")`", re.I),
    re.compile(r"\b(?:load|invoke|apply|use|read|follow)\s+(?:the\s+)?(" + NAME + r")\s+skill\b", re.I),
    re.compile(r"`(" + NAME + r")`\s+skill\b", re.I),
    re.compile(r"^\s*-\s+`(" + NAME + r")`\s+-\s+load\b", re.I),
]
PATH = re.compile(
    r"(?<![\w/.])(?P<path>(?:\.{1,2}/)*(?:bin|docs|\.agents/skills|skills)/"
    r"[^\s`\"'()\[\]{},;:|]+)"
)
LINK = re.compile(r"!?\[[^\]]*\]\(\s*(<[^>]+>|[^\s)]+)(?:\s+[^)]*)?\)")
REFERENCE = re.compile(r"^\s*\[[^\]]+\]:\s*(<[^>]+>|\S+)")
DYNAMIC = re.compile(r"[$*?<>\[\]\{\}\\]|%[a-zA-Z](?![0-9a-fA-F])")


def static_path(raw):
    return not DYNAMIC.search(raw) and not raw.endswith(("/", "..."))


def description_present(text):
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return False
    try:
        end = next(i for i in range(1, len(lines)) if lines[i].strip() == "---")
    except StopIteration:
        return False
    for i in range(1, end):
        match = re.match(r"^description:\s*(.*)", lines[i])
        if not match:
            continue
        value = match[1].split(" #", 1)[0].strip()
        if value in ("|", ">", "|-", ">-", "|+", ">+"):
            block = []
            for line in lines[i + 1:end]:
                if line and not line[0].isspace():
                    break
                if line.strip() and not line.lstrip().startswith("#"):
                    block.append(line.strip())
            return bool(block)
        if value.startswith(("'", '\"')) and value[-1:] == value[:1]:
            return bool(value[1:-1].strip())
        return value.lower() not in ("", "null", "~") and not value.startswith("#")
    return False


def check(root):
    findings = set()
    skills = sorted((root / ".agents/skills").glob("*/SKILL.md"))
    sources = [root / "AGENTS.md", *skills]
    if not (root / "bin").is_dir():
        raise OSError("missing bin/ directory")
    sources += sorted(p for p in (root / "bin").rglob("*") if p.is_file() and "__pycache__" not in p.parts)

    def add(source, line, kind, target):
        findings.add((source.relative_to(root).as_posix(), line, kind, target))

    for source in sources:
        try:
            text = source.read_text(encoding="utf-8")
        except UnicodeError:
            if source in skills or source.name == "AGENTS.md":
                raise
            continue
        if source.name == "SKILL.md" and not description_present(text):
            add(source, 1, "missing-description", "nonempty description: front matter required")
        for number, line in enumerate(text.splitlines(), 1):
            # Markdown links are relative to their source, unlike plain repo paths.
            spans = []
            for match in [*LINK.finditer(line), *REFERENCE.finditer(line)]:
                raw = match[1].strip("<>")
                spans.append(match.span(1))
                parts = urlsplit(raw)
                if parts.scheme or parts.netloc or not parts.path:
                    continue
                path = unquote(parts.path)
                if not static_path(path):
                    continue
                target = root / path.lstrip("/") if path.startswith("/") else source.parent / path
                if not target.exists():
                    add(source, number, "missing-link", raw)

            for match in PATH.finditer(line):
                if any(start <= match.start() < end for start, end in spans):
                    continue
                raw = match["path"].rstrip(".#")
                raw = raw.split("#", 1)[0]
                # Reject partial matches embedded in absolute paths and templates.
                before = line[:match.start()]
                after = line[match.end():]
                if before.endswith(("$", "{", "<")) or after.startswith(("$", "{", "<", "*")):
                    continue
                if not static_path(raw):
                    continue
                canonical = raw
                while canonical.startswith(("../", "./")):
                    canonical = canonical.split("/", 1)[1]
                if canonical.startswith("bin/") and not re.search(r"\.(?:sh|py|js|mjs|ts|pl|jq)$", raw):
                    continue
                if canonical.startswith("docs/") and not Path(raw).suffix:
                    continue
                target = source.parent / raw if raw.startswith(".") and not raw.startswith(".agents/") else root / raw
                if not target.exists():
                    add(source, number, "missing-path", raw)

            # Named skills are instruction prose, not arbitrary script identifiers.
            if source.name in ("AGENTS.md", "SKILL.md"):
                for pattern in SKILL_PATTERNS:
                    for match in pattern.finditer(line):
                        name = match[1].lstrip("/")
                        if name.lower() in ("this", "that", "the", "a", "each", "every", "same"):
                            continue
                        if not (root / ".agents/skills" / name / "SKILL.md").is_file() and not (root / "skills" / name / "SKILL.md").is_file():
                            add(source, number, "missing-skill", name)
    return sorted(findings)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    try:
        findings = check(args.root.resolve())
    except (OSError, UnicodeError, ValueError) as error:
        print(f"tree-check: {error}", file=sys.stderr)
        return 2
    for source, line, kind, target in findings:
        print(f"{source}:{line}: {kind}: {target}")
    print(f"tree-check: {len(findings)} finding(s)")
    return int(bool(findings))


if __name__ == "__main__":
    sys.exit(main())
