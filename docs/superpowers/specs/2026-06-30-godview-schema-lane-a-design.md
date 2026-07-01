# God View Schema (Lane A) — Design Spec

**Date:** 2026-06-30
**Derived from:** `/Users/jn/code/minority_report_architecture/docs/god-view-domain-model-eng-review.md` (11 locked decisions)
**Scope:** Lane A only — the clean-slate Postgres schema for the God View / MRAS SaaS data model. Service instrumentation (Lanes B/C/D), the projector worker, and the God View UI are **separate specs/plans**.
**Repo:** `/Users/jn/code/mras-ops` (migrations in `db/migrations/`).

---

## 1. Goal

Replace the 6-table Phase-0 schema with the full normalized God View model (the eng-review's Full-V1, modified by its 11 decisions), as a **clean-slate rebuild**. Output: one coherent migration set that applies on an empty database and is verified by tests asserting tables, enums, scope columns, foreign keys, and idempotency keys exist and enforce.

## 2. Why clean-slate is allowed (and its expiry)

Owner confirmed all current data is disposable test data (~4 Qdrant faces; named: Jason, maybe Ragnar). **Authorization to wipe is valid only while pre-alpha.** After the first real enrollment, future schema changes revert to additive migrations. The rebuild therefore drops `identities`, `identity_embeddings`, `events`, `campaigns` and recreates everything; Qdrant collection `mras_embeddings` is dropped and re-created on re-enroll (out of this Lane's scope — vision owns it).

## 3. Global constraints (apply to every table)

- Postgres **16** (`postgres:16-alpine`), extension `pgcrypto` (`gen_random_uuid()`).
- Every new table uses `id uuid PRIMARY KEY DEFAULT gen_random_uuid()` **except** `events` (keeps `id bigserial` — the projector cursor depends on a monotonic integer; Decision 8).
- Timestamps `timestamptz`; `created_at NOT NULL DEFAULT now()`; `updated_at` where the row mutates.
- **Shared enum types** via `CREATE TYPE` — never re-declare the same value set inline per table (Decision/fold: DRY). Enum types are listed in §5.
- **Scope columns** (`organization_id, location_id, system_id, display_id, camera_id, subject_profile_id, ad_run_id` as applicable) are nullable `uuid` and carry `REFERENCES` where the parent exists (Decision 2). They appear on `events` **and** on every summary table.
- Migrations are plain SQL in `db/migrations/`, applied by `docker-entrypoint-initdb.d` on a fresh volume. Existing-volume apply is manual (`psql`).

## 4. Decisions baked into this schema

| Decision | Schema effect |
|---|---|
| 1 RBAC | NO `users/roles/permissions/user_memberships`. One table: `user_org_scopes(user_id uuid, organization_id uuid, location_id uuid NULL, role text)`. `user_id` is the Supabase auth subject (uuid); roles are the 8 canonical labels, validated by `role_label` enum. |
| 2 Event scope | Scope columns on `events` + all summary tables, indexed. |
| 3 Projector idempotency | `ad_runs` UNIQUE(`trigger_id`); `playbacks` UNIQUE(`trigger_id`, `display_id`); `subject_observations` UNIQUE(`event_id`) where `event_id` not null. |
| 4 Clean-slate / single keyspace | `subject_profiles` is the only people table (no `identities`); fresh uuid PK. |
| 5 Qdrant reconciler | `subject_embeddings.status` enum includes `pending`/`active`/`rejected`/`expired`/`deleted`; recognition reads only `active`. |
| 6 campaigns | Drop Phase-0 shell; new `campaigns`/`campaign_rules` with uuid keys. Keep `ads`/`components` (re-created with the same shape they have today + FKs into the creative model). |
| 8 events growth | `events.id bigserial`; reads go through one accessor (enforced in Lane A by NOT scattering raw `FROM events` — informational for later lanes). |
| 9 Privacy (accepted risk) | No consent/retention/deletion-cascade tables built. `subject_profiles.status` includes `deleted` (soft flag only). `subject_profile_merges` IS built. |
| 10 Device registry | `cameras`/`displays` carry `screen_id text` (the runtime string the service emits) + human `name`; this is the string→uuid bridge. |
| 12 Watch accuracy | `viewer_exposures.watched boolean NULL` (set only for `role='target'` via trigger_id) + `watch_probability numeric NULL` (bystanders). `ad_runs.target_watched boolean NULL`. |
| fold | Drop speculative `embedding_type` values; `subject_embeddings.embedding_type` enum = `face` only for now. |

## 5. Shared enum types (`CREATE TYPE`)

```
device_status     : active | degraded | offline | retired
lifecycle_status  : planned | active | inactive | degraded | offline | retired
embedding_status  : pending | active | rejected | expired | deleted
profile_status    : anonymous | known | merged | blocklisted | deleted
role_label        : Customer.OptInIdentified | Customer.Anonymous | Customer.Blocklisted |
                    Host.IT | Advertiser.ReadOnly | AgencyOfRecord.Standard |
                    Operator.SystemAdmin | Operator.SeniorSystemAdmin
organization_type : platform_operator | host | advertiser | agency_of_record | partner | vendor
decision_type     : identity | demographic | contextual | scheduled | manual | fallback | blocked_suppressed | error_recovery
ad_run_status     : planned | composing | ready | dispatched | playing | completed | failed | canceled
playback_status   : dispatched | started | ended | failed | interrupted | unknown
composition_status: queued | selected | rendering | rendered | failed | canceled
exposure_role     : target | viewer | bystander | possible_viewer
identity_status   : known | anonymous | unmatched | suppressed
match_status      : matched | no_match | below_threshold | suppressed | blocked
blocklist_type    : biometric_opt_out | personalization_opt_out | legal_hold | manual_suppression | safety
scope_level       : global | organization | location | system
asset_type        : image | frame | clip | video | audio | thumbnail | composite | model_artifact
```

(Additional small enums — `embedding_type=face`, `device_type`, `camera_role`, `display_role`, `location_type`, `system_type`, `participant_role`, `enrollment_scope`, `enrollment_source`, `render_mode`, `personalization_type`, `model_run_type`, `actor_type` — declared inline in their task; values copied from `god-view-domain-model.md` §8, minus the dropped speculative ones.)

## 6. Table inventory (21 tables — `users/roles/permissions` collapsed to `user_org_scopes`)

**Account/access:** `organizations`, `organization_relationships`, `user_org_scopes`
**Physical:** `locations`, `location_participants`, `systems`, `devices`, `cameras`, `displays`
**People:** `subject_profiles`, `identity_enrollments`, `subject_embeddings`, `subject_observations`, `identity_matches`, `observation_tracks`, `subject_profile_merges`, `blocklist_entries`
**Creative:** `campaigns`, `campaign_rules`, `ads`, `components`, `ad_creatives`, `media_assets`, `creative_approvals`
**Decision/run/playback:** `personalization_decisions`, `composition_runs`, `ad_runs`, `playbacks`, `viewer_exposures`, `model_runs`
**Event/audit:** `events` (bigserial + scope columns), `audit_logs`, `device_health_events`, `system_health_events`

Column definitions follow `god-view-domain-model.md` §8 verbatim **except** the Decision-driven changes in §4–§5 above. The plan (`docs/superpowers/plans/2026-06-30-godview-schema-lane-a.md`) contains the executable DDL.

## 7. Acceptance criteria (tests must prove)

1. Migration applies on an empty `postgres:16` database with zero errors.
2. All 21+ tables exist; `events.id` is `bigint` (not uuid); every other PK is `uuid`.
3. Shared enum types exist and reject an invalid value (e.g. `INSERT ... status='bogus'` fails).
4. Scope columns exist on `events` and on `ad_runs`/`playbacks`/`viewer_exposures`/`subject_observations`, with FKs resolving to `systems`/`displays`/`locations`/`cameras`.
5. Idempotency keys enforce: a second `ad_runs` row with the same `trigger_id` is rejected; a second `playbacks` row with the same `(trigger_id, display_id)` is rejected.
6. `cameras`/`displays` have `screen_id text` (the runtime-string bridge).
7. `subject_embeddings.status` defaults usable; recognition-relevant query `WHERE status='active'` is indexable.
8. No `identities`, `identity_embeddings`, `campaigns` (old shell), `users`, `roles`, `permissions` tables exist after migration.
9. Indexes exist for the live-feed and drilldown shapes: `events(system_id, ts DESC)`, `events(location_id, ts DESC)`, `events(ad_run_id) WHERE ad_run_id IS NOT NULL`, `ad_runs(trigger_id)`, `subject_embeddings(subject_profile_id) WHERE status='active'`.

## 8. Out of scope (this Lane)

- Service-side scope stamping / event emission (Lanes B/C/D).
- The projector worker (separate plan; this Lane only provides its target schema + idempotency keys).
- God View API/UI and the device-registration screen (separate plan).
- Qdrant collection management and re-enroll (vision owns).
- Consent/retention/deletion machinery (accepted-risk, not built — Decision 9).
- Resolving blocklist circularity (functional TODO, gates `blocklist_entries` *use*, not its existence).
