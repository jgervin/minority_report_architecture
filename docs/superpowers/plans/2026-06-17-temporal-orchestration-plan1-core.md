# Temporal Orchestration — Plan 1: Orchestrator Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure decision engine for temporal display orchestration in `mras-composer` — a stateful but I/O-free `Orchestrator` that, given identification / presence / clip-ended events, emits commands (`Play`, `Idle`, `RenderAhead`) implementing the owner-approved 2-round-per-person program with even-split + newest-wins.

**Architecture:** A command-pattern core. The `Orchestrator` holds per-screen-group state (programs, presence-with-TTL, per-display state) and exposes sync event handlers that each return a list of immutable `Command`s. No FastAPI, no rendering, no WebSocket, no DB — those map commands to reality in Plan 2. This keeps every behavior a plain `assert returned_commands == [...]`.

**Tech Stack:** Python 3.11 (composer venv), pytest, dataclasses + enum. Pure sync (no asyncio in the core).

**Spec:** `/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-06-17-temporal-display-orchestration-design.md`

---

## File Structure

- Create `src/orchestrator/__init__.py` — package marker.
- Create `src/orchestrator/model.py` — `Round` enum, `next_round()`, `even_split()`, `pair_slot()` (pure assignment math).
- Create `src/orchestrator/commands.py` — `Play`, `Idle`, `RenderAhead` frozen dataclasses.
- Create `src/orchestrator/core.py` — `Orchestrator` class (state + event handlers).
- Create `tests/test_orchestrator_model.py` — tests for the pure math.
- Create `tests/test_orchestrator_core.py` — tests for the state machine.

All paths are relative to `/Users/jn/code/mras-composer`. Run tests with the composer venv:
`cd /Users/jn/code/mras-composer && python -m pytest <path> -v` (the repo's existing convention — see `tests/`).

---

### Task 1: Round enum + next_round

**Files:**
- Create: `src/orchestrator/__init__.py` (empty)
- Create: `src/orchestrator/model.py`
- Test: `tests/test_orchestrator_model.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_orchestrator_model.py
from src.orchestrator.model import Round, next_round


def test_next_round_advances_opener_to_round2_to_done():
    assert next_round(Round.OPENER) == Round.ROUND2
    assert next_round(Round.ROUND2) == Round.DONE
    assert next_round(Round.DONE) == Round.DONE  # terminal, never past done
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_orchestrator_model.py::test_next_round_advances_opener_to_round2_to_done -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'src.orchestrator'`

- [ ] **Step 3: Write minimal implementation**

```python
# src/orchestrator/__init__.py
```
```python
# src/orchestrator/model.py
from enum import IntEnum


class Round(IntEnum):
    OPENER = 0
    ROUND2 = 1
    DONE = 2


def next_round(r: Round) -> Round:
    """opener → round 2 → done (terminal). No round 3 — the cap is structural."""
    return Round.DONE if r >= Round.ROUND2 else Round(r + 1)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_orchestrator_model.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/orchestrator/__init__.py src/orchestrator/model.py tests/test_orchestrator_model.py
git commit -m "feat(orchestrator): Round enum + next_round (opener→round2→done)"
```

---

### Task 2: even_split (even share + newest-wins tiebreak)

**Files:**
- Modify: `src/orchestrator/model.py`
- Test: `tests/test_orchestrator_model.py`

- [ ] **Step 1: Write the failing test**

```python
# add to tests/test_orchestrator_model.py
from src.orchestrator.model import even_split  # noqa: E402


def test_even_split_solo_owns_all_displays():
    d = ["display-1", "display-2", "display-3", "display-4"]
    assert even_split(["jason"], d) == {dd: "jason" for dd in d}


def test_even_split_two_people_split_evenly_newest_first():
    d = ["display-1", "display-2", "display-3", "display-4"]
    # newest-first order: maria is newest
    assert even_split(["maria", "jason"], d) == {
        "display-1": "maria", "display-2": "maria",
        "display-3": "jason", "display-4": "jason",
    }


def test_even_split_remainder_goes_to_newest():
    d = ["display-1", "display-2", "display-3", "display-4"]
    # 3 active, 4 displays → newest gets the extra (2), others 1 each
    assert even_split(["c", "b", "a"], d) == {
        "display-1": "c", "display-2": "c",
        "display-3": "b", "display-4": "a",
    }


def test_even_split_more_people_than_displays_newest_win_one_each():
    d = ["display-1", "display-2"]
    assert even_split(["d", "c", "b", "a"], d) == {
        "display-1": "d", "display-2": "c",  # only the 2 newest are served
    }


def test_even_split_empty_active_is_empty():
    assert even_split([], ["display-1"]) == {}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_orchestrator_model.py -k even_split -v`
Expected: FAIL — `ImportError: cannot import name 'even_split'`

- [ ] **Step 3: Write minimal implementation**

```python
# add to src/orchestrator/model.py
def even_split(active_newest_first: list[str], displays: list[str]) -> dict[str, str]:
    """Map each display → owner uuid. Displays divide as evenly as possible
    among the active people; the newest people get any remainder, and when
    active people outnumber displays only the newest len(displays) are served
    (one display each)."""
    d, a = len(displays), len(active_newest_first)
    if a == 0 or d == 0:
        return {}
    base, rem = divmod(d, a)
    owners: list[str] = []
    for i, uuid in enumerate(active_newest_first):
        owners.extend([uuid] * (base + (1 if i < rem else 0)))
    return {displays[i]: owners[i] for i in range(min(d, len(owners)))}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_orchestrator_model.py -k even_split -v`
Expected: PASS (5 passed)

- [ ] **Step 5: Commit**

```bash
git add src/orchestrator/model.py tests/test_orchestrator_model.py
git commit -m "feat(orchestrator): even_split with newest-wins tiebreak"
```

---

### Task 3: pair_slot (round-2 A,A,B,B pairing)

**Files:**
- Modify: `src/orchestrator/model.py`
- Test: `tests/test_orchestrator_model.py`

- [ ] **Step 1: Write the failing test**

```python
# add to tests/test_orchestrator_model.py
from src.orchestrator.model import pair_slot  # noqa: E402


def test_pair_slot_four_displays_is_AABB():
    owned = ["display-1", "display-2", "display-3", "display-4"]
    assert [pair_slot(dd, owned) for dd in owned] == [0, 0, 1, 1]


def test_pair_slot_two_displays_is_AB():
    owned = ["display-1", "display-2"]
    assert [pair_slot(dd, owned) for dd in owned] == [0, 1]


def test_pair_slot_one_display_is_A():
    owned = ["display-1"]
    assert pair_slot("display-1", owned) == 0


def test_pair_slot_three_displays_is_AAB():
    owned = ["display-1", "display-2", "display-3"]
    assert [pair_slot(dd, owned) for dd in owned] == [0, 0, 1]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_orchestrator_model.py -k pair_slot -v`
Expected: FAIL — `ImportError: cannot import name 'pair_slot'`

- [ ] **Step 3: Write minimal implementation**

```python
# add to src/orchestrator/model.py
import math


def pair_slot(display: str, owned_displays: list[str]) -> int:
    """Round-2 pairing: split an owner's displays into two contiguous groups —
    the first ceil(n/2) show ad A (slot 0), the rest show ad B (slot 1).
    n=1→[0], n=2→[0,1], n=3→[0,0,1], n=4→[0,0,1,1]."""
    half = math.ceil(len(owned_displays) / 2)
    return 0 if owned_displays.index(display) < half else 1
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_orchestrator_model.py -k pair_slot -v`
Expected: PASS (4 passed)

- [ ] **Step 5: Commit**

```bash
git add src/orchestrator/model.py tests/test_orchestrator_model.py
git commit -m "feat(orchestrator): pair_slot for round-2 A,A,B,B pairing"
```

---

### Task 4: Command dataclasses

**Files:**
- Create: `src/orchestrator/commands.py`
- Test: `tests/test_orchestrator_core.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_orchestrator_core.py
from src.orchestrator.commands import Play, Idle, RenderAhead
from src.orchestrator.model import Round


def test_commands_are_value_equal_and_hashable():
    assert Play("display-1", "jason", Round.OPENER, 0) == Play("display-1", "jason", Round.OPENER, 0)
    assert Idle("display-2") == Idle("display-2")
    assert RenderAhead("jason", Round.ROUND2) == RenderAhead("jason", Round.ROUND2)
    # frozen → usable in sets
    assert len({Idle("display-1"), Idle("display-1")}) == 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_orchestrator_core.py::test_commands_are_value_equal_and_hashable -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'src.orchestrator.commands'`

- [ ] **Step 3: Write minimal implementation**

```python
# src/orchestrator/commands.py
from dataclasses import dataclass

from src.orchestrator.model import Round


@dataclass(frozen=True)
class Play:
    """Start the owner's current round on a display. pair_slot is 0/1 for the
    round-2 A/B pairing; ignored (always 0) for the opener."""
    display: str
    owner: str
    round: Round
    pair_slot: int


@dataclass(frozen=True)
class Idle:
    """Return a display to the standard idle shuffle."""
    display: str


@dataclass(frozen=True)
class RenderAhead:
    """Pre-render an owner's upcoming round while the current one plays."""
    owner: str
    round: Round
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_orchestrator_core.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/orchestrator/commands.py tests/test_orchestrator_core.py
git commit -m "feat(orchestrator): Play/Idle/RenderAhead command dataclasses"
```

---

### Task 5: Orchestrator.on_identify — solo opener on idle displays + render-ahead

**Files:**
- Create: `src/orchestrator/core.py`
- Test: `tests/test_orchestrator_core.py`

**Design note:** The `Orchestrator` is constructed with the display list and an injected `clock` (a `() -> float`). `on_identify(uuid)` registers a fresh program (or restarts a DONE one), marks the person present, and reassigns. Idle displays are free to start immediately (interrupting the standard shuffle is desirable for responsiveness); displays currently playing a personalized clip are never interrupted (handoff happens at `clip_ended`).

- [ ] **Step 1: Write the failing test**

```python
# add to tests/test_orchestrator_core.py
from src.orchestrator.core import Orchestrator


class _Clock:
    def __init__(self, t=0.0):
        self.t = t

    def __call__(self):
        return self.t


def _orch(displays=("display-1", "display-2", "display-3", "display-4")):
    return Orchestrator(list(displays), clock=_Clock(), presence_ttl_s=5.0)


def test_on_identify_starts_opener_on_all_idle_displays_and_renders_ahead():
    o = _orch()
    cmds = o.on_identify("jason")
    # opener (round OPENER, slot 0) on all four idle displays
    plays = [c for c in cmds if isinstance(c, Play)]
    assert plays == [
        Play("display-1", "jason", Round.OPENER, 0),
        Play("display-2", "jason", Round.OPENER, 0),
        Play("display-3", "jason", Round.OPENER, 0),
        Play("display-4", "jason", Round.OPENER, 0),
    ]
    # exactly one render-ahead for the round-2 pair
    assert RenderAhead("jason", Round.ROUND2) in cmds
    assert sum(isinstance(c, RenderAhead) for c in cmds) == 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_orchestrator_core.py::test_on_identify_starts_opener_on_all_idle_displays_and_renders_ahead -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'src.orchestrator.core'`

- [ ] **Step 3: Write minimal implementation**

```python
# src/orchestrator/core.py
import time
from dataclasses import dataclass

from src.orchestrator.commands import Idle, Play, RenderAhead
from src.orchestrator.model import Round, even_split, next_round, pair_slot


@dataclass
class _Program:
    uuid: str
    first_seen: float
    round: Round = Round.OPENER


@dataclass
class _Screen:
    owner: str | None = None
    round: Round | None = None
    playing: bool = False


class Orchestrator:
    def __init__(self, displays: list[str], clock=time.monotonic,
                 presence_ttl_s: float = 5.0) -> None:
        self._displays = list(displays)
        self._clock = clock
        self._ttl = presence_ttl_s
        self._programs: dict[str, _Program] = {}
        self._present: dict[str, float] = {}
        self._screens: dict[str, _Screen] = {d: _Screen() for d in self._displays}

    # ---- event handlers (each returns a list of Command) ----

    def on_identify(self, uuid: str) -> list:
        now = self._clock()
        prog = self._programs.get(uuid)
        if prog is None or prog.round == Round.DONE:
            self._programs[uuid] = _Program(uuid, first_seen=now)
        self._present[uuid] = now
        return self._reassign()

    # ---- internals ----

    def _active_newest_first(self) -> list[str]:
        active = [u for u, p in self._programs.items()
                  if p.round != Round.DONE and u in self._present]
        return sorted(active, key=lambda u: self._programs[u].first_seen, reverse=True)

    def _reassign(self) -> list:
        split = even_split(self._active_newest_first(), self._displays)
        owned: dict[str, list[str]] = {}
        for disp, owner in split.items():
            owned.setdefault(owner, []).append(disp)
        cmds: list = []
        render_ahead_owners: list[str] = []  # one render-ahead per owner, not per display
        for disp in self._displays:
            sc = self._screens[disp]
            if sc.playing:
                continue  # never interrupt a personalized clip mid-play
            new_owner = split.get(disp)
            if new_owner is None:
                if sc.owner is not None:
                    sc.owner, sc.round = None, None
                    cmds.append(Idle(disp))
                continue
            rnd = self._programs[new_owner].round
            slot = pair_slot(disp, sorted(owned[new_owner]))
            sc.owner, sc.round, sc.playing = new_owner, rnd, True
            cmds.append(Play(disp, new_owner, rnd, slot))
            if rnd == Round.OPENER and new_owner not in render_ahead_owners:
                render_ahead_owners.append(new_owner)
        cmds.extend(RenderAhead(o, Round.ROUND2) for o in render_ahead_owners)
        return cmds
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_orchestrator_core.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/orchestrator/core.py tests/test_orchestrator_core.py
git commit -m "feat(orchestrator): on_identify starts opener on idle displays + render-ahead"
```

---

### Task 6: on_clip_ended advances opener → round 2 (paired)

**Files:**
- Modify: `src/orchestrator/core.py`
- Test: `tests/test_orchestrator_core.py`

**Design note:** `on_clip_ended(display)` marks that display free, advances the owner's program **only if** this display was showing the owner's current round (so the first display to finish a round advances it; lagging displays don't double-advance), then reassigns. The freed displays then project the owner's (possibly advanced) current round.

- [ ] **Step 1: Write the failing test**

```python
# add to tests/test_orchestrator_core.py
def test_clip_ended_advances_to_round2_paired_AABB():
    o = _orch()
    o.on_identify("jason")  # opener on 1..4 (all now playing)
    # all four openers end (first one advances the program to round 2)
    cmds = []
    for d in ["display-1", "display-2", "display-3", "display-4"]:
        cmds = o.on_clip_ended(d)
    # after the last clip_ended, every display projects round 2, paired A,A,B,B
    plays = {c.display: c for c in cmds if isinstance(c, Play)}
    # the last-ended display (display-4) is reassigned in this call
    assert plays["display-4"] == Play("display-4", "jason", Round.ROUND2, 1)


def test_first_opener_end_advances_program_once():
    o = _orch(displays=("display-1", "display-2"))
    o.on_identify("jason")            # opener on 1,2
    cmds1 = o.on_clip_ended("display-1")  # first → advance to round 2, play round2 on d1
    assert Play("display-1", "jason", Round.ROUND2, 0) in cmds1
    cmds2 = o.on_clip_ended("display-2")  # second → program already round2, no double-advance
    assert Play("display-2", "jason", Round.ROUND2, 1) in cmds2
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_orchestrator_core.py -k clip_ended -v`
Expected: FAIL — `AttributeError: 'Orchestrator' object has no attribute 'on_clip_ended'`

- [ ] **Step 3: Write minimal implementation**

```python
# add to the Orchestrator class in src/orchestrator/core.py
    def on_clip_ended(self, display: str) -> list:
        sc = self._screens[display]
        sc.playing = False
        owner = sc.owner
        if owner is not None and owner in self._programs \
                and self._programs[owner].round == sc.round:
            # first display of this owner to finish the current round → advance
            self._programs[owner].round = next_round(self._programs[owner].round)
        return self._reassign()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_orchestrator_core.py -k clip_ended -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/orchestrator/core.py tests/test_orchestrator_core.py
git commit -m "feat(orchestrator): on_clip_ended advances opener→round2 (paired)"
```

---

### Task 7: round 2 → done → idle (no round 3)

**Files:**
- Test: `tests/test_orchestrator_core.py` (no impl change expected — `next_round` already caps at DONE; this proves the cap end-to-end)

- [ ] **Step 1: Write the failing test**

```python
# add to tests/test_orchestrator_core.py
def test_program_caps_at_round2_then_idles_no_round3():
    o = _orch(displays=("display-1",))
    o.on_identify("jason")                 # opener on d1
    o.on_clip_ended("display-1")           # → round 2 on d1
    cmds = o.on_clip_ended("display-1")    # round 2 ends → DONE → idle (NOT round 3)
    assert Idle("display-1") in cmds
    assert not any(isinstance(c, Play) for c in cmds)  # no round 3 play
```

- [ ] **Step 2: Run test to verify it fails (or passes immediately — see note)**

Run: `python -m pytest tests/test_orchestrator_core.py::test_program_caps_at_round2_then_idles_no_round3 -v`
Expected: PASS is acceptable here — Tasks 1 & 6 already implement the cap; this test is the **regression guard** that proves "no round 3" holds end-to-end. If it FAILS, fix `next_round`/`on_clip_ended` until it passes.

- [ ] **Step 3: (only if the test failed) fix**

If failing, confirm `next_round(Round.ROUND2) == Round.DONE` and that a DONE owner is excluded from `_active_newest_first`. No new code expected.

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_orchestrator_core.py -v`
Expected: PASS (all)

- [ ] **Step 5: Commit**

```bash
git add tests/test_orchestrator_core.py
git commit -m "test(orchestrator): guard the 2-round cap (no round 3)"
```

---

### Task 8: newest-wins handoff at clip-end (never mid-clip)

**Files:**
- Test: `tests/test_orchestrator_core.py` (no impl change expected — proves `on_identify` + `_reassign` defer to boundaries)

- [ ] **Step 1: Write the failing test**

```python
# add to tests/test_orchestrator_core.py
def test_new_identify_does_not_interrupt_playing_clips():
    o = _orch()
    o.on_identify("jason")           # jason opener on 1..4 (all playing)
    cmds = o.on_identify("maria")    # maria identified while jason mid-clip
    # nothing plays yet — all four are still playing jason's opener
    assert not any(isinstance(c, Play) for c in cmds)


def test_newest_wins_takes_freed_displays_at_boundaries():
    o = _orch()
    o.on_identify("jason")
    o.on_identify("maria")           # 2 active → split 2/2, maria newest
    # display-3 frees: maria (newest) owns 3,4 → her opener on the freed display-3
    cmds = o.on_clip_ended("display-3")
    play = next(c for c in cmds if isinstance(c, Play))
    assert play.owner == "maria"
    assert play.round == Round.OPENER
```

- [ ] **Step 2: Run test to verify it fails (or passes — see note)**

Run: `python -m pytest tests/test_orchestrator_core.py -k "interrupt or newest_wins" -v`
Expected: PASS is acceptable — Task 5's "never interrupt playing" + `_reassign`'s newest-first split already implement this. These are behavior guards. If either FAILS, fix `_reassign` until green.

- [ ] **Step 3: (only if failed) fix**

Ensure `_reassign` skips `sc.playing` displays and that `even_split` receives `_active_newest_first()` (newest first). No new code expected.

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_orchestrator_core.py -k "interrupt or newest_wins" -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add tests/test_orchestrator_core.py
git commit -m "test(orchestrator): newest-wins handoff defers to clip boundaries"
```

---

### Task 9: presence TTL — leaving frees displays

**Files:**
- Modify: `src/orchestrator/core.py`
- Test: `tests/test_orchestrator_core.py`

**Design note:** `on_presence(uuids)` refreshes `last_seen` for the listed identified uuids at the current clock time. `tick()` expires any present entry older than the TTL and reassigns — an expired person drops from the active set, so at the next boundary their displays go to remaining active people or idle. (Expiry never interrupts a playing clip; `_reassign` still skips `sc.playing`.)

- [ ] **Step 1: Write the failing test**

```python
# add to tests/test_orchestrator_core.py
def test_presence_ttl_expiry_drops_owner_and_idles_on_next_boundary():
    clock = _Clock(0.0)
    o = Orchestrator(["display-1"], clock=clock, presence_ttl_s=5.0)
    o.on_identify("jason")               # present at t=0, opener on d1 (playing)
    clock.t = 3.0
    o.on_presence(["jason"])             # heartbeat refreshes last_seen=3.0
    clock.t = 10.0                       # >5s since last heartbeat → expired
    o.tick()                             # jason no longer present; d1 still playing → skipped
    cmds = o.on_clip_ended("display-1")  # clip ends → no active owner → idle
    assert Idle("display-1") in cmds


def test_presence_heartbeat_keeps_owner_active():
    clock = _Clock(0.0)
    o = Orchestrator(["display-1"], clock=clock, presence_ttl_s=5.0)
    o.on_identify("jason")
    clock.t = 4.0
    o.on_presence(["jason"])             # refresh
    clock.t = 6.0                        # only 2s since refresh → still present
    o.tick()
    cmds = o.on_clip_ended("display-1")  # ends opener → advances to round 2, still jason
    assert any(isinstance(c, Play) and c.owner == "jason" for c in cmds)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_orchestrator_core.py -k presence -v`
Expected: FAIL — `AttributeError: 'Orchestrator' object has no attribute 'on_presence'`

- [ ] **Step 3: Write minimal implementation**

```python
# add to the Orchestrator class in src/orchestrator/core.py
    def on_presence(self, uuids: list[str]) -> list:
        now = self._clock()
        for uuid in uuids:
            self._present[uuid] = now
        return self.tick()

    def tick(self) -> list:
        now = self._clock()
        expired = [u for u, seen in self._present.items() if now - seen > self._ttl]
        for u in expired:
            del self._present[u]
        return self._reassign()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_orchestrator_core.py -k presence -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/orchestrator/core.py tests/test_orchestrator_core.py
git commit -m "feat(orchestrator): presence heartbeat + TTL expiry frees displays"
```

---

### Task 10: reclaim — remaining active person takes freed displays

**Files:**
- Test: `tests/test_orchestrator_core.py` (no impl change expected — proves the full walk-up trace)

- [ ] **Step 1: Write the failing test**

```python
# add to tests/test_orchestrator_core.py
def test_remaining_active_person_reclaims_displays_after_other_leaves():
    clock = _Clock(0.0)
    o = Orchestrator(["display-1", "display-2"], clock=clock, presence_ttl_s=5.0)
    o.on_identify("jason")    # t0: jason owns 1,2 (opener playing on both)
    clock.t = 1.0
    o.on_identify("maria")    # maria active; split 1/1 deferred to boundaries
    # jason leaves (never heartbeats again); only maria keeps heartbeating
    clock.t = 9.0
    o.on_presence(["maria"])  # maria fresh at t=9
    clock.t = 10.0
    o.tick()                  # jason (last seen t=0) expires; maria (t=9) stays
    # both displays end their clips → maria (only active) reclaims both
    o.on_clip_ended("display-1")
    cmds = o.on_clip_ended("display-2")
    owners = {c.owner for c in cmds if isinstance(c, Play)}
    assert owners == {"maria"}
```

- [ ] **Step 2: Run test to verify it fails (or passes — see note)**

Run: `python -m pytest tests/test_orchestrator_core.py::test_remaining_active_person_reclaims_displays_after_other_leaves -v`
Expected: PASS is acceptable — reclaim is an emergent property of `tick` + `_reassign`. This is the end-to-end walk-up guard. If it FAILS, debug `_reassign`/`tick` until green.

- [ ] **Step 3: (only if failed) fix**

No new code expected; ensure expiry removes jason from `_present` and `_reassign` gives both freed displays to maria.

- [ ] **Step 4: Run the FULL core suite**

Run: `python -m pytest tests/test_orchestrator_core.py tests/test_orchestrator_model.py -v`
Expected: PASS (all)

- [ ] **Step 5: Commit**

```bash
git add tests/test_orchestrator_core.py
git commit -m "test(orchestrator): full walk-up reclaim after a person leaves"
```

---

## Plan 1 self-review (run before handing off)

- [ ] Run the whole composer suite to confirm no regressions: `python -m pytest -q` (expected: all pass, including the existing composer tests).
- [ ] Confirm the core has **zero** imports from FastAPI, httpx, asyncpg, or the WS layer (`grep -rE "fastapi|httpx|asyncpg|websocket" src/orchestrator/` returns nothing).

## What Plan 1 deliberately does NOT do (handled in Plan 2 / 3)

- **Rendering, render-readiness, and the render-gap → idle fallback.** The core emits `Play(ROUND2, …)` assuming the render-ahead landed; Plan 2's integration maps that to "send if rendered, else idle + resume when ready."
- **The watchdog.** Plan 2 calls `on_clip_ended` either from the real kiosk event or from a duration timer; the core needs no clip durations.
- **All I/O:** `/trigger` → `on_identify`, `/presence` → `on_presence` (+ a periodic `tick`), `/ws` `clip_ended` → `on_clip_ended`, and mapping `Play`/`Idle`/`RenderAhead` to real renders and `WSManager.send_to`. That is Plan 2.
- **Vision `/presence` emission and kiosk `clip_ended`/idle handling + live E2E.** That is Plan 3.
