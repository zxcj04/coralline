# Spec — `burn` segment (token burn-rate → range-to-empty)

- **Date:** 2026-06-18
- **Status:** Design approved, pending spec review
- **Author:** brainstormed with Claude
- **Relates:** reuses the same "persist parsed state across renders" idea explored in
  the iTerm2 float spec, but with its own minimal append-only sample file.

## Goal

Show, in a compact opt-in statusline segment, **how long until the 5h rate limit hits
100% at your _recent_ burn rate** — a fuel-gauge "range to empty", e.g. `⛽ ⇢1h58m`.

The car analogy that seeded this: the dashboard already shows the fuel level and a
clock; what it lacks is *instantaneous consumption → remaining range*. That remaining
range is the one number this feature adds.

## Background: what the live spike established (load-bearing)

This design followed a live spike against real Claude Code data. The findings are
load-bearing and are recorded here because they killed earlier approaches:

1. **A stateless "average since window start" mode adds zero information.** If you
   compute `rate = used% / elapsed` and project `ETA = elapsed × (100−used%)/used%`,
   every input (`used%`, and `elapsed = 5h − time_to_reset`) is *already on screen* in
   the existing `limit5h` segment. The projection is pure arithmetic on two visible
   numbers — it tells you nothing new. **Dropped.** The only quantity not already
   visible is the **recent slope**, which can diverge sharply from the average (idle
   for hours, then burst). So the feature is *exclusively* the recent-rate path.

2. **The rate-limit `used_percentage` only exists in Claude Code's statusline input.**
   It is fed to `statusline.sh` on each render; it is not persisted anywhere. To
   measure a slope we must record `(timestamp, used%)` samples ourselves. The sampler
   therefore has to live *inside* `statusline.sh` — the only process that sees the
   value.

3. **`used_percentage` is effectively stepwise in ~1% increments.** It is *typed* as a
   float, but observed values were `6` then `8` with nothing between, and the
   `7.000000000000001` we saw is IEEE float noise, not fine-grained signal. So the
   estimator must treat the data as **1%-quantized** and measure *time between integer
   crossings*, not a fine-grained delta over a fixed window.

4. **The value is account-global**, identical across concurrent sessions. This makes
   the sample file *safe to write from multiple sessions at once* — they all record the
   same truth, just at higher resolution. (Contrast: a per-session transcript
   token-throughput approach would be blind to your other windows and would measure the
   wrong quantity — token throughput, not quota %.)

5. **A neighbouring tool (`TokenBar`, same author) exposes no reusable data file.** Its
   only persisted state is a UI-preferences plist; its `tok/min` figure is computed
   live in memory from Claude Code's own transcript JSONL. coralline must therefore not
   depend on it, and the transcript path is the wrong source anyway (see #4).

## Non-goals

- A 7d burn segment. Over a 7-day window a 10-minute recent slope is essentially
  unmeasurable at 1% granularity (a single 1% crossing can take hours), and the ETA
  would be enormous and noisy. The feature is **5h only**. (A future spec could revisit
  if 7d ever reports finer granularity.)
- Replacing or restyling the existing `limit5h` / `limit7d` segments. `burn` is a new,
  independent, opt-in segment.
- A words-based verdict ("you will run out"). The headline is the ETA number; the
  only verdict is encoded subtly in colour (see Colouring).
- Multi-session correctness beyond "all sessions append the same global truth"
  (interleaved timestamps are re-sorted by the reader).

## What it adds vs. the existing `limit5h`

`limit5h` shows `used% + reset countdown`, whose implied slope is the **whole-window
average**. `burn` shows the **recent-window slope** projected to 100% — a number that
is not visible anywhere today and that is precisely what warns you when you have
*started* burning hard after a quiet stretch.

## Architecture

```
┌─ statusline.sh (every render) ─────────────────────────────┐
│  parse JSON → fh_pct (raw float), fh_rst                     │
│  if VL_BURN=1:                                               │
│     printf '%s\t%s\t%s\n' NOW fh_pct fh_rst  >>  burn-5h.tsv │  ← zero-fork append
│                                                             │
│  seg_burn (when 'burn' in VL_SEGMENTS):                     │
│     one awk pass over burn-5h.tsv →                         │
│        • dedup + sort by epoch                              │
│        • detect 1% crossings, classify state               │
│        • compute recent rate + ETA                         │
│        • rewrite file trimmed to last N rows               │
│     render  ⛽ ⇢<ETA>  (or …/— for warming/idle)            │
└─────────────────────────────────────────────────────────────┘
                          │
              ~/.claude/coralline/burn-5h.tsv
              (append-only TSV; absent unless VL_BURN=1)
```

Three pieces:

### 1. Sampler — inside `statusline.sh`

- Gated by **`VL_BURN=0`** (default off). When off, **nothing is written** — coralline
  keeps its current 100%-stateless, zero-side-effect default.
- When on, append one line per render to `~/.claude/coralline/burn-5h.tsv`:
  `epoch <TAB> fh_pct <TAB> resets_at`.
- **Zero forks**: `printf … >> file` is a bash builtin plus a redirection — no
  subprocess — honouring coralline's fork-frugal ethos.
- Guarded by `[ -n "$fh_pct" ]`, so on plans that don't report a 5h limit the sampler
  is a no-op and the segment renders nothing.
- This is exactly the prototype validated during the spike.

### 2. `seg_burn` — the reader/estimator

A single `awk` pass (one fork — the only one the feature adds) that:

- Reads `burn-5h.tsv`, drops empty-`%` rows, dedups by epoch, sorts ascending.
- Detects **1% crossings**: a sample whose integer `%` exceeds the previous integer
  `%`; the crossing's timestamp is the first sample at the new level (an exact 1%
  boundary).
- **Window-reset detection**: if `%` ever *decreases*, discard all samples at/ before
  the drop and restart (the 5h window rolled over).
- Classifies state (state machine below) and computes the rate/ETA.
- **Trims in place**: writes back only the last `N` rows (default 1500 ≈ ~20 min at the
  observed ~1–2 rows/sec), bounding file size without a separate cron/fork. Idle
  renders keep appending identical samples; the trim caps growth.

### 3. Config / installer integration

- `configure.sh`: a toggle to enable `VL_BURN`, plus a reminder that `burn` must also
  be added to `VL_SEGMENTS` to appear.
- No new files to install beyond the segment logic already in `statusline.sh`.

## Estimator — the state machine

`CORALLINE_BURN_WINDOW` (default **600s** = the "per 10 minutes" the idea started from)
is the lookback. Evaluate these conditions **top-to-bottom; first match wins** (so the
`0-crossings` overlap between `idle` and `warming` is resolved by history):

| State | Condition (first match wins) | Render |
|---|---|---|
| `reset` | `%` decreased anywhere in the file | discard history → re-evaluate as `warming` |
| `active` | **≥2** crossings inside the lookback window | `⛽ ⇢<ETA>` (coloured) |
| `idle` | **≥1** crossing exists in history, but **0** inside the lookback window (you were burning, then stopped) | `⛽ ⇢—` (dim) |
| `warming` | otherwise (cold start / just reset — not yet two crossings to measure) | `⛽ ⇢…` (dim) |

**Active computation** (quantization-robust — both endpoints are exact 1% crossings):

```
rate = (pct_last_crossing − pct_first_crossing) / (t_last_crossing − t_first_crossing)
ETA  = (100 − pct_now) / rate            # seconds, rendered as a countdown
```

Rules:

- **Never freeze a stale ETA.** When state leaves `active` (idle/reset), the ETA blanks
  to `—`; it must not keep displaying the last computed value.
- A single crossing is **not** enough — it stays `warming` until the second crossing
  gives a measurable interval. (Matches the spike: the value sat at 7% for ~6 minutes
  with no second crossing.)
- A slow burn (<1% per lookback) is indistinguishable from idle until a crossing lands,
  and is honestly shown as `—` rather than a fabricated number.
- Guard `t_last − t_first > 0` and `rate > 0`; otherwise treat as `idle`.

### Known resolution limit

At 1% granularity, light use yields sparse crossings, so `active` ETA is coarse and
lags. This is acceptable because the feature's value is greatest under *heavy* burn —
where crossings are dense and the estimate is both responsive and the warning matters
most.

## Display & colouring

- **Headline = ETA** (range to empty): `⛽ ⇢1h58m`.
- `VL_BURN_SHOWRATE=1` additionally renders the recent rate: `⛽ 4.8%/10m ⇢1h58m`.
- Glyph configurable (`VL_BURN_GLYPH`, default a fuel/gauge mark); Nerd-Font and
  `VL_ASCII` fallbacks follow the existing segment conventions.

**Colouring — "ratio" rule (chosen over an absolute-ETA threshold).** The existing
gauges colour purely by fill % (50/75 thresholds) and know nothing about rate or
reset. An absolute-ETA threshold for `burn` would "cry wolf" (ETA 40m flagged red even
when reset is 5m away). Instead colour by **`time_to_reset ÷ ETA`**, keeping the
codebase's threshold idiom while encoding the only thing that matters — *will you hit
the wall before the window resets*:

| `time_to_reset / ETA` | meaning | colour var |
|---|---|---|
| `< 0.8` | reset well before you run dry — safe | `VL_FG_OK` |
| `0.8 – 1.0` | closing in, not yet crossing | `VL_FG_WARN` |
| `≥ 1.0` | ETA ≤ time-to-reset → you hit 100% before reset | `VL_FG_HOT` |

`warming` / `idle` render in `VL_FG_DIM`.

**Theme portability (free).** Every theme overrides the *semantic* colour vars
(`VL_FG_OK/WARN/HOT/DIM`), not literal codes. As long as `burn` colours via those vars
and never hardcodes a colour, all 8 themes' palettes apply automatically. The segment
background defaults to **`VL_BG_BURN="${VL_BG_5H}"`** so it inherits the 5h family's
per-theme background without editing any theme file.

## Data contracts

- **`~/.claude/coralline/burn-5h.tsv`** — append-only TSV, one row per render:
  `epoch <TAB> used_percentage(raw) <TAB> resets_at`. Absent entirely unless
  `VL_BURN=1`. Reader dedups by epoch, sorts ascending, and trims to the last `N` rows.
  A decreasing `%` marks a window reset.

## Config keys

| Key | Default | Meaning |
|---|---|---|
| `VL_BURN` | `0` | `1` = sampler writes `burn-5h.tsv` and `seg_burn` is enabled |
| `CORALLINE_BURN_WINDOW` | `600` | recent-slope lookback, seconds |
| `VL_BURN_SHOWRATE` | `0` | also render the `%/10m` rate beside the ETA |
| `VL_BURN_GLYPH` | (fuel/gauge mark) | segment glyph (with `VL_ASCII` fallback) |
| `VL_BG_BURN` | `${VL_BG_5H}` | segment background; inherits the 5h family colour |
| `VL_BURN_TRIM` | `1500` | max rows kept in `burn-5h.tsv` |

(`burn` must also be added to `VL_SEGMENTS` to appear.)

## Edge cases & error handling

- **5h not reported** (`fh_pct` empty): sampler no-ops, segment renders nothing.
- **Window reset** (`%` drops): discard pre-drop samples, return to `warming`.
- **Clock skew / `NOW` going backwards**: guard `Δt > 0`; skip the bad pair.
- **Concurrent sessions**: harmless — all append the same global `%`; reader re-sorts.
- **Idle growth**: bounded by the in-place trim to `VL_BURN_TRIM` rows.
- **First enable**: `warming` until two crossings accumulate; no fabricated ETA.

## Testing

`seg_burn` is a pure function of the sample file. Tests (in the existing `test/`) feed
synthetic `burn-5h.tsv` fixtures and assert the rendered output:

- steady burn → an `active` ETA within tolerance, correct colour band;
- burst-after-idle → recent slope (and shorter ETA) distinct from the whole-file
  average;
- idle (last crossing older than the window) → `⇢—`, dim;
- warming (one or zero crossings) → `⇢…`, dim;
- window reset (`%` drops mid-file) → history discarded, back to `warming`;
- `time_to_reset/ETA` boundaries (0.8, 1.0) → OK/WARN/HOT selection;
- `VL_BURN=0` → no file written, segment absent.

## Implementation note (prototype cleanup)

During the spike an **un-gated** sampler line was injected into the live
`~/.claude/coralline/statusline.sh` (backed up as `statusline.sh.bak-burnrate-prototype`).
The real implementation replaces it with the `VL_BURN`-gated version; the live file must
be restored from that backup (or re-installed) so no unguarded write remains.
