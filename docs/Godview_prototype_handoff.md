# Godview Prototype Handoff

Yes — that is the correct map hierarchy.

You are describing a **semantic zoom map**, not a normal map with fixed pins.

The map should change what the dots mean based on zoom level.

## MRAS map hierarchy

```text
World / country view
→ region / state view
→ city view
→ building / venue view
→ system view
→ device view
```

At each level, the dot represents a different object.

| Zoom level | Dot represents | Example |
|---|---|---|
| Country / continent | Region aggregate | United States: 812 systems, 19 active ad runs |
| State / metro | City / market | Dallas: 42 systems, 7 live compositions |
| City | Building / venue | NorthPark Center, DFW Airport, Lexus showroom |
| Building | MRAS system / install zone | Entrance wall, food court wall, showroom bay |
| System | Device cluster | Camera group + screen group |
| Deep system view | Individual devices | Camera 1, Display 1, Display 2, Display 3, Display 4 |

So yes:

```text
One city dot can represent many systems.
Zoom into a building → dots become systems.
Zoom into one system → dots become cameras/displays.
```

That is exactly the right model for “thousands of installed systems.”

## Important product decision

The map is not only geography. It is an **operations topology map**.

At high zoom, it is geographic:

```text
US → Texas → Dallas → Building
```

At low/deep zoom, it becomes operational:

```text
Building → System → Camera → Display → AdRun
```

This means the map needs to support two kinds of relationships:

1. **Physical containment**

   ```text
   Country → State → City → Building → System → Camera/Display
   ```

2. **Live activity**

   ```text
   Detection → Composition → Playback → Attention
   ```

That is why the data model needs both location hierarchy and AdRun/composition/playback objects.

## Recommended object hierarchy

Use this:

```text
Organization
└── Region / Market
    └── Location
        └── Building / Venue
            └── Zone
                └── MRAS System
                    ├── Camera(s)
                    ├── Display(s)
                    └── ScreenGroup(s)
```

You may not need every label in the UI immediately, but the model should support it.

For v1, this can be simplified as:

```text
Organization
└── Location
    └── System
        ├── Camera
        ├── Display
        └── ScreenGroup
```

But I would still allow optional fields for:

```text
market
building
floor
zone
lat
lng
```

## What the map dot should show

At every zoom level, a dot should summarize the children underneath it.

Example city dot:

```text
Dallas
42 systems
7 active ads
2 failures
96% healthy
Avg compose: 2.1s
Watch rate: 71%
```

Example building dot:

```text
NorthPark Center
8 systems
3 currently playing
1 camera warning
Last ad: 14 sec ago
```

Example system dot:

```text
Entrance Wall A
1 camera
4 displays
2 active AdRuns
TTS OK
Overlay OK
ffmpeg OK
```

Example display dot:

```text
Display 3
Playing: Lexus Welcome Ad
Person: Jason
Watched: unknown
Clip ends in 8s
```

## Map modes

You probably need map modes, not just one map.

### 1. Health mode

Shows whether systems are working.

```text
green = healthy
yellow = warning
red = failing
gray = offline
```

### 2. Live AdRun mode

Shows live ad activity.

```text
pulse = ad composing
solid = ad playing
ring = watched
red ring = failed
```

### 3. Volume mode

Shows activity density.

```text
bigger dot = more detections/playbacks
brighter dot = more live activity
```

### 4. Error mode

Shows failures.

```text
TTS failures
overlay failures
camera offline
display disconnected
Qdrant errors
ffmpeg timeouts
```

### 5. Campaign mode

Shows where a selected campaign/ad is running.

```text
Lexus campaign active in 14 locations
7 locations played in last hour
2 failed render attempts
```

## How this connects to the single AdRun view

The map should not replace the single AdRun detail. It should route into it.

Flow:

```text
Map dot: Dallas
→ zoom/click
Map dot: NorthPark Center
→ click
System: Entrance Wall A
→ active AdRun
→ Single AdRun View
```

Or:

```text
Map dot pulses red
→ click
Failure cluster
→ failed AdRun
→ Composition Inspector
→ Overlay render failed
```

That gives you both macro and micro:

```text
Map = where things are happening
AdRun view = exactly what happened
```

## Data fields this forces

You now need these fields sooner rather than later:

```text
locations
- id
- organization_id
- name
- type
- country
- region
- state
- city
- address
- lat
- lng
- timezone
- status

systems
- id
- location_id
- name
- zone
- floor
- lat nullable
- lng nullable
- status

cameras
- id
- system_id
- location_id
- name
- status
- last_seen_at

displays
- id
- system_id
- location_id
- screen_group_id
- name
- status
- last_seen_at

ad_runs
- id
- organization_id
- location_id
- system_id
- camera_id
- screen_group_id
- identity_id nullable
- status
- started_at
- completed_at

playbacks
- id
- ad_run_id
- location_id
- system_id
- display_id
- status
- started_at
- ended_at

composition_runs
- id
- ad_run_id
- status
- started_at
- completed_at
- total_ms
```

The current docs already call out that `location_id` does not exist yet and is foundational for multi-location God View. Your map concept confirms that `location_id`, `system_id`, `camera_id`, `display_id`, and `screen_group_id` all need to be real early.

## Revised map answer

The map’s primary dot should represent the **largest meaningful aggregate at the current zoom level**.

So not always Location. Not always AdRun. Not always Display.

Use semantic zoom:

```text
Zoomed out: market/city aggregate
Medium: building/location
Zoomed in: MRAS system
Deep zoom: cameras/displays
Selected state: active AdRuns attached to that node
```

This lets one dot cover an entire city, then gracefully explode into buildings, systems, displays, cameras, and live ad activity as you zoom in.

That is the right architecture for the map.

We are going to follow the current data model for cards, maps, etc in the prototype UX/UI for the Godview SaaS.
