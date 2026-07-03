# Handoff — Session State (2026-07-03)

> **For the next (Fable) session.** Written to be read cold. Companion doc:
> `/Users/jn/code/minority_report_architecture/docs/handoff-03-peelback-orchestration-spec.md`
> (the feature to build next). Deep background lives in
> `/Users/jn/code/minority_report_architecture/docs/SESSION_LOG.md` (2026-07-03 entry, on branch
> `docs/session-log-godview-waves-2026-07-01` / arch PR #21 — not yet on `main`).

## TL;DR

The **God View data pipeline is validated end-to-end, live.** A real walk-up (enroll → recognize →
personalized ad on the display wall → projector fold → `viewer_exposures`) produced a correct
**target `viewer_exposures` row with `watched=TRUE`, `attending_fraction=1.0`, `gaze_duration_ms≈9014`
derived from real gaze.** That validation caught **4 integration bugs** (all green in unit tests, all
broke on real emitted data) which are now **fixed, committed, and pushed** to their PR branches.

The **next task is a different subsystem**: the composer's **display peel-back orchestration**
(play on all displays in the person's area → back off to half → stop). It is NOT a God View bug — see
the companion spec doc.

## What is committed (nothing at risk)

| Repo | Branch | HEAD | PR | What |
|---|---|---|---|---|
| mras-composer | `feat/composer-emission` | `4ee3c8a` | #28 | selector: query `subject_profiles`, not the dropped `identities` table |
| mras-vision | `feat/vision-gaze-jointkey` | `a0199ff` | #22 | detection/success emits `screen_id`+`screen_kind='camera'` |
| mras-ops | `feat/projector-gaze-join` | `100eb88` | #38 | projector: `handle_detection` payload contract + `viewer_exposures` target-attribution fallback |
| minority_report_architecture | `docs/session-log-godview-waves-2026-07-01` | `c090d32` | #21 | SESSION_LOG 2026-07-03 entry |

All four are pushed and in sync with origin; no uncommitted tracked changes anywhere. This handoff doc
lands on a 5th branch, `docs/handoff-peelback-2026-07-03`.

### The 4 bugs the live E2E caught (detail)

1. **composer** `src/selector/selector.py` queried the dropped `identities` table → every recognized
   trigger threw `UndefinedTableError` → fell back to standard content (no name / no TTS). Fixed →
   `subject_profiles` (`uuid`→`id`, `name`→`display_name`, `is_blocked`→`false`; blocklist deferred).
2. **vision** `detection/success` lacked `screen_id`+`screen_kind='camera'` → projector's ScopeResolver
   couldn't scope the event → `subject_observations` stayed empty. Fixed by adding the two keys the
   `gaze/success` event already carried.
3. **projector** `viewer_exposures` target match was `trigger_id`-only, but the composer orchestrator
   mints a fresh per-round `ad_run.trigger_id` that never equals the origin detection's `trigger_id`
   → no target row. Fixed: fallback attributes the most-recent pre-playback detection of
   `ad_run.target_subject_profile_id` on the same `system_id`.
4. **projector** `handle_detection` expected `uuid`/`observed_at`/`detection_type` keys vision never
   emits → NOT NULL violations → every detection routed to `projector.skip` (silently). Fixed: read
   `subject_profile_id`, source `observed_at` from the event `ts`, default `detection_type='face'`.

**Meta-learning:** all 4 had passing unit suites — the tests seeded synthetic shapes that matched the
handlers; the real service emits differ. Only the live E2E caught them. Keep running the live E2E in
red→green; do not trust unit-green as integration-green.

## The God View PR set + merge order

The pipeline is built across a stack of unmerged PRs. Merge order (child rebases onto parent after the
parent lands, then to `main`):

- **mras-ops**: `#36 feat/godview-projector` (the projector "librarian") → `#37 feat/projector-derivations`
  (FK-link resolution + viewer_exposures derivation, stacked on #36) → **`#38 feat/projector-gaze-join`**
  (gaze join + the two fixes above, stacked on #37). Land #36 → #37 → #38.
- **mras-vision**: `#21 feat/subject-reroute` (identities→subject_profiles/Qdrant) → **`#22 feat/vision-gaze-jointkey`**
  (gaze/detection join keys + the screen_id fix, stacked on #21). Land #21 → #22.
- **mras-composer**: **`#28 feat/composer-emission`** (event emission + the selector fix). Depends on the
  vision reroute contract (`subject_profile_id`).
- **mras-display**: `#13 feat/display-echo` (playback echo → composer). Note: the display echo DOES send
  `playback_started/ended` (that's the source of the composer's playback events); it also sends
  `clip_ended` on video-`ended`. See the peel-back spec for how this interacts with round advance.
- **arch docs**: `#21` (SESSION_LOG), plus this branch `docs/handoff-peelback-2026-07-03`.

**Before merging the stack:** the 4 fix commits still want a DBA/architect review pass (the project's
mandated review chain). They were validated live but not re-reviewed after the fixes. See "Open items".

## How to run the live E2E (worktree harness)

The pipeline is validated from **worktrees, pre-merge** (the standing "validate-then-merge" rule). Main
`docker-compose.yml` predates PR #36, so it has NO projector service and builds composer/api from stale
code. The override repoints build contexts at the worktrees and fully defines the projector.

**`/Users/jn/code/mras-ops/docker-compose.override.yml`** (TEMP — delete after the stack merges):
```yaml
services:
  mras-composer:
    build: /Users/jn/code/mras-composer/.worktrees/feat-composer-emission
  mras-ops-api:
    build: /Users/jn/code/mras-ops/.worktrees/feat-projector-gaze-join/api
  mras-ops-projector:
    build: /Users/jn/code/mras-ops/.worktrees/feat-projector-gaze-join/api
    command: python -m src.projector
    environment:
      DATABASE_URL: postgresql://mras:mras@postgres:5432/mras
      PROJECTOR_POLL_MS: "1000"
      PROJECTOR_BATCH_SIZE: "500"
      PROJECTOR_LAG_WARN_S: "10"
      PROJECTOR_LAG_CRIT_S: "60"
      PROJECTOR_SETTLE_MS: "2000"
      PROJECTOR_ADVISORY_LOCK_KEY: "20260701"
    depends_on:
      postgres:
        condition: service_healthy
    restart: unless-stopped
```

Run steps (from `/Users/jn/code/mras-ops`):
1. `docker compose up -d` (brings up pg/qdrant/redis/composer/ops-api/projector/overlays/frontend).
2. **Apply migrations 019–023** to the running dev DB (the container's initdb mount is the MAIN
   checkout, which only has 010–018). For each: `docker compose exec -T postgres psql -U mras -d mras <
   /Users/jn/code/mras-ops/.worktrees/feat-projector-gaze-join/db/migrations/0XX.sql`.
3. **Register devices** (required for scope + gaze system-scoping): an org, a location, a system, then a
   camera `screen_0` and a display `display-1` **under the same `system_id`**. Note `locations` has NO
   `organization_id` column — it links via `systems`.
4. **Run vision NATIVE** from its worktree (camera has no Docker passthrough on macOS; agent-launched
   vision gets no camera — the live walk-up needs the user's own terminal):
   ```
   cd /Users/jn/code/mras-vision/.worktrees/feat-vision-gaze-jointkey \
     && set -a && source /Users/jn/code/mras-vision/.env && set +a \
     && export REDIS_URL=redis://localhost:6379/0 \
     && /Users/jn/code/mras-vision/.venv/bin/uvicorn main:app --host 0.0.0.0 --port 8001
   ```
   (`.venv` is Python 3.9.6 arm64. `CONFIDENCE_THRESHOLD≈0.67` works with good framing.)
5. **Run the display** (Electron, multi-window): `cd /Users/jn/code/mras-display/.worktrees/feat-display-echo
   && NODE_ENV=development npm run electron:dev`. Electron sets `screen_id=display-<n>` per window
   (`electron/main.js:59`). **Port 5173 must be free** or Electron loads stale code / white screens; if
   `NODE_ENV` is unset it loads `dist/index.html` (absent) → `ERR_FILE_NOT_FOUND`.
6. **Enroll** via vision `/enroll` (multipart CSV `name,photo` + photo files). Enrollment segfaults if
   the camera loop runs concurrently.
7. **Force a fresh dispatch**: the Redis cooldown key `cooldown:screen_0:<subject_id>` (TTL 120s)
   persists across vision restarts. `docker compose exec redis redis-cli FLUSHDB` to clear it.
8. Walk up to the camera → watch the ad render → query the summary tables to confirm the fold.

**Gotcha:** `curl`/`wget` are blocked by the context-mode guard for HTTP. Use Python `httpx`
(`/Users/jn/code/mras-vision/.venv/bin/python`) for enroll/trigger/health calls. Raw `git`/`gh` is
blocked in all 5 repos — delegate to the `git-flow-manager` subagent.

## Open items

1. **Display peel-back orchestration** — the next task. See
   `/Users/jn/code/minority_report_architecture/docs/handoff-03-peelback-orchestration-spec.md`.
2. **DBA/architect review pass** on the 4 fixes, then **merge the God View stack** in the order above.
3. **Cosmetic:** target `identity_status` shows `unmatched` because vision emits no `match_status`, so
   the observation defaults `no_match`. Emit `match_status='matched_known'` on a recognition.
4. **Index** for the target-attribution fallback: `subject_observations(subject_profile_id, system_id,
   observed_at DESC)`. The fallback has no lower time bound (causality proxy) — see the projector fix.
5. **Delete `docker-compose.override.yml`** after the stack merges.

## Pointers

- SESSION_LOG (source of truth for "how to run" + history): `docs/SESSION_LOG.md`, 2026-07-03 entry.
- Gaze-join frozen decisions: the scratchpad spec `08-gaze-join.md` (viewer_exposures semantics).
- Auto-memory: `project-godview-e2e-validated`, `project-godview-schema-lane-a` (durable facts).
