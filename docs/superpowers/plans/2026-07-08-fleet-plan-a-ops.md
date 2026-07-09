# Fleet Management — Plan A: mras-ops registry API (Phases 1–2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Orchestrator amendments (2026-07-08, from outside review — BINDING):**
> 1. **(I-1, audit-noise invariant)** In `patch_camera`/`patch_display` (and any future patch
>    helper), filter the journaled `changes` dict to fields where `from != to` before writing the
>    event. Full-form submits from the UI send every config field; without this filter the History
>    panel drowns in no-op "changes". Creates keep their `from: null` entries. Add a test: a PATCH
>    that re-sends an unchanged field journals only the genuinely changed ones (and a PATCH with
>    zero effective changes journals an event with an empty `changes` — or skips the event; pick
>    skipping, and return the row unchanged).
> 2. **(nit)** The adopt journaling's `__import__("json")` variant must be a normal top-level
>    `import json`.
> The outside review verified everything else as-written: all 8 Plan-B contract deltas absorbed,
> schema resolutions correct, indexes will be used, legacy PATCH /cameras preserved (the
> exclude_none→exclude_unset switch breaks no shipped test).

**Goal:** The registry read/write API that the Fleet page (Plan B) builds against. **P1 (read):** parent-scoped keyset lists (`GET /locations|/systems|/screen-groups|/cameras|/displays|/organizations`), per-object detail (`GET /{type}/{id}` → `{object_type, identity, config, state}` per spec §5.1), per-object audit trail (`GET /registry/audit`), `GET /unresolved-devices`, plus migration 028 (the `registry_admin`/`camera_admin` partial audit indexes). **P2 (device writes):** `POST /cameras`, `POST /displays` (D7 staged-offline, D8 devices-row creation), `PATCH /cameras/{id}` extended additively to full camera config (existing 3-field contract preserved), `PATCH /displays/{id}`, lifecycle-transition validation (D3 → 409 with allowed set), and — LAST and DROPPABLE — `POST /displays/adopt` (D11). P3/P4 endpoints (screen-group/container writes) are OUT.

**Architecture:** Extends the two established mras-ops idioms and nothing else. Writes follow `src/cameras.py`: strict pydantic `extra="forbid"` bodies, `FOR UPDATE` + `UPDATE` + journal INSERT in ONE transaction, enum values travel as text with server-side `::enum` casts, 400/404/409/422 split at the route. Reads follow `src/godview/systems.py`: plain SQL, dict rows, `::text` enum casts, `::float8` numeric casts, server-side counts, `LIMIT n+1` keyset probes with a NAME-keyed cursor. New code lives in a new `api/src/registry/` package (`paging.py`, `reads.py`, `lifecycle.py`, `writes.py`, `devices.py`, `adopt.py`); routes are registered in `src/main.py` like every existing route. Transition validation is a pure function module (no DB) so the matrix is unit-tested exhaustively.

**Tech Stack:** FastAPI + asyncpg + pydantic v2 (no ORM); pytest + pytest-asyncio (`asyncio_mode = auto`, module-scoped loops) against a throwaway Postgres created by `api/tests/conftest.py` (`projector_pool` applies every `db/migrations/*.sql` in sorted order); dockerized Postgres for live runs.

**Spec:** `/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-08-fleet-management-design.md` (all 15 decisions + §5.1 matrix LOCKED)
**Consumer:** `/Users/jn/code/minority_report_architecture/docs/superpowers/plans/2026-07-08-fleet-plan-b-ui.md` — its "Contract assumptions" A1–A13/E1–E4 were written against this plan sight-unseen; the Interfaces below match them except for the deltas listed first.

**Repo:** `/Users/jn/code/mras-ops`. ALL repo operations (branch, stage, commit) are delegated to the **git-flow-manager** subagent — never run raw VCS commands. One branch for this plan: `feat/fleet-registry-api` off `main`. Red-test commits are SEPARATE from implementation commits (`test:` commit first, then `feat:` — red→green visible in git history).
**Test command:** `cd /Users/jn/code/mras-ops/api && python -m pytest tests/<file> -q` (requires `cd /Users/jn/code/mras-ops && docker compose up -d postgres` once). Full suite: `python -m pytest tests -q`.
**Migration posture:** 028 is the next number. Initdb scripts only run on fresh volumes — the EXISTING dev DB gets 028 applied manually/standalone (same posture as 025/026/027); command in Task 1 and in the live-verification checklist.

## Global Constraints (binding decisions, verbatim from the spec)

- **D1 (spec-vs-status split):** "Every object's payload carries `config` (editable) and `state` (read-only: `last_seen_at`, effective duty for cameras, health rollups later). Write endpoints accept config fields only; state fields in a write body are schema-rejected (`extra="forbid"` — the `CameraPatch` precedent)."
- **D2 (field classes; §5.1 is the contract):** "IDENTITY — immutable via API forever: `id`, `device_id`, `serial_number`, `external_device_key`, `screen_id` (the wire key kiosks/vision report — changing it would silently orphan history), parent `system_id`/`location_id`/`organization_id` in v1. CONFIG — editable, journaled: `name` (a label — admin renames are legitimate device management and are journaled; *automation never renames*), roles, `screen_group_id` (same-system only), geo/zone/floor/timezone, type enums, `failover_eligible`, jsonb blobs. STATE — read-only: `last_seen_at`, effective duty, `seen_count`, timestamps." The §5.1 rows this plan implements:

  | Type | IDENTITY (immutable) | CONFIG (PATCHable) | STATE (read-only) |
  |---|---|---|---|
  | organization | id, parent_organization_id | name, organization_type, metadata, status* | created/updated_at |
  | location | id, parent_location_id | name, location_type, country/region/state/city/address, lat/lng, timezone, metadata, status* | created/updated_at |
  | system | id, organization_id, location_id | name, system_type, zone, floor, lat/lng, timezone, config, status* | created/updated_at |
  | screen_group | id, system_id, location_id | name, group_type, metadata, status* | created/updated_at |
  | camera | id, device_id, system_id, location_id, screen_id | name, camera_role, failover_eligible, screen_group_id (same-system), stream_url, calibration (incl. typed cam_index), status* | last_seen_at, effective duty |
  | display | id, device_id, system_id, location_id, screen_id | name, display_role, screen_group_id (same-system), resolution_width/height, calibration, status* | last_seen_at |

  (P1 serves detail for all six types; P2 writes touch cameras+displays only.)
- **D3 (lifecycle transitions — matrix written out concretely; this is what `src/registry/lifecycle.py` encodes):**
  "`status` changes go through the same PATCH but are validated against an allowed-transition matrix … Invalid transition ⇒ 409 with the allowed set."

  `device_status` (cameras, displays, devices):
  | from \ to | active | degraded | offline | retired |
  |---|---|---|---|---|
  | **active**   | (no-op) | YES | YES | YES |
  | **degraded** | YES | (no-op) | YES | YES |
  | **offline**  | YES | YES | (no-op) | YES |
  | **retired**  | NO | NO | NO | (no-op) |

  `lifecycle_status` (organizations, locations, systems, screen_groups — defined in the same pure module NOW so P3/P4 don't re-derive it; no P2 endpoint uses it yet):
  | from \ to | planned | active | inactive | degraded | offline | retired |
  |---|---|---|---|---|---|---|
  | **planned**  | (no-op) | YES | NO | NO | NO | YES |
  | **active**   | NO | (no-op) | YES | YES | YES | YES |
  | **inactive** | NO | YES | (no-op) | YES | YES | YES |
  | **degraded** | NO | YES | YES | (no-op) | YES | YES |
  | **offline**  | NO | YES | YES | YES | (no-op) | YES |
  | **retired**  | NO | NO | NO | NO | NO | (no-op) |

  Same-status writes are accepted as no-ops (idempotent PATCH — preserves the shipped camera contract where `{"status":"active"}` on an active camera succeeds). `retired` is terminal: nothing leaves it; its allowed set is `[]` and the 409 renders that.
- **D4 (no DELETE):** "No hard DELETE in v1 for any registry object. No DELETE routes are created. 'Remove' in the UI = retire (with guardrails)." (The adopt flow's `DELETE FROM unresolved_devices` is bookkeeping mandated by D11, not a registry object.)
- **D5 (retire guardrails):** "retiring an object with non-retired children is rejected with 409 + the first N blocking children (`{type, id, name, status}`)." In P2 this is vacuous — cameras/displays have no children — so device retires never 409-block. The E4 shape is reserved; the guardrail query lands with P3 (screen_groups), where an object first has children to check.
- **D7 (creation defaults are staged):** "new devices (device_status has no `planned`) start **`offline`** — visible in the Fleet page but not yet a live participant (the fleet launcher and the TODO-8 peer query select `active` only). Going live is an explicit lifecycle transition." POST bodies have NO `status` field (`extra="forbid"` rejects it); the INSERT hardcodes `'offline'`.
- **D8 (identity row at birth):** "Creating a camera/display also creates its `devices` identity row (same transaction) when `device_id` is not supplied; `serial_number`/`external_device_key` optional at birth, settable ONCE while NULL, immutable after." P2 accepts serial/external only at creation (there is no PATCH /devices in P1/P2, so once-while-NULL enforcement has no surface yet — it lands with the device-row endpoints later).
- **D9 (route style):** "extend the existing flat resource routes, no new namespace: GET/POST /cameras, /displays, /screen-groups, /systems, /locations, /organizations; PATCH /{type}/{id} each. The existing `PATCH /cameras/{camera_id}` contract is preserved exactly (its fields become a subset of the camera config PATCH). GET lists are parent-scoped … and keyset-paginated (name-keyed cursor, the God View systems precedent) with `counts` blocks — never unbounded."
- **D10 (audit):** "one generic `registry_admin` journal event for all new write endpoints: `{object_type, object_id, action: create|update|lifecycle|adopt, changes:{field:{from,to}}}`, emitted in the same transaction as the write (the `camera_admin` template). Cameras keep emitting `camera_admin` for the existing three fields (established consumer contract); documented as the one legacy exception … A partial expression index on `((payload->>'object_id'), id DESC) WHERE event_type='registry_admin'` (migration) serves per-object audit trails, same pattern as `events_camera_duty_idx`." Concretely: `PATCH /cameras/{id}` (pre-existing endpoint) keeps emitting `camera_admin`, its `changes` payload additively extended to whatever config fields were sent; every NEW endpoint (`POST /cameras`, `POST /displays`, `PATCH /displays/{id}`, `POST /displays/adopt`) emits `registry_admin`.
- **D11 (adopt, droppable):** "`GET /unresolved-devices` (list) and `POST /displays/adopt` `{unresolved_id, system_id, name?, screen_group_id?}` → creates the display with the unresolved row's `screen_id` pre-filled (status `offline`), deletes the unresolved row, journals `action: adopt`." Task 13 — the LAST task, droppable without touching anything else (`GET /unresolved-devices` ships in P1 regardless).
- **D15 (convergence by polling):** "camera config changes apply within one TODO-8 poll tick; display/kiosk config consumption is whatever the kiosk already does (no new push channel)." The API returns the updated ADMIN row from writes and never pretends runtime state changed; runtime truth lives only under `state`.
- **Auth (D14):** deliberately absent, same as every existing admin endpoint (single-operator dev posture).
- **conftest:** `godview_isolate`'s TRUNCATE list already covers every table these tests seed (`organizations, locations, systems, cameras, displays, screen_groups, devices, unresolved_devices, events` are all present) — **no conftest change needed**; verified against `/Users/jn/code/mras-ops/api/tests/conftest.py`.

## Interfaces

### Plan-B contract deltas (read FIRST — everything not listed here matches A1–A13/E1–E4 exactly)

1. **Duplicate `screen_id` → 409 with STRING detail.** `cameras.screen_id`/`displays.screen_id` carry GLOBAL UNIQUE constraints (migration 020 — the spec doesn't mention this). `POST /cameras`, `POST /displays`, `POST /displays/adopt` return `409 {"detail": "screen_id already registered"}` on collision — a string, not the E3/E4 object. Plan B's `conflictFrom409` degrades strings to message-only, so no UI change; listed because it is a new 409 shape.
2. **Adopt error strings:** `POST /displays/adopt` → `404 {"detail": "unresolved device not found"}`; `422 {"detail": "unresolved device is not a display"}` when the unresolved row's `kind` is `'camera'` (camera adoption is out of D11's scope).
3. **Device-scope XOR:** `GET /cameras` / `GET /displays` require EXACTLY ONE of `system_id` | `screen_group_id`; otherwise `422 {"detail": "provide exactly one of system_id or screen_group_id"}`. (Plan B always sends exactly one — A4/A5 comply already.)
4. **Explicit JSON `null` in PATCH bodies** is accepted only for nullable columns — camera: `name`, `screen_group_id`, `stream_url`; display: `name`, `screen_group_id`, `resolution_width`, `resolution_height`. Explicit null elsewhere → `422 {"detail": "<field> cannot be null"}`. Consequence for the legacy camera route: `{"status": null}` used to be dropped by `exclude_none` (→ 400 "no updatable fields"); it is now a 422. Values-or-omitted usage (all real clients, incl. Plan B) is byte-identical.
5. **E4 never fires in P2** (see D5): devices have no children, so no `retire_blocked` 409 exists yet. The shape stays locked for P3/P4.
6. **Additive extras (safe to ignore):** create/PATCH responses return the full updated row (a superset of Plan B's `{id, ...}` — Plan B reads only `ok` + `id`); POST bodies additionally accept optional `device_id`, `serial_number`, `external_device_key` (D8); unresolved-device items include `event_id`; `GET /registry/audit` also accepts `cursor` (stringified event id); `GET /unresolved-devices` accepts `cursor`/`limit`; organization list items include `parent_organization_id`.
7. **Camera PATCH journals `camera_admin`, not `registry_admin`** (D10 legacy exception) — invisible to Plan B because `GET /registry/audit` merges `registry_admin` + `camera_admin` + `camera_duty` (exactly what the History panel renders).
8. **Migration 028 adds a second index** (`events_camera_admin_idx` on `((payload->>'camera_id'), id DESC) WHERE event_type='camera_admin'`) beyond D10's literal text — required so the `camera_admin` branch of the audit merge is an index probe, not a journal scan (spec §6: "never a journal scan"). Same pattern, same migration.

### Endpoint contracts (exhaustive; Plan B builds against these)

All list envelopes: `{"counts": {"total": <int>}, "items": [...], "next_cursor": <string|null>}`.
All lists: `limit` clamped to 1..100 (default 50), ordered by `(COALESCE(name,''), id)` ASC with an opaque name-keyed cursor (`"<name>|<uuid>"`, decoded on the LAST `|` — names may contain pipes). Timestamps serialize ISO-8601 via FastAPI's encoder; uuids are strings inside `identity`/`config` maps.

```
GET /organizations?cursor&limit
  -> items: [{ id, name, organization_type, status, parent_organization_id }]
GET /locations?parent_location_id=root|<uuid>&cursor&limit          (default "root" = parent IS NULL)
  -> items: [{ id, name, location_type, status, child_location_count, system_count }]
GET /systems?location_id=<uuid>&cursor&limit                        (location_id REQUIRED -> 422 if absent)
  -> items: [{ id, name, system_type, status, device_count }]       (device_count = cameras + displays)
GET /screen-groups?system_id=<uuid>&cursor&limit                    (system_id REQUIRED)
  -> items: [{ id, name, group_type, status, device_count }]
GET /cameras?system_id=|screen_group_id=&cursor&limit               (exactly one — delta 3)
  -> items: [{ id, name, status, camera_role, failover_eligible, screen_group_id,
               screen_id, effective_duty, last_seen_at }]
GET /displays?system_id=|screen_group_id=&cursor&limit
  -> items: [{ id, name, status, display_role, screen_group_id, screen_id, last_seen_at }]

GET /organizations/{id} | /locations/{id} | /systems/{id} | /screen-groups/{id}
  | /cameras/{id} | /displays/{id}
  -> { object_type: "organization"|"location"|"system"|"screen_group"|"camera"|"display",
       identity: { <§5.1 IDENTITY row, uuids as strings> },
       config:   { <§5.1 CONFIG row; jsonb parsed to objects; status lives here> },
       state:    { created_at, updated_at, +last_seen_at (devices), +effective_duty (camera) } }
  404 {"detail": "<type> not found"} | 400 {"detail": "invalid id"}

GET /registry/audit?object_id=<str>&limit=20&cursor=<event-id>
  -> { items: [{ id, ts, event_type, payload }], next_cursor }      (payload = journal payload as-is)
     merges: registry_admin (payload object_id) + camera_admin (payload camera_id)
           + camera_duty (payload camera_id), newest-first by events.id

GET /unresolved-devices?cursor&limit
  -> { counts: {total}, items: [{ id, screen_id, kind, event_id, first_seen_at,
       last_seen_at, seen_count }], next_cursor }                   (last_seen_at DESC keyset)

PATCH /cameras/{id}   body ⊆ { name, camera_role, status, failover_eligible,
                               screen_group_id, stream_url, calibration }        -> 200 full row
PATCH /displays/{id}  body ⊆ { name, display_role, status, screen_group_id,
                               resolution_width, resolution_height, calibration } -> 200 full row
POST /cameras   { system_id, screen_id?, name?, camera_role?, failover_eligible?,
                  screen_group_id?, stream_url?, calibration?,
                  device_id?, serial_number?, external_device_key? }   -> 201 full row (status="offline")
POST /displays  { system_id, screen_id, name?, display_role?, screen_group_id?,
                  resolution_width?, resolution_height?, calibration?,
                  device_id?, serial_number?, external_device_key? }   -> 201 full row (status="offline")
POST /displays/adopt { unresolved_id, system_id, name?, screen_group_id? } -> 201 full display row

Errors (all endpoints):
  400 {"detail": "invalid id"} | {"detail": "no updatable fields provided"}
  404 {"detail": "<thing> not found"}
  422 pydantic  {"detail": [{loc, msg, type}, ...]}                            (E1)
  422 semantic  {"detail": "<string>"} — "screen_group must belong to the same system",
      "unknown system_id", "unknown screen_group_id", "unknown device_id",
      "<field> cannot be null", "unresolved device is not a display",
      "provide exactly one of system_id or screen_group_id"                    (E2)
  409 lifecycle {"detail": {"error": "invalid_transition", "from": "<status>",
                            "allowed": ["<status>", ...]}}                     (E3)
  409 unique    {"detail": "screen_id already registered"}                     (delta 1)
```

Journal payloads (locked by D10):
```
camera_admin   (legacy, PATCH /cameras only — payload shape unchanged, keys additive):
  { "camera_id": "<uuid>", "changes": { "<field>": {"from": .., "to": ..}, ... } }
registry_admin (all new writes):
  { "object_type": "camera"|"display", "object_id": "<uuid>",
    "action": "create"|"update"|"lifecycle"|"adopt",
    "changes": { "<field>": {"from": .., "to": ..}, ... },
    "adopted_from": { "unresolved_id": "<uuid>", "screen_id": "...", "seen_count": N } }   (adopt only)
```
`action` is `"lifecycle"` when the PATCH body was exactly `{status}`, else `"update"`; creates use `"create"` with `from: null` on every field. Scope columns (`system_id`, `camera_id`/`display_id`) are stamped on the events row, matching the `camera_admin` precedent.

### Spec-vs-schema mismatches (verified against db/migrations/; flagged per instructions)

1. **`devices.system_id` is `NOT NULL REFERENCES systems(id)`** (012) — spec §5.1's device row omits it from IDENTITY. Reality wins: D8's identity row is system-bound; we set it from the camera/display's `system_id` and treat it as IDENTITY (immutable).
2. **`devices.name` is `NOT NULL`** — spec lists `name` as device CONFIG but creation must supply one. D8 creation derives it: `body.name or body.screen_id or "camera"/"display"`.
3. **`screen_id` is globally UNIQUE** on both cameras and displays (020) — spec §3/§7 discuss immutability but not uniqueness. Drives delta 1 (409 on collision). Multiple cameras with NULL `screen_id` remain legal (SQL NULLs are distinct).
4. **`unresolved_devices` also has `event_id bigint`** (020) — additive to the spec's field list; exposed in items (delta 6).
5. **`camera_role` gains `'standby'` only in 027** — the pydantic Literals below match the post-027 enum (the shipped `CameraPatch` already does).
6. **lat/lng are `numeric`** (012) — read endpoints cast `::float8` (godview idiom) so JSON carries numbers, not strings.

### Abstraction judgment (stated, per plan discipline)

- **No generic patch/journal core parameterized by the field matrix.** For exactly two device types the parameterized core would replace two explicit, greppable UPDATE statements with SQL assembled from a spec table — harder to review and debug for zero net lines saved, and it would have to special-case the camera's legacy `camera_admin` event anyway. Extract it in P3/P4 when a third and fourth type would otherwise copy the pattern.
- **What IS shared (each earns its keep across ≥2 call sites today):** `registry/paging.py` (name cursor + page slicing — 6 lists); `registry/lifecycle.py` (pure transition matrix — camera + display PATCH now, containers later); `registry/writes.py` (`SemanticError`, `reject_nulls`, `build_set_clause` — needed because null-out of `screen_group_id` (ungroup) makes the shipped COALESCE style impossible; `ensure_same_system`; `journal_registry_admin` — display PATCH + 2 creates + adopt). `build_set_clause` interpolates COLUMN NAMES only from pydantic-validated field dicts (`extra="forbid"`), never raw input; values are always bind parameters.
- **The detail endpoint is table-driven** (`_DETAIL` dict of static SQL + identity/config/state key tuples): six types share one small function over static SQL strings — that is data, not dynamic SQL.
- **`decode_name_cursor` is written fresh in `registry/paging.py`, not imported from `godview/systems.py`:** the godview decoder splits on the FIRST `|` (breaks on names containing pipes) and is private to a shipped endpoint; the registry version splits on the LAST `|` and handles NULL device names (`COALESCE(name,'')` ordering). The godview endpoint is left untouched.

---

### Task 0: Preflight + branch

- [ ] **Step 1:** `cd /Users/jn/code/mras-ops && docker compose up -d postgres` (conftest needs it). Confirm the suite is green before touching anything: `cd /Users/jn/code/mras-ops/api && python -m pytest tests -q` — Expected: all pass.
- [ ] **Step 2 (git-flow-manager):** create branch `feat/fleet-registry-api` off `main`.

---

## Phase 1 — reads (P1): migration, paging, lists, detail, audit, unresolved

### Task 1: Migration 028 — `registry_admin` + `camera_admin` audit indexes (D10)

**Files:**
- Create: `/Users/jn/code/mras-ops/db/migrations/028_registry_admin_audit.sql`
- Create: `/Users/jn/code/mras-ops/api/tests/test_registry_migration.py`

- [ ] **Step 1: Write the failing tests**

```python
"""Migration 028: partial expression indexes for per-object audit trails (spec D10, §6).

Same pattern as 027's events_camera_duty_idx. projector_pool applies every
db/migrations/*.sql in sorted order, so these assert the file exists AND parses."""


async def test_registry_admin_partial_index_exists(projector_pool):
    idx = await projector_pool.fetchval(
        "SELECT indexdef FROM pg_indexes WHERE indexname = 'events_registry_admin_idx'")
    assert idx is not None
    assert "object_id" in idx
    assert "registry_admin" in idx          # partial: WHERE event_type = 'registry_admin'
    assert "DESC" in idx                    # (expr, id DESC) serves ORDER BY id DESC probes


async def test_camera_admin_partial_index_exists(projector_pool):
    idx = await projector_pool.fetchval(
        "SELECT indexdef FROM pg_indexes WHERE indexname = 'events_camera_admin_idx'")
    assert idx is not None
    assert "camera_id" in idx
    assert "camera_admin" in idx
```

Run: `cd /Users/jn/code/mras-ops/api && python -m pytest tests/test_registry_migration.py -q` — Expected: FAIL (2 failed — indexes absent).

- [ ] **Step 2 (git-flow-manager):** commit `test: migration 028 audit indexes (registry_admin + camera_admin)`

- [ ] **Step 3: Write the migration** `db/migrations/028_registry_admin_audit.sql`

```sql
-- db/migrations/028_registry_admin_audit.sql
-- Fleet P1/P2 (spec D10 / §6): per-object audit trails are latest-N INDEX PROBES,
-- never journal scans. Same partial-expression pattern as 027's
-- events_camera_duty_idx. Additive only; safe under the test harness's
-- sorted-order apply. For the EXISTING dev DB apply manually/standalone
-- (initdb scripts only run on fresh volumes — same posture as 025/026/027):
--   cd /Users/jn/code/mras-ops && \
--   docker compose exec -T postgres psql -U mras -d mras < db/migrations/028_registry_admin_audit.sql

-- D10: the generic registry_admin event, keyed by payload object_id.
CREATE INDEX IF NOT EXISTS events_registry_admin_idx
    ON events ((payload->>'object_id'), id DESC)
    WHERE event_type = 'registry_admin';

-- The one legacy exception (D10): PATCH /cameras keeps emitting camera_admin.
-- GET /registry/audit merges it by payload camera_id — index it the same way so
-- the camera branch of the merge is also a probe (spec §6: never a journal scan).
CREATE INDEX IF NOT EXISTS events_camera_admin_idx
    ON events ((payload->>'camera_id'), id DESC)
    WHERE event_type = 'camera_admin';
```

- [ ] **Step 4:** Re-run the test file — Expected: 2 passed (conftest rebuilds the throwaway DB per module, picking up 028 automatically).
- [ ] **Step 5 (git-flow-manager):** commit `feat: migration 028 — registry_admin/camera_admin partial audit indexes`

---

### Task 2: `registry/paging.py` — name-keyed keyset cursor (pure)

**Files:**
- Create: `/Users/jn/code/mras-ops/api/src/registry/__init__.py` (empty)
- Create: `/Users/jn/code/mras-ops/api/src/registry/paging.py`
- Create: `/Users/jn/code/mras-ops/api/tests/test_registry_paging.py`

- [ ] **Step 1: Write the failing tests**

```python
"""Name-keyed keyset cursor for registry lists (pure, no DB).

Distinct from godview/systems' private decoder: splits on the LAST '|' (names
may contain pipes; uuids never do) and encodes NULL names as '' to match the
lists' COALESCE(name,'') sort key."""
import uuid

from src.registry.paging import decode_name_cursor, encode_name_cursor, page


def test_roundtrip():
    rid = uuid.uuid4()
    assert decode_name_cursor(encode_name_cursor("Bay 2", rid)) == ("Bay 2", rid)


def test_empty_cursor_decodes_to_nones():
    assert decode_name_cursor(None) == (None, None)
    assert decode_name_cursor("") == (None, None)


def test_name_containing_pipes_survives():
    rid = uuid.uuid4()
    assert decode_name_cursor(encode_name_cursor("North|Wall|A", rid)) == ("North|Wall|A", rid)


def test_null_name_encodes_as_empty_string():
    rid = uuid.uuid4()
    assert decode_name_cursor(encode_name_cursor(None, rid)) == ("", rid)


def test_page_slices_limit_and_encodes_next_from_last_kept_row():
    rid = [uuid.uuid4() for _ in range(3)]
    rows = [{"name": "A", "id": rid[0]}, {"name": "B", "id": rid[1]}, {"name": "C", "id": rid[2]}]
    items, next_cursor = page(rows, 2)          # rows fetched with LIMIT limit+1
    assert [i["name"] for i in items] == ["A", "B"]
    assert next_cursor == f"B|{rid[1]}"


def test_page_final_page_has_no_cursor():
    rows = [{"name": "A", "id": uuid.uuid4()}]
    items, next_cursor = page(rows, 2)
    assert len(items) == 1 and next_cursor is None
```

Run: `python -m pytest tests/test_registry_paging.py -q` — Expected: FAIL (ModuleNotFoundError).

- [ ] **Step 2 (git-flow-manager):** commit `test: registry name-keyed keyset cursor helpers`

- [ ] **Step 3: Implement** `src/registry/paging.py` (and the empty `src/registry/__init__.py`)

```python
"""Keyset paging for registry lists (fleet P1, spec D9).

Sort key is (COALESCE(name,''), id) — device names are nullable. The cursor is
"<name>|<uuid>". Names may contain '|', uuids never do, so decoding splits on
the LAST '|'. (godview/systems' private decoder splits on the first — fine for
that shipped endpoint, wrong in general; it is deliberately left untouched.)
"""
import uuid


def encode_name_cursor(name, row_id) -> str:
    return f"{name or ''}|{row_id}"


def decode_name_cursor(cursor):
    if not cursor:
        return (None, None)
    name, _, rid = cursor.rpartition("|")
    return (name, uuid.UUID(rid))


def page(rows, limit, *, name_key="name"):
    """rows were fetched with LIMIT limit+1 -> (items, next_cursor)."""
    items = [dict(r) for r in rows[:limit]]
    next_cursor = None
    if len(rows) > limit:
        last = rows[limit - 1]
        next_cursor = encode_name_cursor(last[name_key], last["id"])
    return items, next_cursor
```

- [ ] **Step 4:** Run `python -m pytest tests/test_registry_paging.py -q` — Expected: 6 passed.
- [ ] **Step 5 (git-flow-manager):** commit `feat: registry keyset paging (name cursor, last-pipe decode, page slicing)`

---

### Task 3: Seed helpers + `registry/reads.py` part 1 — organizations & locations lists

**Files:**
- Create: `/Users/jn/code/mras-ops/api/tests/registry_seed.py` (plain module — `tests/` has `__init__.py`)
- Create: `/Users/jn/code/mras-ops/api/src/registry/reads.py`
- Create: `/Users/jn/code/mras-ops/api/tests/test_registry_reads.py`

- [ ] **Step 1: Write the seed module** (shared by every registry DB test; mirrors `test_camera_admin._org_loc_sys`)

```python
"""Shared seeding for fleet registry tests (plan A). Mirrors test_camera_admin's
inline helpers; kept in one module because five test files need them."""
import uuid


async def org_loc_sys(pool, *, sys_name="Sys1", loc_name="Loc", org_name="Org"):
    org, loc, sid = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    await pool.execute(
        "INSERT INTO organizations (id,name,organization_type) VALUES ($1,$2,'advertiser')", org, org_name)
    await pool.execute(
        "INSERT INTO locations (id,name,location_type) VALUES ($1,$2,'store')", loc, loc_name)
    await pool.execute(
        "INSERT INTO systems (id,organization_id,location_id,name) VALUES ($1,$2,$3,$4)",
        sid, org, loc, sys_name)
    return org, loc, sid


async def root_location(pool, *, name, location_type="mall"):
    lid = uuid.uuid4()
    await pool.execute(
        "INSERT INTO locations (id,name,location_type) VALUES ($1,$2,$3::location_type)",
        lid, name, location_type)
    return lid


async def child_location(pool, parent, *, name, location_type="zone"):
    lid = uuid.uuid4()
    await pool.execute(
        "INSERT INTO locations (id,parent_location_id,name,location_type) VALUES ($1,$2,$3,$4::location_type)",
        lid, parent, name, location_type)
    return lid


async def screen_group(pool, sid, *, name="Grp1", loc=None):
    gid = uuid.uuid4()
    await pool.execute(
        "INSERT INTO screen_groups (id,system_id,location_id,name) VALUES ($1,$2,$3,$4)",
        gid, sid, loc, name)
    return gid


async def camera(pool, sid, *, name="Cam1", screen_id=None, group=None, status="active"):
    cid = uuid.uuid4()
    await pool.execute(
        "INSERT INTO cameras (id,system_id,name,screen_id,screen_group_id,status) "
        "VALUES ($1,$2,$3,$4,$5,$6::device_status)",
        cid, sid, name, screen_id, group, status)
    return cid


async def display(pool, sid, *, name="Kiosk1", screen_id, group=None, status="active"):
    did = uuid.uuid4()
    await pool.execute(
        "INSERT INTO displays (id,system_id,name,screen_id,screen_group_id,status) "
        "VALUES ($1,$2,$3,$4,$5,$6::device_status)",
        did, sid, name, screen_id, group, status)
    return did


async def unresolved(pool, *, screen_id="display-9", kind="display", seen_count=3):
    uid = uuid.uuid4()
    await pool.execute(
        "INSERT INTO unresolved_devices (id,screen_id,kind,seen_count) VALUES ($1,$2,$3,$4)",
        uid, screen_id, kind, seen_count)
    return uid
```

- [ ] **Step 2: Write the failing tests** (`tests/test_registry_reads.py`)

```python
"""Fleet P1 lists: parent-scoped, keyset, counts (spec §5.2 P1, D9)."""
import pytest

from src.registry.reads import list_locations, list_organizations
from tests.registry_seed import child_location, org_loc_sys, root_location

pytestmark = pytest.mark.usefixtures("godview_isolate")


async def test_locations_root_level_scopes_and_counts(projector_pool):
    _, loc, _ = await org_loc_sys(projector_pool)               # root location + 1 system
    await child_location(projector_pool, loc, name="Zone A")
    page = await list_locations(projector_pool, parent_id=None)  # "root"
    assert page["counts"]["total"] == 1                          # the child is NOT at root level
    (item,) = page["items"]
    assert item["id"] == loc
    assert item["location_type"] == "store"
    assert item["status"] == "active"
    assert item["child_location_count"] == 1
    assert item["system_count"] == 1
    assert page["next_cursor"] is None


async def test_locations_child_level(projector_pool):
    _, loc, _ = await org_loc_sys(projector_pool)
    await child_location(projector_pool, loc, name="Zone A")
    page = await list_locations(projector_pool, parent_id=loc)
    assert [i["name"] for i in page["items"]] == ["Zone A"]
    assert page["items"][0]["child_location_count"] == 0
    assert page["items"][0]["system_count"] == 0


async def test_locations_keyset_pagination(projector_pool):
    for n in ("Aaa", "Bbb", "Ccc"):
        await root_location(projector_pool, name=n)
    p1 = await list_locations(projector_pool, parent_id=None, limit=2)
    assert [i["name"] for i in p1["items"]] == ["Aaa", "Bbb"]
    assert p1["counts"]["total"] == 3
    p2 = await list_locations(projector_pool, parent_id=None, limit=2, cursor=p1["next_cursor"])
    assert [i["name"] for i in p2["items"]] == ["Ccc"]
    assert p2["next_cursor"] is None


async def test_organizations_list(projector_pool):
    await org_loc_sys(projector_pool, org_name="Acme")
    page = await list_organizations(projector_pool)
    assert page["counts"]["total"] == 1
    (item,) = page["items"]
    assert item["name"] == "Acme"
    assert item["organization_type"] == "advertiser"
    assert item["parent_organization_id"] is None
```

Run: `python -m pytest tests/test_registry_reads.py -q` — Expected: FAIL (ImportError: reads).

- [ ] **Step 3 (git-flow-manager):** commit `test: registry location/organization lists (parent-scoped, keyset, counts)`

- [ ] **Step 4: Implement** `src/registry/reads.py` (module docstring + these two functions; later tasks append to this file)

```python
"""Fleet registry reads (P1): parent-scoped keyset lists, §5.1 detail, audit,
unresolved devices (spec §5.2 P1; decisions D1/D2/D9/D10).

Idioms follow src/godview/systems.py: plain SQL, dict rows, ::text enum casts,
::float8 numeric casts, server-side counts, LIMIT n+1 keyset probes. Every list
is parent-scoped and bounded (spec §6) — there is no unscoped device list.
"""
import json
import uuid

from src.registry.paging import decode_name_cursor, page

_ENVELOPE = "counts/items/next_cursor"   # documented shape; see plan Interfaces


async def list_organizations(conn, *, cursor=None, limit=50) -> dict:
    total = await conn.fetchval("SELECT count(*) FROM organizations")
    cur_name, cur_id = decode_name_cursor(cursor)
    rows = await conn.fetch(
        """
        SELECT o.id, o.name, o.organization_type::text AS organization_type,
               o.status::text AS status, o.parent_organization_id
        FROM organizations o
        WHERE ($1::text IS NULL OR (COALESCE(o.name,''), o.id) > ($1::text, $2::uuid))
        ORDER BY COALESCE(o.name,'') ASC, o.id ASC
        LIMIT $3
        """,
        cur_name, cur_id, limit + 1)
    items, next_cursor = page(rows, limit)
    return {"counts": {"total": total}, "items": items, "next_cursor": next_cursor}


async def list_locations(conn, *, parent_id=None, cursor=None, limit=50) -> dict:
    """parent_id None = root level (parent_location_id IS NULL)."""
    total = await conn.fetchval(
        "SELECT count(*) FROM locations "
        "WHERE ($1::uuid IS NULL AND parent_location_id IS NULL) OR parent_location_id = $1",
        parent_id)
    cur_name, cur_id = decode_name_cursor(cursor)
    rows = await conn.fetch(
        """
        SELECT l.id, l.name, l.location_type::text AS location_type, l.status::text AS status,
               (SELECT count(*) FROM locations c WHERE c.parent_location_id = l.id) AS child_location_count,
               (SELECT count(*) FROM systems s WHERE s.location_id = l.id) AS system_count
        FROM locations l
        WHERE (($1::uuid IS NULL AND l.parent_location_id IS NULL) OR l.parent_location_id = $1)
          AND ($2::text IS NULL OR (COALESCE(l.name,''), l.id) > ($2::text, $3::uuid))
        ORDER BY COALESCE(l.name,'') ASC, l.id ASC
        LIMIT $4
        """,
        parent_id, cur_name, cur_id, limit + 1)
    items, next_cursor = page(rows, limit)
    return {"counts": {"total": total}, "items": items, "next_cursor": next_cursor}
```

- [ ] **Step 5:** Run `python -m pytest tests/test_registry_reads.py -q` — Expected: 4 passed.
- [ ] **Step 6 (git-flow-manager):** commit `feat: registry reads — organization + location lists`

---

### Task 4: `registry/reads.py` part 2 — systems, screen-groups, cameras, displays lists

**Files:**
- Modify: `/Users/jn/code/mras-ops/api/src/registry/reads.py`
- Modify: `/Users/jn/code/mras-ops/api/tests/test_registry_reads.py`

- [ ] **Step 1: Write the failing tests** (append)

```python
from src.registry.reads import list_cameras, list_displays, list_screen_groups, list_systems
from tests.registry_seed import camera, display, screen_group


async def test_systems_scoped_by_location_with_device_count(projector_pool):
    _, loc, sid = await org_loc_sys(projector_pool)
    await camera(projector_pool, sid, screen_id="scr_c1")
    await display(projector_pool, sid, screen_id="scr_d1")
    other_loc = await root_location(projector_pool, name="Elsewhere")
    page = await list_systems(projector_pool, location_id=loc)
    assert page["counts"]["total"] == 1
    (item,) = page["items"]
    assert item["system_type"] == "onsite_mras"
    assert item["device_count"] == 2
    empty = await list_systems(projector_pool, location_id=other_loc)
    assert empty["counts"]["total"] == 0 and empty["items"] == []


async def test_screen_groups_scoped_by_system(projector_pool):
    _, _, sid = await org_loc_sys(projector_pool)
    gid = await screen_group(projector_pool, sid, name="North Wall")
    await camera(projector_pool, sid, screen_id="scr_c1", group=gid)
    page = await list_screen_groups(projector_pool, system_id=sid)
    (item,) = page["items"]
    assert item["name"] == "North Wall"
    assert item["group_type"] == "custom"
    assert item["device_count"] == 1


async def test_cameras_by_system_and_by_group_with_duty(projector_pool):
    _, _, sid = await org_loc_sys(projector_pool)
    gid = await screen_group(projector_pool, sid)
    cid = await camera(projector_pool, sid, name="Cam A", screen_id="scr_c1", group=gid)
    await camera(projector_pool, sid, name="Cam B", screen_id="scr_c2")
    await projector_pool.execute(
        "INSERT INTO events (trigger_id, service, event_type, status, payload) "
        "VALUES (gen_random_uuid(), 'vision', 'camera_duty', 'success', "
        "        jsonb_build_object('camera_id', $1::text, 'from', 'standby', 'to', 'watching'))",
        str(cid))
    by_sys = await list_cameras(projector_pool, system_id=sid)
    assert by_sys["counts"]["total"] == 2
    cam_a = next(i for i in by_sys["items"] if i["name"] == "Cam A")
    assert cam_a["effective_duty"] == "watching"       # duty probe (027 index)
    assert cam_a["failover_eligible"] is False
    assert cam_a["screen_group_id"] == gid
    cam_b = next(i for i in by_sys["items"] if i["name"] == "Cam B")
    assert cam_b["effective_duty"] == "unknown"
    by_group = await list_cameras(projector_pool, screen_group_id=gid)
    assert [i["name"] for i in by_group["items"]] == ["Cam A"]


async def test_displays_by_system_and_group(projector_pool):
    _, _, sid = await org_loc_sys(projector_pool)
    gid = await screen_group(projector_pool, sid)
    await display(projector_pool, sid, name="Kiosk 1", screen_id="display-1", group=gid)
    await display(projector_pool, sid, name="Kiosk 2", screen_id="display-2")
    by_sys = await list_displays(projector_pool, system_id=sid)
    assert by_sys["counts"]["total"] == 2
    k1 = next(i for i in by_sys["items"] if i["name"] == "Kiosk 1")
    assert k1["display_role"] == "primary_ad" and k1["screen_id"] == "display-1"
    by_group = await list_displays(projector_pool, screen_group_id=gid)
    assert [i["name"] for i in by_group["items"]] == ["Kiosk 1"]


async def test_device_lists_paginate_with_null_names(projector_pool):
    _, _, sid = await org_loc_sys(projector_pool)
    await camera(projector_pool, sid, name=None, screen_id="scr_z1")   # NULL name sorts first
    await camera(projector_pool, sid, name="Aaa", screen_id="scr_z2")
    await camera(projector_pool, sid, name="Bbb", screen_id="scr_z3")
    p1 = await list_cameras(projector_pool, system_id=sid, limit=2)
    assert [i["name"] for i in p1["items"]] == [None, "Aaa"]
    p2 = await list_cameras(projector_pool, system_id=sid, limit=2, cursor=p1["next_cursor"])
    assert [i["name"] for i in p2["items"]] == ["Bbb"]
```

Run — Expected: FAIL (ImportError). **Step 2 (git-flow-manager):** commit `test: registry system/group/device lists (scoping, duty probe, null-name keyset)`

- [ ] **Step 3: Implement** (append to `src/registry/reads.py`)

```python
async def list_systems(conn, *, location_id, cursor=None, limit=50) -> dict:
    total = await conn.fetchval("SELECT count(*) FROM systems WHERE location_id = $1", location_id)
    cur_name, cur_id = decode_name_cursor(cursor)
    rows = await conn.fetch(
        """
        SELECT s.id, s.name, s.system_type::text AS system_type, s.status::text AS status,
               (SELECT count(*) FROM cameras c  WHERE c.system_id = s.id)
             + (SELECT count(*) FROM displays d WHERE d.system_id = s.id) AS device_count
        FROM systems s
        WHERE s.location_id = $1
          AND ($2::text IS NULL OR (COALESCE(s.name,''), s.id) > ($2::text, $3::uuid))
        ORDER BY COALESCE(s.name,'') ASC, s.id ASC
        LIMIT $4
        """,
        location_id, cur_name, cur_id, limit + 1)
    items, next_cursor = page(rows, limit)
    return {"counts": {"total": total}, "items": items, "next_cursor": next_cursor}


async def list_screen_groups(conn, *, system_id, cursor=None, limit=50) -> dict:
    total = await conn.fetchval("SELECT count(*) FROM screen_groups WHERE system_id = $1", system_id)
    cur_name, cur_id = decode_name_cursor(cursor)
    rows = await conn.fetch(
        """
        SELECT g.id, g.name, g.group_type::text AS group_type, g.status::text AS status,
               (SELECT count(*) FROM cameras c  WHERE c.screen_group_id = g.id)
             + (SELECT count(*) FROM displays d WHERE d.screen_group_id = g.id) AS device_count
        FROM screen_groups g
        WHERE g.system_id = $1
          AND ($2::text IS NULL OR (COALESCE(g.name,''), g.id) > ($2::text, $3::uuid))
        ORDER BY COALESCE(g.name,'') ASC, g.id ASC
        LIMIT $4
        """,
        system_id, cur_name, cur_id, limit + 1)
    items, next_cursor = page(rows, limit)
    return {"counts": {"total": total}, "items": items, "next_cursor": next_cursor}


_DEVICE_SCOPE = ("(($1::uuid IS NULL OR {t}.system_id = $1) "
                 "AND ($2::uuid IS NULL OR {t}.screen_group_id = $2))")


async def list_cameras(conn, *, system_id=None, screen_group_id=None, cursor=None, limit=50) -> dict:
    """Route enforces exactly-one-scope (delta 3); function accepts either."""
    scope = _DEVICE_SCOPE.format(t="c")
    total = await conn.fetchval(
        f"SELECT count(*) FROM cameras c WHERE {scope}", system_id, screen_group_id)
    cur_name, cur_id = decode_name_cursor(cursor)
    rows = await conn.fetch(
        f"""
        SELECT c.id, c.name, c.status::text AS status, c.camera_role::text AS camera_role,
               c.failover_eligible, c.screen_group_id, c.screen_id,
               COALESCE((
                   SELECT e.payload->>'to' FROM events e
                   WHERE e.event_type = 'camera_duty'
                     AND e.payload->>'camera_id' = c.id::text
                   ORDER BY e.id DESC LIMIT 1
               ), 'unknown') AS effective_duty,
               c.last_seen_at
        FROM cameras c
        WHERE {scope}
          AND ($3::text IS NULL OR (COALESCE(c.name,''), c.id) > ($3::text, $4::uuid))
        ORDER BY COALESCE(c.name,'') ASC, c.id ASC
        LIMIT $5
        """,
        system_id, screen_group_id, cur_name, cur_id, limit + 1)
    items, next_cursor = page(rows, limit)
    return {"counts": {"total": total}, "items": items, "next_cursor": next_cursor}


async def list_displays(conn, *, system_id=None, screen_group_id=None, cursor=None, limit=50) -> dict:
    scope = _DEVICE_SCOPE.format(t="d")
    total = await conn.fetchval(
        f"SELECT count(*) FROM displays d WHERE {scope}", system_id, screen_group_id)
    cur_name, cur_id = decode_name_cursor(cursor)
    rows = await conn.fetch(
        f"""
        SELECT d.id, d.name, d.status::text AS status, d.display_role::text AS display_role,
               d.screen_group_id, d.screen_id, d.last_seen_at
        FROM displays d
        WHERE {scope}
          AND ($3::text IS NULL OR (COALESCE(d.name,''), d.id) > ($3::text, $4::uuid))
        ORDER BY COALESCE(d.name,'') ASC, d.id ASC
        LIMIT $5
        """,
        system_id, screen_group_id, cur_name, cur_id, limit + 1)
    items, next_cursor = page(rows, limit)
    return {"counts": {"total": total}, "items": items, "next_cursor": next_cursor}
```

(The duty sub-select is the shipped `godview/systems.get_system` pattern verbatim — a single-row probe of `events_camera_duty_idx` per returned camera, bounded by `limit` ≤ 100.)

- [ ] **Step 4:** Run `python -m pytest tests/test_registry_reads.py -q` — Expected: 9 passed.
- [ ] **Step 5 (git-flow-manager):** commit `feat: registry reads — system/group/camera/display lists`

---

### Task 5: `registry/reads.py` part 3 — table-driven §5.1 detail (`get_detail`)

**Files:**
- Modify: `/Users/jn/code/mras-ops/api/src/registry/reads.py`
- Create: `/Users/jn/code/mras-ops/api/tests/test_registry_detail.py`

- [ ] **Step 1: Write the failing tests**

```python
"""GET /{type}/{id} detail: identity/config/state split per spec §5.1 (D1/D2)."""
import pytest

from src.registry.reads import get_detail
from tests.registry_seed import camera, display, org_loc_sys, screen_group

pytestmark = pytest.mark.usefixtures("godview_isolate")


async def test_camera_detail_splits_identity_config_state(projector_pool):
    _, loc, sid = await org_loc_sys(projector_pool)
    gid = await screen_group(projector_pool, sid)
    cid = await camera(projector_pool, sid, name="Cam A", screen_id="scr_c1", group=gid)
    d = await get_detail(projector_pool, "camera", cid)
    assert d["object_type"] == "camera"
    assert d["identity"] == {
        "id": str(cid), "device_id": None, "system_id": str(sid),
        "location_id": None, "screen_id": "scr_c1",
    }   # location_id: seed inserts cameras without the denormalized location (nullable, 012)
    assert d["config"]["name"] == "Cam A"
    assert d["config"]["camera_role"] == "detection"
    assert d["config"]["failover_eligible"] is False
    assert d["config"]["screen_group_id"] == str(gid)
    assert d["config"]["calibration"] == {}            # jsonb parsed to an object
    assert d["config"]["status"] == "active"           # status lives in config (D2 status*)
    assert d["state"]["effective_duty"] == "unknown"
    assert d["state"]["last_seen_at"] is None
    assert "created_at" in d["state"] and "updated_at" in d["state"]
    assert "status" not in d["state"] and "name" not in d["identity"]


async def test_display_and_group_and_container_details(projector_pool):
    org, loc, sid = await org_loc_sys(projector_pool)
    gid = await screen_group(projector_pool, sid, name="Wall")
    did = await display(projector_pool, sid, name="Kiosk 1", screen_id="display-1")
    disp = await get_detail(projector_pool, "display", did)
    assert disp["identity"]["screen_id"] == "display-1"
    assert disp["config"]["display_role"] == "primary_ad"
    assert disp["config"]["resolution_width"] is None
    assert "effective_duty" not in disp["state"]

    grp = await get_detail(projector_pool, "screen_group", gid)
    assert grp["identity"] == {"id": str(gid), "system_id": str(sid), "location_id": None}
    assert grp["config"]["group_type"] == "custom" and grp["config"]["metadata"] == {}

    system = await get_detail(projector_pool, "system", sid)
    assert system["identity"] == {"id": str(sid), "organization_id": str(org), "location_id": str(loc)}
    assert system["config"]["system_type"] == "onsite_mras" and system["config"]["config"] == {}

    location = await get_detail(projector_pool, "location", loc)
    assert location["identity"] == {"id": str(loc), "parent_location_id": None}
    assert location["config"]["location_type"] == "store" and location["config"]["lat"] is None

    organization = await get_detail(projector_pool, "organization", org)
    assert organization["identity"] == {"id": str(org), "parent_organization_id": None}
    assert organization["config"]["organization_type"] == "advertiser"


async def test_camera_detail_reports_latest_duty(projector_pool):
    _, _, sid = await org_loc_sys(projector_pool)
    cid = await camera(projector_pool, sid, screen_id="scr_c1")
    await projector_pool.execute(
        "INSERT INTO events (trigger_id, service, event_type, status, payload) "
        "VALUES (gen_random_uuid(), 'vision', 'camera_duty', 'success', "
        "        jsonb_build_object('camera_id', $1::text, 'from', 'standby', 'to', 'watching'))",
        str(cid))
    d = await get_detail(projector_pool, "camera", cid)
    assert d["state"]["effective_duty"] == "watching"


async def test_unknown_id_returns_none(projector_pool):
    import uuid
    assert await get_detail(projector_pool, "camera", uuid.uuid4()) is None
```

Run — Expected: FAIL. **Step 2 (git-flow-manager):** commit `test: registry §5.1 detail split for all six types`

- [ ] **Step 3: Implement** (append to `src/registry/reads.py`)

```python
# --- §5.1 detail --------------------------------------------------------------
# Table-driven over STATIC SQL: (sql, identity keys, config keys, extra state keys).
# created_at/updated_at are always STATE (spec §5.1). jsonb comes back from asyncpg
# as str (no codec installed in this app) -> parsed here so config is an object.

_JSONB_KEYS = {"metadata", "config", "calibration"}

_DETAIL = {
    "organization": (
        "SELECT id, parent_organization_id, name, organization_type::text AS organization_type, "
        "metadata, status::text AS status, created_at, updated_at "
        "FROM organizations WHERE id = $1",
        ("id", "parent_organization_id"),
        ("name", "organization_type", "metadata", "status"),
        (),
    ),
    "location": (
        "SELECT id, parent_location_id, name, location_type::text AS location_type, "
        "country, region, state, city, address, lat::float8 AS lat, lng::float8 AS lng, "
        "timezone, metadata, status::text AS status, created_at, updated_at "
        "FROM locations WHERE id = $1",
        ("id", "parent_location_id"),
        ("name", "location_type", "country", "region", "state", "city", "address",
         "lat", "lng", "timezone", "metadata", "status"),
        (),
    ),
    "system": (
        "SELECT id, organization_id, location_id, name, system_type::text AS system_type, "
        "zone, floor, lat::float8 AS lat, lng::float8 AS lng, timezone, config, "
        "status::text AS status, created_at, updated_at "
        "FROM systems WHERE id = $1",
        ("id", "organization_id", "location_id"),
        ("name", "system_type", "zone", "floor", "lat", "lng", "timezone", "config", "status"),
        (),
    ),
    "screen_group": (
        "SELECT id, system_id, location_id, name, group_type::text AS group_type, "
        "metadata, status::text AS status, created_at, updated_at "
        "FROM screen_groups WHERE id = $1",
        ("id", "system_id", "location_id"),
        ("name", "group_type", "metadata", "status"),
        (),
    ),
    "camera": (
        "SELECT c.id, c.device_id, c.system_id, c.location_id, c.screen_id, c.name, "
        "c.camera_role::text AS camera_role, c.failover_eligible, c.screen_group_id, "
        "c.stream_url, c.calibration, c.status::text AS status, c.last_seen_at, "
        "c.created_at, c.updated_at, "
        "COALESCE((SELECT e.payload->>'to' FROM events e "
        "          WHERE e.event_type = 'camera_duty' "
        "            AND e.payload->>'camera_id' = c.id::text "
        "          ORDER BY e.id DESC LIMIT 1), 'unknown') AS effective_duty "
        "FROM cameras c WHERE c.id = $1",
        ("id", "device_id", "system_id", "location_id", "screen_id"),
        ("name", "camera_role", "failover_eligible", "screen_group_id",
         "stream_url", "calibration", "status"),
        ("last_seen_at", "effective_duty"),
    ),
    "display": (
        "SELECT id, device_id, system_id, location_id, screen_id, name, "
        "display_role::text AS display_role, screen_group_id, resolution_width, "
        "resolution_height, calibration, status::text AS status, last_seen_at, "
        "created_at, updated_at "
        "FROM displays WHERE id = $1",
        ("id", "device_id", "system_id", "location_id", "screen_id"),
        ("name", "display_role", "screen_group_id", "resolution_width",
         "resolution_height", "calibration", "status"),
        ("last_seen_at",),
    ),
}


def _val(row, key):
    v = row[key]
    if isinstance(v, uuid.UUID):
        return str(v)
    if key in _JSONB_KEYS and isinstance(v, str):
        return json.loads(v)
    return v


async def get_detail(conn, object_type: str, object_id) -> dict | None:
    sql, identity_keys, config_keys, state_keys = _DETAIL[object_type]
    row = await conn.fetchrow(sql, object_id)
    if row is None:
        return None
    return {
        "object_type": object_type,
        "identity": {k: _val(row, k) for k in identity_keys},
        "config": {k: _val(row, k) for k in config_keys},
        "state": {k: _val(row, k) for k in (*state_keys, "created_at", "updated_at")},
    }
```

- [ ] **Step 4:** Run `python -m pytest tests/test_registry_detail.py -q` — Expected: 4 passed.
- [ ] **Step 5 (git-flow-manager):** commit `feat: registry §5.1 detail endpoint core (table-driven, six types)`

---

### Task 6: `registry/reads.py` part 4 — audit trail + unresolved devices

**Files:**
- Modify: `/Users/jn/code/mras-ops/api/src/registry/reads.py`
- Create: `/Users/jn/code/mras-ops/api/tests/test_registry_audit.py`

- [ ] **Step 1: Write the failing tests**

```python
"""GET /registry/audit (D10 merge of registry_admin/camera_admin/camera_duty)
and GET /unresolved-devices (D11 read half)."""
import json
import uuid

import pytest

from src.registry.reads import get_audit, list_unresolved
from tests.registry_seed import unresolved

pytestmark = pytest.mark.usefixtures("godview_isolate")


async def _event(pool, event_type, payload):
    await pool.execute(
        "INSERT INTO events (trigger_id, service, event_type, status, payload) "
        "VALUES (gen_random_uuid(), 'mras-ops', $1, 'success', $2::jsonb)",
        event_type, json.dumps(payload))


async def test_audit_merges_three_event_types_newest_first(projector_pool):
    oid = str(uuid.uuid4())
    await _event(projector_pool, "camera_duty",
                 {"camera_id": oid, "from": "standby", "to": "watching"})
    await _event(projector_pool, "camera_admin",
                 {"camera_id": oid, "changes": {"failover_eligible": {"from": False, "to": True}}})
    await _event(projector_pool, "registry_admin",
                 {"object_type": "camera", "object_id": oid, "action": "update",
                  "changes": {"name": {"from": "Old", "to": "New"}}})
    await _event(projector_pool, "registry_admin",
                 {"object_type": "camera", "object_id": str(uuid.uuid4()),  # other object
                  "action": "update", "changes": {}})
    trail = await get_audit(projector_pool, oid)
    assert [e["event_type"] for e in trail["items"]] == [
        "registry_admin", "camera_admin", "camera_duty"]
    assert trail["items"][0]["payload"]["changes"]["name"]["to"] == "New"   # payload as object
    assert trail["next_cursor"] is None


async def test_audit_keyset_by_event_id(projector_pool):
    oid = str(uuid.uuid4())
    for n in range(3):
        await _event(projector_pool, "registry_admin",
                     {"object_type": "camera", "object_id": oid, "action": "update",
                      "changes": {"name": {"from": str(n), "to": str(n + 1)}}})
    p1 = await get_audit(projector_pool, oid, limit=2)
    assert len(p1["items"]) == 2 and p1["next_cursor"] is not None
    p2 = await get_audit(projector_pool, oid, cursor=p1["next_cursor"], limit=2)
    assert len(p2["items"]) == 1 and p2["next_cursor"] is None
    assert p1["items"][0]["id"] > p1["items"][1]["id"] > p2["items"][0]["id"]


async def test_unresolved_devices_list(projector_pool):
    await unresolved(projector_pool, screen_id="display-9", kind="display", seen_count=3)
    await unresolved(projector_pool, screen_id="scr_ghost", kind="camera", seen_count=1)
    page = await list_unresolved(projector_pool)
    assert page["counts"]["total"] == 2
    ids = {i["screen_id"] for i in page["items"]}
    assert ids == {"display-9", "scr_ghost"}
    assert all("seen_count" in i and "first_seen_at" in i for i in page["items"])
```

Run — Expected: FAIL. **Step 2 (git-flow-manager):** commit `test: registry audit merge + unresolved-devices list`

- [ ] **Step 3: Implement** (append to `src/registry/reads.py`; also add `from src.godview.paging import decode_cursor, encode_cursor` at top)

```python
# --- audit trail ---------------------------------------------------------------
# Three UNION ALL branches so each is a probe of ITS partial index
# (events_registry_admin_idx / events_camera_admin_idx from 028,
#  events_camera_duty_idx from 027) — an OR would defeat the ORDER BY id DESC
#  probes and scan (spec §6: never a journal scan). Cursor = stringified events.id.

async def get_audit(conn, object_id: str, *, cursor=None, limit=20) -> dict:
    before = int(cursor) if cursor else None
    rows = await conn.fetch(
        """
        SELECT id, ts, event_type, payload FROM (
            (SELECT id, ts, event_type, payload FROM events
             WHERE event_type = 'registry_admin' AND payload->>'object_id' = $1
               AND ($2::bigint IS NULL OR id < $2) ORDER BY id DESC LIMIT $3)
            UNION ALL
            (SELECT id, ts, event_type, payload FROM events
             WHERE event_type = 'camera_admin' AND payload->>'camera_id' = $1
               AND ($2::bigint IS NULL OR id < $2) ORDER BY id DESC LIMIT $3)
            UNION ALL
            (SELECT id, ts, event_type, payload FROM events
             WHERE event_type = 'camera_duty' AND payload->>'camera_id' = $1
               AND ($2::bigint IS NULL OR id < $2) ORDER BY id DESC LIMIT $3)
        ) merged ORDER BY id DESC LIMIT $3
        """,
        object_id, before, limit + 1)
    items = []
    for r in rows[:limit]:
        p = r["payload"]
        items.append({"id": r["id"], "ts": r["ts"], "event_type": r["event_type"],
                      "payload": json.loads(p) if isinstance(p, str) else p})
    next_cursor = str(rows[limit - 1]["id"]) if len(rows) > limit else None
    return {"items": items, "next_cursor": next_cursor}


# --- unresolved devices (D11 read half) -----------------------------------------
# Ordered by recency, not name (these rows have no name) -> reuse the godview
# timestamp cursor (encode_cursor/decode_cursor), DESC keyset.

async def list_unresolved(conn, *, cursor=None, limit=50) -> dict:
    total = await conn.fetchval("SELECT count(*) FROM unresolved_devices")
    cur_ts, cur_id = decode_cursor(cursor)
    rows = await conn.fetch(
        """
        SELECT id, screen_id, kind, event_id, first_seen_at, last_seen_at, seen_count
        FROM unresolved_devices
        WHERE ($1::timestamptz IS NULL OR (last_seen_at, id) < ($1::timestamptz, $2::uuid))
        ORDER BY last_seen_at DESC, id DESC
        LIMIT $3
        """,
        cur_ts, cur_id, limit + 1)
    items = [dict(r) for r in rows[:limit]]
    next_cursor = None
    if len(rows) > limit:
        last = rows[limit - 1]
        next_cursor = encode_cursor(last["last_seen_at"], last["id"])
    return {"counts": {"total": total}, "items": items, "next_cursor": next_cursor}
```

- [ ] **Step 4:** Run `python -m pytest tests/test_registry_audit.py -q` — Expected: 3 passed.
- [ ] **Step 5 (git-flow-manager):** commit `feat: registry audit trail (3-way indexed merge) + unresolved-devices list`

---

### Task 7: Wire P1 routes into `main.py` (+ route validation tests) — **P1 shippable here**

**Files:**
- Modify: `/Users/jn/code/mras-ops/api/src/main.py`
- Create: `/Users/jn/code/mras-ops/api/tests/test_registry_routes.py`

- [ ] **Step 1: Write the failing tests** (TestClient + mocked pool — copy the `_AcquireCtx`/`_client` pattern from `test_camera_admin.py` verbatim, with a comment crediting it)

```python
"""Route-level validation for the fleet registry endpoints (mocked pool;
_AcquireCtx/_client pattern from test_camera_admin.py)."""
import uuid
from unittest.mock import AsyncMock, MagicMock

import pytest


class _AcquireCtx:
    async def __aenter__(self):
        return AsyncMock()

    async def __aexit__(self, *exc):
        return False


def _client(monkeypatch):
    from fastapi.testclient import TestClient
    from src.main import app
    fake_pool = AsyncMock()
    fake_pool.acquire = MagicMock(return_value=_AcquireCtx())
    monkeypatch.setenv("DATABASE_URL", "postgresql://fake/fake")
    monkeypatch.setattr("src.main.asyncpg.create_pool", AsyncMock(return_value=fake_pool))
    return TestClient(app)


def test_locations_rejects_bad_parent_uuid(monkeypatch):
    with _client(monkeypatch) as client:
        assert client.get("/locations?parent_location_id=nope").status_code == 400


def test_locations_default_root_calls_reader(monkeypatch):
    reader = AsyncMock(return_value={"counts": {"total": 0}, "items": [], "next_cursor": None})
    monkeypatch.setattr("src.main.list_locations", reader)
    with _client(monkeypatch) as client:
        r = client.get("/locations")
    assert r.status_code == 200 and r.json()["counts"] == {"total": 0}
    assert reader.call_args.kwargs["parent_id"] is None            # "root"


def test_systems_requires_location_id(monkeypatch):
    with _client(monkeypatch) as client:
        assert client.get("/systems").status_code == 422           # FastAPI required query param


def test_cameras_requires_exactly_one_scope(monkeypatch):
    with _client(monkeypatch) as client:
        assert client.get("/cameras").status_code == 422
        two = client.get(f"/cameras?system_id={uuid.uuid4()}&screen_group_id={uuid.uuid4()}")
        assert two.status_code == 422
        assert two.json()["detail"] == "provide exactly one of system_id or screen_group_id"


def test_limit_is_clamped(monkeypatch):
    reader = AsyncMock(return_value={"counts": {"total": 0}, "items": [], "next_cursor": None})
    monkeypatch.setattr("src.main.list_organizations", reader)
    with _client(monkeypatch) as client:
        client.get("/organizations?limit=999")
    assert reader.call_args.kwargs["limit"] == 100


def test_detail_404_and_400(monkeypatch):
    monkeypatch.setattr("src.main.get_detail", AsyncMock(return_value=None))
    with _client(monkeypatch) as client:
        assert client.get(f"/screen-groups/{uuid.uuid4()}").status_code == 404
        assert client.get("/cameras/not-a-uuid").status_code == 400


def test_detail_passes_object_type(monkeypatch):
    detail = {"object_type": "display", "identity": {}, "config": {}, "state": {}}
    getter = AsyncMock(return_value=detail)
    monkeypatch.setattr("src.main.get_detail", getter)
    with _client(monkeypatch) as client:
        r = client.get(f"/displays/{uuid.uuid4()}")
    assert r.status_code == 200 and r.json() == detail
    assert getter.call_args.args[1] == "display"


def test_audit_requires_object_id(monkeypatch):
    with _client(monkeypatch) as client:
        assert client.get("/registry/audit").status_code == 422
```

Run — Expected: FAIL (404s — routes missing). **Step 2 (git-flow-manager):** commit `test: registry P1 route validation (scope XOR, clamps, 400/404/422)`

- [ ] **Step 3: Implement in `src/main.py`.** Add imports:

```python
from src.registry.reads import (get_audit, get_detail, list_cameras, list_displays,
                                list_locations, list_organizations, list_screen_groups,
                                list_systems, list_unresolved)
```

Add a section after the existing camera route (D9: flat resource routes; auth deliberately absent, spec D14):

```python
# ---------------------------------------------------------------------------
# Registry — Fleet P1 reads (spec 2026-07-08 fleet-management, D9)
# ---------------------------------------------------------------------------

def _uuid_or_400(raw: str) -> uuid.UUID:
    try:
        return uuid.UUID(raw)
    except ValueError:
        raise HTTPException(status_code=400, detail="invalid id")


def _clamp(limit: int) -> int:
    return max(1, min(limit, 100))


@app.get("/organizations")
async def registry_organizations(cursor: str | None = None, limit: int = 50):
    async with _db.acquire() as conn:
        return await list_organizations(conn, cursor=cursor, limit=_clamp(limit))


@app.get("/locations")
async def registry_locations(parent_location_id: str = "root",
                             cursor: str | None = None, limit: int = 50):
    parent = None if parent_location_id == "root" else _uuid_or_400(parent_location_id)
    async with _db.acquire() as conn:
        return await list_locations(conn, parent_id=parent, cursor=cursor, limit=_clamp(limit))


@app.get("/systems")
async def registry_systems(location_id: str, cursor: str | None = None, limit: int = 50):
    async with _db.acquire() as conn:
        return await list_systems(conn, location_id=_uuid_or_400(location_id),
                                  cursor=cursor, limit=_clamp(limit))


@app.get("/screen-groups")
async def registry_screen_groups(system_id: str, cursor: str | None = None, limit: int = 50):
    async with _db.acquire() as conn:
        return await list_screen_groups(conn, system_id=_uuid_or_400(system_id),
                                        cursor=cursor, limit=_clamp(limit))


def _device_scope(system_id: str | None, screen_group_id: str | None):
    if (system_id is None) == (screen_group_id is None):     # both or neither
        raise HTTPException(status_code=422,
                            detail="provide exactly one of system_id or screen_group_id")
    return (_uuid_or_400(system_id) if system_id else None,
            _uuid_or_400(screen_group_id) if screen_group_id else None)


@app.get("/cameras")
async def registry_cameras(system_id: str | None = None, screen_group_id: str | None = None,
                           cursor: str | None = None, limit: int = 50):
    sid, gid = _device_scope(system_id, screen_group_id)
    async with _db.acquire() as conn:
        return await list_cameras(conn, system_id=sid, screen_group_id=gid,
                                  cursor=cursor, limit=_clamp(limit))


@app.get("/displays")
async def registry_displays(system_id: str | None = None, screen_group_id: str | None = None,
                            cursor: str | None = None, limit: int = 50):
    sid, gid = _device_scope(system_id, screen_group_id)
    async with _db.acquire() as conn:
        return await list_displays(conn, system_id=sid, screen_group_id=gid,
                                   cursor=cursor, limit=_clamp(limit))


_DETAIL_ROUTES = (("organizations", "organization"), ("locations", "location"),
                  ("systems", "system"), ("screen-groups", "screen_group"),
                  ("cameras", "camera"), ("displays", "display"))

def _register_detail_routes():
    for path, object_type in _DETAIL_ROUTES:
        def make(object_type=object_type):
            async def detail(object_id: str):
                async with _db.acquire() as conn:
                    result = await get_detail(conn, object_type, _uuid_or_400(object_id))
                if result is None:
                    raise HTTPException(status_code=404, detail=f"{object_type} not found")
                return result
            return detail
        app.get(f"/{path}/{{object_id}}")(make())

_register_detail_routes()


@app.get("/registry/audit")
async def registry_audit(object_id: str, cursor: str | None = None, limit: int = 20):
    async with _db.acquire() as conn:
        return await get_audit(conn, object_id, cursor=cursor, limit=_clamp(limit))


@app.get("/unresolved-devices")
async def registry_unresolved(cursor: str | None = None, limit: int = 50):
    async with _db.acquire() as conn:
        return await list_unresolved(conn, cursor=cursor, limit=_clamp(limit))
```

NOTE for the implementer: `test_detail_404_and_400` monkeypatches `src.main.get_detail`, which works because the closure resolves it at import-time binding of the module global — if you inline `get_detail` differently, keep it referenced as a module global (`await get_detail(...)`), same as the existing `src.main.patch_camera` monkeypatch precedent. `GET /systems/{id}` does NOT collide with the existing `/god-view/systems/{system_id}` (different path prefix), and there is no pre-existing flat `GET /systems`; verified against `src/main.py`.

- [ ] **Step 4:** Run `python -m pytest tests/test_registry_routes.py -q` — Expected: 8 passed. Then the FULL suite (`python -m pytest tests -q`) — Expected: no regressions (the existing camera route tests still pass untouched).
- [ ] **Step 5 (git-flow-manager):** commit `feat: registry P1 read routes (lists, detail, audit, unresolved) — P1 shippable`

---

## Phase 2 — device writes (P2): lifecycle matrix, write helpers, PATCH/POST, adopt

### Task 8: `registry/lifecycle.py` — the D3 transition matrix (pure, exhaustive tests)

**Files:**
- Create: `/Users/jn/code/mras-ops/api/src/registry/lifecycle.py`
- Create: `/Users/jn/code/mras-ops/api/tests/test_registry_lifecycle.py`

- [ ] **Step 1: Write the failing tests**

```python
"""D3 transition matrix — pure, no DB. The matrix in the plan's Global
Constraints is normative; these tests enumerate it EXACTLY."""
import pytest

from src.registry.lifecycle import TransitionError, allowed_transitions, check_transition

DEVICE_MATRIX = {
    "active":   {"degraded", "offline", "retired"},
    "degraded": {"active", "offline", "retired"},
    "offline":  {"active", "degraded", "retired"},
    "retired":  set(),
}

LIFECYCLE_MATRIX = {
    "planned":  {"active", "retired"},
    "active":   {"inactive", "degraded", "offline", "retired"},
    "inactive": {"active", "degraded", "offline", "retired"},
    "degraded": {"active", "inactive", "offline", "retired"},
    "offline":  {"active", "inactive", "degraded", "retired"},
    "retired":  set(),
}


def test_device_matrix_exact():
    for current, want in DEVICE_MATRIX.items():
        assert set(allowed_transitions(current, "device")) == want, current


def test_lifecycle_matrix_exact():
    for current, want in LIFECYCLE_MATRIX.items():
        assert set(allowed_transitions(current, "lifecycle")) == want, current


def test_same_status_is_a_noop_even_for_retired():
    check_transition("retired", "retired")      # no raise (idempotent PATCH)
    check_transition("active", "active")


def test_valid_transitions_pass():
    check_transition("offline", "active")
    check_transition("active", "retired")
    check_transition("planned", "active", "lifecycle")


def test_leaving_retired_raises_with_empty_allowed_set():
    with pytest.raises(TransitionError) as exc:
        check_transition("retired", "active")
    assert exc.value.current == "retired"
    assert exc.value.allowed == []              # the 409 renders "allowed: []" (terminal)


def test_planned_cannot_go_sideways():
    with pytest.raises(TransitionError) as exc:
        check_transition("planned", "offline", "lifecycle")
    assert set(exc.value.allowed) == {"active", "retired"}
```

Run: `python -m pytest tests/test_registry_lifecycle.py -q` — Expected: FAIL (import error).

- [ ] **Step 2 (git-flow-manager):** commit `test: D3 transition matrix (device + lifecycle enums, exhaustive)`

- [ ] **Step 3: Implement** `src/registry/lifecycle.py`

```python
"""Lifecycle-transition validation (spec D3). Pure functions, no DB.

The matrix (normative table in the plan's Global Constraints):
  device_status  — active/degraded/offline freely interchange; anything may
      retire; retired is terminal (allowed set is empty).
  lifecycle_status — planned may only activate or retire; active/inactive/
      degraded/offline freely interchange; anything may retire; retired terminal.
Same-status writes are no-ops (idempotent PATCH — preserves the shipped
PATCH /cameras contract). Used by camera+display PATCH in P2; the lifecycle
kind is defined now so P3/P4 container writes reuse this module unchanged.
"""

_DEVICE_LIVE = ("active", "degraded", "offline")
_LIFECYCLE_LIVE = ("active", "inactive", "degraded", "offline")


class TransitionError(Exception):
    """Invalid lifecycle transition -> route maps to 409 (spec D3 / Plan-B E3)."""

    def __init__(self, current: str, allowed):
        self.current = current
        self.allowed = list(allowed)
        super().__init__(f"invalid transition from {current!r}")


def allowed_transitions(current: str, kind: str = "device") -> tuple:
    live = _DEVICE_LIVE if kind == "device" else _LIFECYCLE_LIVE
    if current == "retired":
        return ()
    if current == "planned":                    # lifecycle_status only
        return ("active", "retired")
    return tuple(s for s in live if s != current) + ("retired",)


def check_transition(current: str, new: str, kind: str = "device") -> None:
    if new == current:
        return                                  # idempotent no-op
    if new not in allowed_transitions(current, kind):
        raise TransitionError(current, allowed_transitions(current, kind))
```

- [ ] **Step 4:** Run `python -m pytest tests/test_registry_lifecycle.py -q` — Expected: 6 passed.
- [ ] **Step 5 (git-flow-manager):** commit `feat: D3 lifecycle transition matrix (pure module)`

---

### Task 9: `registry/writes.py` — shared write helpers

**Files:**
- Create: `/Users/jn/code/mras-ops/api/src/registry/writes.py`
- Create: `/Users/jn/code/mras-ops/api/tests/test_registry_writes.py`

- [ ] **Step 1: Write the failing tests**

```python
"""Shared write plumbing: SET-clause builder (null-out capable), null policy,
same-system guard, registry_admin journaling (spec D6/D10)."""
import json
import uuid

import pytest

from src.registry.writes import (SemanticError, build_set_clause, ensure_same_system,
                                 journal_registry_admin, reject_nulls)
from tests.registry_seed import org_loc_sys, screen_group

pytestmark = pytest.mark.usefixtures("godview_isolate")


# --- pure helpers (no DB) ------------------------------------------------------

def test_build_set_clause_binds_values_and_casts():
    sql, args = build_set_clause({"status": "offline", "screen_group_id": None},
                                 {"status": "::device_status"})
    assert sql == "status = $2::device_status, screen_group_id = $3"
    assert args == ["offline", None]            # explicit NULL rides through (ungroup)


def test_build_set_clause_serializes_jsonb_fields():
    sql, args = build_set_clause({"calibration": {"cam_index": 2}}, {"calibration": "::jsonb"})
    assert sql == "calibration = $2::jsonb"
    assert args == ['{"cam_index": 2}']


def test_reject_nulls_policy():
    reject_nulls({"name": None, "screen_group_id": None}, frozenset({"name", "screen_group_id"}))
    with pytest.raises(SemanticError) as exc:
        reject_nulls({"status": None}, frozenset({"name"}))
    assert "status cannot be null" in str(exc.value)


# --- DB helpers ----------------------------------------------------------------

async def test_ensure_same_system_guard(projector_pool):
    _, _, sid = await org_loc_sys(projector_pool)
    _, _, other_sid = await org_loc_sys(projector_pool, sys_name="Sys2")
    gid = await screen_group(projector_pool, sid)
    async with projector_pool.acquire() as conn:
        await ensure_same_system(conn, gid, sid)                    # ok
        with pytest.raises(SemanticError, match="same system"):
            await ensure_same_system(conn, gid, other_sid)          # D6 cross-system
        with pytest.raises(SemanticError, match="unknown screen_group_id"):
            await ensure_same_system(conn, uuid.uuid4(), sid)


async def test_journal_registry_admin_shape(projector_pool):
    _, _, sid = await org_loc_sys(projector_pool)
    oid = uuid.uuid4()
    async with projector_pool.acquire() as conn:
        await journal_registry_admin(
            conn, object_type="display", object_id=oid, action="update",
            changes={"name": {"from": "Old", "to": "New"}}, system_id=sid)
    ev = await projector_pool.fetchrow(
        "SELECT service, status, system_id, payload FROM events "
        "WHERE event_type = 'registry_admin' ORDER BY id DESC LIMIT 1")
    assert ev["service"] == "mras-ops" and ev["status"] == "success"
    assert ev["system_id"] == sid
    payload = json.loads(ev["payload"])
    assert payload == {"object_type": "display", "object_id": str(oid),
                       "action": "update", "changes": {"name": {"from": "Old", "to": "New"}}}
```

Run — Expected: FAIL. **Step 2 (git-flow-manager):** commit `test: shared write helpers (set clause, null policy, same-system guard, registry_admin)`

- [ ] **Step 3: Implement** `src/registry/writes.py`

```python
"""Shared plumbing for registry writes (fleet P2, spec D6/D10).

Why a SET builder instead of the shipped COALESCE style: PATCH must support
explicit null-out for nullable config (ungrouping via screen_group_id=null),
which COALESCE cannot express. Column names are interpolated ONLY from
pydantic-validated field dicts (extra="forbid" models) — never raw input;
values are always bind parameters.
"""
import json
import uuid


class SemanticError(ValueError):
    """422-class semantic failure (cross-system group, unknown FK, bad null)."""


def reject_nulls(fields: dict, nullable: frozenset) -> None:
    for field, value in fields.items():
        if value is None and field not in nullable:
            raise SemanticError(f"{field} cannot be null")


def build_set_clause(fields: dict, casts: dict, *, start: int = 2):
    """-> ("col = $2::cast, col2 = $3", [v1, v2]); $1 stays the row id."""
    sets, args = [], []
    for i, (field, value) in enumerate(fields.items(), start=start):
        sets.append(f"{field} = ${i}{casts.get(field, '')}")
        args.append(json.dumps(value)
                    if field in ("calibration", "metadata", "config") and value is not None
                    else value)
    return ", ".join(sets), args


async def ensure_same_system(conn, screen_group_id, system_id) -> None:
    """Spec D6: a device's screen_group must belong to the device's system."""
    group_system = await conn.fetchval(
        "SELECT system_id FROM screen_groups WHERE id = $1", screen_group_id)
    if group_system is None:
        raise SemanticError("unknown screen_group_id")
    if group_system != system_id:
        raise SemanticError("screen_group must belong to the same system")


def jsonable(value):
    return str(value) if isinstance(value, uuid.UUID) else value


async def journal_registry_admin(conn, *, object_type, object_id, action, changes,
                                 system_id=None, camera_id=None, display_id=None,
                                 extra=None) -> None:
    """The one generic audit event for all NEW write endpoints (spec D10),
    emitted inside the caller's transaction (the camera_admin template)."""
    payload = {"object_type": object_type, "object_id": str(object_id),
               "action": action, "changes": changes}
    if extra:
        payload.update(extra)
    await conn.execute(
        "INSERT INTO events (trigger_id, service, event_type, status, payload, "
        "                    system_id, camera_id, display_id) "
        "VALUES ($1, 'mras-ops', 'registry_admin', 'success', $2::jsonb, $3, $4, $5)",
        uuid.uuid4(), json.dumps(payload, default=str), system_id, camera_id, display_id)
```

- [ ] **Step 4:** Run `python -m pytest tests/test_registry_writes.py -q` — Expected: 5 passed.
- [ ] **Step 5 (git-flow-manager):** commit `feat: shared registry write helpers`

---

### Task 10: Extend `PATCH /cameras/{id}` to full camera config (contract-preserving)

The shipped 3-field contract stays byte-identical for values-or-omitted bodies; `name`, `screen_group_id`, `stream_url`, `calibration` become writable (§5.1 CONFIG); `status` writes now pass the D3 matrix; the event stays `camera_admin` (D10 legacy exception). **One deliberate legacy-test change:** `test_route_rejects_unknown_field` probes with `name` — `name` is CONFIG now (D2 reclassifies it from the TODO-8 docstring's "identity"), so the probe field switches to `screen_id` (true IDENTITY, still 422).

**Files:**
- Modify: `/Users/jn/code/mras-ops/api/src/cameras.py`
- Modify: `/Users/jn/code/mras-ops/api/src/main.py` (route error mapping)
- Modify: `/Users/jn/code/mras-ops/api/tests/test_camera_admin.py` (the one probe-field change)
- Create: `/Users/jn/code/mras-ops/api/tests/test_registry_camera_patch.py`

- [ ] **Step 1: Change the legacy probe field** in `test_camera_admin.py` — replace the body of `test_route_rejects_unknown_field`:

```python
def test_route_rejects_unknown_field(monkeypatch):
    with _client(monkeypatch) as client:
        r = client.patch(f"/cameras/{uuid.uuid4()}", json={"screen_id": "evil"})
    assert r.status_code == 422  # extra="forbid": identity is not writable (spec D2 — name is CONFIG now)
```

Run `python -m pytest tests/test_camera_admin.py -q` — Expected: still all pass (name is still rejected today, so this passes both before AND after the extension; the probe just stops depending on a field that is about to become legal).

- [ ] **Step 2: Write the failing tests** (`tests/test_registry_camera_patch.py`)

```python
"""PATCH /cameras extended to full §5.1 camera config (D2/D3/D6/D10)."""
import json
import uuid

import pytest

from src.cameras import patch_camera
from src.registry.lifecycle import TransitionError
from src.registry.writes import SemanticError
from tests.registry_seed import camera, org_loc_sys, screen_group

pytestmark = pytest.mark.usefixtures("godview_isolate")


async def test_patch_name_and_group_and_journals_camera_admin(projector_pool):
    _, _, sid = await org_loc_sys(projector_pool)
    gid = await screen_group(projector_pool, sid)
    cid = await camera(projector_pool, sid, name="Cam1", screen_id="scr_c1")
    async with projector_pool.acquire() as conn:
        row = await patch_camera(conn, cid, {"name": "Entrance Cam", "screen_group_id": gid,
                                             "stream_url": "rtsp://x/1",
                                             "calibration": {"cam_index": 2}})
    assert row["name"] == "Entrance Cam"
    assert row["screen_group_id"] == gid
    assert row["stream_url"] == "rtsp://x/1"
    assert json.loads(row["calibration"]) == {"cam_index": 2}
    ev = await projector_pool.fetchrow(
        "SELECT payload FROM events WHERE event_type = 'camera_admin' ORDER BY id DESC LIMIT 1")
    changes = json.loads(ev["payload"])["changes"]        # legacy event, keys additive (D10)
    assert changes["name"] == {"from": "Cam1", "to": "Entrance Cam"}
    assert changes["screen_group_id"]["to"] == str(gid)


async def test_patch_ungroup_sets_null(projector_pool):
    _, _, sid = await org_loc_sys(projector_pool)
    gid = await screen_group(projector_pool, sid)
    cid = await camera(projector_pool, sid, screen_id="scr_c1", group=gid)
    async with projector_pool.acquire() as conn:
        row = await patch_camera(conn, cid, {"screen_group_id": None})
    assert row["screen_group_id"] is None


async def test_patch_cross_system_group_rejected(projector_pool):
    _, _, sid = await org_loc_sys(projector_pool)
    _, _, other = await org_loc_sys(projector_pool, sys_name="Sys2")
    foreign_gid = await screen_group(projector_pool, other)
    cid = await camera(projector_pool, sid, screen_id="scr_c1")
    async with projector_pool.acquire() as conn:
        with pytest.raises(SemanticError, match="same system"):
            await patch_camera(conn, cid, {"screen_group_id": foreign_gid})
    assert await projector_pool.fetchval(
        "SELECT count(*) FROM events WHERE event_type = 'camera_admin'") == 0   # txn rolled back


async def test_patch_retired_camera_cannot_reactivate(projector_pool):
    _, _, sid = await org_loc_sys(projector_pool)
    cid = await camera(projector_pool, sid, screen_id="scr_c1", status="retired")
    async with projector_pool.acquire() as conn:
        with pytest.raises(TransitionError) as exc:
            await patch_camera(conn, cid, {"status": "active"})
    assert exc.value.current == "retired" and exc.value.allowed == []


async def test_patch_same_status_is_noop_success(projector_pool):
    _, _, sid = await org_loc_sys(projector_pool)
    cid = await camera(projector_pool, sid, screen_id="scr_c1")
    async with projector_pool.acquire() as conn:
        row = await patch_camera(conn, cid, {"status": "active"})   # shipped-contract idempotency
    assert row["status"] == "active"


# --- route mapping (mocked pool; _client pattern from test_camera_admin) -------

from tests.test_camera_admin import _client  # reuse the shipped helper


def test_route_maps_transition_error_to_409(monkeypatch):
    from unittest.mock import AsyncMock
    monkeypatch.setattr("src.main.patch_camera",
                        AsyncMock(side_effect=TransitionError("retired", ())))
    with _client(monkeypatch) as client:
        r = client.patch(f"/cameras/{uuid.uuid4()}", json={"status": "active"})
    assert r.status_code == 409
    assert r.json()["detail"] == {"error": "invalid_transition", "from": "retired", "allowed": []}


def test_route_maps_semantic_error_to_422_string(monkeypatch):
    from unittest.mock import AsyncMock
    monkeypatch.setattr("src.main.patch_camera",
                        AsyncMock(side_effect=SemanticError("screen_group must belong to the same system")))
    with _client(monkeypatch) as client:
        r = client.patch(f"/cameras/{uuid.uuid4()}", json={"screen_group_id": str(uuid.uuid4())})
    assert r.status_code == 422
    assert r.json()["detail"] == "screen_group must belong to the same system"


def test_route_accepts_name_now(monkeypatch):
    from unittest.mock import AsyncMock
    monkeypatch.setattr("src.main.patch_camera", AsyncMock(return_value={"id": "x", "name": "New"}))
    with _client(monkeypatch) as client:
        r = client.patch(f"/cameras/{uuid.uuid4()}", json={"name": "New"})
    assert r.status_code == 200


def test_route_rejects_null_status(monkeypatch):
    with _client(monkeypatch) as client:
        r = client.patch(f"/cameras/{uuid.uuid4()}", json={"status": None})
    assert r.status_code == 422   # delta 4: explicit null on a non-nullable field
```

Run — Expected: FAIL. **Step 3 (git-flow-manager):** commit `test: extended camera PATCH (config fields, D3 409, D6 422, legacy contract intact)`

- [ ] **Step 4: Implement in `src/cameras.py`** — replace the model, `_RETURNING`, and `patch_camera` (docstring updated: `name` moved from the TODO-8 identity list to CONFIG per fleet spec D2; `id`/`device_id`/`system_id`/`screen_id` remain never-writable):

```python
"""Admin camera-registry updates (TODO-8 Phase C; extended by fleet P2, spec D2/D3/D6/D10).

patch_camera applies a partial update to the §5.1 camera CONFIG fields and
journals the change as a `camera_admin` event IN THE SAME TRANSACTION — an
audited write either fully happens (row + journal) or not at all. Identity
columns (id, device_id, system_id, screen_id) are never writable; `name` is
CONFIG since the fleet spec (admin renames are legitimate and journaled;
automation never renames). Enum values travel as text with server-side casts.
Status changes pass the D3 transition matrix (TransitionError -> 409);
screen_group re-parenting is same-system only (SemanticError -> 422).
Event type stays camera_admin — the one legacy exception to registry_admin
(fleet spec D10); change keys are additive.
"""
import json
import uuid
from typing import Literal, Optional

from pydantic import BaseModel, ConfigDict

from src.registry.lifecycle import check_transition
from src.registry.writes import build_set_clause, ensure_same_system, jsonable, reject_nulls


# cameras.status is device_status (NOT lifecycle_status): no 'planned'/'inactive'.
class CameraPatch(BaseModel):
    model_config = ConfigDict(extra="forbid")  # identity/state fields are schema-rejected (D1/D2)
    name: Optional[str] = None
    camera_role: Optional[Literal["detection", "enrollment", "audience_measurement",
                                  "security_context", "standby"]] = None
    status: Optional[Literal["active", "degraded", "offline", "retired"]] = None
    failover_eligible: Optional[bool] = None
    screen_group_id: Optional[uuid.UUID] = None
    stream_url: Optional[str] = None
    calibration: Optional[dict] = None


_NULLABLE = frozenset({"name", "screen_group_id", "stream_url"})
_CASTS = {"camera_role": "::camera_role", "status": "::device_status", "calibration": "::jsonb"}

_RETURNING = ("id, name, system_id, screen_group_id, camera_role::text AS camera_role, "
              "status::text AS status, failover_eligible, stream_url, calibration, updated_at")


async def patch_camera(conn, camera_id: uuid.UUID, fields: dict):
    """Apply an already-schema-validated {field: value} patch. None = unknown id.
    Raises TransitionError (409) / SemanticError (422)."""
    reject_nulls(fields, _NULLABLE)
    async with conn.transaction():
        before = await conn.fetchrow(
            "SELECT name, camera_role::text AS camera_role, status::text AS status, "
            "failover_eligible, screen_group_id, stream_url, calibration, system_id "
            "FROM cameras WHERE id = $1 FOR UPDATE",
            camera_id)
        if before is None:
            return None
        if "status" in fields:
            check_transition(before["status"], fields["status"])            # D3
        if fields.get("screen_group_id") is not None:
            await ensure_same_system(conn, fields["screen_group_id"], before["system_id"])  # D6
        set_sql, args = build_set_clause(fields, _CASTS)
        row = await conn.fetchrow(
            f"UPDATE cameras SET {set_sql}, updated_at = now() "
            f"WHERE id = $1 RETURNING {_RETURNING}",
            camera_id, *args)
        changes = {k: {"from": jsonable(before[k]), "to": jsonable(row[k])} for k in fields}
        await conn.execute(
            "INSERT INTO events (trigger_id, service, event_type, status, payload, "
            "                    system_id, camera_id) "
            "VALUES ($1, 'mras-ops', 'camera_admin', 'success', $2::jsonb, $3, $4)",
            uuid.uuid4(),
            json.dumps({"camera_id": str(camera_id), "changes": changes}, default=str),
            before["system_id"], camera_id)
    return dict(row)
```

- [ ] **Step 5: Update the route in `src/main.py`** (exclude_unset + error mapping; add imports `from src.registry.lifecycle import TransitionError` and `from src.registry.writes import SemanticError`):

```python
@app.patch("/cameras/{camera_id}")
async def update_camera(camera_id: str, patch: CameraPatch):
    cam_uuid = _uuid_or_400(camera_id)
    fields = patch.model_dump(exclude_unset=True)   # unset != null: null-out is a real op (ungroup)
    if not fields:
        raise HTTPException(status_code=400, detail="no updatable fields provided")
    try:
        async with _db.acquire() as conn:
            row = await patch_camera(conn, cam_uuid, fields)
    except TransitionError as exc:
        raise HTTPException(status_code=409, detail={
            "error": "invalid_transition", "from": exc.current, "allowed": exc.allowed})
    except SemanticError as exc:
        raise HTTPException(status_code=422, detail=str(exc))
    if row is None:
        raise HTTPException(status_code=404, detail="camera not found")
    return row
```

- [ ] **Step 6:** Run `python -m pytest tests/test_registry_camera_patch.py tests/test_camera_admin.py -q` — Expected: ALL pass (the five shipped patch_camera tests pass unmodified — role/status/failover behavior, journaling, 404, 400s are unchanged). Then full suite.
- [ ] **Step 7 (git-flow-manager):** commit `feat: PATCH /cameras extended to full §5.1 config (D3 transitions, D6 guard, legacy contract intact)`

---

### Task 11: `registry/devices.py` — `DisplayPatch` + `PATCH /displays/{id}`

**Files:**
- Create: `/Users/jn/code/mras-ops/api/src/registry/devices.py`
- Create: `/Users/jn/code/mras-ops/api/tests/test_registry_display_patch.py`
- Modify: `/Users/jn/code/mras-ops/api/src/main.py`

- [ ] **Step 1: Write the failing tests**

```python
"""PATCH /displays/{id} (fleet P2): first display write ever; journals registry_admin."""
import json
import uuid

import pytest

from src.registry.devices import patch_display
from src.registry.lifecycle import TransitionError
from src.registry.writes import SemanticError
from tests.registry_seed import display, org_loc_sys, screen_group

pytestmark = pytest.mark.usefixtures("godview_isolate")


async def test_patch_updates_and_journals_registry_admin_update(projector_pool):
    _, _, sid = await org_loc_sys(projector_pool)
    did = await display(projector_pool, sid, name="Kiosk 1", screen_id="display-1")
    async with projector_pool.acquire() as conn:
        row = await patch_display(conn, did, {"name": "Lobby Kiosk", "display_role": "ambient",
                                              "resolution_width": 1920, "resolution_height": 1080})
    assert row["name"] == "Lobby Kiosk"
    assert row["display_role"] == "ambient"
    assert row["resolution_width"] == 1920
    assert row["screen_id"] == "display-1"                       # identity untouched
    ev = await projector_pool.fetchrow(
        "SELECT system_id, display_id, payload FROM events "
        "WHERE event_type = 'registry_admin' ORDER BY id DESC LIMIT 1")
    assert ev["system_id"] == sid and ev["display_id"] == did
    payload = json.loads(ev["payload"])
    assert payload["object_type"] == "display" and payload["object_id"] == str(did)
    assert payload["action"] == "update"
    assert payload["changes"]["display_role"] == {"from": "primary_ad", "to": "ambient"}


async def test_status_only_patch_journals_action_lifecycle(projector_pool):
    _, _, sid = await org_loc_sys(projector_pool)
    did = await display(projector_pool, sid, screen_id="display-1")
    async with projector_pool.acquire() as conn:
        row = await patch_display(conn, did, {"status": "offline"})
    assert row["status"] == "offline"
    payload = json.loads(await projector_pool.fetchval(
        "SELECT payload FROM events WHERE event_type = 'registry_admin' ORDER BY id DESC LIMIT 1"))
    assert payload["action"] == "lifecycle"


async def test_retired_display_is_terminal(projector_pool):
    _, _, sid = await org_loc_sys(projector_pool)
    did = await display(projector_pool, sid, screen_id="display-1", status="retired")
    async with projector_pool.acquire() as conn:
        with pytest.raises(TransitionError):
            await patch_display(conn, did, {"status": "active"})


async def test_cross_system_group_and_ungroup(projector_pool):
    _, _, sid = await org_loc_sys(projector_pool)
    _, _, other = await org_loc_sys(projector_pool, sys_name="Sys2")
    gid = await screen_group(projector_pool, sid)
    foreign = await screen_group(projector_pool, other)
    did = await display(projector_pool, sid, screen_id="display-1", group=gid)
    async with projector_pool.acquire() as conn:
        with pytest.raises(SemanticError, match="same system"):
            await patch_display(conn, did, {"screen_group_id": foreign})
        row = await patch_display(conn, did, {"screen_group_id": None})   # ungroup
    assert row["screen_group_id"] is None


async def test_unknown_display_returns_none(projector_pool):
    async with projector_pool.acquire() as conn:
        assert await patch_display(conn, uuid.uuid4(), {"name": "x"}) is None


# --- route ---------------------------------------------------------------------

from tests.test_camera_admin import _client


def test_route_validates_and_maps_errors(monkeypatch):
    from unittest.mock import AsyncMock
    with _client(monkeypatch) as client:
        assert client.patch("/displays/not-a-uuid", json={"name": "x"}).status_code == 400
        assert client.patch(f"/displays/{uuid.uuid4()}", json={}).status_code == 400
        assert client.patch(f"/displays/{uuid.uuid4()}", json={"screen_id": "evil"}).status_code == 422
        assert client.patch(f"/displays/{uuid.uuid4()}", json={"display_role": "boss"}).status_code == 422
    monkeypatch.setattr("src.main.patch_display", AsyncMock(return_value=None))
    with _client(monkeypatch) as client:
        assert client.patch(f"/displays/{uuid.uuid4()}", json={"name": "x"}).status_code == 404
```

Run — Expected: FAIL. **Step 2 (git-flow-manager):** commit `test: display PATCH (registry_admin journal, D3/D6, route mapping)`

- [ ] **Step 3: Implement** `src/registry/devices.py`

```python
"""Admin display writes + device creation (fleet P2, spec D6/D7/D8/D10).

Mirrors src/cameras.py: strict pydantic extra="forbid", FOR UPDATE + UPDATE +
journal in ONE transaction, enum text casts. Displays never had a legacy event
type, so everything here journals the generic registry_admin event (D10).
Creates are staged (D7: status hardcoded 'offline') and mint the devices
identity row when device_id is absent (D8).
"""
import uuid
from typing import Literal, Optional

from pydantic import BaseModel, ConfigDict

from src.registry.lifecycle import check_transition
from src.registry.writes import (SemanticError, build_set_clause, ensure_same_system,
                                 jsonable, journal_registry_admin, reject_nulls)

_DISPLAY_ROLES = Literal["primary_ad", "secondary_ad", "ambient", "status"]
_DEVICE_STATUSES = Literal["active", "degraded", "offline", "retired"]


class DisplayPatch(BaseModel):
    model_config = ConfigDict(extra="forbid")   # identity/state schema-rejected (D1/D2)
    name: Optional[str] = None
    display_role: Optional[_DISPLAY_ROLES] = None
    status: Optional[_DEVICE_STATUSES] = None
    screen_group_id: Optional[uuid.UUID] = None
    resolution_width: Optional[int] = None
    resolution_height: Optional[int] = None
    calibration: Optional[dict] = None


_PATCH_NULLABLE = frozenset({"name", "screen_group_id", "resolution_width", "resolution_height"})
_CASTS = {"display_role": "::display_role", "status": "::device_status", "calibration": "::jsonb"}

_RETURNING = ("id, name, system_id, screen_group_id, screen_id, "
              "display_role::text AS display_role, status::text AS status, "
              "resolution_width, resolution_height, calibration, updated_at")


async def patch_display(conn, display_id: uuid.UUID, fields: dict):
    """None = unknown id. Raises TransitionError (409) / SemanticError (422)."""
    reject_nulls(fields, _PATCH_NULLABLE)
    async with conn.transaction():
        before = await conn.fetchrow(
            "SELECT name, display_role::text AS display_role, status::text AS status, "
            "screen_group_id, resolution_width, resolution_height, calibration, system_id "
            "FROM displays WHERE id = $1 FOR UPDATE",
            display_id)
        if before is None:
            return None
        if "status" in fields:
            check_transition(before["status"], fields["status"])            # D3
        if fields.get("screen_group_id") is not None:
            await ensure_same_system(conn, fields["screen_group_id"], before["system_id"])  # D6
        set_sql, args = build_set_clause(fields, _CASTS)
        row = await conn.fetchrow(
            f"UPDATE displays SET {set_sql}, updated_at = now() "
            f"WHERE id = $1 RETURNING {_RETURNING}",
            display_id, *args)
        changes = {k: {"from": jsonable(before[k]), "to": jsonable(row[k])} for k in fields}
        await journal_registry_admin(
            conn, object_type="display", object_id=display_id,
            action="lifecycle" if set(fields) == {"status"} else "update",
            changes=changes, system_id=before["system_id"], display_id=display_id)
    return dict(row)
```

- [ ] **Step 4: Route in `src/main.py`** (import `DisplayPatch, patch_display` from `src.registry.devices`):

```python
@app.patch("/displays/{display_id}")
async def update_display(display_id: str, patch: DisplayPatch):
    disp_uuid = _uuid_or_400(display_id)
    fields = patch.model_dump(exclude_unset=True)
    if not fields:
        raise HTTPException(status_code=400, detail="no updatable fields provided")
    try:
        async with _db.acquire() as conn:
            row = await patch_display(conn, disp_uuid, fields)
    except TransitionError as exc:
        raise HTTPException(status_code=409, detail={
            "error": "invalid_transition", "from": exc.current, "allowed": exc.allowed})
    except SemanticError as exc:
        raise HTTPException(status_code=422, detail=str(exc))
    if row is None:
        raise HTTPException(status_code=404, detail="display not found")
    return row
```

- [ ] **Step 5:** Run `python -m pytest tests/test_registry_display_patch.py -q` — Expected: 6 passed. Full suite green.
- [ ] **Step 6 (git-flow-manager):** commit `feat: PATCH /displays/{id} (first display write; registry_admin journal)`

---

### Task 12: `POST /cameras` + `POST /displays` (D7 staged-offline, D8 devices row)

**Files:**
- Modify: `/Users/jn/code/mras-ops/api/src/registry/devices.py`
- Create: `/Users/jn/code/mras-ops/api/tests/test_registry_create.py`
- Modify: `/Users/jn/code/mras-ops/api/src/main.py`

- [ ] **Step 1: Write the failing tests**

```python
"""POST /cameras + /displays: staged creation (D7), devices identity row (D8),
registry_admin action=create (D10)."""
import json
import uuid

import pytest

import asyncpg

from src.registry.devices import CameraCreate, DisplayCreate, create_camera, create_display
from src.registry.writes import SemanticError
from tests.registry_seed import org_loc_sys, screen_group

pytestmark = pytest.mark.usefixtures("godview_isolate")


async def test_create_camera_is_offline_and_mints_device_row(projector_pool):
    _, loc, sid = await org_loc_sys(projector_pool)
    body = CameraCreate(system_id=sid, name="New Cam", screen_id="scr_new",
                        calibration={"cam_index": 1}, serial_number="SN-1")
    async with projector_pool.acquire() as conn:
        row = await create_camera(conn, body)
    assert row["status"] == "offline"                      # D7: staged, never live at birth
    assert row["camera_role"] == "detection"
    assert row["screen_id"] == "scr_new"
    assert row["location_id"] == loc                       # denormalized from the system
    dev = await projector_pool.fetchrow(
        "SELECT system_id, location_id, device_type::text AS device_type, name, "
        "serial_number, status::text AS status FROM devices WHERE id = $1", row["device_id"])
    assert dev is not None                                 # D8: identity row in the SAME txn
    assert dev["device_type"] == "camera" and dev["system_id"] == sid
    assert dev["name"] == "New Cam" and dev["serial_number"] == "SN-1"
    assert dev["status"] == "offline"
    ev = json.loads(await projector_pool.fetchval(
        "SELECT payload FROM events WHERE event_type = 'registry_admin' ORDER BY id DESC LIMIT 1"))
    assert ev["action"] == "create" and ev["object_id"] == str(row["id"])
    assert ev["changes"]["status"] == {"from": None, "to": "offline"}


async def test_create_camera_without_screen_id_or_name(projector_pool):
    _, _, sid = await org_loc_sys(projector_pool)
    async with projector_pool.acquire() as conn:
        row = await create_camera(conn, CameraCreate(system_id=sid))
    assert row["screen_id"] is None                        # nullable for cameras (012)
    dev_name = await projector_pool.fetchval(
        "SELECT name FROM devices WHERE id = $1", row["device_id"])
    assert dev_name == "camera"                            # devices.name NOT NULL fallback


async def test_create_camera_respects_supplied_device_id(projector_pool):
    _, loc, sid = await org_loc_sys(projector_pool)
    dev = uuid.uuid4()
    await projector_pool.execute(
        "INSERT INTO devices (id,system_id,device_type,name) VALUES ($1,$2,'camera','pre')", dev, sid)
    async with projector_pool.acquire() as conn:
        row = await create_camera(conn, CameraCreate(system_id=sid, device_id=dev))
    assert row["device_id"] == dev
    assert await projector_pool.fetchval("SELECT count(*) FROM devices") == 1   # no extra row


async def test_create_rejects_unknown_system_and_cross_system_group(projector_pool):
    _, _, sid = await org_loc_sys(projector_pool)
    _, _, other = await org_loc_sys(projector_pool, sys_name="Sys2")
    foreign = await screen_group(projector_pool, other)
    async with projector_pool.acquire() as conn:
        with pytest.raises(SemanticError, match="unknown system_id"):
            await create_camera(conn, CameraCreate(system_id=uuid.uuid4()))
        with pytest.raises(SemanticError, match="same system"):
            await create_camera(conn, CameraCreate(system_id=sid, screen_group_id=foreign))


async def test_create_display_requires_screen_id_and_dupes_conflict(projector_pool):
    _, _, sid = await org_loc_sys(projector_pool)
    async with projector_pool.acquire() as conn:
        row = await create_display(conn, DisplayCreate(system_id=sid, screen_id="display-7",
                                                       display_role="ambient"))
        assert row["status"] == "offline" and row["display_role"] == "ambient"
        with pytest.raises(asyncpg.UniqueViolationError):   # route maps to 409 (delta 1)
            await create_display(conn, DisplayCreate(system_id=sid, screen_id="display-7"))


# --- routes ----------------------------------------------------------------------

from tests.test_camera_admin import _client


def test_post_routes_status_codes(monkeypatch):
    from unittest.mock import AsyncMock
    created = {"id": str(uuid.uuid4()), "status": "offline"}
    monkeypatch.setattr("src.main.create_camera", AsyncMock(return_value=created))
    with _client(monkeypatch) as client:
        r = client.post("/cameras", json={"system_id": str(uuid.uuid4())})
        assert r.status_code == 201 and r.json()["status"] == "offline"
        # D7: status at birth is not writable — extra="forbid"
        assert client.post("/cameras", json={"system_id": str(uuid.uuid4()),
                                             "status": "active"}).status_code == 422
        # DisplayCreate requires screen_id (NOT NULL, 012)
        assert client.post("/displays", json={"system_id": str(uuid.uuid4())}).status_code == 422
    monkeypatch.setattr("src.main.create_display",
                        AsyncMock(side_effect=asyncpg.UniqueViolationError("dup")))
    with _client(monkeypatch) as client:
        r = client.post("/displays", json={"system_id": str(uuid.uuid4()), "screen_id": "d-1"})
        assert r.status_code == 409
        assert r.json()["detail"] == "screen_id already registered"
```

Run — Expected: FAIL. **Step 2 (git-flow-manager):** commit `test: device creation (staged offline, devices row, dupes, route codes)`

- [ ] **Step 3: Implement** (append to `src/registry/devices.py`)

```python
_CAMERA_ROLES = Literal["detection", "enrollment", "audience_measurement",
                        "security_context", "standby"]


class CameraCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")   # D7: no status field at birth
    system_id: uuid.UUID
    screen_id: Optional[str] = None             # nullable for cameras (012)
    name: Optional[str] = None
    camera_role: _CAMERA_ROLES = "detection"
    failover_eligible: bool = False
    screen_group_id: Optional[uuid.UUID] = None
    stream_url: Optional[str] = None
    calibration: dict = {}
    device_id: Optional[uuid.UUID] = None       # D8: identity row minted when absent
    serial_number: Optional[str] = None
    external_device_key: Optional[str] = None


class DisplayCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    system_id: uuid.UUID
    screen_id: str                              # NOT NULL on displays (012)
    name: Optional[str] = None
    display_role: _DISPLAY_ROLES = "primary_ad"
    screen_group_id: Optional[uuid.UUID] = None
    resolution_width: Optional[int] = None
    resolution_height: Optional[int] = None
    calibration: dict = {}
    device_id: Optional[uuid.UUID] = None
    serial_number: Optional[str] = None
    external_device_key: Optional[str] = None


async def _resolve_system(conn, system_id):
    row = await conn.fetchrow("SELECT location_id FROM systems WHERE id = $1", system_id)
    if row is None:
        raise SemanticError("unknown system_id")
    return row["location_id"]


async def _resolve_device_id(conn, body, device_type: str):
    """D8: mint the devices identity row (same txn, staged offline) unless supplied."""
    if body.device_id is not None:
        if await conn.fetchval("SELECT 1 FROM devices WHERE id = $1", body.device_id) is None:
            raise SemanticError("unknown device_id")
        return body.device_id
    return await conn.fetchval(
        "INSERT INTO devices (system_id, location_id, device_type, name, "
        "                     external_device_key, serial_number, status) "
        "VALUES ($1, $2, $3::device_type, $4, $5, $6, 'offline') RETURNING id",
        body.system_id, await _resolve_system(conn, body.system_id), device_type,
        body.name or body.screen_id or device_type,
        body.external_device_key, body.serial_number)


def _birth_changes(row, fields) -> dict:
    return {f: {"from": None, "to": jsonable(row[f])} for f in fields}


_CAMERA_RETURNING = ("id, device_id, system_id, location_id, screen_id, name, "
                     "camera_role::text AS camera_role, failover_eligible, screen_group_id, "
                     "stream_url, calibration, status::text AS status, created_at, updated_at")


async def create_camera(conn, body: CameraCreate) -> dict:
    import json as _json
    async with conn.transaction():
        location_id = await _resolve_system(conn, body.system_id)
        if body.screen_group_id is not None:
            await ensure_same_system(conn, body.screen_group_id, body.system_id)
        device_id = await _resolve_device_id(conn, body, "camera")
        row = await conn.fetchrow(
            "INSERT INTO cameras (device_id, system_id, location_id, name, camera_role, "
            "                     stream_url, screen_id, screen_group_id, failover_eligible, "
            "                     status, calibration) "
            "VALUES ($1, $2, $3, $4, $5::camera_role, $6, $7, $8, $9, 'offline', $10::jsonb) "
            "RETURNING " + _CAMERA_RETURNING,
            device_id, body.system_id, location_id, body.name, body.camera_role,
            body.stream_url, body.screen_id, body.screen_group_id, body.failover_eligible,
            _json.dumps(body.calibration))
        await journal_registry_admin(
            conn, object_type="camera", object_id=row["id"], action="create",
            changes=_birth_changes(row, ("device_id", "system_id", "location_id", "screen_id",
                                         "name", "camera_role", "failover_eligible",
                                         "screen_group_id", "stream_url", "calibration", "status")),
            system_id=body.system_id, camera_id=row["id"])
    return dict(row)


_DISPLAY_CREATE_RETURNING = ("id, device_id, system_id, location_id, screen_id, name, "
                             "display_role::text AS display_role, screen_group_id, "
                             "resolution_width, resolution_height, calibration, "
                             "status::text AS status, created_at, updated_at")


async def create_display(conn, body: DisplayCreate) -> dict:
    import json as _json
    async with conn.transaction():
        location_id = await _resolve_system(conn, body.system_id)
        if body.screen_group_id is not None:
            await ensure_same_system(conn, body.screen_group_id, body.system_id)
        device_id = await _resolve_device_id(conn, body, "display")
        row = await conn.fetchrow(
            "INSERT INTO displays (device_id, system_id, location_id, name, screen_id, "
            "                      display_role, screen_group_id, resolution_width, "
            "                      resolution_height, status, calibration) "
            "VALUES ($1, $2, $3, $4, $5, $6::display_role, $7, $8, $9, 'offline', $10::jsonb) "
            "RETURNING " + _DISPLAY_CREATE_RETURNING,
            device_id, body.system_id, location_id, body.name, body.screen_id,
            body.display_role, body.screen_group_id, body.resolution_width,
            body.resolution_height, _json.dumps(body.calibration))
        await journal_registry_admin(
            conn, object_type="display", object_id=row["id"], action="create",
            changes=_birth_changes(row, ("device_id", "system_id", "location_id", "screen_id",
                                         "name", "display_role", "screen_group_id",
                                         "resolution_width", "resolution_height",
                                         "calibration", "status")),
            system_id=body.system_id, display_id=row["id"])
    return dict(row)
```

(Move the `import json as _json` to a single top-of-module `import json` if preferred — shown inline here only to make the jsonb bind explicit.)

- [ ] **Step 4: Routes in `src/main.py`** (import `CameraCreate, DisplayCreate, create_camera, create_display`):

```python
@app.post("/cameras", status_code=201)
async def register_camera(body: CameraCreate):
    try:
        async with _db.acquire() as conn:
            return await create_camera(conn, body)
    except SemanticError as exc:
        raise HTTPException(status_code=422, detail=str(exc))
    except asyncpg.UniqueViolationError:
        raise HTTPException(status_code=409, detail="screen_id already registered")


@app.post("/displays", status_code=201)
async def register_display(body: DisplayCreate):
    try:
        async with _db.acquire() as conn:
            return await create_display(conn, body)
    except SemanticError as exc:
        raise HTTPException(status_code=422, detail=str(exc))
    except asyncpg.UniqueViolationError:
        raise HTTPException(status_code=409, detail="screen_id already registered")
```

- [ ] **Step 5:** Run `python -m pytest tests/test_registry_create.py -q` — Expected: 6 passed. Full suite green.
- [ ] **Step 6 (git-flow-manager):** commit `feat: POST /cameras + /displays (D7 staged offline, D8 identity row, 409 on dup screen_id)`

---

### Task 13 (DROPPABLE — D11): `POST /displays/adopt`

Dropping this task removes only `src/registry/adopt.py`, its route block, and its test file; nothing else references them. `GET /unresolved-devices` already shipped in P1.

**Files:**
- Create: `/Users/jn/code/mras-ops/api/src/registry/adopt.py`
- Create: `/Users/jn/code/mras-ops/api/tests/test_registry_adopt.py`
- Modify: `/Users/jn/code/mras-ops/api/src/main.py`

- [ ] **Step 1: Write the failing tests**

```python
"""POST /displays/adopt (D11, droppable): unresolved row -> real display, one txn."""
import json
import uuid

import pytest

from src.registry.adopt import AdoptBody, adopt_display
from src.registry.writes import SemanticError
from tests.registry_seed import org_loc_sys, screen_group, unresolved

pytestmark = pytest.mark.usefixtures("godview_isolate")


async def test_adopt_creates_display_deletes_row_journals_adopt(projector_pool):
    _, _, sid = await org_loc_sys(projector_pool)
    uid = await unresolved(projector_pool, screen_id="display-9", kind="display", seen_count=3)
    async with projector_pool.acquire() as conn:
        row = await adopt_display(conn, AdoptBody(unresolved_id=uid, system_id=sid, name="Kiosk 9"))
    assert row["screen_id"] == "display-9"                   # pre-filled from the unresolved row
    assert row["status"] == "offline"                        # D7 staging applies to adoption too
    assert row["name"] == "Kiosk 9"
    assert row["device_id"] is not None                      # D8 identity row minted
    assert await projector_pool.fetchval("SELECT count(*) FROM unresolved_devices") == 0
    ev = json.loads(await projector_pool.fetchval(
        "SELECT payload FROM events WHERE event_type = 'registry_admin' ORDER BY id DESC LIMIT 1"))
    assert ev["action"] == "adopt" and ev["object_id"] == str(row["id"])
    assert ev["adopted_from"] == {"unresolved_id": str(uid), "screen_id": "display-9",
                                  "seen_count": 3}


async def test_adopt_into_group_same_system_only(projector_pool):
    _, _, sid = await org_loc_sys(projector_pool)
    _, _, other = await org_loc_sys(projector_pool, sys_name="Sys2")
    foreign = await screen_group(projector_pool, other)
    uid = await unresolved(projector_pool, screen_id="display-9")
    async with projector_pool.acquire() as conn:
        with pytest.raises(SemanticError, match="same system"):
            await adopt_display(conn, AdoptBody(unresolved_id=uid, system_id=sid,
                                                screen_group_id=foreign))
    assert await projector_pool.fetchval("SELECT count(*) FROM unresolved_devices") == 1  # rollback


async def test_adopt_rejects_camera_kind_and_unknown_id(projector_pool):
    _, _, sid = await org_loc_sys(projector_pool)
    uid = await unresolved(projector_pool, screen_id="scr_ghost", kind="camera")
    async with projector_pool.acquire() as conn:
        with pytest.raises(SemanticError, match="not a display"):
            await adopt_display(conn, AdoptBody(unresolved_id=uid, system_id=sid))
        assert await adopt_display(conn, AdoptBody(unresolved_id=uuid.uuid4(),
                                                   system_id=sid)) is None


# --- route ---------------------------------------------------------------------

from tests.test_camera_admin import _client


def test_adopt_route_codes(monkeypatch):
    from unittest.mock import AsyncMock
    monkeypatch.setattr("src.main.adopt_display", AsyncMock(return_value=None))
    with _client(monkeypatch) as client:
        r = client.post("/displays/adopt",
                        json={"unresolved_id": str(uuid.uuid4()), "system_id": str(uuid.uuid4())})
        assert r.status_code == 404
        assert r.json()["detail"] == "unresolved device not found"
        assert client.post("/displays/adopt", json={"system_id": str(uuid.uuid4())}).status_code == 422
```

Run — Expected: FAIL. **Step 2 (git-flow-manager):** commit `test: adopt-unresolved flow (create+delete+journal in one txn)`

- [ ] **Step 3: Implement** `src/registry/adopt.py`

```python
"""Adopt an unresolved (seen-but-unregistered) display (spec D11 — UniFi/Meraki
pattern). One transaction: create the display with the unresolved row's
screen_id pre-filled (staged offline, D7; identity row minted, D8), DELETE the
unresolved bookkeeping row, journal registry_admin action=adopt. DROPPABLE:
nothing else imports this module."""
import uuid
from typing import Optional

from pydantic import BaseModel, ConfigDict

from src.registry.devices import DisplayCreate, create_display
from src.registry.writes import SemanticError


class AdoptBody(BaseModel):
    model_config = ConfigDict(extra="forbid")   # D11's exact body: no other fields
    unresolved_id: uuid.UUID
    system_id: uuid.UUID
    name: Optional[str] = None
    screen_group_id: Optional[uuid.UUID] = None


async def adopt_display(conn, body: AdoptBody):
    """None = unknown unresolved_id. Raises SemanticError (422); a duplicate
    screen_id (already-registered race) raises UniqueViolationError (route: 409)."""
    async with conn.transaction():
        unres = await conn.fetchrow(
            "SELECT id, screen_id, kind, seen_count FROM unresolved_devices "
            "WHERE id = $1 FOR UPDATE", body.unresolved_id)
        if unres is None:
            return None
        if unres["kind"] != "display":
            raise SemanticError("unresolved device is not a display")
        row = await create_display(conn, DisplayCreate(
            system_id=body.system_id, screen_id=unres["screen_id"],
            name=body.name, screen_group_id=body.screen_group_id))
        await conn.execute("DELETE FROM unresolved_devices WHERE id = $1", body.unresolved_id)
        await conn.execute(
            "UPDATE events SET payload = payload || $2::jsonb "
            "WHERE id = (SELECT max(id) FROM events WHERE event_type = 'registry_admin' "
            "            AND payload->>'object_id' = $1)",
            str(row["id"]),
            __import__("json").dumps({"action": "adopt", "adopted_from": {
                "unresolved_id": str(unres["id"]), "screen_id": unres["screen_id"],
                "seen_count": unres["seen_count"]}}))
    return row
```

IMPLEMENTER NOTE (cleaner alternative, pick one and journal the choice): instead of rewriting the create's journal row afterwards, refactor `create_display` to accept `action="create"`/`extra=None` passthrough parameters and call it with `action="adopt", extra={"adopted_from": {...}}` — one event written once. The UPDATE shown above works (same txn, targets the row just written via the 028 index) but two-step journaling is uglier; the passthrough refactor is ~4 lines in `create_display` and keeps `journal_registry_admin` calls single-shot. Either way the resulting event payload MUST match the test above (`action: "adopt"`, `adopted_from` block), and `__import__("json")` must become a normal top-level import if kept.

- [ ] **Step 4: Route in `src/main.py`** (import `AdoptBody, adopt_display`):

```python
@app.post("/displays/adopt", status_code=201)
async def adopt_unresolved_display(body: AdoptBody):
    try:
        async with _db.acquire() as conn:
            row = await adopt_display(conn, body)
    except SemanticError as exc:
        raise HTTPException(status_code=422, detail=str(exc))
    except asyncpg.UniqueViolationError:
        raise HTTPException(status_code=409, detail="screen_id already registered")
    if row is None:
        raise HTTPException(status_code=404, detail="unresolved device not found")
    return row
```

(`POST /displays/adopt` cannot be shadowed: the only parameterized display route is `PATCH /displays/{display_id}` — different method.)

- [ ] **Step 5:** Run `python -m pytest tests/test_registry_adopt.py -q` — Expected: 4 passed. Full suite green (`python -m pytest tests -q`).
- [ ] **Step 6 (git-flow-manager):** commit `feat: POST /displays/adopt (D11 — kills the unresolved-devices banner properly)`

---

### Task 14: Live verification against :8080

Run each step and eyeball the output; the smoke objects created here are cleaned up by RETIRING them (D4 — no deletes).

- [ ] **Step 1 — stack + migration:**
```bash
cd /Users/jn/code/mras-ops && docker compose up -d
docker compose exec -T postgres psql -U mras -d mras < db/migrations/028_registry_admin_audit.sql
# expect: CREATE INDEX / CREATE INDEX (or NOTICE ... already exists on re-run)
# restart the api so the new routes load, then:
curl -s localhost:8080/health          # {"status":"ok"}
```
- [ ] **Step 2 — P1 tree walk (each level bounded, counts present):**
```bash
curl -s 'localhost:8080/locations' | jq '{counts, first: .items[0], next_cursor}'
LOC=$(curl -s 'localhost:8080/locations' | jq -r '.items[0].id')
curl -s "localhost:8080/systems?location_id=$LOC" | jq '.items[] | {name, device_count, status}'
SYS=$(curl -s "localhost:8080/systems?location_id=$LOC" | jq -r '.items[0].id')
curl -s "localhost:8080/screen-groups?system_id=$SYS" | jq '.counts'
curl -s "localhost:8080/cameras?system_id=$SYS" | jq '.items[] | {name, status, effective_duty, failover_eligible}'
curl -s "localhost:8080/cameras" -w '%{http_code}\n' -o /dev/null          # 422 (scope XOR)
```
- [ ] **Step 3 — detail split (D1/D2):**
```bash
CAM=$(curl -s "localhost:8080/cameras?system_id=$SYS" | jq -r '.items[0].id')
curl -s "localhost:8080/cameras/$CAM" | jq '{identity, config, state}'
# identity has screen_id/system_id; config has status+calibration (object); state has effective_duty
```
- [ ] **Step 4 — legacy camera contract unchanged, then a new config field:**
```bash
curl -s -X PATCH "localhost:8080/cameras/$CAM" -H 'content-type: application/json' \
  -d '{"failover_eligible": true}' | jq '{failover_eligible, status}'       # 200, as before TODO-8
curl -s -X PATCH "localhost:8080/cameras/$CAM" -H 'content-type: application/json' \
  -d '{"name": "Renamed via Fleet API"}' | jq .name
curl -s -X PATCH "localhost:8080/cameras/$CAM" -H 'content-type: application/json' \
  -d '{"screen_id": "evil"}' -w '%{http_code}\n' -o /dev/null               # 422 (identity, D2)
```
- [ ] **Step 5 — staged creation + D3 terminal retired (on a THROWAWAY camera, not a real one):**
```bash
SMOKE=$(curl -s -X POST localhost:8080/cameras -H 'content-type: application/json' \
  -d "{\"system_id\": \"$SYS\", \"name\": \"fleet-smoke-cam\"}")
echo "$SMOKE" | jq '{id, status}'                                           # status "offline" (D7)
SMOKE_ID=$(echo "$SMOKE" | jq -r .id)
curl -s -X PATCH "localhost:8080/cameras/$SMOKE_ID" -H 'content-type: application/json' \
  -d '{"status": "active"}' | jq .status                                    # offline -> active OK
curl -s -X PATCH "localhost:8080/cameras/$SMOKE_ID" -H 'content-type: application/json' \
  -d '{"status": "retired"}' | jq .status                                   # -> retired
curl -s -X PATCH "localhost:8080/cameras/$SMOKE_ID" -H 'content-type: application/json' \
  -d '{"status": "active"}' | jq .                                          # 409 {error, from: "retired", allowed: []}
```
- [ ] **Step 6 — audit trail (index-served, both event types):**
```bash
curl -s "localhost:8080/registry/audit?object_id=$SMOKE_ID&limit=20" \
  | jq '.items[] | {event_type, action: .payload.action}'
# expect registry_admin create + lifecycle rows; for $CAM expect camera_admin rows
docker compose exec -T postgres psql -U mras -d mras -c \
  "EXPLAIN SELECT id FROM events WHERE event_type='registry_admin' \
   AND payload->>'object_id'='x' ORDER BY id DESC LIMIT 20;" | grep -i events_registry_admin_idx
```
- [ ] **Step 7 — display write + adopt (skip the adopt half if Task 13 was dropped):**
```bash
curl -s localhost:8080/unresolved-devices | jq '{counts, items: [.items[] | {screen_id, kind, seen_count}]}'
UNRES=$(curl -s localhost:8080/unresolved-devices | jq -r '[.items[] | select(.kind=="display")][0].id')
curl -s -X POST localhost:8080/displays/adopt -H 'content-type: application/json' \
  -d "{\"unresolved_id\": \"$UNRES\", \"system_id\": \"$SYS\", \"name\": \"adopted-kiosk\"}" \
  | jq '{id, screen_id, status}'                                            # 201, offline, screen_id pre-filled
curl -s localhost:8080/unresolved-devices | jq '.counts.total'              # decremented
DISP=$(curl -s "localhost:8080/displays?system_id=$SYS" | jq -r '.items[0].id')
curl -s -X PATCH "localhost:8080/displays/$DISP" -H 'content-type: application/json' \
  -d '{"resolution_width": 1920, "resolution_height": 1080}' | jq '{resolution_width, resolution_height}'
```
- [ ] **Step 8 — Plan B smoke:** point godview-prototype at :8080, open `/fleet`, walk tree → drawer → rename a camera → History shows the event. (Owner step; Plan B Task 16 has the full script.)
- [ ] **Step 9 — cleanup:** retire the smoke devices (`{"status": "retired"}` on `$SMOKE_ID`, the adopted display, and any other objects created here). D4: retired rows stay forever; that is the design.
- [ ] **Step 10 (git-flow-manager):** merge per repo convention (superpowers:finishing-a-development-branch).

## Execution order & dependencies

```
Task 0 -> 1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7   (P1 shippable after 7)
              7 -> 8 -> 9 -> 10 -> 11 -> 12 -> 13 (DROPPABLE) -> 14
```
Tasks 3–6 depend on 2 (paging) and 1 only for the audit tests (6). Tasks 10–12 depend on 8+9. Task 13 depends on 12 (reuses `create_display`). Nothing outside Task 13 references adopt.
