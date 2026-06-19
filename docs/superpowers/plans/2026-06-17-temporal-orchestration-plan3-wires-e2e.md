# Temporal Orchestration — Plan 3: Edge Wires + Live E2E Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect the orchestrator's two edges and prove the whole feature live: `mras-vision` emits the presence stream to the composer, the `mras-display` kiosk emits `clip_ended` and honors the new `idle` message, and a live camera walk-up reproduces the spec's trace in the `events` table.

**Architecture:** Vision gets a `PresenceReporter` task (mirrors the existing `GazeLogger`) that POSTs the currently-present identified uuids to the composer `~1–2s`. The kiosk emits `clip_ended` over its existing WS when a *personalized* clip finishes and switches to idle on a `type:idle` message. Then a manual live E2E.

**Tech Stack:** Python 3.9 (vision venv), React/TypeScript + vitest (kiosk), Postgres SQL checks.

**Depends on:** Plan 2 (composer `/presence` + inbound `clip_ended` + `type:idle` send).
**Spec:** `/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-06-17-temporal-display-orchestration-design.md`

---

## File Structure

- Create `mras-vision/src/perception/presence.py` — `PresenceReporter`.
- Modify `mras-vision/main.py` — start the `PresenceReporter` task in `lifespan` (next to `gaze_task`).
- Create `mras-vision/tests/test_presence_reporter.py`.
- Modify `mras-display/src/App.tsx` — emit `clip_ended`; handle `type:idle`; don't auto-advance idle after a personalized clip.
- Modify `mras-display/src/__tests__/App.test.tsx` — kiosk wire tests.

---

### Task 1: Vision — PresenceReporter posts present identified uuids

**Files:**
- Create: `mras-vision/src/perception/presence.py`
- Test: `mras-vision/tests/test_presence_reporter.py`

**Design note:** Mirrors `GazeLogger` (`src/perception/gaze_log.py`): a periodic task over the live
`FaceTracker`. It collects `live_tracks()` whose `.uuid` is bound (identified) and POSTs
`{screen_id, present:[{uuid}]}` to the composer. Posts even when empty, so the composer has a steady
heartbeat (its TTL still expires people who vanish). Best-effort — a composer hiccup never crashes
vision.

- [ ] **Step 1: Write the failing test**

```python
# mras-vision/tests/test_presence_reporter.py
from unittest.mock import AsyncMock, Mock

from src.perception.presence import PresenceReporter


class _Track:
    def __init__(self, uuid):
        self.uuid = uuid


def _tracker(uuids):
    t = Mock()
    t.live_tracks = Mock(return_value=[_Track(u) for u in uuids])
    return t


async def test_report_posts_only_identified_tracks():
    http = AsyncMock()
    r = PresenceReporter(http, "http://composer:8002", "screen_0")
    await r.report(_tracker(["jason", None, "maria"]))  # None = unidentified track
    http.post.assert_awaited_once()
    url = http.post.call_args.args[0]
    body = http.post.call_args.kwargs["json"]
    assert url == "http://composer:8002/presence"
    assert body == {"screen_id": "screen_0",
                    "present": [{"uuid": "jason"}, {"uuid": "maria"}]}


async def test_report_swallows_post_errors():
    http = AsyncMock()
    http.post.side_effect = RuntimeError("composer down")
    r = PresenceReporter(http, "http://composer:8002", "screen_0")
    await r.report(_tracker(["jason"]))  # must not raise
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_presence_reporter.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'src.perception.presence'`

- [ ] **Step 3: Write minimal implementation**

```python
# mras-vision/src/perception/presence.py
from __future__ import annotations

import asyncio
import logging
import os

logger = logging.getLogger(__name__)
_INTERVAL_S = float(os.getenv("PRESENCE_REPORT_S", "1.5"))


class PresenceReporter:
    """Periodically POST the present identified uuids to the composer."""

    def __init__(self, http, composer_url: str, screen_id: str,
                 interval_s: float = _INTERVAL_S) -> None:
        self._http = http
        self._url = f"{composer_url.rstrip('/')}/presence"
        self._screen_id = screen_id
        self._interval = interval_s

    async def run(self, tracker) -> None:
        while True:
            await asyncio.sleep(self._interval)
            await self.report(tracker)

    async def report(self, tracker) -> None:
        present = [{"uuid": t.uuid} for t in tracker.live_tracks() if t.uuid]
        try:
            await self._http.post(
                self._url,
                json={"screen_id": self._screen_id, "present": present},
                timeout=2.0,
            )
        except Exception as exc:  # best-effort, like GazeLogger
            logger.warning("presence report failed: %s", exc)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest tests/test_presence_reporter.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/perception/presence.py tests/test_presence_reporter.py
git commit -m "feat(vision): PresenceReporter posts present identified uuids to composer"
```

---

### Task 2: Vision — start the PresenceReporter task in lifespan

**Files:**
- Modify: `mras-vision/main.py` (imports + `lifespan`)
- Test: none new (wiring; covered by the live E2E in Task 4)

- [ ] **Step 1: Add the import and task**

In `mras-vision/main.py`, add to the imports near `from src.perception.gaze_log import ...`:
```python
from src.perception.presence import PresenceReporter
```

In `lifespan`, alongside `gaze_task = asyncio.create_task(GazeLogger(db, _SCREEN_ID).run(tracker))`, add:
```python
    _COMPOSER_URL = os.getenv("COMPOSER_URL", "http://localhost:8002")
    presence_task = asyncio.create_task(
        PresenceReporter(http, _COMPOSER_URL, _SCREEN_ID).run(tracker)
    )
```
And in the shutdown block (after `yield`, next to `gaze_task.cancel()`), add:
```python
    presence_task.cancel()
```

- [ ] **Step 2: Verify the app still imports / starts**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -c "import main; print('ok')"`
Expected: prints `ok` (no import error).

- [ ] **Step 3: Run the full vision suite (no regressions)**

Run: `cd /Users/jn/code/mras-vision && .venv/bin/python -m pytest -q`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add main.py
git commit -m "feat(vision): start PresenceReporter task in lifespan"
```

---

### Task 3: Kiosk — emit clip_ended for personalized clips; handle type:idle

**Files:**
- Modify: `mras-display/src/App.tsx`
- Test: `mras-display/src/__tests__/App.test.tsx`

**Design note:** Track whether the current clip is a composer-driven *personalized* clip
(`personalizedRef`). On `type:play` set it true; on `type:idle` set it false and resume the idle
shuffle. In `handleEnded`: if the finished clip was personalized, send
`{type:"clip_ended", screen_id, clip_id}` over the WS and DO NOT auto-advance idle (the composer
sends the next `play`/`idle`); otherwise keep today's local idle advance. `screen_id` is read from
the query string (same as the WS connect).

- [ ] **Step 1: Write the failing test**

```tsx
// add to mras-display/src/__tests__/App.test.tsx
// (follow the file's existing WebSocket mock + render setup)
it('emits clip_ended over WS when a personalized clip finishes', async () => {
  const sent: string[] = []
  const sockets = mountAppWithMockWs((data: string) => sent.push(data)) // existing helper pattern
  // composer pushes a personalized clip
  sockets.lastServerSend(JSON.stringify({ type: 'play', video_url: 'http://c/media/x-0.mp4', person: 'jason' }))
  // the front video fires 'ended'
  fireVideoEnded() // existing helper that dispatches onEnded on the front <video>
  const msgs = sent.map((s) => JSON.parse(s))
  expect(msgs.some((m) => m.type === 'clip_ended')).toBe(true)
})

it('switches to idle shuffle on a type:idle message', async () => {
  const sockets = mountAppWithMockWs(() => {})
  const playSpy = spyOnPlayVideo() // existing helper / spy on HTMLMediaElement.play
  sockets.lastServerSend(JSON.stringify({ type: 'idle' }))
  expect(playSpy).toHaveBeenCalled()
})
```

If the test file lacks `mountAppWithMockWs` / `fireVideoEnded` helpers, add them following the
existing WebSocket-mock pattern already used in `App.test.tsx` (it mocks `global.WebSocket` and
renders `<App/>`). Keep the helpers minimal.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/mras-display && npm test -- App.test`
Expected: FAIL — no `clip_ended` is sent / idle message unhandled.

- [ ] **Step 3: Write minimal implementation**

In `mras-display/src/App.tsx`:

Add a ref near the other refs (around line 35):
```tsx
  const personalizedRef = useRef(false)
  const screenIdRef = useRef<string | null>(
    new URLSearchParams(window.location.search).get('screen_id')
  )
```

In `handleEnded` (line 144), before the existing `if (!inFallback.current) { ... }`:
```tsx
    if (personalizedRef.current) {
      personalizedRef.current = false
      const ws = wsRef.current
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({
          type: 'clip_ended',
          screen_id: screenIdRef.current,
          clip_id: frontEl()?.currentSrc,
        }))
      }
      return // composer decides what plays next (play/idle); don't auto-advance idle
    }
```

In `ws.onmessage` (line 198), set the flag on play and handle idle:
```tsx
        if (msg.type === 'play') {
          personalizedRef.current = true
          paused.current = false
          setDebugInfo({ person: msg.person, ad: msg.ad })
          playVideo(msg.video_url, false)
        } else if (msg.type === 'idle') {
          personalizedRef.current = false
          advanceIdle()
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/jn/code/mras-display && npm test -- App.test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/App.tsx src/__tests__/App.test.tsx
git commit -m "feat(kiosk): emit clip_ended for personalized clips; handle type:idle"
```

---

### Task 4: Live E2E walk-up verification

**Files:** none (manual verification per the project's mandatory live-camera rule).

**Pre-req:** Plans 1–3 merged or checked out across `mras-composer`, `mras-vision`, `mras-display`.
At least 2 enrolled identities (e.g. Jason + a second person, or re-enroll for two lighting
conditions). 4 displays.

- [ ] **Step 1: Start the stack** (your terminal, camera permission):
```
cd /Users/jn/code/mras-ops && PERCEPTION_DEBUG=1 ./start-mras.sh
```
Separate terminal — kiosk:
```
cd /Users/jn/code/mras-display && NODE_ENV=development npm run electron:dev
```

- [ ] **Step 2: Solo walk-up.** Stand in frame ~30s. Watch the 4 displays: expect one **opener**
  on all 4, then **round 2** (`A,A,B,B` — two distinct ads paired), then **idle shuffle** (no round 3).

- [ ] **Step 3: Verify the trace in `events`:**
```
docker exec mras-ops-postgres-1 psql -U mras -d mras -c "SELECT ts, event_type, status, payload FROM events WHERE ts > now() - interval '3 minutes' AND (event_type='playback' OR (event_type='composition' AND status='orchestrated')) ORDER BY ts;"
```
Expected: a `composition/orchestrated` row, then `playback` rows — an opener video on all 4
`display-N`, then two distinct round-2 videos paired across the displays.

- [ ] **Step 4: Two-person handoff.** Have a second enrolled person step in while you're mid-round.
  Expect the displays to even-split (2 each), newest person's opener appears at the next clip-ends
  (no mid-clip cut), then when one finishes/leaves the other reclaims displays. Confirm no display
  freezes and idle resumes when both are done.

- [ ] **Step 5: Record the result** in `docs/SESSION_LOG.md` (new dated entry) with the observed
  behavior and any `repo@sha`. If any step fails, capture the `events` rows and debug per
  `superpowers:systematic-debugging` before considering the feature done.

---

## Plan 3 self-review (run before handing off)

- [ ] Vision suite green (`.venv/bin/python -m pytest -q`), kiosk suite green (`npm test`).
- [ ] Confirm `PRESENCE_REPORT_S` (vision) and the composer's `PRESENCE_TICK_S` / TTL are compatible
  (TTL ≥ ~2× report interval) so a present person isn't expired between heartbeats.
- [ ] Live E2E (Task 4) observed and logged — this is the definition of done for the whole feature.
