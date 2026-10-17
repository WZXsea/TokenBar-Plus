#!/usr/bin/env python3
"""Render verbatim notices for every registry package in Helper/Cargo.lock.

Requires Python 3.11+ and an existing `cargo vendor --locked` directory. This
intentionally includes target-specific and development packages too, providing a
conservative superset of the licenses used by the macOS helper. No network access
or license-text inference is performed. Missing sources/notices fail the run.

Example:
  python3.11 Scripts/generate_locked_licenses.py --vendor /path/to/cargo-vendor
"""
from __future__ import annotations

import argparse
import hashlib
import html
import json
from pathlib import Path
import re
import sys
import tomllib

ROOT = Path(__file__).resolve().parent.parent
NOTICE_NAME = re.compile(r"^(?:licen[cs]e|copying|notice|copyright|authors)(?:[._-]|$)", re.I)
PREFERENCE = ["MIT", "Apache-2.0", "ISC", "BSD-2-Clause", "BSD-3-Clause", "Unicode-3.0", "CDLA-Permissive-2.0", "Zlib", "BSL-1.0", "Unlicense"]


def choose_license(expression: str, accepted: set[str]) -> str:
    """Select a permissive branch of SPDX OR expressions; retain all AND terms."""
    tokens = re.findall(r"\(|\)|\bAND\b|\bOR\b|\bWITH\b|[A-Za-z0-9.+-]+", expression.replace("/", " OR "))
    index = 0

    def atom():
        nonlocal index
        if index >= len(tokens):
            raise ValueError(f"Incomplete license expression: {expression}")
        token = tokens[index]
        index += 1
        if token == "(":
            value = alternatives()
            if index >= len(tokens) or tokens[index] != ")":
                raise ValueError(f"Unclosed SPDX group: {expression}")
            index += 1
            return value
        if token in {"AND", "OR", "WITH", ")"}:
            raise ValueError(f"Invalid SPDX token: {expression}")
        if index < len(tokens) and tokens[index] == "WITH":
            index += 1
            if index >= len(tokens):
                raise ValueError(f"Missing SPDX exception: {expression}")
            token += " WITH " + tokens[index]
            index += 1
        return [token] if token in accepted else None

    def conjunction():
        nonlocal index
        value = atom()
        while index < len(tokens) and tokens[index] == "AND":
            index += 1
            right = atom()
            value = value + right if value is not None and right is not None else None
        return value

    def alternatives():
        nonlocal index
        values = [conjunction()]
        while index < len(tokens) and tokens[index] == "OR":
            index += 1
            values.append(conjunction())
        usable = [v for v in values if v is not None]
        return min(usable, key=lambda terms: (max(PREFERENCE.index(t) if t in PREFERENCE else 100 for t in terms), len(terms))) if usable else None

    result = alternatives()
    if index != len(tokens) or result is None:
        raise ValueError(f"No accepted complete license choice: {expression}")
    return " AND ".join(dict.fromkeys(result))


def generate(vendor: Path, lock_path: Path, config_path: Path) -> tuple[str, int]:
    lock_bytes = lock_path.read_bytes()
    packages = tomllib.loads(lock_bytes.decode())["package"]
    accepted = set(tomllib.loads(config_path.read_text())["accepted"])
    records = []
    for package in sorted(packages, key=lambda p: (p["name"], p["version"])):
        if "source" not in package:
            continue
        if not package["source"].startswith("registry+"):
            raise ValueError(f"Unresolved non-registry source: {package['name']}")
        source = vendor / f"{package['name']}-{package['version']}"
        manifest = tomllib.loads((source / "Cargo.toml").read_text())["package"]
        if (manifest["name"], manifest["version"]) != (package["name"], package["version"]):
            raise ValueError(f"Source identity mismatch: {source.name}")
        checksum = json.loads((source / ".cargo-checksum.json").read_text())
        if checksum["package"] != package["checksum"]:
            raise ValueError(f"Locked checksum mismatch: {source.name}")
        expression = manifest.get("license")
        if not expression:
            raise ValueError(f"Missing SPDX declaration: {source.name}")
        selected = choose_license(expression, accepted)
        # Recurse to retain bundled-code notices, including ring's fiat and
        # once_cell licenses. AUTHORS carries the full r-efi MIT grant.
        notice_paths = {p for p in source.rglob("*") if p.is_file() and NOTICE_NAME.match(p.name)}
        if declared := manifest.get("license-file"):
            p = source / declared
            if not p.is_file() or not p.resolve().is_relative_to(source.resolve()):
                raise ValueError(f"Missing/unsafe declared license file: {source.name}")
            notice_paths.add(p)
        if not notice_paths:
            raise ValueError(f"Missing verbatim license/notice files: {source.name}")
        notices = []
        for path in sorted(notice_paths, key=lambda p: p.relative_to(source).as_posix()):
            relative = path.relative_to(source).as_posix()
            data = path.read_bytes()
            if hashlib.sha256(data).hexdigest() != checksum["files"].get(relative):
                raise ValueError(f"Notice source checksum mismatch: {source.name}/{relative}")
            text = data.decode("utf-8")
            if not text.strip():
                raise ValueError(f"Empty notice file: {source.name}/{relative}")
            notices.append((relative, text))
        records.append((package, expression, selected, notices))
    esc = html.escape
    lines = ['<!doctype html>', '<html lang="en"><head><meta charset="utf-8">', '<meta name="viewport" content="width=device-width, initial-scale=1">', '<title>TokenBar third-party licenses</title>', '<style>body{font:15px/1.5 -apple-system,BlinkMacSystemFont,sans-serif;max-width:960px;margin:32px auto;padding:0 24px}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#8881;padding:16px}article{border-top:1px solid #8886;margin-top:28px}h3{overflow-wrap:anywhere}</style></head><body>', '<h1>TokenBar third-party licenses</h1>', f'<p>Generated from all {len(records)} registry packages locked in Helper/Cargo.lock, including target-specific and development dependencies. This catalog is a conservative superset for the macOS helper.</p>', f'<p>Lockfile SHA-256: <code>{hashlib.sha256(lock_bytes).hexdigest()}</code></p>', '<p>For alternative licenses, the selected permissive license is stated explicitly. All supplied license and notice files are reproduced verbatim, including notices for bundled code; reproducing alternative terms does not change that selection.</p>', '<p>Regenerate with Python 3.11+: <code>Scripts/generate_locked_licenses.py --vendor /path/to/cargo-vendor</code>. Sources are verified against the locked Cargo package checksums.</p>', '<h2>Packages</h2><ul>']
    for package, _, selected, _ in records:
        label = f"{package['name']} {package['version']}"
        lines.append(f'<li><a href="#{esc(label.replace(" ", "-"), quote=True)}">{esc(label)}</a> — {esc(selected)}</li>')
    lines.append('</ul><h2>Verbatim license and notice texts</h2>')
    for package, expression, selected, notices in records:
        label = f"{package['name']} {package['version']}"
        lines.extend([f'<article id="{esc(label.replace(" ", "-"), quote=True)}"><h3>{esc(label)}</h3>', f'<p>Declared license: <code>{esc(expression)}</code><br>Selected license: <code>{esc(selected)}</code></p>', f'<p>Source: <a href="https://crates.io/crates/{esc(package["name"], quote=True)}/{esc(package["version"], quote=True)}">crates.io</a></p>'])
        for relative, text in notices:
            # Escape whitespace as entities where Git treats it as trailing;
            # HTML decoding still reproduces every original character.
            rendered = re.sub(r' +(?=\r?$)', lambda match: '&#32;' * len(match[0]), esc(text), flags=re.M)
            rendered = rendered.replace('\r', '&#13;').replace('\t', '&#9;')
            lines.extend([f'<h4>{esc(relative)}</h4>', '<pre>' + rendered + '</pre>'])
        lines.append('</article>')
    lines.append('</body></html>')
    return '\n'.join(lines) + '\n', len(records)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vendor', type=Path, required=True, help='Existing cargo vendor directory for Helper/Cargo.lock')
    parser.add_argument('--output', type=Path, default=ROOT / 'Resources/ThirdPartyLicenses.html')
    args = parser.parse_args()
    try:
        document, count = generate(args.vendor, ROOT / 'Helper/Cargo.lock', ROOT / 'Helper/about.toml')
        args.output.write_text(document, encoding='utf-8')
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f'License catalog generation failed: {error}\n')
    print(f'Created {args.output.name}: {count} verified registry packages')


if __name__ == '__main__':
    main()
