# God View Domain Model — Engineering Review (pre-spec)

**Reviews:** `/Users/jn/code/minority_report_architecture/docs/god-view-domain-model.md`
**Date:** 2026-06-30  **Reviewer:** plan-eng-review (CTO mode) + independent adversarial subagent
**Scope decision:** Full V1 — all 22 tables from §12.1 (owner chose full over the reviewer's thin-cut recommendation)
**Current reality (source of truth):** 6 tables in `/Users/jn/code/mras-ops/db/migrations/` — `identities`, `identity_embeddings`, `events`, `campaigns`, `components`, `ads`. `events` has **no** scope columns. System is single-venue, pre-alpha.

---

## Locked decisions (12 issues reviewed; D11/Issue 11 withdrawn)

| # | Area | Decision |
|---|------|----------|
| 1 | RBAC | Honor D11: Supabase Auth + JWT custom claims for roles; Postgres holds only a thin `user_org_scopes(user_id, org_id, location_id, role)` map for row-scoping. **Drop** relational `users/roles/permissions/user_memberships`. Role check = claim read, no per-request join. |
| 2 | Event scope | First-class nullable scope columns (`location_id, system_id, display_id, camera_id, subject_profile_id, ad_run_id`) on `events` **and** on every summary table. Composite indexes for the live-feed + drilldown query shapes. No backfill (clean wipe — see #4). |
| 3 | Projector ("the librarian") | One event-sourced projection worker in `mras-ops` reads the append-only `events` log and builds/updates the mutable summary tables (`ad_runs`, `playbacks`, `viewer_exposures`, `subject_observations`). Services write **only** to `events`. Live panels read `events`; history reads summary tables. Reuse the existing 1s poll (`/Users/jn/code/mras-ops/api/src/main.py:177`). Cursor on the `bigserial` PK. **Idempotent via natural unique keys** — one `ad_run` per `trigger_id`, one `playback` per `(trigger_id, display_id)` (per adversarial #9). |
| 4 | Migration | **REVISED → clean-slate rebuild.** Owner confirmed all data is disposable test data (~4 faces in Qdrant, 1–2 named: Jason, maybe Ragnar). Wipe `identities`, `identity_embeddings`, `events`, and the Qdrant collection; `subject_profiles` is the single canonical people table with a fresh `uuid` PK; re-enroll the test faces. No alongside-migration, no keyspace bridge. **Authorized only while pre-alpha** — vanishes after first real enrollment. |
| 5 | PG↔Qdrant | Extend the proven D10 reconciler to `subject_embeddings`: write Postgres `status='pending'` → write Qdrant point → mark `active`; background job retries stuck rows and cleans orphans. Recognition only reads `status='active'`. |
| 6 | `campaigns` | **Confirmed dead** by grep across all 5 repos (referenced only by its own migration). Drop the Phase-0 `serial`-id shell; design `campaigns`/`campaign_rules` fresh with `uuid` keys. |
| 7 | Blocklist test | Full cross-repo E2E **and** unit: enroll blocklisted subject → walk past camera → assert non-personalized ad on display **and** suppression logged with **no name/uuid leak**. (Matches owner's E2E-in-red→green rule for privacy-critical flows.) |
| 8 | `events` growth | Defer partitioning (premature at single-venue). Keep projector cursoring on the PK; route reads through one `events` accessor (no hardcoded `FROM events` scattered). TODO partitioning at a volume/latency trigger. **Watch the projector-written high-volume tables too** (`subject_observations`, `viewer_exposures`, `observation_tracks` — one row per detection frame). |
| 9 | Biometric privacy | **Build as written; handle privacy externally — ACCEPTED RISK (owner decision).** Non-consented anonymous embeddings + `subject_profile_merges` retained; RTBF stays an external process + `status='deleted'` soft flag. Reviewer + adversarial voice both flagged this as the project's largest legal exposure (BIPA per-scan / GDPR special-category / non-consensual re-identification). **TODO: revisit with counsel before leaving pre-alpha.** Blocklist circularity (#2 below) is a *functional* bug regardless — TODO. |
| 10 | Device registry | God View **setup/registration flow** writes `locations/systems/cameras/displays`. Each device row holds three ids: runtime string it emits (`screen_id` e.g. `display-2`), the `uuid` PK, and the operator-assigned human name (structured naming schema, enforced in the form). Projector resolves string→uuid at stamp time via the row. This flow is the **writer** for the canonical device tables — an **Admin device-registration screen is required in V1** (addresses adversarial #7 partially). |
| ~~11~~ | ~~Identity keyspace~~ | **Withdrawn** — dissolved by the #4 clean-slate rebuild. Single keyspace from the first face; no bridge column. |
| 12 | Watch accuracy | Propagate `trigger_id` into the new `playback/started`+`playback/ended` events **and** the idle/shuffle path (idle gets its own `trigger_id`). Target-watched correlates by `trigger_id` (exact). Gaze×time-overlap is for bystanders only, stored as `watch_probability` — UI never shows a boolean "watched" for non-targets. |

### Folded build instructions (no separate decision)
- **DRY enums:** declare shared Postgres `CREATE TYPE` enums for the repeated `active/inactive/degraded/offline/retired` and `pending/active/...` sets; reuse across tables instead of inline `CHECK` per table.
- **Drop speculative columns** (adversarial #10, CLAUDE.md §2): remove `embedding_type` values `body/gait/voice/clothing` until the pipeline actually produces them. Keep `face` only.
- **`is_blocked` → `blocklist_entries`** (adversarial #10): on clean rebuild, `blocklist_entries` is the source of truth; ensure composer suppression reads it so there's no silent suppression regression.

---

## What already exists — reuse, don't rebuild

| Existing | Reuse as |
|---|---|
| `events` table + `(ts DESC)`, `(trigger_id)` indexes | Keep verbatim; add scope columns (Decision 2). |
| SSE poll loop `mras-ops/api/src/main.py:177` (1s poll of `events`) | The projector's polling mechanism — point it at summary tables (Decision 3). |
| D10 reconciler (mras-vision) | Extend to `subject_embeddings` (Decision 5). |
| `identities.is_blocked` + D7/D18 composer enforcement | Map to `blocklist_entries`; keep the enforcement seam. |
| `ads`, `components` + `/ads`, `/components` CRUD | Keep; map into the creative model — do not rebuild. |
| `trigger_id` correlation (D9) | The backbone for `ad_runs`; extend into playback + idle paths (Decision 12). |
| Qdrant `mras_embeddings` (512-dim cosine) | Keep as the index; re-point payload to subject ids on re-enroll. |

---

## NOT in scope (considered and deferred)

- **Relational RBAC** (`users/roles/permissions`) — replaced by Supabase claims + thin scope map (Decision 1).
- **Consent gating / retention TTL / deletion-cascade machinery** — NOT built; privacy handled externally (Decision 9, accepted risk).
- **`events` partitioning** — deferred with a trigger-based TODO (Decision 8).
- **DSP/SSP/programmatic, consumer portal/login, billing, full creative-approval workflow, regulator access** — per `mras_ecosystem_and_users.md` v1.0 exclusions.
- **Multi-camera device management** (TODO-8) and **perception-signal consumption in ad selection** (TODO-7) — separate backlog items, not this phase.
- **Distribution pipeline** — N/A; this is schema + services inside existing repos, no new binary/package/image to publish.

---

## Failure modes (per new codepath)

| Codepath | Realistic prod failure | Test? | Error handling? | Visible or silent? |
|---|---|---|---|---|
| Projector | Worker down → summary tables stale while `events` grows; UI looks healthy | needs lag/liveness test | cursor + replay/rebuild | **SILENT → CRITICAL GAP: add a projector-lag indicator** |
| Projector | Replay/restart double-counts | replay idempotency test | natural unique keys | would be silent → keys fix it |
| Reconciler | Qdrant write fails → orphan embedding | orphan-cleanup test | pending→active + reconcile | silent recognition corruption → reconciler fixes it |
| Blocklist | Suppression leaks identity in event payload | E2E no-leak test (Decision 7) | scrub identity from suppressed event | **silent privacy incident** |
| Scope stamp | Device string unresolved → null scope | null-tolerant test | registration required before stamping | God View can't filter → make null = unfiltered, not crash |
| Watch | Idle play has no `trigger_id` → ad run dropped | covered by Decision 12 | idle gets own `trigger_id` | was silent → fixed |

**Critical gaps (no test + no handling + silent):** projector-lag (add monitor); these are the two to close first alongside the schema.

---

## Worktree parallelization

| Lane | Repo / modules | Work | Depends on |
|---|---|---|---|
| A | `mras-ops` (db/, api/, frontend/) | Wipe + 22-table rebuild, shared enums, projector, God View API, **device-registration UI** | — |
| B | `mras-display` | `playback/started`+`playback/ended` + `trigger_id` propagation | — |
| C | `mras-composer` | composition lifecycle events, idle-path `trigger_id`, blocklist read from `blocklist_entries` | A (schema) |
| D | `mras-vision` | re-enroll vs `subject_profiles`/`subject_embeddings`, reconciler extension, scope stamping | A (schema) |

**Execution:** Lane A schema first (tables + enums land). Then B + C + D in parallel worktrees. Then Lane A's projector/API/UI consumes the new events. **Conflict flag:** C and D both block on A's schema — do not start their schema-dependent parts until the migration lands.

---

## Implementation Tasks
Synthesized from this review. P1 blocks ship; P2 same branch; P3 follow-up.

- [ ] **T1 (P1, human: ~1d / CC: ~30m)** — mras-ops/db — Clean-slate migration: drop `identities/identity_embeddings/events/campaigns`, wipe Qdrant; create the 22-table model with shared enum types, scope columns, and natural unique keys (`ad_run` per `trigger_id`, `playback` per `(trigger_id, display_id)`).
  - Surfaced by: Decisions 2/4/6 + adversarial #9. Verify: migrations apply clean on empty DB; unique constraints reject duplicate `trigger_id`.
- [ ] **T2 (P1, human: ~1d / CC: ~30m)** — mras-ops — Projection worker ("librarian"): cursor on `events.id`, idempotent upsert of `ad_runs/playbacks/viewer_exposures/subject_observations`, restart-resume.
  - Surfaced by: Decision 3. Verify: replay same events → no double-count; restart resumes from cursor.
- [ ] **T3 (P1, human: ~0.5d / CC: ~20m)** — mras-ops/frontend — God View device-registration flow (writes `locations/systems/cameras/displays`, binds runtime `screen_id`→uuid + human name).
  - Surfaced by: Decision 10 + adversarial #5/#7. Verify: register `display-2` → events stamp resolves to its uuid.
- [ ] **T4 (P1, human: ~0.5d / CC: ~20m)** — mras-display — Emit `playback/started` + `playback/ended` with `trigger_id`; idle/shuffle gets its own `trigger_id`.
  - Surfaced by: Decisions 12 + handoff §5. Verify: every play (incl. idle) produces start+end events carrying a `trigger_id`.
- [ ] **T5 (P1, human: ~0.5d / CC: ~20m)** — mras-vision — Re-enroll vs `subject_profiles`/`subject_embeddings`; extend D10 reconciler; stamp scope on emitted events.
  - Surfaced by: Decisions 4/5. Verify: re-enroll Jason → `status='active'` row + Qdrant point; kill Qdrant mid-write → reconciler heals.
- [ ] **T6 (P1, human: ~0.5d / CC: ~20m)** — mras-composer — Composition lifecycle events; suppression reads `blocklist_entries`; idle-path `trigger_id`.
  - Surfaced by: Decisions 7/9/12. Verify: blocklisted subject → `decision=blocked_suppressed`, StandardAd, no identity in payload.
- [ ] **T7 (P1, human: ~0.5d / CC: ~20m)** — cross-repo — Blocklist suppression E2E (enroll blocklisted → walk past → assert non-personalized + no leak) + composer unit test.
  - Surfaced by: Decision 7. Verify: live Playwright run green after red.
- [ ] **T8 (P2, human: ~2h / CC: ~15m)** — mras-ops — Projector-lag indicator (last-processed-event age) surfaced in God View health.
  - Surfaced by: Failure-modes critical gap. Verify: stop projector → lag indicator turns red within N seconds.
- [ ] **T9 (P2, human: ~2h / CC: ~10m)** — mras-ops/api — Filtered/paginated God View event queries (`?location_id=&system_id=&event_type=&cursor=`).
  - Surfaced by: doc §11.5. Verify: filter by system returns only that system's events via index.

---

## TODOs (proposed — see review summary for owner decision)

1. **Biometric retention/deletion posture — revisit with counsel before alpha.** (Decision 9 accepted risk; pre-alpha is the cheap window to change it.)
2. **Blocklist circularity — resolve mechanically.** Suppressing an opted-out person requires identifying them; decide the non-biometric suppression signal before `blocklist_entries` ships. (Functional, not just legal.)
3. **`events` partitioning** — introduce monthly RANGE partitioning when event volume or history-query latency crosses a threshold; also size the projector-written high-volume tables. (Decision 8.)

---

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | not run |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | ISSUES_OPEN | 12 issues, 1 critical gap (projector-lag), 1 accepted legal risk |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | not run (God View UI is later phase) |
| Outside Voice | adversarial subagent | Independent challenge | 1 | issues_found | 10 findings; 3 absorbed as new decisions (#5 registry, #8→4 keyspace, #9 idempotency keys), privacy cluster surfaced |

- **CROSS-MODEL:** Inside review + adversarial voice independently agreed full-V1 is heavier than the God View mission needs; owner chose full-V1 with eyes open. Adversarial voice added the biometric-legal dimension the inside review missed.
- **UNRESOLVED:** 0 open decisions (all 12 issues decided; 1 — biometric privacy — decided as accepted risk with a counsel TODO).
- **CRITICAL GAPS:** 1 — projector-lag silent-staleness (T8 closes it).
- **VERDICT:** ENG REVIEW COMPLETE — 11 decisions locked, clean-slate rebuild authorized while pre-alpha. Proceed to spec/plan. Biometric privacy is an explicitly accepted risk pending counsel before alpha.
