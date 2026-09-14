#!/usr/bin/env bash
# Build a small Apple Notes database for offline end-to-end testing.
#
# This writes the legacy (iOS 8) schema on purpose. The parser selects it when
# ZICNOTEDATA is absent (AppleNotesKit.c `_detect_version`), and that path needs
# only four plain tables whose note bodies are raw text -- no gzip, no protobuf,
# no generator to keep in step with the modern column-resolution probes.
#
# What it covers: the repository, the account/folder hierarchy, folder path
# building, filename allocation, every renderer, single-file assembly, the
# archive writers and the sync manifest. What it does not cover: attachments,
# galleries and protobuf->HTML, none of which exist in the legacy schema.
# Attachment behaviour is covered by the unit tests instead.
#
# Usage: make-fixture-notestore.sh <output.sqlite>
set -euo pipefail

OUT="${1:-}"
if [ -z "$OUT" ]; then
  echo "usage: $0 <output.sqlite>" >&2
  exit 2
fi

rm -f "$OUT"
mkdir -p "$(dirname "$OUT")"

# Core Data stores dates as seconds since 2001-01-01, not the Unix epoch.
# 2024-01-15T12:00:00Z and 2024-06-01T09:30:00Z:
CREATED=727012800
MODIFIED=728559000

sqlite3 "$OUT" <<SQL
PRAGMA journal_mode = DELETE;

CREATE TABLE ZACCOUNT (
    Z_PK                 INTEGER PRIMARY KEY,
    ZACCOUNTIDENTIFIER   TEXT,
    ZNAME                TEXT
);

CREATE TABLE ZSTORE (
    Z_PK      INTEGER PRIMARY KEY,
    ZNAME     TEXT,
    ZACCOUNT  INTEGER
);

CREATE TABLE ZNOTEBODY (
    Z_PK      INTEGER PRIMARY KEY,
    ZCONTENT  TEXT
);

CREATE TABLE ZNOTE (
    Z_PK               INTEGER PRIMARY KEY,
    ZCREATIONDATE      REAL,
    ZMODIFICATIONDATE  REAL,
    ZTITLE             TEXT,
    ZBODY              INTEGER,
    ZSTORE             INTEGER
);

INSERT INTO ZACCOUNT VALUES (1, 'fixture-account-1', 'Fixture');

INSERT INTO ZSTORE VALUES (1, 'Notes', 1);
INSERT INTO ZSTORE VALUES (2, 'Work',  1);

-- Deliberately awkward content: an ampersand and angle brackets that every
-- escaper has to handle, a quote, and a non-ASCII character.
INSERT INTO ZNOTEBODY VALUES (1, 'Plain body with an ampersand & a <tag> and "quotes".');
INSERT INTO ZNOTEBODY VALUES (2, 'Second note. Unicode: café — dash.');
INSERT INTO ZNOTEBODY VALUES (3, 'Third note in the Work folder.');

INSERT INTO ZNOTE VALUES (1, $CREATED, $MODIFIED, 'First Note',              1, 1);
INSERT INTO ZNOTE VALUES (2, $CREATED, $MODIFIED, 'Second Note & Friends',   2, 1);
INSERT INTO ZNOTE VALUES (3, $CREATED, $MODIFIED, 'Work Note',               3, 2);
SQL

echo "✓ fixture written to $OUT"
