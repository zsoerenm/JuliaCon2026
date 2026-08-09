using Test
include(joinpath(@__DIR__, "..", "src", "GNSSPresentation.jl"))
using .GNSSPresentation
const GP = GNSSPresentation
using Tachikoma
using Acquisition: plan_acquire, acquire!
using Tracking: NumAnts, TrackedSat, TrackState, track!, get_sat_states,
    get_last_fully_integrated_correlator, get_accumulators
using GNSSSignals: GPSL1CA, get_code_frequency
using SignalChannels: calculate_periodogram
using Dictionaries: dictionary
using Unitful: Hz
include(joinpath(@__DIR__, "synth.jl"))

const FS = 10.0e6Hz
const SYS = GPSL1CA()
const CODE_FREQ = get_code_frequency(SYS)
const SPC = GP.samples_per_code(SYS, FS)
const DATA = joinpath(@__DIR__, "synthetic.int16")
const PRNS = write_synthetic_file(DATA; fs = FS)

readblock(nblocks) = begin
    io = open(DATA)
    b = Matrix{Complex{Int16}}(undef, nblocks * SPC, 1)
    read!(io, b)
    close(io)
    ComplexF32.(vec(b))
end

@testset "acquisition detects injected PRNs" begin
    block = readblock(4)
    plan = plan_acquire(SYS, FS, collect(1:32); num_coherently_integrated_code_periods = 4)
    res = acquire!(plan, block, collect(1:32); store_power_bins = false)
    det = [r.prn for r in res if r.CN0 >= GP.CN0_DETECT_THRESHOLD]
    for p in PRNS
        @test p in det
    end
    r1 = only(acquire!(plan, block, [PRNS[1]]; store_power_bins = true))
    @test r1.power_bins !== nothing
end

@testset "TriangleCorrelator geometry + tracked triangle" begin
    tri = GP.TriangleCorrelator(; sampling_freq = FS, code_freq = CODE_FREQ, num_taps = 31)
    @test length(tri.shifts) == 31
    @test tri.shifts[tri.prompt_idx] == 0
    @test tri.shifts[tri.early_idx] == -tri.shifts[tri.late_idx]
    @test tri.shifts[tri.early_idx] > 0                       # early = +shift
    # E/L ≈ ±0.5 chip
    el_chips = tri.shifts[tri.early_idx] * Float64(get_code_frequency(SYS) / FS)
    @test isapprox(el_chips, 0.5; atol = 0.1)

    block = readblock(8)
    plan = plan_acquire(SYS, FS, [PRNS[1]]; num_coherently_integrated_code_periods = 4)
    acq = only(acquire!(plan, block[1:4*SPC], [PRNS[1]]; subsample_interpolation = true))
    sat = TrackedSat(SYS, PRNS[1], acq.code_phase, acq.carrier_doppler;
        num_ants = NumAnts(1), correlator = tri)
    ts = TrackState(dictionary((PRNS[1] => sat,)))
    ts = track!(block, ts, FS)
    corr = get_last_fully_integrated_correlator(get_sat_states(ts)[PRNS[1]])
    mags = abs.(get_accumulators(corr))
    @test abs(argmax(mags) - tri.prompt_idx) <= 1            # peak at (or next to) prompt
    @test mags[tri.prompt_idx] > mags[1]                     # peak above the noise floor tap
end

@testset "acquisition 3D surface grid + draw" begin
    block = readblock(4)
    plan = plan_acquire(SYS, FS, [PRNS[1]]; num_coherently_integrated_code_periods = 4)
    r1 = only(acquire!(plan, block, [PRNS[1]]; store_power_bins = true))
    S = GP.acq_surface_grid(r1)
    @test size(S.Z, 1) >= 1 && size(S.Z, 2) >= 2
    @test isapprox(maximum(S.Z), 1.0)        # normalized, peak = 1
    @test minimum(S.Z) >= 0.0
    @test S.dop_top > S.dop_bot
    rect = Tachikoma.Rect(1, 1, 44, 16)
    buf = Tachikoma.Buffer(rect)
    GP.draw_acq_surface!(buf, rect, S)       # must not error; draws the heatmap + labels
    @test any(GP.viridis(z) isa Tachikoma.ColorRGB for z in (0.0, 0.5, 1.0))
end

@testset "periodogram is roughly flat (GPS below noise)" begin
    ch = GP.SignalChannel{Complex{Int16}}(SPC, 1)
    @async begin
        io = open(DATA)
        for _ in 1:4
            b = Matrix{Complex{Int16}}(undef, SPC, 1)
            read!(io, b)
            put!(ch, b)
        end
        close(io)
        close(ch)
    end
    pg = calculate_periodogram(ch, FS)
    d = take!(pg)
    @test length(d.freqs) == length(d.powers) > 0
    # no single bin dominates by a huge margin → essentially flat noise floor
    p = Float64.(d.powers)
    @test (maximum(p) - sum(p) / length(p)) < 20.0          # dB
end

@testset "integration: persistent stream + processing (per-slide gating)" begin
    GP._warmup(GPSL1CA(), FS)   # serial compile of all heavy paths before concurrent tasks
    cfg = GP.StreamConfig(; path = DATA, fs = FS, num_samples = 10 * SPC,
        realtime = true, loop = true)
    hub = GP.start_stream(cfg)
    m = GP.PresentationModel(; fs = FS)
    m.hub = hub
    GP.start_processing!(m)

    function waitfor(cond; n = 150, dt = 0.1)
        for _ in 1:n
            sleep(dt)
            cond() && return true
        end
        return false
    end

    # Heavy DSP only runs on its slide → drive the slide to exercise each branch.
    GP._set_slide!(m, GP.SLIDE_SPECTRUM)
    @test waitfor(() -> (@lock m.lk m.periodogram) !== nothing)

    GP._set_slide!(m, GP.SLIDE_ACQ)
    @test waitfor(() -> (@lock m.lk (m.surface !== nothing && m.selected_prn !== nothing)))
    @test !isempty(m.detected)
    # Slide 2 quotes the real plan's search size, published by the background tasks.
    sp = @lock m.lk m.acq_space
    @test sp !== nothing
    @test sp.code_phases == SPC && sp.doppler_bins > 1 && sp.prns == 32
    @test sp.hypotheses ≈ sp.code_phases * sp.doppler_bins * sp.prns

    GP._set_slide!(m, GP.SLIDE_TRACK)
    @test waitfor(() -> (@lock m.lk m.triangle) !== nothing)

    # The receiver is started lazily, by entering the decoding slide — not before.
    @test !(:receiver in (@lock m.lk copy(m.started)))
    @test (@lock m.lk m.gui) === nothing
    GP._set_slide!(m, GP.SLIDE_DECODE)
    @test :receiver in (@lock m.lk copy(m.started))
    ntasks = @lock m.lk length(m.tasks)
    # Revisiting the slide must not start a second receiver (and a second file reader).
    GP._set_slide!(m, GP.SLIDE_TRACK)
    GP._set_slide!(m, GP.SLIDE_DECODE)
    @test (@lock m.lk length(m.tasks)) == ntasks

    @test waitfor(() -> (@lock m.lk m.gui) !== nothing; n = 300)
    # The decoding slide's payload carries live decoder state, not just CN0/PVT.
    gui = @lock m.lk m.gui
    @test gui isa GP.NavSnapshot
    if !isempty(gui.sat_data)
        sd = first(gui.sat_data)
        @test hasproperty(sd, :raw) && hasproperty(sd, :complete)
        @test sd.bits_in_subframe >= -1
    end
    m.quit = true
end

@testset "eager receiver start (rehearsal fallback)" begin
    m = GP.PresentationModel(; fs = FS, eager_rx = true)
    m.hub = GP.start_stream(GP.StreamConfig(; path = DATA, fs = FS, num_samples = 10 * SPC,
        realtime = true, loop = true))
    GP.start_processing!(m)
    @test :receiver in (@lock m.lk copy(m.started))
    # …and entering the decoding slide later must not start a second one.
    n = @lock m.lk length(m.tasks)
    GP._set_slide!(m, GP.SLIDE_DECODE)
    @test (@lock m.lk length(m.tasks)) == n
    m.quit = true
end

@testset "all slides render headlessly" begin
    m = GP.PresentationModel(; fs = FS)
    rect = Tachikoma.Rect(1, 1, 140, 44)
    for slide in 0:(GP.NUM_SLIDES-1)
        m.slide = slide
        buf = Tachikoma.Buffer(rect)
        f = Tachikoma.Frame(buf, rect, Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
        Tachikoma.view(m, f)
        txt = Tachikoma.buffer_to_text(buf, rect)
        @test occursin("JuliaGNSS", txt)
    end
end
