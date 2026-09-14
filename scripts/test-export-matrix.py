#!/usr/bin/env python3
"""Export every format into every destination and check what comes out.

The previous harness ran 18 formats into one destination and asserted only that
the exit code was 0 and the CLI reported no failures. That would have passed a
concatenated ENEX made of several XML documents glued together, which is exactly
what shipped. So this one opens the files.

Runs against the fixture database from make-fixture-notestore.sh, so it needs no
Notes library and no Full Disk Access, and can run in CI.

Usage: test-export-matrix.py <notes-export binary> <fixture.sqlite>
"""

import csv
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import xml.etree.ElementTree as ET
import zipfile

# Formats the CLI advertises, and whether each can be joined into one file.
TEXT_FORMATS = ["html", "markdown", "rtf", "txt", "tex", "json", "jsonl",
                "xml", "csv", "opml", "org", "rst", "adoc", "enex"]
PACKAGED_FORMATS = ["pdf", "docx", "odt", "epub"]
ALL_FORMATS = TEXT_FORMATS + PACKAGED_FORMATS

EXTENSION = {"markdown": "md"}          # advertised token -> file extension

ARCHIVE_MEMBER = {
    "docx": "word/document.xml",
    "odt": "content.xml",
    "epub": "META-INF/container.xml",
}


class Failure(Exception):
    pass


def ext_for(fmt):
    return EXTENSION.get(fmt, fmt)


# ── per-format validation ────────────────────────────────────────────────────

def validate_xml_family(path, data, concatenated):
    """XML, OPML and ENEX must parse, with exactly one root element."""
    try:
        ET.parse(io.BytesIO(data))
    except ET.ParseError as e:
        raise Failure(f"not well-formed XML: {e}")
    # A second declaration means several documents were concatenated.
    if data.count(b"<?xml") > 1 and b"<en-note" not in data:
        raise Failure("more than one XML declaration in a single document")


def validate_json(path, data, concatenated):
    try:
        parsed = json.loads(data)
    except json.JSONDecodeError as e:
        raise Failure(f"not valid JSON: {e}")
    if concatenated and not isinstance(parsed, list):
        raise Failure("concatenated JSON must be an array")


def validate_jsonl(path, data, concatenated):
    for i, line in enumerate(data.decode("utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            json.loads(line)
        except json.JSONDecodeError as e:
            raise Failure(f"line {i} is not valid JSON: {e}")


def validate_csv(path, data, concatenated):
    rows = list(csv.reader(io.StringIO(data.decode("utf-8"))))
    rows = [r for r in rows if r]
    if not rows:
        raise Failure("no rows")
    widths = {len(r) for r in rows}
    if len(widths) != 1:
        raise Failure(f"ragged rows: column counts {sorted(widths)}")
    header = rows[0]
    if sum(1 for r in rows if r == header) != 1:
        raise Failure("header row appears more than once")


def validate_text_is_not_html(path, data, concatenated):
    """Only for plain text: an HTML tag here means conversion did not run."""
    text = data.decode("utf-8", errors="replace")
    for marker in ("<html", "<body", "<img", "<!DOCTYPE"):
        if marker in text:
            raise Failure(f"plain text contains {marker!r}")
    if "base64," in text:
        raise Failure("plain text contains a base64 payload")


def validate_pdf(path, data, concatenated):
    if not data.startswith(b"%PDF-"):
        raise Failure("missing %PDF- header")
    if b"%%EOF" not in data:
        raise Failure("missing %%EOF trailer")


def validate_package(fmt):
    def check(path, data, concatenated):
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as z:
                if z.testzip() is not None:
                    raise Failure("corrupt archive member")
                names = z.namelist()
        except zipfile.BadZipFile as e:
            raise Failure(f"not a valid package: {e}")
        member = ARCHIVE_MEMBER[fmt]
        if member not in names:
            raise Failure(f"missing required member {member}")
    return check


VALIDATORS = {
    "xml": validate_xml_family,
    "opml": validate_xml_family,
    "enex": validate_xml_family,
    "json": validate_json,
    "jsonl": validate_jsonl,
    "csv": validate_csv,
    "txt": validate_text_is_not_html,
    "pdf": validate_pdf,
    "docx": validate_package("docx"),
    "odt": validate_package("odt"),
    "epub": validate_package("epub"),
}


def validate_file(fmt, path, concatenated):
    with open(path, "rb") as fh:
        data = fh.read()
    if not data:
        raise Failure("file is empty")
    validator = VALIDATORS.get(fmt)
    if validator:
        validator(path, data, concatenated)


# ── running one cell of the matrix ───────────────────────────────────────────

def run_export(cli, db, out, fmt, extra):
    cmd = [cli, "export", "--db", db, "--output", out, "--format", fmt] + extra
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise Failure(f"exit {proc.returncode}: {proc.stderr.strip()[:300]}")
    try:
        result = json.loads(proc.stdout)
    except json.JSONDecodeError:
        raise Failure(f"result was not JSON: {proc.stdout[:200]}")
    if result.get("failed"):
        raise Failure(f"{result['failed']} note(s) failed")
    if not result.get("exported"):
        raise Failure("nothing was exported")
    return result


def unpack(archive, into):
    if archive.endswith(".zip"):
        with zipfile.ZipFile(archive) as z:
            if not z.namelist():
                raise Failure("archive is empty")
            z.extractall(into)
    else:
        with tarfile.open(archive) as t:
            if not t.getnames():
                raise Failure("archive is empty")
            t.extractall(into)


def check_cell(cli, db, workdir, fmt, destination):
    """Export one format into one destination and validate every file written."""
    out = os.path.join(workdir, f"{fmt}-{destination}")
    os.makedirs(out, exist_ok=True)
    concatenated = destination == "single"

    extra = {"folder": [], "zip": ["--zip"], "tar": ["--tar"],
             "single": ["--concatenate"]}[destination]
    run_export(cli, db, out, fmt, extra)

    if destination in ("zip", "tar"):
        archives = [f for f in os.listdir(out) if f.endswith((".zip", ".tar"))]
        if len(archives) != 1:
            raise Failure(f"expected one archive, found {archives}")
        loose = [f for f in os.listdir(out) if not f.endswith((".zip", ".tar"))]
        if loose:
            raise Failure(f"staging left behind: {loose}")
        unpacked = os.path.join(workdir, f"{fmt}-{destination}-unpacked")
        unpack(os.path.join(out, archives[0]), unpacked)
        root = unpacked
    else:
        root = out

    written = []
    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            if name.startswith("."):
                continue
            written.append(os.path.join(dirpath, name))
    if not written:
        raise Failure("no files were written")

    if concatenated:
        expected = f".{ext_for(fmt)}"
        joined = [p for p in written if p.endswith(expected)]
        if len(joined) != 1:
            raise Failure(f"expected one {expected} file, found {len(joined)}")
        if os.path.isdir(joined[0]):
            raise Failure("the single file is a directory")

    for path in written:
        if not path.endswith(f".{ext_for(fmt)}"):
            continue                                  # attachments etc.
        try:
            validate_file(fmt, path, concatenated)
        except Failure as e:
            raise Failure(f"{os.path.relpath(path, root)}: {e}")


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    cli, db = sys.argv[1], sys.argv[2]
    if not os.access(cli, os.X_OK):
        print(f"CLI not executable: {cli}", file=sys.stderr)
        return 2

    workdir = tempfile.mkdtemp(prefix="ane-matrix-")
    passed = failed = 0
    failures = []

    print("📤 Export matrix: format × destination")
    print(f"   CLI:     {cli}")
    print(f"   Fixture: {db}\n")
    print(f"{'FORMAT':<10} {'FOLDER':<9} {'ZIP':<9} {'TAR':<9} {'SINGLE':<9}")
    print("-" * 52)

    try:
        for fmt in ALL_FORMATS:
            cells = []
            for destination in ("folder", "zip", "tar", "single"):
                if destination == "single" and fmt in PACKAGED_FORMATS:
                    cells.append("n/a")           # cannot be joined, by design
                    continue
                try:
                    check_cell(cli, db, workdir, fmt, destination)
                    cells.append("ok")
                    passed += 1
                except Failure as e:
                    cells.append("FAIL")
                    failures.append(f"{fmt}/{destination}: {e}")
                    failed += 1
            print(f"{fmt:<10} " + " ".join(f"{c:<9}" for c in cells))
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    print("-" * 52)
    print(f"{passed} passed, {failed} failed")
    if failures:
        print("\nFailures:")
        for f in failures:
            print(f"  ✗ {f}")
        return 1
    print("✅ Export matrix passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
