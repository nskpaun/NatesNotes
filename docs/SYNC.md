# Sync design decisions

Integration with Nathan's Personal File Sync server. The handoff requires five
decisions to be recorded in the app repository before coding; this is that
record, plus the reasoning behind each.

## 0. Ground rules inherited from the handoff

- The base URL lives at the transport boundary only (`SyncSettings.baseURL`),
  never in domain code. Default supplied at runtime — from the app's sync panel or
  `SYNC_BASE_URL` — never compiled in, so a public checkout carries no one's
  home-server address.
- TLS validation is never disabled and no private CA is installed — the
  deployment presents a publicly valid certificate, so the system default is
  exactly right. Verified: `ssl_verify_result=0` against the live host.
- The deployment's own limits are read from `GET /v1/capabilities` (currently
  `maxPageSize 500`, `maxMutationBatch 100`) and the engine clamps its page and
  batch sizes to them rather than trusting its compiled-in defaults.
- Errors come back as RFC 7807 problem documents carrying `code`, `requestId`
  and an explicit `retryable` flag. That flag beats guessing from the status
  code — only the server knows whether a given 5xx is worth another attempt —
  and the `requestId` is kept in the surfaced message so a failure here can be
  matched to a line in the server's log.
- The device token lives in the Keychain and nowhere else. Non-secret device and
  space metadata live in the app's sync state file.
- No live database is uploaded. Every independently editable record becomes its
  own deterministic JSON blob.

## 1. Which server space

One space per app: slug **`natesnotes`**, display name **"Nate's Notes"**.

```bash
./scripts/personal-sync-admin.sh create-space natesnotes "Nate's Notes"
./scripts/personal-sync-admin.sh create-pairing natesnotes write
```

A fresh pairing code per installation. The app never shares a space with
another app; nothing else understands this data model.

## 2. Entity → node mapping

```text
<root>/
  notes/<note-uuid>.json        application/vnd.natesnotes.note+json
  drawings/<drawing-uuid>.json  application/vnd.natesnotes.drawing+json
```

`appProperties`:

| Node | appProperties |
|---|---|
| `notes/…` | `{ "entityType": "note", "schemaVersion": 1 }` |
| `drawings/…` | `{ "entityType": "drawing", "schemaVersion": 1, "noteId": "<uuid>" }` |

**Why drawings are separate nodes rather than embedded in the note.** A drawing
is independently editable — you can redraw a diagram without touching a word of
prose. Giving it its own node means editing the sketch on one device and the
text on another produces two clean upserts instead of one conflict. It also
keeps note documents small, so a text edit doesn't re-upload a large diagram.
This is the handoff's `attachments/<uuid>.<ext>` pattern, specialised.

Note document (canonical JSON: keys sorted, no insignificant whitespace, UTF-8):

```json
{
  "body": "# Title\n\nMarkdown source, verbatim.",
  "createdAt": "2026-08-12T06:00:00.000Z",
  "drawingIds": ["0198f83e-4717-7c49-91f2-ee14cd18a171"],
  "emoji": "📝",
  "id": "0198f83e-4717-7c49-91f2-ee14cd18a171",
  "modifiedAt": "2026-08-12T06:00:00.000Z",
  "pinned": false,
  "schemaVersion": 1,
  "title": "Title"
}
```

`body` is the markdown source of truth. `title` is derived from the body and is
carried only so other clients and the server-side UI can label a note without
parsing markdown; on read it is recomputed and never merged.

Drawing document:

```json
{
  "elements": [ /* DrawElement, canonical field order */ ],
  "id": "…",
  "modifiedAt": "…",
  "noteId": "…",
  "schemaVersion": 1
}
```

Viewport state (`scrollX`, `scrollY`, `zoom`) is deliberately **excluded**. It's
local view state; syncing it would make panning a document mutation and cause
pointless blob churn and conflicts.

Unknown JSON fields in both document types are preserved on round-trip, so a
newer client's additions survive an older client rewriting the record.

## 3. Stable IDs

| Record | Permanent stable ID | Where it already lives |
|---|---|---|
| Note | `Note.id` (UUID) | `id:` in the `.md` front matter, and the filename |
| Drawing | `Drawing.id` (UUID) | key in the note's drawings sidecar, and `drawing://<id>` in the body |

Both predate sync — they are the identifiers the app already keys on, so no
migration and no identity remapping. Node IDs are separate UUIDv7 values minted
per node and held in the local mirror; renames and moves preserve them, exactly
as the server intends.

## 4. How local edits and deletions enter the outbox

Every mutation is recorded durably **before** any network work:

1. `NoteStore` mutates local state and writes its `.md`/sidecar as it always has.
2. The same call notifies `SyncController`, which serialises the record to
   canonical JSON and appends an outbox item — `{ clientMutationId (UUIDv7),
   recordKey, desired content, baseVersion, batch idempotency key, upload
   location, expected digest, committed offset }`.
3. The outbox is persisted with the rest of the sync state by an atomic
   write (temp file + rename), so a crash between steps 1 and 3 loses at most
   the last edit's *sync intent*, never the note itself — and the next full
   reconcile re-derives it from local content anyway.

Coalescing: repeated edits to a record collapse into the single **pending**
item for that record. An item that is already in flight is never rewritten
under its existing idempotency key; a follow-up edit becomes a new pending item
applied after the in-flight one settles. This is what keeps "never reuse a key
with a changed body" true under fast typing.

Deletions enqueue an explicit `delete` carrying the last applied `baseVersion`,
so a delete racing a remote edit surfaces as a conflict rather than silently
winning.

## 5. How the UI presents conflicts without losing either version

Conflicts never block the outbox and never overwrite anything.

Resolution runs three-way, against the last-synced content as the common base:

- Local unchanged from base → take the server version.
- Server unchanged from base → keep local.
- Different fields changed on each side (e.g. `pinned` here, `body` there) →
  field-wise merge, no user involvement.
- **Same field changed differently** → the local version stays in place, and the
  server's version is preserved as a **conflict copy**: a new note titled
  `<title> (conflict from <device>)` with its own fresh ID, which syncs back as
  an ordinary note so every device ends up holding both.

The UI surfaces this rather than hiding it: the sidebar badges the affected
note, and the note detail shows a bar — *"Also edited on <device>"* — with
**Open the other version**, **Keep mine**, and **Keep theirs**. Dismissing it
resolves nothing destructively; both notes remain.

Drawings are structured but effectively opaque to merge, so a conflicting
drawing keeps the local version live and retains the server's as a conflict-copy
drawing reachable from the same bar.

Timestamps are never the deciding factor. Ordering authority is the server's
`version`; `modifiedAt` is informational only.

## Local state

Persisted in `~/Library/Application Support/NatesNotes/sync/state.json`, written
atomically as a single transaction:

```text
installationId (UUIDv7)   spaceId, rootNodeId, folder node IDs
lastCommittedCursor       node mirror: id, version, parent, name, blobId, tombstone
outbox                    conflicts (local intent + server node)
recordIndex               per-record last-synced blob id (the merge base)
```

Verified blobs are cached by SHA-256 in `sync/blobs/`, written only after byte
count and digest both check out.

## Verified against the live server

Run on **12 August 2026** against the live deployment with
`--sync-smoke`, using a throwaway device that revoked its own token afterwards.
All 16 checks passed:

| Area | What was proven |
|---|---|
| Transport | Public TLS validates with system trust; `capabilities` reports `maxPageSize 500`, `maxMutationBatch 100` |
| Pairing | Code redeemed, token stored outside app state, `devices/current` validates |
| Snapshot | Initial sync completed and committed a cursor |
| Push | Blob uploaded via tus, then the file node created |
| Round trip | A second installation with no local state pulled **byte-identical** content, verified by SHA-256 |
| Edit | Propagated as a new version; the node id survived unchanged |
| Idempotence | Re-pushing identical bytes created no new node |
| Delete | Tombstone reached the second installation |
| Revocation | Token cleared locally, and the server rejected it afterwards |

Two harder paths are exercised by the smoke test but have not yet had a live
run — they are covered against the in-process server, which enforces the same
version checks and paging semantics (`test15`, `test16`):

- **Concurrent edit.** Device B writes, device A pushes from a stale
  `baseVersion`; A's write must be refused, A's bytes kept verbatim, B's bytes
  left intact on the server, and the resolution submitted against
  `currentNode.version`.
- **Paged snapshot.** A third installation snapshots two nodes at a time and
  must still assemble the tree completely before committing its cursor.

Four behaviours can only be tested against the fake server, because the live
one cannot be made to misbehave on demand: snapshot/cursor `410` expiry,
resuming an interrupted upload at the server-reported offset, `429`/5xx
backoff, and offline queueing across a restart.

## What is deliberately not implemented yet

- The SSE `events` hint channel. The engine pulls on launch, on foreground, on
  connectivity restoration, after pushes, and on a timer — all of which the
  handoff requires anyway, and events are explicitly never authoritative.
- Encryption (`encryption` is always `null`; the server field is preserved on
  round-trip).
