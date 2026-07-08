# God View Real-Data — Plan B: prototype wiring

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Swap the `godview-prototype` app's static mock `db` for live polling of the God View read endpoints (Plan A), keeping every view-shaping selector's logic client-side.

**Architecture:** A new `src/data/api.ts` (typed fetchers over `VITE_OPS_API_URL`) plus a `usePolling` hook feed each page its endpoint's payload. The existing selectors keep their logic but take the payload slice as input instead of the whole `Db`. Nearly every selector has a single page as its only caller, so each page's task mutates its own selectors and tests without breaking other pages. Fixtures + selector unit tests stay (fixtures become the test seed).

**Tech Stack:** Vite + React 18/19 + TypeScript + react-router-dom v7 (data router) + @xyflow/react; Vitest + @testing-library/react + jsdom.

**Spec:** `/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-07-godview-real-data-wiring-design.md`
**Contract (Plan A):** `/Users/jn/code/minority_report_architecture/docs/superpowers/plans/2026-07-07-godview-realdata-plan-a-ops-api.md` — the endpoint payload shapes below must match Plan A's returns exactly.

## Global Constraints

- Repo: `/Users/jn/code/godview-prototype`. All git delegated to the `git-flow-manager` subagent. One branch for this plan: `feat/godview-realdata-wiring` off `main`.
- Test command: `cd /Users/jn/code/godview-prototype && npm test` (`vitest run`). Test config: `/Users/jn/code/godview-prototype/vitest.config.ts` (jsdom, globals, setup `./src/test/setup.ts`).
- API base URL convention (mirror the mras-ops frontend): `const OPS_API = import.meta.env.VITE_OPS_API_URL ?? "http://localhost:8080";`. Bare `fetch`, snake_case JSON consumed as-is, throw on `!res.ok`.
- **Keep logic client-side:** the endpoints return bounded rows + raw counts; the selectors keep their view-shaping (KPI mapping, failure merge/rank, stage-dot logic, screen_group grouping, graph building). Selector signatures change from `(db)` to the payload slice; the *logic bodies* are preserved.
- Polling interval: 5000 ms for the dashboard, systems list, and pipeline badge. List pagination ("Load more") is user-triggered by cursor, not polled.
- On a failed poll, keep the last-good data (page must not blank); show a dismissible error banner.
- Do not delete `src/data/fixtures.ts` — selector unit tests seed from it.
- **Intentional change from the mock:** per-camera readings on Systems & Logs move from a top-level list into the on-demand drill-down (scale-safe: you cannot list all cameras' readings at 200k cameras). Global "hot" readings remain on the dashboard (`camera_rows`).

---

### Task 1: API client, payload types, polling hook, async-state UI

**Files:**
- Create: `/Users/jn/code/godview-prototype/src/data/apiTypes.ts`
- Create: `/Users/jn/code/godview-prototype/src/data/api.ts`
- Create: `/Users/jn/code/godview-prototype/src/hooks/usePolling.ts`
- Create: `/Users/jn/code/godview-prototype/src/components/AsyncState.tsx`
- Create: `/Users/jn/code/godview-prototype/src/data/api.test.ts`
- Create: `/Users/jn/code/godview-prototype/src/hooks/usePolling.test.ts`
- Create: `/Users/jn/code/godview-prototype/.env.example`

**Interfaces:**
- Produces: payload interfaces in `apiTypes.ts`; fetchers in `api.ts`; `usePolling<T>(fn, intervalMs?) => { data: T | null, loading: boolean, error: Error | null, refetch: () => void }`; `<AsyncState loading error onRetry>` wrapper.

- [ ] **Step 1: Write the failing api test**

Create `/Users/jn/code/godview-prototype/src/data/api.test.ts`:

```ts
import { afterEach, describe, expect, it, vi } from "vitest";
import { fetchDashboard, fetchAdRuns } from "./api";

afterEach(() => vi.restoreAllMocks());

describe("api", () => {
  it("fetchDashboard hits /god-view/dashboard and returns parsed json", async () => {
    const payload = { fleet: { total: 1, active: 1, degraded: 0, offline: 0 } };
    const spy = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify(payload), { status: 200 }));
    const out = await fetchDashboard();
    expect(spy).toHaveBeenCalledWith("http://localhost:8080/god-view/dashboard");
    expect(out.fleet.total).toBe(1);
  });

  it("fetchAdRuns encodes filter + cursor params", async () => {
    const spy = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ items: [], next_cursor: null }), { status: 200 }));
    await fetchAdRuns({ status: "playing", system_id: "s1", cursor: "c1", limit: 25 });
    const url = (spy.mock.calls[0][0] as string);
    expect(url).toContain("/god-view/ad-runs?");
    expect(url).toContain("status=playing");
    expect(url).toContain("system_id=s1");
    expect(url).toContain("cursor=c1");
    expect(url).toContain("limit=25");
  });

  it("throws on non-ok response", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("nope", { status: 500 }));
    await expect(fetchDashboard()).rejects.toThrow();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/godview-prototype && npm test -- src/data/api.test.ts`
Expected: FAIL — cannot resolve `./api`.

- [ ] **Step 3: Write payload types**

Create `/Users/jn/code/godview-prototype/src/data/apiTypes.ts`:

```ts
// Payload shapes returned by the mras-ops God View endpoints (Plan A). snake_case.

export interface FleetCounts { total: number; active: number; degraded: number; offline: number; }
export interface ActiveRun { id: string; status: string; started_at: string | null; system_id: string | null; system_name: string | null; }
export interface FailedRun { id: string; system_id: string | null; system_name: string | null; ended_at: string | null; error_code: string | null; }
export interface HealthDrop { kind: "device" | "system"; ref_id: string; ref_name: string; status: string; detail: string; observed_at: string; }
export interface CameraRow { camera_id: string; name: string | null; system_name: string | null; status: string; face_count: number; confidence: number; }
export interface DashboardPayload {
  fleet: FleetCounts;
  org_count: number;
  active_count: number;
  active_runs: ActiveRun[];
  recent_failed_runs: FailedRun[];
  recent_health_drops: HealthDrop[];
  camera_rows: CameraRow[];
}

export interface AdRunListItem {
  id: string; status: string; started_at: string | null;
  system_id: string | null; system_name: string | null; location_name: string | null;
  campaign_id: string | null; campaign_name: string | null;
  stage_decision: boolean; stage_composition: boolean; stage_playback: boolean;
}
export interface AdRunsPage { items: AdRunListItem[]; next_cursor: string | null; }
export interface AdRunFilters { systems: { id: string; name: string }[]; campaigns: { id: string; name: string }[]; }

export interface SystemCounts { total_systems: number; active_systems: number; unresolved_devices: number; }
export interface SystemListItem {
  id: string; name: string; org_name: string | null; location_name: string | null;
  system_type: string; status: string; device_count: number;
}
export interface SystemsPage { counts: SystemCounts; items: SystemListItem[]; next_cursor: string | null; }

export interface SystemDetail {
  system: { id: string; name: string; status: string; system_type: string };
  screen_groups: { id: string; name: string; group_type: string }[];
  cameras: { id: string; name: string | null; status: string; screen_group_id: string | null; face_count: number; confidence: number }[];
  displays: { id: string; name: string | null; status: string; screen_id: string; screen_group_id: string | null }[];
}

export interface EventItem { id: string; kind: "device" | "system"; ref_id: string; ref_name: string; status: string; detail: string; observed_at: string; }
export interface EventsPage { items: EventItem[]; next_cursor: string | null; }

export interface AdRunDetail {
  ad_run: { id: string; trigger_id: string; status: string; started_at: string | null; ended_at: string | null; system_id: string | null };
  personalization_decision: { id: string; decision_type: string; decision_confidence: number | null; decision_factors: Record<string, unknown> } | null;
  composition_run: { id: string; render_mode: string; status: string; error_code: string | null; error_message: string | null; used_likeness: boolean; used_voice_clone: boolean } | null;
  playbacks: { id: string; status: string; display_id: string | null; screen_id: string; error_code: string | null; error_message: string | null }[];
}

export interface ProjectorStatus { cursor: number; backlog: number; lag_seconds: number | null; health: "ok" | "warn" | "crit"; }
```

- [ ] **Step 4: Write the api client**

Create `/Users/jn/code/godview-prototype/src/data/api.ts`:

```ts
import type {
  DashboardPayload, AdRunsPage, AdRunFilters, SystemsPage, SystemDetail,
  EventsPage, AdRunDetail, ProjectorStatus,
} from "./apiTypes";

const OPS_API = import.meta.env.VITE_OPS_API_URL ?? "http://localhost:8080";

async function getJson<T>(path: string): Promise<T> {
  const res = await fetch(`${OPS_API}${path}`);
  if (!res.ok) throw new Error(`${path} -> ${res.status}`);
  return (await res.json()) as T;
}

function qs(params: Record<string, string | number | undefined>): string {
  const p = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) {
    if (v !== undefined && v !== "" && v !== null) p.set(k, String(v));
  }
  const s = p.toString();
  return s ? `?${s}` : "";
}

export const fetchDashboard = () => getJson<DashboardPayload>("/god-view/dashboard");

export interface AdRunQuery { status?: string; system_id?: string; campaign_id?: string; since?: string; cursor?: string; limit?: number; }
export const fetchAdRuns = (q: AdRunQuery = {}) => getJson<AdRunsPage>(`/god-view/ad-runs${qs(q)}`);
export const fetchAdRunFilters = () => getJson<AdRunFilters>("/god-view/ad-runs/filters");
export const fetchAdRun = (id: string) => getJson<AdRunDetail>(`/god-view/ad-runs/${id}`);

export interface SystemsQuery { search?: string; cursor?: string; limit?: number; }
export const fetchSystems = (q: SystemsQuery = {}) => getJson<SystemsPage>(`/god-view/systems${qs(q)}`);
export const fetchSystem = (id: string) => getJson<SystemDetail>(`/god-view/systems/${id}`);

export interface EventsQuery { cursor?: string; limit?: number; }
export const fetchEvents = (q: EventsQuery = {}) => getJson<EventsPage>(`/god-view/events${qs(q)}`);

export const fetchProjectorStatus = () => getJson<ProjectorStatus>("/projector/status");
```

Note: the ad-runs query object must NOT set `status: ""`; `qs` already drops empty strings so a cleared filter omits the param.

- [ ] **Step 5: Run api test to verify it passes**

Run: `cd /Users/jn/code/godview-prototype && npm test -- src/data/api.test.ts`
Expected: PASS (3 tests). Note: `qs` orders params by insertion; the test uses `toContain`, so order-independent.

- [ ] **Step 6: Write the failing usePolling test**

Create `/Users/jn/code/godview-prototype/src/hooks/usePolling.test.ts`:

```ts
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { renderHook, waitFor, act } from "@testing-library/react";
import { usePolling } from "./usePolling";

beforeEach(() => vi.useFakeTimers());
afterEach(() => { vi.runOnlyPendingTimers(); vi.useRealTimers(); });

describe("usePolling", () => {
  it("fetches on mount and again after the interval", async () => {
    const fn = vi.fn().mockResolvedValue({ n: 1 });
    renderHook(() => usePolling(fn, 5000));
    await act(async () => { await Promise.resolve(); });
    expect(fn).toHaveBeenCalledTimes(1);
    await act(async () => { vi.advanceTimersByTime(5000); await Promise.resolve(); });
    expect(fn).toHaveBeenCalledTimes(2);
  });

  it("keeps last-good data when a later poll rejects", async () => {
    const fn = vi.fn()
      .mockResolvedValueOnce({ n: 1 })
      .mockRejectedValueOnce(new Error("boom"));
    const { result } = renderHook(() => usePolling(fn, 5000));
    await act(async () => { await Promise.resolve(); });
    expect(result.current.data).toEqual({ n: 1 });
    await act(async () => { vi.advanceTimersByTime(5000); await Promise.resolve(); });
    await waitFor(() => expect(result.current.error).toBeInstanceOf(Error));
    expect(result.current.data).toEqual({ n: 1 }); // last-good retained
  });
});
```

- [ ] **Step 7: Run test to verify it fails**

Run: `cd /Users/jn/code/godview-prototype && npm test -- src/hooks/usePolling.test.ts`
Expected: FAIL — cannot resolve `./usePolling`.

- [ ] **Step 8: Implement usePolling + AsyncState + .env.example**

Create `/Users/jn/code/godview-prototype/src/hooks/usePolling.ts`:

```ts
import { useCallback, useEffect, useRef, useState } from "react";

export function usePolling<T>(fn: () => Promise<T>, intervalMs = 5000) {
  const [data, setData] = useState<T | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<Error | null>(null);
  const fnRef = useRef(fn);
  fnRef.current = fn;

  const run = useCallback(async () => {
    try {
      const next = await fnRef.current();
      setData(next);      // only replace data on success -> last-good retained on error
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e : new Error(String(e)));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    run();
    const id = setInterval(run, intervalMs);
    return () => clearInterval(id);
  }, [run, intervalMs]);

  return { data, loading, error, refetch: run };
}
```

Create `/Users/jn/code/godview-prototype/src/components/AsyncState.tsx`:

```tsx
import type { ReactNode } from "react";

export function AsyncState({
  loading, error, hasData, onRetry, children,
}: {
  loading: boolean; error: Error | null; hasData: boolean;
  onRetry: () => void; children: ReactNode;
}) {
  return (
    <>
      {error && (
        <div data-testid="error-banner" className="mb-3 flex items-center justify-between rounded-md border border-crit/40 bg-crit/10 px-3 py-2 text-[12px] text-crit">
          <span>Couldn't reach ops-api. Showing last-known data.</span>
          <button onClick={onRetry} className="underline">Retry</button>
        </div>
      )}
      {loading && !hasData ? (
        <div data-testid="loading" className="py-10 text-center text-[13px] text-muted">Loading…</div>
      ) : (
        children
      )}
    </>
  );
}
```

Create `/Users/jn/code/godview-prototype/.env.example`:

```
# Base URL of the mras-ops read API. Defaults to http://localhost:8080 when unset.
VITE_OPS_API_URL=http://localhost:8080
```

- [ ] **Step 9: Run tests to verify they pass**

Run: `cd /Users/jn/code/godview-prototype && npm test -- src/hooks/usePolling.test.ts src/data/api.test.ts`
Expected: PASS.

- [ ] **Step 10: Commit (delegate to git-flow-manager)**

Delegate: create branch `feat/godview-realdata-wiring` off `main`; stage the 7 created files; commit:
```
feat: api client, payload types, usePolling hook, async-state wrapper
```

---

### Task 2: Wire Main Dashboard + pipeline badge

**Files:**
- Modify: `/Users/jn/code/godview-prototype/src/data/selectors.ts` (fleetSummary, recentFailures signatures; add `toCameraReadingRows`; remove `activeAdRuns`)
- Modify: `/Users/jn/code/godview-prototype/src/data/selectors.test.ts`
- Modify: `/Users/jn/code/godview-prototype/src/pages/MainDashboard.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/pages/MainDashboard.test.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/components/Shell.tsx` (badge polls projector status)

**Interfaces:**
- Consumes: `fetchDashboard`, `fetchProjectorStatus`, `usePolling`, `AsyncState`, payload types.
- Produces (new selector signatures):
  - `fleetSummary(fleet: FleetCounts): { total; healthy; degraded; offline }`
  - `recentFailures(failedRuns: FailedRun[], healthDrops: HealthDrop[], limit: number): FailureRow[]`
  - `toCameraReadingRows(rows: CameraRow[]): CameraReadingRow[]`
  - `activeAdRuns` is removed (server returns `active_runs` pre-filtered).

- [ ] **Step 1: Update the failing selector tests**

In `/Users/jn/code/godview-prototype/src/data/selectors.test.ts`, replace the `fleetSummary`, `recentFailures`, `camerasWithReading`, and `activeAdRuns` test blocks with:

```ts
import { describe, expect, it } from "vitest";
import { fleetSummary, recentFailures, toCameraReadingRows } from "./selectors";

describe("fleetSummary", () => {
  it("maps active->healthy and passes degraded/offline through", () => {
    expect(fleetSummary({ total: 5, active: 3, degraded: 1, offline: 1 }))
      .toEqual({ total: 5, healthy: 3, degraded: 1, offline: 1 });
  });
});

describe("recentFailures", () => {
  it("merges failed runs (crit) and health drops (offline->crit, degraded->warn), newest first", () => {
    const failed = [{ id: "ar1", system_id: "s1", system_name: "Sys1", ended_at: "2026-07-06T10:00:00Z", error_code: "OVERLAY_RENDER_TIMEOUT" }];
    const drops = [
      { kind: "system" as const, ref_id: "s2", ref_name: "Sys2", status: "offline", detail: "down", observed_at: "2026-07-06T11:00:00Z" },
      { kind: "device" as const, ref_id: "d3", ref_name: "CamX", status: "degraded", detail: "lag", observed_at: "2026-07-06T09:00:00Z" },
    ];
    const rows = recentFailures(failed, drops, 5);
    expect(rows.map(r => r.when)).toEqual(["2026-07-06T11:00:00Z", "2026-07-06T10:00:00Z", "2026-07-06T09:00:00Z"]);
    expect(rows[0]).toMatchObject({ severity: "crit", where: "Sys2" });
    expect(rows[1]).toMatchObject({ severity: "crit", where: "Sys1", adRunId: "ar1" });
    expect(rows[2]).toMatchObject({ severity: "warn", where: "CamX" });
  });

  it("respects the limit", () => {
    const drops = Array.from({ length: 8 }, (_, i) => ({
      kind: "system" as const, ref_id: `s${i}`, ref_name: `S${i}`, status: "offline",
      detail: "d", observed_at: `2026-07-06T0${i}:00:00Z`,
    }));
    expect(recentFailures([], drops, 3)).toHaveLength(3);
  });
});

describe("toCameraReadingRows", () => {
  it("renames camera_id/system_name to id/system", () => {
    const rows = toCameraReadingRows([
      { camera_id: "c1", name: "Cam1", system_name: "Sys1", status: "active", face_count: 2, confidence: 0.7 },
    ]);
    expect(rows[0]).toEqual({ id: "c1", name: "Cam1", system: "Sys1", status: "active", face_count: 2, confidence: 0.7 });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/godview-prototype && npm test -- src/data/selectors.test.ts`
Expected: FAIL — `fleetSummary`/`recentFailures` signatures don't match; `toCameraReadingRows` undefined.

- [ ] **Step 3: Rewrite the selectors (logic preserved, inputs redirected)**

In `/Users/jn/code/godview-prototype/src/data/selectors.ts`:

Update the imports at the top to add payload types:
```ts
import type { Db, AdRun, Camera, Display, ScreenGroup, System } from "./types";
import type { FleetCounts, FailedRun, HealthDrop, CameraRow, CameraReadingRow } from "./apiTypes";
```
(If `CameraReadingRow` is currently declared in `selectors.ts`, keep its declaration and do NOT import it — import only the payload input types `FleetCounts, FailedRun, HealthDrop, CameraRow`.)

Replace `fleetSummary`:
```ts
export function fleetSummary(fleet: FleetCounts) {
  return { total: fleet.total, healthy: fleet.active, degraded: fleet.degraded, offline: fleet.offline };
}
```

Remove `activeAdRuns` entirely (server returns pre-filtered `active_runs`).

Replace `recentFailures` (keep the merge/severity/sort/slice logic; source from the two payload arrays instead of `db`):
```ts
export interface FailureRow { id: string; severity: "crit" | "warn"; message: string; where: string; when: string; adRunId?: string; }

export function recentFailures(failedRuns: FailedRun[], healthDrops: HealthDrop[], limit: number): FailureRow[] {
  const fromRuns: FailureRow[] = failedRuns.map((r) => ({
    id: r.id,
    severity: "crit",
    message: r.error_code ?? "composition failed",
    where: r.system_name ?? r.system_id ?? "—",
    when: r.ended_at ?? "",
    adRunId: r.id,
  }));
  const fromHealth: FailureRow[] = healthDrops.map((h) => ({
    id: `${h.kind}:${h.ref_id}:${h.observed_at}`,
    severity: h.status === "offline" ? "crit" : "warn",
    message: h.detail,
    where: h.ref_name,
    when: h.observed_at,
  }));
  return [...fromRuns, ...fromHealth]
    .sort((a, b) => (a.when < b.when ? 1 : a.when > b.when ? -1 : 0))
    .slice(0, limit);
}
```

Add `toCameraReadingRows` (replaces the old `camerasWithReading(db)` for the dashboard; keep the `CameraReadingRow` interface exactly as it is today):
```ts
export function toCameraReadingRows(rows: CameraRow[]): CameraReadingRow[] {
  return rows.map((r) => ({
    id: r.camera_id, name: r.name ?? "", system: r.system_name ?? "",
    status: r.status, face_count: r.face_count, confidence: r.confidence,
  }));
}
```
Leave the existing `camerasWithReading(db)` function in place for now — Task 5 (Systems) is its last remaining caller and removes it there.

- [ ] **Step 4: Run selector test to verify it passes**

Run: `cd /Users/jn/code/godview-prototype && npm test -- src/data/selectors.test.ts`
Expected: PASS.

- [ ] **Step 5: Rewrite MainDashboard data acquisition (preserve existing JSX)**

In `/Users/jn/code/godview-prototype/src/pages/MainDashboard.tsx`, replace the fixtures/selectors imports and the top-of-component data block. New imports:
```ts
import { Link } from "react-router-dom";
import { Shell } from "../components/Shell";
import { StatusDot } from "../components/StatusDot";
import { KpiCard } from "../components/KpiCard";
import { AsyncState } from "../components/AsyncState";
import { usePolling } from "../hooks/usePolling";
import { fetchDashboard } from "../data/api";
import { fleetSummary, recentFailures, toCameraReadingRows } from "../data/selectors";
```
Replace the data block (previously `const s = fleetSummary(db); const active = activeAdRuns(db); const failures = recentFailures(db, 5); const cams = camerasWithReading(db).slice(0, 6);` and inline `db.organizations.length`) with:
```tsx
const { data, loading, error, refetch } = usePolling(fetchDashboard);
const s = data ? fleetSummary(data.fleet) : { total: 0, healthy: 0, degraded: 0, offline: 0 };
const active = data?.active_runs ?? [];
const failures = data ? recentFailures(data.recent_failed_runs, data.recent_health_drops, 5) : [];
const cams = data ? toCameraReadingRows(data.camera_rows) : [];
const orgCount = data?.org_count ?? 0;
```
Wrap the page's existing rendered body in `<AsyncState loading={loading} error={error} hasData={!!data} onRetry={refetch}> ... </AsyncState>`. Keep all existing JSX; only:
- change `{db.organizations.length} organizations` to `{orgCount} organizations`;
- where the active-runs list previously showed a system name via a `db.systems` lookup, read `run.system_name` from the `ActiveRun` shape instead (fields: `id, status, started_at, system_id, system_name`);
- the "Pipeline lag" KpiCard's hardcoded `value="0.8s"` stays as-is here (the live badge is handled in the Shell in Step 7).

- [ ] **Step 6: Update MainDashboard test to mock the api**

In `/Users/jn/code/godview-prototype/src/pages/MainDashboard.test.tsx`, mock `../data/api` and assert render. Replace its body with:
```tsx
import { describe, expect, it, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { MainDashboard } from "./MainDashboard";

vi.mock("../data/api", () => ({
  fetchDashboard: vi.fn().mockResolvedValue({
    fleet: { total: 6, active: 4, degraded: 1, offline: 1 },
    org_count: 3,
    active_count: 1,
    active_runs: [{ id: "ar_x", status: "playing", started_at: "2026-07-06T18:00:00Z", system_id: "sys1", system_name: "Sys1" }],
    recent_failed_runs: [{ id: "ar_d3aa77", system_id: "sys1", system_name: "Sys1", ended_at: "2026-07-06T17:00:00Z", error_code: "OVERLAY_RENDER_TIMEOUT" }],
    recent_health_drops: [],
    camera_rows: [{ camera_id: "cam1", name: "Cam1", system_name: "Sys1", status: "active", face_count: 3, confidence: 0.8 }],
  }),
  fetchProjectorStatus: vi.fn().mockResolvedValue({ cursor: 1, backlog: 0, lag_seconds: 0.4, health: "ok" }),
}));

describe("MainDashboard", () => {
  beforeEach(() => vi.clearAllMocks());
  it("renders fleet + failure data from the api", async () => {
    render(<MemoryRouter><MainDashboard /></MemoryRouter>);
    await waitFor(() => expect(screen.getByText(/OVERLAY_RENDER_TIMEOUT/)).toBeInTheDocument());
    expect(screen.getByText(/3 organizations/)).toBeInTheDocument();
  });
});
```
(If the current test asserts other specific strings from the mock fixtures, keep those assertions only where the new mock payload still contains that text; otherwise update them to the strings above.)

- [ ] **Step 7: Make the Shell pipeline badge live**

In `/Users/jn/code/godview-prototype/src/components/Shell.tsx`, replace the hardcoded badge (`Pipeline OK · 0.8s`) with a live one. Add near the top of `Shell`:
```ts
import { usePolling } from "../hooks/usePolling";
import { fetchProjectorStatus } from "../data/api";
```
Inside the component:
```tsx
const { data: proj } = usePolling(fetchProjectorStatus, 5000);
const health = proj?.health ?? "ok";
const lag = proj?.lag_seconds == null ? "—" : `${proj.lag_seconds.toFixed(1)}s`;
const tone = health === "crit" ? "crit" : health === "warn" ? "warn" : "ok";
```
Replace the badge JSX with (keep the `data-testid="pipeline-health"` and the existing class structure, swapping the fixed color token for `tone` and the text for live values):
```tsx
<div data-testid="pipeline-health" className={`flex items-center gap-1.5 font-mono text-[11px] text-${tone} border border-${tone}/30 bg-${tone}/5 px-2 py-1 rounded-md`}>
  <span className={`h-1.5 w-1.5 rounded-full bg-${tone}`} /> Pipeline {health.toUpperCase()} · {lag}
</div>
```
Note: because Tailwind cannot see dynamically-built class names, add the six variants to the safelist in `/Users/jn/code/godview-prototype/tailwind.config.js` (`safelist: ["text-ok","text-warn","text-crit","border-ok/30","border-warn/30","border-crit/30","bg-ok/5","bg-warn/5","bg-crit/5","bg-ok","bg-warn","bg-crit"]`). If a `tailwind.config.js` safelist is impractical, instead map `tone` to a fixed full class string via a lookup object (`const TONE = { ok: "text-ok border-ok/30 bg-ok/5", ... }`) so the literal classes are statically present.

- [ ] **Step 8: Run tests + commit**

Run: `cd /Users/jn/code/godview-prototype && npm test -- src/data/selectors.test.ts src/pages/MainDashboard.test.tsx`
Expected: PASS.

Delegate commit: stage `src/data/selectors.ts`, `src/data/selectors.test.ts`, `src/pages/MainDashboard.tsx`, `src/pages/MainDashboard.test.tsx`, `src/components/Shell.tsx`, and `tailwind.config.js` if edited; commit:
```
feat: wire Main Dashboard + live pipeline badge to God View api
```

---

### Task 3: Wire Composition Activity

**Files:**
- Modify: `/Users/jn/code/godview-prototype/src/data/selectors.ts` (adRunCards signature)
- Modify: `/Users/jn/code/godview-prototype/src/data/selectors.test.ts`
- Modify: `/Users/jn/code/godview-prototype/src/pages/CompositionActivity.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/pages/CompositionActivity.test.tsx`

**Interfaces:**
- Consumes: `fetchAdRuns`, `fetchAdRunFilters`, payload types.
- Produces: `adRunCards(items: AdRunListItem[]): AdRunCard[]` — maps server rows (names + stage flags already provided) to the existing `AdRunCard` shape. Server-side filtering replaces client `withinTimeRange`/`.filter`.

- [ ] **Step 1: Update the failing selector test**

In `/Users/jn/code/godview-prototype/src/data/selectors.test.ts`, replace the `adRunCards` test block with:
```ts
import { adRunCards } from "./selectors";

describe("adRunCards", () => {
  it("maps server rows (names + stage flags) to card shape", () => {
    const cards = adRunCards([{
      id: "ar1", status: "playing", started_at: "2026-07-06T18:00:00Z",
      system_id: "s1", system_name: "Sys1", location_name: "Loc1",
      campaign_id: "c1", campaign_name: "Camp1",
      stage_decision: true, stage_composition: true, stage_playback: false,
    }]);
    expect(cards[0]).toEqual({
      id: "ar1", campaign: "Camp1", system: "Sys1", location: "Loc1",
      status: "playing", started_at: "2026-07-06T18:00:00Z",
      stageDots: { decision: true, composition: true, playback: false },
    });
  });

  it("falls back to em dash when campaign name is null", () => {
    const cards = adRunCards([{
      id: "ar2", status: "composing", started_at: null,
      system_id: null, system_name: null, location_name: null,
      campaign_id: null, campaign_name: null,
      stage_decision: false, stage_composition: false, stage_playback: false,
    }]);
    expect(cards[0].campaign).toBe("—");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/godview-prototype && npm test -- src/data/selectors.test.ts -t adRunCards`
Expected: FAIL — `adRunCards` signature mismatch.

- [ ] **Step 3: Rewrite adRunCards**

In `/Users/jn/code/godview-prototype/src/data/selectors.ts`, add `AdRunListItem` to the `apiTypes` import, and replace `adRunCards`:
```ts
export interface AdRunCard { id: string; campaign: string; system: string; location: string; status: string; started_at: string; stageDots: { decision: boolean; composition: boolean; playback: boolean } }

export function adRunCards(items: AdRunListItem[]): AdRunCard[] {
  return items.map((r) => ({
    id: r.id,
    campaign: r.campaign_name ?? "—",
    system: r.system_name ?? "—",
    location: r.location_name ?? "—",
    status: r.status,
    started_at: r.started_at ?? "",
    stageDots: { decision: r.stage_decision, composition: r.stage_composition, playback: r.stage_playback },
  }));
}
```

- [ ] **Step 4: Run selector test to verify it passes**

Run: `cd /Users/jn/code/godview-prototype && npm test -- src/data/selectors.test.ts -t adRunCards`
Expected: PASS.

- [ ] **Step 5: Rewrite CompositionActivity (server-side filters + pagination)**

In `/Users/jn/code/godview-prototype/src/pages/CompositionActivity.tsx`, replace imports + data flow. New imports:
```ts
import { useEffect, useState } from "react";
import { Shell } from "../components/Shell";
import { AdRunCard } from "../components/AdRunCard";
import { AsyncState } from "../components/AsyncState";
import { fetchAdRuns, fetchAdRunFilters } from "../data/api";
import { adRunCards } from "../data/selectors";
import type { AdRunsPage, AdRunFilters } from "../data/apiTypes";
```
Replace the mock-based body. Keep the existing filter-control JSX and the `AdRunCard` list JSX; change their data source:
```tsx
const [status, setStatus] = useState("");
const [system, setSystem] = useState("");
const [campaign, setCampaign] = useState("");
const [range, setRange] = useState<"all" | "1h" | "24h">("all");
const [page, setPage] = useState<AdRunsPage | null>(null);
const [items, setItems] = useState<AdRunsPage["items"]>([]);
const [filters, setFilters] = useState<AdRunFilters>({ systems: [], campaigns: [] });
const [loading, setLoading] = useState(true);
const [error, setError] = useState<Error | null>(null);

// map the range control to a `since` ISO timestamp (server-side filter)
const since = range === "1h" ? new Date(Date.now() - 3_600_000).toISOString()
  : range === "24h" ? new Date(Date.now() - 86_400_000).toISOString() : undefined;

useEffect(() => { fetchAdRunFilters().then(setFilters).catch(() => {}); }, []);

useEffect(() => {
  setLoading(true);
  fetchAdRuns({ status: status || undefined, system_id: system || undefined, campaign_id: campaign || undefined, since })
    .then((p) => { setPage(p); setItems(p.items); setError(null); })
    .catch((e) => setError(e instanceof Error ? e : new Error(String(e))))
    .finally(() => setLoading(false));
}, [status, system, campaign, range]);

const loadMore = () => {
  if (!page?.next_cursor) return;
  fetchAdRuns({ status: status || undefined, system_id: system || undefined, campaign_id: campaign || undefined, since, cursor: page.next_cursor })
    .then((p) => { setPage(p); setItems((prev) => [...prev, ...p.items]); });
};

const cards = adRunCards(items);
```
Populate the system/campaign dropdown `<option>`s from `filters.systems` / `filters.campaigns` (id as value, name as label) instead of deriving them from `allCards`. Wrap the card grid in `<AsyncState loading={loading} error={error} hasData={items.length > 0} onRetry={() => setStatus((s) => s)}>`. Add a "Load more" button shown when `page?.next_cursor` is truthy, calling `loadMore`. Remove all `withinTimeRange`/`db` usage.

- [ ] **Step 6: Update CompositionActivity test**

Rewrite `/Users/jn/code/godview-prototype/src/pages/CompositionActivity.test.tsx` to mock `../data/api`:
```tsx
import { describe, expect, it, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { CompositionActivity } from "./CompositionActivity";

vi.mock("../data/api", () => ({
  fetchAdRuns: vi.fn().mockResolvedValue({
    items: [{
      id: "ar_a83f2c", status: "playing", started_at: "2026-07-06T18:00:00Z",
      system_id: "s1", system_name: "Bay 2", location_name: "Downtown",
      campaign_id: "c1", campaign_name: "Lexus Q3",
      stage_decision: true, stage_composition: true, stage_playback: true,
    }],
    next_cursor: null,
  }),
  fetchAdRunFilters: vi.fn().mockResolvedValue({ systems: [{ id: "s1", name: "Bay 2" }], campaigns: [{ id: "c1", name: "Lexus Q3" }] }),
}));

describe("CompositionActivity", () => {
  beforeEach(() => vi.clearAllMocks());
  it("renders ad-run cards from the api", async () => {
    render(<MemoryRouter><CompositionActivity /></MemoryRouter>);
    await waitFor(() => expect(screen.getByText(/Lexus Q3/)).toBeInTheDocument());
  });
});
```

- [ ] **Step 7: Run tests + commit**

Run: `cd /Users/jn/code/godview-prototype && npm test -- src/data/selectors.test.ts src/pages/CompositionActivity.test.tsx`
Expected: PASS.

Delegate commit: stage `src/data/selectors.ts`, `src/data/selectors.test.ts`, `src/pages/CompositionActivity.tsx`, `src/pages/CompositionActivity.test.tsx`; commit:
```
feat: wire Composition Activity to server-filtered, paginated ad-runs
```

---

### Task 4: Wire Ad Detail

**Files:**
- Modify: `/Users/jn/code/godview-prototype/src/data/selectors.ts` (adRunGraph signature)
- Modify: `/Users/jn/code/godview-prototype/src/data/selectors.test.ts`
- Modify: `/Users/jn/code/godview-prototype/src/pages/AdDetail.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/pages/AdDetail.test.tsx`

**Interfaces:**
- Consumes: `fetchAdRun`, `AdRunDetail` payload type.
- Produces: `adRunGraph(detail: AdRunDetail): AdRunGraph` — same node/edge construction as today, sourced from the detail payload (`ad_run`, `personalization_decision`, `composition_run`, `playbacks`) instead of looking rows up in `db`.

- [ ] **Step 1: Update the failing selector test**

In `/Users/jn/code/godview-prototype/src/data/selectors.test.ts`, replace the `adRunGraph` test block with one that passes a detail payload:
```ts
import { adRunGraph } from "./selectors";

describe("adRunGraph", () => {
  const detail = {
    ad_run: { id: "ar1", trigger_id: "trg1", status: "failed", started_at: "2026-07-06T18:00:00Z", ended_at: null, system_id: "s1" },
    personalization_decision: { id: "pd1", decision_type: "identity", decision_confidence: 0.9, decision_factors: { k: "v" } },
    composition_run: { id: "cr1", render_mode: "template_overlay", status: "failed", error_code: "OVERLAY_RENDER_TIMEOUT", error_message: "timeout", used_likeness: true, used_voice_clone: false },
    playbacks: [{ id: "pb1", status: "failed", display_id: null, screen_id: "scr_x", error_code: null, error_message: null }],
  };

  it("builds nodes for the full pipeline including a play node per playback", () => {
    const g = adRunGraph(detail);
    const kinds = g.nodes.map((n) => n.kind);
    expect(kinds).toContain("trigger");
    expect(kinds).toContain("decision");
    expect(kinds).toContain("composition");
    expect(kinds).toContain("adrun");
    expect(g.nodes.some((n) => n.id === "play_0")).toBe(true);
    expect(g.adRun.id).toBe("ar1");
  });

  it("flags the composition->adrun edge failed when composition failed", () => {
    const g = adRunGraph(detail);
    const edge = g.edges.find((e) => e.from === "composition" && e.to === "adrun");
    expect(edge?.failed).toBe(true);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/godview-prototype && npm test -- src/data/selectors.test.ts -t adRunGraph`
Expected: FAIL — `adRunGraph` expects `(db, adRunId)`.

- [ ] **Step 3: Rewrite adRunGraph (preserve node/edge logic, source from payload)**

In `/Users/jn/code/godview-prototype/src/data/selectors.ts`, add `AdRunDetail` to the `apiTypes` import and change the signature + the three lookups. Keep every node/edge the current implementation builds; only change how `adRun`, `decision`, `comp`, and `plays` are obtained:
```ts
export function adRunGraph(detail: AdRunDetail): AdRunGraph {
  const adRun = detail.ad_run;
  const decision = detail.personalization_decision;
  const comp = detail.composition_run;
  const plays = detail.playbacks;
  const compFailed = comp?.status === "failed";
  // ... KEEP the existing node[] and edge[] construction verbatim, but read fields from
  //     adRun/decision/comp/plays above. Field sources:
  //       decision node data: decision?.decision_type, decision?.decision_confidence, decision?.decision_factors
  //       composition node data: comp?.render_mode, comp?.status, comp?.error_code, comp?.error_message, comp?.used_likeness, comp?.used_voice_clone
  //       one play_{i} node per plays[i]; adrun->play_i edge ghost when compFailed
  //       trigger node label from adRun.trigger_id
  //     Return { nodes, edges, adRun }.
}
```
Because `adRunGraph` no longer receives `db`, `AdRunGraph.adRun`'s type is now the detail payload's `ad_run` object (which carries `id`, `trigger_id`, `status`, `started_at`, `ended_at`, `system_id`). Update the `AdRunGraph` interface's `adRun` field type from `AdRun` to `AdRunDetail["ad_run"]`, and drop the now-unused `AdRun` import if nothing else uses it.

- [ ] **Step 4: Run selector test to verify it passes**

Run: `cd /Users/jn/code/godview-prototype && npm test -- src/data/selectors.test.ts -t adRunGraph`
Expected: PASS.

- [ ] **Step 5: Rewrite AdDetail data acquisition**

In `/Users/jn/code/godview-prototype/src/pages/AdDetail.tsx`, replace imports + data flow. New imports:
```ts
import { useEffect, useMemo, useState } from "react";
import { useParams } from "react-router-dom";
import { ReactFlow, Background } from "@xyflow/react";
import { Shell } from "../components/Shell";
import { PipelineNode } from "../components/PipelineNode";
import { Inspector } from "../components/Inspector";
import { AsyncState } from "../components/AsyncState";
import { fetchAdRun } from "../data/api";
import { adRunGraph } from "../data/selectors";
import type { AdRunDetail } from "../data/apiTypes";
```
Replace the memoized `adRunGraph(db, adRunId!)` block:
```tsx
const { adRunId } = useParams();
const [detail, setDetail] = useState<AdRunDetail | null>(null);
const [loading, setLoading] = useState(true);
const [error, setError] = useState<Error | null>(null);

useEffect(() => {
  if (!adRunId) return;
  setLoading(true);
  fetchAdRun(adRunId)
    .then((d) => { setDetail(d); setError(null); })
    .catch((e) => setError(e instanceof Error ? e : new Error(String(e))))
    .finally(() => setLoading(false));
}, [adRunId]);

const g = useMemo(() => (detail ? adRunGraph(detail) : null), [detail]);
```
Guard the render on `g` (the graph is null until loaded). Wrap the page body in `<AsyncState loading={loading} error={error} hasData={!!g} onRetry={() => adRunId && fetchAdRun(adRunId).then(setDetail)}>`. Keep the existing `failedId`/`selected`/`rfNodes`/`rfEdges`/`Inspector` logic, but derive them from `g` (return early / render the AsyncState fallback when `g` is null). A 404 (unknown ad-run) surfaces via `error`.

- [ ] **Step 6: Update AdDetail test**

Rewrite `/Users/jn/code/godview-prototype/src/pages/AdDetail.test.tsx` to mock the api and render at a route:
```tsx
import { describe, expect, it, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Routes, Route } from "react-router-dom";
import { AdDetail } from "./AdDetail";

vi.mock("../data/api", () => ({
  fetchAdRun: vi.fn().mockResolvedValue({
    ad_run: { id: "ar_d3aa77", trigger_id: "trg1", status: "failed", started_at: "2026-07-06T18:00:00Z", ended_at: null, system_id: "s1" },
    personalization_decision: { id: "pd1", decision_type: "identity", decision_confidence: 0.9, decision_factors: {} },
    composition_run: { id: "cr1", render_mode: "template_overlay", status: "failed", error_code: "OVERLAY_RENDER_TIMEOUT", error_message: "timeout", used_likeness: true, used_voice_clone: false },
    playbacks: [{ id: "pb1", status: "failed", display_id: null, screen_id: "scr_x", error_code: null, error_message: null }],
  }),
}));

describe("AdDetail", () => {
  beforeEach(() => vi.clearAllMocks());
  it("fetches the ad-run and renders its graph inspector", async () => {
    render(
      <MemoryRouter initialEntries={["/compositions/ar_d3aa77"]}>
        <Routes><Route path="/compositions/:adRunId" element={<AdDetail />} /></Routes>
      </MemoryRouter>,
    );
    await waitFor(() => expect(screen.getByText(/OVERLAY_RENDER_TIMEOUT/)).toBeInTheDocument());
  });
});
```
(If the existing `PipelineNode`/`ReactFlow` render doesn't surface the `OVERLAY_RENDER_TIMEOUT` string in the DOM, assert on a string the Inspector panel does render from `composition_run` — e.g. the render mode `template_overlay` — instead.)

- [ ] **Step 7: Run tests + commit**

Run: `cd /Users/jn/code/godview-prototype && npm test -- src/data/selectors.test.ts src/pages/AdDetail.test.tsx`
Expected: PASS.

Delegate commit: stage `src/data/selectors.ts`, `src/data/selectors.test.ts`, `src/pages/AdDetail.tsx`, `src/pages/AdDetail.test.tsx`; commit:
```
feat: wire Ad Detail graph to /god-view/ad-runs/{id}
```

---

### Task 5: Wire Systems & Logs

**Files:**
- Modify: `/Users/jn/code/godview-prototype/src/data/selectors.ts` (systemsWithRollup, systemsKpis, systemDrilldown, eventLog signatures; remove orphaned `camerasWithReading` + unused `Db`-only imports)
- Modify: `/Users/jn/code/godview-prototype/src/data/selectors.test.ts`
- Modify: `/Users/jn/code/godview-prototype/src/pages/SystemsLogs.tsx`
- Modify: `/Users/jn/code/godview-prototype/src/pages/SystemsLogs.test.tsx`

**Interfaces:**
- Consumes: `fetchSystems`, `fetchSystem`, `fetchEvents`, payload types.
- Produces (new signatures):
  - `systemsWithRollup(items: SystemListItem[]): SystemRow[]`
  - `systemsKpis(counts: SystemCounts): SystemsKpis`
  - `systemDrilldown(detail: SystemDetail): Drilldown`
  - `eventLog(items: EventItem[]): LogRow[]`

- [ ] **Step 1: Update the failing selector tests**

In `/Users/jn/code/godview-prototype/src/data/selectors.test.ts`, replace the `systemsWithRollup`, `systemsKpis`, `systemDrilldown`, and `eventLog` blocks with:
```ts
import { systemsWithRollup, systemsKpis, systemDrilldown, eventLog } from "./selectors";

describe("systemsWithRollup", () => {
  it("maps server rows (names + device_count) to row shape", () => {
    const rows = systemsWithRollup([{
      id: "s1", name: "Bay 2", org_name: "Lexus", location_name: "Downtown",
      system_type: "onsite_mras", status: "active", device_count: 3,
    }]);
    expect(rows[0]).toEqual({ id: "s1", name: "Bay 2", org: "Lexus", location: "Downtown", system_type: "onsite_mras", status: "active", device_count: 3 });
  });
});

describe("systemsKpis", () => {
  it("computes healthy_pct from counts", () => {
    expect(systemsKpis({ total_systems: 4, active_systems: 3, unresolved_devices: 2 }))
      .toEqual({ total: 4, healthyPct: 75, unresolvedDevices: 2 });
  });
  it("is 0% when there are no systems", () => {
    expect(systemsKpis({ total_systems: 0, active_systems: 0, unresolved_devices: 0 }).healthyPct).toBe(0);
  });
});

describe("systemDrilldown", () => {
  it("groups cameras/displays by screen_group and lists ungrouped", () => {
    const d = systemDrilldown({
      system: { id: "s1", name: "Bay 2", status: "active", system_type: "onsite_mras" },
      screen_groups: [{ id: "g1", name: "Wall A", group_type: "ad_cluster" }],
      cameras: [
        { id: "c1", name: "C1", status: "active", screen_group_id: "g1", face_count: 1, confidence: 0.5 },
        { id: "c2", name: "C2", status: "active", screen_group_id: null, face_count: 0, confidence: 0 },
      ],
      displays: [{ id: "d1", name: "D1", status: "active", screen_id: "scr_d1", screen_group_id: "g1" }],
    });
    expect(d.groups[0].group.name).toBe("Wall A");
    expect(d.groups[0].cameras.map((c) => c.id)).toEqual(["c1"]);
    expect(d.groups[0].displays.map((x) => x.id)).toEqual(["d1"]);
    expect(d.ungroupedCameras.map((c) => c.id)).toEqual(["c2"]);
  });
});

describe("eventLog", () => {
  it("maps ref_id to ref", () => {
    const rows = eventLog([{ id: "e1", kind: "system", ref_id: "s1", ref_name: "Sys1", status: "degraded", detail: "cpu", observed_at: "2026-07-06T10:00:00Z" }]);
    expect(rows[0]).toEqual({ id: "e1", kind: "system", ref: "s1", status: "degraded", detail: "cpu", observed_at: "2026-07-06T10:00:00Z" });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/godview-prototype && npm test -- src/data/selectors.test.ts`
Expected: FAIL — these four selectors' signatures don't match.

- [ ] **Step 3: Rewrite the four selectors (logic preserved)**

In `/Users/jn/code/godview-prototype/src/data/selectors.ts`:

Add payload types to the import: `SystemListItem, SystemCounts, SystemDetail, EventItem`. The `Drilldown` interface currently references `System`, `Camera`, `Display`, `ScreenGroup` from `./types`; retype it to the `SystemDetail` sub-shapes so no `Db` types are needed:

```ts
export interface SystemRow { id: string; name: string; org: string; location: string; system_type: string; status: string; device_count: number; }
export function systemsWithRollup(items: SystemListItem[]): SystemRow[] {
  return items.map((s) => ({
    id: s.id, name: s.name, org: s.org_name ?? "—", location: s.location_name ?? "—",
    system_type: s.system_type, status: s.status, device_count: s.device_count,
  }));
}

export interface SystemsKpis { total: number; healthyPct: number; unresolvedDevices: number; }
export function systemsKpis(counts: SystemCounts): SystemsKpis {
  const total = counts.total_systems;
  const healthyPct = total === 0 ? 0 : Math.round((counts.active_systems / total) * 100);
  return { total, healthyPct, unresolvedDevices: counts.unresolved_devices };
}

type DetailCamera = SystemDetail["cameras"][number];
type DetailDisplay = SystemDetail["displays"][number];
type DetailGroup = SystemDetail["screen_groups"][number];
export interface Drilldown {
  system: SystemDetail["system"];
  groups: { group: DetailGroup; cameras: DetailCamera[]; displays: DetailDisplay[] }[];
  ungroupedCameras: DetailCamera[];
  ungroupedDisplays: DetailDisplay[];
}
export function systemDrilldown(detail: SystemDetail): Drilldown {
  const groups = detail.screen_groups.map((group) => ({
    group,
    cameras: detail.cameras.filter((c) => c.screen_group_id === group.id),
    displays: detail.displays.filter((d) => d.screen_group_id === group.id),
  }));
  return {
    system: detail.system,
    groups,
    ungroupedCameras: detail.cameras.filter((c) => !c.screen_group_id),
    ungroupedDisplays: detail.displays.filter((d) => !d.screen_group_id),
  };
}

export interface LogRow { id: string; kind: string; ref: string; status: string; detail: string; observed_at: string; }
export function eventLog(items: EventItem[]): LogRow[] {
  return items.map((h) => ({ id: h.id, kind: h.kind, ref: h.ref_id, status: h.status, detail: h.detail, observed_at: h.observed_at }));
}
```

Remove the now-orphaned `camerasWithReading` function and the `CameraReading` join it used. Then reconcile the top-of-file imports: `Db` is no longer referenced by any selector, and `AdRun`/`Camera`/`Display`/`ScreenGroup`/`System` may be unused — delete whichever `./types` imports are no longer referenced (TypeScript will flag them). Keep `withinTimeRange` and its `TimeRange` type (still exported, still unit-tested; no page uses it now but it is harmless and its test stays).

- [ ] **Step 4: Run selector test to verify it passes**

Run: `cd /Users/jn/code/godview-prototype && npm test -- src/data/selectors.test.ts`
Expected: PASS (full selector suite).

- [ ] **Step 5: Rewrite SystemsLogs data acquisition**

In `/Users/jn/code/godview-prototype/src/pages/SystemsLogs.tsx`, replace imports + data flow. New imports:
```ts
import { Fragment, useEffect, useState } from "react";
import { Shell } from "../components/Shell";
import { StatusDot } from "../components/StatusDot";
import { AsyncState } from "../components/AsyncState";
import { usePolling } from "../hooks/usePolling";
import { fetchSystems, fetchSystem, fetchEvents } from "../data/api";
import { systemsWithRollup, systemsKpis, systemDrilldown, eventLog } from "../data/selectors";
import type { SystemDetail } from "../data/apiTypes";
```
Replace the mock body. Keep the KPI strip, the systems table, the drill-down section, the event-log list, and the unresolved banner JSX; change their sources:
```tsx
const [search, setSearch] = useState("");
const { data: sysPage, loading, error, refetch } = usePolling(() => fetchSystems({ search: search || undefined }), 5000);
const { data: eventsPage } = usePolling(() => fetchEvents({ limit: 20 }), 5000);
const [open, setOpen] = useState<string | null>(null);
const [detail, setDetail] = useState<SystemDetail | null>(null);

useEffect(() => {
  if (!open) { setDetail(null); return; }
  fetchSystem(open).then(setDetail).catch(() => setDetail(null));
}, [open]);

const rows = sysPage ? systemsWithRollup(sysPage.items) : [];
const kpis = sysPage ? systemsKpis(sysPage.counts) : { total: 0, healthyPct: 0, unresolvedDevices: 0 };
const log = eventsPage ? eventLog(eventsPage.items) : [];
const drill = detail ? systemDrilldown(detail) : null;
```
Wire the search `<input>` to `setSearch` (its change re-runs the polled `fetchSystems` via the `usePolling` factory closure — because `usePolling`'s effect depends on the factory identity, hoist the factory into a `useCallback([search])` or key the polling by remounting; simplest: pass `search` through a `useState` and read it inside the factory, and additionally call `refetch()` in the input's `onChange` after `setSearch` to fetch immediately). The unresolved banner reads `kpis.unresolvedDevices` (remove the old inline `db.playbacks.filter(...)`). The drill-down section renders from `drill` when a row is `open` (remove the inline `systemDrilldown(db, r.id)`). Remove the top-level `camerasWithReading` readings section — per-camera readings now render inside the drill-down from `detail.cameras` (each has `face_count`/`confidence`). Wrap the systems table in `<AsyncState loading={loading} error={error} hasData={rows.length > 0} onRetry={refetch}>`.

Note on the search + `usePolling` interaction: `usePolling` re-subscribes when the factory function identity changes. Define the factory with `useCallback(() => fetchSystems({ search: search || undefined }), [search])` and pass it to `usePolling` so changing `search` re-polls with the new term. Update `usePolling`'s call site accordingly.

- [ ] **Step 6: Update SystemsLogs test**

Rewrite `/Users/jn/code/godview-prototype/src/pages/SystemsLogs.test.tsx` to mock `../data/api`:
```tsx
import { describe, expect, it, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { SystemsLogs } from "./SystemsLogs";

vi.mock("../data/api", () => ({
  fetchSystems: vi.fn().mockResolvedValue({
    counts: { total_systems: 2, active_systems: 1, unresolved_devices: 1 },
    items: [{ id: "s1", name: "Bay 2", org_name: "Lexus", location_name: "Downtown", system_type: "onsite_mras", status: "active", device_count: 3 }],
    next_cursor: null,
  }),
  fetchEvents: vi.fn().mockResolvedValue({
    items: [{ id: "e1", kind: "system", ref_id: "s1", ref_name: "Bay 2", status: "degraded", detail: "cpu high", observed_at: "2026-07-06T10:00:00Z" }],
    next_cursor: null,
  }),
  fetchSystem: vi.fn().mockResolvedValue({
    system: { id: "s1", name: "Bay 2", status: "active", system_type: "onsite_mras" },
    screen_groups: [], cameras: [], displays: [],
  }),
}));

describe("SystemsLogs", () => {
  beforeEach(() => vi.clearAllMocks());
  it("renders systems rows, kpis, and the event log from the api", async () => {
    render(<MemoryRouter><SystemsLogs /></MemoryRouter>);
    await waitFor(() => expect(screen.getByText(/Bay 2/)).toBeInTheDocument());
    expect(screen.getByText(/cpu high/)).toBeInTheDocument();
  });
});
```

- [ ] **Step 7: Run the full suite + commit + PR**

Run: `cd /Users/jn/code/godview-prototype && npm test`
Expected: ALL suites PASS (api, usePolling, selectors, all four pages).

Delegate commit: stage `src/data/selectors.ts`, `src/data/selectors.test.ts`, `src/pages/SystemsLogs.tsx`, `src/pages/SystemsLogs.test.tsx`; commit:
```
feat: wire Systems & Logs to server-paginated systems + on-demand drill-down + events
```

Then open a PR targeting `main`:
- Title: `feat: wire God View prototype to live ops-api read endpoints`
- Body: Summary (mock `db` → live polling of Plan A endpoints; selectors keep view logic), Motivation (real data, scale-safe), Implementation (api client + usePolling + per-page wiring; readings moved to drill-down), Tests (api/hook/selectors/pages green), Risks (depends on Plan A endpoints deployed; polling every 5s; unscoped reads).
- Do NOT merge; report the PR number.

---

## Self-Review

- **Spec coverage:** §5 api.ts/usePolling/env → Task 1; Main Dashboard + badge → Task 2; Composition Activity (filters+pagination) → Task 3; Ad Detail → Task 4; Systems & Logs (list+drilldown+events) → Task 5; loading/error/empty (`AsyncState`) → Task 1, applied per page; "keep logic client-side" honored (every retained selector's body preserved, only inputs redirected).
- **Placeholder scan:** the two "keep the existing construction verbatim" notes (adRunGraph node/edge body; page JSX preservation) are deliberate — they instruct the implementer to preserve existing code they can read, not to invent. All new/changed function bodies are literal. No TBDs.
- **Type consistency:** payload interfaces in `apiTypes.ts` are the single source; every selector's new input type is imported from there. `fleetSummary(FleetCounts)`, `recentFailures(FailedRun[], HealthDrop[], number)`, `adRunCards(AdRunListItem[])`, `adRunGraph(AdRunDetail)`, `systemsWithRollup(SystemListItem[])`, `systemsKpis(SystemCounts)`, `systemDrilldown(SystemDetail)`, `eventLog(EventItem[])` all match their consuming pages. `activeAdRuns`/`camerasWithReading` removals are each done in the task after their last caller migrates (Dashboard, Systems) — no dangling references. `AdRunGraph.adRun` retyped to `AdRunDetail["ad_run"]`.
- **Cross-plan consistency:** every payload field consumed here (e.g. `org_count`, `active_runs[].system_name`, `stage_*`, `counts.*`, `SystemDetail.cameras[].face_count`) is produced by a Plan A endpoint. `org_count` must be added to Plan A's `/god-view/dashboard` return (see Plan A Task 2) — flagged for reconciliation.
