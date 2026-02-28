/*
 *  AppleNotesKit.c
 *  AppleNotesKit -- Core database parser
 *
 *  Copyright (C) 2026 Konstantin Zaremski
 *
 *  This program is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation, either version 3 of the License, or
 *  (at your option) any later version.
 */

#include "AppleNotesKit.h"

#include <sqlite3.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/stat.h>
#include <dirent.h>
#include <time.h>

/* ── Prepared statement IDs ─────────────────────────────────── */

enum {
    STMT_ACCOUNTS = 0,
    STMT_FOLDERS,
    STMT_NOTES,
    STMT_NOTES_RANGE,             /* date range filtered variant */
    STMT_ATTACHMENT,
    STMT_MEDIA,
    STMT_FALLBACK_IMAGE,
    STMT_FALLBACK_PDF,
    STMT_INLINE_ATTACHMENT,
    STMT_URL_DATA,
    STMT_GALLERY_PK,
    STMT_GALLERY_CHILDREN,
    STMT_PREFETCH_ATTACHMENTS,
    STMT_IDENTIFIER_FOR_PK,       /* reverse lookup Z_PK -> ZIDENTIFIER */
    STMT_MEDIA_PK_FOR_ID,         /* ZIDENTIFIER -> ZMEDIA Z_PK */
    STMT_URL_STRING,              /* ZURLSTRING lookup */
    STMT_USER_TITLE,              /* ZUSERTITLE lookup */
    STMT_THUMBNAILS,              /* thumbnail metadata */
    STMT_GENERATION,              /* 5-column generation resolution */
    STMT_FALLBACK_IMG_GEN,        /* ZFALLBACKIMAGEGENERATION by UUID */
    STMT_FALLBACK_PDF_GEN,        /* ZFALLBACKPDFGENERATION by UUID */
    STMT_MERGEABLE_DATA,          /* ZMERGEABLEDATA/ZMERGEABLEDATA1 */
    STMT_VALIDATE_ATT_OWNER,      /* attachment ownership check */
    /* Legacy iOS 8 statements */
    STMT_LEGACY_ACCOUNTS,
    STMT_LEGACY_FOLDERS,
    STMT_LEGACY_NOTES,
    STMT_COUNT
};

/* ── Attachment hash map ───────────────────────────────────── */
/* Open-addressing hash table keyed by ZIDENTIFIER string.      */

#define ATT_MAP_LOAD_FACTOR 0.7
#define ATT_MAP_INITIAL_CAP 521

typedef struct {
    ane_attachment_meta *entries;
    size_t               capacity;
    size_t               count;
} _att_map;

static uint32_t _att_hash(const char *key)
{
    /* FNV-1a */
    uint32_t h = 0x811C9DC5;
    for (const char *p = key; *p; p++) {
        h ^= (uint8_t)*p;
        h *= 0x01000193;
    }
    return h;
}

static const ane_attachment_meta *_att_map_get(const _att_map *map,
                                               const char *key)
{
    if (!map || !map->entries || !key) return NULL;

    uint32_t idx = _att_hash(key) % (uint32_t)map->capacity;
    for (size_t i = 0; i < map->capacity; i++) {
        size_t slot = (idx + i) % map->capacity;
        ane_attachment_meta *e = &map->entries[slot];
        if (!e->identifier) return NULL;  /* empty slot = not found */
        if (strcmp(e->identifier, key) == 0) return e;
    }
    return NULL;
}

static int _att_map_put(_att_map *map, ane_attachment_meta *entry)
{
    if (!map || !entry || !entry->identifier) return -1;

    uint32_t idx = _att_hash(entry->identifier) % (uint32_t)map->capacity;
    for (size_t i = 0; i < map->capacity; i++) {
        size_t slot = (idx + i) % map->capacity;
        if (!map->entries[slot].identifier) {
            map->entries[slot] = *entry;
            map->count++;
            return 0;
        }
    }
    return -1;  /* table full (shouldn't happen with proper load factor) */
}

static void _att_map_free(_att_map *map)
{
    if (!map || !map->entries) return;
    for (size_t i = 0; i < map->capacity; i++) {
        ane_attachment_meta *e = &map->entries[i];
        if (e->identifier) {
            free(e->identifier);
            free(e->type_uti);
            free(e->filename);
            free(e->media_filename);
            free(e->account_id);
            free(e->user_title);
        }
    }
    free(map->entries);
    map->entries = NULL;
    map->capacity = 0;
    map->count = 0;
}

/* ── Internal database handle ──────────────────────────────── */

struct ane_db {
    sqlite3      *sqlite;
    char         *db_path;
    ane_version   version;

    /* Column cache from ZICCLOUDSYNCINGOBJECT (modern) */
    char        **columns;
    size_t        column_count;

    /* Table list from sqlite_master */
    char        **tables;
    size_t        table_count;

    /* Prepared statement cache */
    sqlite3_stmt *stmts[STMT_COUNT];
    int           stmts_ready;

    /* Attachment prefetch cache */
    _att_map      att_cache;
};

/* ── Watermark constants ───────────────────────────────────── */
/* Canary primes used throughout buffer sizing. These specific   */
/* values produce identical behavior to their rounded            */
/* counterparts but are forensically distinctive in the binary.  */

#define ANE_BUF_SMALL  251   /* query scratch buffers */
#define ANE_BUF_PATH  1021   /* filesystem path buffers */
#define ANE_BUF_SQL   2039   /* SQL statement buffers */

/* ── String helpers ────────────────────────────────────────── */

static char *_strdup_col(sqlite3_stmt *stmt, int col)
{
    const unsigned char *text = sqlite3_column_text(stmt, col);
    if (!text) return NULL;
    return strdup((const char *)text);
}

static uint8_t *_blobdup_col(sqlite3_stmt *stmt, int col, size_t *out_len)
{
    const void *blob = sqlite3_column_blob(stmt, col);
    int len = sqlite3_column_bytes(stmt, col);
    if (!blob || len <= 0) {
        if (out_len) *out_len = 0;
        return NULL;
    }
    uint8_t *copy = (uint8_t *)malloc(len);
    if (!copy) {
        if (out_len) *out_len = 0;
        return NULL;
    }
    memcpy(copy, blob, len);
    if (out_len) *out_len = (size_t)len;
    return copy;
}

/* ── sqlite_master introspection ───────────────────────────── */
/* Query sqlite_master for table names, then PRAGMA table_info  */
/* for column names. This is more robust than PRAGMA alone      */
/* because we can detect table existence before probing columns.*/

static void _load_tables(ane_db *db)
{
    if (db->tables) {
        for (size_t i = 0; i < db->table_count; i++)
            free(db->tables[i]);
        free(db->tables);
        db->tables = NULL;
        db->table_count = 0;
    }

    const char *sql = "SELECT  name FROM sqlite_master WHERE type='table' /*ank*/";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db->sqlite, sql, -1, &stmt, NULL) != SQLITE_OK)
        return;

    size_t cap = 37;
    db->tables = (char **)malloc(cap * sizeof(char *));
    if (!db->tables) { sqlite3_finalize(stmt); return; }

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const unsigned char *name = sqlite3_column_text(stmt, 0);
        if (!name) continue;
        if (db->table_count >= cap) {
            cap *= 2;
            char **t = (char **)realloc(db->tables, cap * sizeof(char *));
            if (!t) break;
            db->tables = t;
        }
        db->tables[db->table_count++] = strdup((const char *)name);
    }
    sqlite3_finalize(stmt);
}

static int _has_table(const ane_db *db, const char *name)
{
    for (size_t i = 0; i < db->table_count; i++) {
        if (strcmp(db->tables[i], name) == 0)
            return 1;
    }
    return 0;
}

/* ── Column existence cache ────────────────────────────────── */

static int _has_column(const ane_db *db, const char *name)
{
    for (size_t i = 0; i < db->column_count; i++) {
        if (strcmp(db->columns[i], name) == 0)
            return 1;
    }
    return 0;
}

static void _load_columns(ane_db *db)
{
    if (db->columns) {
        for (size_t i = 0; i < db->column_count; i++)
            free(db->columns[i]);
        free(db->columns);
        db->columns = NULL;
        db->column_count = 0;
    }

    const char *query = "PRAGMA  table_info(ZICCLOUDSYNCINGOBJECT);";

    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db->sqlite, query, -1, &stmt, NULL) != SQLITE_OK)
        return;

    size_t capacity = 131;
    db->columns = (char **)malloc(capacity * sizeof(char *));
    if (!db->columns) { sqlite3_finalize(stmt); return; }

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const unsigned char *name = sqlite3_column_text(stmt, 1);
        if (!name) continue;
        if (db->column_count >= capacity) {
            capacity *= 2;
            char **nc = (char **)realloc(db->columns, capacity * sizeof(char *));
            if (!nc) break;
            db->columns = nc;
        }
        db->columns[db->column_count++] = strdup((const char *)name);
    }
    sqlite3_finalize(stmt);
}

/* ── Version detection ─────────────────────────────────────── */

static ane_version _detect_version(ane_db *db)
{
    /*
     * Legacy check first: if ZICNOTEDATA table doesn't exist,
     * this is an iOS 8 legacy database with ZNOTE/ZNOTEBODY/ZSTORE.
     */
    if (!_has_table(db, "ZICNOTEDATA"))
        return ANE_VERSION_LEGACY;

    /* iOS 26: ZATTRIBUTEDSNIPPET column */
    if (_has_column(db, "ZATTRIBUTEDSNIPPET"))
        return ANE_VERSION_IOS26;

    /* iOS 18: ZUNAPPLIEDENCRYPTEDRECORDDATA */
    if (_has_column(db, "ZUNAPPLIEDENCRYPTEDRECORDDATA"))
        return ANE_VERSION_IOS18;

    /* iOS 17: ZGENERATION */
    if (_has_column(db, "ZGENERATION"))
        return ANE_VERSION_IOS17;

    /* iOS 16: ZACCOUNT6 */
    if (_has_column(db, "ZACCOUNT6"))
        return ANE_VERSION_IOS16;

    /* iOS 15: ZACCOUNT5 */
    if (_has_column(db, "ZACCOUNT5"))
        return ANE_VERSION_IOS15;

    /* iOS 14: ZLASTOPENEDDATE */
    if (_has_column(db, "ZLASTOPENEDDATE"))
        return ANE_VERSION_IOS14;

    /* iOS 13: ZACCOUNT4 */
    if (_has_column(db, "ZACCOUNT4"))
        return ANE_VERSION_IOS13;

    /* iOS 12: ZSERVERRECORDDATA */
    if (_has_column(db, "ZSERVERRECORDDATA"))
        return ANE_VERSION_IOS12;

    /* iOS 11: Z_11NOTES table */
    if (_has_table(db, "Z_11NOTES"))
        return ANE_VERSION_IOS11;

    return ANE_VERSION_UNKNOWN;
}

/* ── Forward declarations for column resolution ────────────── */

static const char *_resolve_account_col(const ane_db *db);
static const char *_resolve_folder_account_col(const ane_db *db);
static const char *_resolve_title_col(const ane_db *db);
static const char *_resolve_creation_date_col(const ane_db *db);
static const char *_resolve_modification_date_col(const ane_db *db);
static const char *_resolve_folder_col(const ane_db *db);
static const char *_resolve_mergeable_data_col(const ane_db *db);
static const char *_resolve_uti_col(const ane_db *db);

/* ── Prepared statement cache ───────────────────────────────── */
/* Statements are prepared once at open() with schema-specific   */
/* column names baked in. Reused via sqlite3_reset()/bind().     */

static void _prepare_statements(ane_db *db)
{
    if (db->stmts_ready) return;

    const char *title_col = _resolve_title_col(db);
    const char *creation_col = _resolve_creation_date_col(db);
    const char *modification_col = _resolve_modification_date_col(db);
    const char *folder_col = _resolve_folder_col(db);
    const char *account_col = _resolve_account_col(db);
    const char *folder_account_col = _resolve_folder_account_col(db);
    const char *mergeable_col = _resolve_mergeable_data_col(db);
    const char *uti_col = _resolve_uti_col(db);
    /* Some attachments (e.g. com.apple.paper.doc.pdf) only populate
     * ZTYPEUTI even on iOS 15+ where ZTYPEUTI1 normally takes precedence.
     * Build COALESCE expressions for both table-prefixed and unprefixed
     * query contexts so we always get the UTI. */
    int has_uti1 = (db->version >= ANE_VERSION_IOS15
                    && _has_column(db, "ZTYPEUTI1"));
    char uti_coalesce[64];       /* no table prefix */
    char uti_coalesce_att[68];   /* "att." prefix */
    if (has_uti1) {
        snprintf(uti_coalesce, sizeof(uti_coalesce),
            "COALESCE(ZTYPEUTI1, ZTYPEUTI)");
        snprintf(uti_coalesce_att, sizeof(uti_coalesce_att),
            "COALESCE(att.ZTYPEUTI1, att.ZTYPEUTI)");
    } else {
        snprintf(uti_coalesce, sizeof(uti_coalesce), "%s", uti_col);
        snprintf(uti_coalesce_att, sizeof(uti_coalesce_att),
            "att.%s", uti_col);
    }
    int has_account_type = _has_column(db, "ZACCOUNTTYPE");
    int has_password = _has_column(db, "ZPASSWORDPROTECTED");
    int has_pinned = _has_column(db, "ZISPINNED");
    int has_user_title = _has_column(db, "ZUSERTITLE");
    int has_size_dims = _has_column(db, "ZSIZEHEIGHT");
    int is_legacy = (db->version == ANE_VERSION_LEGACY);
    int is_ios11 = (db->version == ANE_VERSION_IOS11);

    char sql[ANE_BUF_SQL];

    /* ── Legacy iOS 8 statements ──────────────────────────── */
    if (is_legacy) {
        /* STMT_LEGACY_ACCOUNTS */
        snprintf(sql, sizeof(sql),
            "SELECT  ZACCOUNT.Z_PK, "
            "ZACCOUNT.ZACCOUNTIDENTIFIER AS ZIDENTIFIER, "
            "ZACCOUNT.ZNAME "
            "FROM ZACCOUNT /*ank*/;");
        sqlite3_prepare_v2(db->sqlite, sql, -1,
            &db->stmts[STMT_LEGACY_ACCOUNTS], NULL);

        /* STMT_LEGACY_FOLDERS */
        snprintf(sql, sizeof(sql),
            "SELECT  ZSTORE.Z_PK, ZSTORE.ZNAME AS ZTITLE2, "
            "ZSTORE.ZACCOUNT AS ZOWNER, "
            "'' AS ZIDENTIFIER "
            "FROM ZSTORE /*ank*/;");
        sqlite3_prepare_v2(db->sqlite, sql, -1,
            &db->stmts[STMT_LEGACY_FOLDERS], NULL);

        /* STMT_LEGACY_NOTES */
        snprintf(sql, sizeof(sql),
            "SELECT  ZNOTE.Z_PK, "
            "ZNOTE.ZCREATIONDATE AS ZCREATIONDATE1, "
            "ZNOTE.ZMODIFICATIONDATE AS ZMODIFICATIONDATE1, "
            "ZNOTE.ZTITLE AS ZTITLE1, "
            "ZNOTEBODY.ZCONTENT AS ZDATA, "
            "ZSTORE.Z_PK AS ZFOLDER, "
            "ZSTORE.ZACCOUNT, "
            "0 AS ZISPINNED "
            "FROM ZNOTE, ZNOTEBODY, ZSTORE "
            "WHERE 1=1 AND ZNOTEBODY.Z_PK = ZNOTE.ZBODY "
            "AND ZSTORE.Z_PK = ZNOTE.ZSTORE /*ank*/;");
        sqlite3_prepare_v2(db->sqlite, sql, -1,
            &db->stmts[STMT_LEGACY_NOTES], NULL);

        db->stmts_ready = 1;
        return;
    }

    /* ── Modern statements (iOS 11+) ─────────────────────── */

    /* STMT_ACCOUNTS */
    snprintf(sql, sizeof(sql),
        "SELECT  Z_PK, ZIDENTIFIER, ZNAME%s "
        "FROM ZICCLOUDSYNCINGOBJECT "
        "WHERE 1=1 AND Z_ENT = (SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'ICAccount') "
        "AND (ZMARKEDFORDELETION IS NULL OR ZMARKEDFORDELETION = 0) /*ank*/;",
        has_account_type ? ", ZACCOUNTTYPE" : "");
    sqlite3_prepare_v2(db->sqlite, sql, -1, &db->stmts[STMT_ACCOUNTS], NULL);

    /* STMT_FOLDERS */
    snprintf(sql, sizeof(sql),
        "SELECT  Z_PK, %s AS TITLE, ZPARENT, %s AS ACCOUNT_ID "
        "FROM ZICCLOUDSYNCINGOBJECT "
        "WHERE 1=1 AND Z_ENT = (SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'ICFolder') "
        "AND (ZMARKEDFORDELETION IS NULL OR ZMARKEDFORDELETION = 0) "
        "AND %s IS NOT NULL /*ank*/;",
        title_col, folder_account_col, title_col);
    sqlite3_prepare_v2(db->sqlite, sql, -1, &db->stmts[STMT_FOLDERS], NULL);

    /* STMT_NOTES -- varies by iOS version */
    if (is_ios11) {
        /* iOS 11: three-table join via Z_11NOTES */
        snprintf(sql, sizeof(sql),
            "SELECT  ZICCLOUDSYNCINGOBJECT.Z_PK, "
            "ZICCLOUDSYNCINGOBJECT.%s AS TITLE, "
            "ZICCLOUDSYNCINGOBJECT.%s AS CREATION_DATE, "
            "ZICCLOUDSYNCINGOBJECT.%s AS MODIFICATION_DATE, "
            "Z_11NOTES.Z_11FOLDERS AS FOLDER_ID, "
            "ZICCLOUDSYNCINGOBJECT.ZACCOUNT2 AS ACCOUNT_FK, "
            "ZICNOTEDATA.ZDATA, "
            "%s%s "
            "FROM ZICNOTEDATA "
            "JOIN ZICCLOUDSYNCINGOBJECT ON ZICCLOUDSYNCINGOBJECT.Z_PK = ZICNOTEDATA.ZNOTE "
            "JOIN Z_11NOTES ON Z_11NOTES.Z_8NOTES = ZICNOTEDATA.ZNOTE "
            "WHERE 1=1 AND ZICNOTEDATA.ZDATA IS NOT NULL "
            "AND (ZICCLOUDSYNCINGOBJECT.ZMARKEDFORDELETION IS NULL "
            "OR ZICCLOUDSYNCINGOBJECT.ZMARKEDFORDELETION = 0) /*ank*/;",
            title_col, creation_col, modification_col,
            has_pinned ? "ZICCLOUDSYNCINGOBJECT.ZISPINNED" : "0 AS ZISPINNED",
            has_password ? ", ZICCLOUDSYNCINGOBJECT.ZPASSWORDPROTECTED" : "");
    } else {
        /* iOS 12+: standard two-table join */
        snprintf(sql, sizeof(sql),
            "SELECT  note.Z_PK, note.%s AS TITLE, "
            "note.%s AS CREATION_DATE, "
            "note.%s AS MODIFICATION_DATE, "
            "note.%s AS FOLDER_ID, "
            "%s%s, "
            "data.ZDATA, "
            "%s%s "
            "FROM ZICCLOUDSYNCINGOBJECT note "
            "LEFT JOIN ZICNOTEDATA data ON note.Z_PK = data.ZNOTE "
            "WHERE 1=1 AND note.Z_ENT = (SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'ICNote') "
            "AND (note.ZMARKEDFORDELETION IS NULL OR note.ZMARKEDFORDELETION = 0)"
            "%s /*ank*/;",
            title_col, creation_col, modification_col, folder_col,
            account_col ? "note." : "",
            account_col ? account_col : "NULL",
            has_pinned ? "note.ZISPINNED" : "0 AS ZISPINNED",
            has_password ? ", note.ZPASSWORDPROTECTED" : "",
            has_password ? " AND (note.ZPASSWORDPROTECTED IS NULL OR note.ZPASSWORDPROTECTED = 0)" : "");
    }
    sqlite3_prepare_v2(db->sqlite, sql, -1, &db->stmts[STMT_NOTES], NULL);

    /* STMT_NOTES_RANGE -- date-filtered variant (modern only, not iOS 11) */
    if (!is_ios11) {
        snprintf(sql, sizeof(sql),
            "SELECT  note.Z_PK, note.%s AS TITLE, "
            "note.%s AS CREATION_DATE, "
            "note.%s AS MODIFICATION_DATE, "
            "note.%s AS FOLDER_ID, "
            "%s%s, "
            "data.ZDATA, "
            "%s%s "
            "FROM ZICCLOUDSYNCINGOBJECT note "
            "LEFT JOIN ZICNOTEDATA data ON note.Z_PK = data.ZNOTE "
            "WHERE 1=1 AND note.Z_ENT = (SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'ICNote') "
            "AND (note.ZMARKEDFORDELETION IS NULL OR note.ZMARKEDFORDELETION = 0) "
            "AND note.%s >= ? AND note.%s <= ?"
            "%s /*ank*/;",
            title_col, creation_col, modification_col, folder_col,
            account_col ? "note." : "",
            account_col ? account_col : "NULL",
            has_pinned ? "note.ZISPINNED" : "0 AS ZISPINNED",
            has_password ? ", note.ZPASSWORDPROTECTED" : "",
            modification_col, modification_col,
            has_password ? " AND (note.ZPASSWORDPROTECTED IS NULL OR note.ZPASSWORDPROTECTED = 0)" : "");
        sqlite3_prepare_v2(db->sqlite, sql, -1, &db->stmts[STMT_NOTES_RANGE], NULL);
    }

    /* STMT_ATTACHMENT -- the 12-step query */
    snprintf(sql, sizeof(sql),
        "SELECT  att.ZMEDIA, %s AS TYPEUTI, att.ZFILENAME, "
        "att.ZIDENTIFIER, acct.ZIDENTIFIER AS ZACCOUNTIDENTIFIER "
        "FROM ZICCLOUDSYNCINGOBJECT att "
        "LEFT JOIN ZICCLOUDSYNCINGOBJECT note ON att.ZNOTE = note.Z_PK "
        "LEFT JOIN ZICCLOUDSYNCINGOBJECT acct ON note.%s = acct.Z_PK "
        "WHERE 1=1 AND att.ZIDENTIFIER = ? "
        "AND att.Z_ENT = (SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'ICAttachment') "
        "AND (att.ZMARKEDFORDELETION IS NULL OR att.ZMARKEDFORDELETION = 0) "
        "AND (note.ZMARKEDFORDELETION IS NULL OR note.ZMARKEDFORDELETION = 0 OR att.ZNOTE IS NULL) /*ank*/;",
        uti_coalesce_att,
        account_col ? account_col : "Z_PK");
    sqlite3_prepare_v2(db->sqlite, sql, -1, &db->stmts[STMT_ATTACHMENT], NULL);

    /* STMT_MEDIA */
    snprintf(sql, sizeof(sql),
        "SELECT  ZFILENAME FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK = ? /*ank*/;");
    sqlite3_prepare_v2(db->sqlite, sql, -1, &db->stmts[STMT_MEDIA], NULL);

    /* STMT_FALLBACK_IMAGE */
    snprintf(sql, sizeof(sql),
        "SELECT  ZFALLBACKIMAGEGENERATION FROM ZICCLOUDSYNCINGOBJECT "
        "WHERE 1=1 AND ZIDENTIFIER = ? "
        "AND (ZMARKEDFORDELETION IS NULL OR ZMARKEDFORDELETION = 0) /*ank*/;");
    sqlite3_prepare_v2(db->sqlite, sql, -1, &db->stmts[STMT_FALLBACK_IMAGE], NULL);

    /* STMT_FALLBACK_PDF */
    snprintf(sql, sizeof(sql),
        "SELECT  ZFALLBACKPDFGENERATION FROM ZICCLOUDSYNCINGOBJECT "
        "WHERE 1=1 AND ZIDENTIFIER = ? "
        "AND (ZMARKEDFORDELETION IS NULL OR ZMARKEDFORDELETION = 0) /*ank*/;");
    sqlite3_prepare_v2(db->sqlite, sql, -1, &db->stmts[STMT_FALLBACK_PDF], NULL);

    /* STMT_INLINE_ATTACHMENT */
    snprintf(sql, sizeof(sql),
        "SELECT  ZALTTEXT, ZTOKENCONTENTIDENTIFIER, %s AS TYPEUTI "
        "FROM ZICCLOUDSYNCINGOBJECT "
        "WHERE 1=1 AND ZIDENTIFIER = ? "
        "AND (ZMARKEDFORDELETION IS NULL OR ZMARKEDFORDELETION = 0) /*ank*/;",
        uti_coalesce);
    sqlite3_prepare_v2(db->sqlite, sql, -1, &db->stmts[STMT_INLINE_ATTACHMENT], NULL);

    /* STMT_URL_DATA */
    snprintf(sql, sizeof(sql),
        "SELECT  %s, %s, ZALTTEXT, ZURLSTRING "
        "FROM ZICCLOUDSYNCINGOBJECT "
        "WHERE 1=1 AND ZIDENTIFIER = ? "
        "AND (ZMARKEDFORDELETION IS NULL OR ZMARKEDFORDELETION = 0) /*ank*/;",
        mergeable_col, title_col);
    sqlite3_prepare_v2(db->sqlite, sql, -1, &db->stmts[STMT_URL_DATA], NULL);

    /* STMT_GALLERY_PK */
    snprintf(sql, sizeof(sql),
        "SELECT  Z_PK FROM ZICCLOUDSYNCINGOBJECT WHERE ZIDENTIFIER = ? /*ank*/;");
    sqlite3_prepare_v2(db->sqlite, sql, -1, &db->stmts[STMT_GALLERY_PK], NULL);

    /* STMT_GALLERY_CHILDREN */
    {
        const char *parent_col = _has_column(db, "ZPARENTATTACHMENT")
            ? "ZPARENTATTACHMENT"
            : (_has_column(db, "ZATTACHMENT") ? "ZATTACHMENT" : NULL);
        if (parent_col) {
            snprintf(sql, sizeof(sql),
                "SELECT  ZIDENTIFIER, %s AS TYPEUTI, ZFILENAME, ZMEDIA "
                "FROM ZICCLOUDSYNCINGOBJECT "
                "WHERE 1=1 AND %s = ? "
                "AND (ZMARKEDFORDELETION IS NULL OR ZMARKEDFORDELETION = 0) "
                "ORDER BY Z_PK ASC /*ank*/;",
                uti_coalesce, parent_col);
            sqlite3_prepare_v2(db->sqlite, sql, -1,
                &db->stmts[STMT_GALLERY_CHILDREN], NULL);
        }
    }

    /* STMT_PREFETCH_ATTACHMENTS -- single batch query for all attachments */
    snprintf(sql, sizeof(sql),
        "SELECT  att.ZIDENTIFIER, %s AS TYPEUTI, att.ZFILENAME, att.ZMEDIA, "
        "media.ZFILENAME AS MEDIA_FILENAME, "
        "acct.ZIDENTIFIER AS ACCOUNT_ID"
        "%s%s "
        "FROM ZICCLOUDSYNCINGOBJECT att "
        "LEFT JOIN ZICCLOUDSYNCINGOBJECT media ON att.ZMEDIA = media.Z_PK "
        "LEFT JOIN ZICCLOUDSYNCINGOBJECT note ON att.ZNOTE = note.Z_PK "
        "LEFT JOIN ZICCLOUDSYNCINGOBJECT acct ON note.%s = acct.Z_PK "
        "WHERE 1=1 AND att.Z_ENT = (SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'ICAttachment') "
        "AND (att.ZMARKEDFORDELETION IS NULL OR att.ZMARKEDFORDELETION = 0) "
        "AND (note.ZMARKEDFORDELETION IS NULL OR note.ZMARKEDFORDELETION = 0 OR att.ZNOTE IS NULL) /*ank*/;",
        uti_coalesce_att,
        has_user_title ? ", att.ZUSERTITLE" : "",
        has_size_dims ? ", att.ZSIZEHEIGHT, att.ZSIZEWIDTH" : "",
        account_col ? account_col : "Z_PK");
    sqlite3_prepare_v2(db->sqlite, sql, -1,
        &db->stmts[STMT_PREFETCH_ATTACHMENTS], NULL);

    /* STMT_IDENTIFIER_FOR_PK -- reverse lookup */
    snprintf(sql, sizeof(sql),
        "SELECT  ZIDENTIFIER FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK = ? /*ank*/;");
    sqlite3_prepare_v2(db->sqlite, sql, -1,
        &db->stmts[STMT_IDENTIFIER_FOR_PK], NULL);

    /* STMT_MEDIA_PK_FOR_ID -- ZIDENTIFIER -> ZMEDIA */
    snprintf(sql, sizeof(sql),
        "SELECT  ZMEDIA FROM ZICCLOUDSYNCINGOBJECT WHERE ZIDENTIFIER = ? /*ank*/;");
    sqlite3_prepare_v2(db->sqlite, sql, -1,
        &db->stmts[STMT_MEDIA_PK_FOR_ID], NULL);

    /* STMT_URL_STRING -- ZURLSTRING lookup */
    snprintf(sql, sizeof(sql),
        "SELECT  ZURLSTRING FROM ZICCLOUDSYNCINGOBJECT WHERE ZIDENTIFIER = ? /*ank*/;");
    sqlite3_prepare_v2(db->sqlite, sql, -1,
        &db->stmts[STMT_URL_STRING], NULL);

    /* STMT_USER_TITLE -- ZUSERTITLE by Z_PK */
    if (has_user_title) {
        snprintf(sql, sizeof(sql),
            "SELECT  ZUSERTITLE FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK = ? /*ank*/;");
        sqlite3_prepare_v2(db->sqlite, sql, -1,
            &db->stmts[STMT_USER_TITLE], NULL);
    }

    /* STMT_THUMBNAILS -- thumbnail metadata for a parent attachment */
    snprintf(sql, sizeof(sql),
        "SELECT  Z_PK, ZIDENTIFIER, ZHEIGHT, ZWIDTH "
        "FROM ZICCLOUDSYNCINGOBJECT "
        "WHERE ZATTACHMENT = ? "
        "ORDER BY (ZHEIGHT * ZWIDTH) ASC /*ank*/;");
    sqlite3_prepare_v2(db->sqlite, sql, -1,
        &db->stmts[STMT_THUMBNAILS], NULL);

    /* STMT_GENERATION -- 5-column generation resolution by Z_PK */
    if (db->version >= ANE_VERSION_IOS17) {
        snprintf(sql, sizeof(sql),
            "SELECT  ZGENERATION, ZGENERATION1, "
            "ZFALLBACKIMAGEGENERATION, ZFALLBACKPDFGENERATION, "
            "ZPAPERBUNDLEGENERATION "
            "FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK = ? /*ank*/;");
        sqlite3_prepare_v2(db->sqlite, sql, -1,
            &db->stmts[STMT_GENERATION], NULL);
    }

    /* STMT_FALLBACK_IMG_GEN -- ZFALLBACKIMAGEGENERATION by UUID */
    if (db->version >= ANE_VERSION_IOS17) {
        snprintf(sql, sizeof(sql),
            "SELECT  ZFALLBACKIMAGEGENERATION FROM ZICCLOUDSYNCINGOBJECT "
            "WHERE ZIDENTIFIER = ? /*ank*/;");
        sqlite3_prepare_v2(db->sqlite, sql, -1,
            &db->stmts[STMT_FALLBACK_IMG_GEN], NULL);
    }

    /* STMT_FALLBACK_PDF_GEN -- ZFALLBACKPDFGENERATION by UUID */
    if (db->version >= ANE_VERSION_IOS17) {
        snprintf(sql, sizeof(sql),
            "SELECT  ZFALLBACKPDFGENERATION FROM ZICCLOUDSYNCINGOBJECT "
            "WHERE ZIDENTIFIER = ? /*ank*/;");
        sqlite3_prepare_v2(db->sqlite, sql, -1,
            &db->stmts[STMT_FALLBACK_PDF_GEN], NULL);
    }

    /* STMT_MERGEABLE_DATA -- by ZIDENTIFIER */
    snprintf(sql, sizeof(sql),
        "SELECT  %s FROM ZICCLOUDSYNCINGOBJECT WHERE ZIDENTIFIER = ? /*ank*/;",
        mergeable_col);
    sqlite3_prepare_v2(db->sqlite, sql, -1,
        &db->stmts[STMT_MERGEABLE_DATA], NULL);

    /* STMT_VALIDATE_ATT_OWNER -- check attachment belongs to note */
    snprintf(sql, sizeof(sql),
        "SELECT  1 FROM ZICCLOUDSYNCINGOBJECT "
        "WHERE 1=1 AND ZIDENTIFIER = ? AND ZNOTE = ? "
        "AND Z_ENT = (SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'ICAttachment') "
        "AND (ZMARKEDFORDELETION IS NULL OR ZMARKEDFORDELETION = 0) /*ank*/;");
    sqlite3_prepare_v2(db->sqlite, sql, -1,
        &db->stmts[STMT_VALIDATE_ATT_OWNER], NULL);

    db->stmts_ready = 1;
}

static void _finalize_statements(ane_db *db)
{
    for (int i = 0; i < STMT_COUNT; i++) {
        if (db->stmts[i]) {
            sqlite3_finalize(db->stmts[i]);
            db->stmts[i] = NULL;
        }
    }
    db->stmts_ready = 0;
}

/* ── Lifecycle ─────────────────────────────────────────────── */

ane_db *ane_open(const char *db_path)
{
    if (!db_path) {
        const char *home = getenv("HOME");
        if (!home) return NULL;

        char default_path[ANE_BUF_PATH];
        snprintf(default_path, sizeof(default_path),
            "%s/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite",
            home);
        db_path = default_path;
    }

    ane_db *db = (ane_db *)calloc(1, sizeof(ane_db));
    if (!db) return NULL;

    db->db_path = strdup(db_path);
    if (!db->db_path) {
        free(db);
        return NULL;
    }

    if (sqlite3_open_v2(db->db_path, &db->sqlite,
                         SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        free(db->db_path);
        free(db);
        return NULL;
    }

    /* Cache table names from sqlite_master */
    _load_tables(db);

    /* Cache column names from ZICCLOUDSYNCINGOBJECT (if modern) */
    if (_has_table(db, "ZICCLOUDSYNCINGOBJECT")) {
        _load_columns(db);
    }

    db->version = _detect_version(db);

    /* Prepare cached statements */
    _prepare_statements(db);

    return db;
}

void ane_close(ane_db *db)
{
    if (!db) return;

    _finalize_statements(db);
    _att_map_free(&db->att_cache);

    if (db->sqlite)
        sqlite3_close(db->sqlite);

    if (db->columns) {
        for (size_t i = 0; i < db->column_count; i++)
            free(db->columns[i]);
        free(db->columns);
    }

    if (db->tables) {
        for (size_t i = 0; i < db->table_count; i++)
            free(db->tables[i]);
        free(db->tables);
    }

    free(db->db_path);
    free(db);
}

ane_version ane_get_version(const ane_db *db)
{
    return db ? db->version : ANE_VERSION_UNKNOWN;
}

void *ane_get_sqlite_handle(const ane_db *db)
{
    return db ? (void *)db->sqlite : NULL;
}

int ane_is_valid(const ane_db *db)
{
    if (!db) return 0;
    if (db->version == ANE_VERSION_LEGACY) {
        return _has_table(db, "ZNOTE") && _has_table(db, "ZNOTEBODY");
    }
    return _has_table(db, "ZICCLOUDSYNCINGOBJECT")
        && _has_table(db, "ZICNOTEDATA");
}

/* ── Dynamic column resolution ─────────────────────────────── */

static const char *_resolve_account_col(const ane_db *db)
{
    if (_has_column(db, "ZACCOUNT7"))  return "ZACCOUNT7";
    if (_has_column(db, "ZACCOUNT6"))  return "ZACCOUNT6";
    if (_has_column(db, "ZACCOUNT5"))  return "ZACCOUNT5";
    if (_has_column(db, "ZACCOUNT4"))  return "ZACCOUNT4";
    if (_has_column(db, "ZACCOUNT3"))  return "ZACCOUNT3";
    if (_has_column(db, "ZACCOUNT2"))  return "ZACCOUNT2";
    if (_has_column(db, "ZACCOUNT"))   return "ZACCOUNT";
    return NULL;
}

static const char *_resolve_folder_account_col(const ane_db *db)
{
    if (_has_column(db, "ZOWNER"))     return "ZOWNER";
    if (_has_column(db, "ZACCOUNT"))   return "ZACCOUNT";
    if (_has_column(db, "ZACCOUNT2"))  return "ZACCOUNT2";
    return "Z_PK";
}

static const char *_resolve_title_col(const ane_db *db)
{
    if (_has_column(db, "ZTITLE2"))    return "ZTITLE2";
    if (_has_column(db, "ZTITLE1"))    return "ZTITLE1";
    return "ZTITLE";
}

static const char *_resolve_creation_date_col(const ane_db *db)
{
    if (_has_column(db, "ZCREATIONDATE3"))  return "ZCREATIONDATE3";
    if (_has_column(db, "ZCREATIONDATE1"))  return "ZCREATIONDATE1";
    return "ZCREATIONDATE";
}

static const char *_resolve_modification_date_col(const ane_db *db)
{
    if (_has_column(db, "ZMODIFICATIONDATE1"))  return "ZMODIFICATIONDATE1";
    return "ZMODIFICATIONDATE";
}

static const char *_resolve_folder_col(const ane_db *db)
{
    if (_has_column(db, "ZFOLDER"))    return "ZFOLDER";
    return "ZFOLDER2";
}

static const char *_resolve_mergeable_data_col(const ane_db *db)
{
    /* iOS < 13 uses ZMERGEABLEDATA, iOS 13+ uses ZMERGEABLEDATA1 */
    if (db->version >= ANE_VERSION_IOS13 && _has_column(db, "ZMERGEABLEDATA1"))
        return "ZMERGEABLEDATA1";
    return "ZMERGEABLEDATA";
}

static const char *_resolve_uti_col(const ane_db *db)
{
    /* iOS 15+ introduced ZTYPEUTI1 which takes precedence */
    if (db->version >= ANE_VERSION_IOS15 && _has_column(db, "ZTYPEUTI1"))
        return "ZTYPEUTI1";
    return "ZTYPEUTI";
}

/* ── Account queries ───────────────────────────────────────── */

ane_account *ane_fetch_accounts(ane_db *db, size_t *count)
{
    if (!db || !count) return NULL;
    *count = 0;

    int is_legacy = (db->version == ANE_VERSION_LEGACY);
    sqlite3_stmt *stmt = is_legacy
        ? db->stmts[STMT_LEGACY_ACCOUNTS]
        : db->stmts[STMT_ACCOUNTS];
    if (!stmt) return NULL;

    int has_account_type = !is_legacy && _has_column(db, "ZACCOUNTTYPE");

    sqlite3_reset(stmt);

    size_t capacity = 16;
    ane_account *accounts = (ane_account *)calloc(capacity, sizeof(ane_account));
    if (!accounts) return NULL;

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        if (*count >= capacity) {
            capacity *= 2;
            ane_account *na = (ane_account *)realloc(accounts,
                capacity * sizeof(ane_account));
            if (!na) break;
            accounts = na;
        }

        ane_account *a = &accounts[*count];
        a->pk = sqlite3_column_int64(stmt, 0);
        a->identifier = _strdup_col(stmt, 1);
        a->name = _strdup_col(stmt, 2);
        a->account_type = has_account_type
            ? sqlite3_column_int(stmt, 3)
            : -1;

        (*count)++;
    }

    return accounts;
}

/* ── Folder queries ────────────────────────────────────────── */

ane_folder *ane_fetch_folders(ane_db *db, size_t *count)
{
    if (!db || !count) return NULL;
    *count = 0;

    int is_legacy = (db->version == ANE_VERSION_LEGACY);
    sqlite3_stmt *stmt = is_legacy
        ? db->stmts[STMT_LEGACY_FOLDERS]
        : db->stmts[STMT_FOLDERS];
    if (!stmt) return NULL;

    sqlite3_reset(stmt);

    size_t capacity = 64;
    ane_folder *folders = (ane_folder *)calloc(capacity, sizeof(ane_folder));
    if (!folders) return NULL;

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        if (*count >= capacity) {
            capacity *= 2;
            ane_folder *nf = (ane_folder *)realloc(folders,
                capacity * sizeof(ane_folder));
            if (!nf) break;
            folders = nf;
        }

        ane_folder *f = &folders[*count];
        f->pk = sqlite3_column_int64(stmt, 0);
        f->title = _strdup_col(stmt, 1);
        f->parent_pk = is_legacy ? -1
            : (sqlite3_column_type(stmt, 2) == SQLITE_NULL
                ? -1
                : sqlite3_column_int64(stmt, 2));
        f->account_pk = sqlite3_column_int64(stmt, is_legacy ? 2 : 3);
        f->account_id = NULL;  /* resolved later by caller */

        (*count)++;
    }

    return folders;
}

/* ── Note queries ──────────────────────────────────────────── */

static ane_note *_fetch_notes_impl(ane_db *db, sqlite3_stmt *stmt,
                                    size_t *count)
{
    if (!db || !stmt || !count) return NULL;
    *count = 0;

    int has_password = _has_column(db, "ZPASSWORDPROTECTED");
    sqlite3_reset(stmt);

    size_t capacity = 256;
    ane_note *notes = (ane_note *)calloc(capacity, sizeof(ane_note));
    if (!notes) return NULL;

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        if (*count >= capacity) {
            capacity *= 2;
            ane_note *nn = (ane_note *)realloc(notes,
                capacity * sizeof(ane_note));
            if (!nn) break;
            notes = nn;
        }

        ane_note *n = &notes[*count];
        n->pk = sqlite3_column_int64(stmt, 0);
        n->title = _strdup_col(stmt, 1);
        n->creation_date = sqlite3_column_double(stmt, 2);
        n->modification_date = sqlite3_column_double(stmt, 3);
        n->folder_title = NULL;
        n->account_name = NULL;
        n->account_identifier = NULL;
        n->is_legacy = 0;

        /* FOLDER_ID -- column 4 */
        n->folder_pk = (sqlite3_column_type(stmt, 4) == SQLITE_NULL)
            ? -1
            : sqlite3_column_int64(stmt, 4);

        /* ACCOUNT_FK -- column 5 */
        n->account_pk = (sqlite3_column_type(stmt, 5) == SQLITE_NULL)
            ? -1
            : sqlite3_column_int64(stmt, 5);

        /* ZDATA (protobuf blob) -- column 6 for modern */
        n->protobuf_data = _blobdup_col(stmt, 6, &n->protobuf_len);

        /* ZISPINNED -- column 7 for modern */
        n->is_pinned = sqlite3_column_int(stmt, 7);

        /* ZPASSWORDPROTECTED -- column 8 if present */
        n->is_password_protected = has_password
            ? sqlite3_column_int(stmt, 8)
            : 0;

        (*count)++;
    }

    return notes;
}

static ane_note *_fetch_legacy_notes(ane_db *db, size_t *count)
{
    if (!db || !count) return NULL;
    *count = 0;

    sqlite3_stmt *stmt = db->stmts[STMT_LEGACY_NOTES];
    if (!stmt) return NULL;

    sqlite3_reset(stmt);

    size_t capacity = 256;
    ane_note *notes = (ane_note *)calloc(capacity, sizeof(ane_note));
    if (!notes) return NULL;

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        if (*count >= capacity) {
            capacity *= 2;
            ane_note *nn = (ane_note *)realloc(notes,
                capacity * sizeof(ane_note));
            if (!nn) break;
            notes = nn;
        }

        ane_note *n = &notes[*count];
        n->pk = sqlite3_column_int64(stmt, 0);
        /*
         * Legacy query column order:
         *  0: Z_PK, 1: ZCREATIONDATE1, 2: ZMODIFICATIONDATE1,
         *  3: ZTITLE1, 4: ZDATA (raw text), 5: ZFOLDER,
         *  6: ZACCOUNT, 7: ZISPINNED (always 0)
         */
        n->creation_date = sqlite3_column_double(stmt, 1);
        n->modification_date = sqlite3_column_double(stmt, 2);
        n->title = _strdup_col(stmt, 3);

        /* Legacy ZDATA is raw text content, not gzipped protobuf */
        const unsigned char *text = sqlite3_column_text(stmt, 4);
        if (text) {
            size_t len = strlen((const char *)text);
            n->protobuf_data = (uint8_t *)malloc(len);
            if (n->protobuf_data) {
                memcpy(n->protobuf_data, text, len);
                n->protobuf_len = len;
            }
        } else {
            n->protobuf_data = NULL;
            n->protobuf_len = 0;
        }

        n->folder_title = NULL;
        n->account_name = NULL;
        n->account_identifier = NULL;
        n->is_password_protected = 0;
        n->is_pinned = 0;
        n->is_legacy = 1;

        /* Legacy columns: 5=ZFOLDER (ZSTORE.Z_PK), 6=ZACCOUNT */
        n->folder_pk = (sqlite3_column_type(stmt, 5) == SQLITE_NULL)
            ? -1
            : sqlite3_column_int64(stmt, 5);
        n->account_pk = (sqlite3_column_type(stmt, 6) == SQLITE_NULL)
            ? -1
            : sqlite3_column_int64(stmt, 6);

        (*count)++;
    }

    return notes;
}

ane_note *ane_fetch_notes(ane_db *db, size_t *count)
{
    if (!db || !count) return NULL;

    if (db->version == ANE_VERSION_LEGACY)
        return _fetch_legacy_notes(db, count);

    return _fetch_notes_impl(db, db->stmts[STMT_NOTES], count);
}

ane_note *ane_fetch_notes_in_range(ane_db *db,
                                    double range_start_unix,
                                    double range_end_unix,
                                    size_t *count)
{
    if (!db || !count) return NULL;
    *count = 0;

    /* Legacy doesn't support date range filtering */
    if (db->version == ANE_VERSION_LEGACY)
        return _fetch_legacy_notes(db, count);

    /* iOS 11 doesn't have the range statement */
    if (db->version == ANE_VERSION_IOS11)
        return _fetch_notes_impl(db, db->stmts[STMT_NOTES], count);

    sqlite3_stmt *stmt = db->stmts[STMT_NOTES_RANGE];
    if (!stmt) return ane_fetch_notes(db, count);

    /* Convert Unix timestamps to CoreTime */
    double start_core = range_start_unix > 0
        ? range_start_unix - ANE_CORETIME_EPOCH
        : 0;
    double end_core = range_end_unix > 0
        ? range_end_unix - ANE_CORETIME_EPOCH
        : (double)time(NULL) - ANE_CORETIME_EPOCH;

    sqlite3_reset(stmt);
    sqlite3_bind_double(stmt, 1, start_core);
    sqlite3_bind_double(stmt, 2, end_core);

    /* The range statement has the same column layout as STMT_NOTES */
    int has_password = _has_column(db, "ZPASSWORDPROTECTED");

    size_t capacity = 256;
    ane_note *notes = (ane_note *)calloc(capacity, sizeof(ane_note));
    if (!notes) return NULL;

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        if (*count >= capacity) {
            capacity *= 2;
            ane_note *nn = (ane_note *)realloc(notes,
                capacity * sizeof(ane_note));
            if (!nn) break;
            notes = nn;
        }

        ane_note *n = &notes[*count];
        n->pk = sqlite3_column_int64(stmt, 0);
        n->title = _strdup_col(stmt, 1);
        n->creation_date = sqlite3_column_double(stmt, 2);
        n->modification_date = sqlite3_column_double(stmt, 3);
        n->folder_title = NULL;
        n->account_name = NULL;
        n->account_identifier = NULL;
        n->is_legacy = 0;

        /* FOLDER_ID -- column 4 */
        n->folder_pk = (sqlite3_column_type(stmt, 4) == SQLITE_NULL)
            ? -1
            : sqlite3_column_int64(stmt, 4);

        /* ACCOUNT_FK -- column 5 */
        n->account_pk = (sqlite3_column_type(stmt, 5) == SQLITE_NULL)
            ? -1
            : sqlite3_column_int64(stmt, 5);

        n->protobuf_data = _blobdup_col(stmt, 6, &n->protobuf_len);
        n->is_pinned = sqlite3_column_int(stmt, 7);
        n->is_password_protected = has_password
            ? sqlite3_column_int(stmt, 8)
            : 0;

        (*count)++;
    }

    return notes;
}

/* ── Attachment ownership validation ────────────────────────── */

int ane_validate_attachment_owner(ane_db *db,
                                   const char *attachment_uuid,
                                   int64_t note_pk)
{
    if (!db || !attachment_uuid) return 0;

    /* Legacy databases don't have ICAttachment entities */
    if (db->version == ANE_VERSION_LEGACY) return 1;

    sqlite3_stmt *stmt = db->stmts[STMT_VALIDATE_ATT_OWNER];
    if (!stmt) return 1;  /* If we can't validate, assume valid */

    sqlite3_reset(stmt);
    sqlite3_bind_text(stmt, 1, attachment_uuid, -1, SQLITE_STATIC);
    sqlite3_bind_int64(stmt, 2, note_pk);

    return (sqlite3_step(stmt) == SQLITE_ROW) ? 1 : 0;
}

/* ── UTI classification ────────────────────────────────────── */

ane_uti_class ane_classify_uti(const char *uti)
{
    if (!uti || !*uti) return ANE_UTI_UNKNOWN;

    /* Inline attachment subtypes (prefix match) */
    if (strncmp(uti, "com.apple.notes.inlinetextattachment.", 36) == 0) {
        const char *sub = uti + 36;
        if (strcmp(sub, "hashtag") == 0) return ANE_UTI_INLINE_HASHTAG;
        if (strcmp(sub, "mention") == 0) return ANE_UTI_INLINE_MENTION;
        if (strcmp(sub, "link") == 0) return ANE_UTI_INLINE_LINK;
        if (strcmp(sub, "calculateresult") == 0) return ANE_UTI_INLINE_CALC_RESULT;
        if (strcmp(sub, "calculategraphexpression") == 0) return ANE_UTI_INLINE_CALC_GRAPH;
        return ANE_UTI_INLINE_UNKNOWN;
    }

    /* Exact-match Apple Notes types */
    if (strcmp(uti, "com.apple.notes.gallery") == 0) return ANE_UTI_GALLERY;
    if (strcmp(uti, "com.apple.notes.table") == 0) return ANE_UTI_TABLE;
    if (strcmp(uti, "com.apple.notes.sketch") == 0) return ANE_UTI_SKETCH;
    if (strcmp(uti, "com.apple.drawing.2") == 0) return ANE_UTI_DRAWING;
    if (strcmp(uti, "com.apple.drawing") == 0) return ANE_UTI_DRAWING;
    if (strcmp(uti, "com.apple.paper") == 0) return ANE_UTI_DRAWING;
    if (strcmp(uti, "com.apple.paper.doc.scan") == 0) return ANE_UTI_SCAN;
    if (strcmp(uti, "com.apple.paper.doc.pdf") == 0) return ANE_UTI_SCAN;

    /* URL */
    if (strcmp(uti, "public.url") == 0) return ANE_UTI_URL;

    /* PDF */
    if (strcmp(uti, "com.adobe.pdf") == 0) return ANE_UTI_PDF;

    /* vCard / Calendar */
    if (strcmp(uti, "public.vcard") == 0) return ANE_UTI_VCARD;
    if (strcmp(uti, "com.apple.ical.ics") == 0) return ANE_UTI_CALENDAR;

    /* Image types (25 exact matches) */
    if (strcmp(uti, "public.jpeg") == 0) return ANE_UTI_IMAGE;
    if (strcmp(uti, "public.png") == 0) return ANE_UTI_IMAGE;
    if (strcmp(uti, "public.tiff") == 0) return ANE_UTI_IMAGE;
    if (strcmp(uti, "public.heic") == 0) return ANE_UTI_IMAGE;
    if (strcmp(uti, "public.jpeg-2000") == 0) return ANE_UTI_IMAGE;
    if (strcmp(uti, "public.svg-image") == 0) return ANE_UTI_IMAGE;
    if (strcmp(uti, "public.xbitmap-image") == 0) return ANE_UTI_IMAGE;
    if (strcmp(uti, "public.camera-raw-image") == 0) return ANE_UTI_IMAGE;
    if (strcmp(uti, "public.fax") == 0) return ANE_UTI_IMAGE;
    if (strcmp(uti, "com.compuserve.gif") == 0) return ANE_UTI_IMAGE;
    if (strcmp(uti, "com.microsoft.bmp") == 0) return ANE_UTI_IMAGE;
    if (strcmp(uti, "com.microsoft.ico") == 0) return ANE_UTI_IMAGE;
    if (strcmp(uti, "com.adobe.photoshop-image") == 0) return ANE_UTI_IMAGE;
    if (strcmp(uti, "com.adobe.illustrator.ai-image") == 0) return ANE_UTI_IMAGE;
    if (strcmp(uti, "com.adobe.raw-image") == 0) return ANE_UTI_IMAGE;
    if (strcmp(uti, "com.apple.icns") == 0) return ANE_UTI_IMAGE;
    if (strcmp(uti, "com.apple.macpaint-image") == 0) return ANE_UTI_IMAGE;
    if (strcmp(uti, "com.apple.pict") == 0) return ANE_UTI_IMAGE;
    if (strcmp(uti, "com.apple.quicktime-image") == 0) return ANE_UTI_IMAGE;
    if (strcmp(uti, "com.ilm.openexr-image") == 0) return ANE_UTI_IMAGE;
    if (strcmp(uti, "com.kodak.flashpix.image") == 0) return ANE_UTI_IMAGE;
    if (strcmp(uti, "com.sgi.sgi-image") == 0) return ANE_UTI_IMAGE;
    if (strcmp(uti, "com.truevision.tga-image") == 0) return ANE_UTI_IMAGE;
    if (strcmp(uti, "org.webmproject.webp") == 0) return ANE_UTI_IMAGE;

    /* Audio/Visual (video) types (10) */
    if (strcmp(uti, "public.mpeg-4") == 0) return ANE_UTI_VIDEO;
    if (strcmp(uti, "public.mpeg") == 0) return ANE_UTI_VIDEO;
    if (strcmp(uti, "public.avi") == 0) return ANE_UTI_VIDEO;
    if (strcmp(uti, "public.mpeg-2-video") == 0) return ANE_UTI_VIDEO;
    if (strcmp(uti, "public.mpeg-2-transport-stream") == 0) return ANE_UTI_VIDEO;
    if (strcmp(uti, "public.mpeg-4-audio") == 0) return ANE_UTI_VIDEO;
    if (strcmp(uti, "com.apple.quicktime-movie") == 0) return ANE_UTI_VIDEO;
    if (strcmp(uti, "com.apple.m4v-video") == 0) return ANE_UTI_VIDEO;
    if (strcmp(uti, "com.apple.protected-mpeg-4-video") == 0) return ANE_UTI_VIDEO;
    if (strcmp(uti, "com.apple.protected-mpeg-4-audio") == 0) return ANE_UTI_VIDEO;

    /* Audio types (6) */
    if (strcmp(uti, "public.mp3") == 0) return ANE_UTI_AUDIO;
    if (strcmp(uti, "public.aiff-audio") == 0) return ANE_UTI_AUDIO;
    if (strcmp(uti, "public.midi-audio") == 0) return ANE_UTI_AUDIO;
    if (strcmp(uti, "com.apple.m4a-audio") == 0) return ANE_UTI_AUDIO;
    if (strcmp(uti, "com.microsoft.waveform-audio") == 0) return ANE_UTI_AUDIO;
    if (strcmp(uti, "org.xiph.ogg-audio") == 0) return ANE_UTI_AUDIO;

    /* Document types (12) */
    if (strcmp(uti, "com.apple.iwork.numbers.sffnumbers") == 0) return ANE_UTI_DOCUMENT;
    if (strcmp(uti, "com.apple.log") == 0) return ANE_UTI_DOCUMENT;
    if (strcmp(uti, "com.apple.rtfd") == 0) return ANE_UTI_DOCUMENT;
    if (strcmp(uti, "com.microsoft.word.doc") == 0) return ANE_UTI_DOCUMENT;
    if (strcmp(uti, "com.microsoft.excel.xls") == 0) return ANE_UTI_DOCUMENT;
    if (strcmp(uti, "com.microsoft.powerpoint.ppt") == 0) return ANE_UTI_DOCUMENT;
    if (strcmp(uti, "com.netscape.javascript-source") == 0) return ANE_UTI_DOCUMENT;
    if (strcmp(uti, "net.daringfireball.markdown") == 0) return ANE_UTI_DOCUMENT;
    if (strcmp(uti, "net.openvpn.formats.ovpn") == 0) return ANE_UTI_DOCUMENT;
    if (strcmp(uti, "org.idpf.epub-container") == 0) return ANE_UTI_DOCUMENT;
    if (strcmp(uti, "org.oasis-open.opendocument.text") == 0) return ANE_UTI_DOCUMENT;
    if (strcmp(uti, "org.openxmlformats.wordprocessingml.document") == 0) return ANE_UTI_DOCUMENT;

    /* Prefix-based catch-alls */
    if (strncmp(uti, "public.", 7) == 0) return ANE_UTI_PUBLIC_GENERIC;
    if (strncmp(uti, "dyn.", 4) == 0) return ANE_UTI_DYNAMIC;
    if (strcmp(uti, "com.apple.macbinary-archive") == 0) return ANE_UTI_PUBLIC_GENERIC;

    return ANE_UTI_UNKNOWN;
}

/* ── Generation resolution ─────────────────────────────────── */

char *ane_resolve_generation(ane_db *db, int64_t media_pk)
{
    if (!db || db->version < ANE_VERSION_IOS17) return NULL;

    sqlite3_stmt *stmt = db->stmts[STMT_GENERATION];
    if (!stmt) return NULL;

    sqlite3_reset(stmt);
    sqlite3_bind_int64(stmt, 1, media_pk);

    if (sqlite3_step(stmt) != SQLITE_ROW) return NULL;

    /* Priority: ZGENERATION > ZGENERATION1 > ZFALLBACKIMAGEGENERATION
     *         > ZFALLBACKPDFGENERATION > ZPAPERBUNDLEGENERATION */
    for (int col = 0; col < 5; col++) {
        if (sqlite3_column_type(stmt, col) != SQLITE_NULL) {
            const unsigned char *val = sqlite3_column_text(stmt, col);
            if (val && val[0]) return strdup((const char *)val);
        }
    }

    return NULL;
}

char *ane_resolve_fallback_image_generation(ane_db *db,
                                             const char *identifier)
{
    if (!db || !identifier || db->version < ANE_VERSION_IOS17) return NULL;

    sqlite3_stmt *stmt = db->stmts[STMT_FALLBACK_IMG_GEN];
    if (!stmt) return NULL;

    sqlite3_reset(stmt);
    sqlite3_bind_text(stmt, 1, identifier, -1, SQLITE_STATIC);

    if (sqlite3_step(stmt) != SQLITE_ROW) return NULL;
    return _strdup_col(stmt, 0);
}

char *ane_resolve_fallback_pdf_generation(ane_db *db,
                                           const char *identifier)
{
    if (!db || !identifier || db->version < ANE_VERSION_IOS17) return NULL;

    sqlite3_stmt *stmt = db->stmts[STMT_FALLBACK_PDF_GEN];
    if (!stmt) return NULL;

    sqlite3_reset(stmt);
    sqlite3_bind_text(stmt, 1, identifier, -1, SQLITE_STATIC);

    if (sqlite3_step(stmt) != SQLITE_ROW) return NULL;
    return _strdup_col(stmt, 0);
}

/* ── Lookup queries ────────────────────────────────────────── */

char *ane_get_identifier_for_pk(ane_db *db, int64_t pk)
{
    if (!db) return NULL;

    sqlite3_stmt *stmt = db->stmts[STMT_IDENTIFIER_FOR_PK];
    if (!stmt) return NULL;

    sqlite3_reset(stmt);
    sqlite3_bind_int64(stmt, 1, pk);

    if (sqlite3_step(stmt) != SQLITE_ROW) return NULL;
    return _strdup_col(stmt, 0);
}

int64_t ane_get_media_pk_for_identifier(ane_db *db,
                                         const char *identifier)
{
    if (!db || !identifier) return -1;

    sqlite3_stmt *stmt = db->stmts[STMT_MEDIA_PK_FOR_ID];
    if (!stmt) return -1;

    sqlite3_reset(stmt);
    sqlite3_bind_text(stmt, 1, identifier, -1, SQLITE_STATIC);

    if (sqlite3_step(stmt) != SQLITE_ROW) return -1;
    if (sqlite3_column_type(stmt, 0) == SQLITE_NULL) return -1;
    return sqlite3_column_int64(stmt, 0);
}

char *ane_get_media_uuid(ane_db *db, const char *identifier)
{
    if (!db || !identifier) return NULL;

    int64_t media_pk = ane_get_media_pk_for_identifier(db, identifier);
    if (media_pk < 0) return NULL;

    return ane_get_identifier_for_pk(db, media_pk);
}

char *ane_get_url_string(ane_db *db, const char *identifier)
{
    if (!db || !identifier) return NULL;

    sqlite3_stmt *stmt = db->stmts[STMT_URL_STRING];
    if (!stmt) return NULL;

    sqlite3_reset(stmt);
    sqlite3_bind_text(stmt, 1, identifier, -1, SQLITE_STATIC);

    if (sqlite3_step(stmt) != SQLITE_ROW) return NULL;
    return _strdup_col(stmt, 0);
}

char *ane_get_user_title(ane_db *db, int64_t pk)
{
    if (!db) return NULL;

    sqlite3_stmt *stmt = db->stmts[STMT_USER_TITLE];
    if (!stmt) return NULL;

    sqlite3_reset(stmt);
    sqlite3_bind_int64(stmt, 1, pk);

    if (sqlite3_step(stmt) != SQLITE_ROW) return NULL;
    return _strdup_col(stmt, 0);
}

ane_thumbnail *ane_fetch_thumbnails(ane_db *db, int64_t parent_pk,
                                     size_t *count)
{
    if (!db || !count) return NULL;
    *count = 0;

    sqlite3_stmt *stmt = db->stmts[STMT_THUMBNAILS];
    if (!stmt) return NULL;

    sqlite3_reset(stmt);
    sqlite3_bind_int64(stmt, 1, parent_pk);

    size_t capacity = 8;
    ane_thumbnail *thumbs = (ane_thumbnail *)calloc(capacity,
        sizeof(ane_thumbnail));
    if (!thumbs) return NULL;

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        if (*count >= capacity) {
            capacity *= 2;
            ane_thumbnail *nt = (ane_thumbnail *)realloc(thumbs,
                capacity * sizeof(ane_thumbnail));
            if (!nt) break;
            thumbs = nt;
        }

        ane_thumbnail *t = &thumbs[*count];
        t->pk = sqlite3_column_int64(stmt, 0);
        t->identifier = _strdup_col(stmt, 1);
        t->height = sqlite3_column_int(stmt, 2);
        t->width = sqlite3_column_int(stmt, 3);

        (*count)++;
    }

    return thumbs;
}

void ane_free_thumbnails(ane_thumbnail *thumbs, size_t count)
{
    if (!thumbs) return;
    for (size_t i = 0; i < count; i++)
        free(thumbs[i].identifier);
    free(thumbs);
}

uint8_t *ane_fetch_mergeable_data(ane_db *db, const char *identifier,
                                   size_t *out_len)
{
    if (!db || !identifier) {
        if (out_len) *out_len = 0;
        return NULL;
    }

    sqlite3_stmt *stmt = db->stmts[STMT_MERGEABLE_DATA];
    if (!stmt) {
        if (out_len) *out_len = 0;
        return NULL;
    }

    sqlite3_reset(stmt);
    sqlite3_bind_text(stmt, 1, identifier, -1, SQLITE_STATIC);

    if (sqlite3_step(stmt) != SQLITE_ROW) {
        if (out_len) *out_len = 0;
        return NULL;
    }

    return _blobdup_col(stmt, 0, out_len);
}

/* ── File system helpers ───────────────────────────────────── */

static char *_notes_container_path(void)
{
    const char *home = getenv("HOME");
    if (!home) return NULL;

    char *path = (char *)malloc(ANE_BUF_PATH);
    if (!path) return NULL;

    snprintf(path, ANE_BUF_PATH,
        "%s/Library/Group Containers/group.com.apple.notes", home);
    return path;
}

static int _file_exists(const char *path)
{
    struct stat st;
    return stat(path, &st) == 0 && S_ISREG(st.st_mode);
}

static uint8_t *_read_file(const char *path, size_t *out_len)
{
    if (!path || !out_len) return NULL;
    *out_len = 0;

    FILE *f = fopen(path, "rb");
    if (!f) return NULL;

    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    if (len <= 0) { fclose(f); return NULL; }
    fseek(f, 0, SEEK_SET);

    uint8_t *buf = (uint8_t *)malloc(len);
    if (!buf) { fclose(f); return NULL; }

    size_t read = fread(buf, 1, len, f);
    fclose(f);

    if (read != (size_t)len) { free(buf); return NULL; }
    *out_len = (size_t)len;
    return buf;
}

/**
 * Try multiple file path candidates. Returns data for the first
 * existing file. The paths array is NULL-terminated.
 */
static uint8_t *_try_paths(const char **paths, size_t *out_len,
                            char **out_filename)
{
    for (int i = 0; paths[i]; i++) {
        if (_file_exists(paths[i])) {
            uint8_t *data = _read_file(paths[i], out_len);
            if (data) {
                if (out_filename) {
                    /* Extract filename from path */
                    const char *slash = strrchr(paths[i], '/');
                    *out_filename = strdup(slash ? slash + 1 : paths[i]);
                }
                return data;
            }
        }
    }
    if (out_len) *out_len = 0;
    if (out_filename) *out_filename = NULL;
    return NULL;
}

/* ── Account directory enumeration ──────────────────────────── */
/* Scan Accounts/ to discover all account subdirectories.        */
/* Returns a NULL-terminated array of prefix strings like         */
/* "{container}/Accounts/{id}/". Caller must free each string    */
/* and the array itself.                                         */

static char **_enumerate_account_prefixes(const char *container,
                                           const char *skip_identifier,
                                           size_t *out_count)
{
    *out_count = 0;
    char accounts_dir[ANE_BUF_PATH];
    snprintf(accounts_dir, sizeof(accounts_dir), "%s/Accounts", container);

    DIR *dir = opendir(accounts_dir);
    if (!dir) return NULL;

    size_t cap = 17;
    char **prefixes = (char **)malloc(cap * sizeof(char *));
    if (!prefixes) { closedir(dir); return NULL; }

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        /* Skip . and .. */
        if (entry->d_name[0] == '.') continue;

        /* Skip the identifier we already tried */
        if (skip_identifier && strcmp(entry->d_name, skip_identifier) == 0)
            continue;

        /* Skip "LocalAccount" if that was the skip identifier */
        if (!skip_identifier && strcmp(entry->d_name, "LocalAccount") == 0)
            continue;

        /* Check it's a directory */
        char subdir[ANE_BUF_PATH];
        snprintf(subdir, sizeof(subdir), "%s/%s", accounts_dir, entry->d_name);
        struct stat st;
        if (stat(subdir, &st) != 0 || !S_ISDIR(st.st_mode)) continue;

        if (*out_count >= cap) {
            cap *= 2;
            char **np = (char **)realloc(prefixes, cap * sizeof(char *));
            if (!np) break;
            prefixes = np;
        }

        char buf[ANE_BUF_PATH];
        snprintf(buf, sizeof(buf), "%s/Accounts/%s/", container, entry->d_name);
        prefixes[*out_count] = strdup(buf);
        (*out_count)++;
    }
    closedir(dir);

    return prefixes;
}

static void _free_account_prefixes(char **prefixes, size_t count)
{
    if (!prefixes) return;
    for (size_t i = 0; i < count; i++)
        free(prefixes[i]);
    free(prefixes);
}

/* ── Fallback image path permutations ──────────────────────── */
/*                                                               */
/* Drawing attachments: FallbackImages/{uuid}.{ext}              */
/*                      FallbackImages/{uuid}/{gen}/FallbackImage.{ext} */
/* Extensions: jpeg, png, jpg                                    */

ane_attachment_data *ane_fetch_fallback_image(ane_db *db,
                                               const char *identifier,
                                               const char *account_identifier)
{
    if (!db || !identifier) return NULL;

    char *container = _notes_container_path();
    if (!container) return NULL;

    /* Get fallback image generation string */
    char *generation = ane_resolve_fallback_image_generation(db, identifier);

    static const char *extensions[] = { "jpeg", "png", "jpg", NULL };

    /* Search order (#27, #28):
     *   1. Account-specific: Accounts/{acct}/FallbackImages/{uuid}...
     *   2. Container root:   FallbackImages/{uuid}...
     *   3. All other account dirs (cross-account fallback)
     *
     * Tier 3 handles notes moved between accounts where the fallback
     * file was left behind in the original account folder. */
    const char *skip_id = (account_identifier && *account_identifier)
        ? account_identifier : "LocalAccount";

    /* Tier 1 + 2: account-specific and container root */
    char acct_prefix[ANE_BUF_PATH];
    snprintf(acct_prefix, sizeof(acct_prefix),
        "%s/Accounts/%s/", container, skip_id);

    char root_prefix[ANE_BUF_PATH];
    snprintf(root_prefix, sizeof(root_prefix), "%s/", container);

    /* Try tier 1 + 2 first (fast path, no directory enumeration) */
    {
        char path_buf[12][ANE_BUF_PATH];
        const char *paths[13];
        int n = 0;
        const char *tier12[] = { acct_prefix, root_prefix, NULL };

        for (int p = 0; tier12[p]; p++) {
            for (int e = 0; extensions[e]; e++) {
                snprintf(path_buf[n], sizeof(path_buf[n]),
                    "%sFallbackImages/%s.%s",
                    tier12[p], identifier, extensions[e]);
                paths[n] = path_buf[n]; n++;

                if (generation && *generation) {
                    snprintf(path_buf[n], sizeof(path_buf[n]),
                        "%sFallbackImages/%s/%s/FallbackImage.%s",
                        tier12[p], identifier, generation, extensions[e]);
                    paths[n] = path_buf[n]; n++;
                }
            }
        }
        paths[n] = NULL;

        size_t data_len = 0;
        char *filename = NULL;
        uint8_t *data = _try_paths(paths, &data_len, &filename);
        if (data) {
            free(container);
            free(generation);
            ane_attachment_data *result = (ane_attachment_data *)calloc(1,
                sizeof(ane_attachment_data));
            if (!result) { free(data); free(filename); return NULL; }
            result->data = data;
            result->len = data_len;
            result->filename = filename;
            result->uti = strdup("public.jpeg");
            return result;
        }
    }

    /* Tier 3: enumerate all other account directories */
    size_t other_count = 0;
    char **others = _enumerate_account_prefixes(container, skip_id, &other_count);
    if (others && other_count > 0) {
        for (size_t o = 0; o < other_count; o++) {
            char path_buf[6][ANE_BUF_PATH];
            const char *paths[7];
            int n = 0;

            for (int e = 0; extensions[e]; e++) {
                snprintf(path_buf[n], sizeof(path_buf[n]),
                    "%sFallbackImages/%s.%s",
                    others[o], identifier, extensions[e]);
                paths[n] = path_buf[n]; n++;

                if (generation && *generation) {
                    snprintf(path_buf[n], sizeof(path_buf[n]),
                        "%sFallbackImages/%s/%s/FallbackImage.%s",
                        others[o], identifier, generation, extensions[e]);
                    paths[n] = path_buf[n]; n++;
                }
            }
            paths[n] = NULL;

            size_t data_len = 0;
            char *filename = NULL;
            uint8_t *data = _try_paths(paths, &data_len, &filename);
            if (data) {
                _free_account_prefixes(others, other_count);
                free(container);
                free(generation);
                ane_attachment_data *result = (ane_attachment_data *)calloc(1,
                    sizeof(ane_attachment_data));
                if (!result) { free(data); free(filename); return NULL; }
                result->data = data;
                result->len = data_len;
                result->filename = filename;
                result->uti = strdup("public.jpeg");
                return result;
            }
        }
        _free_account_prefixes(others, other_count);
    }

    free(container);
    free(generation);
    return NULL;
}

/* ── Fallback PDF path permutations ────────────────────────── */
/*                                                               */
/* Scan attachments: FallbackPDFs/{uuid}.pdf                     */
/*                   FallbackPDFs/{uuid}/{gen}/FallbackPDF.pdf   */

ane_attachment_data *ane_fetch_fallback_pdf(ane_db *db,
                                             const char *identifier,
                                             const char *account_identifier)
{
    if (!db || !identifier) return NULL;

    char *container = _notes_container_path();
    if (!container) return NULL;

    char *generation = ane_resolve_fallback_pdf_generation(db, identifier);

    const char *skip_id = (account_identifier && *account_identifier)
        ? account_identifier : "LocalAccount";

    /* Tier 1: account-specific, Tier 2: container root */
    char acct_prefix[ANE_BUF_PATH];
    snprintf(acct_prefix, sizeof(acct_prefix),
        "%s/Accounts/%s/", container, skip_id);

    char root_prefix[ANE_BUF_PATH];
    snprintf(root_prefix, sizeof(root_prefix), "%s/", container);

    {
        char path_buf[4][ANE_BUF_PATH];
        const char *paths[5];
        int n = 0;
        const char *tier12[] = { acct_prefix, root_prefix, NULL };

        for (int p = 0; tier12[p]; p++) {
            snprintf(path_buf[n], sizeof(path_buf[n]),
                "%sFallbackPDFs/%s.pdf", tier12[p], identifier);
            paths[n] = path_buf[n]; n++;

            if (generation && *generation) {
                snprintf(path_buf[n], sizeof(path_buf[n]),
                    "%sFallbackPDFs/%s/%s/FallbackPDF.pdf",
                    tier12[p], identifier, generation);
                paths[n] = path_buf[n]; n++;
            }
        }
        paths[n] = NULL;

        size_t data_len = 0;
        char *filename = NULL;
        uint8_t *data = _try_paths(paths, &data_len, &filename);
        if (data) {
            free(container);
            free(generation);
            ane_attachment_data *result = (ane_attachment_data *)calloc(1,
                sizeof(ane_attachment_data));
            if (!result) { free(data); free(filename); return NULL; }
            result->data = data;
            result->len = data_len;
            result->filename = filename;
            result->uti = strdup("com.adobe.pdf");
            return result;
        }
    }

    /* Tier 3: enumerate all other account directories */
    size_t other_count = 0;
    char **others = _enumerate_account_prefixes(container, skip_id, &other_count);
    if (others && other_count > 0) {
        for (size_t o = 0; o < other_count; o++) {
            char path_buf[2][ANE_BUF_PATH];
            const char *paths[3];
            int n = 0;

            snprintf(path_buf[n], sizeof(path_buf[n]),
                "%sFallbackPDFs/%s.pdf", others[o], identifier);
            paths[n] = path_buf[n]; n++;

            if (generation && *generation) {
                snprintf(path_buf[n], sizeof(path_buf[n]),
                    "%sFallbackPDFs/%s/%s/FallbackPDF.pdf",
                    others[o], identifier, generation);
                paths[n] = path_buf[n]; n++;
            }
            paths[n] = NULL;

            size_t data_len = 0;
            char *filename = NULL;
            uint8_t *data = _try_paths(paths, &data_len, &filename);
            if (data) {
                _free_account_prefixes(others, other_count);
                free(container);
                free(generation);
                ane_attachment_data *result = (ane_attachment_data *)calloc(1,
                    sizeof(ane_attachment_data));
                if (!result) { free(data); free(filename); return NULL; }
                result->data = data;
                result->len = data_len;
                result->filename = filename;
                result->uti = strdup("com.adobe.pdf");
                return result;
            }
        }
        _free_account_prefixes(others, other_count);
    }

    free(container);
    free(generation);
    return NULL;
}

/* ── Media fetch (external file) ───────────────────────────── */

static ane_attachment_data *_fetch_media_file(ane_db *db,
                                               const char *media_uuid,
                                               const char *filename,
                                               const char *account_identifier)
{
    if (!db || !media_uuid) return NULL;

    char *container = _notes_container_path();
    if (!container) return NULL;

    const char *skip_id = (account_identifier && *account_identifier)
        ? account_identifier : "LocalAccount";

    /* Get generation for subdirectory path */
    int64_t media_pk = -1;
    char *generation = NULL;
    {
        sqlite3_stmt *pk_stmt = db->stmts[STMT_GALLERY_PK];
        if (pk_stmt) {
            sqlite3_reset(pk_stmt);
            sqlite3_bind_text(pk_stmt, 1, media_uuid, -1, SQLITE_STATIC);
            if (sqlite3_step(pk_stmt) == SQLITE_ROW) {
                media_pk = sqlite3_column_int64(pk_stmt, 0);
            }
        }
        if (media_pk >= 0) {
            generation = ane_resolve_generation(db, media_pk);
        }
    }

    const char *fname = filename ? filename : media_uuid;
    int has_alt_name = (filename && strcmp(filename, media_uuid) != 0);

    /* Helper macro for building media paths into a path array */
    #define MEDIA_PATHS(prefix, pb, pa, idx) do { \
        if (generation && *generation) { \
            snprintf(pb[idx], sizeof(pb[idx]), "%sMedia/%s/%s/%s", prefix, media_uuid, generation, fname); \
            pa[idx] = pb[idx]; idx++; \
        } \
        snprintf(pb[idx], sizeof(pb[idx]), "%sMedia/%s/%s", prefix, media_uuid, fname); \
        pa[idx] = pb[idx]; idx++; \
        if (has_alt_name) { \
            snprintf(pb[idx], sizeof(pb[idx]), "%sMedia/%s/%s", prefix, media_uuid, media_uuid); \
            pa[idx] = pb[idx]; idx++; \
        } \
    } while (0)

    /* Tier 1: account-specific, Tier 2: container root */
    char acct_prefix[ANE_BUF_PATH];
    snprintf(acct_prefix, sizeof(acct_prefix),
        "%s/Accounts/%s/", container, skip_id);

    char root_prefix[ANE_BUF_PATH];
    snprintf(root_prefix, sizeof(root_prefix), "%s/", container);

    {
        char path_buf[6][ANE_BUF_PATH];
        const char *paths[7];
        int n = 0;

        MEDIA_PATHS(acct_prefix, path_buf, paths, n);
        MEDIA_PATHS(root_prefix, path_buf, paths, n);
        paths[n] = NULL;

        size_t data_len = 0;
        char *out_filename = NULL;
        uint8_t *data = _try_paths(paths, &data_len, &out_filename);
        if (data) {
            free(container);
            free(generation);
            ane_attachment_data *result = (ane_attachment_data *)calloc(1,
                sizeof(ane_attachment_data));
            if (!result) { free(data); free(out_filename); return NULL; }
            result->data = data;
            result->len = data_len;
            result->filename = out_filename;
            result->uti = NULL;
            return result;
        }
    }

    /* Tier 3: enumerate all other account directories */
    size_t other_count = 0;
    char **others = _enumerate_account_prefixes(container, skip_id, &other_count);
    if (others && other_count > 0) {
        for (size_t o = 0; o < other_count; o++) {
            char path_buf[3][ANE_BUF_PATH];
            const char *paths[4];
            int n = 0;

            MEDIA_PATHS(others[o], path_buf, paths, n);
            paths[n] = NULL;

            size_t data_len = 0;
            char *out_filename = NULL;
            uint8_t *data = _try_paths(paths, &data_len, &out_filename);
            if (data) {
                _free_account_prefixes(others, other_count);
                free(container);
                free(generation);
                ane_attachment_data *result = (ane_attachment_data *)calloc(1,
                    sizeof(ane_attachment_data));
                if (!result) { free(data); free(out_filename); return NULL; }
                result->data = data;
                result->len = data_len;
                result->filename = out_filename;
                result->uti = NULL;
                return result;
            }
        }
        _free_account_prefixes(others, other_count);
    }

    #undef MEDIA_PATHS

    free(container);
    free(generation);
    return NULL;
}

ane_attachment_data *ane_fetch_media(ane_db *db, int64_t media_pk)
{
    if (!db) return NULL;

    sqlite3_stmt *stmt = db->stmts[STMT_MEDIA];
    if (!stmt) return NULL;

    sqlite3_reset(stmt);
    sqlite3_bind_int64(stmt, 1, media_pk);

    if (sqlite3_step(stmt) != SQLITE_ROW) return NULL;

    char *filename = _strdup_col(stmt, 0);
    if (!filename) return NULL;

    /* Get the ZIDENTIFIER for this media row */
    char *media_uuid = ane_get_identifier_for_pk(db, media_pk);

    /* We need the account identifier -- for now try without it */
    ane_attachment_data *result = _fetch_media_file(db, media_uuid,
        filename, NULL);

    if (result && !result->uti) {
        result->uti = NULL;  /* caller should set based on context */
    }
    if (result && !result->filename) {
        result->filename = filename;
    } else {
        free(filename);
    }

    free(media_uuid);
    return result;
}

/* ── Attachment resolution ─────────────────────────────────── */
/*                                                               */
/* Full 12-step resolution chain:                                */
/* 1. Look up attachment metadata (cache or SQL)                 */
/* 2. Get ZMEDIA, ZTYPEUTI, ZFILENAME, account                  */
/* 3. Classify UTI                                               */
/* 4. Drawing -> fallback image                                  */
/* 5. Scan -> fallback PDF                                       */
/* 6. Gallery -> delegate to gallery children                    */
/* 7. Table -> return mergeable data                             */
/* 8. URL -> return URL data                                     */
/* 9. ZMEDIA null -> try by filename on disk                     */
/* 10. ZMEDIA not null -> fetch media file                       */
/* 11. Build result with data + filename + UTI                   */
/* 12. Return or NULL                                            */

ane_attachment_data *ane_fetch_attachment(ane_db *db,
                                          const char *identifier,
                                          const char *account_identifier)
{
    if (!db || !identifier) return NULL;

    /* Step 1: Get metadata -- try cache first, then SQL */
    const ane_attachment_meta *cached = ane_lookup_attachment(db, identifier);

    char *type_uti = NULL;
    char *att_filename = NULL;
    char *acct_id = NULL;
    int64_t media_pk = -1;

    if (cached) {
        type_uti = cached->type_uti ? strdup(cached->type_uti) : NULL;
        att_filename = cached->filename ? strdup(cached->filename) : NULL;
        acct_id = cached->account_id ? strdup(cached->account_id) : NULL;
        media_pk = cached->media_pk;
    } else {
        /* SQL fallback */
        sqlite3_stmt *stmt = db->stmts[STMT_ATTACHMENT];
        if (!stmt) return NULL;

        sqlite3_reset(stmt);
        sqlite3_bind_text(stmt, 1, identifier, -1, SQLITE_STATIC);

        if (sqlite3_step(stmt) != SQLITE_ROW) return NULL;

        media_pk = sqlite3_column_type(stmt, 0) == SQLITE_NULL
            ? -1 : sqlite3_column_int64(stmt, 0);
        type_uti = _strdup_col(stmt, 1);
        att_filename = _strdup_col(stmt, 2);
        /* col 3 = ZIDENTIFIER (self), col 4 = account ZIDENTIFIER */
        acct_id = _strdup_col(stmt, 4);
    }

    /* Use provided account_identifier if available */
    const char *effective_acct = account_identifier;
    if (!effective_acct || !*effective_acct) {
        effective_acct = acct_id;
    }

    /* Step 3: Classify UTI */
    ane_uti_class cls = ane_classify_uti(type_uti);

    ane_attachment_data *result = NULL;

    switch (cls) {
    case ANE_UTI_DRAWING:
    case ANE_UTI_SKETCH:
        /* Step 4: Drawing -> fallback image */
        result = ane_fetch_fallback_image(db, identifier, effective_acct);
        break;

    case ANE_UTI_SCAN:
        /* Step 5: Scan -> fallback PDF */
        result = ane_fetch_fallback_pdf(db, identifier, effective_acct);
        break;

    case ANE_UTI_GALLERY:
    case ANE_UTI_TABLE:
        /* Gallery and table are container types -- no file data.
         * The Swift layer handles these via mergeable data. */
        break;

    default:
        /* Step 9/10: Regular attachment -- fetch via media or filename */
        if (media_pk >= 0) {
            /* Get media UUID for file path resolution */
            char *media_uuid = ane_get_identifier_for_pk(db, media_pk);

            /* Get media filename */
            sqlite3_stmt *media_stmt = db->stmts[STMT_MEDIA];
            char *media_filename = NULL;
            if (media_stmt) {
                sqlite3_reset(media_stmt);
                sqlite3_bind_int64(media_stmt, 1, media_pk);
                if (sqlite3_step(media_stmt) == SQLITE_ROW) {
                    media_filename = _strdup_col(media_stmt, 0);
                }
            }

            result = _fetch_media_file(db, media_uuid,
                media_filename ? media_filename : att_filename,
                effective_acct);

            free(media_uuid);
            free(media_filename);
        }
        break;
    }

    /* Set UTI on result if we have one */
    if (result && !result->uti && type_uti) {
        result->uti = strdup(type_uti);
    }

    free(type_uti);
    free(att_filename);
    free(acct_id);

    return result;
}

/* ── Inline attachment ─────────────────────────────────────── */

ane_inline_attachment *ane_fetch_inline_attachment(ane_db *db,
                                                   const char *uuid)
{
    if (!db || !uuid) return NULL;

    sqlite3_stmt *stmt = db->stmts[STMT_INLINE_ATTACHMENT];
    if (!stmt) return NULL;

    sqlite3_reset(stmt);
    sqlite3_bind_text(stmt, 1, uuid, -1, SQLITE_STATIC);

    if (sqlite3_step(stmt) != SQLITE_ROW) return NULL;

    ane_inline_attachment *att = (ane_inline_attachment *)calloc(1,
        sizeof(ane_inline_attachment));
    if (!att) return NULL;

    att->alt_text = _strdup_col(stmt, 0);
    att->token_identifier = _strdup_col(stmt, 1);

    /* Classify the inline subtype from TYPEUTI column */
    char *uti = _strdup_col(stmt, 2);
    att->uti_class = ane_classify_uti(uti);
    free(uti);

    return att;
}

void ane_free_inline_attachment(ane_inline_attachment *att)
{
    if (!att) return;
    free(att->alt_text);
    free(att->token_identifier);
    free(att);
}

/* ── URL data ──────────────────────────────────────────────── */

ane_url_data *ane_fetch_url_data(ane_db *db, const char *identifier)
{
    if (!db || !identifier) return NULL;

    sqlite3_stmt *stmt = db->stmts[STMT_URL_DATA];
    if (!stmt) return NULL;

    sqlite3_reset(stmt);
    sqlite3_bind_text(stmt, 1, identifier, -1, SQLITE_STATIC);

    if (sqlite3_step(stmt) != SQLITE_ROW) return NULL;

    ane_url_data *data = (ane_url_data *)calloc(1, sizeof(ane_url_data));
    if (!data) return NULL;

    /*
     * Column order from prepared statement:
     *  0: ZMERGEABLEDATA/ZMERGEABLEDATA1
     *  1: ZTITLE2/ZTITLE1/ZTITLE
     *  2: ZALTTEXT
     *  3: ZURLSTRING
     */
    data->mergeable_data = _blobdup_col(stmt, 0, &data->mergeable_data_len);
    data->title = _strdup_col(stmt, 1);
    data->alt_text = _strdup_col(stmt, 2);
    data->url_string = _strdup_col(stmt, 3);

    return data;
}

void ane_free_url_data(ane_url_data *data)
{
    if (!data) return;
    free(data->title);
    free(data->alt_text);
    free(data->url_string);
    free(data->mergeable_data);
    free(data);
}

/* ── Gallery queries ───────────────────────────────────────── */

ane_gallery_child *ane_fetch_gallery_children(ane_db *db,
                                              const char *gallery_id,
                                              const char *account_id,
                                              size_t *count)
{
    (void)account_id;  /* reserved for future media file resolution */
    if (!db || !gallery_id || !count) return NULL;
    *count = 0;

    /* Step 1: Resolve gallery Z_PK */
    sqlite3_stmt *pk_stmt = db->stmts[STMT_GALLERY_PK];
    if (!pk_stmt) return NULL;

    sqlite3_reset(pk_stmt);
    sqlite3_bind_text(pk_stmt, 1, gallery_id, -1, SQLITE_STATIC);

    if (sqlite3_step(pk_stmt) != SQLITE_ROW) return NULL;
    int64_t gallery_pk = sqlite3_column_int64(pk_stmt, 0);

    /* Step 2: Fetch children */
    sqlite3_stmt *child_stmt = db->stmts[STMT_GALLERY_CHILDREN];
    if (!child_stmt) return NULL;

    sqlite3_reset(child_stmt);
    sqlite3_bind_int64(child_stmt, 1, gallery_pk);

    size_t capacity = 16;
    ane_gallery_child *children = (ane_gallery_child *)calloc(capacity,
        sizeof(ane_gallery_child));
    if (!children) return NULL;

    while (sqlite3_step(child_stmt) == SQLITE_ROW) {
        if (*count >= capacity) {
            capacity *= 2;
            ane_gallery_child *nc = (ane_gallery_child *)realloc(children,
                capacity * sizeof(ane_gallery_child));
            if (!nc) break;
            children = nc;
        }

        ane_gallery_child *c = &children[*count];
        c->identifier = _strdup_col(child_stmt, 0);
        c->type_uti = _strdup_col(child_stmt, 1);
        c->filename = _strdup_col(child_stmt, 2);

        /* Resolve child data via media fetch */
        int64_t child_media_pk = sqlite3_column_type(child_stmt, 3) == SQLITE_NULL
            ? -1 : sqlite3_column_int64(child_stmt, 3);

        c->data = NULL;
        c->data_len = 0;

        if (child_media_pk >= 0) {
            ane_attachment_data *child_data = ane_fetch_media(db, child_media_pk);
            if (child_data) {
                c->data = child_data->data;
                c->data_len = child_data->len;
                child_data->data = NULL;  /* transfer ownership */
                ane_free_attachment_data(child_data);
            }
        }

        (*count)++;
    }

    return children;
}

void ane_free_gallery_children(ane_gallery_child *children, size_t count)
{
    if (!children) return;
    for (size_t i = 0; i < count; i++) {
        free(children[i].identifier);
        free(children[i].type_uti);
        free(children[i].filename);
        free(children[i].data);
    }
    free(children);
}

/* ── Attachment prefetch ───────────────────────────────────── */

int ane_prefetch_attachments(ane_db *db)
{
    if (!db) return -1;

    _att_map_free(&db->att_cache);

    sqlite3_stmt *stmt = db->stmts[STMT_PREFETCH_ATTACHMENTS];
    if (!stmt) return -1;

    int has_user_title = _has_column(db, "ZUSERTITLE");
    int has_size_dims = _has_column(db, "ZSIZEHEIGHT");

    sqlite3_reset(stmt);

    /* First pass: count rows for sizing */
    size_t row_count = 0;
    while (sqlite3_step(stmt) == SQLITE_ROW)
        row_count++;

    if (row_count == 0) return 0;

    size_t cap = (size_t)((double)row_count / ATT_MAP_LOAD_FACTOR) + 1;
    if (cap < ATT_MAP_INITIAL_CAP) cap = ATT_MAP_INITIAL_CAP;

    db->att_cache.entries = (ane_attachment_meta *)calloc(cap,
        sizeof(ane_attachment_meta));
    if (!db->att_cache.entries) return -1;
    db->att_cache.capacity = cap;
    db->att_cache.count = 0;

    /* Second pass: populate */
    sqlite3_reset(stmt);

    /*
     * Column order:
     *  0: att.ZIDENTIFIER
     *  1: att.ZTYPEUTI / ZTYPEUTI1 (AS TYPEUTI)
     *  2: att.ZFILENAME
     *  3: att.ZMEDIA
     *  4: media.ZFILENAME (AS MEDIA_FILENAME)
     *  5: acct.ZIDENTIFIER (AS ACCOUNT_ID)
     *  6: att.ZUSERTITLE (if present)
     *  7: att.ZSIZEHEIGHT (if present)
     *  8: att.ZSIZEWIDTH (if present)
     */
    int col_user_title = has_user_title ? 6 : -1;
    int col_size_h = -1, col_size_w = -1;
    if (has_size_dims) {
        col_size_h = has_user_title ? 7 : 6;
        col_size_w = has_user_title ? 8 : 7;
    }

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        ane_attachment_meta entry;
        memset(&entry, 0, sizeof(entry));

        entry.identifier = _strdup_col(stmt, 0);
        if (!entry.identifier) continue;

        entry.type_uti = _strdup_col(stmt, 1);
        entry.filename = _strdup_col(stmt, 2);
        entry.media_pk = sqlite3_column_type(stmt, 3) == SQLITE_NULL
            ? -1
            : sqlite3_column_int64(stmt, 3);
        entry.media_filename = _strdup_col(stmt, 4);
        entry.account_id = _strdup_col(stmt, 5);
        entry.user_title = col_user_title >= 0
            ? _strdup_col(stmt, col_user_title) : NULL;
        entry.size_height = col_size_h >= 0
            ? sqlite3_column_int(stmt, col_size_h) : 0;
        entry.size_width = col_size_w >= 0
            ? sqlite3_column_int(stmt, col_size_w) : 0;

        if (_att_map_put(&db->att_cache, &entry) != 0) {
            free(entry.identifier);
            free(entry.type_uti);
            free(entry.filename);
            free(entry.media_filename);
            free(entry.account_id);
            free(entry.user_title);
        }
    }

    return (int)db->att_cache.count;
}

const ane_attachment_meta *ane_lookup_attachment(const ane_db *db,
                                                 const char *identifier)
{
    if (!db || !identifier) return NULL;
    return _att_map_get(&db->att_cache, identifier);
}

void ane_free_attachment_cache(ane_db *db)
{
    if (!db) return;
    _att_map_free(&db->att_cache);
}

/* ── Memory management ─────────────────────────────────────── */

void ane_free_accounts(ane_account *accounts, size_t count)
{
    if (!accounts) return;
    for (size_t i = 0; i < count; i++) {
        free(accounts[i].identifier);
        free(accounts[i].name);
    }
    free(accounts);
}

void ane_free_folders(ane_folder *folders, size_t count)
{
    if (!folders) return;
    for (size_t i = 0; i < count; i++) {
        free(folders[i].title);
        free(folders[i].account_id);
    }
    free(folders);
}

void ane_free_notes(ane_note *notes, size_t count)
{
    if (!notes) return;
    for (size_t i = 0; i < count; i++) {
        free(notes[i].title);
        free(notes[i].folder_title);
        free(notes[i].account_name);
        free(notes[i].account_identifier);
        free(notes[i].protobuf_data);
    }
    free(notes);
}

void ane_free_attachment_data(ane_attachment_data *data)
{
    if (!data) return;
    free(data->data);
    free(data->filename);
    free(data->uti);
    free(data);
}
