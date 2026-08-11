"""
    GNSSPresentation

Interactive JuliaCon 2026 terminal presentation driving a live software-defined GNSS
receiver (JuliaGNSS) from one continuous stream of SDR samples, built on Tachikoma.jl.

One persistent source is `tee`'d into four always-drained branches (receiver,
periodogram, acquisition, tracking); slides only change which branch's latest result is
shown. Run with `run_presentation(...)`.
"""
module GNSSPresentation

using Tachikoma
@tachikoma_app

using GNSSReceiver: receive, get_gui_data_channel
using GNSSDecoder: is_sat_healthy, is_decoding_completed_for_positioning
using Acquisition: plan_acquire, acquire!, AcquisitionResults, is_detected
using Tracking: NumAnts, TrackState, TrackedSat, track!,
    CPUThreadedDownconvertAndCorrelator, get_sat_states,
    get_last_fully_integrated_correlator, get_accumulators, get_prompt,
    get_early, get_late, dll_disc, get_code_phase, estimate_cn0
using GNSSSignals: GPSL1CA, get_code_frequency, get_code_length, gen_code, AbstractGNSSSignal
# module bindings so the outro slide can report each package's actual version at runtime
import GNSSSignals, Acquisition, Tracking, PositionVelocityTime, SignalChannels, GNSSReceiver,
    GNSSDecoder
using SignalChannels: SignalChannel, consume_channel
using PositionVelocityTime: get_LLA, get_sat_enu, PVTSolution
using UnicodeMaps: worldmap
using Dictionaries: dictionary, Dictionary
using FFTW: ESTIMATE
using PrecompileTools: @compile_workload
import DSP
import UnicodePlots as UP   # qualified: barplot/polarplot names would clash with Tachikoma
using Unitful: Hz, MHz, dBHz, s, ustrip, @u_str
using StaticArrays: SVector

include("colormap.jl")
include("triangle_correlator.jl")
include("source.jl")
include("acq_surface.jl")
include("nav_snapshot.jl")

const NUM_SLIDES = 9            # see slide index constants below
const CN0_DETECT_THRESHOLD = 38.0   # dBHz; a PRN counts as "detected" above this

# ── Model ────────────────────────────────────────────────────────────────────

mutable struct PresentationModel <: Model
    quit::Bool
    slide::Int                       # 0 … NUM_SLIDES-1
    tick::Int
    lk::ReentrantLock
    hub::Union{StreamHub,Nothing}
    tasks::Vector{Task}
    # config
    system::AbstractGNSSSignal
    fs::Any
    interm_freq::Any
    skip_acq::Bool                   # diagnostic: drop the acquisition slide + task
    skip_rx::Bool                    # diagnostic: don't run the receiver (no PVT)
    eager_rx::Bool                   # start the receiver at startup instead of on SLIDE_DECODE
    started::Set{Symbol}             # one-shot registry for lazily started work (under lk)
    # shared results (published wholesale by background tasks; read under lk)
    chunk_count::Int
    periodogram::Any                 # PeriodogramData | nothing
    acq_results::Vector{AcquisitionResults}
    detected::Vector{Int}
    cursor::Int                      # index into `detected`
    selected_prn::Union{Int,Nothing}
    selected_acq::Union{AcquisitionResults,Nothing}
    surface::Any                     # PixelImage | nothing
    acquiring::Bool
    triangle::Any                    # NamedTuple | nothing
    gui::Any                         # GUIData | nothing
    last_fix::Any                    # last GUIData that had a PVT fix (persist position)
    map_lines::Any                   # cached UnicodeMaps render as Vector{Vector{Span}} | nothing
    map_key::Any                     # render key the cached map corresponds to | nothing
    map_want::Any                    # render key the PVT slide requests | nothing
    map_zoom::Int                    # map zoom level (user-controllable on the PVT slide)
    map_dlon::Float64                # map pan offset from the fix, degrees longitude
    map_dlat::Float64                # map pan offset from the fix, degrees latitude
    pg_ymin::Float64                 # periodogram y-axis min [dB] (windowed)
    pg_ymax::Float64                 # periodogram y-axis max [dB] (windowed)
    pg_win::Vector{Tuple{Float64,Float64}}  # sliding window of per-frame (min,max)
    acq_zoom::Bool                   # acquisition surface: true=±chips around peak, false=full code
    eph_seen::Dict{Tuple{Int,Symbol},Int}   # (prn, field) → tick it first appeared (flash timing)
    last_tow::Dict{Int,Int}          # prn → most recent decoded TOW (the decoder's flickers out)
    acq_space::Any                   # NamedTuple of real search-space sizes | nothing
end

function PresentationModel(; system = GPSL1CA(), fs = 10.0e6Hz, interm_freq = 0.0Hz,
    skip_acq = false, skip_rx = false, eager_rx = false)
    PresentationModel(false, 0, 0, ReentrantLock(), nothing, Task[],
        system, fs, interm_freq, skip_acq, skip_rx, eager_rx, Set{Symbol}(),
        0, nothing, AcquisitionResults[], Int[], 1, nothing, nothing, nothing,
        false, nothing, nothing, nothing, nothing, nothing, nothing, 13, 0.0, 0.0,
        Inf, -Inf, Tuple{Float64,Float64}[], false,   # acq_zoom: default to full code-phase view
        Dict{Tuple{Int,Symbol},Int}(), Dict{Int,Int}(), nothing)
end

should_quit(m::PresentationModel) = m.quit

# ── Background processing (started once the hub is up) ────────────────────────
#
# CPU discipline: the source is always drained on every branch (cheap `take!` that just
# keeps the latest raw chunk), but the EXPENSIVE DSP for a slide only runs while THAT
# slide is on screen. Acquisition (a 32-PRN `@batch` search across all cores) and the
# spectrum FFT would otherwise run non-stop on every slide and peg the machine. Only the
# receiver runs continuously, so the PVT slide stays warm.

const SLIDE_INTRO = 0
const SLIDE_SPECTRUM = 1
const SLIDE_EXPLAIN = 2
const SLIDE_ACQ = 3
const SLIDE_TRACK = 4
const SLIDE_DECODE = 5
const SLIDE_PVT = 6
const SLIDE_JULIA = 7
const SLIDE_OUTRO = 8
const PG_WINDOW = 24              # periodogram y-axis sliding window (frames, ~6 s at 4 Hz)

_slide(m::PresentationModel) = @lock m.lk m.slide

"Attach the branch consumers to the running hub."
function start_processing!(m::PresentationModel)
    hub = m.hub
    hub === nothing && return
    push!(m.tasks, _spawn_periodogram(m, hub))
    # The receiver is normally started on demand, when the decoding slide is first shown,
    # so the audience watches the ephemeris decode and the fix converge from zero rather
    # than meeting a fix that was quietly reached during the intro. `--eager-receiver`
    # restores the old warm-from-startup behaviour as a timing fallback.
    m.eager_rx && _start_receiver_once!(m; startup_delay = 2.0)
    m.skip_acq || push!(m.tasks, _spawn_acquisition(m, hub))
    push!(m.tasks, _spawn_tracking(m, hub))
    push!(m.tasks, _spawn_map(m))
    return m
end

"""
    _start_once!(f, m, key) -> Bool

Run `f()` the first time `key` is claimed and return `true`; later calls are no-ops
returning `false`. Takes `m.lk` (reentrant, so it is safe to call from `update!`, which
already holds it). Slides can be revisited, so every on-demand start goes through here.
"""
function _start_once!(f, m::PresentationModel, key::Symbol)
    @lock m.lk begin
        key in m.started && return false
        push!(m.started, key)
        f()
        return true
    end
end

"Start the receiver exactly once (no-op under `--no-receiver`)."
function _start_receiver_once!(m::PresentationModel; startup_delay = 0.0)
    m.skip_rx && return false
    _start_once!(m, :receiver) do
        hub = m.hub
        hub === nothing || push!(m.tasks, _spawn_receiver(m, hub; startup_delay))
    end
end

"""
    _publish_acq_space!(m, plan)

Publish the real size of the acquisition search so slide 2 can quote it instead of
hardcoding textbook figures: the number of code-phase offsets (one per sample of a code
period), the Doppler grid the plan actually searches, and the PRN count. `operations` is
what a *naive* search would cost — every hypothesis is a full code-period correlation —
which is the number that motivates the FFT-based search on the next slide.

Called by whichever background task builds a plan first; first writer wins.
"""
function _publish_acq_space!(m::PresentationModel, plan)
    @lock m.lk begin
        m.acq_space === nothing || return
        dopplers = plan.doppler_freqs
        code_phases = plan.samples_per_code
        bins = length(dopplers)
        prns = length(plan.avail_prns)
        hypotheses = float(code_phases) * bins * prns
        m.acq_space = (
            code_phases = code_phases,
            doppler_bins = bins,
            doppler_span_hz = abs(Float64(ustrip(Hz, last(dopplers) - first(dopplers)))),
            prns = prns,
            hypotheses = hypotheses,
            operations = hypotheses * code_phases,
        )
    end
    return
end

# Edge-triggered "slide N became visible", called from the two places that assign
# `m.slide`. Anything started here must be idempotent — see `_start_once!`.
function _on_slide_enter!(m::PresentationModel, slide::Int)
    slide == SLIDE_DECODE && _start_receiver_once!(m)
    return
end

# Spectrum: drain always (cheap, keep latest raw chunk); compute the FFT only while the
# spectrum slide is shown, and only a few times a second.
function _spawn_periodogram(m, hub)
    latest = Ref{Any}(nothing)
    Base.errormonitor(Threads.@spawn _poll_drain(c -> (latest[] = c), hub.branches.periodogram))
    Base.errormonitor(Threads.@spawn begin
        fsHz = Float64(ustrip(Hz, m.fs))
        while !m.quit
            if _slide(m) == SLIDE_SPECTRUM && latest[] !== nothing
                x = ComplexF32.(vec(latest[]))
                pg = DSP.periodogram(x; onesided = false, fs = fsHz)
                freqs = DSP.fftshift(collect(Float64, pg.freq))
                powers = 10 .* log10.(DSP.fftshift(pg.power) .+ 1e-12)
                lo, hi = extrema(powers)
                @lock m.lk begin
                    m.periodogram = (freqs = freqs, powers = powers)
                    # Sliding-window min/max: stable axis that still adapts to recent
                    # conditions (older frames age out of the window).
                    push!(m.pg_win, (lo, hi))
                    length(m.pg_win) > PG_WINDOW && popfirst!(m.pg_win)
                    m.pg_ymin = minimum(first, m.pg_win)
                    m.pg_ymax = maximum(last, m.pg_win)
                end
                sleep(0.25)
            else
                sleep(0.3)
            end
        end
    end)
end

# Started on demand when the decoding slide is first shown (`_on_slide_enter!`), so the
# decode and the fix happen live in front of the audience instead of during the intro;
# `startup_delay` only matters for the eager path, where it lets the light slides warm
# first (the receiver's first FFTW.MEASURE planning is CPU-heavy).
#
# File replay: the receiver processes the recording ONCE, on its own dedicated lossless
# reader, then the fix is held on screen (`last_fix`). Looping a finite recording feeds a
# stateful receiver GPS time that jumps backward at the seam (~61.5 s for this file);
# empirically the built-in re-acquisition then never re-decodes satellite health — PVT
# keeps running on the pass-1 ephemeris, but sats read unhealthy. A single clean pass
# gives a correct healthy fix. The stateless front slides keep looping (live) off the
# shared fan-out. A live SDR has monotonic time, so it runs continuously.
function _spawn_receiver(m, hub; startup_delay = 2.0)
    Base.errormonitor(Threads.@spawn begin
        startup_delay > 0 && sleep(startup_delay)
        cfg = hub.cfg
        if cfg.path === nothing
            _run_receiver!(m, hub.branches.receiver, hub.max_meas)   # live SDR: continuous
        else
            # Second argument is the channel DEPTH, not the antenna count (antennas are
            # the type parameter N, default 1). A depth of 1 lock-steps the reader to the
            # receiver's *instantaneous* rate, so every periodic-reacquisition burst
            # stalls the paced reader and steals wall-clock time it can never win back.
            # A deeper buffer lets the reader hold real-time pacing across those bursts —
            # the same job a real SDR's DMA ring does.
            chan = SignalChannel{Complex{Int16}}(cfg.num_samples, 64)
            _spawn_file_reader!(chan, cfg.path, cfg.fs, cfg.num_samples,
                cfg.realtime, false, Complex{Int16};                 # loop = false → one pass
                stop = () -> m.quit)
            _run_receiver!(m, chan, hub.max_meas)                    # runs to EOF, then fix is held
        end
    end)
end

function _run_receiver!(m::PresentationModel, chan, max_meas)
    data_channel = receive(chan, m.system, m.fs;
        num_ants = NumAnts(1), max_meas = max_meas, interm_freq = m.interm_freq,
        extract = nav_data_of_interest)          # + live decoder state (see nav_snapshot.jl)
    gui_channel = nav_gui_channel(data_channel)
    consume_channel(gui_channel) do gui
        @lock m.lk begin
            m.gui = gui
            gui.pvt.time === nothing || (m.last_fix = gui)           # keep the last real fix
        end
    end
end

# Acquisition: drain always (keep newest raw chunk); run the heavy 32-PRN search only
# while the acquisition slide is shown, on a ~2 s cadence. `store_power_bins` (the whole
# Doppler×code surface) is materialized for the selected PRN only.
function _spawn_acquisition(m, hub)
    latest = Ref{Any}(nothing)
    Base.errormonitor(Threads.@spawn _poll_drain(hub.branches.acquisition) do chunk
        latest[] = chunk                                  # store raw; convert lazily
        @lock m.lk (m.chunk_count += 1)
    end)
    Base.errormonitor(Threads.@spawn begin
        plan = plan_acquire(m.system, m.fs, collect(1:32);
            num_coherently_integrated_code_periods = 4, fft_flag = ESTIMATE)
        _publish_acq_space!(m, plan)         # slide 2 quotes this plan's real search size
        minlen = 4 * samples_per_code(m.system, m.fs)
        last_full = 0.0                      # last full 32-PRN search
        last_surf = 0.0                      # last surface (single-PRN) render
        surf_sel = nothing                   # PRN the current surface is for
        surf_full = nothing                  # zoom mode the current surface is in
        while !m.quit
            raw = latest[]
            if _slide(m) == SLIDE_ACQ && raw !== nothing && length(vec(raw)) >= minlen
                block = ComplexF32.(vec(raw))
                now = time()
                # Full 32-PRN search (the bar + detection) on a ~2 s cadence.
                if now - last_full >= 2.0
                    @lock m.lk (m.acquiring = true)
                    results = acquire!(plan, block, collect(1:32);
                        interm_freq = m.interm_freq, store_power_bins = false)
                    # Proper CFAR detection; peak_to_noise_ratio ranks strength.
                    det = [r.prn for r in results if is_detected(r)]
                    @lock m.lk begin
                        m.acq_results = results
                        m.detected = det
                        m.cursor = clamp(m.cursor, 1, max(1, length(det)))
                        if m.selected_prn === nothing && !isempty(det)
                            m.selected_prn = det[argmax([results[findfirst(r -> r.prn == p, results)].peak_to_noise_ratio for p in det])]
                        end
                    end
                    @lock m.lk (m.acquiring = false)
                    last_full = now
                end
                # Surface (single-PRN, with power bins): rebuild IMMEDIATELY when the
                # selection or zoom mode changes, else refresh every ~2 s.
                sel, zoom_on = @lock m.lk (m.selected_prn, m.acq_zoom)
                if sel !== nothing &&
                   (sel != surf_sel || (!zoom_on) != surf_full || now - last_surf >= 2.0)
                    sres = only(acquire!(plan, block, [sel];
                        interm_freq = m.interm_freq, store_power_bins = true))
                    surf = try
                        acq_surface_grid(sres; full = !zoom_on)
                    catch
                        nothing
                    end
                    @lock m.lk begin
                        m.selected_acq = sres
                        surf === nothing || (m.surface = surf)
                    end
                    surf_sel = sel
                    surf_full = !zoom_on
                    last_surf = now
                end
            end
            sleep(0.25)
        end
    end)
end

# Tracking: a fast consumer keeps the newest block (never stalls the fan-out); a throttled
# loop, while the tracking slide is shown, re-ACQUIRES the selected PRN on the current
# block (so the seed is aligned to *these* samples) and tracks that block with the
# many-tap TriangleCorrelator, publishing the correlation triangle. Re-acquiring every
# update keeps it aligned and makes it robust to the file's loop wrap — otherwise a seed
# from an earlier block drifts out of phase and the triangle collapses into noise.
function _spawn_tracking(m, hub)
    latest = Ref{Any}(nothing)
    Base.errormonitor(Threads.@spawn _poll_drain(c -> (latest[] = c), hub.branches.tracking))
    Base.errormonitor(Threads.@spawn begin
        code_freq = get_code_frequency(m.system)
        dc = CPUThreadedDownconvertAndCorrelator()
        plan = plan_acquire(m.system, m.fs, collect(1:32);
            num_coherently_integrated_code_periods = 4, fft_flag = ESTIMATE)
        _publish_acq_space!(m, plan)         # backstop: this task runs even under --no-acq
        minlen = 4 * samples_per_code(m.system, m.fs)
        while !m.quit
            sel = @lock m.lk m.selected_prn
            raw = latest[]
            if _slide(m) == SLIDE_TRACK && sel !== nothing && raw !== nothing &&
               length(vec(raw)) >= minlen
                block = ComplexF32.(vec(raw))
                acq = only(acquire!(plan, block, [sel];
                    interm_freq = m.interm_freq, subsample_interpolation = true))
                tri = TriangleCorrelator(; sampling_freq = m.fs, code_freq = code_freq)
                sat = TrackedSat(m.system, sel, acq.code_phase, acq.carrier_doppler;
                    num_ants = NumAnts(1), correlator = tri)
                ts = track!(block, TrackState(dictionary((sel => sat,))), m.fs;
                    downconvert_and_correlator = dc, intermediate_frequency = m.interm_freq)
                sat_state = get_sat_states(ts)[sel]
                corr = get_last_fully_integrated_correlator(sat_state)
                snap = (
                    offsets = collect(Float64, tap_offsets_chips(tri, m.fs, code_freq)),
                    mags = collect(Float64, abs.(get_accumulators(corr))),
                    prompt_idx = tri.prompt_idx,
                    early_idx = tri.early_idx,
                    late_idx = tri.late_idx,
                    prn = sel,
                    doppler = acq.carrier_doppler,
                    disc = dll_disc(m.system, corr, sat_state.code_doppler, m.fs),
                    code_phase = mod(get_code_phase(sat_state), get_code_length(m.system)),
                )
                @lock m.lk (m.triangle = snap)
                sleep(0.2)
            else
                sleep(0.2)
            end
        end
    end)
end

# Render the position on an OpenStreetMap tile with UnicodeMaps (network download, a few
# seconds) — done on a background task, once per (position, panel-size), so the PVT slide
# only ever draws the cached, parsed span-lines. The PVT slide publishes what it wants via
# `m.map_want`; here we render it and cache the parsed lines in `m.map_lines`.
function _spawn_map(m::PresentationModel)
    Base.errormonitor(Threads.@spawn begin
        while !m.quit
            want, have = @lock m.lk (m.map_want, m.map_key)
            if want !== nothing && want != have
                lat, lon, w, h, zoom, marker = want
                if w >= 8 && h >= 4
                    try
                        img = worldmap(; center = (lon, lat), zoom = Int(zoom),
                            size = (Int(w), Int(h)), marker = marker)
                        lines = [parse_ansi(String(l)) for l in split(sprint(show, img), "\n")]
                        @lock m.lk begin
                            m.map_lines = lines
                            m.map_key = want
                        end
                    catch
                        @lock m.lk (m.map_key = want)   # don't retry a failing request in a loop
                    end
                end
            end
            sleep(0.5)
        end
    end)
end

# ── Snapshot read under lock, then render ────────────────────────────────────

function _snapshot(m::PresentationModel)
    @lock m.lk (
        slide = m.slide, tick = m.tick, chunk_count = m.chunk_count,
        periodogram = m.periodogram, acq_results = m.acq_results, detected = m.detected,
        cursor = m.cursor, selected_prn = m.selected_prn, surface = m.surface,
        acquiring = m.acquiring, triangle = m.triangle, gui = m.gui, last_fix = m.last_fix,
        map_lines = m.map_lines, pg_ymin = m.pg_ymin, pg_ymax = m.pg_ymax, acq_zoom = m.acq_zoom,
        acq_space = m.acq_space,
    )
end

# ── Input ────────────────────────────────────────────────────────────────────

# Step to the next/previous slide, skipping the acquisition slide when it's disabled.
function _step_slide(m::PresentationModel, dir::Int)
    s = clamp(m.slide + dir, 0, NUM_SLIDES - 1)
    if m.skip_acq && s == SLIDE_ACQ
        s = clamp(s + dir, 0, NUM_SLIDES - 1)
    end
    s
end

# Show slide `s` and fire the slide-enter hook on an actual change. The hook runs outside
# the assignment's lock section (it takes `m.lk` itself) and only on the leading edge, so
# revisiting a slide never restarts its work. Every slide change goes through here — key
# handling via `_goto_slide!`, tests directly — so nothing can move slides without the hook.
function _set_slide!(m::PresentationModel, s::Int)
    prev = @lock m.lk ((old = m.slide; m.slide = s; old))
    s == prev || _on_slide_enter!(m, s)
    return s
end

"Step to the next/previous slide."
_goto_slide!(m::PresentationModel, dir::Int) = _set_slide!(m, @lock m.lk _step_slide(m, dir))

function update!(m::PresentationModel, e::KeyEvent)
    if e.key == :ctrl_c || e.key == :escape
        m.quit = true
        return
    end
    if e.key == :char && (e.char == 'q' || e.char == 'Q')
        m.quit = true
        return
    end
    if e.key == :right || (e.key == :char && e.char == 'n') || e.key == :pagedown
        _goto_slide!(m, 1)
        return
    end
    if e.key == :left || (e.key == :char && e.char == 'p') || e.key == :pageup
        _goto_slide!(m, -1)
        return
    end
    # acquisition slide: ↑/↓ directly select the previous/next detected PRN.
    if m.slide == SLIDE_ACQ
        if e.key == :up || e.key == :down
            @lock m.lk begin
                if !isempty(m.detected)
                    i = findfirst(==(m.selected_prn), m.detected)
                    i = i === nothing ? 1 :
                        (e.key == :up ? max(1, i - 1) : min(length(m.detected), i + 1))
                    newsel = m.detected[i]
                    m.cursor = i
                    if newsel != m.selected_prn
                        m.selected_prn = newsel
                        m.selected_acq = nothing   # force re-acquire with bins for the surface
                        m.surface = nothing
                    end
                end
            end
        elseif e.key == :char && e.char == 'z'
            @lock m.lk (m.acq_zoom = !m.acq_zoom)   # toggle zoomed ↔ full code-phase view
        end
    end
    # PVT slide: pan/zoom the map. `+`/`-` zoom, `h/j/k/l` pan (vim), `0` recenter.
    # (←/→ stay slide navigation, so map pan uses hjkl to avoid conflict.)
    if m.slide == SLIDE_PVT && e.key == :char
        c = e.char
        if c == '+' || c == '='
            @lock m.lk (m.map_zoom = clamp(m.map_zoom + 1, 1, 18))
        elseif c == '-' || c == '_'
            @lock m.lk (m.map_zoom = clamp(m.map_zoom - 1, 1, 18))
        elseif c == '0'
            @lock m.lk begin
                m.map_zoom = 13
                m.map_dlon = 0.0
                m.map_dlat = 0.0
            end
        elseif c == 'h' || c == 'j' || c == 'k' || c == 'l'
            @lock m.lk begin
                step = 0.35 * 360.0 / 2.0^m.map_zoom   # ~⅓ view per press, scales with zoom
                c == 'h' && (m.map_dlon -= step)       # west
                c == 'l' && (m.map_dlon += step)       # east
                c == 'k' && (m.map_dlat += step)       # north
                c == 'j' && (m.map_dlat -= step)       # south
            end
        end
    end
    return
end

update!(::PresentationModel, ::Event) = nothing

# ── View ─────────────────────────────────────────────────────────────────────

const SLIDE_TITLES = (
    "Real-Time GNSS Positioning with JuliaGNSS",
    "The raw spectrum: signals below the noise",
    "The signal I have to chase",
    "Acquisition: finding the satellites",
    "Tracking: the correlation triangle",
    "Decoding: 50 bits per second",
    "PVT: position, velocity & time",
    "Why Julia",
    "The JuliaGNSS ecosystem",
)

# The pipeline as a live progress bar for the talk: the stage the current slide is about
# is highlighted, and a stage turns green only once it has ACTUALLY succeeded on this
# run — satellites found, ephemeris decoded, fix computed. It doubles as the audience's
# "you are here", and as honest proof that nothing on screen is canned.
const PIPELINE_STAGES = ("Samples", "Acquisition", "Tracking", "Decoding", "PVT")

# Which stage each slide is about (nothing = no stage, e.g. the title and closing slides).
function _slide_stage(slide::Int)
    slide == SLIDE_SPECTRUM && return 1
    (slide == SLIDE_EXPLAIN || slide == SLIDE_ACQ) && return 2
    slide == SLIDE_TRACK && return 3
    slide == SLIDE_DECODE && return 4
    slide == SLIDE_PVT && return 5
    return nothing
end

# Has each stage actually produced something yet?
function _stage_done(s)
    sats = s.gui === nothing ? nothing : s.gui.sat_data
    decoded = sats !== nothing && any(sd -> sd.complete, sats)
    (s.chunk_count > 0,
        !isempty(s.detected),
        sats !== nothing && !isempty(sats),
        decoded,
        s.last_fix !== nothing)
end

function _render_pipeline!(buf, area::Rect, s)
    done = _stage_done(s)
    here = _slide_stage(s.slide)
    x = area.x + 1
    for (i, name) in enumerate(PIPELINE_STAGES)
        x > right(area) && break
        current = here == i
        style = current ? tstyle(:accent, bold = true) :
                done[i] ? tstyle(:success) : tstyle(:text_dim)
        label = current ? "▸ " * name * " ◂" : name
        x = set_string!(buf, x, area.y, label, style; max_x = right(area))
        if i < length(PIPELINE_STAGES)
            x = set_string!(buf, x, area.y, "  →  ", tstyle(:text_dim); max_x = right(area))
        end
    end
    return
end

function view(m::PresentationModel, f::Frame)
    m.tick += 1
    s = _snapshot(m)
    buf = f.buffer
    rows = split_layout(Layout(Vertical, [Fixed(1), Fixed(1), Fill(), Fixed(1)]), f.area)
    header, pipeline, body, footer = rows[1], rows[2], rows[3], rows[4]

    # header
    hdr = " ● JuliaGNSS  │  $(SLIDE_TITLES[s.slide+1])"
    set_string!(buf, header.x, header.y, rpad(hdr, header.width),
        tstyle(:title, bold = true); max_x = right(header))
    _render_pipeline!(buf, pipeline, s)

    # body per slide
    if s.slide == SLIDE_INTRO
        render_intro(m, f, body, s)
    elseif s.slide == SLIDE_SPECTRUM
        render_spectrum(m, f, body, s)
    elseif s.slide == SLIDE_EXPLAIN
        render_explain(m, f, body, s)
    elseif s.slide == SLIDE_ACQ
        render_acquisition(m, f, body, s)
    elseif s.slide == SLIDE_TRACK
        render_tracking(m, f, body, s)
    elseif s.slide == SLIDE_DECODE
        render_decode(m, f, body, s)
    elseif s.slide == SLIDE_PVT
        render_pvt(m, f, body, s)
    elseif s.slide == SLIDE_JULIA
        render_julia(m, f, body, s)
    else
        render_outro(m, f, body, s)
    end

    # footer
    slidehint = s.slide == SLIDE_ACQ ? "[↑/↓] select PRN  [z] zoom/full  " :
                s.slide == SLIDE_PVT ? "[+/-] zoom  [hjkl] pan map  [0] recenter  " : ""
    render(StatusBar(
            left = [Span(" [←/→] slide  ", tstyle(:text_dim)),
                Span(slidehint, tstyle(:text_dim))],
            right = [Span("slide $(s.slide+1)/$NUM_SLIDES   [q] quit ", tstyle(:text_dim))],
        ), footer, buf)
    return
end

include("slide_intro.jl")
include("slide_spectrum.jl")
include("slide_explain.jl")
include("slide_acquisition.jl")
include("slide_tracking.jl")
include("slide_decode.jl")
include("slide_pvt.jl")
include("slide_julia.jl")
include("slide_outro.jl")

# ── Entry point ──────────────────────────────────────────────────────────────

# Pay Julia's first-call (TTFX) compilation cost for the acquisition / surface / tracking
# code paths BEFORE the app starts, so the interactive slides respond immediately instead
# of filling in over ~10 s while methods compile. Uses a self-contained synthetic block —
# no stream needed. The receiver pipeline is left to warm in the background (PVT is last).
function _warmup(system, fs; receiver::Bool = true)
    spc = samples_per_code(system, fs)
    code = ComplexF32.(gen_code(4 * spc, system, 1, fs, get_code_frequency(system), 0.0))
    plan = plan_acquire(system, fs, collect(1:32);
        num_coherently_integrated_code_periods = 4, fft_flag = ESTIMATE)
    acquire!(plan, code, collect(1:32); store_power_bins = false)
    r = only(acquire!(plan, code, [1]; store_power_bins = true))
    try
        acq_surface_grid(r)
    catch
    end
    tri = TriangleCorrelator(; sampling_freq = fs, code_freq = get_code_frequency(system))
    sat = TrackedSat(system, 1, r.code_phase, r.carrier_doppler;
        num_ants = NumAnts(1), correlator = tri)
    ts = TrackState(dictionary((1 => sat,)))
    track!(vcat(code, code), ts, fs; downconvert_and_correlator = CPUThreadedDownconvertAndCorrelator())

    # Warm the PVT slide's UnicodePlots CN0 barplot + DOA polarplot (heavy first-call
    # compilation) so the slide doesn't stutter the first time it's shown.
    try
        bp = string(UP.barplot(["PRN 1", "PRN 2"], [45.0, 48.0]; color = [:green, :red],
            border = :none, width = 20, maximum = 55); color = true)
        foreach(l -> parse_ansi(String(l)), split(bp, '\n'))
        dp = UP.polarplot([0.5, 2.0], [30.0, 60.0]; rlim = (0, 90), scatter = true,
            marker = :circle, color = :green, border = :none, num_rad_lab = 0,
            width = 20, height = 10)
        UP.annotate!(dp, 30cos(0.5), 30sin(0.5), "1"; color = :green)
        UP.label!(dp, :t, "0°"; color = UP.BORDER_COLOR[])
        foreach(l -> parse_ansi(String(l)), split(string(dp; color = true), '\n'))
    catch
    end

    # Warm the full receiver pipeline too. A short synthetic stream is enough to trace
    # every method. This is the heavy part; skip it for the light runtime insurance pass
    # (the real receiver warms itself in the background) and only run it during the
    # precompile workload, where its compilation is baked into the on-disk cache.
    receiver || return nothing
    ch = SignalChannel{Complex{Int16}}(10 * spc, 1)
    Threads.@spawn begin
        blk = zeros(Complex{Int16}, 10 * spc, 1)
        for _ in 1:3
            put!(ch, copy(blk))
        end
        close(ch)
    end
    dc = receive(ch, system, fs; num_ants = NumAnts(1), max_meas = 2^11,
        extract = nav_data_of_interest)
    gc = nav_gui_channel(dc)
    consume_channel(_ -> nothing, gc)
    return nothing
end

"""
    run_presentation(; path, fs=10e6u"Hz", num_samples, realtime=true, fps=20, hub=nothing)

Start the persistent stream (real-time file replay from `path`, or a caller-provided
`hub` for a live SDR), launch the background processing, and run the Tachikoma app.
"""
function run_presentation(;
    path::Union{String,Nothing} = nothing,
    fs = 10.0e6Hz,
    interm_freq = 0.0Hz,
    num_samples::Int = 10 * samples_per_code(GPSL1CA(), fs),
    realtime::Bool = true,
    fps::Int = 12,
    skip_acquisition::Bool = false,
    skip_receiver::Bool = false,
    eager_receiver::Bool = false,
    hub::Union{StreamHub,Nothing} = nothing,
)
    m = PresentationModel(; fs, interm_freq, skip_acq = skip_acquisition,
        skip_rx = skip_receiver, eager_rx = eager_receiver)
    # The acquisition/tracking/receiver code paths are baked into the package precompile
    # cache (see the `@compile_workload` at the bottom of this file), so a fresh process
    # starts fast. This light DSP pass is cheap insurance in case the cache is stale.
    _warmup(m.system, fs; receiver = false)
    if hub === nothing
        cfg = StreamConfig(; path, fs, interm_freq, num_samples, realtime)
        hub = start_stream(cfg)
    end
    m.hub = hub
    start_processing!(m)
    # Run the GUI loop on the interactive threadpool when available (`julia -t auto,1`)
    # so the render loop is never starved by the streaming/DSP tasks on the default pool.
    if Threads.nthreads(:interactive) > 0
        wait(Threads.@spawn :interactive app(m; fps))
    else
        app(m; fps)
    end
end

export run_presentation, PresentationModel, StreamConfig, StreamHub, start_stream,
    start_processing!, TriangleCorrelator, acq_surface_grid, draw_acq_surface!, viridis

# Bake the expensive first-call compilation (acquisition, correlation surface, tracking,
# and the full receiver pipeline) into the on-disk precompile cache, so every `julia
# run.jl` starts fast instead of recompiling these paths at runtime (~35 s). This runs
# once when the package precompiles; the compiled code is then reused across processes.
@compile_workload begin
    try
        _warmup(GPSL1CA(), 10.0e6Hz)
    catch
        # A failed workload only means a smaller cache — never block precompilation.
    end
end

end # module
