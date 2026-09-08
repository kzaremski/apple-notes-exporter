#!/usr/bin/env bash
# Offline checks for the paths we can exercise without NoteStore / Full Disk Access:
# CLI help, --folder copy, sync-status history, missing-db export.
set -euo pipefail

CLI="${1:-}"
if [ -z "$CLI" ] || [ ! -x "$CLI" ]; then
  echo "usage: $0 /path/to/notes-export" >&2
  exit 2
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1" >&2; exit 1; }

echo "🧪 Offline CLI checks"
echo "   CLI: $CLI"

"$CLI" --help >/dev/null 2>&1 || fail "notes-export --help"
"$CLI" --help | grep -q "list-notes" || fail "root help lists list-notes"
pass "root help"

"$CLI" export --help 2>&1 | grep -q "folder id" || fail "export --help mentions folder id"
"$CLI" export --help 2>&1 | grep -q "subfolders" || fail "export --help mentions subfolders"
"$CLI" export --help 2>&1 | grep -q "include-deleted" || fail "export --help mentions include-deleted"
"$CLI" export --help 2>&1 | grep -q "shared-attachments" || fail "export --help mentions shared-attachments"
"$CLI" export --help 2>&1 | grep -q "html-indexes" || fail "export --help mentions html-indexes"
pass "export --folder help"

"$CLI" list-notes --help 2>&1 | grep -q "folder id" || fail "list-notes --help mentions folder id"
"$CLI" list-notes --help 2>&1 | grep -q "include-deleted" || fail "list-notes --help mentions include-deleted"
pass "list-notes --folder help"

"$CLI" sync-status --help 2>&1 | grep -q "history" || fail "sync-status --help mentions history"
pass "sync-status help"

mkdir -p "$TMP/empty"
empty_json=$("$CLI" sync-status -o "$TMP/empty")
python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d.get("manifestFound") is False, d
' <<< "$empty_json" || fail "sync-status without manifest"
pass "sync-status missing manifest"

mkdir -p "$TMP/with-history"
cat > "$TMP/with-history/AppleNotesExportSyncWatermark.json" << 'EOF'
{
  "version" : 1,
  "lastSync" : 1700000000,
  "notes" : {
    "1" : {
      "attachmentPaths" : [],
      "exportedPath" : "iCloud/Notes/Keep.md",
      "modificationDate" : 1700000000
    }
  },
  "history" : [
    {
      "timestamp" : 1700000100,
      "added" : [
        { "noteId" : "1", "path" : "iCloud/Notes/Keep.md" },
        { "noteId" : "2", "path" : "iCloud/Notes/Gone.md" }
      ],
      "updated" : [],
      "deleted" : []
    },
    {
      "timestamp" : 1700000200,
      "added" : [],
      "updated" : [
        { "noteId" : "1", "path" : "iCloud/Notes/Keep.md" }
      ],
      "deleted" : [
        { "noteId" : "2", "path" : "iCloud/Notes/Gone.md" }
      ]
    }
  ]
}
EOF

hist_json=$("$CLI" sync-status -o "$TMP/with-history")
python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d.get("manifestFound") is True, d
assert d.get("trackedNotes") == 1, d
assert d.get("historyRuns") == 2, d
hist = d.get("history") or []
assert len(hist) == 2, hist
last = hist[-1]
assert last.get("deletedCount") == 1, last
assert last["deleted"][0]["path"] == "iCloud/Notes/Gone.md", last
assert last["updated"][0]["path"] == "iCloud/Notes/Keep.md", last
' <<< "$hist_json" || fail "sync-status history diff"
pass "sync-status file/folder history"

mkdir -p "$TMP/export-out"
set +e
"$CLI" export --output "$TMP/export-out" --format txt \
  --db "$TMP/missing/NoteStore.sqlite" >"$TMP/export-out/stdout.txt" 2>"$TMP/export-out/stderr.txt"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  fail "export against missing NoteStore should fail (rc=$rc)"
fi
if ! grep -q "databaseUnavailable" "$TMP/export-out/stderr.txt"; then
  fail "missing-db export should report databaseUnavailable"
fi
pass "export --db absolute missing path (rc=$rc)"

set +e
"$CLI" export --output "$TMP/export-out" --format txt \
  --db "~/definitely-not-notestore/NoteStore.sqlite" >"$TMP/tilde-stdout.txt" 2>"$TMP/tilde-stderr.txt"
trc=$?
set -e
if [ "$trc" -eq 0 ]; then
  fail "export --db with tilde should fail"
fi
if grep -q "definitely-not-notestore" "$TMP/tilde-stderr.txt" && grep -q "~/" "$TMP/tilde-stderr.txt"; then
  fail "error still contains an unexpanded tilde"
fi
pass "export --db expands tilde before open"

echo "✅ Offline CLI checks passed"
