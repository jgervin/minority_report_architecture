# Plan L — Remotion Source: Frontend (godview-prototype) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render the Remotion `.tsx` source — syntax-highlighted, line-numbered, collapsible (default expanded), with a Copy button and a personalization props strip — inside the Composition node of the ad-run pipeline graph on `/compositions/:adRunId`, exactly when `render_mode === "remotion"` and a source is available.

**Architecture:** The selector (`adRunGraph`) is the single gate: it copies `source`/`component_slug`/props metadata into the composition node's `data` only for remotion runs with a non-null source, and shifts downstream node positions to make room. `PipelineNode` stays dumb — if `data.source` is present it widens and mounts a new self-contained `RemotionSourcePanel` (zero-dep regex tokenizer for highlighting; no bundle-heavy highlighter per godview issue #36). The Inspector omits the bulky `source` string from its key/value rows.

**Tech Stack:** React 19 + `@xyflow/react` 12.11.2 + Tailwind (custom palette: `elev/elev2/border/borderSoft/dim/faint/accent/ok/warn/crit`), vitest + @testing-library/react (jsdom renders real ReactFlow — proven by `src/pages/AdDetail.test.tsx`).

**Spec:** `/Users/jn/code/minority_report_architecture/docs/superpowers/specs/2026-07-17-remotion-source-node.md`
**Mockup (visual truth):** https://claude.ai/code/artifact/0c3923a3-7014-40d2-bda4-9cb9545bbf67
**Depends on:** Plan K's response contract — `composition_run` gains nullable `component_slug`, `source`, `props_schema`, `default_props`, `personalized_field`, `base_video`. The frontend work needs no live backend (unit tests mock `fetchAdRun`), so K and L can build in parallel; only the final E2E needs K deployed.

## Global Constraints

- Work in a dedicated worktree branch of `godview-prototype` under `.claude/worktrees/` (e.g. `feat/remotion-source-node`). Implementers start with `cd <worktree> && pwd`; `/Users/jn/code/godview-prototype` is READ-ONLY reference.
- **Implementers never run git.** Red test committed separately from green impl by `git-flow-manager` (files + messages given per task).
- Test command: `npm test` (vitest run) from the worktree root; targeted: `npx vitest run src/data/selectors.test.ts`.
- **Tailwind literals:** every arbitrary-value class (`max-h-[240px]`, `w-80`…) must appear as a FULL LITERAL string — ternaries select between complete literals, never string-interpolate fragments.
- **@xyflow scroll capture:** the scrollable code `<pre>` carries the `nowheel` class (wheel scrolls code, not canvas zoom); the panel root carries `nodrag` (text selection / button clicks don't drag the node).
- **Node 25 gotcha:** global `localStorage` shadows jsdom's — irrelevant here (collapse state is component state, NOT persisted; do not add persistence).
- New fields in `apiTypes.ts` are **optional** (`source?: string | null`) so existing fixtures/tests that build `composition_run` literals stay valid (same pattern as `ad_run.target_watched?`).
- All file references in commits/PRs use absolute paths.

---

### Task 1 (L1): Types + selector gate + layout shift

**Files:**
- Modify: `src/data/apiTypes.ts` (the `composition_run` member of `AdRunDetail`, around line 57)
- Modify: `src/data/selectors.ts:96-128` (`adRunGraph` nodes array)
- Test: `src/data/selectors.test.ts` (append to the existing `describe("adRunGraph")`, which defines a `const detail = {...}` fixture with `render_mode: "template_overlay"`)

**Interfaces:**
- Consumes: Plan K's `composition_run` response fields (names above).
- Produces: composition `GraphNode.data` gains `source: string`, `component_slug: string | null`, `props_schema`, `default_props: Record<string, unknown> | null`, `personalized_field: string | null` — ONLY when `render_mode === "remotion"` and `source != null`; otherwise these keys are absent. Downstream x-positions shift +240 and the `creative_inputs` satellite moves to y=460 in that same case. Tasks L3/L4 key off `data.source` presence.

- [ ] **Step 1: Write the failing tests**

Append inside `describe("adRunGraph", ...)` in `src/data/selectors.test.ts` (reuse its `detail` const):

```ts
  const remotionDetail = {
    ...detail,
    composition_run: {
      ...detail.composition_run,
      render_mode: "remotion",
      component_slug: "comp-hello",
      source: "export const Hello = () => <div/>;",
      props_schema: { type: "object" },
      default_props: { text: "Hi" },
      personalized_field: "name",
      base_video: "base.mp4",
    },
  };

  it("passes remotion source fields into the composition node data", () => {
    const g = adRunGraph(remotionDetail as any);
    const comp = g.nodes.find((n) => n.id === "composition")!;
    expect(comp.data.source).toBe("export const Hello = () => <div/>;");
    expect(comp.data.component_slug).toBe("comp-hello");
    expect(comp.data.default_props).toEqual({ text: "Hi" });
    expect(comp.data.personalized_field).toBe("name");
  });

  it("omits source fields for non-remotion render modes even when source exists", () => {
    const d = { ...detail, composition_run: { ...detail.composition_run, source: "code", component_slug: "comp-x" } };
    const g = adRunGraph(d as any);
    expect(g.nodes.find((n) => n.id === "composition")!.data.source).toBeUndefined();
  });

  it("omits source fields for remotion runs whose source is null (pre-migration components)", () => {
    const d = { ...detail, composition_run: { ...detail.composition_run, render_mode: "remotion", source: null, component_slug: "comp-x" } };
    const g = adRunGraph(d as any);
    expect(g.nodes.find((n) => n.id === "composition")!.data.source).toBeUndefined();
  });

  it("shifts downstream nodes right and the creative satellite down when source is shown", () => {
    const g = adRunGraph(remotionDetail as any);
    expect(g.nodes.find((n) => n.id === "adrun")!.x).toBe(880);
    expect(g.nodes.find((n) => n.id === "play_0")!.x).toBe(1100);
    expect(g.nodes.find((n) => n.id === "exposure")!.x).toBe(1100);
    expect(g.nodes.find((n) => n.id === "creative_inputs")!.y).toBe(460);
    // baseline layout untouched without source
    const base = adRunGraph(detail as any);
    expect(base.nodes.find((n) => n.id === "adrun")!.x).toBe(640);
    expect(base.nodes.find((n) => n.id === "creative_inputs")!.y).toBe(160);
  });
```

(If the existing fixture is used without a cast in this file, match its idiom instead of `as any`.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx vitest run src/data/selectors.test.ts`
Expected: the 4 new tests FAIL (`comp.data.source` undefined where expected / positions 640/160 instead of 880/460); pre-existing tests still pass.

- [ ] **Step 3: Commit the red tests** (via git-flow-manager)

Stage only `src/data/selectors.test.ts`.
Message: `test: adRunGraph gates remotion source into composition node + layout shift (red)`

- [ ] **Step 4: Implement types + selector**

In `src/data/apiTypes.ts`, extend the `composition_run` object type inside `AdRunDetail` (append after `used_visible_name: boolean`):

```ts
    component_slug?: string | null; source?: string | null;
    props_schema?: Record<string, unknown> | null; default_props?: Record<string, unknown> | null;
    personalized_field?: string | null; base_video?: string | null;
```

In `src/data/selectors.ts` `adRunGraph()`, insert before the `const nodes: GraphNode[] = [` line (currently `:96`):

```ts
  // Remotion source display (spec 2026-07-17): the selector is the single gate —
  // node data carries source only for remotion runs that have one persisted.
  const remotionSource = comp?.render_mode === "remotion" && comp.source != null
    ? { source: comp.source, component_slug: comp.component_slug ?? null,
        props_schema: comp.props_schema ?? null, default_props: comp.default_props ?? null,
        personalized_field: comp.personalized_field ?? null }
    : null;
  const xShift = remotionSource ? 240 : 0; // widened node (w-40 → w-80) + breathing room
```

Then update the nodes array (only the listed lines change):

```ts
    { id: "composition", kind: "composition", label: "Composition",
      data: { render_mode: comp?.render_mode, status: comp?.status,
              error_code: comp?.error_code, error_message: comp?.error_message,
              used_likeness: comp?.used_likeness, used_voice_clone: comp?.used_voice_clone,
              ...(remotionSource ?? {}) }, x: 420, y: 40 },
    { id: "adrun", kind: "adrun", label: "Ad Run", data: { status: adRun.status }, x: 640 + xShift, y: 40 },
    ...plays.map((p, i): GraphNode => ({ id: `play_${i}`, kind: "playback",
      label: "Playback", data: { screen_id: p.screen_id, display_id: p.display_id ?? "(unresolved)", status: p.status }, x: 860 + xShift, y: 20 + i * 90 })),
    { id: "exposure", kind: "exposure", label: "Viewer Exposure",
      data: exposureData ?? { note: "no exposure data yet" }, x: 860 + xShift, y: 240,
      ghost: !exposureData },
```

and the `creative_inputs` satellite's position becomes `x: 420, y: remotionSource ? 460 : 160`.

- [ ] **Step 5: Run tests to verify green**

Run: `npx vitest run src/data/selectors.test.ts`
Expected: all PASS.

- [ ] **Step 6: Commit the green implementation** (via git-flow-manager)

Stage only `src/data/apiTypes.ts` and `src/data/selectors.ts`.
Message: `feat: adRunGraph passes remotion source through composition node, shifts layout (green)`

---

### Task 2 (L2): Zero-dep `.tsx` tokenizer

**Files:**
- Create: `src/components/remotion/highlightTsx.ts`
- Test: `src/components/remotion/highlightTsx.test.ts`

**Interfaces:**
- Produces: `highlightTsx(source: string): Token[][]` — one row per source line; `Token = { text: string; type: "keyword" | "string" | "comment" | "tag" | "number" | "plain" }`. Concatenating every row's `text` joined by `"\n"` reproduces the input exactly (Task L3 relies on this for the Copy button showing what's rendered). Task L3 imports both `highlightTsx` and `TokenType`.

- [ ] **Step 1: Write the failing test**

Create `src/components/remotion/highlightTsx.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { highlightTsx } from "./highlightTsx";

describe("highlightTsx", () => {
  it("classifies keywords, strings, numbers and plain identifiers", () => {
    const [line] = highlightTsx('const x = "hi" + 42;');
    expect(line).toContainEqual({ text: "const", type: "keyword" });
    expect(line).toContainEqual({ text: '"hi"', type: "string" });
    expect(line).toContainEqual({ text: "42", type: "number" });
    expect(line).toContainEqual({ text: "x", type: "plain" });
  });

  it("classifies comments and JSX tags", () => {
    const lines = highlightTsx("// note\nreturn <AbsoluteFill>text</AbsoluteFill>;");
    expect(lines[0]).toEqual([{ text: "// note", type: "comment" }]);
    expect(lines[1]).toContainEqual({ text: "<AbsoluteFill", type: "tag" });
    expect(lines[1]).toContainEqual({ text: "</AbsoluteFill", type: "tag" });
  });

  it("emits one row per line and round-trips the text exactly", () => {
    const src = 'import { AbsoluteFill } from "remotion";\n\nexport const Hello = () => {\n  return <AbsoluteFill />;\n};';
    const lines = highlightTsx(src);
    expect(lines).toHaveLength(5);
    expect(lines.map((l) => l.map((t) => t.text).join("")).join("\n")).toBe(src);
  });

  it("does not treat a less-than comparison as a JSX tag", () => {
    const [line] = highlightTsx("if (a < 5) return 1;");
    expect(line.find((t) => t.type === "tag")).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run src/components/remotion/highlightTsx.test.ts`
Expected: FAIL — cannot resolve `./highlightTsx`.

- [ ] **Step 3: Commit the red test** (via git-flow-manager)

Stage only `src/components/remotion/highlightTsx.test.ts`.
Message: `test: zero-dep tsx tokenizer for remotion source display (red)`

- [ ] **Step 4: Implement the tokenizer**

Create `src/components/remotion/highlightTsx.ts`:

```ts
export type TokenType = "keyword" | "string" | "comment" | "tag" | "number" | "plain";
export interface Token { text: string; type: TokenType }

const KEYWORDS = new Set([
  "import", "export", "from", "const", "let", "var", "function", "return", "default",
  "if", "else", "for", "while", "new", "typeof", "interface", "type", "extends",
  "as", "async", "await", "null", "undefined", "true", "false",
]);

// Display-grade single-pass tokenizer, not a parser: comments/strings win first,
// then JSX tag opens/closes, numbers, identifiers, and a whitespace/punctuation rest.
const TOKEN_RE =
  /(\/\/[^\n]*|\/\*[\s\S]*?\*\/)|("(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`(?:[^`\\]|\\.)*`)|(<\/?[A-Za-z][\w.]*|\/?>)|(\b\d+(?:\.\d+)?\b)|([A-Za-z_$][\w$]*)|(\s+|[^\sA-Za-z0-9_$]+)/g;

export function highlightTsx(source: string): Token[][] {
  const lines: Token[][] = [[]];
  const push = (text: string, type: TokenType) => {
    text.split("\n").forEach((part, i) => {
      if (i > 0) lines.push([]);
      if (part) lines[lines.length - 1].push({ text: part, type });
    });
  };
  TOKEN_RE.lastIndex = 0;
  let m: RegExpExecArray | null;
  while ((m = TOKEN_RE.exec(source)) !== null) {
    const text = m[0];
    const type: TokenType = m[1] ? "comment" : m[2] ? "string" : m[3] ? "tag"
      : m[4] ? "number" : m[5] ? (KEYWORDS.has(text) ? "keyword" : "plain") : "plain";
    push(text, type);
  }
  return lines;
}
```

- [ ] **Step 5: Run test to verify green**

Run: `npx vitest run src/components/remotion/highlightTsx.test.ts`
Expected: all 4 PASS.

- [ ] **Step 6: Commit the green implementation** (via git-flow-manager)

Stage only `src/components/remotion/highlightTsx.ts`.
Message: `feat: zero-dep regex tokenizer for tsx display highlighting (green)`

---

### Task 3 (L3): `RemotionSourcePanel` component

**Files:**
- Create: `src/components/remotion/RemotionSourcePanel.tsx`
- Test: `src/components/remotion/RemotionSourcePanel.test.tsx`

**Interfaces:**
- Consumes: `highlightTsx`, `TokenType` from Task L2.
- Produces: `RemotionSourcePanel({ slug, source, defaultProps, personalizedField }: { slug: string; source: string; defaultProps: Record<string, unknown> | null; personalizedField: string | null })` — Task L4 mounts it inside `PipelineNode`. No xyflow imports; renders standalone.

- [ ] **Step 1: Write the failing test**

Create `src/components/remotion/RemotionSourcePanel.test.tsx`:

```tsx
import { afterEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import { RemotionSourcePanel } from "./RemotionSourcePanel";

const props = {
  slug: "comp-hello",
  source: 'export const Hello = () => <div>hi</div>;',
  defaultProps: { text: "Hello" } as Record<string, unknown>,
  personalizedField: "name",
};

afterEach(() => vi.unstubAllGlobals());

describe("RemotionSourcePanel", () => {
  it("renders filename, highlighted code and props strip, expanded by default", () => {
    render(<RemotionSourcePanel {...props} />);
    expect(screen.getByText("comp-hello.tsx")).toBeInTheDocument();
    expect(screen.getByText("export")).toBeInTheDocument(); // keyword token span
    expect(screen.getByText("name ← viewer.visible_name")).toBeInTheDocument();
    expect(screen.getByText("text: Hello")).toBeInTheDocument();
  });

  it("collapses to a one-line summary and expands back", () => {
    render(<RemotionSourcePanel {...props} />);
    fireEvent.click(screen.getByLabelText("Collapse source"));
    expect(screen.queryByText("export")).not.toBeInTheDocument();
    expect(screen.getByText(/source hidden/)).toBeInTheDocument();
    fireEvent.click(screen.getByLabelText("Expand source"));
    expect(screen.getByText("export")).toBeInTheDocument();
  });

  it("copies the raw source to the clipboard", () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    vi.stubGlobal("navigator", { ...navigator, clipboard: { writeText } });
    render(<RemotionSourcePanel {...props} />);
    fireEvent.click(screen.getByText("Copy"));
    expect(writeText).toHaveBeenCalledWith(props.source);
  });

  it("omits the props strip entirely when there is no personalization metadata", () => {
    render(<RemotionSourcePanel {...props} defaultProps={null} personalizedField={null} />);
    expect(screen.queryByText(/viewer.visible_name/)).not.toBeInTheDocument();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run src/components/remotion/RemotionSourcePanel.test.tsx`
Expected: FAIL — cannot resolve `./RemotionSourcePanel`.

- [ ] **Step 3: Commit the red test** (via git-flow-manager)

Stage only `src/components/remotion/RemotionSourcePanel.test.tsx`.
Message: `test: RemotionSourcePanel expanded-by-default code + props strip + copy (red)`

- [ ] **Step 4: Implement the panel**

Create `src/components/remotion/RemotionSourcePanel.tsx`. Note the single-template-literal
text nodes (`{`...`}`) — split JSX expressions would break `getByText` on the full string:

```tsx
import { useState } from "react";
import { highlightTsx, type TokenType } from "./highlightTsx";

const TOKEN_CLASS: Record<TokenType, string> = {
  keyword: "text-accent", string: "text-ok", comment: "text-faint italic",
  tag: "text-warn", number: "text-dim", plain: "",
};

export function RemotionSourcePanel({ slug, source, defaultProps, personalizedField }:
  { slug: string; source: string; defaultProps: Record<string, unknown> | null; personalizedField: string | null }) {
  const [open, setOpen] = useState(true); // owner decision 2026-07-17: expanded by default
  const [copied, setCopied] = useState(false);
  const lines = highlightTsx(source);
  const copy = () => {
    navigator.clipboard?.writeText(source).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    });
  };
  return (
    <div className="nodrag mt-1.5 border border-borderSoft rounded-[7px] bg-elev2/80 overflow-hidden cursor-auto">
      <div className="flex items-center gap-1.5 px-2 py-1 border-b border-borderSoft">
        <button aria-label={open ? "Collapse source" : "Expand source"} onClick={() => setOpen(!open)}
          className="text-dim text-[10px] leading-none">{open ? "▾" : "▸"}</button>
        <span className="font-mono text-[10px] text-dim truncate">{`${slug}.tsx`}</span>
        <span className="font-mono text-[9px] text-faint ml-auto">{`${lines.length} lines`}</span>
        <button onClick={copy}
          className="font-mono text-[9.5px] text-dim border border-borderSoft rounded px-1.5 py-0.5">
          {copied ? "Copied" : "Copy"}
        </button>
      </div>
      {open ? (
        <>
          <pre className="nowheel max-h-[240px] overflow-auto py-1 m-0 font-mono text-[9.5px] leading-[1.5]">
            {lines.map((toks, i) => (
              <div key={i} className="flex">
                <span className="w-7 shrink-0 text-right pr-2 text-faint select-none">{i + 1}</span>
                <span className="whitespace-pre pr-2">
                  {toks.map((t, j) => t.type === "plain"
                    ? t.text
                    : <span key={j} className={TOKEN_CLASS[t.type]}>{t.text}</span>)}
                </span>
              </div>
            ))}
          </pre>
          {(personalizedField != null || defaultProps != null) && (
            <div className="px-2 py-1 border-t border-borderSoft flex flex-wrap gap-1">
              {personalizedField != null && (
                <span className="font-mono text-[9px] text-accent bg-accent/10 rounded px-1 py-0.5">
                  {`${personalizedField} ← viewer.visible_name`}
                </span>
              )}
              {Object.entries(defaultProps ?? {}).map(([k, v]) => (
                <span key={k} className="font-mono text-[9px] text-faint bg-elev rounded px-1 py-0.5">
                  {`${k}: ${String(v)}`}
                </span>
              ))}
            </div>
          )}
        </>
      ) : (
        <div className="px-2 py-1 font-mono text-[9px] text-faint">{`${lines.length} lines · source hidden`}</div>
      )}
    </div>
  );
}
```

- [ ] **Step 5: Run test to verify green**

Run: `npx vitest run src/components/remotion/RemotionSourcePanel.test.tsx`
Expected: all 4 PASS.

- [ ] **Step 6: Commit the green implementation** (via git-flow-manager)

Stage only `src/components/remotion/RemotionSourcePanel.tsx`.
Message: `feat: RemotionSourcePanel — highlighted tsx, collapse, copy, props strip (green)`

---

### Task 4 (L4): Mount in `PipelineNode` + Inspector hygiene (page integration)

**Files:**
- Modify: `src/components/PipelineNode.tsx` (non-satellite branch)
- Modify: `src/pages/AdDetail.tsx:53-55` (Inspector rows filter)
- Test: `src/pages/AdDetail.test.tsx` (append — it renders REAL ReactFlow in jsdom and its `vi.mock("../data/api", ...)` pattern is the one to extend)

**Interfaces:**
- Consumes: `data.source` / `data.component_slug` / `data.default_props` / `data.personalized_field` set by Task L1; `RemotionSourcePanel` from Task L3.
- Produces: the shipped feature — no downstream consumers.

- [ ] **Step 1: Write the failing tests**

Append to the `describe("AdDetail", ...)` block in `src/pages/AdDetail.test.tsx` (reuse its imports; note the file's existing mock resolves a non-remotion detail — these tests override per-test via `vi.mocked(fetchAdRun)`, same as the retry test does):

```tsx
  const remotionDetail = {
    ad_run: { id: "ar_rem1", trigger_id: "trg9", status: "completed", started_at: "2026-07-06T18:00:00Z", ended_at: null, system_id: "s1" },
    personalization_decision: { id: "pd9", decision_type: "identity", decision_confidence: 0.9, decision_factors: {}, target_subject_profile_id: null },
    composition_run: {
      id: "cr9", render_mode: "remotion", status: "rendered", error_code: null, error_message: null,
      used_likeness: false, used_voice_clone: false, ad_id: "ad9", component_id: "comp9",
      input_asset_id: null, output_asset_id: null, used_spoken_name: false, used_visible_name: true,
      component_slug: "comp-hello", source: "export const Hello = () => <div>hi</div>;",
      props_schema: { type: "object" }, default_props: { text: "Hello" }, personalized_field: "name",
      base_video: "base.mp4",
    },
    playbacks: [{ id: "pb9", status: "ended", display_id: "d1", screen_id: "scr_r", error_code: null, error_message: null }],
  };

  it("shows the remotion source panel inside the Composition node, expanded by default", async () => {
    const { fetchAdRun } = await import("../data/api");
    vi.mocked(fetchAdRun).mockResolvedValueOnce(remotionDetail as any);
    render(
      <MemoryRouter initialEntries={["/compositions/ar_rem1"]}>
        <Routes><Route path="/compositions/:adRunId" element={<AdDetail />} /></Routes>
      </MemoryRouter>,
    );
    await waitFor(() => expect(screen.getByText("comp-hello.tsx")).toBeInTheDocument());
    expect(screen.getByText("export")).toBeInTheDocument();
    expect(screen.getByText("name ← viewer.visible_name")).toBeInTheDocument();
  });

  it("renders no source panel for non-remotion runs", async () => {
    render(
      <MemoryRouter initialEntries={["/compositions/ar_d3aa77"]}>
        <Routes><Route path="/compositions/:adRunId" element={<AdDetail />} /></Routes>
      </MemoryRouter>,
    );
    await waitFor(() => expect(screen.getByText(/OVERLAY_RENDER_TIMEOUT/)).toBeInTheDocument());
    expect(screen.queryByText(/\.tsx/)).not.toBeInTheDocument();
  });

  it("keeps the bulky source string out of the Inspector rows", async () => {
    const { fetchAdRun } = await import("../data/api");
    vi.mocked(fetchAdRun).mockResolvedValueOnce(remotionDetail as any);
    render(
      <MemoryRouter initialEntries={["/compositions/ar_rem1"]}>
        <Routes><Route path="/compositions/:adRunId" element={<AdDetail />} /></Routes>
      </MemoryRouter>,
    );
    await waitFor(() => expect(screen.getByText("comp-hello.tsx")).toBeInTheDocument());
    // composition is the default-selected node; the inspector must not dump `source`
    const inspector = screen.getByTestId("inspector");
    expect(inspector.textContent).not.toContain("export const Hello");
    expect(inspector).toHaveTextContent("render_mode");
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx vitest run src/pages/AdDetail.test.tsx`
Expected: the two remotion tests FAIL (`comp-hello.tsx` not found — panel doesn't exist yet). The
non-remotion test passes trivially; keep it as the regression guard. If the Inspector test fails
on `source` leaking, that confirms the AdDetail filter is needed.

- [ ] **Step 3: Commit the red tests** (via git-flow-manager)

Stage only `src/pages/AdDetail.test.tsx`.
Message: `test: AdDetail renders remotion source panel in Composition node, inspector stays clean (red)`

- [ ] **Step 4: Implement — PipelineNode variant + Inspector filter**

In `src/components/PipelineNode.tsx`, import the panel and widen the non-satellite branch when
source is present (the ternary selects between FULL literal class strings):

```tsx
import { Handle, Position } from "@xyflow/react";
import { StatusDot } from "./StatusDot";
import { RemotionSourcePanel } from "./remotion/RemotionSourcePanel";
```

and replace the non-satellite `return` with:

```tsx
  const hasSource = data.kind === "composition" && typeof data.source === "string";
  return (
    <div className={`${hasSource ? "w-80" : "w-40"} bg-elev border rounded-[9px] px-2.5 py-2.5 ${data.ghost ? "opacity-40 border-dashed border-border" : data.failed ? "border-crit/50" : "border-border"} ${data.selected ? "ring-1 ring-accent" : ""}`}>
      <Handle type="target" position={Position.Left} className="!bg-border" />
      <div className="flex items-center gap-1.5 mb-1">
        {!data.ghost && <StatusDot status={data.status ?? "off"} kind="adrun" />}
        <span className="text-[11.5px] font-semibold">{data.label}</span>
      </div>
      {data.sub && <div className="font-mono text-[10px] text-faint">{data.sub}</div>}
      {hasSource && (
        <RemotionSourcePanel slug={data.component_slug ?? "component"} source={data.source}
          defaultProps={data.default_props ?? null} personalizedField={data.personalized_field ?? null} />
      )}
      <Handle type="source" position={Position.Right} className="!bg-border" />
    </div>
  );
```

In `src/pages/AdDetail.tsx`, the rows filter (currently `:53-55`) additionally drops `source`
(the panel already shows it; a multi-KB string would flood the inspector):

```ts
  const rows: [string, string][] = sel
    ? Object.entries(sel.data)
        .filter(([k, v]) => v !== undefined && typeof v !== "object" && k !== "source")
        .map(([k, v]) => [k, String(v)])
    : [];
```

- [ ] **Step 5: Run the full suite + lint**

Run: `npm test` then `npm run lint`
Expected: everything PASSES (including all pre-existing suites — the selector shift only
activates on remotion-with-source data, which no old test uses).

- [ ] **Step 6: Commit the green implementation** (via git-flow-manager)

Stage only `src/components/PipelineNode.tsx` and `src/pages/AdDetail.tsx`.
Message: `feat: Composition node renders RemotionSourcePanel; inspector omits source (green)`

---

### Task 5 (L5): Live E2E + design review (controller checklist — not a subagent task)

Needs Plan K deployed (Task K4) so real data carries `source`.

- [ ] Clean dev-server start in the worktree: `npx vite --port 5175 --strictPort` (avoid HMR-warmup artifacts; port must not collide with the kiosk's 5173).
- [ ] Playwright MCP against the user's real Chrome, app tab only: navigate to `/compositions`, open a remotion ad-run, verify: expanded highlighted source with line numbers inside the Composition node, filename header `comp-<slug>.tsx`, props strip with `name ← viewer.visible_name`, Copy works, wheel over the code scrolls the code (canvas zoom unchanged), collapse → summary line, downstream nodes not overlapped, non-remotion runs unchanged.
- [ ] Dedicated design-review pass against the mockup (owner-locked gate) before merge: https://claude.ai/code/artifact/0c3923a3-7014-40d2-bda4-9cb9545bbf67
- [ ] Close-out: SESSION_LOG entry, memory update, follow-up issues, worktree cleanup.
