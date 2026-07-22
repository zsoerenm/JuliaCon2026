#!/usr/bin/env julia
# Download a bounded prefix of the ION LimeSDR GPS L1 sample recording (10 MSPS, int16
# I/Q) via an HTTP range request, so slides work without pulling the whole file.
#
# Usage:
#   julia scripts/download_data.jl              # ~40 s (~1.6 GB) — enough for a PVT fix
#   julia scripts/download_data.jl --short      # ~4 s  (~160 MB) — spectrum/acq/tracking
#   julia scripts/download_data.jl --seconds 20 # custom length
#   julia scripts/download_data.jl --full       # the entire file (large!)

const URL = "https://sdr.ion.org/LimeSDR/LimeSDR_Bands-L1.int16"
const FS = 10_000_000                 # samples/s
const BYTES_PER_SAMPLE = 4            # Complex{Int16}

function main(args)
    seconds = 40.0
    full = false
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--short"
            seconds = 4.0
        elseif a == "--full"
            full = true
        elseif a == "--seconds" && i < length(args)
            seconds = parse(Float64, args[i+1]); i += 1
        end
        i += 1
    end
    outdir = joinpath(@__DIR__, "..", "data")
    mkpath(outdir)
    out = joinpath(outdir, "LimeSDR_Bands-L1.int16")

    if full
        @info "Downloading the FULL LimeSDR recording (this is large)…" URL out
        run(`curl -L --fail -o $out $URL`)
    else
        nbytes = round(Int, seconds * FS * BYTES_PER_SAMPLE)
        @info "Downloading ~$(seconds)s prefix ($(round(nbytes/1e6; digits=1)) MB)…" URL out
        run(`curl -L --fail -r 0-$(nbytes - 1) -o $out $URL`)
    end
    sz = filesize(out)
    @info "Done." file=out size_MB=round(sz / 1e6; digits = 1) approx_seconds=round(sz / (FS * BYTES_PER_SAMPLE); digits = 1)
end

main(ARGS)
