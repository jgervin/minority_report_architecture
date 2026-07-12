# God View Globe v2 — Living Topology (2026-07-12)

**Status:** owner-approved design (this session); pending owner spec review + outside opinion.
**Builds on:** Globe v1, shipped 2026-07-12 (spec
`/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-11-globe-view-design.md`;
mras-ops PR #53, godview-prototype PR #13). Realizes the deep-zoom half of
`/Users/jn/code/minority_report_architecture/docs/Godview_prototype_handoff.md` that v1
deliberately deferred ("geography at high zoom, topology at deep zoom"), now on the owner's word.

## 1. Goal

Make the globe a living topology: venue dots explode into fleets then cameras/screens as you keep
zooming; connectors between nodes reflect real DB relationships with labels at every level;
retailer networks span the globe (click a brand → all its stores' connectors light up); and when
a camera recognizes someone, a green pulse travels the lit path. Clicking any node swaps the right
panel to that node's details.

## 2. Owner decisions (made 2026-07-12, this session)

| Decision | Choice |
|---|---|
| Deep-zoom mechanics | **Anchored explosion** — stay on the globe; venue dot fans into system nodes, then devices, at the venue's geo anchor (operational topology, not fake geography) |
| Recognition-pulse latency | **Poll-based** (~2–7 s trail = poll interval + projector settle; accepted). No backend push; SSE stays a future upgrade |
| Retailer seed | **Split existing venues among 3–4 fake retailer orgs** under the demo umbrella; fold in same-city venues (mras-ops #55) |
| Phasing | **All three lanes, in order** (each independently shippable) |

## 3. Lane 1 — Retailer network (globe level)

### Seed v2 (mras-ops)
- Keep umbrella org `Demo Retail Group` (`dea00000-0000-4000-8000-000000000001`). Add 3–4
  retailer orgs with deterministic uuids (`…-0002` through `…-0005`, e.g. "Northline Apparel",
  "Vantage Motors", "Corebrew Coffee"), linked to the umbrella via the existing
  `organization_relationships` table (no schema change).
- Existing venues split among retailers via `systems.organization_id` (each seeded venue is
  single-retailer by construction). Add 2–3 **same-city venues** (closes mras-ops #55) so
  clustering AND org arcs are both live-demo-able.
- **Teardown/generator scope by the demo-org id SET** (umbrella + retailers — the deterministic
  uuid family), preserving one-shot cleanup and the generator's hard-scope/hard-exit discipline.
  All v1 invariants hold: deterministic md5 ids, `demo-` screen_id namespace, tags on rows that
  have metadata/config, FK-cycle-aware delete order, projector cursor untouched.

### API (mras-ops, additive only)
- `/god-view/map` venues gain `org: { id, name } | null` — the venue's dominant org by system
  count, derived truthfully from `systems.organization_id` (null if the venue has no systems with
  an org). No breaking changes; Plan-B-style optional typing on the frontend.

### Globe (godview-prototype)
- **Org arcs:** per retailer, a deterministic connector network between its venues — a greedy
  nearest-neighbor chain (pure function of the org's venue list; unit-tested), NOT a full mesh
  (100 stores would be 4,950 arcs). Drawn dim by default via globe.gl `arcsData`.
- **Highlight:** clicking a venue dot, a rail row, or an **org chip** (new small org legend near
  the rail) lights that retailer's whole network — brighter color + `arcDashAnimateTime` sweep
  (native globe.gl arc dash animation). Clicking elsewhere/again clears it.
- **Labels:** venue/cluster name labels via globe.gl `labelsData` at mid zoom (cluster label =
  city + venue count; venue label = name), fading by altitude. Deep-zoom node labels are Lane 2.
- Arcs/labels data are **identity-diffed** into the globe like v1's points (never re-init).

## 4. Lane 2 — Anchored explosion (venue → fleet → devices)

- New `EXPLODE_ALTITUDE` threshold below v1's `CLUSTER_ALTITUDE`. **Exactly one venue explodes at
  a time** — the selected venue (or the one nearest camera center when none selected). Others
  remain plain dots. This bounds DOM-label/three-object counts for hours-long TV sessions.
- Explosion tiers: first a **radial ring of system nodes** around the venue anchor; below a
  second threshold each system fans its **cameras and displays** in an outer arc segment. Layout
  is a pure deterministic function (radial positions from sorted ids + counts) — unit-tested
  without WebGL.
- **Connectors** venue→system and system→device rendered as a custom three.js line layer (via
  globe.gl `customLayerData`/`objectsData`), styled by the active mode (health tone / live
  state). Relationships come from the existing `/god-view/map/locations/{id}` payload — the DB
  is the source of truth, nothing invented client-side.
- **Octagon hull:** an octagonal ring (three.js line loop) around the exploded group; the org's
  arcs to its other venue-groups remain visible entering/leaving the hull.
- **Node labels:** DOM labels via globe.gl `htmlElementsData` (crisp text) — venue name on the
  hull, system names on ring nodes, camera/display names + status glyph on device nodes.
- **Per-node right panel:** clicking a node swaps the panel content by node type, mounted keyed
  `${type}:${id}` (fleet keying lesson): venue → v1 panel; system → zone/status/system_type +
  device list; camera → status, last_seen, screen_id, current duty; display → status, last_seen,
  screen group. Data comes from the panel payload plus the existing fleet detail fetchers
  (`fetchObjectDetail` in `/Users/jn/code/godview-prototype/src/data/api.ts`) — no new backend.
- GlobeCanvas stays the only imperative island; all new geometry/layout/label content is computed
  by pure selectors and diffed in.

## 5. Lane 3 — Recognition pulse (poll-delta driven)

- A pure **delta engine** compares consecutive poll payloads:
  - Far zoom: a venue's `runs_last_hour`/`playing_count` rise or a new recent ad_run → venue dot
    pulse + ONE animated dash sweep along its org's arcs.
  - Deep zoom (exploded venue): a new ad_run/playback in the panel payload → camera node flash,
    then a **traveling pulse along camera → system → display connectors** (animated dash offset
    on the custom line layer).
- Color: green default; rainbow behind a config constant (demo fun, one-line switch).
- Trigger sources are the REAL pipeline: live recognition on the demo box, or
  `scripts/demo_traffic.py` for seeded venues. Accepted lag ~2–7 s (poll + settle) — the moment
  reads responsive, not instant; SSE is the future upgrade path if instant is ever wanted.
- While in this code: fix godview #14 item 1 — **ring datum identity** (v1's pulse-phase reset
  each poll) — the same identity-diff treatment as points, so all animations hold phase.

## 6. Build plan & verification

Three lanes, sequential, each with the standard process (spec→plans gate-checked, worktrees, TDD
red→green pairs, per-task reviews, strongest-model final review, merge commits, live E2E always):

- **Lane 1:** Plan C (mras-ops: seed v2 + `org` field + updated drill) then Plan D
  (godview-prototype: arcs/chips/labels/highlight). Live E2E: seed v2 applied, org chip click
  lights the right arc set, clustering triggers on the same-city venues.
- **Lane 2:** Plan E (godview-prototype only): explosion layout selectors → custom layers →
  node panels. Live E2E: zoom into a venue, see systems then devices with labels, click a camera
  → panel shows its detail, hull + outbound org arcs visible.
- **Lane 3:** Plan F (godview-prototype only): delta engine + animations + rings-identity fix.
  Live E2E: run `demo_traffic`, observe far-zoom venue pulse + arc sweep and deep-zoom
  camera→screen traveling pulse; owner optionally validates with the real camera (real
  recognition → globe pulse).

Unit-test surface: chain-builder, org grouping, explosion layout, hull points, label content,
delta engine — all pure. jsdom never touches three (v1 guardrails unchanged).

## 7. Out of scope (v2)

- SSE/WebSocket push (poll-based by owner decision).
- Multiple simultaneous exploded venues; explosion at cluster level.
- Volume/Error/Campaign modes; editing from the globe (Fleet owns writes); arcs beyond org
  networks (no traffic/route semantics).
- Real brand data (retailers are seeded fakes); auth/tenant scoping (deferred project-wide).
- Mobile polish for deep zoom (desktop/TV-first; page stays usable at 390px as in v1).

## 8. Risks / trade-offs (accepted)

- Lane 2 is the largest custom-three.js piece attempted on this surface (node/connector/hull
  layers + DOM labels). Mitigations: one-venue-at-a-time explosion, pure-layout selectors,
  identity-diffed layers, per-lane E2E.
- Deep-zoom label density needs live tuning against real screen space (budgeted in Lane 2's E2E).
- Poll-based pulses can coalesce (two recognitions inside one poll window animate once per
  affected path) — acceptable for demo semantics.
- Org arc chains are a visual abstraction (nearest-neighbor chain), not a claim about network
  traffic; labels/legend must not imply data flows between stores.
