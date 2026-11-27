#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 RenPlay Contributors
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verify AI help guide, embedded script parity, docs links, and privacy hygiene."""

from __future__ import annotations

import ast
from pathlib import Path
import re
import sys
import textwrap

ROOT = Path(__file__).resolve().parents[1]

GUIDE_REL = Path("Resources/Give-to-AI-with-logs.txt")
XTOOL_YML = ROOT / "xtool.yml"
AI_HELP_SWIFT = ROOT / "Sources/RenPlay/AIHelp.swift"
ENGINE_LAUNCHER_SWIFT = ROOT / "Sources/RenPlay/EngineLauncher.swift"

DOC_FILES = [
    Path("README.md"),
    Path("AGENTS.md"),
    Path("CLAUDE.md"),
    Path("BUILDING.md"),
    Path("THIRD-PARTY-NOTICES.md"),
    Path("llms.txt"),
    Path("docs/ARCHITECTURE.md"),
    Path("docs/INPUT_AND_OVERLAY.md"),
    Path("docs/STORAGE_SAVES_AND_SMB.md"),
]

TEXT_EXTENSIONS = {
    ".swift", ".m", ".mm", ".c", ".h", ".py", ".rpy",
    ".sh", ".yml", ".yaml", ".md", ".txt", ".toml", ".plist",
}

SKIP_DIRS = {
    ".git", ".build", ".xtool-tmp", "xtool", "BundleResources",
    "LICENSES", "dist", "repack",
}

# Build sensitive patterns via concatenation so this script holds no bare literals.
LEAK_PATTERNS = [
    ("local mount prefix", re.compile(r"/mn" + r"t/")),
    ("developer home path", re.compile(r"/ho" + r"me/sin" + r"gh")),
    ("personal username", re.compile(r"\bsin" + r"gh\b", re.IGNORECASE)),
    ("local disk label", re.compile(r"\bac" + r"er\b", re.IGNORECASE)),
    ("local token file", re.compile(r"pa" + r"t\.txt")),
    ("internal tool handle", re.compile(r"anti" + r"gravity", re.IGNORECASE)),
    ("internal thread prefix", re.compile(r"\b(cmsg|chan)_[A-Za-z0-9]+")),
    ("third-party app reference (s)", re.compile(r"\bsp" + r"ark\b", re.IGNORECASE)),
    ("third-party app reference (m)", re.compile(r"\bmad" + r"eira\b", re.IGNORECASE)),
    ("meta phrase", re.compile(r"\bhuman\s+de" + r"vs\b", re.IGNORECASE)),
]

failures = 0


def check(condition: bool, message: str) -> None:
    global failures
    print(("PASS: " if condition else "FAIL: ") + message)
    if not condition:
        failures += 1


def collect_code_corpus() -> str:
    parts: list[str] = []
    for folder in ("Sources", "scripts"):
        base = ROOT / folder
        if not base.exists():
            continue
        for path in base.rglob("*"):
            if not path.is_file():
                continue
            if "CSMB2/upstream" in path.as_posix():
                continue
            if path.suffix in {".swift", ".m", ".mm", ".c", ".h", ".py", ".rpy", ".sh"}:
                parts.append(path.read_text(encoding="utf-8", errors="replace"))
    return "\n".join(parts)


def check_ai_guide(code_corpus: str) -> None:
    guide_path = ROOT / GUIDE_REL
    check(guide_path.is_file(), f"{GUIDE_REL} exists")
    if not guide_path.is_file():
        return

    raw_bytes = guide_path.read_bytes()
    text = raw_bytes.decode("utf-8", errors="strict")
    check(len(raw_bytes) <= 32768, f"{GUIDE_REL} size {len(raw_bytes)} <= 32768 bytes")
    check(text.isascii(), f"{GUIDE_REL} is plain ASCII")

    long_lines = [idx + 1 for idx, line in enumerate(text.splitlines()) if len(line) > 76]
    check(not long_lines, f"{GUIDE_REL} lines <= 76 chars (violations: {long_lines[:5]})")

    xtool_text = XTOOL_YML.read_text(encoding="utf-8")
    check("Resources/Give-to-AI-with-logs.txt" in xtool_text, "xtool.yml lists Give-to-AI-with-logs.txt")

    ai_help_text = AI_HELP_SWIFT.read_text(encoding="utf-8")
    check('fileName = "Give-to-AI-with-logs.txt"' in ai_help_text, "AIHelp.swift references Give-to-AI-with-logs.txt")

    guide_vars = sorted(set(re.findall(r"\bRENPY_[A-Z0-9_]+\b", text)))
    missing_guide = [v for v in guide_vars if v not in code_corpus]
    check(bool(guide_vars) and not missing_guide, f"all {len(guide_vars)} RENPY_* vars in AI guide exist in code (missing: {missing_guide})")


def check_script_parity() -> None:
    launcher_text = ENGINE_LAUNCHER_SWIFT.read_text(encoding="utf-8")

    m_main = re.search(r'private static let engineMainScript = #"""\n(.*?)\n    """#', launcher_text, re.S)
    check(m_main is not None, "EngineLauncher.engineMainScript block present")
    if m_main:
        embedded_main = textwrap.dedent(m_main.group(1)).rstrip("\n")
        file_main = (ROOT / "scripts/engine_main.py").read_text(encoding="utf-8").rstrip("\n")
        check(embedded_main == file_main, "EngineLauncher.engineMainScript matches scripts/engine_main.py")
        ast.parse(file_main)

    m_ov = re.search(r'private static let runtimeOverridesScript = #"""\n(.*?)\n    """#', launcher_text, re.S)
    check(m_ov is not None, "EngineLauncher.runtimeOverridesScript block present")
    if m_ov:
        embedded_ov = textwrap.dedent(m_ov.group(1)).rstrip("\n")
        file_ov = (ROOT / "scripts/99renplay_overrides.rpy").read_text(encoding="utf-8").rstrip("\n")
        check(embedded_ov == file_ov, "EngineLauncher.runtimeOverridesScript matches scripts/99renplay_overrides.rpy")
        ov_py = file_ov.split("init 999 python:\n", 1)[1]
        ast.parse(textwrap.dedent(ov_py))


def check_docs_links_and_vars(code_corpus: str) -> None:
    link_re = re.compile(r"\[[^\]]+\]\(([^)#?\s]+)(?:#[^)]*)?\)")
    for rel in DOC_FILES:
        path = ROOT / rel
        check(path.is_file(), f"doc exists: {rel}")
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8")

        for match in link_re.finditer(text):
            target = match.group(1)
            if target.startswith(("http://", "https://", "mailto:", "file://")):
                continue
            resolved = (path.parent / target).resolve()
            check(resolved.exists(), f"{rel} link resolves: {target}")

        if rel.parts[0] == "docs":
            doc_vars = sorted(set(re.findall(r"\bRENPY_[A-Z0-9_]+\b", text)))
            missing = [v for v in doc_vars if v not in code_corpus]
            check(not missing, f"{rel} RENPY_* vars exist in code (missing: {missing})")


def check_privacy_and_hygiene() -> None:
    leaks: list[str] = []
    for path in ROOT.rglob("*"):
        if not path.is_file():
            continue
        rel_parts = set(path.relative_to(ROOT).parts)
        if rel_parts & SKIP_DIRS:
            continue
        if "CSMB2/upstream" in path.as_posix():
            continue
        if path.suffix not in TEXT_EXTENSIONS:
            continue
        content = path.read_text(encoding="utf-8", errors="replace")
        for label, pattern in LEAK_PATTERNS:
            if pattern.search(content):
                leaks.append(f"{path.relative_to(ROOT)} ({label})")
    check(not leaks, f"no private paths or disallowed terms in repo files (found: {leaks})")


def main() -> int:
    corpus = collect_code_corpus()
    check_ai_guide(corpus)
    check_script_parity()
    check_docs_links_and_vars(corpus)
    check_privacy_and_hygiene()
    print("PASS" if failures == 0 else f"FAIL ({failures})")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
