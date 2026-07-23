#!/usr/bin/env julia
# Entry point for the JuliaCon 2026 GNSS presentation.
#
#   julia --project -t auto run.jl                 # replay the recorded file (real-time)
#   julia --project -t auto run.jl --no-realtime   # replay as fast as possible
#   julia --project -t auto run.jl --path FILE     # use a different recording
#   julia --project -t auto run.jl --sdr           # live from a SoapySDR device
#
# Best visuals need a sixel/kitty terminal (kitty, iTerm2, WezTerm, foot); the 3D
# acquisition surface auto-falls back to braille elsewhere. Navigate with ← / →.

import Pkg
Pkg.activate(@__DIR__)

# Load as a precompiled package (NOT `include`) so the acquisition/tracking/receiver
# compilation baked into the precompile cache is reused — this is what keeps startup fast.
using GNSSPresentation
using Unitful: Hz, dB
using SignalChannels: SDRChannelConfig, stream_data

function parse_args(args)
    opts = Dict{String,Any}(
        "path" => joinpath(@__DIR__, "data", "LimeSDR_Bands-L1.int16"),
        "sdr" => false, "realtime" => true, "fps" => 12, "fs" => 10.0e6Hz,
        "no_acq" => false, "no_rx" => false, "if_khz" => nothing, "gain" => 60.0,
    )
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--sdr"
            opts["sdr"] = true
        elseif a == "--no-acq"
            opts["no_acq"] = true
        elseif a == "--no-receiver"
            opts["no_rx"] = true
        elseif a == "--if-khz" && i < length(args)
            opts["if_khz"] = parse(Float64, args[i+1]); i += 1
        elseif a == "--no-realtime"
            opts["realtime"] = false
        elseif a == "--path" && i < length(args)
            opts["path"] = args[i+1]; i += 1
        elseif a == "--fps" && i < length(args)
            opts["fps"] = parse(Int, args[i+1]); i += 1
        elseif a == "--gain" && i < length(args)
            opts["gain"] = parse(Float64, args[i+1]); i += 1
        end
        i += 1
    end
    opts
end

function live_hub(fs, num_samples, gain_db)
    @info "Opening SoapySDR device…"
    @eval Main using SoapySDR
    dev = first(Main.SoapySDR.Devices())
    config = SDRChannelConfig(; sample_rate = fs, frequency = 1.57542e9Hz, gain = gain_db * dB)
    # ComplexF32 stream (general CPU backend; max_meas unused). Streams until closed.
    data_channel, _warn = stream_data(dev, config, typemax(Int); chunk_size = num_samples)
    cfg = GNSSPresentation.StreamConfig(; fs, num_samples, realtime = true)
    GNSSPresentation.start_stream_from_channel(data_channel, cfg)
end

function main()
    opts = parse_args(ARGS)
    fs = opts["fs"]
    spc = GNSSPresentation.samples_per_code(GNSSPresentation.GPSL1CA(), fs)
    num_samples = 10 * spc

    if_set = opts["if_khz"] !== nothing
    if opts["sdr"]
        # A live SDR is tuned to L1 → baseband (0 IF) unless overridden.
        interm_freq = (if_set ? opts["if_khz"] : 0.0) * 1e3 * Hz
        hub = live_hub(fs, num_samples, opts["gain"])
        run_presentation(; fs, interm_freq, num_samples, hub, fps = opts["fps"],
            skip_acquisition = opts["no_acq"], skip_receiver = opts["no_rx"])
    else
        path = opts["path"]
        if !isfile(path)
            println("""
            Sample file not found:
              $path

            Download a bounded prefix first, e.g.:
              julia --project scripts/download_data.jl --short   # ~4 s, spectrum/acq/tracking
              julia --project scripts/download_data.jl           # ~40 s, enough for a PVT fix

            Or point at your own recording with --path, or stream live with --sdr.
            """)
            return
        end
        # The ION LimeSDR recording is at a 420 kHz IF (from its .sdrx metadata).
        interm_freq = (if_set ? opts["if_khz"] : 420.0) * 1e3 * Hz
        run_presentation(; path, fs, interm_freq, num_samples, realtime = opts["realtime"],
            fps = opts["fps"], skip_acquisition = opts["no_acq"], skip_receiver = opts["no_rx"])
    end
end

main()
