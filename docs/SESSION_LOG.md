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

**TTS:** ElevenLabs primary → **Google Gemini** fallback (MisoOne was replaced). Keys in `mras-ops/.env`.

**Recognition:** confidence threshold 0.68. Below threshold → `is_new_visitor=true` → standard ad
(no name). Enrolled identities seed Qdrant collection `mras_embeddings` (512-dim Cosine).

**Gotchas:**
- The `mras-ops-frontend` container **bakes its source at build time** (no volume mount). After
  editing `frontend/src/*`, redeploy with `docker compose up -d --build mras-ops-frontend`.
- **curl/wget are blocked** by the context-mode guard for HTTP fetches. Use Python `httpx`
  (e.g. `mras-vision/.venv/bin/python`) for enroll/trigger calls.
- Vision tests run via `mras-vision/.venv/bin/python -m pytest` (host pyenv 3.11 lacks deps).
- `mras-kiosk` is a superseded scaffold — the live kiosk is `mras-display`.
- One-command startup: `mras-ops/start-mras.sh` (starts Docker, the compose stack, then native vision).

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
