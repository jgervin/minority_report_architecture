# Flat Map v4 — Investigation Findings

Repo investigated: `/Users/jn/code/godview-prototype` (main@3bc3ff7, read-only, no edits/git made).

## Root-Cause Summary

**Teal square bug:** Venue selection flies the camera through a **3-stage zoom ladder**
(`nextFlyZoom` in `/Users/jn/code/godview-prototype/src/data/mapSelectors.ts:18-22`: country
zoom 4 → city zoom 11 → building zoom 15.5), advancing only ONE stage per click, based on the
map's *current* zoom. Starting from the initial view (`mapZoom = 1.4`,
`/Users/jn/code/godview-prototype/src/pages/FlatMap.tsx:38`), a single venue-select click flies
only to **zoom 4** — which is still `mapTier(4) === "world"` because `CITY_ZOOM = 5`
(`/Users/jn/code/godview-prototype/src/data/mapSelectors.ts:5-11`). Since the building glyph
layer is gated on `mapTier(mapZoom) === "building"`
(`/Users/jn/code/godview-prototype/src/pages/FlatMap.tsx:55`, `BUILDING_ZOOM = 14`), it never
fires — no system/camera/display detail is even fetched, so `building` stays `null` and the
building sources stay empty (`/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.tsx:177-178`).
All the user sees is the **venue marker itself**: at world/city tier this is a DOM `<div>` with
only a `box-shadow`/`border` ring (no filled icon) colored by the venue's org "halo" color
(`/Users/jn/code/godview-prototype/src/data/venueMarkers.ts:32-36`). The org palette
(`/Users/jn/code/godview-prototype/src/data/topologySelectors.ts:11`) includes `#2dd4bf`
(Tailwind teal-400) as one of 6 rotating hues — so roughly 1-in-6 venues render exactly a small
teal square outline with nothing inside it. The user must click the **same venue 3 times in a
row** to actually walk the zoom ladder into the building tier and see camera/screen glyphs.

**Label-overlap bug:** Venue markers + labels are plain `mapboxgl.Marker` DOM elements
(`/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.tsx:165`), not a GeoJSON
symbol layer. DOM markers have **no collision/declutter system** — Mapbox's `text-allow-overlap`/
`symbol-sort-key` machinery only applies to symbol layers, and none exists for venues. At world
zoom with many venues close together, their badges (`venue.name · N sys` text,
`/Users/jn/code/godview-prototype/src/data/venueMarkers.ts:28-31`) simply stack in the DOM with
zero decluttering. Fix requires either migrating venues to a real symbol layer (to get Mapbox's
built-in label collision) or suppressing labels at world tier (only show on hover/selection).

---

## 1. Teal Square Root Cause (detailed trace)

**flyTo target zoom — staged, not single-shot.**
`/Users/jn/code/godview-prototype/src/pages/FlatMap.tsx:80-81`:
```ts
const flyToVenue = (lat: number, lng: number) =>
  setMapFocus((f) => ({ lat, lng, zoom: nextFlyZoom(mapZoom), token: (f?.token ?? 0) + 1 }));
```
`nextFlyZoom` — `/Users/jn/code/godview-prototype/src/data/mapSelectors.ts:14-22`:
```ts
export const STAGE_ZOOM = { country: 4, city: 11, building: 15.5 } as const;

export function nextFlyZoom(currentZoom: number): number {
  if (currentZoom < STAGE_ZOOM.country) return STAGE_ZOOM.country;
  if (currentZoom < STAGE_ZOOM.city) return STAGE_ZOOM.city;
  return STAGE_ZOOM.building;
}
```
This is called by both the rail-click handler (`FlatMap.tsx:106`) and the corner-globe dot click
(`FlatMap.tsx:89-92` → `selectVenue` → `flyToVenue`). Both read `mapZoom`, the *live* map zoom
state updated continuously by `FlatMapCanvas`'s `zoom` event
(`/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.tsx:84-88`). Since the
page initializes `mapZoom = 1.4` (`FlatMap.tsx:38`), the **first** selection click computes
`nextFlyZoom(1.4) = 4` (country stage) — not building. A second click (now at ~zoom 4) computes
`nextFlyZoom(4) = 11` (city stage). Only a **third** click (now at ~zoom 11) computes
`nextFlyZoom(11) = 15.5` (building stage). The actual camera move is a single `map.flyTo` per
click (`/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.tsx:247-251`):
```ts
useEffect(() => {
  const map = mapRef.current;
  if (!map || !focus) return;
  map.flyTo({ center: [focus.lng, focus.lat], zoom: focus.zoom, duration: 1200 });
}, [focus, ready]);
```
— i.e. each click IS a real flyTo, but to the *next rung* of the ladder, not to the final
building zoom.

**Does the landed zoom reach the "building" tier?** Only on the 3rd click.
`mapTier` — `/Users/jn/code/godview-prototype/src/data/mapSelectors.ts:3-12`:
```ts
export const CITY_ZOOM = 5;
export const BUILDING_ZOOM = 14;

export function mapTier(zoom: number): MapTier {
  if (zoom < CITY_ZOOM) return "world";
  if (zoom < BUILDING_ZOOM) return "city";
  return "building";
}
```
Click 1 lands at zoom 4 → `mapTier(4) = "world"`. Click 2 lands at zoom 11 → `mapTier(11) =
"city"`. Click 3 lands at zoom 15.5 → `mapTier(15.5) = "building"` (only now ≥ `BUILDING_ZOOM=14`).

**Building-tier gate.** `/Users/jn/code/godview-prototype/src/pages/FlatMap.tsx:53-56`:
```ts
// Plan H building tier (Task 6, mirrors Globe.tsx:42-61): only the selected venue's detail is
// fetched, and only once Mapbox zoom crosses into the building band.
const buildingVenueId = mapTier(mapZoom) === "building" ? selectedVenueId : null;
const { detail } = useVenueDetailPoll(buildingVenueId);
```
Until click 3, `buildingVenueId` is `null`, so `detail` never loads, `nodes`/`building` stay
`null` (`FlatMap.tsx:59,61`), and the Mapbox building sources are cleared to empty
(`/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.tsx:174-179`):
```ts
useEffect(() => {
  const map = mapRef.current;
  if (!map || !ready || !map.isStyleLoaded()) return;
  map.getSource("building-connectors")?.setData(building?.connectors ?? EMPTY_FC);
  map.getSource("building-glyphs")?.setData(building?.glyphs ?? EMPTY_FC);
}, [building, ready]);
```

**What is the "teal square"?** It is the **venue marker**, not a building glyph. Venue markers
are pure DOM elements built by `buildVenueMarker` —
`/Users/jn/code/godview-prototype/src/data/venueMarkers.ts:11-39`:
```ts
export function buildVenueMarker(
  venue: MapVenue, tier: MapTier, _mode: MapMode, orgColor: string | null,
): VenueMarkerDatum {
  const el = document.createElement("div");
  el.setAttribute("data-testid", "venue-marker");
  ...
  const tone = TONE_HEX[healthTone(venue.rollup)];
  const dot = document.createElement("span");
  dot.setAttribute("style", `background:${tone}`);
  el.appendChild(dot);

  if (tier === "world") {
    const badge = document.createElement("span");
    badge.textContent = `${venue.name} · ${venue.rollup.systems} sys`;
    el.appendChild(badge);
  } else {
    const halo = orgColor ?? "#212734";
    el.style.boxShadow = `0 0 0 2px ${halo}`;
    el.style.border = `1px solid ${halo}`;
  }
  return { id: venue.location_id, lat: venue.lat ?? 0, lng: venue.lng ?? 0, el };
}
```
Neither the outer `el` div nor the inner `dot` span is ever given an explicit width/height
anywhere in the codebase (confirmed: `/Users/jn/code/godview-prototype/src/index.css` has no
rules for `venue-marker`/dot sizing — it's just the 3-line Tailwind base import). So at
city/building tier (the `else` branch, taken once `mapTier !== "world"`, i.e. from click 2
onward), the visible shape is literally just the CSS `border` + `box-shadow` ring around a
zero-content box — an outlined little square with no icon inside, colored by `orgColor` (or
`#212734` default). `orgColor` comes from `ORG_PALETTE` —
`/Users/jn/code/godview-prototype/src/data/topologySelectors.ts:11`:
```ts
export const ORG_PALETTE = ["#45c4ff", "#a78bfa", "#f472b6", "#fb923c", "#2dd4bf", "#818cf8"];
```
`#2dd4bf` (index 4, Tailwind teal-400) is one of the 6 rotating org hues — so for orgs at that
palette index, the marker is exactly a small **teal** square outline. This matches the reported
symptom precisely, independent of which click count the user reached.

**Do building glyphs actually render, if you get there?** Yes, if `mapTier === "building"` and
detail loads: `buildingFeatures()` produces `circle` + `symbol` GeoJSON features
(`/Users/jn/code/godview-prototype/src/data/buildingFeatures.ts:43-71`), rendered via the
`building-glyphs-circle` and `building-glyphs-symbol` layers added at map load
(`/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.tsx:97-111`). Node
layout radii — `/Users/jn/code/godview-prototype/src/data/mapLayout.ts:21-22`:
```ts
const SYSTEM_RING_M = 40;            // building-scale radii in meters (Task 11 tunes live)
const DEVICE_RING_M = 70;
```
At the building-stage fly zoom (15.5), meters-per-pixel ≈ `156543 * cos(lat) / 2^15.5` ≈
2.6–3.4 px/m depending on latitude, so the 40m/70m rings resolve to roughly 12–30px screen
radius — small but visually separable circles, not sub-pixel. So the ring geometry itself is not
the blocker; the zoom simply never gets there on the first (or even second) click.

**Bottom line / what needs to change:** `nextFlyZoom` should fly a freshly-selected venue
straight to `STAGE_ZOOM.building` (or a single dedicated "focus zoom") in one flyTo, rather than
walking a 3-click ladder gated on live `mapZoom`. The ladder logic conflates two different
behaviors — "user is exploring/zooming in generally" vs. "user explicitly selected a venue and
wants its building detail" — and venue *selection* (rail click, corner-dot click) should always
target the building zoom directly. Separately, the venue marker itself should probably render an
actual filled/iconized shape (not just an empty border ring) so it reads as a marker rather than
a stray colored square, regardless of zoom-fix.

---

## 2. Stacked Labels at World Zoom

Venue markers + labels are **DOM `mapboxgl.Marker` elements**, not a GeoJSON symbol layer —
confirmed at `/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.tsx:164-166`:
```ts
const datum = buildVenueMarker(v, tier, mode, orgColor);
const marker = new mapboxgl.Marker({ element: datum.el }).setLngLat([v.lng, v.lat]).addTo(map);
next.set(v.location_id, marker);
```
The label text itself is plain DOM textContent set inside `buildVenueMarker`'s world-tier branch
(`/Users/jn/code/godview-prototype/src/data/venueMarkers.ts:28-31`, quoted above). DOM markers
are positioned purely by lng/lat → screen projection with CSS `transform`; Mapbox's label
collision engine (`text-allow-overlap`, `text-optional`, `symbol-sort-key`) is a **symbol-layer
only** feature and does not apply to `mapboxgl.Marker` DOM elements at all. There is no such
layer for venues in `/Users/jn/code/godview-prototype/src/map/style.json` (the only symbol
layer defined there is the basemap's `settlement-label`, lines 18-20, unrelated to venues). So
at world zoom with many venues geographically close, badges simply overlap/stack in the DOM with
no decluttering mechanism whatsoever — this is a structural gap, not a misconfigured collision
flag.

**Fix options:** (a) migrate venue markers to a real Mapbox GeoJSON `symbol` layer (icon +
`text-field`) to get built-in collision detection (`text-allow-overlap: false`,
`text-optional: true`, `symbol-sort-key` by rollup severity) — loses per-venue click-handler
simplicity that DOM markers give for free, would need `layer.on('click', ...)` querying instead;
or (b) keep DOM markers but suppress the text badge at world tier entirely (show only the health
dot / a fixed-size icon) and reveal the name only on hover or once a venue is selected.

---

## 3. Venue / Building Icons

**World/city tier (venue):** no icon — a DOM `<div>` with a `background`-colored `<span>` (dot,
zero explicit size per finding in §1) plus, at world tier only, plain text
`"{name} · {N} sys"`; at city/building tier, just a `border`/`box-shadow` outline ring in the org
halo color. Source: `/Users/jn/code/godview-prototype/src/data/venueMarkers.ts:11-39` (quoted
above).

**Building tier (system/camera/display):** rendered via Mapbox `circle` + `symbol` paint, not
Marker DOM elements. `glyphIcon` — `/Users/jn/code/godview-prototype/src/data/buildingFeatures.ts:27-31`:
```ts
export function glyphIcon(type: MapNode["type"]): string {
  if (type === "system") return "▣";
  if (type === "camera") return "◉";
  return "▤";
}
```
This `icon` field is written into each glyph feature's `properties.icon`
(`/Users/jn/code/godview-prototype/src/data/buildingFeatures.ts:46-53`) **but it is never
consumed** by any Mapbox layer — the `building-glyphs-symbol` layer's `text-field` uses
`properties.glyph` (the *status* glyph, from `statusGlyph(node.status)`) concatenated with
`properties.label`, not `properties.icon`
(`/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.tsx:104-111`):
```ts
map.addLayer({
  id: "building-glyphs-symbol", type: "symbol", source: "building-glyphs",
  layout: {
    "text-field": ["concat", ["get", "glyph"], " ", ["get", "label"]],
    "text-size": 10, "text-offset": [0, 1.2],
  },
  paint: { "text-color": ["get", "color"] },
});
```
So today's actual visual for a system/camera/display node is: a plain colored `circle` (radius 6,
`building-glyphs-circle` layer, `/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.tsx:97-103`)
plus a small text label below it showing the *status* glyph (not the shape glyph ▣/◉/▤) + node
name. The type-differentiating `▣/◉/▤` glyph field exists in the data (`glyphIcon`,
`buildingFeatures.ts:27-31`, `properties.icon`) but is dead/unused in the render layer — a real,
already-modeled seam to wire up.

**Icon library:** `lucide-react` **is** a dependency —
`/Users/jn/code/godview-prototype/package.json` lists `"lucide-react": "^1.23.0"` — but
`grep -rl lucide-react src` returns **no matches**; it is not imported/used anywhere in `src/`
today.

**Mapbox symbol images:** `grep -rn "addImage\|loadImage" src` returns **no matches** anywhere in
the repo. There is no `map.addImage` call — all Mapbox rendering is either paint-based
(circle/line fill colors) or plain-text `symbol` layers using system fonts via
`style.json`'s `glyphs` URL (`/Users/jn/code/godview-prototype/src/map/style.json:4`). To render
real camera/monitor line-icons on the Mapbox canvas (vs. Unicode glyphs), the building layer
would need `map.addImage()` calls (e.g. rasterized lucide SVGs) wired into the existing
`building-glyphs-symbol` layer via `icon-image`; venue markers, being DOM-based, could use
`lucide-react` components directly inside `buildVenueMarker`'s created elements.

---

## 4. Corner Globe Nav Window

`/Users/jn/code/godview-prototype/src/pages/FlatMap.tsx:117-125`:
```tsx
{webgl && (
  <div data-testid="corner-globe" className="absolute bottom-3 left-3 h-[300px] w-[300px] overflow-hidden rounded-[10px] border border-border bg-bg">
    <GlobeCanvas dots={dots} mode={mode} focus={null}
      arcs={[]} labels={[]} highlightOrgId={null}
      explosion={null} liveSystems={new Set()} farPulses={null} deepPulses={null}
      paused={cameraBusy}
      onDotClick={onCornerDotClick} onNodeClick={() => {}} onPovChange={setPov} />
  </div>
)}
```
Position: `absolute bottom-3 left-3` (bottom-left corner of the map container). Size: fixed
`300px × 300px` (`h-[300px] w-[300px]`), `overflow-hidden`, rounded 10px corners, 1px border,
`bg-bg` (matches page background, `#0a0d12` per `tailwind.config.ts:9`). `GlobeCanvas` is fed
`focus={null}` (no programmatic fly-to — the mini-globe never re-centers itself), empty
`arcs`/`labels` arrays (no org-arc sweep or mid-zoom labels on the mini-globe — dots-only), and
`explosion={null}`/`liveSystems={new Set()}`/`farPulses={null}`/`deepPulses={null}` (no
building-tier visuals on the mini-globe at all — confirms it's a dots-only navigation aid).
`paused={cameraBusy}` — `cameraBusy` is set from the big map's `movestart`/`moveend` events
(`/Users/jn/code/godview-prototype/src/components/flatmap/FlatMapCanvas.tsx:82-83`,
`onCameraBusyRef.current(true/false)`), so the mini-globe's autorotate presumably pauses while
the main Mapbox camera is moving. `onPovChange={setPov}` feeds the mini-globe's own
altitude/lat/lng back into `FlatMap`'s `pov` state (`FlatMap.tsx:35-36`), which drives
`clusterVenues(venues, pov.altitude)` for the mini-globe's own dot clustering — i.e. the
mini-globe is a fully independent navigation camera from the big Mapbox map, linked only via
`onCornerDotClick` (clicking a dot on the mini-globe drives the big map's `flyToVenue`/`selectVenue`,
`FlatMap.tsx:89-92`). **No zoom control** exists on it (no `+`/`-` buttons, no exposed zoom prop) —
its only interaction is drag-to-orbit (`globe.gl`'s default `OrbitControls`, per
`/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.tsx:225-228` — `autoRotate`,
`addEventListener("start", ...)` to stop autorotate on user interaction) plus dot clicks.

---

## 5. Panels (Collapse Feature)

**Layout container — identical grid in both pages:**
- FlatMap: `/Users/jn/code/godview-prototype/src/pages/FlatMap.tsx:101`:
  `<div className="grid grid-cols-1 lg:grid-cols-[280px_minmax(0,1fr)] gap-4 h-[calc(100vh-170px)] min-h-[420px]">`
- Globe: `/Users/jn/code/godview-prototype/src/pages/Globe.tsx:119`: identical classes.

**Left rail:**
- FlatMap (`/Users/jn/code/godview-prototype/src/pages/FlatMap.tsx:102-108`): a fixed 280px grid
  column, always visible on desktop (`overflow-auto border border-border rounded-[10px] p-2`),
  containing only `<VenueRail>`. No collapse state.
- Globe (`/Users/jn/code/godview-prototype/src/pages/Globe.tsx:120-123`): same 280px column but
  `hidden lg:block` (hidden entirely on mobile, replaced by a bottom-sheet triggered via a
  floating `rail-toggle` button, `Globe.tsx:130-133`, and a full `mobile-rail` overlay,
  `Globe.tsx:151-159`) — contains `<OrgChips>` + `<VenueRail>`. **No desktop collapse/toggle** —
  the rail column is unconditionally rendered at 280px on `lg:` viewports; only the
  mobile show/hide (`railOpen` boolean) exists, and that's a full overlay sheet, not a
  width-collapsing rail.

**Right detail panel:**
- FlatMap (`/Users/jn/code/godview-prototype/src/pages/FlatMap.tsx:126-130`): rendered directly
  inside the map's relatively-positioned container with **no wrapper div/positioning classes at
  all** — `VenuePanel`/`NodePanel` are mounted bare (`{panel && (panel.type === "venue" ? <VenuePanel .../> : <NodePanel .../>)}`).
  `VenuePanel`/`NodePanel` supply their own container classes internally
  (`/Users/jn/code/godview-prototype/src/components/globe/VenuePanel.tsx:66`,
  `/Users/jn/code/godview-prototype/src/components/globe/NodePanel.tsx:40`:
  `"h-full overflow-auto bg-sidebar/95 border-l border-border p-3"`) — so on `/map` the panel
  fills the full height of the map container's right edge only via its own `border-l` + `h-full`,
  with no explicit width or slide-in wrapper (relies on being a flex/absolute child — needs
  visual verification, but there is no dedicated positioning wrapper the way Globe.tsx has one).
- Globe (`/Users/jn/code/godview-prototype/src/pages/Globe.tsx:135-147`): explicit responsive
  wrapper —
  ```tsx
  <div data-testid="venue-panel-wrap"
    className="fixed inset-x-0 bottom-0 z-50 h-[70vh] overflow-hidden rounded-t-xl border-t border-border
               lg:absolute lg:left-auto lg:top-0 lg:right-0 lg:bottom-0 lg:z-10 lg:h-auto lg:w-[380px] lg:rounded-none lg:border-t-0">
  ```
  — mobile: fixed bottom sheet (70vh); desktop (`lg:`): absolute right-docked panel, fixed
  `380px` width, full height. A `bg-black/50` scrim overlay backs it on mobile
  (`Globe.tsx:137`).

**No existing collapse/toggle state anywhere** for either the rail or the right panel on
desktop — confirmed via `grep -n "collaps\|toggle" VenueRail.tsx/VenuePanel.tsx/NodePanel.tsx`
(only match is the `railOpen` mobile-sheet boolean in `Globe.tsx:31`, and an unrelated `open`
row-expand toggle inside `VenuePanel.tsx:77-80` for ad-run detail rows). To add a collapse
toggle: FlatMap.tsx's left rail is a plain grid column (`grid-cols-[280px_...]`) so a collapse
would need to change the grid template columns conditionally (e.g. `[0px_1fr]` or
`[48px_1fr]` for a rail-icon-only state) plus a toggle button; Globe.tsx's rail is the same
pattern. The right panel in FlatMap.tsx has no wrapper to hang a width-transition off of yet —
would need one added, mirroring Globe.tsx's `venue-panel-wrap` div, before a collapse/resize
affordance could be layered on.

---

## 6. Zoom Controls

**Mapbox (`/map`):** No `NavigationControl` and no `map.addControl` call anywhere in the repo
(`grep -rn "addControl|NavigationControl|scrollZoom|dragRotate" src` returns zero matches).
`createMap` — `/Users/jn/code/godview-prototype/src/components/flatmap/mapboxImpl.ts:9-18`:
```ts
export function createMap(opts: { container: HTMLElement; token: string; style: object }): mapboxgl.Map {
  mapboxgl.accessToken = opts.token;
  return new mapboxgl.Map({
    container: opts.container,
    style: opts.style as mapboxgl.StyleSpecification,
    center: [0, 20],
    zoom: 1.4,
    attributionControl: true,
  });
}
```
No interaction handlers are overridden, so all of Mapbox's defaults apply (`scrollZoom`,
`dragPan`, `dragRotate`, `doubleClickZoom`, `touchZoomRotate`, `boxZoom`, `keyboard` all enabled
by default) — but there is **no on-screen +/- UI**; zoom is scroll/pinch/keyboard only. Adding a
`+/-` control would mean either instantiating `mapboxgl.NavigationControl` via `map.addControl(...)`
(inside the `map.on("load", ...)` block, `FlatMapCanvas.tsx:89-114`) or building custom buttons
that call `map.zoomIn()`/`map.zoomOut()`.

**Globe (mini-globe + `/globe` page):** `GlobeCanvas` exposes no zoom/altitude prop or ref API to
the parent — the only zoom-adjacent surface is `focus: Focus | null` (a one-shot fly-to lat/lng,
consumed at `/Users/jn/code/godview-prototype/src/components/globe/GlobeCanvas.tsx:478-479`:
`globe.pointOfView({ lat: focus.lat, lng: focus.lng, altitude: CLUSTER_ALTITUDE * 0.6 }, 1200)`)
and `onPovChange` (reports current `{lat,lng,altitude}` out, doesn't accept it in). The
underlying `globe.gl` instance's `.controls()` (three.js `OrbitControls`) and `.pointOfView()`
API are fully encapsulated inside the effect closure (`GlobeCanvas.tsx:225-228`) and not exposed
via props/ref — driving +/- buttons against the globe (main `/globe` page or the mini corner
globe) would require adding a new prop (e.g. `zoomDelta` or an imperative ref/`forwardRef`) since
none exists today.

---

## 7. Tailwind / Design Tokens

Tailwind confirmed in use — `/Users/jn/code/godview-prototype/tailwind.config.ts`:
```ts
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
Key tokens for new UI (legend/toggles/collapse handles): panel/border color `border` (`#212734`)
+ `borderSoft` (`#1a2029`); surfaces `bg` (`#0a0d12`), `elev`/`elev2` (`#12161d`/`#171c25`),
`sidebar` (`#0d1016`); text `text`/`dim`/`faint` (`#e6e9ee`/`#8b93a3`/`#5b6472`); single accent
`accent` (`#45c4ff`, also the first `ORG_PALETTE` hue — reused across orgs and UI accents, so a
new UI element using `accent` could visually collide with an org's arc/halo color); status colors
`ok`/`warn`/`crit`/`off` mirror `TONE_HEX` in `globeSelectors.ts:10-12` exactly (`#34d399`/
`#f5b942`/`#f2545b`/`#5b6472`) — these are the same hex values already implicated in the
teal-square finding (§1). `darkMode: "class"` but no light-mode tokens are defined anywhere — this
app is dark-theme-only today.

**Icon library for collapse chevrons / +/- buttons:** `lucide-react ^1.23.0` is already a
declared dependency in `/Users/jn/code/godview-prototype/package.json` but is currently unused
anywhere in `src/` (confirmed via repo-wide grep) — free to adopt for new chevron/+/- iconography
without adding a new dependency. Existing chevron-like affordances in the codebase today are
plain text glyphs, e.g. `▾`/`▸` in `VenuePanel.tsx:80` and `✕` close buttons in
`VenuePanel.tsx:68`/`NodePanel.tsx:42` — so introducing `lucide-react` icons would be a deliberate
upgrade from the current plain-glyph convention, not a continuation of an existing pattern.
