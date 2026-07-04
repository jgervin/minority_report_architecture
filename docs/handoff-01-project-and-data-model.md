# Handoff 01 — Project & Data Model (2026-07-03)

> **Read this first.** Overview of what MRAS is and its full data model, grounded in the **live schema**
> (36 tables, verified 2026-07-03). Then read `handoff-02-session-state.md` (what's committed, how to run)
> and `handoff-03-peelback-orchestration-spec.md` (the next task). Deep history:
> `docs/SESSION_LOG.md` (2026-07-03 entry). Numbered handoffs are sequential — the next session adds `04`.

## What the project is and does

**MRAS (AdFace)** is a Minority Report–style personalized digital-advertising system, demoed live.
Cameras recognize enrolled people in a venue; the system composes a **personalized ad** (the person's
name shown on-screen + spoken via TTS) and plays it on the **displays near them**; it then measures
**who actually watched** (gaze/attention) and records durable exposure data for analytics/billing
("God View"). It is multi-tenant: a venue (mall) plus independent stores each run their own MRAS
*system* of cameras + displays.

**5 repos:**
- **`minority_report_architecture`** — architecture docs, SESSION_LOG, cross-repo source of truth.
- **`mras-vision`** — perception: face detection/recognition, enrollment, gaze/attention tracking
  (Python, runs native on macOS for camera access; DeepFace + Qdrant vector search).
- **`mras-composer`** — ad composition + **display orchestration** (which ad plays on which displays,
  in rounds; ffmpeg + Remotion overlay sidecar + ElevenLabs/Gemini TTS).
- **`mras-display`** — the kiosk/display wall (Electron, one fullscreen window per monitor).
- **`mras-ops`** — the database, API, **projector** ("God View"), and dashboard frontend.

## Architecture — event-sourcing / CQRS

- **`events`** is an append-only journal. The composer, display, and vision services only **APPEND**
  events (a `trigger_id` correlates a whole interaction; `payload` jsonb carries scope + business data).
- **Vision direct-writes** the enrollment/identity tables + Qdrant vectors (recognition needs
  synchronous reads).
- A single-writer **projector ("librarian")** folds `events` into the read-optimized **summary tables**
  and **back-stamps** each event's scope columns.
- **Scope resolution:** every event carries `screen_id` + `screen_kind` (`camera` | `display`). The
  projector's `ScopeResolver` maps that → organization / location / system / camera / display via the
  device registry (`cameras`/`displays`, `UNIQUE(screen_id)`), caching and logging misses to
  `unresolved_devices`. This is how an append-only event gets tenant-scoped.

## The data model (36 tables, live)

**Tenancy & topology** — the venue hierarchy and device registry:
- `organizations`, `organization_relationships` — tenants (mall, stores) and their relationships.
- `locations`, `location_participants` — physical sites. *Note: `locations` has no `organization_id`;
  it links via `systems`.*
- `systems` — a deployed MRAS instance (a store's or the mall's own set of cameras+displays). The unit
  of scope for gaze/co-location.
- `cameras`, `displays` — registered devices (`screen_id`, `screen_kind`), each under a `system`.
- `unresolved_devices` — devices seen in events but not yet registered (audit of scope misses).
- `user_org_scopes` — dashboard access control. `devices`, `components` — generic device/component
  scaffolding.

**Identity** — who people are:
- `subject_profiles` — the person record (`id`, `display_name`, `status`, `first_seen_at`,
  `last_seen_at`). **This replaced the old `identities` table** in the clean-slate schema.
- `subject_embeddings` — per-photo face embeddings (each becomes a Qdrant point; never averaged).
- `identity_enrollments` — enrollment provenance (`source`, `status`).
- `identity_matches` — recognition match records. `subject_profile_merges` — dedupe/merge history.

**Event journal:**
- `events` — append-only log. Columns: `id`, `trigger_id`, `ts`, `service`, `event_type`, `status`,
  `payload` jsonb, `asset_ref`, plus the projector-back-stamped scope FKs (`organization_id`,
  `location_id`, `system_id`, `display_id`, `camera_id`, `subject_profile_id`, `ad_run_id`).

**Observations** — folded perception:
- `subject_observations` — one row per detection: `subject_profile_id`, `camera_track_id` (text; the
  tracker's per-camera id, the **durable cross-event join key**), `observed_at`, `detection_type` (enum:
  face/body/eyes/group/demographic/object), `match_status` (enum), `system_id`/`camera_id`,
  `bounding_box`, `face_quality_score`, `identity_confidence`, and
  `attention_snapshot`/`mood_snapshot`/`demographic_snapshot` jsonb.
- `observation_tracks` — track continuity, keyed `(camera_screen_id, camera_track_id)`.

**Personalization pipeline** — decision → render → play:
- `personalization_decisions` — "play ad X for person Y" (from `decision/made` events).
- `composition_runs` — the render lifecycle (`queued`/`rendering`/`rendered`/`failed`).
- `ad_runs` — a planned/dispatched ad play: `trigger_id`, `target_subject_profile_id`,
  `composition_run_id`, `personalization_decision_id`. *The orchestrator mints a fresh per-round
  `trigger_id` — this is why viewer_exposures needed the `target_subject_profile_id` fallback (see
  handoff-02 fixes).*
- `playbacks` — one row per display playing a clip (`started`/`ended`/`interrupted`), keyed
  `UNIQUE(trigger_id, screen_id)`; links `ad_run_id`, `media_asset_id`.
- `media_assets` — the rendered clip files.

**Analytics — the derived payoff table:**
- `viewer_exposures` — **projector-derived**, one row per (playback × person) exposure. `role`
  (target/bystander), `identity_status`, `watched` (bool), `watch_probability` (numeric),
  `attending_fraction`, `gaze_duration_ms`, `visible_duration_ms`, `distance_estimate_m`, mood /
  expression / demographic snapshots. Links `ad_run_id`, `playback_id`, `subject_profile_id`,
  `subject_observation_id`, `observation_track_id`, plus full scope FKs. **This is the "who watched
  what" record for analytics/billing.**

**Ad catalog & campaigns** (scaffolding, mostly unused today): `ads`, `ad_creatives`, `campaigns`,
`campaign_rules`, `creative_approvals`.

**Governance / compliance:** `blocklist_entries` (deferred until production go-live), `audit_logs`,
`model_runs`.

**Health / ops:** `projector_state` (the projector's forward-only cursor), `device_health_events`,
`system_health_events`.

## The projector ("librarian") — mras-ops PRs #36 → #37 → #38

- **#36** — single-writer worker: session-scoped advisory lock on a dedicated (non-pooled) connection,
  forward-only cursor (`projector_state`), batched fold with a STOP-boundary settle window, per-event
  savepoint, back-stamps all event scope columns, and a `projector.resolve_miss` / `projector.skip`
  audit trail. 7 idempotent handlers upsert the summary tables. Migrations 019 (cursor), 020
  (device-registry `UNIQUE` + `unresolved_devices`), 021 (`playbacks` re-key).
- **#37** — FK-link resolution across the pipeline by shared `trigger_id`, plus the **`viewer_exposures`
  derivation** (fires on `playback` `ended`/`interrupted`). Migration 022 (perf index).
- **#38** — the **gaze → viewer_exposures join** (below) + this session's projector fixes.

## Gaze → viewer_exposures derivation (the "who watched" logic)

- Join key: **`camera_track_id`** (vision emits it on both `detection/success` and `gaze/success`);
  fallback `subject_profile_id`.
- Attention source: **`gaze/success`** events (windowed `attending_fraction` + `samples`, emitted ~every
  3s per track), joined over the playback window `[started_at, ended_at]`, scoped by `system_id`.
- `watched` (target) = TRUE iff any in-window gaze row has `attending_fraction > 0`.
- `watch_probability` (bystander) = MAX in-window `attending_fraction`.
- `attending_fraction` = same max; `gaze_duration_ms` = `round(window_seconds × attending_fraction ×
  1000)`.
- Idempotent COALESCE-on-conflict upsert (re-deriving never wipes a recorded measurement).

## Live-validated state (2026-07-03)

Enroll → recognize → personalized ad on the display wall → projector fold → a correct **target
`viewer_exposures` row** (`watched=TRUE`, `attending_fraction=1.0`, `gaze_duration_ms≈9014` from real
gaze). Populated chain: `subject_observations`=268 → decisions → composition_runs → ad_runs → playbacks
→ viewer_exposures=13. The 4 integration bugs this caught (and their fixes/PRs) are in
`handoff-02-session-state.md`. Schema shipped as God View "Lane A" (mras-ops#34, 2026-06-30; clean-slate
rebuild of the dev DB).
