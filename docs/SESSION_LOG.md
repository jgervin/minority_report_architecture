# MRAS / AdFace — Session Log

Append-only engineering journal across the MRAS multi-repo system
(`minority_report_architecture`, `mras-vision`, `mras-composer`, `mras-display`, `mras-ops`).
Purpose: survive reboots, `/clear`, and context summarization so any future session, skill,
or agent can recover what was done, what was learned, and how to run the system.

## Protocol (read this first, every session)

1. **At session start:** read this file top-to-bottom plus `TODOS.md` and `adface_architecture.md`.
2. **At session end (or before a likely reboot / `/clear`):** prepend a new dated entry under
   "Session Entries" using the template below. Newest first.
3. **Keep it durable, not chatty.** Record: what changed (with repo + commit SHA), what was
   *learned* (non-obvious facts, gotchas), and any new run/operational steps. Skip blow-by-blow.
4. **Cross-repo commits** live in their own repos — always cite `repo@sha`. Working-tree-only
   changes (not yet committed) must be flagged as such.
5. This is the source of truth for "how do I run it" — keep the Operational Reference current.

### Entry template
```
## YYYY-MM-DD — <short title>
**Changes:** repo@sha — one line each.
**Learnings:** non-obvious facts / gotchas discovered.
**State:** what's working / verified, what's pending.
```

---

## Operational Reference (keep current)

**Topology (IMPORTANT — differs from the original plan doc):**
- `mras-vision` runs **natively on macOS**, NOT in Docker — macOS cannot pass the webcam into a
  container. The compose service has `profiles: ["docker-vision"]` so it is **excluded** from
  default `docker compose up`. Start it with `mras-ops/run-vision-native.sh` (bootstraps an
  arm64 venv at `mras-vision/.venv`, CAM_INDEX=0 = built-in webcam).
- Default `docker compose up` (run from `mras-ops/`) brings up: postgres, qdrant, mras-composer,
  mras-ops-api, mras-ops-frontend.
- **Camera permission:** native vision must be launched from the user's own terminal so macOS can
  prompt for camera access. A background/agent launch gets `not authorized to capture video` and
  the camera task fails (app still serves `/enroll` and `/health` — camera is a background task).

**Ports:** vision 8001, composer 8002, ops-api 8080, ops-frontend 3000, postgres 5432, qdrant 6333.
mras-overlays render sidecar **3000 (internal `expose` only, not host-published)** — composer reaches
it at `http://mras-overlays:3000`.

**Overlay render sidecar (M3):** `mras-overlays` is a compose service (`docker compose up`/down
governs it — no separate process). Composer renders the viewer's name as an animated overlay in
`/trigger` via `OVERLAY_SIDECAR_URL` (default `http://mras-overlays:3000`), styled by
`OVERLAY_TEMPLATE` (default `{name}`) + `OVERLAY_PRESET|START_MS|DURATION_MS|COLOR|POSITION`.
**No caching** — every personalized trigger renders fresh (warm ≈ 2.9s in-container). First ~10–90s
after startup the sidecar is still warming → overlay silently falls back to no-overlay (ad still ships).

**Custom-component authoring (M4 — branches, not yet merged):** advertisers upload a Remotion `.tsx`
(via ops-frontend → ops-api `POST /components` → sidecar bundles once, registers `comp-<slug>`), bind
it to an **ad** (`ads` table: base_video + component + default_props + personalized_field + is_active),
and an identified viewer's `/trigger` renders the bound custom component (warm, ~1.1s) with their name.
Sidecar `POST /render` takes `{compositionId, props}`; uploaded components persist on the
`custom_components` volume. **No sandbox/security yet** — advertiser code runs un-isolated (deferred).
Apply migration `002_custom_components.sql` manually on an existing DB volume (init scripts run only on
a fresh DB).

**TTS:** ElevenLabs primary → **Google Gemini** fallback (MisoOne was replaced). Keys in `mras-ops/.env`.

**Recognition:** confidence threshold `CONFIDENCE_THRESHOLD` (code/example default 0.68; **lowered to
0.67 in `mras-vision/.env` local override as of 2026-06-17** because live "Jason" scores cluster ~0.679).
Below threshold → `is_new_visitor=true` → standard ad (no name). Enrolled identities seed Qdrant
collection `mras_embeddings` (512-dim Cosine). Live recognition is marginal — re-enroll under demo
lighting for reliability (pending).

**Perception CPU throttle (2026-06-17):** DeepFace-emotion + YOLO are throttled to ~1 Hz via
`PERCEPTION_ANALYZER_INTERVAL_S` (default 1.0s, set in `build_analyzers()`). Without it they ran
~6x/sec (capture loop awaits `process_frame`), pegging a GPU-less Mac and causing track churn. Identity
embedding + tracking still run every frame.

**Phase 2 perception (2026-06-12):** vision now tracks faces and enriches every trigger's
`scene_context` with `objects[]` (label/confidence/color/bbox/source via yolo11n + k-means) and,
after ~3s dwell, `viewer{track_id, mood, mood_confidence, attending, evidence_frames}`. Attention
windows land in Postgres as `gaze` events (`attending_fraction` per track per ~3s window; uuid
bound once identified) — "did X watch the ad" = join `gaze` × `playback` rows on screen + time
window. **Debug view:** run vision with `PERCEPTION_DEBUG=1` → http://localhost:8001/debug/live
(annotated MJPEG: yellow object boxes, green/red face boxes = attending/not, track id + mood).
Env knobs (defaults): `VIEWER_MIN_EVIDENCE_S=3.0`, `ATTENTION_YAW_DEG=25`, `ATTENTION_PITCH_DEG=20`,
`GAZE_FLUSH_S=3.0`, `YOLO_CONF=0.4`, `PERCEPTION_DEBUG=0`. First live frames lazy-warm the
mood/attention models (yolo prewarms at startup; mediapipe downloads ~5MB to
`~/.cache/mras-vision/` once). Identity dispatch is never blocked by perception — tracker failure
falls back to untracked dispatch and logs a `perception`/`error` event.

**Gotchas:**
- The `mras-ops-frontend` container **bakes its source at build time** (no volume mount). After
  editing `frontend/src/*`, redeploy with `docker compose up -d --build mras-ops-frontend`.
- **curl/wget are blocked** by the context-mode guard for HTTP fetches. Use Python `httpx`
  (e.g. `mras-vision/.venv/bin/python`) for enroll/trigger calls.
- Vision tests run via `mras-vision/.venv/bin/python -m pytest` (host pyenv 3.11 lacks deps).
- `mras-kiosk` is a superseded scaffold — the live kiosk is `mras-display`.
- One-command startup: `mras-ops/start-mras.sh` (starts Docker, the compose stack, then native vision).
- **Kiosk is multi-display (T-D, 2026-06-11):** `npm run electron:dev` in `mras-display` starts
  **DISPLAY_COUNT windows (default 4, clamp 1–10)** — fullscreen-per-monitor when enough monitors,
  else a tiled grid on the primary. Each window shuffles the idle pool independently and connects as
  `/ws?screen_id=display-<n>`; the composer broadcast makes all windows play the same composed clip.
  **Port 5173 must be free** — a stale vite server there makes Electron silently load OLD code
  (worktree vite falls back to 5174 but Electron still hits 5173).
- **Node containers: don't `CMD ["npm","start"]`** — npm as PID 1 swallows SIGTERM so graceful
  handlers never run. Run the binary directly (`node_modules/.bin/tsx …`) + compose `init: true`
  (tini). The overlay sidecar does this; `docker compose stop mras-overlays` logs the graceful close.
- **Raw `git`/`gh` is blocked in all 5 CLAUDE.md repos** by a PreToolUse guard
  (`.claude/hooks/guard-git.sh`). The main agent must delegate to the `git-flow-manager` subagent; the
  subagent opts in by prefixing commands with `CLAUDE_GIT_OK=1` (e.g. `CLAUDE_GIT_OK=1 git status`).
  Pushing to `main` is denied even with the marker — land via `gh pr merge` after review. A "Raw git/gh
  is disabled" error means: delegate, don't fight it.

**Enroll a face (vision must be running):**
```python
# mras-vision/.venv/bin/python
import httpx
csv = b"name,photo\nAlice,alice.jpg\n"
with open("alice.jpg","rb") as f:
    httpx.post("http://localhost:8001/enroll",
        files={"csv_file":("e.csv",csv,"text/csv"),
               "photos":("alice.jpg",f.read(),"image/jpeg")}, timeout=60)
```

---

## Session Entries (newest first)

## 2026-06-19 — Temporal orchestration LIVE E2E PASSED (walk-up, 4 displays)
**What ran:** full stack via `mras-ops/start-mras.sh` (Docker rebuild + native vision) + kiosk (`mras-display` `npm run electron:dev`, 4 windows). Owner walked up to the camera as the enrolled identity.
**Verified end-to-end (composer + vision logs + visual):**
- vision `PresenceReporter` → composer `POST /presence 200 OK` streaming continuously (PR #20 path live).
- identification → composer `POST /trigger 200 OK` → orchestrated render: kiosks fetched `GET /media/orch-<uuid>-1-0.mp4` AND `orch-<uuid>-1-1.mp4` — the **`orch-` prefix proves the orchestrator (not the old one-shot fan-out) produced the clips**, two distinct variants = the A/B split.
- name overlay rendered: `POST http://mras-overlays:3000/render 200 OK`.
- **Visual: name opener on all 4 windows → then paired down to 2** = opener-on-all-owned-displays → round-2 A/A/B/B split, exactly the designed 2-round program. Kiosks `connection closed` ×4 then resumed presence = clean return to idle.
- No crashes, no black windows, vision stayed up throughout.
**Non-blocking findings (NOT orchestration bugs):**
- ElevenLabs returned `402 Payment Required` (account out of credits) → **Gemini TTS fallback fired `200 OK`** as designed; name still spoken. Top up ElevenLabs before a paid demo, but fallback covers it.
- vision-side `portable_clearcut_uploader.cc FAILED_PRECONDITION` = MediaPipe/Google telemetry noise, harmless.
**State:** temporal orchestration (composer #24 `2bdb60a` / display #12 `19561a3` / vision #20 `b225f31`) is **live-verified**. The owner-pending E2E is now DONE — orchestration feature complete. `DisplayAssigner` remains intentionally kept (orphaned). Next: TODO-5 (ffmpeg software-latency benchmark).

## 2026-06-19 — Temporal orchestration CODE merged → ACTIVATED on main (3 repos)
**Changes:** merged the three interdependent temporal-orchestration CODE PRs (each base `main`, true `--merge`, remote branch deleted, local `main` fast-forwarded == origin/main):
- `mras-composer` PR #24 → `main`@`2bdb60a` — `Orchestrator` core + runtime/watchdog + **activated** `/trigger`→`on_identify` (the one-shot fan-out path is no longer the live path).
- `mras-display` PR #12 → `main`@`19561a3` — kiosk emits `clip_ended` and waits for composer to decide next; `{type:idle}` resumes idle shuffle.
- `mras-vision` PR #20 → `main`@`b225f31` — `PresenceReporter` posts identified live tracks per `screen_id` to composer `/presence`.
**Owner decisions this session:** (1) merge all 3 together — done. (2) **KEEP** `mras-composer/src/display_assignment.py` (`DisplayAssigner`) + its tests despite being orphaned post-activation (no production caller) — left intact intentionally, NOT dead-code-deleted; revisit only if a one-shot fallback is ever wanted again.
**State / pending:** Orchestration is live on all three `main` branches but **NOT yet E2E-verified** — the live walk-up / multi-camera / kiosk run (composer orchestrated `/trigger` ↔ vision `/presence` ↔ kiosk `clip_ended`) needs owner camera + display hardware and has NOT been run. Pre-merge: all three were unit-green (composer 134, vision 111, display 47 + tsc clean). vision #20 mergeable resolved UNKNOWN→CLEAN before merge.

## 2026-06-19 — Planning docs merged to main (specs/plans now discoverable)
**Changes:** merged the three DOCS-ONLY planning PRs in `minority_report_architecture`: #14 serialized-inference (`cf85e0f`), #13 adaptive-enrollment (`0b02466`), #12 temporal-orchestration (`e3a14f6`). `main`@`e3a14f6`.
**Why this mattered:** the spec/plan markdown previously lived ONLY on unmerged `chore/*-spec` branches, so agents working from a clean `main` (and `GODVIEW_HANDOFF.md`'s references) could NOT find them — Agent D building #12 hit exactly this and worked from its task brief instead. Now all 6 specs + 8 plans are on `main` under `docs/superpowers/specs/` and `/plans/`.
**Naming gotcha (caused confusion):** PR numbers COLLIDE across repos. The DOCS specs/plans are `minority_report_architecture` #12/#13/#14/#15; the CODE is in component repos with independent numbering (e.g. enrollment **code** = `mras-vision` #19 + `mras-ops` #33; orchestration **code** = `mras-composer` #24 + `mras-vision` #20 + `mras-display` #12). "Merge #13" earlier meant the enrollment CODE, not the docs PR #13. Always qualify PRs as `<repo> #<n>`.

## 2026-06-19 — Temporal orchestration #12 Plan 3 + activation shipped → 3 OPEN PRs (must merge together)
**Changes (TDD red→green, failing test committed separately in each repo; 3 repos):**
- `mras-vision` PR #20 (branch `feat/temporal-orchestration-presence`, base main, OPEN). `mras-vision@bfbd14a` (impl) on `@1d32454` (red test). New `src/perception/presence.py` `PresenceReporter` — periodic POST of identified (uuid-bound) live tracks per `screen_id` to composer `/presence` (newest-first, deduped, best-effort; env `COMPOSER_URL`/`SCREEN_ID`/`PRESENCE_REPORT_S`). Started in `main.py` lifespan next to `GazeLogger`/`AugmentReporter`, cancelled on shutdown. New `tests/test_presence.py` (6). **Full vision suite 111 passed.**
- `mras-display` PR #12 (branch `feat/temporal-orchestration-kiosk`, base main, OPEN). `mras-display@de0ad60` (impl) on `@816d924` (red tests). `src/App.tsx`: a personalized (composer-pushed) `play` clip is tracked via `personalizedClipRef`; on its `ended` the kiosk emits `{type:clip_ended,screen_id,clip_id}` over the WS and does NOT auto-advance idle (composer decides next); new `{type:idle}` message resumes the idle shuffle; idle-clip endings still auto-advance. `screenIdRef` captured in the WS effect. Mock WS gained a `send` spy. **47 vitest passed; `tsc --noEmit` clean.**
- `mras-composer` PR #24 (branch `feat/temporal-orchestration-core`, base main, OPEN — same PR as the core work, now extended). `mras-composer@6a8fcc2` (green activation) on `@864badd` (red test). `main.py` `/trigger`: an identified non-standard person with tagged kiosks now calls `orchestrator.on_identify(uuid)` + `await runtime.apply(cmds)` and logs `composition/orchestrated` (status `"orchestrated"`), replacing the one-shot DisplayAssigner+select_variants+parallel fan-out. **KEPT** the standard-gate short-circuit and the no-screen-id legacy `_trigger_single_broadcast` fallback. Removed orphaned `DisplayAssigner` import/wiring, `select_variants` import, `_DISPLAY_HOLD_SECS`. Test reconciliation: removed `tests/test_trigger_variants.py` (7 fan-out tests); rewrote `test_name_overlay_always.py` (2 owner-rule tests now hit `_render_overlay_inserts` directly, dropped 1 parallel-send-timing test, kept 1); added `tests/test_trigger_orchestrated.py` (3). **Suite 139 → 134 passing** (−7 fan-out, −1 timing, +3 orchestrated), 1 deselected. Full reconciliation table is in PR #24's body.
**Learnings / gotchas:**
- The orchestrated `play` message (`runtime._send_play`) carries only `{type,video_url,person:owner_uuid}` — NO `ad`/`trigger_id`/`clip_id`. The kiosk therefore falls back to the `video_url` as the `clip_id` it echoes in `clip_ended`. The composer's `/ws` handler only keys off `screen_id` anyway (clip_id is informational).
- The opener is now ONE shared render across an owner's displays (only round 2 splits A/B) — this is why the old `test_four_displays_get_four_distinct_clips` is wrong by design, not just rewired.
- The planning docs referenced in the task (`docs/superpowers/plans/2026-06-17-temporal-orchestration-plan3-wires-e2e.md`, `…/specs/2026-06-17-temporal-display-orchestration-design.md`) **do not exist on disk** — worked from the task brief + the existing orchestrator code/tests instead.
**State / pending:**
- ⚠️ **The 3 PRs MUST merge together** — composer's orchestrated `/trigger` depends on vision `/presence` input and kiosk `clip_ended` output. None merged.
- ⚠️ **FLAGGED FOR OWNER:** `mras-composer/src/display_assignment.py` (`DisplayAssigner`) + `tests/test_display_assignment.py` are now **orphaned** (no production caller post-activation). Left intact (tests still pass on the class contract) rather than guess — owner decides delete vs keep.
- Live walk-up / multi-camera / kiosk E2E is **owner-pending** (camera + display hardware); NOT run.

## 2026-06-18 — Temporal orchestration Plans 1+2 implemented (composer) → PR #24 — orchestrator WIRED BUT NOT ACTIVATED
**Changes (parallel agent, `mras-composer` only; TDD red→green, 26 commits):**
- `mras-composer` PR #24 (branch `feat/temporal-orchestration-core`, base main, OPEN/not merged). Plan 1 (10/10): `src/orchestrator/model.py` (`Round`/`next_round`, `even_split`, `pair_slot`), `commands.py` (`Play`/`Idle`/`RenderAhead`), `core.py` (`Orchestrator` state machine `on_identify`/`on_clip_ended`/`on_presence`/`tick`, I/O-free). Plan 2 (Tasks 1–5 + watchdog/wiring): `runtime.py` (`OrchestratorRuntime` command→render/WS mapping + render-gap idle/resume), `renderer.py`, `watchdog.py`; `main.py` gained `POST /presence`, inbound `clip_ended` on `/ws`, lifespan wiring of orchestrator + runtime + watchdog + periodic `tick`. **139 passed** (was 109; verified independently). Tests run with pyenv py3.11 + repo deps (`python3 -m pytest`), no Docker.
**Learnings / IMPORTANT caveat:**
- **The orchestrator is wired but NOT ACTIVATED.** Plan 2 Task 6's `/trigger`→`on_identify` swap was **deliberately DEFERRED** by the agent: doing it as written obsoletes ~**9 shipped per-display-fan-out tests** (the PR #20 behavior: multi-face split, parallel send, name-overlay-through-trigger, `no_display`, release-on-race) that the plan never addressed reconciling — a product decision, not a mechanical edit. So **a real identification still uses the OLD one-shot path**; the orchestrator is reachable via `/presence` + `clip_ended` + watchdog + tick but isn't driving ads yet. **Owner decision needed:** activation = swap the entry point + reconcile/rewrite those ~9 tests to the approved orchestration behavior (the orchestration design supersedes the one-shot fan-out). Pair this with Plan 3.
- Agents caught two literal bugs in the plans I wrote (both fixed): opener `pair_slot` must be 0, not paired (Plan 1 Task 5 `_reassign`); runtime `_resume_pending` Task-1 stub must be a no-op `return`, not `raise NotImplementedError`, or the render-ahead task errors (Plan 2 Task 1).
**State:** #12 core+integration code complete + unit-verified, PR #24 open/not merged. Pending: review/merge #24; **#12 Plan 3 + activation** — vision `/presence` emitter + kiosk `clip_ended`/`idle` handling + the `/trigger`→orchestrator swap + the ~9-test reconciliation (held back to avoid the vision `main.py` conflict with #13; do after #13 merges); live camera/kiosk E2E (owner).

## 2026-06-18 — Adaptive enrollment Plan 2 (gated auto-augmentation + reversibility) implemented → PRs open
**Changes (branch `feat/adaptive-enrollment-auto-augment` in both repos; TDD red→green, failing test committed separately before each impl):**
- `mras-vision` PR #19 (`4d418c2`…`28b5504`, 8 commits) — new `src/identity/quality.py` (per-frame quality gate: bbox area / sharpness / pose / single-face + composite score); new `src/identity/augment.py` (`GateConfig`/`IdSample`/`Candidate`, pure `evaluate_candidate` — dwell ≥5s + ≥10 agreeing quality-passing frames + best conf ≥0.90; `apply_augmentation` — admission dedup <0.95, `add_member(source='auto')`, `augment/success` audit event, cap-12 diversity eviction that never evicts `enroll` anchors); `tracker.py` `Track` gains `id_samples` deque + `augmented` flag + `add_id_sample`; new `src/perception/augment_reporter.py` (periodic task fires augmentation once per track when dwell gates first met — avoids racing the gaze drain; best-effort, never crashes perception); `main.py` records an `IdSample` per resolved face + starts/cancels the reporter; `resolver.py` `resolve()` now returns `(uuid, confidence)`. Full suite **105 passed** (was 92), `import main` ok.
- `mras-ops` PR #33 (`3883e2a`,`07f4d01`) — `scripts/purge_auto_embeddings.py` `purge(db, qdrant, uuid, since=None)` deletes `source='auto'` rows + Qdrant points (anchors untouched); `tests/pytest.ini` (`asyncio_mode=auto`). Unit test 1 passed.
**Learnings / gotchas:**
- `resolve()` signature change to a tuple broke `tests/test_multiface.py` (mocks returned a bare value); fixed the mocks to return `(uuid, conf)` tuples — those weren't in the plan but were affected call sites.
- mras-ops has **no unit-test harness** (only the docker-gated `tests/e2e/`); the purge unit test was run with the **mras-vision .venv** (`cd /Users/jn/code/mras-ops && /Users/jn/code/mras-vision/.venv/bin/python -m pytest tests/test_purge.py`) because system python lacks `qdrant_client`.
- Added `from __future__ import annotations` to the purge script (vs the plan's verbatim text) so its `str | None` annotation works on the py3.9 venv (the vision .venv is 3.9.6) as well as 3.11; behavior unchanged.
**State:** Both PRs **MERGED** (reviewed clean by a separate agent — gates/anchors/audit/purge verified vs spec; 105 vision + 1 ops test green): `mras-vision@c1e0038`, `mras-ops@f3a01db`. Builds on Plan 1 (`mras-ops@1d75a7b`, `mras-vision@1237a6f`). **Two minor non-blocking follow-ups** (not yet filed): (a) audit provenance stores `{"track": frames}` but NOT `track_id` (Candidate doesn't carry track_id) — weaker traceability than the spec's `{track_id,frames,confidence,ts}`; (b) `_evict_if_over_cap` has no dedicated unit test (logic verified by reading only). **Live camera E2E pending owner** (enroll Jason → walk-up under varied lighting → `augment/success` event + new `source='auto'` row → confidence rises → run purge CLI → confirm `auto` rows/points gone, `enroll` anchors remain). Follow-up: `pose_deg` is a near-frontal proxy (0.0) — wire real head-pose yaw/pitch if the attention analyzer exposes it. (Concurrent work: another agent on `mras-composer` only; no overlap.)

## 2026-06-18 — Live /enroll segfault root-caused; Jason re-enrolled via standalone; serialized-inference fix planned (PR #14)
**Changes:**
- Jason re-enrolled **additively** under current lighting via a standalone script (`/tmp/standalone_enroll.py`, reuses `run_enrollment(additive=True)`; run with vision DOWN so no camera loop). Jason gallery now `{enroll: 2}`, Qdrant **3 points**. Operational — no repo change.
- `minority_report_architecture` PR #14 (docs-only) — serialized-inference-worker **spec + plan**.
**Learnings (root cause, confirmed via systematic debugging):**
- **Live `POST /enroll` segfaults** because DeepFace/TF/mediapipe native inference is **not safe to call concurrently**. The camera loop calls `DeepFace.represent` **every frame** (the detector runs even with the lens covered / no face in view), colliding with the enroll's `embed` on the event-loop thread → shared TF model/session/MPS(Metal) corruption → native crash. Proven: standalone `embed()` works (dim 512); crash only inside the running server; **lens-covering did NOT help** (camera still calls `represent` every frame); gallery/Qdrant unchanged after the crash → our additive code is clean, the crash is in the embed step.
- **Workaround that works:** enroll in a standalone process (no camera loop) — process isolation means no shared TF/Metal state, no concurrency.
- **Fix (PR #14 plan):** route ALL native inference (embed/mood/objects/attention/enroll/prewarm) through one `max_workers=1` worker → no concurrent inference, Metal thread-affinity, also removes the Bug-B thread oversubscription. NOTE: camera `cap.read` (`capture.py`) STAYS on the default pool — it's I/O, not inference.
**State:** Jason re-enrolled additively to **3 lighting conditions** (jason_now.jpg + jason_nownow.jpg via standalone; gallery `{enroll: 3}`, Qdrant 4 points) — **restart vision + walk up to confirm recognition** clears threshold reliably. **Serialized-inference fix IMPLEMENTED** — `mras-vision` PR #18 (branch `fix/serialized-inference-worker`, 5 commits, 92 tests pass): new `src/perception/infer.py` single `max_workers=1` worker, all 6 inference sites rerouted, `cap.read` stays on default pool. **PR #18 MERGED** (`mras-vision@3f88ceb`) and **live E2E PASSED**: live `POST /enroll` run while standing in front of the camera (the exact prior crash condition) returned `200 OK` (`{"enrolled":0,"updated":1,"failed":[]}`) and vision kept running — no segfault. The live `/enroll` endpoint is now safe to use while the system runs (no more lens-cover/standalone workaround). Jason gallery now 4 conditions (E2E added one). Remaining: adaptive enrollment Plan 2 (auto-augmentation, PR #13); temporal orchestration plans (PR #12). (PR #14 = the design/plan docs for this fix.) **Handoff for the next agent (God View work) written: `docs/GODVIEW_HANDOFF.md`** — a cross-location real-time + historical dashboard reading the `events` table; it documents every event_type/payload shape, maps desired panels to data, and flags the big gap (no `location_id` dimension exists yet — single-location `screen_0` only).

## 2026-06-18 — Adaptive enrollment Plan 1 (gallery foundation) implemented → PRs open
**Changes (branch `feat/adaptive-enrollment-gallery` in both repos; TDD red→green per file):**
- `mras-ops` PR #32 (`183f9f7`) — `db/migrations/003_identity_embeddings.sql`: multi-embedding gallery table (`id, identity_uuid FK, embedding float4[], source 'enroll'|'auto', quality, provenance jsonb, created_at`) + indexes + backfill. **Applied to the dev DB — 2 enroll anchors (Jason, Ragnar).**
- `mras-vision` PR #17 (`54a9220`…`502fe31`) — `src/identity/gallery.py add_member` (Postgres row + Qdrant point, point-id = row id, payload.uuid groups); `resolver.py best_identity()` group-by-uuid max-score + `limit=QDRANT_GALLERY_FANOUT` (15); `enroller.py` additive (`source='enroll'`, non-destructive) re-enroll + `/enroll` `additive` form field. Full suite **90 passed** (was 85; +5).
**Learnings:** resolution change is backward-compatible — single-hit payloads resolve identically through `best_identity`, so existing resolver tests stayed green. Migration is idempotent (IF NOT EXISTS + guarded backfill); initdb runs it on fresh volumes, apply manually on existing (done).
**State:** Plan 1 **MERGED** to `main` in dependency order — `mras-ops@1d75a7b` (#32, table) then `mras-vision@1237a6f` (#17, code). Both local mains in sync; vision `.env` still `CONFIDENCE_THRESHOLD=0.67`. **Restart vision to load the merged gallery code before testing. Live verification pending (owner + camera):** additively re-enroll Jason under current lighting (`POST /enroll` with `additive=true`), walk up, confirm recognition clears threshold consistently (vs prior 3/60) and prior enrollment still matches (nothing overwritten). Then adaptive enrollment Plan 2 (gated auto-augmentation, docs PR #13) and the temporal-orchestration plans (PR #12) remain to implement.

## 2026-06-17 — Two perception bugs fixed + two features designed & fully planned (orchestration, adaptive enrollment)
**Changes:**
- `mras-vision@c78417e` (PR #15, MERGED) — coerce DeepFace's numpy `float32` emotion score to native `float` in `src/perception/analyzers/mood.py`. viewer-enriched `scene_context` now JSON-serializes.
- `mras-vision@caeddfb` (PR #16, MERGED) — throttle DeepFace-emotion + YOLO to ~1 Hz via `PERCEPTION_ANALYZER_INTERVAL_S` (default 1.0s); `MoodAnalyzer`/`ObjectsAnalyzer` take `min_interval_s`+injectable `clock`, objects serves last result from cache while throttled. 85 tests pass.
- `mras-vision/.env` (working-tree-only, gitignored) — `CONFIDENCE_THRESHOLD` 0.68→0.67.
- **Planning (docs-only PRs against minority_report_architecture):** PR #12 = temporal display orchestration (spec + 3 impl plans); PR #13 = adaptive enrollment (spec + 2 impl plans). Both owner-approved via brainstorming; awaiting review, NO code yet.
**Learnings:**
- **float32 silently killed the whole viewer/mood feature.** DeepFace emotion scores are numpy `float32`; they rode into `viewer.mood_confidence`, so once a track passed the 3s dwell gate, `json.dumps` raised `Object of type float32 is not JSON serializable` on BOTH paths — the detection-success log (`resolver._log_event`) AND the composer `/trigger` dispatch (`resolver._dispatch`). Net effect: successful detections never carried `viewer`, and viewer-enriched triggers showed up only as `dispatch/error` rows. Fix = cast at the source in `mood.py`.
- **Heavy analyzers ran ~6x/sec → CPU/thermal spiral → track churn.** The capture loop `await`s `process_frame`, and every sampled frame ran YOLO full-frame + DeepFace per track. On a GPU-less Mac this thermally throttled and pushed per-frame latency past the 2s track-expiry, so one person was re-tracked as `t-1…t-13` with null-uuid gaps. Throttling the two heavy models to ~1 Hz (identity+tracking still every frame) dropped distinct tracks over 3 min from **6+ → 2** and let personalized ads fan to all 4 displays. Verified live.
- **Recognition is marginal, not broken.** Live "Jason" scores cluster ~0.679 against the 0.68 threshold; lowering to 0.67 lifted recognition 1/181 → 3/60 — enough to fire ads but still occasional. Robust fix is **re-enrollment under demo lighting** (owner deferred it for now).
- **Run-script gotcha:** `start-mras.sh` already launches native vision in the foreground; `run-vision-native.sh` is only for "Docker up but vision down." Running both collides on port 8001 (the second errors "port already in use"). During model prewarm the port is bound but `/health` doesn't answer yet (~20-40s cold).
**Design decisions captured (for the two planned features):**
- **Temporal orchestration (PR #12):** each identification = a bounded **2-round per-person program** (opener on all owned displays → paired `A,A,B,B` round 2 → idle; **no round 3**). Even-split co-present people, **newest-wins** tiebreak; handoff only at clip-end (never mid-clip). Event-driven pacing (kiosk `clip_ended` + composer duration watchdog). Render-ahead during the opener; render-gap → idle then resume. New: composer `Orchestrator` (pure command core) + `/presence` stream from vision + kiosk `clip_ended`. **Important finding:** 4 active ads already exist and `select_variants` already fans distinct ads per display — Jason "saw the same ad" because 4 ads share base videos + all show his name (content gap, not code).
- **Adaptive enrollment (PR #13):** **full multi-embedding gallery, max-similarity match** (averaging is *least* accurate across lighting — it's Jason's 0.679 problem). New `identity_embeddings` table (mras-ops migration) + multi-point Qdrant; group-by-uuid resolution. **Conservative gated auto-augmentation** at end of dwell (conf≥0.90, dwell≥5s & ≥10 same-uuid frames, quality gates, dedup<0.95), **auto-add but audited + reversible** (purge-by-uuid); `source='enroll'` anchors protected from eviction; additive (non-destructive) manual re-enroll. The poisoning risk the owner raised is handled by high gates + provenance audit + reversibility, never learning from borderline matches.
**State:** Bugs A & B fixed, MERGED, live-verified (viewer lands in detection-success; float32 dispatch errors → 0; distinct tracks/3min 6+→2; personalized ads fan to 4 displays). Two features designed + fully planned (PRs #12, #13) — **not yet implemented**. Owner intent: implement both once plans are confirmed. Pending: review/confirm PRs #12 & #13 then execute; re-enroll Jason (the additive-enroll path in PR #13 Plan 1 is the durable fix); confirm TTS speaks the name (last `tts_attempt` payload empty `{}`); on-screen name text still Phase 0.5 (Remotion). Implementation order suggestion: enrollment Plan 1 (gallery) gives the immediate recognition win.

## 2026-06-12 — Phase 2 perception part 1 SHIPPED (objects+colors, mood, attention, gaze, /debug/live)
**Changes:**
- minority_report_architecture@`562ae7e` (**PR #11 merged**) — approved design spec
  (`docs/superpowers/specs/2026-06-12-phase2-perception-part1-design.md`), 13-task implementation
  plan (`docs/superpowers/plans/2026-06-12-phase2-perception-part1.md`), TODO-7 (consume signals
  for ads — part 2 backlog) and TODO-8 (multi-camera management, after production-level test).
- mras-vision@`f6159d1` (**PR #11 merged**) — batch 1: `embed_all` returns `Face(embedding, bbox)`;
  `src/perception/tracker.py` FaceTracker (IoU + ArcFace-cosine tiebreak, 2s expiry →
  `drain_closed()`, per-track mood/attention evidence, dwell-gated `viewer_summary`, uuid binding);
  aggregator analyzers take `(frame, tracks)`, `None` results omitted.
- mras-vision@`a4a34cf` (**PR #12 merged**) — batch 2: multi-backend object gateway with fusion
  (`src/perception/objects/gateway.py`; LocateAnything/VLM slot ready), yolo11n backend
  (ultralytics 8.4.66, lazy load + prewarm, weights gitignored `*.pt`), k-means dominant-color
  naming (crops downsampled to 64px), ObjectsAnalyzer (detect+color in ONE executor call —
  review fix: kmeans was blocking the event loop).
- mras-vision@`6f9e9e9` (**PR #14 merged**) — spec-gap fix found while writing the owner's
  verification commands: scene_context only traveled on the /trigger wire (composer accepts it
  but never logs it), so objects/mood were invisible to the events-table diagnostic flow.
  Detection success events now carry scene_context. Volume note: ~0.5–2KB jsonb per detection
  row (~6/s per face while in frame); revisit retention pre-production.
- mras-vision@`90a4ffd` (**PR #13 merged**) — batch 3: MoodAnalyzer (DeepFace emotion,
  `detector_backend="skip"` on track crops), AttentionAnalyzer (mediapipe 0.10.35 **tasks API** —
  no `mp.solutions` on py3.9; FaceLandmarker model atomically cached at
  `~/.cache/mras-vision/face_landmarker.task`), gaze flusher (`gaze` event rows, watermark
  advances before best-effort INSERT), resolver returns matched uuid (4 surgical lines),
  full pipeline wiring + `GET /debug/live`.
**Learnings:**
- **The vision venv is Python 3.9.6**, not 3.11 — `X | None` unions need
  `from __future__ import annotations` in every new module.
- **Real bug caught by review, fixed red-first:** the head-pose Euler decomposition labeled
  ROLL as yaw — a 30° head TURN read yaw≈0, so "attending" would never gate on turning away.
  Proven + pinned deterministically with `cv2.projectPoints` round-trip tests (turn→yaw,
  nod→pitch, facing→0/0) — no camera needed to verify pose math.
- mediapipe ≥0.10.35 dropped `mp.solutions`; use `mediapipe.tasks` FaceLandmarker.
- cv2.kmeans on full-size crops blocks the event loop inside the 800ms analyzer budget —
  run detect+color in one executor call and downsample crops first.
- `gh pr merge --delete-branch` fails from inside a worktree (branch checked out); merge
  without it, then `git push origin --delete <branch>` as a STANDALONE command — the guard
  hook false-positives on compound commands containing `push origin --delete`.
**State:** all 3 PRs merged and green (81 tests, was 44). **Owner-run live verification PENDING**
(camera needs owner terminal): walk-up with a colored object + look toward/away; check
detection events' scene_context, `gaze` rows, and http://localhost:8001/debug/live with
`PERCEPTION_DEBUG=1`. First live frames lazy-warm mood/attention models (one-time download).

## 2026-06-12 — HANDOFF.md refreshed for the next agents (PR #10)
**Changes:** minority_report_architecture@`a2a384a` (**PR #10 merged** → `ef78e21`) —
`/Users/jn/code/minority_report_architecture/docs/HANDOFF.md` fully rewritten: state as of
2026-06-12, the six LOCKED owner decisions, next work in order (production parallel composition
— **needs a plan doc before building**; God View; Phase 2 perception; open issues; demo-day
checks), process rules, run commands, gotchas. Fresh agents start there → SESSION_LOG → work.
**State:** session closing; everything merged and journaled; no working-tree-only changes anywhere.

## 2026-06-12 — Identity stores purged to real people only (owner-mandated)
**Changes (live data only, no code):** deleted **John Anderton** from BOTH stores (its qdrant
vector was byte-identical to the owner's face — same misfire class as E2EPerson) and the orphan
duplicate **Jason** row (`11111111-…`, no embedding). Final state, verified paired in postgres +
qdrant: **Jason (`f487f5b0…`) and Ragnar Ervin (`0ae7f78b…`) only.** The owner's face now exists
under exactly one name. Rule of thumb going forward: demo personas must use a face that isn't an
enrolled real person, or not be enrolled at all.

## 2026-06-12 — E2EPerson identity leak: live ads addressed "E2E"; data purged + e2e teardown (PR #31)

**Changes:** mras-ops@14f577c (merge of PR #31, red 6531935 → green 0bdf30d) —
`/Users/jn/code/mras-ops/tests/e2e/test_phase0_e2e.py` gains `_cleanup_e2e_identity()` (qdrant
delete-by-filter on payload name via httpx REST + postgres DELETE via `docker exec
mras-ops-postgres-1 psql`), an autouse session fixture that runs it even on test failure, and a
regression test that resolves the helper *before* seeding. Live data cleanup (not in git): deleted
qdrant point f7a980ca-f0e7-4957-949d-6a362a51a585 and the `E2EPerson` identities row.
**Learnings:** `tests/e2e/fixtures/test_face.jpg` is the OWNER'S face — embedding it scores 1.0 vs
E2EPerson, 1.0 vs John Anderton, 0.87 vs Jason (f487f5b0). So the e2e seed put the owner's face in
qdrant under a second name and live recognition alternated uuids (Jason 03:18/03:19, E2EPerson
03:47/03:48 detections) → ads spoke/wrote "E2EPerson". John Anderton's vector is IDENTICAL to the
fixture (also the owner's face, demo persona — left untouched). There is also a duplicate `Jason`
identities row uuid 11111111-1111-1111-1111-111111111111 with NO qdrant point (left untouched —
review). Vision has no DELETE endpoint; e2e cleanup must hit the stores directly.
**State:** identities = John Anderton, Jason (f487f5b0), Jason (11111111…), Ragnar Ervin; qdrant =
3 points (no E2E*). Vision service was down during this session; cleanup helper validated against
live stores with a synthetic seed instead of the full harness.

## 2026-06-12 — Owner rules shipped: name ALWAYS written, full-length overlays, send-when-ready
**Changes:**
- mras-composer@`6554f12` (**PR #23 merged** → `6e63c57`; red `03cace2`) — three owner rules from
  the second walk-up: (1) **a spoken name is always also WRITTEN** — the animated name-text
  overlay composites on top of EVERY personalized variant, custom-Remotion or not (pixel-verified
  at t=7s on a decorative fallingsnow variant: 8,276 white text pixels); (2) overlay windows are
  **`OVERLAY_DURATION_FRACTION` × the base clip** (code default 0.5; was a 2s flash);
  (3) **each variant ships to its display the moment it's ready** (arrivals now stagger
  28.7/33.6/36.7/39.6s instead of all-at-the-end). 109 passed.
- mras-ops@`7af4ebe` (**PR #30 merged** → `729dcc1`) — demo rig sets `OVERLAY_DURATION_FRACTION=1.0`
  (full-length name overlays). Old composited clips purged (79 mp4s) from
  `/Users/jn/code/mras-ops/output/`; composer rebuilt.
**LATENCY REALITY (recorded for the production-architecture work):** first video is still ~28s
because the owner's rules doubled the render workload — every variant = component render + name
render, both now FULL-length (192 frames vs 48), all serialized through the single-flight
sidecar (8 renders/trigger). Send-when-ready hides part of it, but the real fixes are
(a) render the name overlay once per unique base geometry (~8→5 renders), and (b) sidecar
render concurrency / horizontal render capacity — the <4s/2s production target. Neither built
tonight; they belong to the production-scale plan.
**State:** name-on-every-video + full-length overlays + staggered delivery live-verified on the
real stack. Owner re-test pending (KIOSK_DEBUG=1 badge available since PR #11).

## 2026-06-12 — Live walk-up forensics: 3 bugs found in events data, fixed & merged
Owner's first real walk-up test: Ragnar got no ad for exactly 30s; names spoken but rarely
written. **Diagnosed entirely from the `events` table** (detection confidences, a
TRIGGER_DROPPED at 02:07:29, a no_display flood) — the observability investment paid off.
**Root causes & fixes:**
1. **Stranger-flood starved real triggers** (mras-vision@`d9e4687`, **PR #10** → `b879658`):
   every sub-threshold frame (~6–12/sec; the owners themselves scoring 0.5–0.678!) dispatched a
   pointless composer call; the 8-slot queue drowned; Ragnar's identified trigger (0.79) was
   DROPPED and his claim burned → the exact 30s lockout. Fix: **unidentified faces log but never
   dispatch** — the idle loop is the standard tier. Phase 2 demographics re-opens the gate.
2. **Name-never-written was ad ORDER, not overlays** (mras-composer@`adb7736`, **PR #21** →
   `e8c8462`): `ORDER BY created_at DESC` deterministically dealt the two NEWEST ads — both
   decorative/textless — to every 2-display person. Fix: `ORDER BY random()` per trigger; plus
   the standard gate now runs BEFORE display assignment (strangers/blocked never reserve the
   wall), and play messages carry `ad` + `person`. Residual: random can still deal an
   all-decorative hand → **issue mras-composer#22** (needs a shows_name flag — schemas can't
   distinguish text-bearing comps).
3. **No visual debugging** (mras-display@`c6a015f`, **PR #11** → `faea3d3`): `KIOSK_DEBUG=1` →
   each window overlays an HTML badge `screen_id · person · ad` from the play message —
   independent of the video pipeline, so it names the chosen component even when an on-video
   overlay fails (the owner's overlay idea, made failure-proof).
**Live-verified post-merge:** Ragnar trigger → 2 displays got `comp-helloname` + `comp-snallfall`
with `person: Ragnar Ervin` in the messages. Composer container rebuilt; vision picks up the
gate on next native start; kiosk badge on next launch with KIOSK_DEBUG=1.
**Operational guidance (recognition marginal in demo lighting):** re-enroll with BOTH photos
(`./enroll.sh "Ragnar Ervin" ragnar.jpg ragnar2.jpg` — embeddings average) and consider
`CONFIDENCE_THRESHOLD=0.62` for the venue; near-miss scores are visible in the activity feed.

## 2026-06-11 — fix: demo CLIs print actionable service-down errors (owner-reported)
**Changes:** mras-ops@`2fccc31` (**PR #29 merged**, `origin/main` @ `164bbc4`) — owner ran
`./enroll.sh` with the vision service down and got a 50-line httpx traceback. Both
`/Users/jn/code/mras-ops/enroll.sh` and `compose-random.sh` now catch `ConnectError` and print
which service is down, at which URL, and the exact start command (exit 1). Live-verified both
paths. Note for later: `ConnectTimeout`/`ReadTimeout` still traceback (catch `httpx.HTTPError`
if it ever bites). **Owner burst policy locked (mras-vision#9 CLOSED):** during a burst, serve
what the queue/displays can handle; missing some people is accepted; dropped person self-heals
in 30s. Don't re-litigate without the owner.

## 2026-06-11 — PER-DISPLAY CUSTOM ADS SHIPPED: multi-face vision, variant fan-out, demo CLIs — 4-ads-for-one-person and 2/2 two-person split PROVEN live
**Plan:** minority_report_architecture@`8ab584b` (PR #9, `08d60a5`) —
`docs/superpowers/plans/2026-06-11-per-display-custom-ads.md`: owner decisions (4 distinct
custom-Remotion ads; 2/2 split; enroll + random-compose CLIs; **T0/TODO-5 latency benchmark ON
HOLD** — current architecture isn't the production shape; production = real-time PARALLEL
composition, ~4 people <4s/2s per area, 1–4 areas × ~1000 locations), plus the long-term
perception architecture (Strategy-registry analyzers, scatter-gather-with-deadline into D9
`scene_context`; face TRACKING is the real Phase 2 work).
**T-V (mras-vision@`418be31`, PR #8 merged → `08623d2`):** live path resolves EVERY face —
**recon found a hard blocker: the old live path raised `multiple_faces` and skipped any frame with
2+ people, so nothing triggered**. `embed_all()` (enrollment's one-face `embed()` unchanged);
`faces_in_frame` + `scene_context` ride the trigger payload; new
`/Users/jn/code/mras-vision/src/perception/aggregator.py` (deadline-gather, EMPTY registry — pure
seam). 43/43. Follow-up: issue mras-vision#9 (release claim on queue-drop; multi-face amplifies).
**T-C (mras-composer@`db7db6a`+`7d246c9`, PR #20 merged → `ed8a1b7`):** WSManager tracks
`screen_id` per kiosk window + `send_to`; `DisplayAssigner` splits displays evenly by
`faces_in_frame` with TTL reservations (DISPLAY_HOLD_SECS=12, released early when nothing will
play — review caught a new visitor freezing the wall); `select_variants` = up to N DISTINCT
active custom ads (cycle when fewer, legacy fallback, identity-race guarded); `/trigger`
composes variants IN PARALLEL and targets each display its own clip; untagged kiosks keep the
legacy broadcast. ffmpeg Semaphore 1→`FFMPEG_CONCURRENCY` (default 4). 101 passed.
**T-E/T-R (mras-ops@`0ea03df`, PR #28 merged → `35aebd0`):**
`/Users/jn/code/mras-ops/enroll.sh "Name" photo.jpg` (vision /enroll wrapper; live-verified via
the E2EPerson duplicate-merge path: `updated: 1`) and
`/Users/jn/code/mras-ops/compose-random.sh [Name]` (random base × random ready component via
composer /preview; live-verified: fallingsnow × standard.mp4 → real mp4).
**LIVE E2E (real stack + 4-window kiosk, no camera):**
- Seeded 2 more active ads → 4 active ads on 4 DISTINCT components (snallfall, helloname,
  fallingsnow, lightleak).
- **Jason alone (faces_in_frame=1): one trigger → `{status: ok, displays: 4}` — all 4 displays
  played a DIFFERENT composed clip** (variant suffixes -0..-3). Took **16.6s**: the overlay
  sidecar renders are single-flight (M3 design), so 4 variants serialize there — fine for the
  demo, but the <4s production budget needs parallel render capacity (recorded in the plan).
- **Two people (both faces_in_frame=2): Jason → displays 1+2, E2EPerson → displays 3+4**, each
  pair showing that person's own two variants; one TTS per person (Gemini). 6.8s/11.2s.
**Gotchas:** components uploaded pre-M5 have empty props_schema → compose-random personalizes
the first STRING prop only when one exists (decorative comps rely on the TTS voice for the
name); FFMPEG_TIMEOUT=10 survived 4-wide parallel encodes (long pole is the sidecar, not
ffmpeg).
**State:** everything merged & live-verified except the physical walk-up (camera needs the
owner's terminal): restart native vision (now multi-face), stand in frame alone → 4 ads; with a
second enrolled person → 2/2. Enroll them via `./enroll.sh "Name" photo.jpg`.

## 2026-06-11 — T2 + T3 SHIPPED: burst backpressure + kiosk watchdog — Phase 1 core complete
**T2 (mras-vision@`fbf440a`+`cf76d85`, PR #6 merged, `origin/main` @ `0ffb8b9`):** per-trigger
`create_task` replaced by `asyncio.Queue(maxsize=TRIGGER_QUEUE_MAX, default 8, clamped ≥1)` + one
drain worker in `/Users/jn/code/mras-vision/src/identity/resolver.py`. At most 1 in-flight composer
POST, FIFO; full queue → drop + `TRIGGER_DROPPED` event (visible in the ops feed). Worker survives
dispatch failures and is revived if it ever dies; also fixes a pre-existing fire-and-forget
task-GC hazard. TDD red→green `a82adc4`→`fbf440a` (+2 review red→greens); 34/34 pytest. **Live:**
burst of 6 (queue_max=2) vs the real composer → exactly 3 POSTs, 3 `dropped` rows in real Postgres
`events`. Follow-up filed: mras-vision#7 (Redis queue if P1 goes multi-process + claim-token
release on drop).
**T3 (mras-display@`747ad01`+`76b5df0`+`f26953c`, PR #9 merged, `origin/main` @ `ffc0f9b`):**
- Outer: `launchd/com.mras.kiosk.plist` (KeepAlive+RunAtLoad) + README — **must exec the REAL
  Electron binary** (`node_modules/electron/dist/Electron.app/Contents/MacOS/Electron`); the
  `.bin/electron` shim is `#!/usr/bin/env node` and launchd has no node on PATH (live E2E caught
  it: `env: node: No such file or directory`, exit 127).
- Inner: `render-process-gone` → recreate just that window with **exponential backoff** (1s→30s
  cap, reset on healthy load; replacement-before-destroy so `window-all-closed` can't fire);
  `unresponsive` → reload. `/health` on `KIOSK_HEALTH_PORT` (default **8003**) serves per-window
  status; **EADDRINUSE degrades monitoring, never kills the kiosk** (review caught the health
  server being able to crash-loop the kiosk it monitors). 41/41 vitest.
- **Live E2E:** SIGKILL one renderer → that window recreated (backoff logged), other display
  untouched, health ok; production build under a temp launchd plist → `kill -9` main pid →
  **relaunched by KeepAlive** (new pid), health ok; temp plist removed. Alert wiring filed as
  mras-display#10 (P3-C4 doesn't exist yet).
**Ops notes:** kiosk health: `http://localhost:8003/health`. Supervisor install/remove:
`/Users/jn/code/mras-display/launchd/README.md`. Vision picks up T2 on next native restart
(`TRIGGER_QUEUE_MAX` env to tune).
**State:** **Phase 1 core (T-D, T1+race fix, T2, T3) ALL SHIPPED & live-verified.** Remaining:
T4 AWS profile (deferred by owner), T0 latency validation (optional), demo-day walk-up checks
(restart-survival cooldown, 2-monitor fullscreen, WS-reconnect after launchd relaunch).

## 2026-06-11 — Cross-camera cooldown race CLOSED: atomic try_claim (T1 follow-up)
**Changes:** mras-vision@`8c07f2c` (**PR #5 merged**, `origin/main` @ `4ef3056`; red `cdb0fe3`) —
the cooldown store's two-step `is_on_cooldown`/`record_impression` collapsed into one atomic
`try_claim(key)` in `/Users/jn/code/mras-vision/src/identity/cooldown.py`: default single-ad
policy = one `SET NX EX` (exactly one racer wins the window, TTL lands with the key);
`max_ads>1` = one Lua script (blocked-check→INCR→EXPIRE→threshold-flag, no boundary overshoot).
Resolver inverts to claim→dispatch-if-won. Test dep `fakeredis`→`fakeredis[lua]` (lupa; test-only —
real Redis runs Lua natively). 28/28 pytest.
**Live (real Redis):** 5 concurrent claims → exactly 1 winner; fresh process blocked; Lua path
2-allowed-then-blocked; every key TTL'd.
**Learnings / design notes (load-bearing for T2):**
- **The claim must stay at resolve time.** Deferring it to dispatch/dequeue time would let an
  in-frame person enqueue ~180 duplicate triggers per 30s window (6fps), flooding the future T2
  queue and starving other people's ads. Accepted cost: a T2 queue-drop burns the claim (person
  waits out the 30s). Compatible extension if ever needed: claim token (key holds a UUID,
  compare-and-delete release on drop).
- fakeredis runs commands serially — it can contract-test concurrency but not reproduce a true
  interleaving; the race proof is `SET NX` atomicity verified live against the real container.
- In-memory fallback stays per-process (degraded mode only — cross-process safety requires Redis).
**State:** race closed & live-verified. Phase 1 remaining: **T2 (burst queue) → T3 (watchdog)**.

## 2026-06-11 — T1 SHIPPED: Redis shared cooldown (TTL-only keys, in-memory fallback)
**Changes:**
- mras-vision@`a2ef3e4`+`26fda0b` (**PR #4 merged**, `origin/main` @ `67db4a4`) — new
  `/Users/jn/code/mras-vision/src/identity/cooldown.py`: `RedisCooldownStore` when `REDIS_URL` is
  set (shared across cameras/processes, survives restarts) else the Phase 0 in-memory dict;
  per-call fallback to memory on Redis errors. Resolver delegates (injectable store); key
  `screen_id:uuid` (namespaced `cooldown:`/`impressions:`); `screen_id` = camera/screen-group.
  Deps: `redis` (runtime), `fakeredis` (tests). TDD red→green `ffc381b`→`a2ef3e4`; 27/27 pytest
  (10 new). Review: 3 important findings, all fixed in `26fda0b`.
- mras-ops@`d771469`+`2ffe22c` (**PR #27 merged**, `origin/main` @ `297bce6`) — `redis:7-alpine`
  compose service (**loopback-only `127.0.0.1:6379`** — unauthenticated Redis must not reach venue
  Wi-Fi; healthcheck; **deliberately NO volume**); vision compose env + `run-vision-native.sh` get
  `REDIS_URL` defaults. Container recreated from merged main — port now binds loopback.
**OWNER DATA-BOUNDARY RULE (locked 2026-06-11):** Redis holds ONLY transient coordination flags —
**every Redis key must carry a TTL** (cooldown = `COOLDOWN_SECS`=30s; any bookkeeping key capped at
24h; the default MAX_ADS=1 path writes a single `SET EX`, no counter at all). **Durable
transactional play history (dashboard, billing, play proof) lands in the PostgreSQL `events` table
(D19), never Redis.** Losing Redis costs at most one repeated ad per person.
**Live verification (real Redis container):** cooldown key TTL=30; a **fresh second process** sees
the cooldown (restart/second-camera survival — the point of T1); `max_ads=2` pipeline path
verified; `docker stop redis` → warning + in-memory fallback, no crash; `redis-cli` shows only
TTL'd keys, counters cleaned up.
**Learnings / gotchas:**
- Review caught an **un-TTL'd key window**: separate `INCR`+`EXPIRE` round trips could strand a
  TTL-less counter if Redis failed between them — fixed with a transaction pipeline (and the
  default path avoids the counter entirely). Also caught: suite hermeticity (`tests/conftest.py`
  now scrubs ambient `REDIS_URL`) and the 0.0.0.0 port binding.
- The git guard pattern-matches `push`+`main` across a whole compound command line — run `git push`
  and `gh pr create --base main` as separate Bash calls.
**State:** T1 shipped & live-verified. Phase 1 remaining: **T2 (burst queue) → T3 (watchdog)**;
T4 deferred. Restart-survival walk-up test with the real camera still worth doing at next demo.

## 2026-06-11 — T-D SHIPPED: multi-display kiosk (4 windows, shuffled idle) + Phase 1 plan resequenced
**Changes:**
- minority_report_architecture@`7b8b372` (**PR #8** merged, `c164fc3`) — Phase 1 plan
  (`docs/superpowers/plans/2026-06-11-phase-1-venue-readiness.md`) gained new ticket **T-D**
  (owner requirement: 1–10 displays off one camera system, 4 at startup, shuffle not loop, same
  composed clip on all for now), resequenced **T-D→T1→T2→T3**, **T4 (AWS) deferred**; T1 note:
  cooldown `screen_id` = camera/screen-group, NOT per display; T3 gains a per-window
  `render-process-gone` recovery layer.
- mras-display@`1d897ba` (**PR #7 merged**, `origin/main` @ `25fa0be`) — **T-D done.** Electron
  startup creates `DISPLAY_COUNT` windows (default 4, clamp 1–10) via new pure
  `/Users/jn/code/mras-display/electron/layout.js` (fullscreen-per-monitor when ≥N monitors, else
  grid on primary); each window loads `?screen_id=display-<n>` and appends it to the composer WS
  URL (forward hook — composer ignores it today). Idle rotation is a **shuffled cycle** per window
  (new `/Users/jn/code/mras-display/src/shuffle.ts`: Fisher-Yates, full coverage per cycle, no
  immediate repeat across cycles; drop-in `/playlist` refreshes join the next cycle). TDD
  red→green `6e30c5a`→`1d897ba`; 32/32 vitest (12 new), tsc clean. Code review: ready-to-merge,
  0 critical/important.
**Live E2E (real stack + Electron):** 4 windows opened with distinct screen_ids; composer logged 4
`/ws?screen_id=display-N` connections; independent shuffle orders observed; real `POST /trigger`
(enrolled Jason) → **all 4 windows played the same composed clip** then resumed **4 different**
idle videos.
**Learnings / gotchas:**
- **Stale vite on 5173 = silent stale-code E2E.** `electron:dev` hardcodes 5173; a leftover dev
  server from the main checkout served OLD App code while the worktree's vite sat on 5174 — looked
  exactly like a code bug (lockstep sequential rotation). Kill 5173 listeners before kiosk E2E.
- **Pre-existing lockfile drift in mras-display:** `playwright` is in `package.json` dependencies
  on main but missing from `package-lock.json` (npm install dirties the lock). Excluded from the
  T-D PR; filed as a follow-up chore issue.
- Fullscreen-per-monitor path is unit-tested only (single-Mac dev box; macOS gives each
  fullscreen window its own Space) — do a 2-monitor smoke test before venue day.
**State:** T-D shipped & live-verified. Phase 1 remaining: **T1 (Redis cooldown) → T2 (burst
queue) → T3 (watchdog, now multi-window-aware)**; T0 latency check optional-first; T4 deferred.

## 2026-06-11 — Phase 1 plan consolidated + HANDOFF pointer (PR #6); journal catch-up
**Changes:** minority_report_architecture@39511c8 (merged via **PR #6** `6eed023`) —
- `/Users/jn/code/minority_report_architecture/docs/superpowers/plans/2026-06-11-phase-1-venue-readiness.md`
  — the consolidated **Phase 1 (multi-camera venue readiness)** plan: TODOS.md TODO-1..4 turned into
  sequenced tickets T1 (Redis shared cooldown) / T2 (P1→P2 backpressure) / T3 (kiosk watchdog) /
  T4 (AWS GPU profile), plus optional T0 (TODO-5 ffmpeg latency validation), with per-ticket TDD
  breakdowns and success criteria. Code lands in sibling repos (mras-vision, mras-display, mras-ops).
- `/Users/jn/code/minority_report_architecture/docs/HANDOFF.md` — title now "M3/M4/M5 done; Phase 1
  next" + a "Next phase" pointer to the plan. Fresh-agent entry point: HANDOFF → plan → execute.
**Learnings:** the prior session's handoff claimed `a37a6cf` (the "guard hardening DONE" journal
commit) was discarded by a `git reset --hard origin/main` — it wasn't; it is reachable from
`origin/main` and the hardening entry below already reads DONE. Verify git state before "correcting"
it. Also: the auto-mode permission classifier can block even the guard-sanctioned direct journal push
(`CLAUDE_GIT_OK=1 git push origin main`); when that happens, land journal updates via a chore PR
instead of fighting it (this entry landed that way).
**State:** Phase 0 + 0.5 (M3/M4/M5) done and merged; Phase 1 planned but not started. Next: execute
the Phase 1 plan ticket-by-ticket (T0 latency validation first, then T1→T4).

## 2026-06-09 — Review-findings (4 fixes) + git-governance convergence + SESSION_LOG guard exception
Working the 4 non-blocking review findings from the delete-ads/components merge, plus the
pre-filed #17, as proper tickets in **`mras-ops`** (all five live there, not in this repo).
Worktree-per-ticket + git delegated to the `git-flow-manager` subagent; sequential (grouped by
file) to avoid same-line conflicts. **#2+#4 combined** into one ticket (same DELETE handlers).
**Issues filed (jgervin/mras-ops):** #18 (non-UUID DELETE→500, finding #2), #19 (DELETE no-404,
finding #4), #20 (coerceProps boolean default, finding #3), #21 (adPropValues reset deps, finding
#1). #17 (props_schema key) already open.
**Ticket 1 — DONE (closes #18+#19):** `fix/18-harden-delete-handlers`. DELETE `/ads|/components`
now UUID-validate the id (→**400**, before the DB call) and check the asyncpg command tag (→**404**
on no-match); 409 in-use path preserved. TDD red→green: `fb3a499` (4 failing tests) → `9270356`
(fix). **PR #22 merged** → `origin/main` @ **`c631c08`**. Suite 13/13.
**Live E2E (httpx → ops-api :8080, after `docker compose up -d --build mras-ops-api`):** bad id→400,
absent uuid→404 (both `/ads` and `/components`), `GET /ads`→200. The 404 confirms real asyncpg
returns `"DELETE 0"` for a no-match (the basis of the fix) — verified against live Postgres.
**Gotcha:** mras-ops **local `main` is 3 commits ahead of `origin/main`** (unpushed governance
commits `a14f2ca` = the git guardrails). Branched tickets from `origin/main` for clean diffs; after
merging #22, rebased local `main` onto `origin/main` (governance replayed → `cfa3cc9`, 3 ahead, clean)
so the working tree has the fix for the container rebuild. **Open question for next session:** land the
3 governance commits on `origin/main` via a chore PR (they can't be pushed to `main` directly — guarded).
**Ticket 2 — DONE (closes #17):** `fix/17-normalize-props-schema-key`. `POST /components` now returns
`props_schema` (snake_case, matching GET + the DB column) instead of `propsSchema`; frontend reads the
single key and drops its dual-key tolerance (`api.ts` `ComponentRecord`, `Authoring.tsx` upload-result +
Create-Ad reads). ops-api↔sidecar contract (reads the sidecar's camelCase `propsSchema`) unchanged. TDD
red→green: `b28a97a` (tests assert `props_schema`) → `1c3098d` (impl). **PR #23 merged** → `origin/main`
@ **`485c239`**. pytest 13/13, vitest 17/17, tsc clean.
**Live E2E:** rebuilt ops-api **and** ops-frontend (`docker compose up -d --build`). httpx upload →
`POST /components` response keys include `props_schema` (no `propsSchema`), props count/colors/speed/
waveAmplitude. **Playwright UI:** uploaded FishSwim.tsx via the running frontend → Preview rendered all
four schema-driven fields default-filled (count=6, colors=[…], speed=1, waveAmplitude=0.06), Status:
ready. Cleaned up test component + cwd file afterward (delete returned 200 — hardened DELETE handles real
rows too). Op note: frontend bakes source at build time, so `--build` is required for ops-frontend.
**Ticket 3 — DONE (closes #20):** `fix/20-coerceprops-boolean-default`. `coerceProps`
(`frontend/src/Authoring.tsx`) emitted a boolean for every boolean field even when untouched, sending
`false` and overriding the component's own default. Fix = one-line reorder: moved `if (v === "")
continue;` above the `p.type === "boolean"` branch, so an empty boolean is omitted like every other
optional type. TDD red→green: `a2017c9` (component-level test asserting an untouched boolean is omitted
from the preview payload) → `fa1f493` (fix). **PR #24 merged** → `origin/main` @ **`7ec959e`**. vitest
18/18, tsc clean.
**Live E2E (Playwright, after rebuilding ops-frontend):** no example component has a boolean prop, so
authored a minimal `BoolCheck.tsx` with `showText: z.boolean().optional()` (a *required* boolean 422s in
the sidecar — it can't render without it; optional-no-default is the case that yields an empty raw value
and exercises the fix). Uploaded via the UI → Preview rendered `text (string)`=Hi + an unchecked
`showText (boolean)` checkbox → clicked Preview without touching it → captured the live `POST :8002/preview`
body: `props` = `{"text":"Hi"}` — **`showText` omitted** (pre-fix it would be `{"text":"Hi","showText":false}`).
Cleaned up the authored test components + cwd file afterward (demo back to the 5 originals).
**Ticket 4 — DONE (closes #21):** `fix/21-adpropvalues-reset-deps`. The Create-Ad prop reset
`useEffect` (`frontend/src/Authoring.tsx`) depended on the whole `components` array, so deleting ANY
component re-ran it and wiped in-progress ad prop edits. Fix: depend on `[adForm.component_id,
adSchemaProps]` instead (and dropped the eslint-disable — deps are now honest). `adSchemaProps` is the
selected component's `.properties` object **by reference** (`schemaPropertiesOf` returns it directly, not
a fresh object), and delete uses `setComponents(prev => prev.filter(...))` which preserves surviving
element refs — so an unrelated delete leaves `adSchemaProps` stable and the effect doesn't fire. TDD
red→green: `c9df5b6` (test: edit an ad prop, delete an unrelated component, edit must survive) →
`08b885e` (fix). **PR #25 merged** → `origin/main` @ **`032f570`**. vitest 19/19, tsc clean.
**Live E2E (Playwright, after rebuilding ops-frontend):** uploaded two schema'd throwaways; selected one
in Create Ad → count/colors/speed/waveAmplitude fields rendered; edited `count` 6→**99**; deleted the
*other* (unrelated) component → `count` **stayed 99** (pre-fix it would reset to 6). Cleaned up both
throwaways (demo back to the 5 originals). Op note: `fish1` and other pre-M5 components have
`props_schema={}` and correctly fall back to the JSON textarea — only schema'd components render fields.

**ALL FOUR REVIEW-FINDING TICKETS SHIPPED + LIVE-VERIFIED.** Merged to `mras-ops` `origin/main` in order:
#22 (`c631c08`, closes #18+#19) → #23 (`485c239`, closes #17) → #24 (`7ec959e`, closes #20) → #25
(`032f570`, closes #21). Each: own worktree off origin/main, TDD red→green (separate commits), self-review,
live E2E, merge, container rebuild. ops-api + ops-frontend rebuilt from the final main.
**GOVERNANCE CONVERGENCE (resolved this session):** the git-governance bootstrap commits had been
committed directly to local `main` in all 5 CLAUDE.md repos and never pushed (couldn't be — the guard
blocks pushing to `main`). Landed them on each `origin/main` via a `chore/land-git-governance` PR, then
`reset --hard origin/main` to converge local main (0 ahead / 0 behind): minority_report_architecture #3
(`e5dc299`), mras-composer #19 (`f2552ba`), mras-kiosk #1 (`226d058`), mras-ops #26 (`07e8f1f`),
mras-vision #3 (`63a30cd`). Divergence gone; future tickets branch off `origin/main` and merge via PR, so
it won't recur. Guard gotcha (use `HEAD`, not the literal word `main`, as a branch start-point — the guard
substring-matches `main`).
**SESSION_LOG guard exception:** added a journal-only push exception to
`/Users/jn/code/minority_report_architecture/.claude/hooks/guard-git.sh` (PR #4, `36eaa10`; test-first via
`.claude/hooks/guard-git.test.sh`, 7/7): a push to `main` is allowed iff the `CLAUDE_GIT_OK=1` marker is
present AND the net diff (`origin/main..HEAD`) is nothing but `docs/SESSION_LOG.md`. This journal can now be
committed + pushed straight to main with no PR — which is how THIS entry landed.
**SECURITY (hardening — DONE, PR #5 `e4dcafe`):** two automated reviews flagged a HIGH on the exception —
it inferred the payload from `origin/main..HEAD` rather than the actual pushed refspec, so an unusual push
form (`git push origin other:main`, `refs/heads/main`, `git -C … push`, or a compound command) could differ
from what the diff check saw. Guard is accident-prevention, not adversarial-proof (marker is readable), and
the real journal push is the safe literal `git push origin main`, so it was never exploited. Hardened
test-first (`guard-git.test.sh` 13/13, +6 security cases): the exception now requires the EXACT literal form
`CLAUDE_GIT_OK=1 git push origin main` (or `HEAD:main`, opt. `-u/-q`) — source is always HEAD/main, no
refspec differential; compound commands rejected by the `$` anchor; push/main detection broadened to catch
`git -C … push` and `refs/heads/main` so the deny path can't be skipped; the journal-only diff check kept as
defense in depth.
**Guard ergonomics / gotchas:** (1) the detection substring-matches `git…push` + a `main` token, so a
`git commit`/`gh pr` whose MESSAGE or BODY contains the phrase "git push … main" is over-denied (fail-safe)
— pass such text via `-F`/`--body-file` from a temp file, not inline. (2) Use `HEAD`, not the literal word
`main`, as a branch start-point. (3) Known residual (pre-existing, documented in-code): a *bare* `git push`
from `main` with an upstream isn't detected; git-flow-manager always uses explicit `git push origin main`.
**State:** ALL DONE — 4 mras-ops review findings + governance convergence (all 5 repos) + SESSION_LOG guard
exception + security hardening, all shipped & verified. Nothing pending.

## 2026-06-09 — Git workflow guardrails: worktree-per-ticket rules + git-flow-manager subagent + PreToolUse guard
Standardized Git discipline across all 5 MRAS repos that have a `CLAUDE.md`
(`minority_report_architecture`, `mras-composer`, `mras-kiosk`, `mras-ops`, `mras-vision`).
`mras-display` and `mras-overlays` were **skipped — they have no `CLAUDE.md`.** Goal: stop agents
stepping on each other's branches / touching `main`. Three commits per repo (all on `main`; the
rules themselves are the bootstrap, so they were committed directly):
**Changes (per repo: rules → agent → guard):**
- `minority_report_architecture@cd67a96` → `@c5698f7` → `@d846a08`
- `mras-composer@2cf1424` → `@809385e` → `@c527940`
- `mras-kiosk@7507452` → `@04f7600` → `@284cf34`
- `mras-ops@11fdef8` → `@8a36b1e` → `@a14f2ca`
- `mras-vision@dc65827` → `@a528918` → `@b48f985`
**What landed:**
1. **CLAUDE.md "Git & Branching Rules"** — branch off `main` as `{type}/{ticket}-{slug}`, one worktree
   per ticket (`claude -w feat/TKT-…` → `.claude/worktrees/feat-TKT-…/`), `start ticket` / `open PR` /
   `finish ticket` lifecycle, stacked-PR handling, and "main agent must delegate all git to the
   `git-flow-manager` subagent."
2. **`.claude/agents/git-flow-manager.md`** — the sole sanctioned Git operator. **Replaced** a stale
   Git Flow agent (develop/release/hotfix, no worktrees) that pre-existed untracked in composer/ops and
   contradicted the new model. Same content in all 5 repos (kept the filename per user request).
3. **PreToolUse guard** (`.claude/hooks/guard-git.sh` + `.claude/settings.json`) — denies raw `git`/`gh`
   in the session; the subagent opts in with the `CLAUDE_GIT_OK=1` marker; **pushing to `main` is
   hard-blocked even with the marker.** `.gitignore` now tracks `.claude/{agents,hooks}/` +
   `settings.json` while keeping `.claude/worktrees/` and `settings.local.json` ignored.
**Learnings / gotchas:**
- **The guard activated live mid-session** the moment `.claude/settings.json` was written in the cwd
  repo — the settings watcher picked it up without a restart. Verified end-to-end: marker-free `git log`
  → denied; `CLAUDE_GIT_OK=1 git log` → allowed. For the *other* repos the hook activates when a Claude
  session next starts there (committed settings load at startup).
- **Marker scope is whole-command:** a single Bash call is allowed if `CLAUDE_GIT_OK=1` appears anywhere
  in it (one combined echo+git demo leaked through because a later clause carried the marker). Run the
  deny case as its own marker-free call.
- All 5 repos default to `main` with **no `develop`/`master`** anywhere (local or remote) — the
  branch-off-`main` model matches reality.
- Not adversarial-proof (an agent could read the marker); it stops *accidental* raw git. The
  `main`-push block is the one rule that holds regardless of marker.
**State:** Live and verified in `minority_report_architecture` this session; committed in all 5 repos.
Pending: nothing required. Optional follow-ups offered — relax guard to mutation-only if read-only
denies get noisy; rename `git-flow-manager.md` (content is ticket/worktree, not classic Git Flow).

## 2026-06-09 — Delete ads/components: live E2E fixes + reconciled with M5, MERGED to main
Debugged a live-demo failure (delete buttons broken) with systematic debugging + Playwright E2E.
**Merged to `mras-ops` main** (`origin/main` @ `7ee9e3d`) via a **stacked PR** chain:
`feat/delete-ads-and-components` (PR #14) → base `fix/flag-broken-ads` (PR #13) → `main`. Merge order
was child→parent→main: PR #14 first (into its parent branch), then PR #13 (parent → main). Reviewed
(`/code-review` — 4 non-blocking findings, see below), tests 17/17, both merges CLEAN.
**Root causes (two):**
1. **Stale ops-api container.** Branch code was correct (`DELETE /ads|/components` + CORS `DELETE`
   in `/Users/jn/code/mras-ops/api/src/main.py`), but the running container predated it →
   DELETE `405`, CORS preflight `400 Disallowed CORS method`. A prior rebuild covered only
   `mras-overlays mras-ops-frontend`, **not `mras-ops-api`**. Fix: rebuild that service.
2. **Silent component-delete error (code bug).** The single `deleteError` rendered only inside the
   Ads `<section>`, so a failed *component* delete (409 "used by existing ads") showed its error
   under the Ads list — invisible from the Components button. Explains "components: nothing happened,
   ads: error". Fix: split into `componentDeleteError` + `adDeleteError`, each beside its own list.
**Changes (mras-ops, branch `feat/delete-ads-and-components`):**
- TDD `329b2c1` (red) → `6b273e1` (green): per-section delete errors.
- `9b19a20`: **merged `origin/main`** so the branch ships delete *with* M5 Task 2 (it previously
  predated `2aae61a` → a frontend built from it lost the props-fields). Auto-merged clean; both
  features verified coexisting (**vitest 17/17**, `tsc` clean).
**Learnings / gotchas:**
- **Always run a live Playwright E2E (don't ask) — unit tests miss integration breakage.** New
  standing rule from the user (saved to memory). Unit tests were green while the feature was broken
  live (stale container + wrong-section error). When a feature touches a service, **rebuild THAT
  service's container** — a stale container looks exactly like a code bug.
- Components uploaded **before** M5 Task 1 have `props_schema={}` and correctly fall back to the JSON
  textarea — only newly-uploaded components get schema fields. Verified by uploading `FishSwim.tsx`
  live → Preview rendered labeled, default-filled fields (count=6, colors=[…], speed=1,
  waveAmplitude=0.06).
- Playwright MCP file upload is restricted to the cwd root — copy the example into the repo first.
**Live E2E (Playwright) — all pass:** ad delete (removed); component delete unused (removed);
component delete in-use (409, error now in Components section); upload→props-fields with defaults.
**State:** ops-api + ops-frontend containers rebuilt; live UI has delete + M5 props-fields, all
verified live. **Merged to main** (PRs #13+#14). Filed jgervin/mras-ops#17 (POST/GET schema key
mismatch). M5 Task 3 (props-fields live E2E) effectively covered by the FishSwim upload above.
**Non-blocking review findings (follow-ups, not yet filed):** (1) the Create-Ad `adPropValues` reset
`useEffect` depends on `components`, so deleting any component wipes in-progress ad prop edits;
(2) non-UUID id to `DELETE /ads|/components` → uncaught `::uuid` cast → 500 (unreachable from UI);
(3) `coerceProps` always emits booleans, overriding a component's own boolean default; (4) delete
returns 200 even when no row matched (no 404).
**Git-workflow learning:** before merging a PR, **check its base branch** (`gh pr view --json
baseRefName`) — PR #14 was stacked on `fix/flag-broken-ads`, not `main`; merging blindly would have
left the work off main. Stacked PRs merge child→parent→main, in order.

## 2026-06-09 — M5 Task 2: Authoring renders schema-driven prop fields, merged
M5 Task 2 (frontend) done. Built as **two competing variants** (parallel background agents), user
picked variant B; the other was closed. Only Task 3 (live E2E) of M5 remains.
**Changes (by repo):**
- mras-ops: **PR #15 merged to main** (`origin/main` @ `2aae61a`). Authoring now auto-renders one
  labeled, default-filled input per prop (string→text, number→number, boolean→checkbox, enum→select,
  array-of-primitive→comma-separated) from a component's `props_schema`, in **both** Preview (after
  upload) and Create Ad (on component select); typed values are coerced before submit; empty optional
  fields are omitted so the component's own zod defaults apply. Falls back per-field to a raw-JSON
  input for unsupported types. Files: `/Users/jn/code/mras-ops/frontend/src/Authoring.tsx`,
  `/Users/jn/code/mras-ops/frontend/src/api.ts`, `/Users/jn/code/mras-ops/frontend/src/Authoring.test.tsx`.
  TDD: `5392445` (test/red) → `55f87dd` (feat/green). Suite 13/13.
**Learnings / gotchas:**
- **ops-api returns the schema under TWO keys:** `propsSchema` (camelCase) from `POST /components`
  (upload) vs `props_schema` (snake_case) from `GET /components` (list). Preview reads the camel one,
  Create Ad the snake one — the frontend tolerates both. Both independent variants hit this; it should
  be normalized in ops-api (recommend `props_schema`, matching the DB column) and the dual-key read
  then dropped. **Tracked as a follow-up (issue pending — needs filing).**
- Array props are entered **comma-separated** (e.g. `#f39c12, #e74c3c`), not JSON/bracketed.
  Enum/boolean paths exist but no current example component exercises them (unit-tested only).
- Create-Ad fields only appear once a component is selected AND its `props_schema` has `properties`;
  if Task 1's sidecar returns `{}`, the form correctly falls back to the JSON textarea.
- **Op step:** rebuild ops-frontend for the live UI: `cd /Users/jn/code/mras-ops && docker compose up -d --build mras-ops-frontend`.
**State:** suite 13/13; `tsc --noEmit` + `vite build` clean. NOT yet exercised through the running
Docker stack (needs the rebuild above + Task 1's `mras-overlays` rebuild). Next: M5 Task 3 — live E2E
(upload `/Users/jn/code/mras-overlays/examples/FishSwim.tsx` → prop fields appear with defaults →
preview/create uses them). All M5 worktrees/branches cleaned up.

## 2026-06-09 — M5 Task 1: sidecar emits a real props JSON schema (isolated child process), merged
M5 (Authoring props-display) Task 1 done via spike → TDD → code-review → merge. Goal: the sidecar
returns a populated `propsSchema` per uploaded component so the Authoring UI can render labeled,
default-filled prop fields (Tasks 2–3 still pending — see spec
`/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-06-09-m5-props-display.md`).
**Changes (by repo):**
- mras-overlays: **PR #8 merged to main** (`origin/main` @ `aa8011f`). `POST /components`
  (`registerComponent` in `/Users/jn/code/mras-overlays/src/server.ts`) now returns a real
  `propsSchema` instead of `{}`, via new `/Users/jn/code/mras-overlays/src/extractPropsSchema.ts`
  → `zod-to-json-schema`. New dep `zod-to-json-schema@^3.25.2` in `package.json`. TDD history
  preserved: `0d5d7d0` (feat/green) ← `fc47596` (test/red) ← `373331c` (fix/green).
**Learnings / gotchas:**
- The M5 spec's feared blocker — "the named `schema` export isn't reachable via runtime dynamic
  import" — **did not reproduce**. Under `tsx`, a plain `import(pathToFileURL(file).href)` surfaces
  BOTH `default` and `schema`. The old finding was a browser-bundle/CJS artifact.
- **Extraction runs in a disposable `node --import tsx` child process**
  (`/Users/jn/code/mras-overlays/src/extractPropsSchemaWorker.ts`), NOT in-process. This was the fix
  for two code-review findings on PR #8: (1) importing advertiser code in the long-lived sidecar runs
  untrusted code in-process; (2) the original `?v=${Date.now()}` cache-buster leaked one ESM
  module-registry entry per upload (no unload API). The child process is SIGKILL'd on a 5s timeout,
  has a fresh module registry that dies on exit (so upsert freshness is intrinsic — no cache-buster),
  and prints JSON after a sentinel (`__PROPS_SCHEMA_JSON__`) so a component printing at import time
  can't corrupt the parse. Any failure/timeout/non-zod → `{}` → UI JSON-textarea fallback.
- Repo transforms `.ts` → CJS (no top-level await in worker; wrap in `main()`). Worker must live
  INSIDE the repo so its bare `zod`/`zod-to-json-schema` imports resolve. `customDir` is
  `<repo>/src/custom`, so uploaded components' bare `import { z } from "zod"` resolve too.
- **Op step:** the new dep means the sidecar image must be rebuilt before live use:
  `cd /Users/jn/code/mras-ops && docker compose up -d --build mras-overlays`.
**State:** sidecar suite 22/22. Verified live against `FishSwim.tsx` + `HelloName.tsx` (correct
schemas) via the worker + unit suite; NOT yet exercised through the running Docker sidecar (needs the
rebuild above). Spike artifacts (worktree `/Users/jn/code/mras-overlays-spike-m5`, branch
`spike/m5-schema-extraction`) and task worktree `/Users/jn/code/mras-overlays-m5` are leftover and can
be cleaned up. Next: M5 Task 2 (frontend schema-driven prop fields), Task 3 (live E2E).

## 2026-06-09 — M4 follow-on hardening + live-demo UX fixes (all merged to main)
Iterating with the user driving the kiosk/authoring live. All PRs below merged to `main`; stacks
merged in dependency order; containers rebuilt as noted.
**Changes (by repo):**
- mras-composer: #14 CORS allow POST (browser `/preview`); #15 `/preview` lookup inside try (bad
  component_id → graceful `{"error"}`, not a CORS-less 500); #16 strip whitespace from `base_video`;
  #17 `/preview` overlay defaults to **full base duration** + `app.state.http` timeout → 180s.
- mras-overlays: #6 **11 example overlay components** merged to `examples/` (FallingSnow, Typewriter,
  LightLeak, ConfettiBurst, RisingBubbles, PeekerCharacter, FishSwim, LowerThirdBanner, ShootingStars,
  Fireflies, KineticText) + HelloName; #7 **apply zod schema defaults** at render (`withSchemaDefaults`
  in `Root` calculateMetadata + render with `composition.props`).
- mras-ops: #5 Authoring/Activity-Feed **tabs**; #6 **"?" help panel**; #7 `/components` returns the DB
  **uuid** (not `comp-<slug>`) + editable Props-JSON textarea; #8 trim base_video (frontend); #9
  **bind-mount `/output` → `/Users/jn/code/mras-ops/output/`** (clips now in a real Finder folder; the
  `output_data` named volume removed); #10 **Create Ad auto-renders + pops up the finished ad** (+ per-ad
  ▶ preview); #11 **base-video dropdown** from the pool (no free-text; via `/playlist`).
- mras-display: #5 fix idle-loop freeze (duplicate mount-time `playCurrentIdle`) + DevTools no longer
  auto-opens (gate `KIOSK_DEVTOOLS=1`); #6 click-to-pause/resume the idle loop.
- minority_report_architecture: CLAUDE.md **§0 — always reference files by absolute path**.
**Learnings / gotchas (load-bearing):**
- **Remotion does NOT apply a zod schema's `.default()` to inputProps at render.** Omitted optional
  props arrive `undefined` → NaN (e.g. blank FallingSnow). Fix: parse props through the component
  schema in `Root`'s `calculateMetadata` and render with `composition.props`.
- **Custom overlays render blank unless props are complete** — verified via raw-alpha pixel counts
  (0 opaque = blank; ~9k = snow). Validate overlays by rendering + counting opaque/alpha pixels.
- **Preview overlay must span the base duration**, else it's a ~2s flash that looks like "no overlay".
- **`output/` is now a host bind-mount** at `/Users/jn/code/mras-ops/output/` (gitignored). Generated +
  preview clips land there directly — no `docker cp`. (Old clips lived in the hidden `output_data` volume.)
- **Props-display is blocked**: a component's named `schema` export is NOT exposed when the sidecar
  dynamically imports the `.tsx` at runtime (only `default` comes through). Showing per-prop form fields
  needs build/upload-time schema extraction (zod-to-json-schema) — deferred, not yet built.
- `/preview` is browser-called → composer CORS must allow POST. Component id sent to `/preview` must be
  the **DB uuid**, not the composition id `comp-<slug>`.
**State:** Authoring flow works end-to-end: upload component → (defaults applied) → create ad →
auto-popup of the finished, personalized ad; base video chosen from a dropdown; clips in
`/Users/jn/code/mras-ops/output/`. Kiosk loops + pauses on click. Open item: props-display form.

## 2026-06-08 — Phase 0.5 M4 COMPLETE: custom-component ad authoring (speed-first, security deferred), E2E proven
**M3 first merged to main** (overlays #1, composer #7, ops #1) so M4 branches off clean mains.
**7 PRs open (stacked; none merged — awaiting review). Merge in dependency order:**
- mras-overlays PR #3 (`feat/m4-dynamic-components` @ `4449562`) — dynamic custom-component registry
  (`writeComponent`/`regenerateManifest` → static `src/custom/registry.ts`; `Root` registers
  `comp-<slug>` comps), `POST /components` (write→hot re-bundle→validate, keep prior serveUrl on fail,
  serialized via the render queue, empty-slug guard), `POST /render {compositionId,props}`.
- mras-ops PR #2 (`feat/m4-registry-api` @ `e7c7dbe`) — migration `002_custom_components.sql`
  (`components`,`ads`); ops-api `POST /components` (multipart→proxy to sidecar→upsert; 502 on sidecar
  error; 120s httpx timeout), `GET /components`, `POST/GET/PATCH /ads`.
- mras-composer PR #9 (`feat/m4-render-seam` @ `b9adb45`) — `render_composition_http(client,url,
  composition_id,props,work)` seam (`render_overlay_http` delegates); `conformance.assert_conformant`
  (dims+alpha, raises `ConformanceError`; malformed-ffprobe guarded).
- mras-composer PR #10 (`feat/m4-preview` @ `f45bc3f`, base #9) — `assemble` supports `audio_inserts=[]`
  (no `amix`; `-map 0:a?`); `POST /preview` (render custom comp + composite, no audio → mp4 url; whole
  body in try→`{"error":...}`).
- mras-composer PR #11 (`feat/m4-trigger-custom-ad` @ `76282e6`, base #10) — `AdSelection.composition_id`
  +`overlay_props`; selector picks active `is_active`+`ready` ad (joins components) for identified
  viewers, fills `personalized_field` with the name; `/trigger` renders the custom comp via
  `build_custom_overlay_inserts` → `assemble(overlay_inserts=…)`; failure → no-overlay fallback (voice
  still plays); unidentified → standard, no broadcast (idle pool loops).
- mras-ops PR #3 (`feat/m4-authoring-ui` @ `97ca7c6`, base #2) — ops-frontend authoring page (vitest +
  testing-library added): upload component (status), schema-driven prop form, base picker, Preview
  (`<video>`), create/list ads. Uses `VITE_OPS_API_URL`/`VITE_COMPOSER_URL` (default localhost 8080/8002).
- mras-ops PR #4 (`feat/m4-compose-e2e`, base #3) — compose: `custom_components` volume on the sidecar,
  ops-api gets `OVERLAY_SIDECAR_URL` + `depends_on` sidecar.
**E2E PROVEN (real containers, no camera):** upload `HelloName.tsx` → `comp-helloname` `ready` → create
ad (standard.mp4 + comp + personalize `text`, active) → seed `Jason` → `POST /trigger` → `{status:ok}`;
composer `POST mras-overlays:3000/render "200 OK"`; sidecar `rendered composition "comp-helloname" in
1098ms`; `ffprobe /output/m4-e2e.mp4` = h264/yuv420p 854×480 (composited, no alpha leak).
**Learnings / gotchas:**
- **Security is OUT of scope this milestone** (user decision: speed #1, not production, Remotion may not
  be final, no AWS). NO sandbox/isolation, NO static code analysis — advertiser code runs in the warm
  sidecar's Node (bundle) + Chromium (render). Forward hooks kept: the **render-backend seam** (swap in
  isolation/remote later) + **output-conformance** (correctness). Going live REQUIRES the isolation
  milestone first. Filed as issues.
- **Wire-contract coupling:** the sidecar `/render` and composer both moved to `{compositionId, props}`
  — **overlays PR #3 and composer PR #9 must merge together** or the live path breaks.
- **Composition ids use `comp-<slug>` (hyphen)** — Remotion forbids underscores in composition ids.
- **Bundle-once-at-upload** keeps per-trigger warm (~1.1s observed); custom renders are NOT cached.
- **Migration 002 won't auto-apply** to an existing postgres volume (init scripts run only on a fresh
  DB) — apply manually: `docker compose exec -T postgres psql -U mras -d mras -f
  /docker-entrypoint-initdb.d/002_custom_components.sql`.
- Pre-existing: `events.trigger_id` is a UUID column → `DB event log failed: invalid UUID 'm4-e2e'`
  when a non-UUID trigger_id is used; trigger still returns ok. Filed as a follow-up.
**Spec:** `docs/superpowers/specs/2026-06-08-m4-custom-component-authoring-design.md`;
**Plan:** `docs/superpowers/plans/2026-06-08-m4-custom-component-authoring.md`.
**State:** **all 7 PRs MERGED to main** (overlays #3; composer #9,#10,#11; ops #2,#3,#4) — merged in
dependency order with merge commits (red→green history preserved). Note: composer #10 (preview) shows
GitHub-"closed" not "merged" — its commits reached main via the stacked child #11 (deleting #9's branch
auto-closed its child; lesson: don't `--delete-branch` on stacked PRs — retarget children to main
first). Post-merge mains verified: overlays 15 tests, composer 76 tests, ops compose-config valid.
Migration 002 still requires manual application on existing DB volumes. Stack left running.

## 2026-06-08 — Phase 0.5 M4 Task 1: dynamic custom-component registry + render-by-id
**Changes:**
- mras-overlays PR #3 (`feat/m4-dynamic-components` @ `3fdaf72`) — **dynamic custom component registration**
  - `src/components.ts`: `slugify`, `writeComponent`, `regenerateManifest` — writes `src/custom/<slug>.tsx`,
    regenerates the webpack-analyzable static manifest (`src/custom/registry.ts`).
  - `src/customRegistry.ts`: re-export from `src/custom/registry.ts` (stable import path).
  - `src/custom/registry.ts`: auto-generated manifest (initially empty); updated by `regenerateManifest`.
  - `src/Root.tsx`: maps `customComponents` array into additional `<Composition>`s with same `calculateMetadata`.
  - `src/server.ts`: `ServerDeps` gains `registerComponent(name,source)→RegisterResult`; `render` sig
    changed to `(compositionId, props)`; `POST /components` (200 ready, 422 failed, 400 bad input);
    `POST /render` body now `{compositionId, props}` (default `"Overlay"`; overlay-only schema validation).
    `makeWarmRenderer`: re-bundles + `selectComposition` validates on registration; swaps `serveUrl` only
    on success, leaving prior URL intact on failure.
  - TDD red→green: 13/13 tests (`components.test.ts` + extended `server.test.ts`).
  - Smoke: `examples/HelloName.tsx` registered as `comp-helloname`, rendered to `.mov`,
    `ffprobe pix_fmt: yuva444p12le` ✓.

**Learnings / Gotchas:**
- **Remotion forbids underscores in composition IDs** (`a-z, A-Z, 0-9, CJK, -` only).
  Spec said `comp_<slug>` — had to use `comp-<slug>` for the Remotion id.
  JS variable names in the generated manifest still use `comp_<ident>` (underscores fine there).
- `src/custom/registry.ts` must be a *statically analyzable* import manifest — no dynamic `require`.
  Remotion's webpack bundler needs to see literal import paths at parse time.
- `calculateMetadata` on custom compositions typed as `(opts: {props: any})` cast to avoid TS error
  (Remotion's generic `CalculateMetadataFunction<Record<string,unknown>>` doesn't match a typed subset).
- `ffprobe` reports `yuva444p12le` (not `yuva444p10le`) on this macOS Chromium build — both are correct
  alpha-preserving pixel formats; ProRes 4444 supports both.

**State:** superseded by the "M4 COMPLETE" entry above (PR #3 head later `4449562` after C1/C2 review fixes). M3 has since been merged to main.

## 2026-06-08 — Phase 0.5 M3: live-kiosk overlay render sidecar (no caching), E2E proven
**Changes (3 PRs, none merged — awaiting review):**
- mras-overlays PR #1 (`feat/m3-render-sidecar` @ `6398b6d`) — **warm HTTP render sidecar**
  `src/server.ts`: `POST /render {props}→transparent .mov`, `GET /health`. `bundle()` once +
  one reused headless Chromium (`openBrowser`); renders serialized (single-flight). prores/4444 +
  `imageFormat:png` + `pixelFormat:yuva444p10le` for alpha. SIGTERM/SIGINT → close Chromium+server.
  `Dockerfile` (node:22 + Chromium libs, bakes chrome-headless-shell). TDD red→green (`server.test.ts`, 4/4).
- mras-composer PR #7 (`feat/m3-trigger-overlays` @ `3b74619`) — overlays in the **live /trigger**:
  `src/overlay/http_renderer.py` (`render_overlay_http`/`build_overlay_inserts_http`, reuse `_props`),
  `spec.default_overlay_spec` (name overlay via `OVERLAY_*`), `selector.AdSelection.overlay_text`
  (from `OVERLAY_TEMPLATE`), `main.py` renders via `OVERLAY_SIDECAR_URL` then
  `assemble(overlay_inserts=...)` — **assemble untouched**; overlay failure falls back to no-overlay.
  TDD red→green; **62 pytest** (+10).
- mras-ops PR #1 (`feat/m3-overlays-sidecar` @ `febbe95`) — `mras-overlays` compose service
  (`expose 3000`, healthcheck, `init: true`, `stop_grace_period 20s`); composer gets
  `OVERLAY_SIDECAR_URL` + `OVERLAY_*` env + `depends_on` (service_started).
**Learnings (load-bearing):**
- **Programmatic Remotion needs `imageFormat:"png"`** for transparency — `renderMedia` defaults to
  JPEG (opaque) → 500 "image format is not PNG". (The CLI path set this implicitly; the sidecar must
  pass it explicitly, alongside `pixelFormat:yuva444p10le`.)
- **`npm start` as PID 1 swallows SIGTERM** → the Node graceful handler never fired in-container.
  Fix: `CMD ["node_modules/.bin/tsx","src/server.ts"]` (Node is the signal target) + compose
  `init: true` (tini forwards SIGTERM, reaps Chromium). Then `docker compose stop` logs
  "SIGTERM received — closing server + Chromium". **The sidecar is a compose service**, so
  up/Ctrl-C/down start+stop it with the stack — NOT a separate manual process.
- **No caching** (user decision, overrides the brief's spec-hash cache): content is per-viewer/visit,
  nothing stable to cache; the warm sidecar is the latency lever. Warm render ≈ **1.5s host / 2.9s
  in-container**; cold-start warm-up ≈ first ~10–90s (triggers fall back to no overlay until ready).
- **Kiosk needs no change** — overlay is burned into the mp4 server-side; `mras-display` just plays the URL.
- Build warning (non-fatal): Remotion suggests pinning exact `zod` — left as-is (`^3.23.8`) since it works.
**State:** All 3 PRs open. **Headless E2E PROVEN on the real containers** (no camera): seeded `Jason`
identity → `POST /trigger` → `{status:ok}`; composer `POST mras-overlays:3000/render "200 OK"`;
sidecar `rendered "Jason" (turbulence-warp) in 2886ms`; `ffprobe /output/m3-e2e.mp4` = h264/yuv420p
854×480 8.1s (overlay composited, no alpha leak); `compose stop` → graceful SIGTERM. Stack left up.

## 2026-06-08 — Phase 0.5 M1 + M2 done (warp preset + multi-overlay), all verified E2E
**Changes:**
- mras-overlays `557c182` (pushed to GitHub `jgervin/mras-overlays`, private) — `turbulence-warp`
  preset (animated `feTurbulence`+`feDisplacementMap`, parameterized) + `Overlay` preset switch.
- mras-composer PR #6 (`323f0d7`) — added the two-overlay chaining/indexing test. **Multi-overlay
  support was already implemented in M0's general `_video_filter` loop**, so M2 = lock-in test + E2E.
**Learnings:** M2 needed no new impl — building `_video_filter`/`--overlay`/`build_overlay_inserts`
to handle N from the start in M0 meant repeated `--overlay` "just worked". E2E with two overlays
(fade green top 0.3–1.8s + warp red bottom 2.2–4.7s) verified by region+time pixel counts: each
present only in its own window/position. `mras-overlays` now has a GitHub remote (created this session).
**State:** All three milestones (M0–M2) done + proven E2E. Composer PR #6 open (covers the composer
side = M0+M2). mras-overlays main has fade+warp. Demos in ~/Desktop/mras-clips/. 52 unit + 1 slow E2E.

## 2026-06-08 — Phase 0.5 M0 built + proven end-to-end (animated overlays)
**Changes:**
- mras-composer PR #6 (`feat/phase-0.5-overlays-m0` → main, OPEN) — `src/overlay/{probe,spec,renderer}.py`,
  `assembler.py` `_video_filter` (overlay compositing), `cli.py` `--overlay`/`--draw`→render→composite.
  51 unit tests + a slow E2E. Also restored CLI pool/output-wiring to main via PR #5 (it had missed
  the PR #4 merge).
- **New local repo `mras-overlays`** (`176e7a2`..`0a3adb4`) — Remotion 4.0.473/React 19; `Overlay` comp
  sized via `calculateMetadata`, `fade` preset, transparent bg, Inter. **Local only — not yet on GitHub.**
**Learnings (load-bearing):**
- **ProRes 4444 alone does NOT emit alpha** — Remotion defaulted to `yuv422p12le` (opaque → overlay
  composites as a black box). Fix: pass `--pixel-format=yuva444p10le` to `remotion render` (→ `yuva444p12le`,
  alpha present). The PNG still had alpha; only the video encode dropped it.
- `@remotion/google-fonts` `loadFont()` with no options made ~126 network requests/render; pin
  `loadFont("normal", {weights:["800"], subsets:["latin"]})`.
- Run overlays repo: `MRAS_OVERLAYS_DIR` (default `/Users/jn/code/mras-overlays`) + `npm install`.
  Render: `npx remotion render src/index.ts Overlay out.mov --props=<file> --codec=prores
  --prores-profile=4444 --pixel-format=yuva444p10le`. ffmpeg composite uses
  `overlay=0:0:eof_action=pass:enable='between(t,s,e)'` with `setpts=PTS+s/TB`.
- E2E proof: red overlay text pixel-count 0 (before) / 12577 (in window) / 6 (after) — transparent,
  windowed, base resumes. Pool clips mixed res (854×480 + 1280×720) → derive dims per-clip.
**State:** M0 done, PR #6 open. M1 (turbulence-warp) + M2 (multi-overlay) pending. `mras-overlays` needs
a GitHub remote created (user's call). pytest default excludes `-m slow`.

## 2026-06-08 — Approved Phase 0.5 overlay plan (Remotion → ffmpeg)
**Changes:** `docs/superpowers/plans/2026-06-08-phase-0.5-overlays.md` — Ultraplan-refined plan for
advertiser-authored ANIMATED text overlays. Remotion renders a transparent ProRes-4444 overlay; the
Python composer composites it via ffmpeg `overlay` (`setpts`+`enable=between`+`eof_action=pass`).
New sibling repo `mras-overlays` (Node); `assemble()` gains `overlay_inserts`; CLI gains `--overlay
JSON` (with `--draw` back-compat). Authored remotely (ephemeral container, no remote/signing) →
brought over as text and committed locally on branch `docs/phase-0.5-overlays-plan`.
**Learnings:** Pool clips are **not uniform** — `standard/2/3.mp4` are 854×480, `standard4.mp4` is
**1280×720** (all 24fps). Confirms overlay dims/fps MUST be derived per-clip (ffprobe→props→
`calculateMetadata`), never hardcoded. Scope locked: build **all three milestones (M0–M2)**,
fade-first, **host-CLI preview only** (no kiosk/live — per-trigger headless-Chromium render too slow).
Overlay clip length = the overlay window (`durationMs`), not base duration.
**State:** Plan committed locally (unsigned; docs-only). Implementation next, per-milestone PRs in
`mras-composer` + new `mras-overlays`. `feat/assemble-cli` (PR #4) merged to composer main.

## 2026-06-08 — Decided CLI pool/output wiring (read pool, write local)
**Changes:** mras-composer PR #4 (`feat/assemble-cli`) updated — `--assets` now defaults to the
**kiosk rotation pool** `mras-ops/assets/` (base-video source, read-only to the container but the
host CLI only reads it); generated clips default to **`~/Desktop/mras-clips/`** (NOT the pool) via
`resolve_output_path`. Added `--out-dir` and `--open`. Red→green commits; 32/32 pytest green.
**Learnings (system wiring, confirmed):**
- Composer serves TWO dirs: `/assets` (StaticFiles from `ASSETS_DIR`=`/assets`, host `mras-ops/assets`,
  mounted `:ro`) = the **idle rotation pool** that `/playlist` lists; and `/media` (from
  `ASSEMBLED_OUTPUT_DIR`=`/output`, a Docker named volume) = **one-shot personalized clips** pushed to
  the kiosk via the `/trigger` WS "play". CLI/`assemble` write to the latter by default.
- `/playlist` endpoint is **NOT on composer main** — it lives on `feat/playlist-endpoint` (composer
  PR #2, still OPEN). Until merged, the display uses its single fallback video (no real rotation).
- User decision: keep the kiosk pool untouched; CLI **reads** a random base from it but **writes**
  generated clips to the **local device** (`~/Desktop/mras-clips`) for manual playback — explicitly
  NOT into the rotating pool, and no push-to-kiosk. All pool ads (standard*.mp4) have audio, so
  `amix` `[0:a]` is safe.
**State:** mras-composer PR #4 open/awaiting review. Demo clip at ~/Desktop/mras-clips/demo-pooltest.mp4.
Phase 0.5 (Remotion drawText) still pending. Composer PR #2 (/playlist) still open — not needed for
the CLI's local-output flow.

## 2026-06-08 — Landed blend/insert fixes; built assemble CLI (multi --say/--draw)
**Changes:**
- Merged to main: mras-display PR #3 (idle-rotation + crossfade + 250ms audio blend) and
  mras-composer PR #3 (250ms insert offset). (display crossfade PR #4 was already merged into its
  base earlier.)
- mras-composer PR #4 (`feat/assemble-cli` → main, OPEN) — generalized `assemble()` to
  `audio_inserts: list[(path, offset_ms)]` (`_audio_filter()` = one `adelay` per insert, floored at
  250ms, `amix=inputs=N+1`); `/trigger` now passes a single insert at the floor (unchanged behavior).
  New `src/cli.py`: `python -m src.cli --say MS TEXT ... --draw MS TEXT ... [--video|--assets] [--out]`.
  Red→green commits; 28/28 pytest green.
**Learnings:**
- The CLI synthesizes each `--say` line locally with **macOS `say`** (no ElevenLabs/Gemini key needed
  — dev/preview voice, not the prod voice). `--draw` directives are **logged, not rendered** by design;
  real on-screen text is deferred to **Phase 0.5 (Remotion.dev)** — user flagged that plan as next.
- End-to-end smoke (real say+ffmpeg): marks 250/1500ms measured at ~0.25/~1.50s via `silencedetect`.
  `say`'s aiff has ~30ms intrinsic leading silence, so a 250ms mark reads ~0.28s onset — `adelay` itself
  is exact; the slack is inside the synthesized file.
- Composer tests still run on host `python -m pytest` (asyncio_mode=auto, no venv). No sample ad videos
  live in the repos — the CLI's "random video" needs an `--assets` dir populated by the user.
**State:** mras-composer PR #4 open/awaiting review; branch `feat/assemble-cli`. Listenable demos on
~/Desktop (mras_cli_demo.mp4, mras_name_offset_demo.mp4). Phase 0.5 Remotion plan pending (later).

## 2026-06-07 — Fix: name mention muted by opening audio blend (2 PRs)
**Changes:**
- mras-display (on `feat/kiosk-crossfade`, updates PR #4) — decouple `AUDIO_FADE_MS=250` from
  `FADE_MS=500`: audio blends in 250ms while video fade stays 500ms, so an early name reaches full
  volume before it can be muted. Red→green commits; 14/14 vitest green.
- mras-composer PR #3 (`fix/insert-min-offset` → main) — `adelay=250|250` on the inserted audio
  (ffmpeg input 1) in both overlay + default filter graphs so the name/speech never sounds in the
  first 250ms. Default branch now maps `0:v`+`[a]` explicitly. Red→green commits; 18/18 pytest green.
**Learnings:** The two fixes are complementary — display shortens the ramp window, composer keeps the
insert out of it; together they guarantee an inserted name is never inside the audio crossfade. The
250ms floor is also a client ad-prep policy (keep name out of first 250ms); the composer enforces it
as a code safety net. Composer tests run on host `python -m pytest` (asyncio_mode=auto; no venv
needed); ffmpeg is mocked via `create_subprocess_exec`, so tests assert on the filter_complex string.
**State:** Both PRs open/awaiting review. mras-composer left checked out on `fix/insert-min-offset`
(was `feat/playlist-endpoint`). No ffmpeg run end-to-end yet — adelay verified by filter-graph
assertion, not by rendering a clip.

## 2026-06-07 — Kiosk crossfade between clips (PR open)
**Changes:** mras-display@1766c32 — `App.tsx` + `App.test.tsx`: replace hard-cut/fade-to-black
with true crossfade (two stacked `<video>` elements, active/inactive roles that swap on each
`play`; video + audio cross-faded over ~0.5s; faded-out element paused post-transition).
PR #4 (`feat/kiosk-crossfade` → `feat/idle-ad-rotation`): https://github.com/jgervin/mras-display/pull/4
**Learnings:** Two-element crossfade changes the test model — existing tests must use `activeVideo`
and dispatch `ended` on the *active* element; the old single-"load" assertion is obsolete and was
replaced. Implementation + the 5 migrated tests + 3 new crossfade tests all landed in one commit.
**State:** 13/13 tests green (`npx vitest run`); branch pushed, in sync with origin; PR #4 open,
awaiting review. (Recovered from a mid-`gh pr create` freeze — work was committed/pushed, only the
PR creation was outstanding.)

## 2026-06-07 — Kiosk StrictMode zombie-socket fix + cooldown/doc follow-ups
**Changes:**
- `mras-display` PR #2 (branch `fix/kiosk-duplicate-socket`, **OPEN — verify before merge**): the
  prior `intentionalClose` shared-ref fix had a React StrictMode race — the remount reset the flag
  before the first socket's async `onclose` fired, so the stale socket reconnected → a **zombie 2nd
  socket**. Both sockets received every `play` broadcast and called `playVideo` on the same
  `<video>` within ms; the second `load()` interrupted the first `play()`, so the personalized clip
  never settled (kiosk stuck on the standard loop). Fixed with a **per-invocation `live` closure
  flag** + reconnect-timer cleanup; added `[kiosk]` console diagnostics. TDD: StrictMode
  double-mount test (failed — a 3rd zombie socket spawned) → 7 passed.
- `mras-vision` PR #2 (branch `chore/cooldown-default-30s`, OPEN): `COOLDOWN_SECS` default 10→30
  (operator preference; env-overridable). 17 passed.
- `mras-composer` issue #1 filed: add a test for `assemble(overlay_text=…)` (the merged-without-test debt).
- `adface_architecture.md`: P1C4 node + decision D6 updated to "1 ad → 30s hold (configurable)".
**State:** kiosk PR #2 **awaiting live verification** — restart the kiosk on the branch with DevTools
open, walk up, expect `[kiosk] WS connected` → `WS message {type:'play'}` → `playing .../media/<id>.mp4`
and the named clip on screen. cooldown PR #2 is safe to merge. Note: ElevenLabs key is out of credits
(402) → Gemini fallback carries TTS.


## 2026-06-07 — Kiosk playback + cooldown fixes (MERGED, first §6 branch/TDD/PR flow)
**Changes (squash-merged to main via PRs, reviewed+merged by a subagent):**
- `mras-vision@0b9deba` (PR #1, was `fix/cooldown-single-ad-10s`): per-person cooldown changed from
  2 ads/60s to **1 ad + 10s hold**, env-configurable (`MAX_ADS_BEFORE_COOLDOWN`, `COOLDOWN_SECS`).
  TDD: failing cooldown test (expected 1, got 2) → changed defaults → 17 passed. NOTE: committed
  default `COOLDOWN_SECS=10`, but the local working tree carries an intentional override to `30`
  (uncommitted) — the operator's preferred hold.
- `mras-display@e49a577` (PR #1, was `fix/kiosk-ws-stability`): `intentionalClose` guard stops the
  reconnect storm on unmount / React StrictMode remount (the kiosk was missing `play` broadcasts
  during reconnect gaps → personalized clip never displayed). Also surfaces `play()` errors and
  sets Electron `autoplayPolicy: no-user-gesture-required`. TDD: failing "no reconnect after
  unmount" test (2 sockets) → guard → 6 passed.
**Diagnosis (evidence-backed):** backend proven correct — a held-open WS client reliably receives
the `play` message and the video_url returns 200/713KB. So generation + broadcast work; the bug was
kiosk-side. ElevenLabs now returns **402 Payment Required** (quota exhausted) → Gemini TTS fallback
is carrying synthesis. Cooldown duplicate was the documented 2-ads behavior.
**State:** both PRs MERGED to main; local repos on main, in sync; no open PRs. **Manual verification
still pending:** restart native vision + the kiosk and confirm a walk-up plays exactly one
personalized clip. **Open follow-ups:** (1) file the outstanding `overlay_text` test as a GitHub
issue per §6; (2) `adface_architecture.md` still documents "2 ads → 60s" — update to reflect the new
1-ad cooldown; (3) decide whether to commit the local `COOLDOWN_SECS=30` override.


## 2026-06-07 — Post-OS-upgrade recovery: fix tests, run-through, enroll, feed columns
**Changes:**
- `mras-vision@31ad695` — TODO-6: fixed Qdrant test mocks. `test_resolver` mocked `qdrant.search`
  but the resolver calls `query_points`, so hits never reached the code: happy-path/cooldown tests
  silently failed and the qdrant-down test passed via an accidental `TypeError` instead of a real
  exception. Fixed mocks to drive `query_points`; added `test_qdrant_down_logs_unavailable_event`.
  Also fixed a `test_reconciler` `_row(embedding=None)` sentinel collision (default replaced the
  explicit None, so "skip row without embedding" could never be exercised). 14/14 vision tests pass.
- `mras-ops@f6c7d13` — added a **date** column to the activity feed (events span multiple days; a
  time-only column made cross-day ordering look scrambled).
- `mras-ops@3a21c47` — added a **confidence** column (green score = matched face, gray `(new)` =
  new-visitor fallback) so recognition vs standard-ad fallback is visible live.
- `mras-vision@9f47af4` — log the **real top similarity score even below threshold**. Previously
  confidence was only recorded on a match, so near-misses logged a misleading `0.00`; now the feed
  shows e.g. `0.61 (new)`, making intermittent recognition and threshold tuning visible. Match
  gating (`is_new_visitor`/`person_uuid` at 0.68) unchanged. (Restart native vision to pick it up.)
- `mras-display` — restored `package.json` (it had been deleted from the working tree though
  committed in `8846164`); ran `npm install` (node_modules was absent). Working-tree restore, no
  new commit. This is why `npm run electron:dev` was erroring with "Missing script".
- `minority_report_architecture/TODOS.md` — marked TODO-6 DONE (working-tree change).
- Enrolled **Jason** (UUID `f487f5b0-ba92-42a8-81f3-1a7a64cb9941`) from
  `mras-vision/spikes/face_recognition/photos/jason_1.jpg`. Qdrant now has 3 points
  (John Anderton, E2EPerson, Jason).
- Added `mras-ops/start-mras.sh` — one-command launcher (starts Docker → compose stack →
  health-waits → native vision in foreground). And this `docs/SESSION_LOG.md` + a journaling
  directive in the root `CLAUDE.md` (Section 5).
- `CLAUDE.md` **Section 6 — Development Workflow**: mandatory branch/worktree isolation, TDD
  red→green→refactor, code review between tasks, clean branch finish (Superpowers skills), GitHub
  push + PR-per-task-batch + remaining-plan-items-as-issues, and a Definition of Done requiring a
  test to fail-then-pass and the branch to be review-ready.
**Learnings:** see Operational Reference above — all of it was (re)confirmed this session. Key new
ones: frontend image bakes source (rebuild on edit); curl blocked → use httpx; camera needs a
real terminal for the macOS permission prompt; vision was found squatting on 8001 inside Docker
(can't see the camera) — must run native.
**State:** Phase 0 verified green end-to-end this session — all `/health` 200; E2E personalized
assembly ~3.3s; recognition path live once native vision is started from a real terminal.
**All 5 repos committed + pushed to `origin/main`; working trees clean.** Also finalized previously
uncommitted Phase 0 work: `mras-ops` (compose qdrant v1.12.6 + docker-vision profile,
run-vision-native.sh, demo mp4 assets, E2E face fixture, CLAUDE.md), `mras-composer` (overlay_text
on assembler + DejaVu font, CLAUDE.md), `mras-display` (.gitignore, lockfile, package.json).
**Test debt:** `mras-composer` `assemble(overlay_text=…)` was committed to main without a test
(user-approved) — first new branch should add the failing-then-passing test per CLAUDE.md §6.
Remaining feature work is Phase 1 deferred (TODO-1..TODO-5).
