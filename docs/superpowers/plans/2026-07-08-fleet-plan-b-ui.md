# Fleet Management — Plan B: godview-prototype Fleet page (Phases 1–2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Orchestrator amendments (2026-07-08, from outside review — BINDING):**
> 1. **(M-1, error fallback)** In every form/adopt catch block, the non-422/409 fallback message
>    must prefer the server's string detail:
>    `typeof err.detail === "string" ? err.detail : err.message` (e.g. adopt 404 shows
>    "unresolved device not found", not "/displays/adopt -> 404").
> 2. **(M-2, StatePanel honesty)** Gate the D15 "converges on the device's next poll" copy AND the
>    state polling to device types (`camera`/`display`) only — locations/systems/groups have no
>    device poll; render their state block static.
> 3. **(nit)** `UnresolvedDeviceItem` gains optional `event_id?: number` (contract delta 6
>    completeness).
> Cross-plan contract: the outside review verified all 8 Plan-A deltas are absorbed by this plan
> as written ("Plan B amendments required now: none") — Task 0's reconcile remains mandatory but
> expect confirmation, not rework.

**Goal:** A new "Fleet" God View page. **P1 (read):** lazy hierarchy browser (locations tree → systems → groups+devices; each level a bounded keyset fetch) + object detail drawer with Config / State / History sections, all read-only. **P2 (device writes):** camera+display Config sections become forms (submit → PATCH → refetch; no optimistic updates), create-camera / create-display forms, a lifecycle transition control honoring 409 allowed-set errors, and — LAST and DROPPABLE — the adopt-unresolved flow. P3/P4 UI (group/container CRUD) is OUT.

**Architecture:** Extends the established idioms only — fetchers in `src/data/api.ts` (plus this app's FIRST write path: an `ApiError`-throwing `sendJson`), payload types in `src/data/apiTypes.ts`, view logic in selectors (new `src/data/fleetSelectors.ts`), `usePolling` for the State panel ONLY (forms and tree levels do not poll), `AsyncState`-style last-good handling + keyset "Load more" for lists. The page decomposes into small focused components under `src/components/fleet/` — tree level lists, object drawer, config form field primitives, state panel, history list — each testable alone. Write flow: plain `useState` form state → submit → fetcher → on 422 map pydantic `detail[]` into per-field errors → on 409 render the allowed-set / blocker list → on success refetch the detail AND invalidate the parent level list. No new libraries (no react-query, no form libs — nothing added to package.json).

**Tech Stack:** Vite + React 19 + TypeScript + react-router-dom v7; Tailwind; Vitest + @testing-library/react + jsdom.

**Spec:** `/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-08-fleet-management-design.md`
**Contract (Plan A):** `/Users/jn/code/minority_report_architecture/docs/superpowers/plans/2026-07-08-fleet-plan-a-ops.md` — **did not exist when this plan was written.** The payload shapes in "Contract assumptions" below are derived from spec §5.1/§5.2, D9/D10, and the shipped `PATCH /cameras/{camera_id}` + God View keyset precedents in `/Users/jn/code/mras-ops`. **Task 0 (mandatory): if Plan A's Interfaces section exists at execution time, diff it against the assumptions and fix `apiTypes.ts`/fetcher paths in Task 1 before writing any component.** All shape knowledge is deliberately confined to Tasks 1/3/9 (types, fetchers, selectors) so reconciliation is cheap.

## Global Constraints (binding decisions, verbatim from the spec)

- **D1 (spec-vs-status rendering):** "Every object's payload carries `config` (editable) and `state` (read-only: `last_seen_at`, effective duty for cameras, health rollups later)." The UI renders Config and State as visually distinct sections; State is never editable; forms never send state fields.
- **D2 (identity never editable):** "IDENTITY — immutable via API forever: `id`, `device_id`, `serial_number`, `external_device_key`, `screen_id` (the wire key kiosks/vision report — changing it would silently orphan history), parent `system_id`/`location_id`/`organization_id` in v1." Identity fields render as a read-only monospace block and are NEVER form inputs in edit forms. (`screen_id`/`system_id` appear as inputs only in CREATE forms — identity is set at birth, D8.)
- **D3 (lifecycle transitions):** "`status` changes go through the same PATCH but are validated against an allowed-transition matrix (e.g. `retired` is terminal — nothing leaves it) … Invalid transition ⇒ 409 with the allowed set." The UI has a dedicated lifecycle control (not a plain status field inside the config form) and renders the 409 allowed set verbatim.
- **D7 (staged creation copy):** "new devices (device_status has no `planned`) start **`offline`** — visible in the Fleet page but not yet a live participant … Going live is an explicit lifecycle transition." Create forms have no status field and display exactly this copy: *"New devices are created offline — visible in Fleet but not live until you activate them."*
- **D12 (Advanced raw-JSON editor + typed cam_index):** "jsonb blobs (`metadata`/`config`/`calibration`) are editable as raw JSON behind an 'Advanced' disclosure in the UI, validated only as parseable JSON in v1. Exception: `calibration.cam_index` gets a dedicated typed field in the camera form (it's operationally load-bearing for the fleet launcher)."
- **D13 (UI shape):** "one new God View page ('Fleet') using existing idioms — no new framework. Left: lazy hierarchy browser (locations tree → systems → groups+devices), each level a bounded, keyset-paginated fetch. Right: object detail with three sections — **Config** (form; submit → PATCH → refetch; no optimistic updates), **State** (read-only, polled), **History** (latest 20 `registry_admin`/`camera_admin`/`camera_duty` events for the object). Create/adopt via explicit buttons per level. Every API validation error surfaces field-level in the form."
- **D15 (convergence honesty):** "camera config changes apply within one TODO-8 poll tick; display/kiosk config consumption is whatever the kiosk already does … The Fleet page sets admin truth and shows runtime truth — it never pretends a write is instantly live." The State panel shows `last_seen_at` staleness (and duty for cameras) directly beside Config, with explicit convergence copy.
- Repo: `/Users/jn/code/godview-prototype`. ALL repo operations (branch, stage, commit) are delegated to the **git-flow-manager** subagent — never run raw VCS commands. One branch for this plan: `feat/fleet-page` off `main`. Red-test commits are SEPARATE from implementation commits (`test:` commit first, then `feat:`).
- Test command: `cd /Users/jn/code/godview-prototype && npm test` (vitest run, jsdom, setup `src/test/setup.ts`). Lint: `npm run lint`. Build: `npm run build`.
- Test convention: component tests `vi.mock` the api module (`"../../data/api"` from `src/components/fleet/`, `"../data/api"` from `src/pages/`); any test that renders `Shell` (directly or via the Fleet page) MUST mock `fetchProjectorStatus` resolving `{ cursor, backlog, lag_seconds, health }` (Shell polls it).
- `usePolling` is used by the State panel only. Tree levels fetch on expand (manual reload on invalidation); forms are plain `useState`.
- History panel reads BOTH `registry_admin` and legacy `camera_admin` (+ `camera_duty`) event types (spec §7 documents the two-event-type reality).

## Contract assumptions (reconcile against Plan A's Interfaces in Task 0)

```
A1  GET /locations?parent_location_id=root|<uuid>&cursor&limit        (tree level)
      -> { counts: {total}, items: [{ id, name, location_type, status,
           child_location_count, system_count }], next_cursor }
A2  GET /systems?location_id=<uuid>&cursor&limit
      -> { counts: {total}, items: [{ id, name, system_type, status, device_count }], next_cursor }
A3  GET /screen-groups?system_id=<uuid>&cursor&limit
      -> { counts: {total}, items: [{ id, name, group_type, status, device_count }], next_cursor }
A4  GET /cameras?system_id=|screen_group_id=&cursor&limit
      -> { counts: {total}, items: [{ id, name, status, camera_role, failover_eligible,
           screen_group_id, screen_id, effective_duty, last_seen_at }], next_cursor }
A5  GET /displays?system_id=|screen_group_id=&cursor&limit
      -> { counts: {total}, items: [{ id, name, status, display_role, screen_group_id,
           screen_id, last_seen_at }], next_cursor }
A6  GET /{locations|systems|screen-groups|cameras|displays}/{id}   (object detail)
      -> { object_type, identity: {..per spec §5.1..}, config: {..per §5.1..},
           state: { last_seen_at?, effective_duty?, created_at, updated_at } }
A7  GET /registry/audit?object_id=<uuid>&limit=20
      -> { items: [{ id, ts, event_type, payload }], next_cursor }   (payload = journal payload as-is)
A8  GET /unresolved-devices
      -> { counts: {total}, items: [{ id, screen_id, kind, first_seen_at, last_seen_at,
           seen_count }], next_cursor }
A9  PATCH /cameras/{id}   body ⊆ { name, camera_role, status, failover_eligible,
           screen_group_id, stream_url, calibration }         -> 200 (body unused; UI refetches A6)
A10 PATCH /displays/{id}  body ⊆ { name, display_role, status, screen_group_id,
           resolution_width, resolution_height, calibration }  -> 200
A11 POST /cameras  { system_id, screen_id?, name?, camera_role?, screen_group_id?,
           stream_url?, calibration?, failover_eligible? }      -> 201 { id, ... } (status forced offline, D7)
A12 POST /displays { system_id, screen_id, name?, display_role?, screen_group_id?,
           resolution_width?, resolution_height? }              -> 201 { id, ... }
A13 POST /displays/adopt { unresolved_id, system_id, name?, screen_group_id? } -> 201 { id, ... }
E1  422 pydantic: { detail: [ { loc: [..., "<field>"], msg, type }, ... ] }   (extra="forbid"/Literal precedent)
E2  422 semantic (e.g. D6 cross-system screen_group): { detail: "<string>" }  -> form-level error
E3  409 lifecycle (D3): { detail: { error: "invalid_transition", from: "<status>",
           allowed: ["<status>", ...] } }
E4  409 retire-blocked (D5): { detail: { error: "retire_blocked",
           blockers: [{ type, id, name, status }, ...] } }
```
Enums verified against `/Users/jn/code/mras-ops/db/migrations/010_enums.sql` (+027): `camera_role` = detection|enrollment|audience_measurement|security_context|standby; `display_role` = primary_ad|secondary_ad|ambient|status; `device_status` = active|degraded|offline|retired. The UI depends on write RESPONSES only for `res.ok` + (creates) `id` — everything else is refetched via A6, insulating the page from Plan A response drift. Unrecognized error `detail` shapes degrade to a form-level message.

---

### Task 0: Reconcile contract + branch

- [ ] **Step 1:** Check `/Users/jn/code/minority_report_architecture/docs/superpowers/plans/2026-07-08-fleet-plan-a-ops.md`. If present, diff its Interfaces section against A1–A13/E1–E4 and amend Tasks 1/3/9 code (paths, field names, error `detail` shapes) BEFORE starting. Record deviations in the task journal.
- [ ] **Step 2 (git-flow-manager):** create branch `feat/fleet-page` off `main`.

---

## Phase 1 — read-only hierarchy browser + object detail

### Task 1: Fleet payload types + read fetchers

**Files:**
- Modify: `/Users/jn/code/godview-prototype/src/data/apiTypes.ts`
- Modify: `/Users/jn/code/godview-prototype/src/data/api.ts`
- Modify: `/Users/jn/code/godview-prototype/src/data/api.test.ts`

- [ ] **Step 1: Write the failing tests** (append to `api.test.ts`)

```ts
import { fetchLocationChildren, fetchFleetCameras, fetchObjectDetail, fetchObjectAudit } from "./api";

describe("fleet api (P1 reads)", () => {
  it("fetchLocationChildren hits /locations with parent + cursor params", async () => {
    const spy = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ counts: { total: 0 }, items: [], next_cursor: null }), { status: 200 }));
    await fetchLocationChildren("root", { cursor: "c1", limit: 25 });
    const url = spy.mock.calls[0][0] as string;
    expect(url).toContain("/locations?");
    expect(url).toContain("parent_location_id=root");
    expect(url).toContain("cursor=c1");
    expect(url).toContain("limit=25");
  });

  it("fetchFleetCameras scopes by screen_group_id", async () => {
    const spy = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ counts: { total: 0 }, items: [], next_cursor: null }), { status: 200 }));
    await fetchFleetCameras({ screen_group_id: "g1" });
    expect(spy.mock.calls[0][0] as string).toContain("/cameras?screen_group_id=g1");
  });

  it("fetchObjectDetail maps object type to its route path", async () => {
    const spy = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ object_type: "screen_group", identity: {}, config: {}, state: {} }), { status: 200 }));
    await fetchObjectDetail("screen_group", "sg1");
    expect(spy.mock.calls[0][0] as string).toContain("/screen-groups/sg1");
  });

  it("fetchObjectAudit hits /registry/audit with object_id and default limit 20", async () => {
    const spy = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ items: [], next_cursor: null }), { status: 200 }));
    await fetchObjectAudit("cam1");
    const url = spy.mock.calls[0][0] as string;
    expect(url).toContain("/registry/audit?");
    expect(url).toContain("object_id=cam1");
    expect(url).toContain("limit=20");
  });
});
```

Run: `cd /Users/jn/code/godview-prototype && npm test -- src/data/api.test.ts` — Expected: FAIL (exports missing).

- [ ] **Step 2 (git-flow-manager):** commit `test: fleet read fetchers (locations tree, scoped devices, detail, audit)`

- [ ] **Step 3: Types** (append to `apiTypes.ts`)

```ts
// --- Fleet page (registry browse/CRUD, fleet Plan A). ASSUMED shapes — see plan-b "Contract assumptions".

export interface FleetPage<T> { counts: { total: number }; items: T[]; next_cursor: string | null; }

export interface LocationNodeItem {
  id: string; name: string; location_type: string; status: string;
  child_location_count: number; system_count: number;
}
export interface FleetSystemItem { id: string; name: string; system_type: string; status: string; device_count: number; }
export interface ScreenGroupItem { id: string; name: string; group_type: string; status: string; device_count: number; }
export interface FleetCameraItem {
  id: string; name: string | null; status: string; camera_role: string; failover_eligible: boolean;
  screen_group_id: string | null; screen_id: string | null; effective_duty: string; last_seen_at: string | null;
}
export interface FleetDisplayItem {
  id: string; name: string | null; status: string; display_role: string;
  screen_group_id: string | null; screen_id: string; last_seen_at: string | null;
}

export type FleetObjectType = "location" | "system" | "screen_group" | "camera" | "display";
export interface ObjectDetail {
  object_type: FleetObjectType;
  identity: Record<string, string | null>;                       // D2: rendered read-only, never form inputs
  config: Record<string, unknown>;                               // D1: the editable surface
  state: { last_seen_at?: string | null; effective_duty?: string; created_at?: string; updated_at?: string };
}

export interface AuditEventItem { id: number; ts: string; event_type: string; payload: Record<string, unknown>; }
export interface AuditPage { items: AuditEventItem[]; next_cursor: string | null; }
export interface UnresolvedDeviceItem {
  id: string; screen_id: string; kind: string; first_seen_at: string; last_seen_at: string; seen_count: number;
}
```

- [ ] **Step 4: Fetchers** (append to `api.ts`; extend the type-import list)

```ts
export interface LevelQuery { cursor?: string; limit?: number; }
export interface DeviceScope { system_id?: string; screen_group_id?: string; }

const FLEET_TYPE_PATH: Record<FleetObjectType, string> = {
  location: "locations", system: "systems", screen_group: "screen-groups",
  camera: "cameras", display: "displays",
};

export const fetchLocationChildren = (parent: string, q: LevelQuery = {}) =>
  getJson<FleetPage<LocationNodeItem>>(`/locations${qs({ parent_location_id: parent, ...q })}`);
export const fetchFleetSystems = (locationId: string, q: LevelQuery = {}) =>
  getJson<FleetPage<FleetSystemItem>>(`/systems${qs({ location_id: locationId, ...q })}`);
export const fetchFleetScreenGroups = (systemId: string, q: LevelQuery = {}) =>
  getJson<FleetPage<ScreenGroupItem>>(`/screen-groups${qs({ system_id: systemId, ...q })}`);
export const fetchFleetCameras = (scope: DeviceScope, q: LevelQuery = {}) =>
  getJson<FleetPage<FleetCameraItem>>(`/cameras${qs({ ...scope, ...q })}`);
export const fetchFleetDisplays = (scope: DeviceScope, q: LevelQuery = {}) =>
  getJson<FleetPage<FleetDisplayItem>>(`/displays${qs({ ...scope, ...q })}`);
export const fetchObjectDetail = (type: FleetObjectType, id: string) =>
  getJson<ObjectDetail>(`/${FLEET_TYPE_PATH[type]}/${id}`);
export const fetchObjectAudit = (objectId: string, limit = 20) =>
  getJson<AuditPage>(`/registry/audit${qs({ object_id: objectId, limit })}`);
export const fetchUnresolvedDevices = () =>
  getJson<FleetPage<UnresolvedDeviceItem>>("/unresolved-devices");
```

- [ ] **Step 5:** Run `npm test -- src/data/api.test.ts` — Expected: PASS. Then full `npm test` + `npm run lint`.
- [ ] **Step 6 (git-flow-manager):** commit `feat: fleet payload types + read fetchers`

---

### Task 2: `useLevelList` — keyset accumulation hook for tree levels

**Files:**
- Create: `/Users/jn/code/godview-prototype/src/hooks/useLevelList.ts`
- Create: `/Users/jn/code/godview-prototype/src/hooks/useLevelList.test.ts`

**Interfaces:** `useLevelList<T>(fetchPage, refreshToken?) => { items, loading, error, hasMore, loadMore, reload }`. Fetches once on mount and whenever `refreshToken` changes (write-invalidation path); `loadMore` appends the next keyset page. NOT polled (D13: tree levels are bounded on-demand fetches).

- [ ] **Step 1: Write the failing tests**

```ts
import { describe, expect, it, vi } from "vitest";
import { act, renderHook, waitFor } from "@testing-library/react";
import { useLevelList } from "./useLevelList";

describe("useLevelList", () => {
  it("loads the first page on mount and appends on loadMore", async () => {
    const fetchPage = vi.fn()
      .mockResolvedValueOnce({ items: [1, 2], next_cursor: "c1" })
      .mockResolvedValueOnce({ items: [3], next_cursor: null });
    const { result } = renderHook(() => useLevelList<number>(fetchPage));
    await waitFor(() => expect(result.current.items).toEqual([1, 2]));
    expect(result.current.hasMore).toBe(true);
    await act(() => result.current.loadMore());
    expect(fetchPage).toHaveBeenLastCalledWith("c1");
    expect(result.current.items).toEqual([1, 2, 3]);
    expect(result.current.hasMore).toBe(false);
  });

  it("reload resets to page one; refreshToken change reloads", async () => {
    const fetchPage = vi.fn().mockResolvedValue({ items: [9], next_cursor: null });
    const { result, rerender } = renderHook(({ t }) => useLevelList<number>(fetchPage, t), { initialProps: { t: 0 } });
    await waitFor(() => expect(result.current.items).toEqual([9]));
    rerender({ t: 1 });
    await waitFor(() => expect(fetchPage).toHaveBeenCalledTimes(2));
  });

  it("keeps last-good items and sets error on a failed reload", async () => {
    const fetchPage = vi.fn()
      .mockResolvedValueOnce({ items: [1], next_cursor: null })
      .mockRejectedValueOnce(new Error("boom"));
    const { result } = renderHook(() => useLevelList<number>(fetchPage));
    await waitFor(() => expect(result.current.items).toEqual([1]));
    await act(() => result.current.reload());
    expect(result.current.items).toEqual([1]);      // last-good retained (AsyncState idiom)
    expect(result.current.error?.message).toBe("boom");
  });
});
```

Run: `npm test -- src/hooks/useLevelList.test.ts` — Expected: FAIL.

- [ ] **Step 2 (git-flow-manager):** commit `test: useLevelList keyset accumulation hook`

- [ ] **Step 3: Implement** `src/hooks/useLevelList.ts`

```ts
import { useCallback, useEffect, useRef, useState } from "react";

export interface LevelPage<T> { items: T[]; next_cursor: string | null; }

/** Bounded keyset level fetch (D13). Loads on mount + refreshToken change; loadMore appends. Never polls. */
export function useLevelList<T>(fetchPage: (cursor?: string) => Promise<LevelPage<T>>, refreshToken = 0) {
  const [items, setItems] = useState<T[]>([]);
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<Error | null>(null);
  const fnRef = useRef(fetchPage);
  fnRef.current = fetchPage;

  const reload = useCallback(async () => {
    setLoading(true);
    try {
      const p = await fnRef.current(undefined);
      setItems(p.items); setNextCursor(p.next_cursor); setError(null);   // last-good retained on error
    } catch (e) {
      setError(e instanceof Error ? e : new Error(String(e)));
    } finally { setLoading(false); }
  }, []);

  const loadMore = useCallback(async () => {
    if (!nextCursor) return;
    try {
      const p = await fnRef.current(nextCursor);
      setItems((prev) => [...prev, ...p.items]); setNextCursor(p.next_cursor);
    } catch (e) { setError(e instanceof Error ? e : new Error(String(e))); }
  }, [nextCursor]);

  useEffect(() => { reload(); }, [reload, refreshToken]);

  return { items, loading, error, hasMore: nextCursor != null, loadMore, reload };
}
```

- [ ] **Step 4:** Run `npm test -- src/hooks/useLevelList.test.ts` — Expected: PASS.
- [ ] **Step 5 (git-flow-manager):** commit `feat: useLevelList hook (bounded keyset levels, last-good on error)`

---

### Task 3: Fleet selectors (P1 subset): staleness, history rows, config entries

**Files:**
- Create: `/Users/jn/code/godview-prototype/src/data/fleetSelectors.ts`
- Create: `/Users/jn/code/godview-prototype/src/data/fleetSelectors.test.ts`

- [ ] **Step 1: Write the failing tests**

```ts
import { describe, expect, it } from "vitest";
import { stalenessOf, historyRows, configEntries } from "./fleetSelectors";

describe("stalenessOf (D15 convergence honesty)", () => {
  const now = new Date("2026-07-08T12:00:00Z");
  it("never seen", () => expect(stalenessOf(null, now)).toEqual({ label: "never seen", tone: "crit" }));
  it("fresh", () => expect(stalenessOf("2026-07-08T11:59:30Z", now)).toEqual({ label: "seen 30s ago", tone: "ok" }));
  it("minutes-stale", () => expect(stalenessOf("2026-07-08T11:30:00Z", now)).toEqual({ label: "stale — seen 30m ago", tone: "warn" }));
  it("hours-stale", () => expect(stalenessOf("2026-07-08T06:00:00Z", now)).toEqual({ label: "stale — seen 6h ago", tone: "crit" }));
});

describe("historyRows (registry_admin + legacy camera_admin + camera_duty)", () => {
  it("summarizes admin changes and duty flips", () => {
    const rows = historyRows([
      { id: 3, ts: "2026-07-08T10:00:00Z", event_type: "registry_admin",
        payload: { object_type: "display", object_id: "d1", action: "update",
                   changes: { name: { from: "Old", to: "New" } } } },
      { id: 2, ts: "2026-07-08T09:00:00Z", event_type: "camera_admin",
        payload: { camera_id: "c1", changes: { failover_eligible: { from: false, to: true } } } },
      { id: 1, ts: "2026-07-08T08:00:00Z", event_type: "camera_duty",
        payload: { camera_id: "c1", from: "standby", to: "watching", reason: "lease" } },
    ]);
    expect(rows[0].summary).toContain('name: "Old" → "New"');
    expect(rows[1].summary).toContain("failover_eligible: false → true");
    expect(rows[2].summary).toBe("duty standby → watching (lease)");
  });
});

describe("configEntries (D1 read-only rendering)", () => {
  it("stringifies scalars, nulls, and jsonb blobs", () => {
    const entries = configEntries({
      object_type: "camera", identity: {},
      config: { name: "Cam A", failover_eligible: true, stream_url: null, calibration: { cam_index: 2 } },
      state: {},
    });
    expect(entries).toEqual([
      { key: "name", value: "Cam A" },
      { key: "failover_eligible", value: "true" },
      { key: "stream_url", value: "—" },
      { key: "calibration", value: '{"cam_index":2}' },
    ]);
  });
});
```

Run: `npm test -- src/data/fleetSelectors.test.ts` — Expected: FAIL.

- [ ] **Step 2 (git-flow-manager):** commit `test: fleet selectors — staleness, history rows, config entries`

- [ ] **Step 3: Implement** `src/data/fleetSelectors.ts`

```ts
import type { AuditEventItem, ObjectDetail } from "./apiTypes";

// Enum vocabularies (db/migrations/010_enums.sql + 027). Lifecycle validity is SERVER truth (D3) —
// the UI offers all non-current statuses and renders the 409 allowed set on rejection.
export const DEVICE_STATUSES = ["active", "degraded", "offline", "retired"] as const;
export const CAMERA_ROLES = ["detection", "enrollment", "audience_measurement", "security_context", "standby"] as const;
export const DISPLAY_ROLES = ["primary_ad", "secondary_ad", "ambient", "status"] as const;

export interface Staleness { label: string; tone: "ok" | "warn" | "crit"; }
export function stalenessOf(lastSeenAt: string | null | undefined, now: Date = new Date()): Staleness {
  if (!lastSeenAt) return { label: "never seen", tone: "crit" };
  const ageS = (now.getTime() - new Date(lastSeenAt).getTime()) / 1000;
  if (ageS < 120) return { label: `seen ${Math.max(0, Math.round(ageS))}s ago`, tone: "ok" };
  if (ageS < 3600) return { label: `stale — seen ${Math.round(ageS / 60)}m ago`, tone: "warn" };
  return { label: `stale — seen ${Math.round(ageS / 3600)}h ago`, tone: "crit" };
}

export interface HistoryRow { id: number; when: string; kind: string; summary: string; }
export function historyRows(items: AuditEventItem[]): HistoryRow[] {
  return items.map((e) => {
    const p = (e.payload ?? {}) as Record<string, unknown>;
    let summary: string;
    if (e.event_type === "camera_duty") {
      summary = `duty ${p.from} → ${p.to}${p.reason ? ` (${p.reason})` : ""}`;
    } else {
      const changes = (p.changes ?? {}) as Record<string, { from: unknown; to: unknown }>;
      const parts = Object.entries(changes).map(([k, v]) => `${k}: ${JSON.stringify(v.from)} → ${JSON.stringify(v.to)}`);
      summary = `${p.action ?? "update"}${parts.length ? ` · ${parts.join(", ")}` : ""}`;
    }
    return { id: e.id, when: e.ts, kind: e.event_type, summary };
  });
}

export interface ConfigEntry { key: string; value: string; }
export function configEntries(detail: ObjectDetail): ConfigEntry[] {
  return Object.entries(detail.config).map(([key, value]) => ({
    key,
    value: value == null ? "—" : typeof value === "object" ? JSON.stringify(value) : String(value),
  }));
}
```

- [ ] **Step 4:** Run `npm test -- src/data/fleetSelectors.test.ts` — Expected: PASS.
- [ ] **Step 5 (git-flow-manager):** commit `feat: fleet selectors (staleness, history rows, config entries)`

---

### Task 4: Tree primitives — `TreeRow`, `LoadMoreRow`, `DeviceLevel`

**Files:**
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/TreeRow.tsx`
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/DeviceLevel.tsx`
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/DeviceLevel.test.tsx`

**Interfaces:**
- `TreeRow({ depth, label, meta?, status?, statusKind?, selected?, expandable?, expanded?, onToggle?, onSelect, testId? })` — one row; caret button when expandable; label click selects.
- `LoadMoreRow({ depth, hasMore, onLoadMore })` (exported from `TreeRow.tsx`).
- `DeviceLevel({ scope: { system_id? , screen_group_id? }, depth, selectedId, onSelect, refreshToken })` — fetches cameras + displays for the scope via `useLevelList`, renders `TreeRow`s (`cam:` prefix meta shows role/duty; display rows show screen_id), each with Load more.

- [ ] **Step 1: Write the failing tests** (`DeviceLevel.test.tsx`)

```tsx
import { describe, expect, it, vi, beforeEach } from "vitest";
import { render, screen, waitFor, fireEvent } from "@testing-library/react";
import { DeviceLevel } from "./DeviceLevel";
import { fetchFleetCameras, fetchFleetDisplays } from "../../data/api";

vi.mock("../../data/api", () => ({
  fetchFleetCameras: vi.fn().mockResolvedValue({
    counts: { total: 1 },
    items: [{ id: "c1", name: "Cam A", status: "active", camera_role: "detection", failover_eligible: true,
              screen_group_id: null, screen_id: "screen_0", effective_duty: "watching", last_seen_at: null }],
    next_cursor: null,
  }),
  fetchFleetDisplays: vi.fn().mockResolvedValue({
    counts: { total: 2 },
    items: [{ id: "d1", name: "Kiosk 1", status: "offline", display_role: "primary_ad",
              screen_group_id: null, screen_id: "display-1", last_seen_at: null }],
    next_cursor: "cur1",
  }),
}));

describe("DeviceLevel", () => {
  beforeEach(() => vi.clearAllMocks());

  it("renders cameras (role · duty) and displays (screen_id) for the scope", async () => {
    render(<DeviceLevel scope={{ system_id: "s1" }} depth={2} selectedId={null} onSelect={() => {}} refreshToken={0} />);
    await waitFor(() => expect(screen.getByText("Cam A")).toBeInTheDocument());
    expect(vi.mocked(fetchFleetCameras)).toHaveBeenCalledWith({ system_id: "s1" }, expect.anything());
    expect(screen.getByText(/detection · watching/)).toBeInTheDocument();
    expect(screen.getByText("Kiosk 1")).toBeInTheDocument();
    expect(screen.getByText(/display-1/)).toBeInTheDocument();
  });

  it("selects a device on click and pages displays on Load more", async () => {
    const onSelect = vi.fn();
    render(<DeviceLevel scope={{ screen_group_id: "g1" }} depth={3} selectedId={null} onSelect={onSelect} refreshToken={0} />);
    await waitFor(() => expect(screen.getByText("Cam A")).toBeInTheDocument());
    fireEvent.click(screen.getByText("Cam A"));
    expect(onSelect).toHaveBeenCalledWith({ type: "camera", id: "c1" });
    fireEvent.click(screen.getByRole("button", { name: /load more displays/i }));
    await waitFor(() => expect(vi.mocked(fetchFleetDisplays)).toHaveBeenCalledTimes(2));
  });
});
```

Run: `npm test -- src/components/fleet/DeviceLevel.test.tsx` — Expected: FAIL.

- [ ] **Step 2 (git-flow-manager):** commit `test: DeviceLevel tree rows (cameras + displays, scoped, paged)`

- [ ] **Step 3: Implement** `TreeRow.tsx`

```tsx
import { StatusDot } from "../StatusDot";

export function TreeRow({ depth, label, meta, status, statusKind = "device", selected, expandable, expanded, onToggle, onSelect, testId }: {
  depth: number; label: string; meta?: string; status?: string; statusKind?: "lifecycle" | "device";
  selected?: boolean; expandable?: boolean; expanded?: boolean;
  onToggle?: () => void; onSelect: () => void; testId?: string;
}) {
  return (
    <div data-testid={testId} style={{ paddingLeft: depth * 14 }}
      className={`flex items-center gap-1.5 py-1 pr-2 rounded-md text-[12px] ${selected ? "bg-elev text-text" : "text-dim hover:bg-elev/60"}`}>
      {expandable
        ? <button aria-label={`${expanded ? "collapse" : "expand"} ${label}`} onClick={onToggle} className="w-4 text-faint">{expanded ? "▾" : "▸"}</button>
        : <span className="w-4" />}
      {status && <StatusDot status={status} kind={statusKind} />}
      <button onClick={onSelect} className="truncate text-left flex-1">{label}</button>
      {meta && <span className="font-mono text-[10px] text-faint truncate">{meta}</span>}
    </div>
  );
}

export function LoadMoreRow({ depth, hasMore, onLoadMore, what }: { depth: number; hasMore: boolean; onLoadMore: () => void; what: string }) {
  if (!hasMore) return null;
  return (
    <button onClick={onLoadMore} style={{ paddingLeft: depth * 14 + 20 }}
      className="block py-0.5 text-[11px] text-accent hover:underline">Load more {what}</button>
  );
}
```

- [ ] **Step 4: Implement** `DeviceLevel.tsx`

```tsx
import { useCallback } from "react";
import { fetchFleetCameras, fetchFleetDisplays } from "../../data/api";
import type { DeviceScope } from "../../data/api";
import { useLevelList } from "../../hooks/useLevelList";
import { TreeRow, LoadMoreRow } from "./TreeRow";
import type { FleetObjectType } from "../../data/apiTypes";

export interface Selection { type: FleetObjectType; id: string; }

export function DeviceLevel({ scope, depth, selectedId, onSelect, refreshToken }: {
  scope: DeviceScope; depth: number; selectedId: string | null;
  onSelect: (sel: Selection) => void; refreshToken: number;
}) {
  const cams = useLevelList(useCallback((cursor?: string) => fetchFleetCameras(scope, { cursor }),
    [scope.system_id, scope.screen_group_id]), refreshToken);
  const disps = useLevelList(useCallback((cursor?: string) => fetchFleetDisplays(scope, { cursor }),
    [scope.system_id, scope.screen_group_id]), refreshToken);
  return (
    <div>
      {cams.items.map((c) => (
        <TreeRow key={c.id} depth={depth} label={c.name ?? c.id.slice(0, 8)} status={c.status}
          meta={`${c.camera_role} · ${c.effective_duty}`} selected={selectedId === c.id}
          onSelect={() => onSelect({ type: "camera", id: c.id })} testId={`tree-camera-${c.id}`} />
      ))}
      <LoadMoreRow depth={depth} hasMore={cams.hasMore} onLoadMore={cams.loadMore} what="cameras" />
      {disps.items.map((d) => (
        <TreeRow key={d.id} depth={depth} label={d.name ?? d.screen_id} status={d.status}
          meta={d.screen_id} selected={selectedId === d.id}
          onSelect={() => onSelect({ type: "display", id: d.id })} testId={`tree-display-${d.id}`} />
      ))}
      <LoadMoreRow depth={depth} hasMore={disps.hasMore} onLoadMore={disps.loadMore} what="displays" />
    </div>
  );
}
```

Note: `DeviceScope` must be exported from `api.ts` (it is, Task 1). Ungrouped devices at system level: Plan A's `?system_id=` scope is assumed to return ALL of the system's devices; the tree therefore shows groups first and a "Devices" section listing the system-scoped fetch. If Plan A adds an `ungrouped_only` param, adopt it here (Task 0 reconciliation).

- [ ] **Step 5:** Run `npm test -- src/components/fleet/DeviceLevel.test.tsx` — Expected: PASS. Then `npm run lint`.
- [ ] **Step 6 (git-flow-manager):** commit `feat: TreeRow/LoadMoreRow primitives + DeviceLevel`

---

### Task 5: `GroupLevel` + `SystemLevel`

**Files:**
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/GroupLevel.tsx`
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/SystemLevel.tsx`
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/SystemLevel.test.tsx`

**Interfaces:**
- `GroupLevel({ systemId, depth, selectedId, onSelect, refreshToken })` — screen-group rows; expanding a group renders `DeviceLevel({ screen_group_id })`.
- `SystemLevel({ locationId, depth, selectedId, onSelect, refreshToken })` — system rows; expanding renders `GroupLevel` + a "Devices" heading + `DeviceLevel({ system_id })`.

- [ ] **Step 1: Write the failing tests** (`SystemLevel.test.tsx`) — mock `../../data/api` (`fetchFleetSystems`, `fetchFleetScreenGroups`, `fetchFleetCameras`, `fetchFleetDisplays`); assert: systems render lazily (groups NOT fetched before expand); clicking the caret fetches groups + devices for that system; clicking a group caret fetches group-scoped devices; clicking a system name calls `onSelect({ type: "system", id })`.

```tsx
import { describe, expect, it, vi, beforeEach } from "vitest";
import { render, screen, waitFor, fireEvent } from "@testing-library/react";
import { SystemLevel } from "./SystemLevel";
import { fetchFleetScreenGroups, fetchFleetCameras } from "../../data/api";

vi.mock("../../data/api", () => ({
  fetchFleetSystems: vi.fn().mockResolvedValue({
    counts: { total: 1 },
    items: [{ id: "s1", name: "Bay 2", system_type: "onsite_mras", status: "active", device_count: 3 }],
    next_cursor: null,
  }),
  fetchFleetScreenGroups: vi.fn().mockResolvedValue({
    counts: { total: 1 },
    items: [{ id: "g1", name: "North Zone", group_type: "zone", status: "active", device_count: 2 }],
    next_cursor: null,
  }),
  fetchFleetCameras: vi.fn().mockResolvedValue({ counts: { total: 0 }, items: [], next_cursor: null }),
  fetchFleetDisplays: vi.fn().mockResolvedValue({ counts: { total: 0 }, items: [], next_cursor: null }),
}));

describe("SystemLevel", () => {
  beforeEach(() => vi.clearAllMocks());

  it("is lazy: groups are not fetched until a system is expanded", async () => {
    render(<SystemLevel locationId="l1" depth={1} selectedId={null} onSelect={() => {}} refreshToken={0} />);
    await waitFor(() => expect(screen.getByText("Bay 2")).toBeInTheDocument());
    expect(vi.mocked(fetchFleetScreenGroups)).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: /expand Bay 2/i }));
    await waitFor(() => expect(screen.getByText("North Zone")).toBeInTheDocument());
    expect(vi.mocked(fetchFleetScreenGroups)).toHaveBeenCalledWith("s1", expect.anything());
    expect(vi.mocked(fetchFleetCameras)).toHaveBeenCalledWith({ system_id: "s1" }, expect.anything());
  });

  it("expanding a group fetches group-scoped devices; selecting a system reports it", async () => {
    const onSelect = vi.fn();
    render(<SystemLevel locationId="l1" depth={1} selectedId={null} onSelect={onSelect} refreshToken={0} />);
    await waitFor(() => expect(screen.getByText("Bay 2")).toBeInTheDocument());
    fireEvent.click(screen.getByText("Bay 2"));
    expect(onSelect).toHaveBeenCalledWith({ type: "system", id: "s1" });
    fireEvent.click(screen.getByRole("button", { name: /expand Bay 2/i }));
    await waitFor(() => expect(screen.getByText("North Zone")).toBeInTheDocument());
    fireEvent.click(screen.getByRole("button", { name: /expand North Zone/i }));
    await waitFor(() => expect(vi.mocked(fetchFleetCameras)).toHaveBeenCalledWith({ screen_group_id: "g1" }, expect.anything()));
  });
});
```

Run — Expected: FAIL. **Step 2 (git-flow-manager):** commit `test: SystemLevel/GroupLevel lazy expansion`

- [ ] **Step 3: Implement** `GroupLevel.tsx`

```tsx
import { useCallback, useState } from "react";
import { fetchFleetScreenGroups } from "../../data/api";
import { useLevelList } from "../../hooks/useLevelList";
import { TreeRow, LoadMoreRow } from "./TreeRow";
import { DeviceLevel, type Selection } from "./DeviceLevel";

export function GroupLevel({ systemId, depth, selectedId, onSelect, refreshToken }: {
  systemId: string; depth: number; selectedId: string | null; onSelect: (sel: Selection) => void; refreshToken: number;
}) {
  const groups = useLevelList(useCallback((cursor?: string) => fetchFleetScreenGroups(systemId, { cursor }), [systemId]), refreshToken);
  const [openIds, setOpenIds] = useState<Set<string>>(new Set());
  const toggle = (id: string) => setOpenIds((s) => { const n = new Set(s); n.has(id) ? n.delete(id) : n.add(id); return n; });
  return (
    <div>
      {groups.items.map((g) => (
        <div key={g.id}>
          <TreeRow depth={depth} label={g.name} meta={g.group_type} status={g.status} statusKind="lifecycle"
            selected={selectedId === g.id} expandable expanded={openIds.has(g.id)}
            onToggle={() => toggle(g.id)} onSelect={() => onSelect({ type: "screen_group", id: g.id })} />
          {openIds.has(g.id) && (
            <DeviceLevel scope={{ screen_group_id: g.id }} depth={depth + 1}
              selectedId={selectedId} onSelect={onSelect} refreshToken={refreshToken} />
          )}
        </div>
      ))}
      <LoadMoreRow depth={depth} hasMore={groups.hasMore} onLoadMore={groups.loadMore} what="groups" />
    </div>
  );
}
```

- [ ] **Step 4: Implement** `SystemLevel.tsx` — same expansion pattern: `useLevelList(fetchFleetSystems(locationId))`; each expanded system renders `<GroupLevel systemId ... depth={depth+1} />`, then a faint "devices" divider row, then `<DeviceLevel scope={{ system_id }} depth={depth+1} />`. System row: `meta={`${s.system_type} · ${s.device_count} devices`}`, `statusKind="lifecycle"`, `onSelect({ type: "system", id })`. (P2 Task 13 adds "+ camera / + display" buttons on the expanded system — leave a `actions?: ReactNode` prop seam now: rendered right after the divider when provided. Plumb `deviceActions?: (systemId: string) => ReactNode` through props.)

- [ ] **Step 5:** Run `npm test -- src/components/fleet/SystemLevel.test.tsx` — Expected: PASS.
- [ ] **Step 6 (git-flow-manager):** commit `feat: SystemLevel + GroupLevel lazy tree levels`

---

### Task 6: `LocationLevel` — the lazy locations tree root

**Files:**
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/LocationLevel.tsx`
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/LocationLevel.test.tsx`

**Interfaces:** `LocationLevel({ parentId /* "root" | uuid */, depth, selectedId, onSelect, refreshToken, deviceActions? })`. Renders one level of `fetchLocationChildren(parentId)`; a location expands into (a) `LocationLevel(parentId=id)` when `child_location_count > 0` and (b) `SystemLevel(locationId=id)` when `system_count > 0`. Recursive — each level is its own bounded fetch (spec §6: "each level loads on expand").

- [ ] **Step 1: Write the failing tests** — mock api; fixture: root returns `[{ id: "l1", name: "California", location_type: "state", status: "active", child_location_count: 1, system_count: 0 }]`; child call (`parent_location_id: "l1"`) returns `[{ id: "l2", name: "Downtown LA", location_type: "venue", status: "active", child_location_count: 0, system_count: 2 }]`. Assert: root renders without fetching children; expanding California calls `fetchLocationChildren("l1", …)` and renders Downtown LA; Downtown LA's expansion renders a SystemLevel fetch (`fetchFleetSystems("l2", …)`); selecting a location row calls `onSelect({ type: "location", id })`. Run — FAIL.
- [ ] **Step 2 (git-flow-manager):** commit `test: LocationLevel recursive lazy tree`
- [ ] **Step 3: Implement** — same shape as `GroupLevel` (openIds set, caret only when `child_location_count + system_count > 0`, `meta={location_type}`, `statusKind="lifecycle"`); expanded node renders `LocationLevel(parentId=id, depth+1)` if `child_location_count > 0`, then `SystemLevel(locationId=id, depth+1)` if `system_count > 0`.
- [ ] **Step 4:** Run tests — PASS. `npm run lint`.
- [ ] **Step 5 (git-flow-manager):** commit `feat: LocationLevel recursive lazy locations tree`

---

### Task 7: Drawer building blocks — `IdentityBlock`, `ConfigSection` (read-only), `StatePanel` (polled), `HistoryList`

**Files:**
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/IdentityBlock.tsx`
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/ConfigSection.tsx`
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/StatePanel.tsx`
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/StatePanel.test.tsx`
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/HistoryList.tsx`
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/HistoryList.test.tsx`

- [ ] **Step 1: Write the failing tests**

`StatePanel.test.tsx` — mock `../../data/api` with `fetchObjectDetail` resolving a camera detail whose `state` is `{ last_seen_at: <45s ago>, effective_duty: "watching", created_at: "…", updated_at: "…" }`. Assert: renders `watching`, a staleness label matching `/seen \d+s ago/`, and the D15 convergence copy (`/converge on the device's next poll/i`); uses `usePolling` (assert `fetchObjectDetail` called once on mount — interval behavior is already covered by `usePolling.test.ts`).

`HistoryList.test.tsx` — mock `fetchObjectAudit` with one `registry_admin` and one `camera_duty` item (Task 3 fixture shapes). Assert both summaries render, header says "History", and `fetchObjectAudit` was called with `("cam1", 20)` (D13: latest 20).

Run — Expected: FAIL. **Step 2 (git-flow-manager):** commit `test: StatePanel (polled, D15 copy) + HistoryList (latest 20, both event types)`

- [ ] **Step 3: Implement** `IdentityBlock.tsx` (D2 — pure render, no test needed beyond drawer test)

```tsx
export function IdentityBlock({ identity }: { identity: Record<string, string | null> }) {
  return (
    <section data-testid="identity-block" className="mb-4">
      <h3 className="text-[11px] uppercase tracking-wider text-faint mb-1">Identity · immutable</h3>
      <dl className="bg-elev2 border border-borderSoft rounded-md p-2 font-mono text-[11px]">
        {Object.entries(identity).map(([k, v]) => (
          <div key={k} className="flex gap-2 py-0.5">
            <dt className="text-faint w-40 shrink-0">{k}</dt>
            <dd className="text-dim truncate">{v ?? "—"}</dd>
          </div>
        ))}
      </dl>
    </section>
  );
}
```

- [ ] **Step 4: Implement** `ConfigSection.tsx` (P1 read-only; Task 13 swaps in forms for camera/display)

```tsx
import { configEntries } from "../../data/fleetSelectors";
import type { ObjectDetail } from "../../data/apiTypes";

export function ConfigSection({ detail }: { detail: ObjectDetail }) {
  return (
    <section data-testid="config-section" className="mb-4">
      <h3 className="text-[11px] uppercase tracking-wider text-faint mb-1">Config · admin truth</h3>
      <dl className="border border-border rounded-md p-2 text-[12px]">
        {configEntries(detail).map((e) => (
          <div key={e.key} className="flex gap-2 py-0.5">
            <dt className="text-dim w-40 shrink-0">{e.key}</dt>
            <dd className="font-mono text-[11px] truncate">{e.value}</dd>
          </div>
        ))}
      </dl>
    </section>
  );
}
```

- [ ] **Step 5: Implement** `StatePanel.tsx` — the ONLY polled piece (D13/D15)

```tsx
import { useCallback } from "react";
import { usePolling } from "../../hooks/usePolling";
import { fetchObjectDetail } from "../../data/api";
import { stalenessOf } from "../../data/fleetSelectors";
import type { FleetObjectType } from "../../data/apiTypes";

const TONE_TEXT = { ok: "text-ok", warn: "text-warn", crit: "text-crit" } as const;

export function StatePanel({ type, id }: { type: FleetObjectType; id: string }) {
  const { data } = usePolling(useCallback(() => fetchObjectDetail(type, id), [type, id]), 5000);
  const st = data?.state;
  const staleness = stalenessOf(st?.last_seen_at ?? null);
  return (
    <section data-testid="state-panel" className="mb-4">
      <h3 className="text-[11px] uppercase tracking-wider text-faint mb-1">State · runtime truth (read-only)</h3>
      <div className="border border-border rounded-md p-2 text-[12px]">
        {(type === "camera" || type === "display") && (
          <div className="flex gap-2 py-0.5">
            <span className="text-dim w-40 shrink-0">last_seen</span>
            <span className={`font-mono text-[11px] ${TONE_TEXT[staleness.tone]}`}>{staleness.label}</span>
          </div>
        )}
        {type === "camera" && (
          <div className="flex gap-2 py-0.5">
            <span className="text-dim w-40 shrink-0">effective_duty</span>
            <span className="font-mono text-[11px]">{st?.effective_duty ?? "unknown"}</span>
          </div>
        )}
        <div className="flex gap-2 py-0.5">
          <span className="text-dim w-40 shrink-0">updated_at</span>
          <span className="font-mono text-[11px]">{st?.updated_at ?? "—"}</span>
        </div>
        <p className="mt-1 text-[10.5px] text-faint">
          Config changes converge on the device's next poll — a write here is not instantly live.
        </p>
      </div>
    </section>
  );
}
```

- [ ] **Step 6: Implement** `HistoryList.tsx` — fetch once per object + Refresh button (not polled)

```tsx
import { useCallback, useEffect, useState } from "react";
import { fetchObjectAudit } from "../../data/api";
import { historyRows, type HistoryRow } from "../../data/fleetSelectors";

export function HistoryList({ objectId, refreshToken }: { objectId: string; refreshToken: number }) {
  const [rows, setRows] = useState<HistoryRow[]>([]);
  const load = useCallback(() => {
    fetchObjectAudit(objectId, 20).then((p) => setRows(historyRows(p.items))).catch(() => {});
  }, [objectId]);
  useEffect(() => { load(); }, [load, refreshToken]);
  return (
    <section data-testid="history-list">
      <div className="flex items-center justify-between mb-1">
        <h3 className="text-[11px] uppercase tracking-wider text-faint">History · latest 20</h3>
        <button onClick={load} className="text-[11px] text-accent hover:underline">Refresh</button>
      </div>
      <table className="w-full text-[11px] border border-border rounded-md overflow-hidden">
        <tbody>
          {rows.map((r) => (
            <tr key={r.id} className="border-b border-borderSoft">
              <td className="px-2 py-1 font-mono text-faint whitespace-nowrap">{r.when.slice(0, 19).replace("T", " ")}</td>
              <td className="px-2 py-1 font-mono text-faint">{r.kind}</td>
              <td className="px-2 py-1 text-dim">{r.summary}</td>
            </tr>
          ))}
          {rows.length === 0 && <tr><td className="px-2 py-1 text-faint">no events</td></tr>}
        </tbody>
      </table>
    </section>
  );
}
```

- [ ] **Step 7:** Run `npm test -- src/components/fleet` — Expected: PASS.
- [ ] **Step 8 (git-flow-manager):** commit `feat: IdentityBlock, ConfigSection, StatePanel, HistoryList drawer sections`

---

### Task 8: `ObjectDrawer` + `Fleet` page + route + nav

**Files:**
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/ObjectDrawer.tsx`
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/ObjectDrawer.test.tsx`
- Create: `/Users/jn/code/godview-prototype/src/pages/Fleet.tsx`
- Create: `/Users/jn/code/godview-prototype/src/pages/Fleet.test.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/routes.tsx` (add `{ path: "/fleet", element: <Fleet /> }`)
- Modify: `/Users/jn/code/godview-prototype/src/components/Shell.tsx` (God View nav group gains `{ to: "/fleet", label: "Fleet" }` after "Systems & Logs")
- Modify: `/Users/jn/code/godview-prototype/src/components/Shell.test.tsx` (assert the Fleet link renders)

- [ ] **Step 1: Write the failing tests**

`ObjectDrawer.test.tsx` — mock `../../data/api` (`fetchObjectDetail` camera detail with identity `{ id, device_id, system_id, location_id, screen_id }`, config `{ name: "Cam A", camera_role: "detection", failover_eligible: true, screen_group_id: null, stream_url: null, calibration: {}, status: "active" }`; `fetchObjectAudit` empty). Assert: renders identity block with `screen_id` value, config section with `Cam A`, state panel, history list — the three D13 sections plus the D2 identity block; asserts NO `<input>` elements exist in P1 (`container.querySelectorAll("input").length === 0`).

`Fleet.test.tsx` — mock `../data/api` fully (all Task 1 fetchers + `fetchProjectorStatus` — REQUIRED because Fleet renders Shell). Root locations fixture → expand → select a camera → drawer appears. Assert: "Fleet" crumb, tree renders root location, clicking a camera row shows the drawer's config section.

Run — Expected: FAIL. **Step 2 (git-flow-manager):** commit `test: ObjectDrawer sections + Fleet page assembly (red)`

- [ ] **Step 3: Implement** `ObjectDrawer.tsx`

```tsx
import { useEffect, useState } from "react";
import { fetchObjectDetail } from "../../data/api";
import type { FleetObjectType, ObjectDetail } from "../../data/apiTypes";
import { IdentityBlock } from "./IdentityBlock";
import { ConfigSection } from "./ConfigSection";
import { StatePanel } from "./StatePanel";
import { HistoryList } from "./HistoryList";
import { StatusDot } from "../StatusDot";

export function ObjectDrawer({ type, id, onMutated }: {
  type: FleetObjectType; id: string;
  onMutated: () => void;    // P2: invalidate tree levels after a successful write
}) {
  const [detail, setDetail] = useState<ObjectDetail | null>(null);
  const [version, setVersion] = useState(0);      // bumped after every successful write -> refetch (D13: no optimistic updates)
  const [error, setError] = useState<Error | null>(null);

  useEffect(() => {
    let live = true;
    setError(null);
    fetchObjectDetail(type, id)
      .then((d) => { if (live) setDetail(d); })
      .catch((e) => { if (live) setError(e instanceof Error ? e : new Error(String(e))); });
    return () => { live = false; };
  }, [type, id, version]);

  if (error) return <div data-testid="drawer-error" className="text-crit text-[12px]">couldn't load {type} — {error.message}</div>;
  if (!detail) return <div data-testid="drawer-loading" className="text-faint text-[12px]">Loading…</div>;

  const name = String(detail.config.name ?? id.slice(0, 8));
  const status = String(detail.config.status ?? "");
  return (
    <div data-testid="object-drawer">
      <div className="flex items-center gap-2 mb-3">
        <StatusDot status={status} kind={type === "camera" || type === "display" ? "device" : "lifecycle"} />
        <h2 className="text-[14px] font-semibold truncate">{name}</h2>
        <span className="font-mono text-[10px] text-faint border border-border px-1.5 rounded">{detail.object_type}</span>
      </div>
      <IdentityBlock identity={detail.identity} />
      <ConfigSection detail={detail} />
      <StatePanel type={type} id={id} />
      <HistoryList objectId={id} refreshToken={version} />
    </div>
  );
}
```

(Unused-in-P1 `onMutated` + `setVersion`: wire `const saved = () => { setVersion(v => v + 1); onMutated(); };` now and pass `saved` down from Task 13's forms; until then reference them via the P2 seam or omit `onMutated` from destructuring to keep lint clean — implementer's choice, note it in the journal.)

- [ ] **Step 4: Implement** `Fleet.tsx`

```tsx
import { useState } from "react";
import { Shell } from "../components/Shell";
import { LocationLevel } from "../components/fleet/LocationLevel";
import { ObjectDrawer } from "../components/fleet/ObjectDrawer";
import type { Selection } from "../components/fleet/DeviceLevel";

export function Fleet() {
  const [selected, setSelected] = useState<Selection | null>(null);
  const [treeVersion, setTreeVersion] = useState(0);   // bump -> expanded levels reload (write invalidation)
  return (
    <Shell crumb="Fleet">
      <h1 className="text-[18px] font-semibold mb-4">Fleet</h1>
      <div className="grid grid-cols-[minmax(280px,1fr)_minmax(360px,480px)] gap-4 items-start">
        <div className="border border-border rounded-[10px] p-2 min-h-[400px]">
          <LocationLevel parentId="root" depth={0} selectedId={selected?.id ?? null}
            onSelect={setSelected} refreshToken={treeVersion} />
        </div>
        <div className="border border-border rounded-[10px] p-3 min-h-[400px]">
          {selected
            ? <ObjectDrawer type={selected.type} id={selected.id} onMutated={() => setTreeVersion((v) => v + 1)} />
            : <div className="text-faint text-[12px]">Select a location, system, group, or device.</div>}
        </div>
      </div>
    </Shell>
  );
}
```

- [ ] **Step 5:** Wire `routes.tsx` + `Shell.tsx` nav + extend `Shell.test.tsx` (`expect(screen.getByText("Fleet")).toBeInTheDocument();`).
- [ ] **Step 6:** Run full `npm test` && `npm run lint` && `npm run build` — Expected: all green. **P1 is shippable here** (replaces "psql to see what exists").
- [ ] **Step 7 (git-flow-manager):** commit `feat: Fleet page — lazy hierarchy browser + read-only object drawer (/fleet)`

---

## Phase 2 — device writes (cameras + displays)

### Task 9: Write-path plumbing — `ApiError`, `sendJson`, write fetchers, 422/409 selectors

The app's FIRST write path. Design: fetchers throw a typed `ApiError` carrying `{ status, detail }`; selectors translate that into form-consumable structures. No optimistic updates anywhere (D13).

**Files:**
- Modify: `/Users/jn/code/godview-prototype/src/data/api.ts`
- Modify: `/Users/jn/code/godview-prototype/src/data/apiTypes.ts`
- Modify: `/Users/jn/code/godview-prototype/src/data/api.test.ts`
- Modify: `/Users/jn/code/godview-prototype/src/data/fleetSelectors.ts`
- Modify: `/Users/jn/code/godview-prototype/src/data/fleetSelectors.test.ts`

- [ ] **Step 1: Write the failing tests**

Append to `api.test.ts`:

```ts
import { ApiError, patchCameraConfig, createDisplay } from "./api";

describe("fleet api (P2 writes)", () => {
  it("patchCameraConfig PATCHes JSON and returns on 200", async () => {
    const spy = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ id: "c1" }), { status: 200 }));
    await patchCameraConfig("c1", { name: "New", failover_eligible: true });
    const [url, init] = spy.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("http://localhost:8080/cameras/c1");
    expect(init.method).toBe("PATCH");
    expect(init.headers).toMatchObject({ "content-type": "application/json" });
    expect(JSON.parse(init.body as string)).toEqual({ name: "New", failover_eligible: true });
  });

  it("throws ApiError with parsed detail on 422", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(
      JSON.stringify({ detail: [{ loc: ["body", "camera_role"], msg: "invalid", type: "literal_error" }] }),
      { status: 422 }));
    const err = await patchCameraConfig("c1", { name: "x" }).catch((e) => e);
    expect(err).toBeInstanceOf(ApiError);
    expect(err.status).toBe(422);
    expect(err.detail[0].loc).toContain("camera_role");
  });

  it("throws ApiError with null detail on a non-JSON error body", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("<html>bad gateway</html>", { status: 502 }));
    const err = await createDisplay({ system_id: "s1", screen_id: "d-9" }).catch((e) => e);
    expect(err).toBeInstanceOf(ApiError);
    expect(err.status).toBe(502);
    expect(err.detail).toBeNull();
  });
});
```

Append to `fleetSelectors.test.ts`:

```ts
import { ApiError } from "./api";
import { fieldErrorsFrom422, conflictFrom409 } from "./fleetSelectors";

describe("fieldErrorsFrom422", () => {
  it("maps pydantic detail[] to per-field messages (E1)", () => {
    const err = new ApiError("/cameras/c1", 422, [
      { loc: ["body", "camera_role"], msg: "not a valid camera_role", type: "literal_error" },
      { loc: ["body", "resolution_width"], msg: "value is not a valid integer", type: "int_parsing" },
    ]);
    expect(fieldErrorsFrom422(err)).toEqual({
      fields: { camera_role: "not a valid camera_role", resolution_width: "value is not a valid integer" },
      form: null,
    });
  });
  it("maps a string detail to a form-level error (E2 semantic 422)", () => {
    const err = new ApiError("/cameras/c1", 422, "screen_group must belong to the same system");
    expect(fieldErrorsFrom422(err)).toEqual({ fields: {}, form: "screen_group must belong to the same system" });
  });
  it("returns null for non-422 / non-ApiError", () => {
    expect(fieldErrorsFrom422(new Error("x"))).toBeNull();
    expect(fieldErrorsFrom422(new ApiError("/x", 409, {}))).toBeNull();
  });
});

describe("conflictFrom409", () => {
  it("extracts the lifecycle allowed set (E3, D3)", () => {
    const err = new ApiError("/cameras/c1", 409, { error: "invalid_transition", from: "retired", allowed: [] });
    expect(conflictFrom409(err)).toEqual({ message: "invalid_transition", from: "retired", allowed: [], blockers: [] });
  });
  it("extracts retire blockers (E4, D5)", () => {
    const err = new ApiError("/screen-groups/g1", 409, {
      error: "retire_blocked",
      blockers: [{ type: "display", id: "d1", name: "Kiosk 1", status: "active" }],
    });
    expect(conflictFrom409(err)?.blockers).toHaveLength(1);
  });
  it("degrades a string detail to message-only", () => {
    expect(conflictFrom409(new ApiError("/x", 409, "conflict happened")))
      .toEqual({ message: "conflict happened", from: null, allowed: [], blockers: [] });
  });
});
```

Run — Expected: FAIL. **Step 2 (git-flow-manager):** commit `test: ApiError write path + 422 field mapping + 409 conflict extraction`

- [ ] **Step 3: Implement in `api.ts`**

```ts
/** Thrown by write fetchers on !res.ok — carries the parsed FastAPI `detail` for the form layer. */
export class ApiError extends Error {
  readonly status: number;
  readonly detail: unknown;
  constructor(path: string, status: number, detail: unknown) {
    super(`${path} -> ${status}`);
    this.name = "ApiError";
    this.status = status;
    this.detail = detail;
  }
}

async function sendJson<T>(method: "POST" | "PATCH", path: string, body: unknown): Promise<T> {
  const res = await fetch(`${OPS_API}${path}`, {
    method,
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    let detail: unknown = null;
    try { detail = ((await res.json()) as { detail?: unknown }).detail ?? null; } catch { detail = null; }
    throw new ApiError(path, res.status, detail);
  }
  return (await res.json()) as T;
}

// Write responses: the UI depends ONLY on ok + id (creates). Detail is refetched via fetchObjectDetail (D13).
export const patchCameraConfig = (id: string, patch: CameraConfigPatch) =>
  sendJson<{ id: string }>("PATCH", `/cameras/${id}`, patch);
export const patchDisplayConfig = (id: string, patch: DisplayConfigPatch) =>
  sendJson<{ id: string }>("PATCH", `/displays/${id}`, patch);
export const createCamera = (body: CameraCreate) => sendJson<{ id: string }>("POST", "/cameras", body);
export const createDisplay = (body: DisplayCreate) => sendJson<{ id: string }>("POST", "/displays", body);
```

And in `apiTypes.ts` (D2: NO identity fields in patch types — unrepresentable, not just unsent):

```ts
// Write bodies (config-class fields only, spec §5.1). status rides the same PATCH but is sent
// ONLY by the LifecycleControl (D3). resolution/cam_index are raw pass-through strings when the
// user types a non-number — the SERVER owns validation; a 422 comes back to the field (D13).
export interface CameraConfigPatch {
  name?: string | null; camera_role?: string; status?: string; failover_eligible?: boolean;
  screen_group_id?: string | null; stream_url?: string | null; calibration?: Record<string, unknown>;
}
export interface DisplayConfigPatch {
  name?: string | null; display_role?: string; status?: string; screen_group_id?: string | null;
  resolution_width?: number | string | null; resolution_height?: number | string | null;
  calibration?: Record<string, unknown>;
}
export interface CameraCreate {
  system_id: string; screen_id?: string; name?: string; camera_role?: string;
  screen_group_id?: string | null; stream_url?: string; calibration?: Record<string, unknown>;
  failover_eligible?: boolean;
}
export interface DisplayCreate {
  system_id: string; screen_id: string; name?: string; display_role?: string;
  screen_group_id?: string | null; resolution_width?: number | string; resolution_height?: number | string;
}
```

- [ ] **Step 4: Implement in `fleetSelectors.ts`**

```ts
import { ApiError } from "./api";

export interface FieldErrors { fields: Record<string, string>; form: string | null; }
/** E1/E2: pydantic detail[] -> per-field; string detail -> form-level. null when not a 422. */
export function fieldErrorsFrom422(err: unknown): FieldErrors | null {
  if (!(err instanceof ApiError) || err.status !== 422) return null;
  const d = err.detail;
  if (Array.isArray(d)) {
    const fields: Record<string, string> = {};
    for (const item of d as { loc?: unknown[]; msg?: unknown }[]) {
      const loc = Array.isArray(item.loc) ? item.loc : [];
      const field = String(loc[loc.length - 1] ?? "");
      if (field && field !== "body") fields[field] = String(item.msg ?? "invalid value");
    }
    if (Object.keys(fields).length > 0) return { fields, form: null };
  }
  return { fields: {}, form: typeof d === "string" ? d : "validation failed" };
}

export interface ConflictInfo {
  message: string; from: string | null; allowed: string[];
  blockers: { type: string; id: string; name: string | null; status: string }[];
}
/** E3/E4: lifecycle allowed-set and retire-blocker 409s. null when not a 409. */
export function conflictFrom409(err: unknown): ConflictInfo | null {
  if (!(err instanceof ApiError) || err.status !== 409) return null;
  const d = err.detail as Record<string, unknown> | string | null;
  if (d && typeof d === "object") {
    return {
      message: String((d as any).message ?? (d as any).error ?? "conflict"),
      from: (d as any).from != null ? String((d as any).from) : null,
      allowed: Array.isArray((d as any).allowed) ? (d as any).allowed.map(String) : [],
      blockers: Array.isArray((d as any).blockers) ? (d as any).blockers : [],
    };
  }
  return { message: typeof d === "string" ? d : "conflict", from: null, allowed: [], blockers: [] };
}
```

- [ ] **Step 5:** Run `npm test -- src/data` — Expected: PASS. `npm run lint`.
- [ ] **Step 6 (git-flow-manager):** commit `feat: ApiError + sendJson write path, device write fetchers, 422/409 selectors`

---

### Task 10: Form primitives — `FormField`, `JsonField` (D12), `LifecycleControl` (D3)

**Files:**
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/FormField.tsx`
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/JsonField.tsx`
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/JsonField.test.tsx`
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/LifecycleControl.tsx`
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/LifecycleControl.test.tsx`

- [ ] **Step 1: Write the failing tests**

`JsonField.test.tsx`: collapsed by default behind an "Advanced" disclosure (D12); expanding shows the textarea; typing `{"a":` shows "not valid JSON" and reports invalid via `onValidChange(false)`; typing `{"a": 1}` clears it and reports `true`.

`LifecycleControl.test.tsx`:

```tsx
import { describe, expect, it, vi } from "vitest";
import { render, screen, waitFor, fireEvent } from "@testing-library/react";
import { LifecycleControl } from "./LifecycleControl";
import { ApiError } from "../../data/api";

describe("LifecycleControl (D3)", () => {
  it("offers all non-current statuses and applies the chosen transition", async () => {
    const onApply = vi.fn().mockResolvedValue(undefined);
    render(<LifecycleControl current="offline" onApply={onApply} />);
    const select = screen.getByLabelText(/transition to/i);
    expect([...select.querySelectorAll("option")].map((o) => o.textContent))
      .toEqual(["choose…", "active", "degraded", "retired"]);   // no 'offline' (current)
    fireEvent.change(select, { target: { value: "active" } });
    fireEvent.click(screen.getByRole("button", { name: /apply/i }));
    await waitFor(() => expect(onApply).toHaveBeenCalledWith("active"));
  });

  it("renders the 409 allowed set verbatim (terminal retired -> empty set)", async () => {
    const onApply = vi.fn().mockRejectedValue(
      new ApiError("/cameras/c1", 409, { error: "invalid_transition", from: "retired", allowed: [] }));
    render(<LifecycleControl current="retired" onApply={onApply} />);
    fireEvent.change(screen.getByLabelText(/transition to/i), { target: { value: "active" } });
    fireEvent.click(screen.getByRole("button", { name: /apply/i }));
    await waitFor(() => expect(screen.getByTestId("lifecycle-conflict")).toBeInTheDocument());
    expect(screen.getByTestId("lifecycle-conflict").textContent)
      .toContain("none — terminal state");
  });

  it("renders 409 blockers when present", async () => {
    const onApply = vi.fn().mockRejectedValue(new ApiError("/displays/d1", 409, {
      error: "retire_blocked", blockers: [{ type: "display", id: "d9", name: "Kiosk 9", status: "active" }] }));
    render(<LifecycleControl current="active" onApply={onApply} />);
    fireEvent.change(screen.getByLabelText(/transition to/i), { target: { value: "retired" } });
    fireEvent.click(screen.getByRole("button", { name: /apply/i }));
    await waitFor(() => expect(screen.getByText(/Kiosk 9/)).toBeInTheDocument());
  });
});
```

Run — FAIL. **Step 2 (git-flow-manager):** commit `test: JsonField Advanced disclosure + LifecycleControl 409 allowed-set`

- [ ] **Step 3: Implement** `FormField.tsx`

```tsx
import type { ReactNode } from "react";

export function FormField({ name, label, error, children }: {
  name: string; label: string; error?: string; children: ReactNode;
}) {
  return (
    <label className="block mb-2 text-[12px]">
      <span className="block text-dim mb-0.5">{label}</span>
      {children}
      {error && <span data-testid={`field-error-${name}`} className="block text-crit text-[11px] mt-0.5">{error}</span>}
    </label>
  );
}

export const inputClass = "w-full bg-elev border border-border rounded-md px-2 py-1 text-[12px]";
```

- [ ] **Step 4: Implement** `JsonField.tsx` (D12 — parse-only validation, Advanced-gated)

```tsx
import { useMemo, useState } from "react";

export function JsonField({ name, label, value, onChange, onValidChange, serverError }: {
  name: string; label: string; value: string;
  onChange: (v: string) => void; onValidChange?: (ok: boolean) => void; serverError?: string;
}) {
  const [open, setOpen] = useState(false);
  const parseError = useMemo(() => {
    if (!value.trim()) return null;
    try { JSON.parse(value); return null; } catch { return "not valid JSON"; }
  }, [value]);
  const err = parseError ?? serverError;
  return (
    <div className="mb-2">
      <button type="button" onClick={() => setOpen(!open)} className="text-[11px] text-faint hover:text-dim">
        {open ? "▾" : "▸"} Advanced: {label} (raw JSON)
      </button>
      {open && (
        <>
          <textarea data-testid={`json-${name}`} value={value} rows={6}
            onChange={(e) => { onChange(e.target.value); onValidChange?.(isParseable(e.target.value)); }}
            className="mt-1 w-full font-mono text-[11px] bg-elev border border-border rounded-md p-2" />
          {err && <span data-testid={`field-error-${name}`} className="block text-crit text-[11px]">{err}</span>}
        </>
      )}
    </div>
  );
}

function isParseable(v: string): boolean {
  if (!v.trim()) return true;
  try { JSON.parse(v); return true; } catch { return false; }
}
```

- [ ] **Step 5: Implement** `LifecycleControl.tsx`

```tsx
import { useState } from "react";
import { DEVICE_STATUSES, conflictFrom409, type ConflictInfo } from "../../data/fleetSelectors";
import { inputClass } from "./FormField";

/** D3: transitions ride the config PATCH but get their own control; server owns the matrix. */
export function LifecycleControl({ current, onApply }: { current: string; onApply: (next: string) => Promise<void> }) {
  const [next, setNext] = useState("");
  const [conflict, setConflict] = useState<ConflictInfo | null>(null);
  const [busy, setBusy] = useState(false);
  const apply = async () => {
    if (!next) return;
    setBusy(true); setConflict(null);
    try { await onApply(next); setNext(""); }
    catch (e) {
      const c = conflictFrom409(e);
      setConflict(c ?? { message: e instanceof Error ? e.message : String(e), from: null, allowed: [], blockers: [] });
    } finally { setBusy(false); }
  };
  return (
    <section className="mb-4">
      <h3 className="text-[11px] uppercase tracking-wider text-faint mb-1">Lifecycle</h3>
      <div className="flex items-center gap-2">
        <span className="font-mono text-[12px]">{current}</span>
        <span className="text-faint text-[12px]">→</span>
        <label className="sr-only" htmlFor="lifecycle-next">transition to</label>
        <select id="lifecycle-next" aria-label="transition to" value={next}
          onChange={(e) => setNext(e.target.value)} className={inputClass + " w-36"}>
          <option value="">choose…</option>
          {DEVICE_STATUSES.filter((s) => s !== current).map((s) => <option key={s} value={s}>{s}</option>)}
        </select>
        <button onClick={apply} disabled={busy || !next}
          className="bg-elev border border-border rounded-md px-3 py-1 text-[12px] hover:border-accent/40 disabled:opacity-50">
          Apply
        </button>
      </div>
      {conflict && (
        <div data-testid="lifecycle-conflict" className="mt-2 px-2 py-1.5 rounded-md bg-warn/10 border border-warn/30 text-warn text-[11.5px]">
          <div>Transition rejected ({conflict.message}). Allowed from '{conflict.from ?? current}': {conflict.allowed.length ? conflict.allowed.join(", ") : "none — terminal state"}.</div>
          {conflict.blockers.length > 0 && (
            <ul className="mt-1 list-disc pl-4">
              {conflict.blockers.map((b) => <li key={b.id}>{b.type} "{b.name ?? b.id}" is {b.status}</li>)}
            </ul>
          )}
        </div>
      )}
    </section>
  );
}
```

- [ ] **Step 6:** Run `npm test -- src/components/fleet` — PASS.
- [ ] **Step 7 (git-flow-manager):** commit `feat: FormField, JsonField (Advanced raw-JSON), LifecycleControl (409 allowed-set)`

---

### Task 11: `CameraConfigForm`

**Files:**
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/CameraConfigForm.tsx`
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/CameraConfigForm.test.tsx`

- [ ] **Step 1: Write the failing tests** — mock `../../data/api` (`patchCameraConfig`, and keep `ApiError` REAL via `importOriginal`):

```tsx
import { describe, expect, it, vi, beforeEach } from "vitest";
import { render, screen, waitFor, fireEvent } from "@testing-library/react";
import { CameraConfigForm } from "./CameraConfigForm";
import { patchCameraConfig, ApiError } from "../../data/api";
import type { ObjectDetail } from "../../data/apiTypes";

vi.mock("../../data/api", async (importOriginal) => {
  const mod = await importOriginal<typeof import("../../data/api")>();
  return { ...mod, patchCameraConfig: vi.fn().mockResolvedValue({ id: "c1" }) };
});

const detail: ObjectDetail = {
  object_type: "camera",
  identity: { id: "c1", device_id: "dev1", system_id: "s1", location_id: "l1", screen_id: "screen_0" },
  config: { name: "Cam A", camera_role: "detection", failover_eligible: false, screen_group_id: null,
            stream_url: null, calibration: { cam_index: 0 }, status: "active" },
  state: { last_seen_at: null, effective_duty: "unknown" },
};
const groups = [{ id: "g1", name: "North Zone" }];

describe("CameraConfigForm", () => {
  beforeEach(() => vi.mocked(patchCameraConfig).mockClear());

  it("D2: renders NO inputs for identity fields (screen_id/system_id/device_id)", () => {
    render(<CameraConfigForm id="c1" detail={detail} groups={groups} onSaved={() => {}} />);
    expect(screen.queryByLabelText(/screen_id/i)).toBeNull();
    expect(screen.queryByLabelText(/system_id/i)).toBeNull();
    expect(screen.queryByLabelText(/device_id/i)).toBeNull();
  });

  it("submits ONLY config fields, with typed cam_index merged into calibration (D12), then reports saved", async () => {
    const onSaved = vi.fn();
    render(<CameraConfigForm id="c1" detail={detail} groups={groups} onSaved={onSaved} />);
    fireEvent.change(screen.getByLabelText("name"), { target: { value: "Cam A2" } });
    fireEvent.change(screen.getByLabelText("cam_index"), { target: { value: "3" } });
    fireEvent.click(screen.getByRole("checkbox", { name: /failover_eligible/i }));
    fireEvent.click(screen.getByRole("button", { name: /save/i }));
    await waitFor(() => expect(patchCameraConfig).toHaveBeenCalledTimes(1));
    expect(vi.mocked(patchCameraConfig).mock.calls[0]).toEqual(["c1", {
      name: "Cam A2", camera_role: "detection", failover_eligible: true,
      screen_group_id: null, stream_url: null, calibration: { cam_index: 3 },
    }]);   // no status (LifecycleControl owns it, D3), no identity (D2), no state (D1)
    expect(onSaved).toHaveBeenCalled();   // refetch detail + invalidate level (D13)
  });

  it("maps a 422 into a field-level error", async () => {
    vi.mocked(patchCameraConfig).mockRejectedValueOnce(new ApiError("/cameras/c1", 422,
      [{ loc: ["body", "stream_url"], msg: "invalid url", type: "value_error" }]));
    render(<CameraConfigForm id="c1" detail={detail} groups={groups} onSaved={() => {}} />);
    fireEvent.click(screen.getByRole("button", { name: /save/i }));
    await waitFor(() => expect(screen.getByTestId("field-error-stream_url")).toHaveTextContent("invalid url"));
  });

  it("renders a 409 conflict block (D6 cross-system group as string, or structured)", async () => {
    vi.mocked(patchCameraConfig).mockRejectedValueOnce(new ApiError("/cameras/c1", 409,
      { error: "invalid_transition", from: "active", allowed: ["offline", "degraded", "retired"] }));
    render(<CameraConfigForm id="c1" detail={detail} groups={groups} onSaved={() => {}} />);
    fireEvent.click(screen.getByRole("button", { name: /save/i }));
    await waitFor(() => expect(screen.getByTestId("form-conflict")).toHaveTextContent(/offline, degraded, retired/));
  });

  it("blocks submit on a non-integer cam_index (client-side, the one typed field)", async () => {
    render(<CameraConfigForm id="c1" detail={detail} groups={groups} onSaved={() => {}} />);
    fireEvent.change(screen.getByLabelText("cam_index"), { target: { value: "abc" } });
    fireEvent.click(screen.getByRole("button", { name: /save/i }));
    await waitFor(() => expect(screen.getByTestId("field-error-cam_index")).toHaveTextContent(/integer/));
    expect(patchCameraConfig).not.toHaveBeenCalled();
  });
});
```

Run — FAIL. **Step 2 (git-flow-manager):** commit `test: CameraConfigForm submit/422/409/identity-lockout`

- [ ] **Step 3: Implement** `CameraConfigForm.tsx`

```tsx
import { useState, type FormEvent } from "react";
import { patchCameraConfig } from "../../data/api";
import type { ObjectDetail } from "../../data/apiTypes";
import { CAMERA_ROLES, fieldErrorsFrom422, conflictFrom409, type FieldErrors, type ConflictInfo } from "../../data/fleetSelectors";
import { FormField, inputClass } from "./FormField";
import { JsonField } from "./JsonField";
import { ConflictBlock } from "./ConflictBlock";

export function CameraConfigForm({ id, detail, groups, onSaved }: {
  id: string; detail: ObjectDetail;
  groups: { id: string; name: string }[];   // SAME-SYSTEM groups only (D6) — caller fetches them
  onSaved: () => void;                      // drawer refetch + tree invalidation (D13: no optimistic updates)
}) {
  const cfg = detail.config as Record<string, unknown>;
  const calib = (cfg.calibration ?? {}) as Record<string, unknown>;
  const [name, setName] = useState(String(cfg.name ?? ""));
  const [role, setRole] = useState(String(cfg.camera_role ?? "detection"));
  const [failover, setFailover] = useState(Boolean(cfg.failover_eligible));
  const [groupId, setGroupId] = useState(cfg.screen_group_id == null ? "" : String(cfg.screen_group_id));
  const [streamUrl, setStreamUrl] = useState(cfg.stream_url == null ? "" : String(cfg.stream_url));
  const [camIndex, setCamIndex] = useState(calib.cam_index == null ? "" : String(calib.cam_index));  // D12 typed field
  const [calibJson, setCalibJson] = useState(JSON.stringify(calib, null, 2));
  const [jsonOk, setJsonOk] = useState(true);
  const [errors, setErrors] = useState<FieldErrors>({ fields: {}, form: null });
  const [conflict, setConflict] = useState<ConflictInfo | null>(null);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setErrors({ fields: {}, form: null }); setConflict(null); setSaved(false);
    if (camIndex !== "" && !Number.isInteger(Number(camIndex))) {
      setErrors({ fields: { cam_index: "must be an integer" }, form: null }); return;
    }
    let calibration: Record<string, unknown>;
    try { calibration = calibJson.trim() ? JSON.parse(calibJson) : {}; }
    catch { setErrors({ fields: { calibration: "not valid JSON" }, form: null }); return; }
    if (camIndex !== "") calibration = { ...calibration, cam_index: Number(camIndex) };
    else delete calibration.cam_index;
    setSaving(true);
    try {
      await patchCameraConfig(id, {
        name: name || null, camera_role: role, failover_eligible: failover,
        screen_group_id: groupId || null, stream_url: streamUrl || null, calibration,
      });
      setSaved(true);
      onSaved();
    } catch (err) {
      const fe = fieldErrorsFrom422(err);
      const c = conflictFrom409(err);
      if (fe) setErrors(fe);
      else if (c) setConflict(c);
      else setErrors({ fields: {}, form: err instanceof Error ? err.message : String(err) });
    } finally { setSaving(false); }
  };

  return (
    <form onSubmit={submit} data-testid="camera-config-form" className="mb-4">
      <h3 className="text-[11px] uppercase tracking-wider text-faint mb-1">Config · admin truth</h3>
      <FormField name="name" label="name" error={errors.fields.name}>
        <input aria-label="name" value={name} onChange={(e) => setName(e.target.value)} className={inputClass} />
      </FormField>
      <FormField name="camera_role" label="camera_role" error={errors.fields.camera_role}>
        <select aria-label="camera_role" value={role} onChange={(e) => setRole(e.target.value)} className={inputClass}>
          {CAMERA_ROLES.map((r) => <option key={r} value={r}>{r}</option>)}
        </select>
      </FormField>
      <FormField name="failover_eligible" label="failover_eligible" error={errors.fields.failover_eligible}>
        <input type="checkbox" aria-label="failover_eligible" checked={failover}
          onChange={(e) => setFailover(e.target.checked)} />
      </FormField>
      <FormField name="screen_group_id" label="screen_group (same system)" error={errors.fields.screen_group_id}>
        <select aria-label="screen_group (same system)" value={groupId}
          onChange={(e) => setGroupId(e.target.value)} className={inputClass}>
          <option value="">ungrouped</option>
          {groups.map((g) => <option key={g.id} value={g.id}>{g.name}</option>)}
        </select>
      </FormField>
      <FormField name="stream_url" label="stream_url" error={errors.fields.stream_url}>
        <input aria-label="stream_url" value={streamUrl} onChange={(e) => setStreamUrl(e.target.value)} className={inputClass} />
      </FormField>
      <FormField name="cam_index" label="cam_index" error={errors.fields.cam_index}>
        <input aria-label="cam_index" value={camIndex} onChange={(e) => setCamIndex(e.target.value)}
          className={inputClass + " w-24 font-mono"} />
      </FormField>
      <JsonField name="calibration" label="calibration" value={calibJson}
        onChange={setCalibJson} onValidChange={setJsonOk} serverError={errors.fields.calibration} />
      {errors.form && <div data-testid="form-error" className="mb-2 text-crit text-[11.5px]">{errors.form}</div>}
      {conflict && <ConflictBlock conflict={conflict} />}
      <div className="flex items-center gap-2">
        <button type="submit" disabled={saving || !jsonOk}
          className="bg-elev border border-border rounded-md px-3 py-1 text-[12px] hover:border-accent/40 disabled:opacity-50">
          Save
        </button>
        {saved && <span data-testid="saved-note" className="text-ok text-[11px]">saved — refreshing…</span>}
      </div>
    </form>
  );
}
```

Also create `ConflictBlock.tsx` (extracted so config forms and create forms share the 409 rendering; `LifecycleControl` keeps its inline variant with the current-status context):

```tsx
import type { ConflictInfo } from "../../data/fleetSelectors";

export function ConflictBlock({ conflict }: { conflict: ConflictInfo }) {
  return (
    <div data-testid="form-conflict" className="mb-2 px-2 py-1.5 rounded-md bg-warn/10 border border-warn/30 text-warn text-[11.5px]">
      <div>Rejected ({conflict.message}){conflict.allowed.length ? ` — allowed: ${conflict.allowed.join(", ")}` : ""}.</div>
      {conflict.blockers.length > 0 && (
        <ul className="mt-1 list-disc pl-4">
          {conflict.blockers.map((b) => <li key={b.id}>{b.type} "{b.name ?? b.id}" is {b.status}</li>)}
        </ul>
      )}
    </div>
  );
}
```

(Add `ConflictBlock.tsx` to this task's Files; refactor `LifecycleControl` to reuse it if trivial.)

- [ ] **Step 4:** Run `npm test -- src/components/fleet/CameraConfigForm.test.tsx` — PASS. `npm run lint`.
- [ ] **Step 5 (git-flow-manager):** commit `feat: CameraConfigForm (config-only PATCH, typed cam_index, 422/409 surfacing)`

---

### Task 12: `DisplayConfigForm`

**Files:**
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/DisplayConfigForm.tsx`
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/DisplayConfigForm.test.tsx`

- [ ] **Step 1: Write the failing tests** — mirror Task 11 with display fields: submits `{ name, display_role, screen_group_id, resolution_width, resolution_height, calibration }`; `resolution_width` is passed through RAW (type `"abc"` → body contains `"abc"`; the server 422 comes back mapped to `field-error-resolution_width` — this is the E2E 422 vehicle); D2 lockout (no `screen_id` input); empty resolution inputs send `null`. Run — FAIL.
- [ ] **Step 2 (git-flow-manager):** commit `test: DisplayConfigForm submit/422 raw pass-through`
- [ ] **Step 3: Implement** — same skeleton as `CameraConfigForm`: `DISPLAY_ROLES` select, `resolution_width`/`resolution_height` text inputs kept as strings in state, submitted as `resolution_width: resW === "" ? null : (Number.isInteger(Number(resW)) ? Number(resW) : resW)` (numeric when valid, raw otherwise so the SERVER's 422 surfaces on the field), `calibration` JsonField, no cam_index. Shares `FormField`/`JsonField`/`ConflictBlock`.
- [ ] **Step 4:** Run — PASS. **Step 5 (git-flow-manager):** commit `feat: DisplayConfigForm`

---

### Task 13: Wire editable Config + Lifecycle into `ObjectDrawer`

**Files:**
- Modify: `/Users/jn/code/godview-prototype/src/components/fleet/ObjectDrawer.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/components/fleet/ObjectDrawer.test.tsx`

- [ ] **Step 1: Write the failing tests** — extend the Task 8 test file: for a camera detail, the drawer now renders `camera-config-form` (not the read-only `config-section`), a `LifecycleControl`, and fetches same-system groups via `fetchFleetScreenGroups(identity.system_id)`; saving triggers `fetchObjectDetail` again (refetch — assert called ≥2 times after clicking Save) AND calls `onMutated` (tree invalidation). For a display: `display-config-form`. For a location/system/screen_group: STILL the read-only `config-section` and NO lifecycle control (container writes are P3/P4). Run — FAIL.
- [ ] **Step 2 (git-flow-manager):** commit `test: ObjectDrawer editable device config + lifecycle wiring (red)`
- [ ] **Step 3: Implement** — in `ObjectDrawer`:

```tsx
const saved = () => { setVersion((v) => v + 1); onMutated(); };   // PATCH -> refetch + invalidate (D13)
const isDevice = type === "camera" || type === "display";
// groups for the D6 same-system select: fetch once per system_id
const [groups, setGroups] = useState<{ id: string; name: string }[]>([]);
useEffect(() => {
  const sysId = detail?.identity.system_id;
  if (!isDevice || !sysId) { setGroups([]); return; }
  fetchFleetScreenGroups(sysId, { limit: 100 }).then((p) => setGroups(p.items)).catch(() => setGroups([]));
}, [detail?.identity.system_id, isDevice]);
```

Render: `{type === "camera" && <CameraConfigForm id={id} detail={detail} groups={groups} onSaved={saved} />}` / display analog / `{!isDevice && <ConfigSection detail={detail} />}`; after the config block, `{isDevice && <LifecycleControl current={String(detail.config.status)} onApply={(next) => (type === "camera" ? patchCameraConfig(id, { status: next }) : patchDisplayConfig(id, { status: next })).then(saved)} />}`. Note `.then(saved)` runs only on success — the 409 propagates to `LifecycleControl`'s catch.

- [ ] **Step 4:** Run `npm test -- src/components/fleet/ObjectDrawer.test.tsx` then full `npm test` — PASS.
- [ ] **Step 5 (git-flow-manager):** commit `feat: ObjectDrawer — editable device config forms + lifecycle transitions`

---

### Task 14: Create-camera / create-display forms + per-level buttons

**Files:**
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/CreateDeviceForm.tsx`
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/CreateDeviceForm.test.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/components/fleet/SystemLevel.tsx` (render `deviceActions(systemId)` seam from Task 5)
- Modify: `/Users/jn/code/godview-prototype/src/pages/Fleet.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/pages/Fleet.test.tsx`

One component, two modes (`kind: "camera" | "display"`) — the fields differ but the submit/error skeleton is identical and already proven in Tasks 11/12.

- [ ] **Step 1: Write the failing tests** (`CreateDeviceForm.test.tsx`, api mocked with real `ApiError` via `importOriginal`)
  - Renders the D7 staged-creation copy VERBATIM: `expect(screen.getByText("New devices are created offline — visible in Fleet but not live until you activate them.")).toBeInTheDocument();` and NO status field (`expect(screen.queryByLabelText(/status/i)).toBeNull()`).
  - camera mode: fill name + screen_id + cam_index → submit calls `createCamera({ system_id: "s1", screen_id: "screen_9", name: "New Cam", camera_role: "detection", screen_group_id: null, stream_url: null, calibration: { cam_index: 1 }, failover_eligible: false })` and then `onCreated({ type: "camera", id: "<returned id>" })`.
  - display mode: submit calls `createDisplay({ system_id: "s1", screen_id: "display-9", name: "New Kiosk", display_role: "primary_ad", screen_group_id: null, resolution_width: null, resolution_height: null })`.
  - 422 with `loc: ["body","screen_id"]` lands on `field-error-screen_id`; 409 renders `form-conflict`.

  `Fleet.test.tsx` additions: expanding a system shows "+ camera" / "+ display" buttons (the Task 5 `deviceActions` seam); clicking "+ display" swaps the right panel to the create form; a successful create returns to the drawer showing the NEW device (Fleet selects `onCreated` result) and bumps `treeVersion` (assert the level fetcher is called again).

  Run — FAIL.
- [ ] **Step 2 (git-flow-manager):** commit `test: CreateDeviceForm (D7 staged copy, no status field) + Fleet create wiring (red)`
- [ ] **Step 3: Implement** `CreateDeviceForm.tsx`

```tsx
import { useState, type FormEvent } from "react";
import { createCamera, createDisplay } from "../../data/api";
import { CAMERA_ROLES, DISPLAY_ROLES, fieldErrorsFrom422, conflictFrom409, type FieldErrors, type ConflictInfo } from "../../data/fleetSelectors";
import { FormField, inputClass } from "./FormField";
import { JsonField } from "./JsonField";
import { ConflictBlock } from "./ConflictBlock";
import type { Selection } from "./DeviceLevel";

export function CreateDeviceForm({ kind, systemId, groups, onCreated, onCancel }: {
  kind: "camera" | "display"; systemId: string;
  groups: { id: string; name: string }[];
  onCreated: (sel: Selection) => void; onCancel: () => void;
}) {
  const [name, setName] = useState("");
  const [screenId, setScreenId] = useState("");
  const [role, setRole] = useState(kind === "camera" ? "detection" : "primary_ad");
  const [groupId, setGroupId] = useState("");
  const [streamUrl, setStreamUrl] = useState("");
  const [camIndex, setCamIndex] = useState("");
  const [calibJson, setCalibJson] = useState("{}");
  const [jsonOk, setJsonOk] = useState(true);
  const [resW, setResW] = useState(""); const [resH, setResH] = useState("");
  const [errors, setErrors] = useState<FieldErrors>({ fields: {}, form: null });
  const [conflict, setConflict] = useState<ConflictInfo | null>(null);
  const [saving, setSaving] = useState(false);

  const rawInt = (v: string) => (v === "" ? null : Number.isInteger(Number(v)) ? Number(v) : v);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setErrors({ fields: {}, form: null }); setConflict(null);
    if (kind === "camera" && camIndex !== "" && !Number.isInteger(Number(camIndex))) {
      setErrors({ fields: { cam_index: "must be an integer" }, form: null }); return;
    }
    let calibration: Record<string, unknown>;
    try { calibration = calibJson.trim() ? JSON.parse(calibJson) : {}; }
    catch { setErrors({ fields: { calibration: "not valid JSON" }, form: null }); return; }
    if (kind === "camera" && camIndex !== "") calibration = { ...calibration, cam_index: Number(camIndex) };
    setSaving(true);
    try {
      const created = kind === "camera"
        ? await createCamera({ system_id: systemId, screen_id: screenId || undefined, name: name || undefined,
            camera_role: role, screen_group_id: groupId || null, stream_url: streamUrl || null as never,
            calibration, failover_eligible: false })
        : await createDisplay({ system_id: systemId, screen_id: screenId, name: name || undefined,
            display_role: role, screen_group_id: groupId || null,
            resolution_width: rawInt(resW) as never, resolution_height: rawInt(resH) as never });
      onCreated({ type: kind, id: created.id });
    } catch (err) {
      const fe = fieldErrorsFrom422(err); const c = conflictFrom409(err);
      if (fe) setErrors(fe);
      else if (c) setConflict(c);
      else setErrors({ fields: {}, form: err instanceof Error ? err.message : String(err) });
    } finally { setSaving(false); }
  };

  return (
    <form onSubmit={submit} data-testid={`create-${kind}-form`}>
      <h2 className="text-[14px] font-semibold mb-1">New {kind}</h2>
      <p className="mb-3 px-2 py-1.5 rounded-md bg-accent/10 border border-accent/30 text-[11.5px] text-dim">
        New devices are created offline — visible in Fleet but not live until you activate them.
      </p>
      <FormField name="name" label="name" error={errors.fields.name}>
        <input aria-label="name" value={name} onChange={(e) => setName(e.target.value)} className={inputClass} />
      </FormField>
      <FormField name="screen_id" label={`screen_id (wire key${kind === "camera" ? ", optional" : ""})`} error={errors.fields.screen_id}>
        <input aria-label="screen_id" value={screenId} onChange={(e) => setScreenId(e.target.value)} className={inputClass + " font-mono"} />
      </FormField>
      <FormField name="role" label={kind === "camera" ? "camera_role" : "display_role"}
        error={errors.fields.camera_role ?? errors.fields.display_role}>
        <select aria-label={kind === "camera" ? "camera_role" : "display_role"} value={role}
          onChange={(e) => setRole(e.target.value)} className={inputClass}>
          {(kind === "camera" ? CAMERA_ROLES : DISPLAY_ROLES).map((r) => <option key={r} value={r}>{r}</option>)}
        </select>
      </FormField>
      <FormField name="screen_group_id" label="screen_group (same system)" error={errors.fields.screen_group_id}>
        <select aria-label="screen_group (same system)" value={groupId} onChange={(e) => setGroupId(e.target.value)} className={inputClass}>
          <option value="">ungrouped</option>
          {groups.map((g) => <option key={g.id} value={g.id}>{g.name}</option>)}
        </select>
      </FormField>
      {kind === "camera" && (<>
        <FormField name="stream_url" label="stream_url" error={errors.fields.stream_url}>
          <input aria-label="stream_url" value={streamUrl} onChange={(e) => setStreamUrl(e.target.value)} className={inputClass} />
        </FormField>
        <FormField name="cam_index" label="cam_index" error={errors.fields.cam_index}>
          <input aria-label="cam_index" value={camIndex} onChange={(e) => setCamIndex(e.target.value)} className={inputClass + " w-24 font-mono"} />
        </FormField>
        <JsonField name="calibration" label="calibration" value={calibJson} onChange={setCalibJson}
          onValidChange={setJsonOk} serverError={errors.fields.calibration} />
      </>)}
      {kind === "display" && (<>
        <FormField name="resolution_width" label="resolution_width" error={errors.fields.resolution_width}>
          <input aria-label="resolution_width" value={resW} onChange={(e) => setResW(e.target.value)} className={inputClass + " w-24 font-mono"} />
        </FormField>
        <FormField name="resolution_height" label="resolution_height" error={errors.fields.resolution_height}>
          <input aria-label="resolution_height" value={resH} onChange={(e) => setResH(e.target.value)} className={inputClass + " w-24 font-mono"} />
        </FormField>
      </>)}
      {errors.form && <div data-testid="form-error" className="mb-2 text-crit text-[11.5px]">{errors.form}</div>}
      {conflict && <ConflictBlock conflict={conflict} />}
      <div className="flex gap-2">
        <button type="submit" disabled={saving || !jsonOk}
          className="bg-elev border border-border rounded-md px-3 py-1 text-[12px] hover:border-accent/40 disabled:opacity-50">Create</button>
        <button type="button" onClick={onCancel} className="text-[12px] text-dim hover:underline">Cancel</button>
      </div>
    </form>
  );
}
```

- [ ] **Step 4: Wire into `Fleet.tsx`** — page state becomes
  `panel: { kind: "object"; sel: Selection } | { kind: "create"; device: "camera" | "display"; systemId: string } | null`.
  `deviceActions={(systemId) => (<span className="pl-5 text-[11px]"><button onClick={() => setPanel({ kind: "create", device: "camera", systemId })} className="text-accent hover:underline mr-2">+ camera</button><button onClick={() => setPanel({ kind: "create", device: "display", systemId })} className="text-accent hover:underline">+ display</button></span>)}` passed through `LocationLevel → SystemLevel`. The create branch fetches same-system groups (same one-shot fetch as the drawer — lift a tiny `useSameSystemGroups(systemId)` helper into `src/components/fleet/useSameSystemGroups.ts` and reuse in both, keeping ObjectDrawer's Task 13 version). `onCreated(sel)` → `setTreeVersion(v => v + 1); setPanel({ kind: "object", sel })` — the new offline device is selected and visible (D7).
- [ ] **Step 5:** Run full `npm test` — PASS. `npm run lint`.
- [ ] **Step 6 (git-flow-manager):** commit `feat: create camera/display forms with staged-offline copy + per-system buttons`

---

### Task 15 (LAST — DROPPABLE, D11): Adopt-unresolved flow

If schedule pressure hits, DROP THIS TASK — nothing else depends on it; the spec marks adopt as a droppable growth item. Everything lands in one task so dropping it is a clean cut.

**Files:**
- Modify: `/Users/jn/code/godview-prototype/src/data/api.ts` (add `adoptUnresolved`)
- Modify: `/Users/jn/code/godview-prototype/src/data/api.test.ts`
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/AdoptPanel.tsx`
- Create: `/Users/jn/code/godview-prototype/src/components/fleet/AdoptPanel.test.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/pages/Fleet.tsx` + `Fleet.test.tsx`

- [ ] **Step 1: Write the failing tests**
  - `api.test.ts`: `adoptUnresolved({ unresolved_id: "u1", system_id: "s1", name: "Kiosk 3" })` POSTs `/displays/adopt` with that JSON body.
  - `AdoptPanel.test.tsx`: mock `fetchUnresolvedDevices` → 2 rows (`{ id: "u1", screen_id: "display-7", kind: "display", first_seen_at: …, last_seen_at: …, seen_count: 14 }`, …) and `fetchSystems` (the EXISTING God View fetcher — reused as the system picker) → one system. Assert: rows render screen_id + seen_count; clicking "Adopt" on a row opens an inline form with screen_id shown READ-ONLY (it is the identity being adopted, D2) and a system select; submit calls `adoptUnresolved({ unresolved_id: "u1", system_id: "s1", name: "Kiosk 7" })`; success calls `onAdopted({ type: "display", id: "<returned id>" })`; a 409/422 renders via the shared blocks. Copy assertion (spec risk §7): the panel explains re-imaged kiosks: `/adopt creates the display pre-filled and removes the unresolved row/i`.
  - `Fleet.test.tsx`: when `fetchUnresolvedDevices` reports `counts.total > 0`, the page header shows an "Unresolved devices (N)" button; clicking it swaps the right panel to the AdoptPanel; after `onAdopted` the tree version bumps and the new display is selected.

  Run — FAIL.
- [ ] **Step 2 (git-flow-manager):** commit `test: adopt-unresolved fetcher, panel, and Fleet banner wiring (red)`
- [ ] **Step 3: Implement** — `api.ts`: `export interface AdoptRequest { unresolved_id: string; system_id: string; name?: string; screen_group_id?: string | null; } export const adoptUnresolved = (body: AdoptRequest) => sendJson<{ id: string }>("POST", "/displays/adopt", body);` — `AdoptPanel.tsx`: `useLevelList(fetchUnresolvedDevices)` for the rows; per-row expandable inline form (name input, system select fed by `fetchSystems({ limit: 50 })` items, optional group select via `useSameSystemGroups` once a system is chosen); submit → `adoptUnresolved` → `onAdopted({ type: "display", id })`; errors through `fieldErrorsFrom422`/`ConflictBlock`. — `Fleet.tsx`: fetch `fetchUnresolvedDevices()` once on mount + after every `treeVersion` bump (NOT polled); render the header button when `counts.total > 0`; panel union gains `{ kind: "adopt" }`.
- [ ] **Step 4:** Run full `npm test` — PASS. `npm run lint`, `npm run build`.
- [ ] **Step 5 (git-flow-manager):** commit `feat: adopt-unresolved panel — kills the unregistered screen_id banner the right way`

---

### Task 16: Full verification + live E2E against the real ops-api (:8080)

Preconditions: Plan A deployed (ops-api serving A1–A13 on `http://localhost:8080`), DB up. Uses the Playwright MCP browser tools (`browser_navigate`, `browser_snapshot`, `browser_click`, `browser_type`, `browser_fill_form`, `browser_network_requests`) — no Playwright npm dependency is added to the repo.

- [ ] **Step 1: Static gates** — `cd /Users/jn/code/godview-prototype && npm test && npm run lint && npm run build` — all green.
- [ ] **Step 2: Record restore points (BEFORE any mutation)** via psql against the ops DB:
  ```sql
  SELECT id, name FROM cameras LIMIT 5;                       -- pick one; note its current name + failover_eligible
  SELECT id, screen_id, kind, first_seen_at, last_seen_at, seen_count FROM unresolved_devices;  -- full copy, needed for restore
  ```
  Save the output in the task journal.
- [ ] **Step 3: Start the app** — `cd /Users/jn/code/godview-prototype && npm run dev` (background; default `VITE_OPS_API_URL` already points at :8080).
- [ ] **Step 4: Browse the tree** — navigate to `http://localhost:5173/fleet`; snapshot; expand a root location → child location → system → group; verify device rows show role/duty (cameras) and screen_id (displays); verify each expansion issued ONE bounded request (`browser_network_requests`: `/locations?parent_location_id=…`, `/systems?location_id=…`, `/screen-groups?system_id=…`, `/cameras?…`, `/displays?…`).
- [ ] **Step 5: Edit a camera name** — select the noted camera; in Config set name to `E2E rename probe`; Save; verify the drawer refetches (name updates WITHOUT reload), History gains an admin event with `name: "<old>" → "E2E rename probe"`, and the State panel still shows honest staleness (D15). **Restore:** set the name back to the recorded value; Save; confirm History shows the second event.
- [ ] **Step 6: Flip failover_eligible** — toggle it, Save, confirm via History + tree meta; flip it BACK (restore). Cross-check convergence honesty: `psql -c "SELECT failover_eligible FROM cameras WHERE id='<id>'"` matches.
- [ ] **Step 7: Create a display** — expand a system → "+ display"; verify the D7 copy is visible; screen_id `e2e-probe-display-1`, name `E2E probe display`; Create; verify it appears in the tree with an OFFLINE dot and is auto-selected.
- [ ] **Step 8: Exercise a 422** — on the new display's Config form, type `abc` into resolution_width; Save; expect the server 422 rendered ON THE FIELD ("value is not a valid integer" or Plan A's wording). Then clear it and Save clean.
- [ ] **Step 9: Exercise a 409** — Lifecycle: transition the probe display `offline → retired` (allowed, D3 `*→retired`); then attempt `retired → active`: expect the conflict block quoting the allowed set ("none — terminal state"). This doubles as the probe display's cleanup — retired is the supported "remove" (D4).
- [ ] **Step 10 (skip if Task 15 dropped): Adopt an unresolved device** — header button "Unresolved devices (3)"; adopt one row into a real system with name `E2E adopted kiosk`; verify: display created offline, selected in the tree, unresolved count decremented, History shows `action: adopt`. **Cleanup/restore:** transition the adopted display to `retired`; re-insert the consumed unresolved row from Step 2's copy:
  ```sql
  INSERT INTO unresolved_devices (id, screen_id, kind, first_seen_at, last_seen_at, seen_count)
  VALUES ('<id>', '<screen_id>', '<kind>', '<first_seen_at>', '<last_seen_at>', <seen_count>);
  ```
  (If the projector re-detects it organically, the insert is harmless duplication-avoidance — check first.) Note: the retired probe/adopted displays deliberately REMAIN in the registry — D4, no hard deletes; record their ids in the journal.
- [ ] **Step 11:** Stop the dev server. Verify final `npm test` still green.
- [ ] **Step 12 (git-flow-manager):** commit any E2E-discovered fixes as `fix:` commits; then merge per superpowers:finishing-a-development-branch.

---

## Execution order & shippability

Task 0 → 1 → 2 → 3 → (4 → 5 → 6) tree → (7 → 8) drawer+page ⇒ **P1 shippable** → 9 → 10 → (11, 12 parallel-safe) → 13 → 14 → [15 droppable] → 16. Tasks 4–7 touch disjoint files after their shared deps (1–3) land — safe for subagent parallelism if desired; 13/14 both touch `Fleet.tsx`/`ObjectDrawer.tsx`, keep serial.

### Critical Files for Implementation

- /Users/jn/code/godview-prototype/src/data/api.ts
- /Users/jn/code/godview-prototype/src/data/apiTypes.ts
- /Users/jn/code/godview-prototype/src/data/fleetSelectors.ts
- /Users/jn/code/godview-prototype/src/components/fleet/ObjectDrawer.tsx
- /Users/jn/code/godview-prototype/src/pages/Fleet.tsx
