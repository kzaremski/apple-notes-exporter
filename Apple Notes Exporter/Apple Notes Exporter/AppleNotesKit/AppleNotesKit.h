/*
 *  AppleNotesKit.h
 *  AppleNotesKit
 *
 *  Copyright (C) 2026 Konstantin Zaremski
 *
 *  This program is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation, either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

#ifndef ANE_PARSER_H
#define ANE_PARSER_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── Opaque database handle ────────────────────────────────── */

typedef struct ane_db ane_db;

/* ── Schema version (maps to iOS/macOS release) ────────────── */

typedef enum {
    ANE_VERSION_UNKNOWN  = -1,
    ANE_VERSION_LEGACY   =  8,   /* iOS 8: ZNOTE/ZNOTEBODY/ZSTORE tables */
    ANE_VERSION_IOS9     =  9,
    ANE_VERSION_IOS10    = 10,
    ANE_VERSION_IOS11    = 11,   /* Z_11NOTES join table */
    ANE_VERSION_IOS12    = 12,
    ANE_VERSION_IOS13    = 13,
    ANE_VERSION_IOS14    = 14,
    ANE_VERSION_IOS15    = 15,   /* ZTYPEUTI1, inline attachments */
    ANE_VERSION_IOS16    = 16,
    ANE_VERSION_IOS17    = 17,   /* ZGENERATION columns */
    ANE_VERSION_IOS18    = 18,
    ANE_VERSION_IOS26    = 26    /* ZATTRIBUTEDSNIPPET */
} ane_version;

/* ── CoreTime epoch offset ─────────────────────────────────── */
/* Apple CoreData stores dates as seconds since 2001-01-01.     */
/* Add this offset to convert to Unix time, subtract to convert */
/* from Unix time to CoreTime.                                  */

#define ANE_CORETIME_EPOCH 978307200

/* ── UTI classification ────────────────────────────────────── */

typedef enum {
    ANE_UTI_UNKNOWN = 0,
    ANE_UTI_IMAGE,
    ANE_UTI_AUDIO,
    ANE_UTI_VIDEO,
    ANE_UTI_DOCUMENT,
    ANE_UTI_PDF,
    ANE_UTI_URL,
    ANE_UTI_VCARD,
    ANE_UTI_CALENDAR,
    ANE_UTI_DRAWING,         /* com.apple.drawing, com.apple.drawing.2, com.apple.paper */
    ANE_UTI_SCAN,            /* com.apple.paper.doc.scan, com.apple.paper.doc.pdf */
    ANE_UTI_SKETCH,          /* com.apple.notes.sketch */
    ANE_UTI_TABLE,           /* com.apple.notes.table */
    ANE_UTI_GALLERY,         /* com.apple.notes.gallery */
    ANE_UTI_INLINE_HASHTAG,
    ANE_UTI_INLINE_MENTION,
    ANE_UTI_INLINE_LINK,
    ANE_UTI_INLINE_CALC_RESULT,
    ANE_UTI_INLINE_CALC_GRAPH,
    ANE_UTI_INLINE_UNKNOWN,  /* com.apple.notes.inlinetextattachment.* (unrecognized subtype) */
    ANE_UTI_PUBLIC_GENERIC,  /* public.* catch-all */
    ANE_UTI_DYNAMIC          /* dyn.* catch-all */
} ane_uti_class;

/* ── Result structures ─────────────────────────────────────── */

typedef struct {
    int64_t     pk;
    char       *identifier;       /* ZIDENTIFIER (UUID string) */
    char       *name;             /* ZNAME */
    int         account_type;     /* ZACCOUNTTYPE, -1 if column absent */
} ane_account;

typedef struct {
    int64_t     pk;
    char       *title;
    int64_t     parent_pk;        /* Z_PK of parent folder, -1 if root */
    int64_t     account_pk;       /* Z_PK of owning account */
    char       *account_id;       /* ZIDENTIFIER of owning account */
} ane_folder;

typedef struct {
    int64_t     pk;
    char       *title;
    char       *folder_title;
    char       *account_name;
    char       *account_identifier;
    double      creation_date;    /* Seconds since 2001-01-01 (NSDate ref) */
    double      modification_date;
    int64_t     folder_pk;        /* Z_PK of owning folder, -1 if unknown */
    int64_t     account_pk;       /* Z_PK of owning account, -1 if unknown */
    uint8_t    *protobuf_data;    /* Raw gzipped protobuf note body (ZDATA) */
    size_t      protobuf_len;
    int         is_password_protected;
    int         is_pinned;        /* ZISPINNED, 0 for legacy */
    int         is_legacy;        /* 1 if from legacy iOS 8 tables */
} ane_note;

typedef struct {
    uint8_t    *data;
    size_t      len;
    char       *filename;
    char       *uti;
} ane_attachment_data;

typedef struct {
    int64_t     pk;
    char       *identifier;
    int         height;           /* ZHEIGHT */
    int         width;            /* ZWIDTH */
} ane_thumbnail;

/* ── Lifecycle ─────────────────────────────────────────────── */

/**
 * Open a NoteStore.sqlite database.
 * Pass NULL for db_path to use the default system location.
 * Returns NULL on failure.
 */
ane_db *ane_open(const char *db_path);

/**
 * Close the database and free the handle.
 */
void ane_close(ane_db *db);

/**
 * Get the underlying sqlite3 handle for direct queries.
 * The returned pointer is owned by the ane_db and must NOT
 * be closed by the caller. Use for legacy code that needs
 * raw SQLite access (e.g., HTMLAttachmentProcessor, TableParser).
 */
void *ane_get_sqlite_handle(const ane_db *db);

/* ── Schema detection ──────────────────────────────────────── */

/**
 * Returns the detected schema version.
 * Must be called after ane_open().
 */
ane_version ane_get_version(const ane_db *db);

/**
 * Check if the database is a valid Apple Notes store.
 * Returns 1 if valid, 0 if not.
 */
int ane_is_valid(const ane_db *db);

/* ── Fetching ──────────────────────────────────────────────── */

/**
 * Fetch all accounts. Caller owns the returned array.
 * Sets *count to the number of results.
 * Returns NULL if no accounts found or on error.
 */
ane_account *ane_fetch_accounts(ane_db *db, size_t *count);

/**
 * Fetch all folders. Caller owns the returned array.
 */
ane_folder *ane_fetch_folders(ane_db *db, size_t *count);

/**
 * Fetch all non-deleted notes with protobuf body data.
 * Caller owns the returned array.
 */
ane_note *ane_fetch_notes(ane_db *db, size_t *count);

/**
 * Fetch notes modified within a date range (Unix timestamps).
 * Converts to CoreTime internally using ANE_CORETIME_EPOCH.
 * Pass 0 for range_start to mean "from the beginning".
 * Pass 0 for range_end to mean "until now".
 */
ane_note *ane_fetch_notes_in_range(ane_db *db,
                                    double range_start_unix,
                                    double range_end_unix,
                                    size_t *count);

/* ── Attachment prefetch cache ──────────────────────────────── */

/**
 * Prefetched attachment metadata for O(1) lookups.
 */
typedef struct {
    char    *identifier;        /* ZIDENTIFIER */
    char    *type_uti;          /* ZTYPEUTI (or ZTYPEUTI1 on iOS 15+) */
    char    *filename;          /* att.ZFILENAME */
    char    *media_filename;    /* media.ZFILENAME */
    char    *account_id;        /* acct.ZIDENTIFIER */
    char    *user_title;        /* ZUSERTITLE */
    int64_t  media_pk;          /* att.ZMEDIA (Z_PK), -1 if NULL */
    int      size_height;       /* ZSIZEHEIGHT */
    int      size_width;        /* ZSIZEWIDTH */
} ane_attachment_meta;

/**
 * Prefetch all attachment metadata in a single query.
 * Builds an internal hash map keyed by ZIDENTIFIER for O(1) lookups.
 * Call this once after ane_open(), before processing notes.
 * Returns the number of attachments cached, or -1 on error.
 */
int ane_prefetch_attachments(ane_db *db);

/**
 * Look up prefetched attachment metadata by ZIDENTIFIER.
 * Returns NULL if not found. The returned pointer is owned by the
 * cache and must NOT be freed by the caller.
 */
const ane_attachment_meta *ane_lookup_attachment(const ane_db *db,
                                                 const char *identifier);

/**
 * Free the prefetched attachment cache.
 * Called automatically by ane_close().
 */
void ane_free_attachment_cache(ane_db *db);

/* ── Attachment resolution ─────────────────────────────────── */

/**
 * Resolve an attachment by its ZIDENTIFIER string.
 * Performs the full 12-step resolution chain:
 *   query -> null check -> UTI routing -> fallback images/PDFs -> media fetch
 * If ane_prefetch_attachments() was called, uses the cache for the
 * initial metadata lookup (O(1) instead of a SQL query).
 * Returns NULL if attachment cannot be resolved.
 * Caller must free with ane_free_attachment_data().
 */
ane_attachment_data *ane_fetch_attachment(ane_db *db,
                                          const char *identifier,
                                          const char *account_identifier);

/**
 * Fetch media data by Z_PK of the ZMEDIA row.
 * Returns NULL if not found.
 */
ane_attachment_data *ane_fetch_media(ane_db *db, int64_t media_pk);

/**
 * Fetch fallback image for a drawing attachment.
 * Checks multiple path permutations:
 *   {uuid}.jpeg, {uuid}.png, {uuid}.jpg
 *   {uuid}/{generation}/FallbackImage.{ext}
 * Returns NULL if no fallback found.
 */
ane_attachment_data *ane_fetch_fallback_image(ane_db *db,
                                              const char *identifier,
                                              const char *account_identifier);

/**
 * Fetch fallback PDF for a scanned document attachment.
 * Checks: {uuid}.pdf, {uuid}/{generation}/FallbackPDF.pdf
 * Returns NULL if no fallback found.
 */
ane_attachment_data *ane_fetch_fallback_pdf(ane_db *db,
                                            const char *identifier,
                                            const char *account_identifier);

/* ── Attachment ownership validation ────────────────────────── */

/**
 * Validate that an attachment UUID belongs to a given note Z_PK.
 * Returns 1 if the attachment exists, is not deleted, and its
 * ZNOTE foreign key matches note_pk. Returns 0 otherwise.
 * Used to filter stale attachment references from protobuf data.
 */
int ane_validate_attachment_owner(ane_db *db,
                                   const char *attachment_uuid,
                                   int64_t note_pk);

/* ── UTI classification ────────────────────────────────────── */

/**
 * Classify a UTI string into an ane_uti_class enum.
 * Handles 70+ specific UTI types plus prefix-based classification.
 */
ane_uti_class ane_classify_uti(const char *uti);

/* ── Generation resolution ─────────────────────────────────── */

/**
 * Resolve the generation string for a media row (by Z_PK).
 * Checks 5 columns in priority order:
 *   ZGENERATION, ZGENERATION1, ZFALLBACKIMAGEGENERATION,
 *   ZFALLBACKPDFGENERATION, ZPAPERBUNDLEGENERATION
 * Only queries on iOS 17+, returns NULL on older versions.
 * Caller must free the returned string.
 */
char *ane_resolve_generation(ane_db *db, int64_t media_pk);

/**
 * Resolve the fallback image generation for an attachment by UUID.
 * Returns ZFALLBACKIMAGEGENERATION. Caller must free.
 */
char *ane_resolve_fallback_image_generation(ane_db *db,
                                             const char *identifier);

/**
 * Resolve the fallback PDF generation for an attachment by UUID.
 * Returns ZFALLBACKPDFGENERATION. Caller must free.
 */
char *ane_resolve_fallback_pdf_generation(ane_db *db,
                                           const char *identifier);

/* ── Lookup queries ────────────────────────────────────────── */

/**
 * Look up ZIDENTIFIER from Z_PK (reverse lookup).
 * Caller must free the returned string.
 */
char *ane_get_identifier_for_pk(ane_db *db, int64_t pk);

/**
 * Look up ZMEDIA Z_PK from the attachment's ZIDENTIFIER.
 * Returns -1 if not found.
 */
int64_t ane_get_media_pk_for_identifier(ane_db *db,
                                         const char *identifier);

/**
 * Two-step media UUID resolution: ZIDENTIFIER -> ZMEDIA -> ZIDENTIFIER.
 * Returns the media row's ZIDENTIFIER. Caller must free.
 */
char *ane_get_media_uuid(ane_db *db, const char *identifier);

/**
 * Look up ZURLSTRING for a public.url attachment.
 * Caller must free the returned string.
 */
char *ane_get_url_string(ane_db *db, const char *identifier);

/**
 * Look up ZUSERTITLE for an attachment by Z_PK.
 * Caller must free the returned string.
 */
char *ane_get_user_title(ane_db *db, int64_t pk);

/**
 * Fetch thumbnails for an attachment (by parent Z_PK).
 * Returns array sorted by area (height * width) ascending.
 * Caller must free with ane_free_thumbnails().
 */
ane_thumbnail *ane_fetch_thumbnails(ane_db *db, int64_t parent_pk,
                                     size_t *count);
void ane_free_thumbnails(ane_thumbnail *thumbs, size_t count);

/**
 * Fetch mergeable data blob by ZIDENTIFIER.
 * Automatically selects ZMERGEABLEDATA or ZMERGEABLEDATA1
 * based on schema version (< iOS 13 vs >= iOS 13).
 * Returns gzipped protobuf data. Caller must free.
 */
uint8_t *ane_fetch_mergeable_data(ane_db *db, const char *identifier,
                                   size_t *out_len);

/* ── Memory management ─────────────────────────────────────── */

void ane_free_accounts(ane_account *accounts, size_t count);
void ane_free_folders(ane_folder *folders, size_t count);
void ane_free_notes(ane_note *notes, size_t count);
void ane_free_attachment_data(ane_attachment_data *data);

/* ── Inline attachment queries ─────────────────────────────── */

typedef struct {
    char       *alt_text;
    char       *token_identifier;
    ane_uti_class uti_class;       /* specific inline subtype */
} ane_inline_attachment;

/**
 * Fetch inline attachment metadata by UUID.
 * Returns NULL if not found.
 */
ane_inline_attachment *ane_fetch_inline_attachment(ane_db *db,
                                                   const char *uuid);
void ane_free_inline_attachment(ane_inline_attachment *att);

/* ── URL/link card data ────────────────────────────────────── */

typedef struct {
    char    *title;
    char    *alt_text;
    char    *url_string;          /* ZURLSTRING */
    uint8_t *mergeable_data;
    size_t   mergeable_data_len;
} ane_url_data;

ane_url_data *ane_fetch_url_data(ane_db *db, const char *identifier);
void ane_free_url_data(ane_url_data *data);

/* ── Gallery queries ───────────────────────────────────────── */

typedef struct {
    char    *identifier;
    char    *type_uti;
    char    *filename;
    uint8_t *data;
    size_t   data_len;
} ane_gallery_child;

/**
 * Fetch all child attachments for a gallery container.
 * Returns NULL if gallery not found.
 */
ane_gallery_child *ane_fetch_gallery_children(ane_db *db,
                                              const char *gallery_id,
                                              const char *account_id,
                                              size_t *count);
void ane_free_gallery_children(ane_gallery_child *children, size_t count);

#ifdef __cplusplus
}
#endif

#endif /* ANE_PARSER_H */
