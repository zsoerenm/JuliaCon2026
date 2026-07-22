#!/usr/bin/env julia
# Diagnose a recording: read a block, print I/Q sample stats, and run acquisition over
# all PRNs. Use this to check whether a file actually acquires (independent of the app).
#
#   julia --project scripts/check_signal.jl [FILE] [FS_MHZ] [INTERM_KHZ]
#
# Defaults: FILE = data/LimeSDR_Bands-L1.int16, FS_MHZ = 10, INTERM_KHZ = 0.
# The file is read as interleaved little-endian Int16 I/Q (the ION .int16 format).

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using GNSSSignals, Acquisition, Unitful, Statistics
using Unitful: Hz, MHz, kHz

function main(args)
    file = get(args, 1, joinpath(@__DIR__, "..", "data", "LimeSDR_Bands-L1.int16"))
    fs = parse(Float64, get(args, 2, "10")) * 1e6 * Hz
    interm = parse(Float64, get(args, 3, "420")) * 1e3 * Hz   # ION LimeSDR IF = 420 kHz
    isfile(file) || error("file not found: $file")

    system = GPSL1CA()
    spc = ceil(Int, get_code_length(system) / get_code_frequency(system) * fs)
    ncoh = 4
    nnc = 5                         # noncoherent accumulations for extra sensitivity
    nsamp = ncoh * nnc * spc        # ~20 ms

    io = open(file)
    raw = Matrix{Complex{Int16}}(undef, nsamp, 1)
    read!(io, raw)
    close(io)
    x = vec(raw)

    re = real.(x); im = imag.(x)
    println("File: ", file, "  ($(round(filesize(file)/1e6; digits=1)) MB)")
    println("Read $(nsamp) samples ($(round(nsamp/ustrip(Hz,fs)*1000; digits=1)) ms) at fs=$(fs), IF=$(interm)")
    println("I: min=$(minimum(re)) max=$(maximum(re)) mean=$(round(mean(re);digits=1)) std=$(round(std(re);digits=1))")
    println("Q: min=$(minimum(im)) max=$(maximum(im)) mean=$(round(mean(im);digits=1)) std=$(round(std(im);digits=1))")
    absmax = maximum(abs, x)
    println("peak |sample| = $absmax  (int16 full-scale = 32767)")
    if abs(mean(re)) > 3 * std(re) || abs(mean(im)) > 3 * std(im)
        println("⚠ large DC offset — data may have a bias or wrong format")
    end
    if std(re) < 1 || std(im) < 1
        println("⚠ near-zero variance — data looks empty/constant (wrong format or offset?)")
    end

    block = ComplexF32.(x)

    # peak/noise is the robust detector (CN0 estimate is inflated at low noise).
    # A real satellite sits well above the ~13–15 noise floor.
    function report(results, label)
        order = sortperm([r.peak_to_noise_ratio for r in results]; rev = true)
        println("\n", label)
        println(rpad("PRN", 5), rpad("peak/noise", 12), rpad("CN0[dBHz]", 12), "Doppler[Hz]")
        best = 0.0
        for i in order[1:min(10, end)]
            r = results[i]
            pn = r.peak_to_noise_ratio
            best = max(best, pn)
            mark = pn >= 25 ? "  ← DETECTED" : ""
            println(rpad(r.prn, 5), rpad(round(pn; digits = 1), 12),
                rpad(round(r.CN0; digits = 1), 12),
                round(Int, ustrip(Hz, r.carrier_doppler)), mark)
        end
        best
    end

    # 1) Normal ±7 kHz search.
    r_norm = acquire(system, block, fs, 1:32; interm_freq = interm,
        num_coherently_integrated_code_periods = ncoh, num_noncoherent_accumulations = nnc)
    b1 = report(r_norm, "Standard search (±7 kHz Doppler, $(ncoh)ms coherent × $(nnc)):")

    # 2) WIDE ±50 kHz Doppler search — catches a carrier/IF offset. The `Doppler[Hz]` of a
    #    detected PRN then reveals the offset (real GPS Doppler is only ±5 kHz).
    r_wide = acquire(system, block, fs, 1:32; interm_freq = interm,
        num_coherently_integrated_code_periods = ncoh, num_noncoherent_accumulations = nnc,
        min_doppler_coverage = 50_000u"Hz")
    b2 = report(r_wide, "WIDE search (±50 kHz Doppler):")

    println()
    if max(b1, b2) < 25
        println("""
        No satellites detected even with a ±50 kHz search. Next things to try:
          • A different sample rate (the code replica must match the true fs):
              julia --project scripts/check_signal.jl $file 5     # try 5, 20, 2.048, …
          • An IF offset larger than 50 kHz:
              julia --project scripts/check_signal.jl $file $(round(ustrip(MHz,fs);digits=3)) <IF_KHZ>
          • Verify the byte format from the file's .sdrx metadata (signed/LE/interleaved).""")
    elseif b2 >= 25 && b1 < 25
        println("→ Detected only with the WIDE search: the recording has a carrier/IF offset.")
        println("  Read the detected PRN's Doppler above; pass that as the IF to the app/diagnostic.")
    else
        println("→ Satellites detected with the standard search — the file is fine.")
    end
end

main(ARGS)
