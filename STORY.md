# The story

The narrative plan for *Real-Time GNSS Positioning with JuliaGNSS: From SDR Signals to
Your Location* — JuliaCon 2026, 12 minutes.
Abstract: <https://pretalx.com/juliacon-2026/talk/Z38XCK/>

This file is the script-level companion to the code. The slides implement it; this
explains *why* each slide exists and what it must leave the audience wanting.

## The frame: three clocks

The talk is a race between what Julia can compute and what physics will deliver. Three
clocks set the pace, and all three are introduced in the first ninety seconds:

1. **The satellite's clock — 50 bit/s.** One subframe is 300 bits, six seconds. Nothing
   can make it faster. It is the slowest data link anyone in the room uses every day,
   and everything waits on it.
2. **The receiver's clock — 10 MSPS.** Samples arrive whether or not we are ready. Fall
   behind once and it is over. This is where the abstract's "rivals C/C++" claim
   actually lives — not as a benchmark table, but as the thing that must not fail on
   stage.
3. **The talk's clock — 12 minutes.**

There is no riddle and nothing for the audience to guess. The tension is on screen at
all times, and everyone can read the progress bar.

The reveal at the end is not *where* but **from nothing**: the receiver was handed a
stream of `Int16` samples and a sample rate. No time, no place, no almanac. Ninety
seconds later it knows where it is to a few metres and *what time it is to nanoseconds*.

### Why the receiver starts late

The receiver (tracking → decoding → PVT) does **not** run from startup. It starts the
moment the decoding slide is first shown, and the audience watches the ephemeris fill in
from zero and the fix converge in real time.

This is the single most important staging decision in the talk, because it answers the
skepticism that shadows every live demo: it cannot be canned. It also self-paces the
demo — the decode genuinely takes ~30 s, which is roughly the length of the decoding
slide.

The cost is that we are now hostage to 50 bit/s. If the talk runs ahead of the
satellites, we stand and wait — so the progress bar has to make waiting *legible*, and
"this is the slowest data link you use every day" is the line to say while it fills.
`--eager-receiver` pre-warms the receiver if a rehearsal or the room's timing goes badly.

### Measured timings — verify these on the presentation machine

Against the real ION LimeSDR recording (50 s prefix, 420 kHz IF), measured from the
moment the decoding slide is entered, on a 24-core container:

| Event | t |
|---|---|
| first satellite tracked | 1.2 s |
| first time-of-week decoded | 11.6 s |
| first ephemeris value on screen | 17.7 s |
| ephemeris validated → **first PVT fix** | 41.9 s |

The fix lands at 52.177171° N, 4.490035° E with 10 satellites.

So the decoding and PVT slides together have to cover roughly 45 s. That fits the budget
below, but it is worth timing on the presentation machine — and if it runs long, the
receiver can be started a slide earlier (Tracking) for ~75 s of head start.

**The receiver is not the bottleneck.** It processes the stream at about **1.9× real
time** under full app load (measured with `--no-realtime`: 49.9 s of signal in 26.1 s of
wall clock, reaching a fix 15.9 s after the slide opens). The talk's "keeps up with the
antenna" claim holds with room to spare.

What *was* slow was the file replay's own pacing — see the pacing note in
`_spawn_file_reader!`. Two fixes took the paced reader from 0.63× to ~0.87× under load
(0.99× in isolation, with nothing consuming it). The residue is scheduler contention on a
busy thread pool, not DSP throughput, and a live SDR does not have the problem at all
because the hardware clocks the samples. **Expect the live demo to converge faster than
the file rehearsal, not slower.**

## Slide beats

Every slide ends on the problem the next one solves. That is the difference between a
tour and a story: each stage exists because the previous stage left something broken.

| # | Slide | Beat | Leaves you with |
|---|-------|------|-----------------|
| 0 | Title | The three clocks; the receiver knows nothing | — |
| 1 | Spectrum | Flat noise. ~10 satellites are in this picture, ~20 dB *below* the floor | How do you find what you cannot see? |
| 2 | The signal I have to chase | Nav bits × chips, and a replica that must be aligned | Which satellite? What code phase? What Doppler? |
| 3 | Acquisition | The 2D search, live, and the FFT trick that makes it possible | Found them — but they move at 4 km/s and the peak slides away |
| 4 | Tracking | Early/Prompt/Late holds the lock; delay now measurable to nanoseconds | Delay relative to *what*? What time is it? |
| 5 | **Decoding** | **The receiver starts here.** Values pop in one 30-bit word at a time | 4 satellites ready — now we can solve |
| 6 | PVT | Four unknowns: x, y, z **and the clock**. The fix lands, live | From nothing, on stage |
| 7 | Why Julia | Composability and performance, argued from this repo | — |
| 8 | Ecosystem | v1.0 milestone, next steps, how to join | — |

### Slide 2 in detail

Nav bits (20 ms) and chips (1 µs) are four orders of magnitude apart and cannot share a
time axis, so the zoom between them is drawn explicitly rather than faked:

1. the navigation message at 50 bit/s, one bit spanning 20 whole code repetitions;
2. the 1023-chip PRN code, 1.023 Mchip/s, repeating every 1 ms;
3. what actually arrives — code × nav bit, on a carrier of unknown Doppler — with a
   local replica *sliding* underneath it (the chase, made literal);
4. the two unknowns, searched together, with the hypothesis count.

The numbers in (4) are computed at render time from the real `plan_acquire`
configuration, not hardcoded, so the claim is truthful rather than merely plausible.

This slide deliberately has **no correlation triangle**. The triangle answers a question
nobody has asked yet at this point; it belongs on the tracking slide, where it is a real
measurement rather than a diagram.

The hinge into acquisition is the good part: brute force is order 10^12 operations, so
**nobody does it by brute force** — which is exactly why `Acquisition.jl` uses an
FFT-based parallel code-phase search and the next slide finishes in milliseconds.

The nav-bit layer here also plants the 50 bit/s message four minutes before the decoding
slide needs it, so it arrives as an old friend rather than a new concept.

### Slide 5 in detail

`GNSSDecoder.GPSL1CAData` is a `@kwdef` struct in which every field is
`Union{Nothing,T}` defaulting to `nothing`, rebuilt once per parity-checked 30-bit word.
So `decoder.raw_data` is already an incremental accumulator: fields flip `nothing →
value` roughly every 0.6 s and fill over ~18 s.

Read **`raw_data`, not `data`** — `data` is all-or-nothing and stays blank until
subframes 1–3 all validate.

Two fields turned out to be unusable as written and are worth remembering:
`num_bits_after_valid_syncro_sequence` stays `nothing` long after words are demonstrably
decoding (driving a progress bar from it showed "searching for the preamble… 0/300"
while values were landing), so progress is measured by how many orbit numbers have
actually arrived; and `TOW` is cleared again whenever the next one isn't exactly
previous+1, so it flickers and has to be latched.

Four panels: a decode-progress bar counting orbit numbers received; one hero PRN's 26 ephemeris slots
grouped by subframe, dim until their word arrives; one plain-language line on what the
numbers *mean* (this is the satellite's orbit — with it we know exactly where it was
when it sent this bit); and a per-PRN readiness strip carrying the suspense counter,
**"N of M ready — 4 needed for a fix"**, which is what pays off into PVT.

### Slide 7 in detail

Do not reach for a benchmark table. The stronger argument is sitting in this repo:

- `src/triangle_correlator.jl` is a **user-defined** `AbstractEarlyPromptLateCorrelator`
  that `Tracking.jl` accepts without ever having heard of it;
- `receive`'s `extract` hook let us reach into the receiver's internals with a closure
  and get a typed channel back — no plugin API, no fork;
- one stream at 10 MSPS fanned out to four consumers, no C in the hot loop;
- 3 s to first frame, because the compile workload is baked into the precompile cache.

The presentation *is* the composability proof.

## Time budget

Maps onto the abstract's promised 6 / 4 / 2 split.

| Time | Content |
|------|---------|
| 0:00–1:15 | Hook: the three clocks, and why an open receiver matters |
| 1:15–2:00 | Spectrum — it is not there |
| 2:00–3:30 | The signal I have to chase (the conceptual core; do not rush it) |
| 3:30–5:00 | Acquisition — live |
| 5:00–6:15 | Tracking |
| 6:15–7:15 | Decoding — **receiver starts**; ephemeris fills live (~18 s to first value) |
| 7:15–8:30 | PVT — the fix lands (~42 s after the decoding slide opened) |
| 8:30–10:30 | Why Julia |
| 10:30–12:00 | Ecosystem, next steps, close |

## Devices

- **Persistent pipeline header.** The intro's `Samples → Acquisition → Tracking →
  Decoding → PVT` diagram rides along on every slide, current stage highlighted,
  completed stages turning green *when they actually succeed live*. The diagram becomes
  a progress bar for the story and keeps the audience oriented.
- **Questions, not summaries.** Each slide's closing caption poses the next slide's
  question rather than restating what was just shown.
