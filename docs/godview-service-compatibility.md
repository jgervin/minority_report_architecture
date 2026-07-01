# MRAS God View — Service Compatibility Assessment

_Date: 2026-07-01. Based on static analysis of the shipped schema (migrations 010–017) against live service code._

---

## Bottom Line

The new schema (migrations 010–017) is a complete, correct reader half: the event journal, summary tables,
scope columns, and audit infrastructure are all in place. The writer and plumbing half is almost entirely
unbuilt. Four of the five services require code changes before the God View can show real data — only
`mras-overlays` is unaffected. The events-table reshape was purely additive (new columns only), so existing
`INSERT INTO events` calls in all services continue to work without modification; no event write breaks today.
What breaks are the service-side reads/writes to the tables that were replaced (`identities`,
`identity_embeddings`) and the two projector-side systems (T2 projector + T3 device registry) that do not
yet exist in `mras-ops`. Until T2 and T3 are built, the summary tables stay empty, every scope column stays
NULL, and the God View's history panels show nothing — even if the other four services are fixed first.

---

## Per-Service Verdict

| Service | Verdict | Concrete reason |
|---|---|---|
| **mras-overlays** | **WORKS** | Stateless Remotion render/bundler sidecar. Zero Postgres or Qdrant access (no pg/prisma/drizzle). Its only schema-adjacent surface is an HTTP `status` field (`ready`/`failed`) — both values remain valid. Entirely unaffected. |
| **mras-ops** | **NEEDS-CHANGE** | Existing components/ads CRUD and the events SSE stream (`/events/stream`) all still work — the schema was additive there. But the **projector (T2)** and the **device-registration + `screen_id`→uuid resolver (T3)** do not exist anywhere in `/Users/jn/code/mras-ops/`. The load-bearing half of the God View model is absent. |
| **mras-display** | **NEEDS-CHANGE (greenfield)** | Pure Electron kiosk, no DB layer. Cannot break against the schema directly, but emits no `playback` events, carries no `trigger_id` anywhere in its codebase, and its inbound `play` WebSocket message carries none either. T4 (display event emission) is entirely new work with a hidden dependency on composer propagating `trigger_id` first. |
| **mras-composer** | **BREAKS** | Blocklist gate at `/Users/jn/code/mras-composer/src/selector/selector.py:35,93` issues `SELECT name, is_blocked FROM identities WHERE uuid=$1` — table and both columns are dropped. This is a privacy-critical path that errors on any suppression check. Additionally: `trigger_id` is corrupted (see Live Bugs §4), and the idle path emits no event and no `trigger_id`. |
| **mras-vision** | **BREAKS (hard)** | Reads and writes the dropped `identities` and `identity_embeddings` tables throughout — reconciler, enroller, gallery, augment, and name-lookup paths are all dead on arrival. Ships its own stale `/Users/jn/code/mras-vision/db/schema.sql` that still declares the old schema. Recognition and enrollment cannot function after the 010–017 migrations land. |

---

## Ranked Gap List

Ordered by blocking severity: a higher-ranked gap renders lower-ranked gaps irrelevant until it is resolved.

**1. Projector (T2) and device registry (T3) are absent and the absence is silent.**
The event journal grows but `ad_runs`, `playbacks`, `viewer_exposures`, `subject_observations`,
`composition_runs`, and `observation_tracks` stay permanently empty. Scope columns on every summary row stay
NULL. The God View shows a healthy-looking but empty history. No amount of service-side fixes matters until
T2 is built. T3 (device registration) is a prerequisite for scope resolution — the projector has nothing to
look up until `cameras.screen_id` and `displays.screen_id` are populated via an admin UI or seed.

**2. `screen_id` is an overloaded namespace (known contract, D-E).**
`mras-vision` emits `screen_id` to mean a camera ID (default value `screen_0`,
`/Users/jn/code/mras-vision/src/identity/resolver.py:17`). `mras-composer` and `mras-display` emit
`screen_id` to mean a display ID (e.g. `display-2`, `/Users/jn/code/mras-composer/main.py:418`). Same JSON
key, two entirely different device dimensions. The projector must disambiguate by the emitting service before
resolving against `cameras.screen_id` vs `displays.screen_id`, or it will stamp the wrong uuid. This
overloading is documented as a known contract (D-E) rather than a defect; the projector owns the
disambiguation logic.

**3. Qdrant keyspace is orphaned — nothing writes `subject_embeddings`.**
Vision's Qdrant point IDs are derived from the dropped `identities.uuid` /
`identity_embeddings.id` (used at `/Users/jn/code/mras-vision/src/identity/reconciler.py:39`,
`/Users/jn/code/mras-vision/src/identity/gallery.py:27`,
`/Users/jn/code/mras-vision/src/enrollment/enroller.py:116`).
The new `subject_embeddings.qdrant_point_id` / `qdrant_collection` columns — the bridge between Postgres
and Qdrant in the new schema — are written by no code anywhere. Re-enrollment (T5) is therefore not just
"re-add faces": there is currently zero code path that creates a `subject_embeddings` row, so recognition
reads `WHERE status='active'` against an empty table and silently matches no one.

**4. Composer blocklist reads dropped `identities` — privacy-critical suppression fails.**
`/Users/jn/code/mras-composer/src/selector/selector.py:35` and `:93` issue
`SELECT name, is_blocked FROM identities WHERE uuid=$1`. The table is dropped. If the error is swallowed
anywhere up the call stack, the guard at selector.py:37 (`row is None → return std`) fails open to the
standard ad. That is the safe-for-suppression direction, but the blocklist "circularity" TODO (Decision 9)
means the full suppression path against `blocklist_entries` is unproven. This must be fixed before any
blocked-subject flow is exercised live.

**5. `trigger_id` chain has two breaks; under the new schema they become projector INSERT failures.**
Under the old schema these were fuzzy-join annoyances. Under the new schema `ad_runs.UNIQUE(trigger_id)`
and `playbacks.UNIQUE(trigger_id, display_id)` are NOT NULL constraints — a missing, malformed, or
duplicate `trigger_id` turns into a projector INSERT failure that stalls summary table population silently,
compounding gap #1. The two specific breaks are detailed in §4 (Live Bugs).

---

## Live Bugs

**Bug 1 — composer `trigger_id` corruption (being fixed now, composer-only)**

- File: `/Users/jn/code/mras-composer/main.py:417`
- Defect: `trigger_id` is set to `owner`, which is a subject uuid, not a per-trigger uuid. Every
  orchestrated `playback` event written to `events` carries a subject uuid in the `trigger_id` column.
- Impact: `ad_runs.UNIQUE(trigger_id)` — keyed on what is supposed to be a stable per-play identifier —
  receives a subject uuid. If the same subject triggers two sequential plays, the second INSERT collides
  on the UNIQUE constraint and the projector skips it. If two different subjects trigger plays the
  constraint is not violated but the semantic is wrong (subject B's play appears to be subject A's run).
- Fix status: **in progress, composer-only**. The fix is to thread a real per-trigger uuid through the
  orchestration path and pass it in the event payload.

**Bug 2 — mras-vision `augment.py` reads dropped `identity_embeddings` table**

- File: `/Users/jn/code/mras-vision/src/identity/augment.py:66–68`
- Defect: `SELECT id::text, source, embedding FROM identity_embeddings WHERE identity_uuid = $1`. The
  `identity_embeddings` table is dropped in migration 013. This is not a rename — the new schema keeps
  vectors only in Qdrant; the Postgres side has `subject_embeddings.qdrant_point_id` (a reference, not
  the vector). The column `embedding float4[]` no longer exists in Postgres at all.
- `augment.py:97` also issues `DELETE FROM identity_embeddings WHERE id = $1` — same dead table.
- Fix status: **deferred; folded into the vision reroute lane (Lane D)**. Because the fix requires
  simultaneously rerouting the entire identity subsystem (enroller, gallery, reconciler, augment) to
  `subject_profiles` / `subject_embeddings` / Qdrant, patching `augment.py` in isolation would leave a
  half-rerouted state. The lane boundary is the correct unit.

---

## Work Lanes Ahead

The order below reflects blocking dependencies. Lane A must start first; Lanes B, C, D can proceed in
parallel once their Lane A prerequisite (projector accepting events) is understood.

**Lane A — mras-ops: projector + device registry (prerequisite for everything else)**

Build the event-sourcing projector worker (`mras-ops-projector` compose service) and the device-registration
admin UI/seed (T3). The projector tails `events.id` via bigserial cursor, resolves `screen_id` strings to
device uuids, and upserts into the summary tables using the D-A idempotency keys. The device registry
populates `cameras.screen_id` and `displays.screen_id` so the projector has something to look up. See
`/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-01-librarian-projector-design.md`
for the full build spec. Migration 018 (idempotency keys + `projector_state` table) lands as part of this
lane.

**Lane B — mras-display: event emission (depends on Lane C for `trigger_id` propagation)**

Add `playback/started` and `playback/ended` event emissions to the Electron kiosk. Because `mras-display`
has no DB layer, events must be forwarded through the composer's WebSocket terminus or a new ingest
endpoint — not written directly to Postgres. Composer must first propagate `trigger_id` in the inbound
`play` WS message before display can echo it; that composer change is part of Lane C. The idle/shuffle loop
must mint its own `trigger_id` per segment.

**Lane C — mras-composer: `trigger_id` fix + blocklist reroute**

Two scoped changes: (1) fix `trigger_id` corruption at
`/Users/jn/code/mras-composer/main.py:417` — thread a real per-trigger uuid through the orchestration
path and include it in the `play` WS message sent to display; (2) replace the dead blocklist read at
`/Users/jn/code/mras-composer/src/selector/selector.py:35,93` with a query against `blocklist_entries` +
`subject_profiles`. The enforcement seam must be preserved so no suppression regression is possible. Also:
mint a `trigger_id` per idle segment at
`/Users/jn/code/mras-composer/src/orchestrator/runtime.py:36–39` and emit an event carrying it.

**Lane D — mras-vision: full identity subsystem reroute**

Reroute the entire identity subsystem from the dropped `identities` / `identity_embeddings` tables to
`subject_profiles` / `subject_embeddings` / Qdrant. Covers reconciler, enroller, gallery, augment, and all
name-lookup paths (`augment_reporter.py:40`, `main.py:174`). Requires: updating the status enum vocabulary
(`pending→complete` becomes `pending→active`), writing `subject_embeddings.qdrant_point_id` +
`qdrant_collection` at enroll time, re-enrolling faces to re-populate Qdrant under the new point-ID
keyspace, and deleting the stale `/Users/jn/code/mras-vision/db/schema.sql`.

---

## Deferred

The following items are explicitly out of scope until the go-live announcement and must not be treated as
open work for the current build cycle:

- **Biometric-privacy machinery** — consent flows, retention policies, and the legal/regulatory framework
  for handling biometric data at scale.
- **Blocklist circularity** — the architectural question of how `blocklist_entries` is populated without
  creating a dependency loop between the suppression enforcement path and the identity resolution path
  (Decision 9, item 2). The suppression _gate_ (selector.py) must be rerouted to `blocklist_entries` as
  part of Lane C; the circularity question about how entries get _into_ `blocklist_entries` is deferred.
