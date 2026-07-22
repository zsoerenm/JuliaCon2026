# Persistent sample source + fan-out hub.
#
# The source (recorded file, replayed at real time, or a live SoapySDR stream) is opened
# ONCE and fanned out to four branches — one per processing stage. The fan-out drains the
# source at full cadence and drops-on-full per branch, so a slow/bursty consumer (the
# receiver during its periodic acquisition) never stalls the source (which would overflow
# a real SDR) nor the light slides. Real-time pacing of file replay makes the file path
# exercise this backpressure exactly like a live SDR.

using SignalChannels: SignalChannel, num_antenna_channels
import Base: isfull, similar
using GNSSSignals: GPSL1CA, get_code_length, get_code_frequency, AbstractGNSSSignal
using Unitful: Hz, ustrip

"Samples per primary code period at `fs` for `system`."
samples_per_code(system, fs) =
    ceil(Int, get_code_length(system) / get_code_frequency(system) * fs)

Base.@kwdef struct StreamConfig
    path::Union{String,Nothing} = nothing
    system::AbstractGNSSSignal = GPSL1CA()
    fs = 10.0e6Hz
    interm_freq = 0.0Hz
    num_samples::Int = 10 * samples_per_code(GPSL1CA(), 10.0e6Hz)  # ~10 ms chunks
    realtime::Bool = true
    loop::Bool = true
end

struct StreamHub
    cfg::StreamConfig
    source::SignalChannel
    branches::NamedTuple
    max_meas::Int
end

"Read the first chunk to size the front-end full-scale for the Int16 tracking backend."
function probe_max_meas(path, num_samples; type = Complex{Int16})
    io = open(path)
    chunk = Matrix{type}(undef, num_samples, 1)
    try
        read!(io, chunk)
    catch e
        e isa EOFError || rethrow(e)
    finally
        close(io)
    end
    m = 0
    @inbounds for x in chunk
        m = max(m, abs(Int(real(x))), abs(Int(imag(x))))
    end
    max(m, 1)
end

# Background task: read `num_samples`-chunks from `path` into `out`, paced to real time
# (sleep `num_samples/fs` per chunk), looping at EOF so the demo never runs dry.
function _spawn_file_reader!(out, path, fs, num_samples, realtime, loop, type)
    period = num_samples / Float64(ustrip(Hz, fs))
    Base.errormonitor(Threads.@spawn begin
        try
            deadline = time()
            while true
                io = open(path)
                try
                    while true
                        chunk = Matrix{type}(undef, num_samples, 1)  # fresh buffer per chunk
                        got = true
                        try
                            read!(io, chunk)
                        catch e
                            e isa EOFError ? (got = false) : rethrow(e)
                        end
                        got || break
                        put!(out, chunk)
                        if realtime
                            deadline += period
                            dt = deadline - time()
                            dt > 0 && sleep(dt)
                            deadline < time() && (deadline = time())  # don't spiral if behind
                        else
                            yield()
                        end
                    end
                finally
                    close(io)
                end
                loop || break
            end
        finally
            close(out)
        end
    end)
end

const BRANCH_NAMES = (:receiver, :periodogram, :acquisition, :tracking)
# Per-branch buffer depth. The receiver is bursty (its periodic 32-PRN acquisition),
# so it gets a deep buffer to absorb bursts before dropping; the light branches stay
# shallow and current.
const BRANCH_BUFFERS = (receiver = 64, periodogram = 8, acquisition = 8, tracking = 8)

# SignalChannel/PipeChannel are lock-free and BUSY-WAIT (`take!`/`wait`/`put!` spin with
# `yield()`) for microsecond SDR latency. With chunked streaming (~10 ms gaps) that pegs
# every core. For a presentation we don't need that latency, so we poll `isready` and
# `sleep` when idle — tasks then actually park and the CPU stays low.
const POLL_INTERVAL = 0.002   # 2 ms; adds ≤2 ms latency, negligible vs 10 ms chunks

"Drain `ch` by polling (sleeping when empty) instead of busy-waiting; call `f(chunk)` per item."
function _poll_drain(f, ch; interval = POLL_INTERVAL)
    while true
        if isready(ch)
            f(take!(ch))
        elseif isopen(ch)
            sleep(interval)
        else
            break
        end
    end
end

# Fan the source out to the branches with DROP-ON-FULL semantics: a branch whose consumer
# falls behind drops the newest chunk rather than stalling everyone else. Polls the source
# (sleeping when empty, no spin). Safe under SignalChannel's one-producer/one-consumer
# rule: only this task `put!`s to a branch, and `isfull` only goes false→(stays) as its
# single consumer drains it. (On file replay the stateful receiver runs off its own
# dedicated single-pass reader, not this looping fan-out — see `_spawn_receiver`.)
function _spawn_fanout!(source, branches)
    bs = Tuple(branches)
    Base.errormonitor(Threads.@spawn begin
        try
            _poll_drain(source; interval = 0.001) do chunk
                for b in bs
                    isfull(b) || put!(b, chunk)
                end
            end
        finally
            for b in bs
                close(b)
            end
        end
    end)
end

"Create the four named branches and start the drop-on-full fan-out from `source`."
function _make_branches(source)
    branches = NamedTuple{BRANCH_NAMES}(
        map(n -> similar(source, getfield(BRANCH_BUFFERS, n)), BRANCH_NAMES))
    _spawn_fanout!(source, branches)
    branches
end

"""
    start_stream(cfg::StreamConfig; type=Complex{Int16}) -> StreamHub

Open the recorded file, probe `max_meas`, start the real-time paced reader, and fan the
stream out to the four branches. The source and branches live until the channels close.
"""
function start_stream(cfg::StreamConfig; type = Complex{Int16})
    cfg.path === nothing &&
        throw(ArgumentError("StreamConfig.path is nothing; use start_stream_from_channel for a live SDR source"))
    isfile(cfg.path) || throw(ArgumentError("sample file not found: $(cfg.path) — run scripts/download_data.jl"))
    max_meas = probe_max_meas(cfg.path, cfg.num_samples; type)
    source = SignalChannel{type}(cfg.num_samples, 1)
    _spawn_file_reader!(source, cfg.path, cfg.fs, cfg.num_samples, cfg.realtime, cfg.loop, type)
    StreamHub(cfg, source, _make_branches(source), max_meas)
end

"""
    start_stream_from_channel(source, cfg; max_meas=1) -> StreamHub

Build a hub from an already-running source `SignalChannel` — e.g. a live SoapySDR
stream from `SignalChannels.stream_data(device, SDRChannelConfig(...))`. The caller owns
the device/warning channel. Real-time pacing is inherent to the SDR.
"""
function start_stream_from_channel(source::SignalChannel, cfg::StreamConfig; max_meas::Int = 1)
    StreamHub(cfg, source, _make_branches(source), max_meas)
end
