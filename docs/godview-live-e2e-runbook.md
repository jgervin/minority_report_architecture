# God View — Live End-to-End Runbook

Validates the full God View data path **live** after the Build-Waves 1+2 PRs merge: service
event-emission → the projector "librarian" fold → the observation/run/decision/playback summary
tables → the `viewer_exposures` derivation. Everything in those PRs was built **static** (unit +
throwaway-DB integration tests only); this runbook is the one pass that exercises the real
multi-service pipeline end to end.

**Scope of "works":** an identified walk-up produces a personalized ad on a display AND the projector
folds the whole causal chain into correctly-scoped summary rows. See **§8 Known gaps** for what is
intentionally NOT expected to work in v1 (notably `viewer_exposures.watched` — gaze not wired yet).

> Cross-references: `docs/SESSION_LOG.md` (the "Operational Reference" section + the Build-Waves
> 1+2 entry) and `adface_architecture.md`. All file paths are absolute.

---

## 0. Preconditions — merge the PRs first

This runbook assumes the God View PRs are **merged to `main`** in each repo. Suggested order (from the
SESSION_LOG entry):

1. `mras-ops` **#36** (projector) → `main`
2. `mras-vision` **#21** + `mras-composer` **#28** **together** (lockstep — both moved the `/trigger`
   key to `subject_profile_id`; merging one without the other diverges the key across services)
3. `mras-ops` **#37** (viewer_exposures derivation + FK resolution) — rebase onto `main` **after** #36,
   then merge
4. `mras-display` **#13** (playback echo)

After merging, in each repo: `git checkout main && git pull`. If you want to dry-run BEFORE merge,
substitute each repo's worktree path (`.worktrees/feat-*`) for its main checkout below.

**Working dirs:** `mras-ops` = `/Users/jn/code/mras-ops`, `mras-vision` = `/Users/jn/code/mras-vision`,
`mras-composer` = `/Users/jn/code/mras-composer`, `mras-display` = `/Users/jn/code/mras-display`.

---

## 1. Bring up infra + apply migrations

The dev DB was previously recreated clean-slate on migrations `010–018`. The new projector migrations
`019–022` are **additive ALTERs on empty/near-empty tables** — apply them to the existing volume
(no `down -v`, so enrollments/data are preserved). `initdb` only runs on a *fresh* volume, so these
are applied manually.

```bash
cd /Users/jn/code/mras-ops

# Bring up datastores first (postgres, qdrant, redis) — leave app services down for a moment
docker compose up -d postgres qdrant redis

# Apply the projector migrations to the EXISTING volume (order matters)
docker compose exec postgres psql -U mras -d mras -f /docker-entrypoint-initdb.d/019_projector_state.sql
docker compose exec postgres psql -U mras -d mras -f /docker-entrypoint-initdb.d/020_device_registry.sql
docker compose exec postgres psql -U mras -d mras -f /docker-entrypoint-initdb.d/021_playbacks_rekey.sql
docker compose exec postgres psql -U mras -d mras -f /docker-entrypoint-initdb.d/022_viewer_exposures_perf.sql
```

Verify the schema is at 022:

```bash
docker compose exec postgres psql -U mras -d mras -c "\d projector_state"          # exists, singleton
docker compose exec postgres psql -U mras -d mras -c "\d unresolved_devices"        # exists (020)
docker compose exec postgres psql -U mras -d mras -c \
  "SELECT conname FROM pg_constraint WHERE conname = 'playbacks_trigger_screen_key';"  # 021 rekey present
docker compose exec postgres psql -U mras -d mras -c \
  "SELECT indexname FROM pg_indexes WHERE tablename='subject_observations' AND indexdef ILIKE '%system_id%observed_at%';"  # 022 index
```

**DB connection (for all verification SQL):** db `mras`, user `mras`, pass `mras`.
From host: `psql -h localhost -p 5432 -U mras -d mras`  ·  via compose:
`docker compose exec postgres psql -U mras -d mras`.

### 1a. ⚠️ Register the devices (REQUIRED for scope to resolve)

The projector's `ScopeResolver` maps each event's `screen_id` → org/location/system uuids via the
`cameras`/`displays` tables (both got `UNIQUE(screen_id)` in 020). **If a `screen_id` is not
registered, the event still folds but its summary row lands unscoped and a row is written to
`unresolved_devices`.** So register the camera + display(s) the demo uses, under one org/location/
system, with `screen_id` values matching what the services emit:

- vision emits the **camera** `screen_id` — default `screen_0` (see composer `TriggerPayload.screen_id`)
- the display emits its **display** `screen_id` — Electron uses `display-<n>` (e.g. `display-1`)

```sql
-- ⚠️ TEMPLATE — confirm exact NOT NULL columns against
--   /Users/jn/code/mras-ops/db/migrations/011_accounts.sql (organizations, locations)
--   /Users/jn/code/mras-ops/db/migrations/012_physical.sql (systems, cameras, displays)
-- Seed one tenant + one system, then a camera 'screen_0' and a display 'display-1':
INSERT INTO organizations (name) VALUES ('Demo Org') RETURNING id;          -- :org
INSERT INTO locations (organization_id, name) VALUES (:org, 'Demo Store') RETURNING id;   -- :loc
INSERT INTO systems (organization_id, location_id, name) VALUES (:org, :loc, 'Demo System') RETURNING id;  -- :sys
INSERT INTO cameras  (system_id, location_id, screen_id) VALUES (:sys, :loc, 'screen_0');
INSERT INTO displays (system_id, location_id, screen_id) VALUES (:sys, :loc, 'display-1');
```

Verify both resolve:

```sql
SELECT screen_id, system_id, location_id FROM cameras  WHERE screen_id = 'screen_0';
SELECT screen_id, system_id, location_id FROM displays WHERE screen_id = 'display-1';
```

---

## 2. Start the services

```bash
cd /Users/jn/code/mras-ops
# Default compose = postgres, qdrant, redis, mras-composer, mras-overlays, mras-ops-api,
# mras-ops-projector, mras-ops-frontend. (mras-vision has profile 'docker-vision' and is EXCLUDED —
# run it natively so macOS can grant the webcam.)
docker compose up -d
```

**Vision (native — MUST be launched from your own terminal so macOS prompts for camera access; a
background/agent launch gets `not authorized to capture video`):**

```bash
cd /Users/jn/code/mras-ops
./run-vision-native.sh          # venv (py3.9.6), CAM_INDEX=0 (built-in cam), uvicorn on :8001
# override camera: CAM_INDEX=1 ./run-vision-native.sh
```

**Display (native — Electron or Vite):**

```bash
cd /Users/jn/code/mras-display
npm run electron:dev            # opens display window(s) with ?screen_id=display-1 → ws://localhost:8002/ws
# web-only alternative (set screen_id yourself):
#   npm run dev  → open http://localhost:5173/?screen_id=display-1
```

**Ports:** vision `8001` · composer `8002` · ops-api `8080` · ops-frontend `3000` · postgres `5432`
· qdrant `6333` · redis `6379` (loopback) · overlays internal-only (`mras-overlays:3000`) · display
Vite `5173`.

---

## 3. Health checks (before the walk-up)

```bash
curl -s http://localhost:8001/health          # vision
curl -s http://localhost:8002/health          # composer
curl -s http://localhost:8080/health          # ops-api

# Projector status (the /projector/status route lives in the ops-api app, port 8080):
curl -s http://localhost:8080/projector/status | jq
#   expect: { cursor: 0, last_event_ts: null|<ts>, backlog: 0, lag_seconds: ..., health: "ok", ... }

# Projector worker container is up and holding the advisory lock (single writer):
docker compose ps mras-ops-projector           # state = running
docker compose logs --tail=20 mras-ops-projector
```

If `mras-ops-projector` is crash-looping, check `DATABASE_URL` + that `projector_state` (019) exists.

---

## 4. Scenario A — enrol, walk up, personalize

### 4a. Enrol a subject (Playwright MCP on the enroll UI, or curl)

The vision `/enroll` endpoint is `POST /enroll` multipart: `csv_file` (a CSV with a `name` column),
`photos` (one+ files matched to CSV rows by filename), `additive` (bool; `true` = merge). Use the ops
enroll UI if present, else:

```bash
curl -s -X POST http://localhost:8001/enroll \
  -F "csv_file=@/path/to/people.csv" \
  -F "photos=@/path/to/alice.jpg" \
  -F "additive=true"
```

Verify enrollment persisted (Postgres + Qdrant — vision direct-writes the enrollment tables):

```sql
SELECT id, display_name, status FROM subject_profiles ORDER BY created_at DESC LIMIT 5;
SELECT subject_profile_id, source, status FROM identity_enrollments ORDER BY created_at DESC LIMIT 5;
SELECT subject_profile_id, qdrant_point_id, status FROM subject_embeddings WHERE status='active' LIMIT 5;
```
```bash
# Qdrant has the point(s):
curl -s http://localhost:6333/collections | jq '.result.collections'
```
Note the enrolled subject's `subject_profiles.id` → call it **$PROFILE**.

### 4b. Walk up (the real trigger)

Stand in front of the camera. Vision detects → recognizes → emits `detection/success`
(+ `track/*`, `identity_match/candidates`) to `events`, and POSTs `/trigger` to the composer with
`subject_profile_id=$PROFILE`, `screen_id=screen_0`. Composer decides → composes → dispatches a
personalized ad to the display; the display plays it and echoes `playback_started`/`playback_ended`
back; composer emits the `playback/*` + `ad_run/*` events.

**Manual trigger (if you want a scripted run instead of a live walk-up):**

```bash
curl -s -X POST http://localhost:8002/trigger -H 'Content-Type: application/json' -d '{
  "trigger_id": "'"$(uuidgen)"'",
  "subject_profile_id": "'"$PROFILE"'",
  "confidence": 0.92,
  "screen_id": "screen_0",
  "faces_in_frame": 1
}'
```

**Observe:** the personalized ad should render on the `display-1` window within a few seconds.

---

## 5. Verify the projector folded the chain

Give the projector a moment (poll 1s, settle window 2s), then confirm it caught up:

```bash
curl -s http://localhost:8080/projector/status | jq '{cursor, backlog, lag_seconds, health}'
# backlog should return to 0 (caught up)
```
```sql
-- cursor == max(events.id):
SELECT (SELECT cursor FROM projector_state WHERE id=1) AS cursor, (SELECT max(id) FROM events) AS max_id;
```

### 5a. The events journal has the full causal chain

```sql
SELECT id, service, event_type, status,
       payload->>'screen_kind' AS kind, payload->>'screen_id' AS screen_id,
       trigger_id
FROM events
WHERE trigger_id = '<the trigger_id from 4b>'
ORDER BY id;
-- expect (per trigger): mras-vision detection/success (+track/*, identity_match/candidates);
--   mras-composer decision/made, composition/{queued,rendering,rendered}, ad_run/{planned,dispatched,...},
--   playback/dispatched; playback/{started,ended} (from the display echo).
-- decision/composition/ad_run-planned carry screen_kind='camera'; dispatch/playback carry 'display'.
```

### 5b. Every summary table populated WITH RESOLVED SCOPE

```sql
-- one query per table; org/location/system (and camera/display) uuids must be NON-NULL:
SELECT id, system_id, camera_id, subject_profile_id, detection_type FROM subject_observations ORDER BY created_at DESC LIMIT 3;
SELECT id, system_id, camera_id, camera_screen_id FROM observation_tracks ORDER BY created_at DESC LIMIT 3;
SELECT subject_observation_id, rank, match_status FROM identity_matches ORDER BY created_at DESC LIMIT 5;
SELECT id, trigger_id, organization_id, system_id, decision_type, selected_ad_id, target_subject_profile_id,
       personalization_decision_id IS NOT NULL AS has_dec_fk FROM personalization_decisions ORDER BY created_at DESC LIMIT 3;
SELECT id, trigger_id, system_id, status, render_mode, personalization_decision_id FROM composition_runs ORDER BY created_at DESC LIMIT 3;
SELECT id, trigger_id, system_id, display_id, status, composition_run_id, personalization_decision_id FROM ad_runs ORDER BY created_at DESC LIMIT 3;
SELECT id, trigger_id, screen_id, display_id, ad_run_id, status, dispatched_at, started_at, ended_at FROM playbacks ORDER BY created_at DESC LIMIT 3;
```
- `personalization_decisions`/`composition_runs` scope comes from the **camera** side (screen_kind=camera).
- `ad_runs.composition_run_id`, `ad_runs.personalization_decision_id`, `playbacks.ad_run_id` should be
  NON-NULL (FK resolution by shared `trigger_id`, PR #37).

### 5c. `events` scope back-stamp (fixes the 017 indexes)

```sql
SELECT count(*) FILTER (WHERE system_id IS NOT NULL)         AS scoped,
       count(*) FILTER (WHERE subject_profile_id IS NOT NULL) AS subj_stamped,
       count(*) FILTER (WHERE ad_run_id IS NOT NULL)          AS adrun_stamped,
       count(*)                                               AS total
FROM events;
-- scoped should cover all resolvable events; detection carries subject_profile_id; ad_run/playback carry ad_run_id.
```

### 5d. `viewer_exposures` derived (target by trigger_id)

```sql
SELECT ve.role, ve.identity_status, ve.watched, ve.watch_probability,
       ve.ad_run_id, ve.subject_observation_id
FROM viewer_exposures ve
JOIN ad_runs a ON a.id = ve.ad_run_id
WHERE a.trigger_id = '<the trigger_id>'
ORDER BY ve.role;
-- expect exactly one role='target' row (the causal observation, matched by trigger_id — inserted
-- regardless of the playback window). watched is EXPECTED NULL in v1 (gaze not wired — see §8).
-- Bystanders (other people seen during the ad, if any) appear as role='bystander'.
```

### 5e. Nothing went unresolved / poison

```sql
SELECT * FROM unresolved_devices;                         -- EXPECT EMPTY (all devices registered in §1a)
SELECT action, count(*) FROM audit_logs
 WHERE action IN ('projector.skip','projector.resolve_miss') GROUP BY action;   -- expect 0 (or explained)
```
A row in `unresolved_devices` ⇒ a `screen_id` wasn't registered (redo §1a). A `projector.skip` ⇒ a
bad-enum/malformed event (inspect it). A `projector.resolve_miss` ⇒ a child event whose parent was
skipped.

---

## 6. Idempotency + restart checks

```bash
# Restart the projector — the advisory lock releases and re-acquires on the dedicated conn; the cursor
# persists in projector_state. No rows should be re-projected (upserts converge).
docker compose restart mras-ops-projector
sleep 5
curl -s http://localhost:8080/projector/status | jq '{cursor, backlog, health}'
```
```sql
-- Row counts for the trigger should be UNCHANGED after restart (idempotent replay).
-- (Re-run the §5b queries; counts identical.)
```
Single-writer sanity: only one `mras-ops-projector` should hold the lock. Scaling it to 2 replicas
must leave exactly one folding (the other idles on `pg_try_advisory_lock`).

---

## 7. Multi-viewer / bystander pass (optional)

With the ad playing on `display-1`, have a **second** (non-target) person enter frame. Vision emits a
second `detection/success`; the projector's `viewer_exposures` derivation should, on
`playback/ended`, add a `role='bystander'` row for that in-window observation alongside the
`role='target'` row. Verify via §5d (expect 2 rows now).

---

## 8. Known gaps — do NOT expect these in v1 (by design, documented in PR bodies)

- **`viewer_exposures.watched` / `watch_probability`** — sourced from a `gaze/success` event join that
  is **not wired** (needs vision to emit gaze in a joinable form). `watched` is NULL for anonymous
  targets today. This is the tracked follow-up you asked to defer.
- **Multi-device co-scope** — bystander attribution is system-level, so at a multi-display site every
  in-window observation of the system is attributed to each display's ad. Fine for single-camera/
  single-display demo; needs a camera↔display adjacency map otherwise.
- **api `/health` degradation** — `/health` stays 200 regardless of projector lag; projector liveness
  is on `/projector/status` by design.
- **`composition/queued` timing / `ad_run/failed`** — queued is emitted; failure states are best-effort
  (no distinct code stage for some failures yet).
- **Biometric-privacy machinery + blocklist** — deferred to the go-live announcement.
- **Redis** — if down, vision falls back to in-memory cooldown (no crash).

---

## 9. Teardown

```bash
# Stop native processes: Ctrl-C the vision terminal + the display (Electron/Vite).
cd /Users/jn/code/mras-ops
docker compose down            # keep volumes (preserves enrollments + folded data)
# docker compose down -v       # ONLY to wipe the DB/qdrant volumes (clean-slate; re-enroll needed)
```

---

## Appendix — one-shot pipeline health query

```sql
SELECT
  (SELECT count(*) FROM events)                       AS events,
  (SELECT cursor FROM projector_state WHERE id=1)     AS cursor,
  (SELECT count(*) FROM subject_observations)         AS observations,
  (SELECT count(*) FROM personalization_decisions)    AS decisions,
  (SELECT count(*) FROM composition_runs)             AS compositions,
  (SELECT count(*) FROM ad_runs)                      AS ad_runs,
  (SELECT count(*) FROM playbacks)                    AS playbacks,
  (SELECT count(*) FROM viewer_exposures)             AS exposures,
  (SELECT count(*) FROM unresolved_devices)           AS unresolved,
  (SELECT count(*) FROM audit_logs WHERE action LIKE 'projector.%') AS projector_audits;
-- healthy: cursor == max(events.id); unresolved == 0; each summary count > 0 after a walk-up.
```
