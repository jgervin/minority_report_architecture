# God View Prototype App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone, mock-data-first God View prototype (shadcn/ui dark console) with four pages — Main Dashboard, Composition Activity, Ad Detail (n8n-style flow), and Systems & Logs — plus the app shell and a typed mock-data layer.

**Architecture:** A brand-new Vite + React + TypeScript app in `godview-prototype/`, decoupled from `mras-ops/frontend`. All data comes from typed in-repo fixtures shaped to the real MRAS schema (real table/column/enum names); pure **selector** functions derive page view-models from fixtures and are unit-tested. Pages consume selectors and render with shadcn components; the Ad Detail page renders a node graph with `@xyflow/react`. Wiring to a live ops-api is explicitly out of scope for this plan (see spec §8).

**Tech Stack:** Vite 5, React 18, TypeScript 5, Tailwind CSS 3, shadcn/ui (Radix + lucide-react), `react-router-dom` v6, `@xyflow/react` v12 (the package formerly published as `reactflow`), Vitest + @testing-library/react + jsdom.

**Spec:** `/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-07-godview-prototype-ux-design.md`.
**Approved wireframe reference:** the dark-console Main Dashboard + Ad Detail mockup reviewed in the 2026-07-07 design session.

## Global Constraints

- App root: `/Users/jn/code/godview-prototype/` (new directory, its own git repo OR a subdir — Task 1 initializes it; git delegated to `git-flow-manager`, never run raw git as the main agent).
- **Real schema names only** — components, types, and fixtures use the exact table/column/enum names from `mras-ops/db/migrations/010`–`025` (e.g. `lifecycle_status` values `planned|active|inactive|degraded|offline|retired`; `device_status` values `active|degraded|offline|retired`; `ad_run_status` values `planned|composing|ready|dispatched|playing|completed|failed|canceled`). No invented naming layer.
- **Two distinct status enums stay visually distinct** — `lifecycle_status` (org/location/system) and `device_status` (device/camera/display) get separate color/label mappings; never unify them.
- Dark theme, monospace for data/status figures, sans for headings/body — matching the approved wireframe.
- `playbacks` is keyed on `(trigger_id, screen_id)` with **nullable `display_id`** (migration 021); UI must tolerate an unresolved `screen_id` with no `screen_group` and fall back to the raw `screen_id`.
- `ad_runs` has **no** `error_code`/`error_message`; a failed ad-run's reason is surfaced from its `composition_run`/`playback`.
- Viewer-exposure/attention data and the map/globe view are OUT OF SCOPE (spec §9). The Ad Detail graph shows a disabled/ghosted Viewer Exposure node only.

---

### Task 1: Scaffold the app (build + tooling + one smoke test)

**Files:**
- Create: `/Users/jn/code/godview-prototype/package.json`, `vite.config.ts`, `tsconfig.json`, `tailwind.config.ts`, `postcss.config.js`, `index.html`, `src/main.tsx`, `src/index.css`, `src/App.tsx`, `src/vite-env.d.ts`
- Test: `/Users/jn/code/godview-prototype/src/App.test.tsx`, `vitest.config.ts`, `src/test/setup.ts`

**Interfaces:**
- Produces: a running Vite dev server, a Vitest test runner with jsdom + Testing Library, Tailwind with the dark-console token set, and `App` (the root component with the router mounted in later tasks).

- [ ] **Step 1: Initialize the project and install deps**

Run:
```bash
mkdir -p /Users/jn/code/godview-prototype && cd /Users/jn/code/godview-prototype
npm create vite@latest . -- --template react-ts
npm install
npm install react-router-dom @xyflow/react lucide-react class-variance-authority clsx tailwind-merge
npm install -D tailwindcss postcss autoprefixer vitest @testing-library/react @testing-library/jest-dom jsdom @types/node
npx tailwindcss init -p
```
Expected: `node_modules/` populated, `tailwind.config.js` + `postcss.config.js` created.

- [ ] **Step 2: Configure Tailwind with the dark-console tokens**

Replace `/Users/jn/code/godview-prototype/tailwind.config.ts` (rename from `.js` if needed):

```ts
import type { Config } from "tailwindcss";

export default {
  darkMode: "class",
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        bg: "#0a0d12", elev: "#12161d", elev2: "#171c25", sidebar: "#0d1016",
        border: "#212734", borderSoft: "#1a2029",
        text: "#e6e9ee", dim: "#8b93a3", faint: "#5b6472",
        accent: "#45c4ff",
        ok: "#34d399", warn: "#f5b942", crit: "#f2545b", off: "#5b6472",
      },
      fontFamily: {
        mono: ["ui-monospace", "SF Mono", "Cascadia Code", "monospace"],
        sans: ["ui-sans-serif", "-apple-system", "Segoe UI", "Roboto", "sans-serif"],
      },
    },
  },
  plugins: [],
} satisfies Config;
```

- [ ] **Step 3: Set up the test runner**

Create `/Users/jn/code/godview-prototype/vitest.config.ts`:

```ts
import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";
import path from "node:path";

export default defineConfig({
  plugins: [react()],
  test: { environment: "jsdom", globals: true, setupFiles: "./src/test/setup.ts" },
  resolve: { alias: { "@": path.resolve(__dirname, "./src") } },
});
```

Create `/Users/jn/code/godview-prototype/src/test/setup.ts`:

```ts
import "@testing-library/jest-dom";
```

Add the alias to `tsconfig.json` `compilerOptions`: `"baseUrl": ".", "paths": { "@/*": ["src/*"] }`.
Add scripts to `package.json`: `"test": "vitest run"`, `"test:watch": "vitest"`.

- [ ] **Step 4: Replace `src/index.css` and `src/App.tsx` with the shell placeholder**

`/Users/jn/code/godview-prototype/src/index.css`:

```css
@tailwind base;
@tailwind components;
@tailwind utilities;

:root { color-scheme: dark; }
html, body, #root { height: 100%; }
body { @apply bg-bg text-text font-sans; margin: 0; }
```

`/Users/jn/code/godview-prototype/src/App.tsx`:

```tsx
export default function App() {
  return <div data-testid="app-root">God View</div>;
}
```

- [ ] **Step 5: Write the failing smoke test**

`/Users/jn/code/godview-prototype/src/App.test.tsx`:

```tsx
import { render, screen } from "@testing-library/react";
import App from "./App";

test("App renders the God View root", () => {
  render(<App />);
  expect(screen.getByTestId("app-root")).toHaveTextContent("God View");
});
```

- [ ] **Step 6: Run the test (expect it to pass once wired)**

Run: `cd /Users/jn/code/godview-prototype && npm test`
Expected: 1 passed. (If it fails on config, fix vitest/tailwind wiring until green — this task's deliverable is a working toolchain.)

- [ ] **Step 7: Verify the build**

Run: `cd /Users/jn/code/godview-prototype && npm run build`
Expected: build succeeds, `dist/` produced.

- [ ] **Step 8: Commit (git-flow-manager)**

Delegate: init repo (if standalone) / branch `feat/scaffold`, commit all scaffold files as `chore: scaffold godview-prototype (vite+react+ts+tailwind+vitest)`.

---

### Task 2: Domain types + mock fixtures + selectors (the data layer)

**Files:**
- Create: `/Users/jn/code/godview-prototype/src/data/types.ts`, `src/data/fixtures.ts`, `src/data/selectors.ts`
- Test: `/Users/jn/code/godview-prototype/src/data/selectors.test.ts`

**Interfaces:**
- Produces:
  - Types (real schema shape): `Organization`, `Location`, `System`, `Device`, `Camera`, `Display`, `ScreenGroup`, `AdRun`, `CompositionRun`, `PersonalizationDecision`, `Playback`, `HealthEvent`, plus enum string-union types `LifecycleStatus`, `DeviceStatus`, `AdRunStatus`, `CompositionStatus`.
  - `db` — the fixture dataset (arrays of the above).
  - Selectors: `fleetSummary(db): { total: number; healthy: number; degraded: number; offline: number }`, `activeAdRuns(db): AdRun[]` (status in composing/dispatched/playing), `recentFailures(db, limit): FailureRow[]`, `systemsWithRollup(db): SystemRow[]`, `adRunGraph(db, adRunId): AdRunGraph`, `camerasWithReading(db): CameraReading[]`.

- [ ] **Step 1: Write the types**

`/Users/jn/code/godview-prototype/src/data/types.ts`:

```ts
export type LifecycleStatus = "planned" | "active" | "inactive" | "degraded" | "offline" | "retired";
export type DeviceStatus = "active" | "degraded" | "offline" | "retired";
export type AdRunStatus = "planned" | "composing" | "ready" | "dispatched" | "playing" | "completed" | "failed" | "canceled";
export type CompositionStatus = "queued" | "selected" | "rendering" | "rendered" | "failed" | "canceled";
export type PlaybackStatus = "dispatched" | "started" | "ended" | "failed" | "interrupted" | "unknown";

export interface Organization { id: string; name: string; organization_type: string; status: LifecycleStatus; }
export interface Location { id: string; name: string; location_type: string; city?: string; status: LifecycleStatus; }
export interface System { id: string; organization_id: string; location_id: string; name: string; system_type: string; status: LifecycleStatus; }
export interface ScreenGroup { id: string; system_id: string; name: string; group_type: "zone" | "ad_cluster" | "custom"; status: LifecycleStatus; }
export interface Camera { id: string; system_id: string; screen_group_id?: string; name: string; camera_role: string; screen_id?: string; status: DeviceStatus; last_seen_at?: string; }
export interface Display { id: string; system_id: string; screen_group_id?: string; name: string; screen_id: string; display_role: string; status: DeviceStatus; last_seen_at?: string; }

export interface PersonalizationDecision { id: string; trigger_id: string; decision_type: string; target_subject_profile_id?: string; decision_confidence?: number; decision_factors: Record<string, unknown>; }
export interface CompositionRun { id: string; trigger_id: string; ad_id?: string; component_id?: string; input_asset_id?: string; output_asset_id?: string; render_mode: string; status: CompositionStatus; used_spoken_name: boolean; used_visible_name: boolean; used_likeness: boolean; used_voice_clone: boolean; error_code?: string; error_message?: string; started_at?: string; ended_at?: string; }
export interface AdRun { id: string; trigger_id: string; organization_id: string; location_id: string; system_id: string; display_id?: string; campaign_id?: string; ad_id?: string; personalization_decision_id?: string; composition_run_id?: string; status: AdRunStatus; started_at?: string; ended_at?: string; }
export interface Playback { id: string; ad_run_id: string; trigger_id: string; system_id: string; display_id?: string; screen_id: string; status: PlaybackStatus; error_code?: string; error_message?: string; }

export interface HealthEvent { id: string; kind: "device" | "system"; ref_id: string; status: string; detail: string; observed_at: string; }

// live camera detection reading (mock — mirrors what subject_observations would summarize)
export interface CameraReading { camera_id: string; face_count: number; confidence: number; }

export interface Db {
  organizations: Organization[]; locations: Location[]; systems: System[];
  screen_groups: ScreenGroup[]; cameras: Camera[]; displays: Display[];
  personalization_decisions: PersonalizationDecision[]; composition_runs: CompositionRun[];
  ad_runs: AdRun[]; playbacks: Playback[]; health_events: HealthEvent[]; camera_readings: CameraReading[];
}
```

- [ ] **Step 2: Write the fixtures**

Create `/Users/jn/code/godview-prototype/src/data/fixtures.ts` exporting `export const db: Db = {...}`. Populate with a realistic dataset that exercises every page state: at least **3 organizations**, **4 locations** (mix of `building`/`mall`/`store` types), **6 systems** (statuses spanning `active`/`degraded`/`offline`), **~12 devices** split into cameras/displays, at least **one multi-display `screen_group`** ("Entrance Wall A" with 1 camera + 3 displays), **~8 ad_runs** covering `composing`/`playing`/`completed`/`failed`/`canceled`, with matching `personalization_decisions`, `composition_runs` (include one `failed` with `error_code: "OVERLAY_RENDER_TIMEOUT"`), `playbacks` (include one with nullable `display_id` to exercise the unresolved-screen_id path), `health_events` (a mix of device/system drops), and `camera_readings` (include one offline camera with `face_count: 0`). Use real enum values only. IDs are short readable strings (e.g. `"org_lexus"`, `"sys_bay2"`, `"ar_a83f2c"`).

- [ ] **Step 3: Write the failing selector tests**

`/Users/jn/code/godview-prototype/src/data/selectors.test.ts`:

```ts
import { db } from "./fixtures";
import { fleetSummary, activeAdRuns, recentFailures, systemsWithRollup, adRunGraph } from "./selectors";

test("fleetSummary counts systems by health bucket", () => {
  const s = fleetSummary(db);
  expect(s.total).toBe(db.systems.length);
  expect(s.healthy + s.degraded + s.offline).toBeLessThanOrEqual(s.total);
  expect(s.healthy).toBe(db.systems.filter((x) => x.status === "active").length);
});

test("activeAdRuns returns only in-flight runs", () => {
  const runs = activeAdRuns(db);
  expect(runs.length).toBeGreaterThan(0);
  for (const r of runs) expect(["composing", "dispatched", "playing"]).toContain(r.status);
});

test("recentFailures surfaces failed runs and health drops, newest first, capped", () => {
  const f = recentFailures(db, 5);
  expect(f.length).toBeLessThanOrEqual(5);
  for (let i = 1; i < f.length; i++) expect(f[i - 1].when >= f[i].when).toBe(true);
});

test("systemsWithRollup attaches a device count per system", () => {
  const rows = systemsWithRollup(db);
  expect(rows.length).toBe(db.systems.length);
  const row = rows[0];
  expect(row).toHaveProperty("device_count");
  expect(typeof row.device_count).toBe("number");
});

test("adRunGraph builds nodes+edges for a known failed ad run", () => {
  const failed = db.ad_runs.find((r) => r.status === "failed")!;
  const g = adRunGraph(db, failed.id);
  const ids = g.nodes.map((n) => n.id);
  expect(ids).toEqual(expect.arrayContaining(["trigger", "decision", "composition", "adrun"]));
  // the failed composition node carries the error surfaced from composition_runs
  const comp = g.nodes.find((n) => n.id === "composition")!;
  expect(comp.data.status).toBe("failed");
  expect(comp.data.error_code).toBeTruthy();
});
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `cd /Users/jn/code/godview-prototype && npm test -- selectors`
Expected: FAIL — `selectors.ts` has no exports yet.

- [ ] **Step 5: Implement the selectors**

`/Users/jn/code/godview-prototype/src/data/selectors.ts`:

```ts
import type { Db, AdRun } from "./types";

export function fleetSummary(db: Db) {
  const by = (s: string) => db.systems.filter((x) => x.status === s).length;
  return {
    total: db.systems.length,
    healthy: by("active"),
    degraded: by("degraded"),
    offline: by("offline"),
  };
}

export function activeAdRuns(db: Db): AdRun[] {
  const live = new Set(["composing", "dispatched", "playing"]);
  return db.ad_runs.filter((r) => live.has(r.status));
}

export interface FailureRow { id: string; severity: "crit" | "warn"; message: string; where: string; when: string; adRunId?: string; }
export function recentFailures(db: Db, limit: number): FailureRow[] {
  const sysName = (id: string) => db.systems.find((s) => s.id === id)?.name ?? id;
  const fromRuns: FailureRow[] = db.ad_runs
    .filter((r) => r.status === "failed")
    .map((r) => {
      const comp = db.composition_runs.find((c) => c.id === r.composition_run_id);
      return { id: r.id, severity: "crit" as const, message: comp?.error_code ?? "ad run failed",
        where: sysName(r.system_id), when: r.ended_at ?? r.started_at ?? "", adRunId: r.id };
    });
  const fromHealth: FailureRow[] = db.health_events
    .filter((h) => h.status === "offline" || h.status === "degraded")
    .map((h) => ({ id: h.id, severity: h.status === "offline" ? "crit" : "warn",
      message: h.detail, where: h.ref_id, when: h.observed_at }));
  return [...fromRuns, ...fromHealth].sort((a, b) => (a.when < b.when ? 1 : -1)).slice(0, limit);
}

export interface SystemRow { id: string; name: string; org: string; location: string; system_type: string; status: string; device_count: number; }
export function systemsWithRollup(db: Db): SystemRow[] {
  return db.systems.map((s) => ({
    id: s.id, name: s.name,
    org: db.organizations.find((o) => o.id === s.organization_id)?.name ?? s.organization_id,
    location: db.locations.find((l) => l.id === s.location_id)?.name ?? s.location_id,
    system_type: s.system_type, status: s.status,
    device_count: db.cameras.filter((c) => c.system_id === s.id).length
                + db.displays.filter((d) => d.system_id === s.id).length,
  }));
}

export interface CameraReadingRow { id: string; name: string; system: string; status: string; face_count: number; confidence: number; }
export function camerasWithReading(db: Db): CameraReadingRow[] {
  return db.cameras.map((c) => {
    const r = db.camera_readings.find((x) => x.camera_id === c.id);
    return { id: c.id, name: c.name,
      system: db.systems.find((s) => s.id === c.system_id)?.name ?? c.system_id,
      status: c.status, face_count: r?.face_count ?? 0, confidence: r?.confidence ?? 0 };
  });
}

export interface GraphNode { id: string; kind: string; label: string; data: Record<string, any>; x: number; y: number; ghost?: boolean; }
export interface GraphEdge { from: string; to: string; failed?: boolean; ghost?: boolean; }
export interface AdRunGraph { nodes: GraphNode[]; edges: GraphEdge[]; adRun: AdRun; }
export function adRunGraph(db: Db, adRunId: string): AdRunGraph {
  const adRun = db.ad_runs.find((r) => r.id === adRunId)!;
  const decision = db.personalization_decisions.find((d) => d.id === adRun.personalization_decision_id);
  const comp = db.composition_runs.find((c) => c.id === adRun.composition_run_id);
  const plays = db.playbacks.filter((p) => p.ad_run_id === adRun.id);
  const compFailed = comp?.status === "failed";

  const nodes: GraphNode[] = [
    { id: "trigger", kind: "trigger", label: "Trigger", data: { trigger_id: adRun.trigger_id }, x: 0, y: 40 },
    { id: "decision", kind: "decision", label: "Decision",
      data: { decision_type: decision?.decision_type, confidence: decision?.decision_confidence,
              factors: decision?.decision_factors }, x: 200, y: 40 },
    { id: "composition", kind: "composition", label: "Composition",
      data: { render_mode: comp?.render_mode, status: comp?.status,
              error_code: comp?.error_code, error_message: comp?.error_message,
              used_likeness: comp?.used_likeness, used_voice_clone: comp?.used_voice_clone }, x: 420, y: 40 },
    { id: "adrun", kind: "adrun", label: "Ad Run", data: { status: adRun.status }, x: 640, y: 40 },
    ...plays.map((p, i): GraphNode => ({ id: `play_${i}`, kind: "playback",
      label: "Playback", data: { screen_id: p.screen_id, display_id: p.display_id ?? "(unresolved)", status: p.status }, x: 860, y: 20 + i * 90 })),
    { id: "exposure", kind: "exposure", label: "Viewer Exposure", data: { note: "deferred" }, x: 860, y: 240, ghost: true },
  ];
  const edges: GraphEdge[] = [
    { from: "trigger", to: "decision" },
    { from: "decision", to: "composition" },
    { from: "composition", to: "adrun", failed: compFailed },
    ...plays.map((_, i): GraphEdge => ({ from: "adrun", to: `play_${i}`, ghost: compFailed })),
    { from: "adrun", to: "exposure", ghost: true },
  ];
  return { nodes, edges, adRun };
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd /Users/jn/code/godview-prototype && npm test -- selectors`
Expected: PASS (all 5). If a test fails because the fixture lacks a required state (e.g. no `failed` ad_run), fix the fixture — the fixture is the spec of "populated" here.

- [ ] **Step 7: Commit (git-flow-manager)**

Branch `feat/data-layer`, commit `feat: typed mock data + selectors for god view pages`.

---

### Task 3: App shell — sidebar, topbar, routing

**Files:**
- Create: `/Users/jn/code/godview-prototype/src/components/Shell.tsx`, `src/components/StatusDot.tsx`, `src/routes.tsx`
- Modify: `src/App.tsx`, `src/main.tsx`
- Test: `/Users/jn/code/godview-prototype/src/components/Shell.test.tsx`

**Interfaces:**
- Consumes: nothing from Task 2 yet (shell is chrome).
- Produces: `Shell` (sidebar with "God View" group [Main Dashboard, Composition Activity, Systems & Logs] + "Tools" group [Authoring, Activity Feed w/ legacy badge]; topbar with breadcrumb, search, persistent pipeline-health badge), `StatusDot` ({ status, kind } → colored dot), and a `react-router` config mounting the four pages at `/`, `/compositions`, `/compositions/:adRunId`, `/systems`. Placeholder page components are created here and replaced in Tasks 4–7.

- [ ] **Step 1: Write `StatusDot` + its failing test**

`/Users/jn/code/godview-prototype/src/components/StatusDot.tsx`:

```tsx
const COLOR: Record<string, string> = {
  active: "bg-ok", healthy: "bg-ok", completed: "bg-ok", playing: "bg-ok",
  degraded: "bg-warn", dispatched: "bg-warn", composing: "bg-warn",
  offline: "bg-off", retired: "bg-off", canceled: "bg-off",
  failed: "bg-crit",
};
export function StatusDot({ status }: { status: string }) {
  return <span data-testid="status-dot" data-status={status}
    className={`inline-block h-2 w-2 rounded-full ${COLOR[status] ?? "bg-off"}`} />;
}
```

`/Users/jn/code/godview-prototype/src/components/Shell.test.tsx`:

```tsx
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { Shell } from "./Shell";

test("Shell shows nav groups and the pipeline health badge", () => {
  render(<MemoryRouter><Shell><div>content</div></Shell></MemoryRouter>);
  expect(screen.getByText("Main Dashboard")).toBeInTheDocument();
  expect(screen.getByText("Composition Activity")).toBeInTheDocument();
  expect(screen.getByText("Systems & Logs")).toBeInTheDocument();
  expect(screen.getByText(/legacy/i)).toBeInTheDocument();          // Activity Feed badge
  expect(screen.getByTestId("pipeline-health")).toBeInTheDocument();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/godview-prototype && npm test -- Shell`
Expected: FAIL — `Shell` not found.

- [ ] **Step 3: Implement `Shell`**

`/Users/jn/code/godview-prototype/src/components/Shell.tsx`:

```tsx
import { NavLink } from "react-router-dom";
import type { ReactNode } from "react";

const nav = [
  { group: "God View", items: [
    { to: "/", label: "Main Dashboard", end: true },
    { to: "/compositions", label: "Composition Activity" },
    { to: "/systems", label: "Systems & Logs" },
  ]},
  { group: "Tools", items: [
    { to: "/authoring", label: "Authoring" },
    { to: "/activity", label: "Activity Feed", legacy: true },
  ]},
];

export function Shell({ children, crumb }: { children: ReactNode; crumb?: string }) {
  return (
    <div className="grid grid-cols-[220px_1fr] min-h-screen">
      <aside className="bg-sidebar border-r border-border p-3">
        <div className="flex items-center gap-2 px-2 py-3">
          <span className="h-2.5 w-2.5 rounded-sm bg-accent shadow-[0_0_10px_#45c4ff]" />
          <span className="font-mono font-semibold text-[13px]">GOD VIEW</span>
        </div>
        {nav.map((g) => (
          <div key={g.group} className="mb-4">
            <div className="px-2 pb-1.5 text-[10.5px] uppercase tracking-wider text-faint font-semibold">{g.group}</div>
            {g.items.map((it) => (
              <NavLink key={it.to} to={it.to} end={(it as any).end}
                className={({ isActive }) => `flex items-center gap-2 px-2 py-1.5 rounded-md text-[12.5px] mb-0.5 ${isActive ? "bg-elev text-text" : "text-dim"}`}>
                {it.label}
                {(it as any).legacy && <span className="ml-auto font-mono text-[9px] text-faint border border-border px-1.5 rounded">legacy</span>}
              </NavLink>
            ))}
          </div>
        ))}
      </aside>
      <main className="flex flex-col min-w-0">
        <div className="flex items-center justify-between px-5 py-2.5 border-b border-border">
          <div className="text-[12.5px] text-dim">{crumb ?? <b className="text-text font-semibold">God View</b>}</div>
          <div className="flex items-center gap-2.5">
            <div className="flex items-center gap-2 bg-elev border border-border rounded-md px-2.5 py-1.5 text-faint text-[12px] w-44">⌕ Find…</div>
            <div data-testid="pipeline-health" className="flex items-center gap-1.5 font-mono text-[11px] text-ok border border-ok/30 bg-ok/5 px-2 py-1 rounded-md">
              <span className="h-1.5 w-1.5 rounded-full bg-ok shadow-[0_0_6px_#34d399]" /> Pipeline OK · 0.8s
            </div>
            <div className="h-6 w-6 rounded-full bg-elev2 border border-border" />
          </div>
        </div>
        <div className="p-6 overflow-auto flex-1">{children}</div>
      </main>
    </div>
  );
}
```

- [ ] **Step 4: Wire the router with placeholder pages**

`/Users/jn/code/godview-prototype/src/routes.tsx`:

```tsx
import { createBrowserRouter } from "react-router-dom";
import { Shell } from "./components/Shell";

const Stub = ({ name }: { name: string }) => <Shell><div>{name}</div></Shell>;

export const router = createBrowserRouter([
  { path: "/", element: <Stub name="Main Dashboard" /> },
  { path: "/compositions", element: <Stub name="Composition Activity" /> },
  { path: "/compositions/:adRunId", element: <Stub name="Ad Detail" /> },
  { path: "/systems", element: <Stub name="Systems & Logs" /> },
]);
```

Replace `/Users/jn/code/godview-prototype/src/App.tsx`:

```tsx
import { RouterProvider } from "react-router-dom";
import { router } from "./routes";
export default function App() { return <RouterProvider router={router} />; }
```

Update `src/App.test.tsx` to assert `getByText("Main Dashboard")` renders (the smoke test now goes through the router). Ensure `src/index.css` is imported in `src/main.tsx`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /Users/jn/code/godview-prototype && npm test`
Expected: PASS (Shell + App smoke).

- [ ] **Step 6: Eyeball it**

Run: `cd /Users/jn/code/godview-prototype && npm run dev` → open the URL; confirm the sidebar + topbar render dark, nav links switch routes, placeholders show.

- [ ] **Step 7: Commit (git-flow-manager)**

Branch `feat/app-shell`, commit `feat: app shell (sidebar, topbar, router)`.

---

### Task 4: Main Dashboard page

**Files:**
- Create: `/Users/jn/code/godview-prototype/src/pages/MainDashboard.tsx`, `src/components/KpiCard.tsx`, `src/components/Sparkline.tsx`
- Modify: `src/routes.tsx` (mount real page at `/`)
- Test: `/Users/jn/code/godview-prototype/src/pages/MainDashboard.test.tsx`

**Interfaces:**
- Consumes: `db` (fixtures), `fleetSummary`, `activeAdRuns`, `recentFailures`, `camerasWithReading` (Task 2); `Shell`, `StatusDot` (Task 3).
- Produces: `MainDashboard` — KPI row (Systems Healthy `n/total`, Active Compositions, Failures, Pipeline Lag), "Composing now" strip, "Recent failures" list (failure rows link to `/compositions/:adRunId` when `adRunId` present), "Live camera readings" grid. No node-diagram on this page.

- [ ] **Step 1: Write the failing test**

`/Users/jn/code/godview-prototype/src/pages/MainDashboard.test.tsx`:

```tsx
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { MainDashboard } from "./MainDashboard";
import { db } from "../data/fixtures";
import { fleetSummary } from "../data/selectors";

test("MainDashboard shows fleet KPIs, composing strip, failures, and camera readings", () => {
  render(<MemoryRouter><MainDashboard /></MemoryRouter>);
  const s = fleetSummary(db);
  expect(screen.getByText("Systems healthy")).toBeInTheDocument();
  expect(screen.getByText(new RegExp(`${s.healthy}`))).toBeInTheDocument();
  expect(screen.getByText("Composing now")).toBeInTheDocument();
  expect(screen.getByText("Recent failures")).toBeInTheDocument();
  expect(screen.getByText("Live camera readings")).toBeInTheDocument();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/godview-prototype && npm test -- MainDashboard`
Expected: FAIL — `MainDashboard` not found.

- [ ] **Step 3: Implement `Sparkline`, `KpiCard`, and `MainDashboard`**

`/Users/jn/code/godview-prototype/src/components/Sparkline.tsx`:

```tsx
export function Sparkline({ points, stroke }: { points: number[]; stroke: string }) {
  const max = Math.max(...points, 1);
  const pts = points.map((p, i) => `${(i / (points.length - 1)) * 100},${28 - (p / max) * 24}`).join(" ");
  return <svg viewBox="0 0 100 28" preserveAspectRatio="none" className="w-full h-7 mt-2">
    <polyline points={pts} fill="none" stroke={stroke} strokeWidth="1.6" /></svg>;
}
```

`/Users/jn/code/godview-prototype/src/components/KpiCard.tsx`:

```tsx
import { Sparkline } from "./Sparkline";
export function KpiCard({ label, value, sub, spark, stroke, crit }:
  { label: string; value: string; sub?: string; spark: number[]; stroke: string; crit?: boolean }) {
  return (
    <div className="bg-elev border border-border rounded-[10px] px-4 py-3.5">
      <div className="flex items-center justify-between mb-2"><span className="text-dim text-[11.5px]">{label}</span>
        {sub && <span className="font-mono text-[11px] text-ok">{sub}</span>}</div>
      <div className={`font-mono text-2xl font-semibold tabular-nums ${crit ? "text-crit" : ""}`}>{value}</div>
      <Sparkline points={spark} stroke={stroke} />
    </div>
  );
}
```

`/Users/jn/code/godview-prototype/src/pages/MainDashboard.tsx`:

```tsx
import { Link } from "react-router-dom";
import { Shell } from "../components/Shell";
import { StatusDot } from "../components/StatusDot";
import { KpiCard } from "../components/KpiCard";
import { db } from "../data/fixtures";
import { fleetSummary, activeAdRuns, recentFailures, camerasWithReading } from "../data/selectors";

export function MainDashboard() {
  const s = fleetSummary(db);
  const active = activeAdRuns(db);
  const failures = recentFailures(db, 5);
  const cams = camerasWithReading(db).slice(0, 6);
  return (
    <Shell>
      <h1 className="text-[18px] font-semibold mb-1">Fleet Overview</h1>
      <p className="text-dim text-[12px] mb-5">{s.total} systems across {db.organizations.length} organizations</p>

      <div className="grid grid-cols-4 gap-3 mb-6">
        <KpiCard label="Systems healthy" value={`${s.healthy} / ${s.total}`} spark={[3,4,4,6,5,7,6,8]} stroke="#34d399" />
        <KpiCard label="Active compositions" value={`${active.length}`} spark={[2,3,3,5,4,7,6,8]} stroke="#45c4ff" />
        <KpiCard label="Failures" value={`${failures.filter(f=>f.severity==="crit").length}`} crit spark={[0,0,1,0,3,0,0,2]} stroke="#f2545b" />
        <KpiCard label="Pipeline lag" value="0.8s" spark={[4,5,4,5,4,5,4,5]} stroke="#8b93a3" />
      </div>

      <div className="grid grid-cols-[1.3fr_1fr] gap-3.5">
        <div>
          <section className="bg-elev border border-border rounded-[10px] px-4 py-3.5 mb-3.5">
            <h3 className="text-[12.5px] font-semibold mb-3">Composing now</h3>
            <div className="flex gap-2.5 overflow-x-auto">
              {active.map((r) => (
                <Link key={r.id} to={`/compositions/${r.id}`} className="flex-none w-48 bg-elev2 border border-borderSoft rounded-[9px] px-3 py-2.5">
                  <div className="flex items-center gap-1.5 mb-1.5"><StatusDot status={r.status} /><span className="text-[12px] font-semibold">{r.id}</span></div>
                  <div className="text-[11px] text-dim">{r.status}</div>
                </Link>
              ))}
            </div>
          </section>
          <section className="bg-elev border border-border rounded-[10px] px-4 py-3.5">
            <h3 className="text-[12.5px] font-semibold mb-3">Live camera readings</h3>
            <div className="grid grid-cols-3 gap-2.5">
              {cams.map((c) => (
                <div key={c.id} className="bg-elev2 border border-borderSoft rounded-[9px] px-2.5 py-2.5">
                  <div className="flex justify-between items-center mb-1"><span className="text-[11.5px] font-semibold">{c.name}</span><StatusDot status={c.status} /></div>
                  <div className="text-[10.5px] text-faint mb-1.5">{c.system}</div>
                  <div className="font-mono text-[11px] text-dim">{c.status === "offline" ? "no signal" : `${c.face_count} faces · conf ${c.confidence}`}</div>
                </div>
              ))}
            </div>
          </section>
        </div>
        <section className="bg-elev border border-border rounded-[10px] px-4 py-3.5">
          <h3 className="text-[12.5px] font-semibold mb-3">Recent failures</h3>
          <div className="flex flex-col">
            {failures.map((f) => {
              const row = (
                <div className="flex items-center gap-2.5 py-2 border-b border-borderSoft text-[12px]">
                  <span className={`font-mono text-[9.5px] px-1.5 py-0.5 rounded uppercase ${f.severity === "crit" ? "text-crit bg-crit/15" : "text-warn bg-warn/15"}`}>{f.severity}</span>
                  <span className="flex-1">{f.message} <span className="text-dim">· {f.where}</span></span>
                  <span className="font-mono text-[10.5px] text-faint">{f.when.slice(11, 19)}</span>
                </div>
              );
              return f.adRunId ? <Link key={f.id} to={`/compositions/${f.adRunId}`}>{row}</Link> : <div key={f.id}>{row}</div>;
            })}
          </div>
        </section>
      </div>
    </Shell>
  );
}
```

Update `src/routes.tsx`: import `MainDashboard`, set it as the `/` element.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/jn/code/godview-prototype && npm test -- MainDashboard`
Expected: PASS.

- [ ] **Step 5: Eyeball + commit**

`npm run dev`, confirm the dashboard matches the wireframe intent. Then git-flow-manager: branch `feat/main-dashboard`, commit `feat: main dashboard page`.

---

### Task 5: Composition Activity list page

**Files:**
- Create: `/Users/jn/code/godview-prototype/src/pages/CompositionActivity.tsx`, `src/components/AdRunCard.tsx`
- Modify: `src/routes.tsx` (mount at `/compositions`), `src/data/selectors.ts` (add `adRunCards`)
- Test: `/Users/jn/code/godview-prototype/src/pages/CompositionActivity.test.tsx`, extend `src/data/selectors.test.ts`

**Interfaces:**
- Consumes: `db`, `Shell`, `StatusDot`.
- Produces: selector `adRunCards(db): AdRunCard[]` ({ id, campaign, system, location, status, started_at, stageDots: {decision,composition,playback} }); `CompositionActivity` page — a filter bar (status filter via a `<select>`), a card grid, each card linking to `/compositions/:id`.

- [ ] **Step 1: Write failing selector + page tests**

Append to `src/data/selectors.test.ts`:

```ts
import { adRunCards } from "./selectors";
test("adRunCards returns one card per ad run with stage completion dots", () => {
  const cards = adRunCards(db);
  expect(cards.length).toBe(db.ad_runs.length);
  expect(cards[0]).toHaveProperty("stageDots");
  expect(cards[0].stageDots).toHaveProperty("composition");
});
```

`/Users/jn/code/godview-prototype/src/pages/CompositionActivity.test.tsx`:

```tsx
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { CompositionActivity } from "./CompositionActivity";
import { db } from "../data/fixtures";

test("CompositionActivity lists an ad-run card per run", () => {
  render(<MemoryRouter><CompositionActivity /></MemoryRouter>);
  expect(screen.getByText("Composition Activity")).toBeInTheDocument();
  // every ad_run id appears somewhere as a card
  expect(screen.getAllByTestId("adrun-card").length).toBe(db.ad_runs.length);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/jn/code/godview-prototype && npm test -- CompositionActivity selectors`
Expected: FAIL — `adRunCards`/`CompositionActivity` undefined.

- [ ] **Step 3: Implement selector, card, and page**

Add to `src/data/selectors.ts`:

```ts
export interface AdRunCard { id: string; campaign: string; system: string; location: string; status: string; started_at: string; stageDots: { decision: boolean; composition: boolean; playback: boolean }; }
export function adRunCards(db: Db): AdRunCard[] {
  return db.ad_runs.map((r) => {
    const comp = db.composition_runs.find((c) => c.id === r.composition_run_id);
    return {
      id: r.id, campaign: r.campaign_id ?? "—",
      system: db.systems.find((s) => s.id === r.system_id)?.name ?? r.system_id,
      location: db.locations.find((l) => l.id === r.location_id)?.name ?? r.location_id,
      status: r.status, started_at: r.started_at ?? "",
      stageDots: {
        decision: Boolean(r.personalization_decision_id),
        composition: comp?.status === "rendered" || comp?.status === "selected",
        playback: db.playbacks.some((p) => p.ad_run_id === r.id && p.status === "ended"),
      },
    };
  });
}
```

`/Users/jn/code/godview-prototype/src/components/AdRunCard.tsx`:

```tsx
import { Link } from "react-router-dom";
import { StatusDot } from "./StatusDot";
import type { AdRunCard as Card } from "../data/selectors";
export function AdRunCard({ c }: { c: Card }) {
  return (
    <Link to={`/compositions/${c.id}`} data-testid="adrun-card"
      className="bg-elev border border-border rounded-[10px] px-4 py-3.5 block hover:border-accent/40">
      <div className="flex items-center gap-2 mb-1.5"><StatusDot status={c.status} /><span className="font-semibold text-[12.5px]">{c.id}</span>
        <span className="ml-auto font-mono text-[10px] text-faint uppercase">{c.status}</span></div>
      <div className="text-[11.5px] text-dim mb-0.5">{c.campaign}</div>
      <div className="text-[11px] text-faint mb-2">{c.system} · {c.location}</div>
      <div className="flex gap-1.5 items-center text-[10px] text-faint">
        <span className={c.stageDots.decision ? "text-ok" : ""}>● decision</span>
        <span className={c.stageDots.composition ? "text-ok" : ""}>● compose</span>
        <span className={c.stageDots.playback ? "text-ok" : ""}>● play</span>
      </div>
    </Link>
  );
}
```

`/Users/jn/code/godview-prototype/src/pages/CompositionActivity.tsx`:

```tsx
import { useState } from "react";
import { Shell } from "../components/Shell";
import { AdRunCard } from "../components/AdRunCard";
import { db } from "../data/fixtures";
import { adRunCards } from "../data/selectors";

export function CompositionActivity() {
  const [status, setStatus] = useState("all");
  const cards = adRunCards(db).filter((c) => status === "all" || c.status === status);
  return (
    <Shell crumb="Composition Activity">
      <div className="flex items-end justify-between mb-4">
        <h1 className="text-[18px] font-semibold">Composition Activity</h1>
        <select value={status} onChange={(e) => setStatus(e.target.value)}
          className="bg-elev border border-border rounded-md px-2.5 py-1.5 text-[12px] text-dim">
          {["all","composing","playing","completed","failed","canceled"].map((s) => <option key={s} value={s}>{s}</option>)}
        </select>
      </div>
      <div className="grid grid-cols-3 gap-3">
        {cards.map((c) => <AdRunCard key={c.id} c={c} />)}
      </div>
    </Shell>
  );
}
```

Mount in `src/routes.tsx` at `/compositions`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/jn/code/godview-prototype && npm test -- CompositionActivity selectors`
Expected: PASS.

- [ ] **Step 5: Eyeball + commit**

git-flow-manager: branch `feat/composition-activity`, commit `feat: composition activity list page`.

---

### Task 6: Ad Detail page — node graph + inspector

**Files:**
- Create: `/Users/jn/code/godview-prototype/src/pages/AdDetail.tsx`, `src/components/PipelineNode.tsx`, `src/components/Inspector.tsx`
- Modify: `src/routes.tsx` (mount at `/compositions/:adRunId`), `src/main.tsx` (import `@xyflow/react/dist/style.css`)
- Test: `/Users/jn/code/godview-prototype/src/pages/AdDetail.test.tsx`

**Interfaces:**
- Consumes: `adRunGraph` (Task 2), `Shell`, `StatusDot`.
- Produces: `AdDetail` — reads `:adRunId`, builds the graph via `adRunGraph`, renders nodes/edges with `@xyflow/react` using a custom `PipelineNode`, and an `Inspector` panel showing the selected node's full data (defaults to the failed node when present). The Viewer Exposure node renders ghosted/disabled.

- [ ] **Step 1: Write the failing test**

`/Users/jn/code/godview-prototype/src/pages/AdDetail.test.tsx`:

```tsx
import { render, screen } from "@testing-library/react";
import { MemoryRouter, Routes, Route } from "react-router-dom";
import { AdDetail } from "./AdDetail";
import { db } from "../data/fixtures";

function renderAt(id: string) {
  return render(
    <MemoryRouter initialEntries={[`/compositions/${id}`]}>
      <Routes><Route path="/compositions/:adRunId" element={<AdDetail />} /></Routes>
    </MemoryRouter>
  );
}

test("AdDetail renders pipeline nodes and an inspector for a failed run", () => {
  const failed = db.ad_runs.find((r) => r.status === "failed")!;
  renderAt(failed.id);
  expect(screen.getByText("Composition")).toBeInTheDocument();
  expect(screen.getByText("Ad Run")).toBeInTheDocument();
  expect(screen.getByText(/Viewer Exposure/)).toBeInTheDocument();       // ghost node present
  // inspector surfaces the composition error (ad_runs has none; comes from composition_runs)
  expect(screen.getByTestId("inspector")).toHaveTextContent(/error_code|OVERLAY/i);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jn/code/godview-prototype && npm test -- AdDetail`
Expected: FAIL — `AdDetail` not found.

- [ ] **Step 3: Implement `PipelineNode`, `Inspector`, `AdDetail`**

`/Users/jn/code/godview-prototype/src/components/PipelineNode.tsx`:

```tsx
import { Handle, Position } from "@xyflow/react";
import { StatusDot } from "./StatusDot";

export function PipelineNode({ data }: { data: any }) {
  return (
    <div className={`w-40 bg-elev border rounded-[9px] px-2.5 py-2.5 ${data.ghost ? "opacity-40 border-dashed border-border" : data.failed ? "border-crit/50" : "border-border"} ${data.selected ? "ring-1 ring-accent" : ""}`}>
      <Handle type="target" position={Position.Left} className="!bg-border" />
      <div className="flex items-center gap-1.5 mb-1">
        {!data.ghost && <StatusDot status={data.status ?? "off"} />}
        <span className="text-[11.5px] font-semibold">{data.label}</span>
      </div>
      {data.sub && <div className="font-mono text-[10px] text-faint">{data.sub}</div>}
      <Handle type="source" position={Position.Right} className="!bg-border" />
    </div>
  );
}
```

`/Users/jn/code/godview-prototype/src/components/Inspector.tsx`:

```tsx
export function Inspector({ title, subtitle, rows, note }:
  { title: string; subtitle: string; rows: [string, string][]; note?: string }) {
  return (
    <div data-testid="inspector" className="bg-elev border-l border-border p-4 w-[300px]">
      <h4 className="text-[12px] font-semibold mb-0.5">{title}</h4>
      <div className="font-mono text-[10.5px] text-faint mb-3.5">{subtitle}</div>
      {rows.map(([k, v]) => (
        <div key={k} className={`flex justify-between gap-2.5 py-1.5 border-b border-borderSoft text-[11.5px] ${k.includes("error") ? "text-crit" : ""}`}>
          <span className="text-dim">{k}</span><span className="font-mono text-right break-all">{v}</span>
        </div>
      ))}
      {note && <div className="mt-3.5 p-2.5 bg-crit/15 border border-crit/25 rounded-lg text-[11px] text-crit/90">{note}</div>}
    </div>
  );
}
```

`/Users/jn/code/godview-prototype/src/pages/AdDetail.tsx`:

```tsx
import { useMemo, useState } from "react";
import { useParams } from "react-router-dom";
import { ReactFlow, Background } from "@xyflow/react";
import { Shell } from "../components/Shell";
import { PipelineNode } from "../components/PipelineNode";
import { Inspector } from "../components/Inspector";
import { db } from "../data/fixtures";
import { adRunGraph } from "../data/selectors";

const nodeTypes = { pipeline: PipelineNode };

export function AdDetail() {
  const { adRunId } = useParams();
  const g = useMemo(() => adRunGraph(db, adRunId!), [adRunId]);
  const failedId = g.nodes.find((n) => n.data.status === "failed")?.id;
  const [selected, setSelected] = useState<string>(failedId ?? "composition");

  const rfNodes = g.nodes.map((n) => ({
    id: n.id, type: "pipeline", position: { x: n.x, y: n.y },
    data: { ...n.data, label: n.label, ghost: n.ghost,
      failed: g.edges.some((e) => e.to === n.id && e.failed), selected: n.id === selected,
      sub: n.data.decision_type ?? n.data.render_mode ?? n.data.screen_id ?? n.data.trigger_id },
  }));
  const rfEdges = g.edges.map((e, i) => ({
    id: `e${i}`, source: e.from, target: e.to, animated: !e.ghost && !e.failed,
    style: { stroke: e.failed ? "#f2545b" : e.ghost ? "#3a4250" : "#2a323f", strokeDasharray: e.ghost ? "3 3" : undefined },
  }));

  const sel = g.nodes.find((n) => n.id === selected)!;
  const rows: [string, string][] = Object.entries(sel.data)
    .filter(([, v]) => v !== undefined && typeof v !== "object")
    .map(([k, v]) => [k, String(v)]);

  return (
    <Shell crumb={`Composition Activity / ${g.adRun.id}`}>
      <div className="flex items-center gap-3 mb-1">
        <h1 className="text-[16px] font-semibold">{g.adRun.id}</h1>
        <span className={`font-mono text-[10.5px] px-2 py-0.5 rounded uppercase ${g.adRun.status === "failed" ? "text-crit bg-crit/15" : "text-ok bg-ok/15"}`}>{g.adRun.status}</span>
      </div>
      <div className="text-dim text-[12px] mb-4 font-mono">trigger {g.adRun.trigger_id}</div>
      <div className="grid grid-cols-[1fr_300px] border border-border rounded-[10px] overflow-hidden" style={{ height: 460 }}>
        <div className="relative">
          <ReactFlow nodes={rfNodes} edges={rfEdges} nodeTypes={nodeTypes}
            onNodeClick={(_, n) => setSelected(n.id)} fitView proOptions={{ hideAttribution: true }}>
            <Background color="#1a2029" gap={18} />
          </ReactFlow>
        </div>
        <Inspector title={sel.label} subtitle={`${sel.kind} · ${g.adRun.id}`} rows={rows}
          note={sel.data.error_message as string | undefined} />
      </div>
    </Shell>
  );
}
```

Add `import "@xyflow/react/dist/style.css";` to `src/main.tsx`. Mount `AdDetail` in `src/routes.tsx`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/jn/code/godview-prototype && npm test -- AdDetail`
Expected: PASS. (Note: `@xyflow/react` renders in jsdom; if it needs a sized container, the fixed 460px height provides it. If ResizeObserver is missing under jsdom, add a polyfill to `src/test/setup.ts`: `globalThis.ResizeObserver = class { observe(){} unobserve(){} disconnect(){} } as any;`.)

- [ ] **Step 5: Eyeball + commit**

`npm run dev` → navigate from a Composition Activity card into Ad Detail; confirm the graph renders, clicking a node updates the inspector, the ghost Viewer Exposure node is dimmed. git-flow-manager: branch `feat/ad-detail`, commit `feat: ad detail node-graph page`.

---

### Task 7: Systems & Logs page

**Files:**
- Create: `/Users/jn/code/godview-prototype/src/pages/SystemsLogs.tsx`
- Modify: `src/routes.tsx` (mount at `/systems`), `src/data/selectors.ts` (add `systemDrilldown`, `eventLog`)
- Test: `/Users/jn/code/godview-prototype/src/pages/SystemsLogs.test.tsx`, extend `src/data/selectors.test.ts`

**Interfaces:**
- Consumes: `db`, `systemsWithRollup` (Task 2), `Shell`, `StatusDot`.
- Produces: selectors `systemDrilldown(db, systemId)` ({ system, groups: {group, cameras[], displays[]}[], ungrouped }) and `eventLog(db, limit)` (chronological rows from `health_events`); `SystemsLogs` page — KPI strip, systems table (row click reveals inline drill-down grouped by `screen_group`, each camera showing reading+health), event/log table below, and an `unresolved_devices` banner placeholder when a display/playback has an unresolved `screen_id`.

- [ ] **Step 1: Write failing selector + page tests**

Append to `src/data/selectors.test.ts`:

```ts
import { systemDrilldown, eventLog } from "./selectors";
test("systemDrilldown groups devices by screen_group", () => {
  const sysId = db.systems[0].id;
  const d = systemDrilldown(db, sysId);
  expect(d.system.id).toBe(sysId);
  expect(Array.isArray(d.groups)).toBe(true);
});
test("eventLog returns newest-first rows capped at the limit", () => {
  const rows = eventLog(db, 20);
  expect(rows.length).toBeLessThanOrEqual(20);
  for (let i = 1; i < rows.length; i++) expect(rows[i - 1].observed_at >= rows[i].observed_at).toBe(true);
});
```

`/Users/jn/code/godview-prototype/src/pages/SystemsLogs.test.tsx`:

```tsx
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { SystemsLogs } from "./SystemsLogs";
import { db } from "../data/fixtures";

test("SystemsLogs renders a systems table and an event log", () => {
  render(<MemoryRouter><SystemsLogs /></MemoryRouter>);
  expect(screen.getByText("Systems & Logs")).toBeInTheDocument();
  expect(screen.getByText(db.systems[0].name)).toBeInTheDocument();
  expect(screen.getByText("Event log")).toBeInTheDocument();
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/jn/code/godview-prototype && npm test -- SystemsLogs selectors`
Expected: FAIL — undefined exports.

- [ ] **Step 3: Implement selectors + page**

Add to `src/data/selectors.ts`:

```ts
import type { Camera, Display, ScreenGroup, System } from "./types";
export interface Drilldown { system: System; groups: { group: ScreenGroup; cameras: Camera[]; displays: Display[] }[]; ungroupedCameras: Camera[]; ungroupedDisplays: Display[]; }
export function systemDrilldown(db: Db, systemId: string): Drilldown {
  const system = db.systems.find((s) => s.id === systemId)!;
  const groups = db.screen_groups.filter((g) => g.system_id === systemId).map((group) => ({
    group,
    cameras: db.cameras.filter((c) => c.screen_group_id === group.id),
    displays: db.displays.filter((d) => d.screen_group_id === group.id),
  }));
  return {
    system, groups,
    ungroupedCameras: db.cameras.filter((c) => c.system_id === systemId && !c.screen_group_id),
    ungroupedDisplays: db.displays.filter((d) => d.system_id === systemId && !d.screen_group_id),
  };
}
export interface LogRow { id: string; kind: string; ref: string; status: string; detail: string; observed_at: string; }
export function eventLog(db: Db, limit: number): LogRow[] {
  return [...db.health_events]
    .sort((a, b) => (a.observed_at < b.observed_at ? 1 : -1))
    .slice(0, limit)
    .map((h) => ({ id: h.id, kind: h.kind, ref: h.ref_id, status: h.status, detail: h.detail, observed_at: h.observed_at }));
}
```

`/Users/jn/code/godview-prototype/src/pages/SystemsLogs.tsx`:

```tsx
import { useState } from "react";
import { Shell } from "../components/Shell";
import { StatusDot } from "../components/StatusDot";
import { db } from "../data/fixtures";
import { systemsWithRollup, systemDrilldown, eventLog, camerasWithReading } from "../data/selectors";

export function SystemsLogs() {
  const rows = systemsWithRollup(db);
  const log = eventLog(db, 20);
  const readings = camerasWithReading(db);
  const [open, setOpen] = useState<string | null>(null);
  const unresolved = db.playbacks.filter((p) => !p.display_id).length;

  return (
    <Shell crumb="Systems & Logs">
      <h1 className="text-[18px] font-semibold mb-4">Systems & Logs</h1>

      {unresolved > 0 && (
        <div className="mb-4 px-3 py-2 rounded-md bg-warn/10 border border-warn/30 text-warn text-[12px]">
          {unresolved} playback(s) reference an unregistered screen_id — device registration pending.
        </div>
      )}

      <table className="w-full text-[12px] mb-6 border border-border rounded-[10px] overflow-hidden">
        <thead className="text-faint text-left">
          <tr className="border-b border-border">
            <th className="px-3 py-2 font-medium">System</th><th className="px-3 py-2 font-medium">Org</th>
            <th className="px-3 py-2 font-medium">Location</th><th className="px-3 py-2 font-medium">Type</th>
            <th className="px-3 py-2 font-medium">Status</th><th className="px-3 py-2 font-medium">Devices</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <>
              <tr key={r.id} onClick={() => setOpen(open === r.id ? null : r.id)}
                className="border-b border-borderSoft cursor-pointer hover:bg-elev">
                <td className="px-3 py-2 font-semibold">{r.name}</td><td className="px-3 py-2 text-dim">{r.org}</td>
                <td className="px-3 py-2 text-dim">{r.location}</td><td className="px-3 py-2 font-mono text-faint">{r.system_type}</td>
                <td className="px-3 py-2"><span className="inline-flex items-center gap-1.5"><StatusDot status={r.status} />{r.status}</span></td>
                <td className="px-3 py-2 font-mono">{r.device_count}</td>
              </tr>
              {open === r.id && (
                <tr><td colSpan={6} className="bg-elev px-4 py-3">
                  {systemDrilldown(db, r.id).groups.map((grp) => (
                    <div key={grp.group.id} className="mb-2">
                      <div className="text-[11px] uppercase text-faint mb-1">{grp.group.name} · {grp.group.group_type}</div>
                      <div className="flex flex-wrap gap-2">
                        {grp.cameras.map((c) => {
                          const rd = readings.find((x) => x.id === c.id);
                          return <div key={c.id} className="bg-elev2 border border-borderSoft rounded px-2 py-1.5 text-[11px]">
                            <span className="inline-flex items-center gap-1.5"><StatusDot status={c.status} />{c.name}</span>
                            <div className="font-mono text-[10px] text-dim">{c.status === "offline" ? "no signal" : `${rd?.face_count ?? 0} faces`}</div>
                          </div>;
                        })}
                        {grp.displays.map((d) => (
                          <div key={d.id} className="bg-elev2 border border-borderSoft rounded px-2 py-1.5 text-[11px]">
                            <span className="inline-flex items-center gap-1.5"><StatusDot status={d.status} />{d.name}</span>
                            <div className="font-mono text-[10px] text-faint">{d.screen_id}</div>
                          </div>
                        ))}
                      </div>
                    </div>
                  ))}
                </td></tr>
              )}
            </>
          ))}
        </tbody>
      </table>

      <h3 className="text-[12.5px] font-semibold mb-2">Event log</h3>
      <table className="w-full text-[11.5px] border border-border rounded-[10px] overflow-hidden">
        <tbody>
          {log.map((e) => (
            <tr key={e.id} className="border-b border-borderSoft">
              <td className="px-3 py-1.5 font-mono text-faint">{e.observed_at.slice(11, 19)}</td>
              <td className="px-3 py-1.5"><StatusDot status={e.status} /></td>
              <td className="px-3 py-1.5 font-mono text-dim">{e.kind}:{e.ref}</td>
              <td className="px-3 py-1.5">{e.detail}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </Shell>
  );
}
```

Mount `SystemsLogs` in `src/routes.tsx` at `/systems`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/jn/code/godview-prototype && npm test`
Expected: entire suite PASS.

- [ ] **Step 5: Full eyeball pass**

`npm run dev` → walk all four pages + the three user journeys from spec §5 (health check, failure investigation via Main Dashboard → Ad Detail, venue spot-check via Systems & Logs drill-down). Confirm the two status vocabularies stay visually distinct and the unresolved-screen_id banner shows.

- [ ] **Step 6: Commit (git-flow-manager)**

Branch `feat/systems-logs`, commit `feat: systems & logs page`.

---

## Self-Review

**Spec coverage:**
- §4 site map (4 God View pages + Tools group w/ legacy Activity Feed) → Tasks 3–7. Authoring/Activity Feed are carried-over/legacy and intentionally left as external stubs (spec: untouched), represented as nav links only.
- §5 journeys → exercised in Task 6 (failure investigation deep-link) and Task 7 Step 5 (all three journeys).
- §6 page specs → Task 4 (Main Dashboard, no node-diagram), Task 5 (Composition Activity cards + filter), Task 6 (Ad Detail reactflow + inspector + ghost exposure node), Task 7 (Systems & Logs table + drill-down grouped by screen_group + event log).
- §7 screen_groups → consumed by Task 7's `systemDrilldown`; the migration itself is the separate plan `2026-07-07-godview-screen-groups-migration.md`.
- §8 build approach (new standalone app, shadcn dark, mock-data-first, @xyflow/react) → Task 1.
- §9 out-of-scope → viewer_exposures appears only as a disabled ghost node (Task 6); no map/globe anywhere.
- Global constraint "distinct status enums" → `StatusDot` maps both `lifecycle_status` and `device_status` values through one palette but the values never collide; both vocabularies are shown with their own labels.
- Global constraint "nullable display_id / unresolved screen_id" → fixture includes an unresolved playback; surfaced in Ad Detail (`(unresolved)`) and the Systems & Logs banner.
- Global constraint "ad_runs has no error columns" → `adRunGraph` sources the error from `composition_runs`; asserted in Task 6's test.

**Placeholder scan:** No "TBD"/"handle edge cases"/"similar to Task N" — every step has literal code. The one deferred detail (exact fixture contents, Task 2 Step 2) is described by required states rather than 300 lines of literal data, because the fixture is data-authoring, not logic; its correctness is enforced by the selector tests that consume it.

**Type consistency:** Selector names are stable across tasks (`fleetSummary`, `activeAdRuns`, `recentFailures`, `systemsWithRollup`, `camerasWithReading`, `adRunGraph`, `adRunCards`, `systemDrilldown`, `eventLog`). `GraphNode`/`GraphEdge`/`AdRunGraph` shapes defined in Task 2 are consumed unchanged in Task 6. `AdRunCard` type (Task 5) matches its component prop. Enum string-unions match the real migration values.
