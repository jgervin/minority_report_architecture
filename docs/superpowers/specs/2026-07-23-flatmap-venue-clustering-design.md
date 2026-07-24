# Flat Map venue clustering (#37) — design

**Date:** 2026-07-23 · **Repo:** `godview-prototype` · **Issue:** #37

## Problem

On `/map` at world zoom, geographically co-located venues render their white-square
markers directly on top of each other (visual collision). In the demo data the tight
overlaps are all **same-city pairs** — Dubai (Mall of the Emirates + The Dubai Mall),
London (Battersea + Westfield London), New York (Hudson Yards + Fifth Avenue) — at
0.03–0.08° separation. `clusterVenues()` already exists in `src/data/globeSelectors.ts`
and the corner mini-globe already renders these as single per-city clusters, but the flat
map plots every venue at its exact coordinate: `FlatMapCanvas` receives the raw `venues`
prop and `syncVenueMarkers` iterates it 1:1 (`src/components/flatmap/FlatMapCanvas.tsx`).

## Chosen approach

City-cluster the map's venue markers by **reusing the existing, tested `clusterVenues()`
semantic** (group by `city|country`), gated on Mapbox zoom. Consistent with the corner
globe; minimal new surface; the demo's collisions are all same-city so city-grouping
covers them.

Rejected alternatives:
- **Spread-offset (fan out)** — distorts true geographic position; diverges from the globe's model.
- **Pixel-proximity clustering** — more code, E2E-only projection math, and unnecessary because
  the demo's collisions are same-city (a general different-city merge is not needed; see Out of scope).

## Design

### 1. Pure selector — `clusterMapVenues(venues, mapZoom)` (`src/data/mapSelectors.ts`)

```
world tier  (mapTier(mapZoom) === "world")  → clusterVenues(venues, Infinity)  // force city-grouping
city tier +                                  → clusterVenues(venues, 0)         // all individual venues
```

- Returns `GlobeDot[]` (`VenueDot | ClusterDot`), reusing the `globeSelectors` types.
- `clusterVenues(v, Infinity)`: altitude ≥ threshold → city-grouped; single-venue cities stay `VenueDot`.
- `clusterVenues(v, 0)`: altitude < threshold → every plotted venue is an individual `VenueDot`.
- Pure (no mapbox/react) → **unit-testable in jsdom**. This is the part TDD covers.

### 2. Rendering (`FlatMapCanvas.syncVenueMarkers`)

- Iterate `clusterMapVenues(venuesRef.current, map.getZoom())`, computed **live from the map's
  zoom** — mirrors the existing live `showLabel = mapTier(map.getZoom()) === "city"` gating, which
  avoids React-state prop lag on the imperative layer.
- `VenueDot` → `MapNodeMarker kind="venue"` exactly as today: label tier-gated (#26), click →
  `onVenueClick(id)`, single/double-click disambiguation unchanged.
- `ClusterDot` → `MapNodeMarker kind="venue"` with `count={dot.venues.length}`, `ring`, `status`
  from `dot.rollup.worst_status`, `label={dot.city}`, and **`showLabel` forced `true`** (the cluster
  is labeled even at world tier — chosen extra); click → `onClusterClick(dot.lat, dot.lng)`.
- Marker keys: venue `dot:<location_id>`, cluster `dot:<GlobeDot.id>` (e.g. `dot:cluster:Dubai|AE`).
  The existing seen-set reconciliation + deferred `root.unmount()` hygiene is unchanged — cluster↔venue
  transitions are just markers appearing/disappearing by key across a zoom tier crossing.
- Re-sync already fires on zoom tier crossings (the label-gating handler); the cluster/de-cluster
  transition rides that same path.

### 3. Interaction — `onClusterClick(lat, lng)` prop

- New prop on `FlatMapCanvas`. `FlatMap` wires it to `flyTo(lat, lng, STAGE_ZOOM.city, !!panel)` —
  fly to city zoom at the cluster centroid, which de-clusters into individual venues. No selection,
  no panel; mirrors the corner-globe `onCornerDotClick` cluster branch.

### 4. Labels

- Individual venue markers unchanged (label hidden at world tier per #26).
- Cluster markers show the **city name label + count badge** even at world tier (chosen extra).

### 5. Pulses — no change needed (verified)

Far-pulses are a **geo-anchored GeoJSON layer** (`src/data/mapPulseGeometry.ts` `pulsePointFeature`
→ a Point at the venue's own `[lng, lat]`), independent of marker DOM. A clustered venue's pulse
renders at its true coordinate — within a few pixels of the cluster centroid at world zoom (members
are 0.03–0.08° apart), and the growing/fading ring envelops the cluster marker. **No remapping.**
This is a conscious decision: remapping would collapse all members' pulses onto one centroid point
and lose per-venue fidelity; geo-anchoring is both simpler and more faithful.

## Testing

**Unit (jsdom, pure) — `clusterMapVenues` in `mapSelectors.test.ts`:**
- world zoom → same-city venues grouped into one `ClusterDot` with correct `venues.length` (count)
  and mean-of-members centroid; single-venue cities stay `VenueDot`.
- city / building zoom → all `VenueDot` (no clustering).
- a venue with no `city` stays its own dot even at world zoom (inherited `clusterVenues` rule).
- empty input → empty output.

**Live Playwright E2E (real Mapbox — E2E-only, jsdom can't run mapbox):**
- world zoom → Dubai / London / New York each render as ONE marker with a count badge (2) + city
  label; total venue-marker count is 3 fewer than the raw 17.
- zoom to city tier → the three clusters split into individual venue markers.
- click a cluster → the map flies in to city zoom and it de-clusters.

## Out of scope

- Different-city geographic overlap (New York ↔ King of Prussia, ~1.4° apart) — mild, separates on
  a slight zoom-in; not clustered (city-grouping only).
- Cluster detail panel / cluster selection.

## Files touched

- `src/data/mapSelectors.ts` — add `clusterMapVenues` (+ `mapSelectors.test.ts` unit tests).
- `src/components/flatmap/FlatMapCanvas.tsx` — `syncVenueMarkers` cluster rendering + `onClusterClick` prop.
- `src/pages/FlatMap.tsx` — pass `onClusterClick` wired to `flyTo(..., STAGE_ZOOM.city)`.
