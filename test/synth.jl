# Synthesize a short GPS L1 C/A recording (Complex{Int16} interleaved I/Q) with a few
# satellites buried in noise, for headless tests and for running the demo without a
# network download.

using GNSSSignals, Unitful
using Unitful: Hz

"""
    write_synthetic_file(path; fs=10e6u"Hz", seconds=0.06, sats=..., noise_std=8.0, amp=3.0)

Write a synthetic recording with the given satellites `(prn, doppler_Hz, code_phase_chips)`
to `path` as interleaved little-endian Int16 I/Q. Returns the PRNs written.
"""
function write_synthetic_file(path;
    fs = 10.0e6Hz,
    seconds = 0.06,
    sats = [(2, 500.0, 100.0), (5, -1200.0, 3000.0), (7, 2500.0, 7000.0)],
    noise_std = 8.0,
    amp = 4.0,
    scale = 24.0,
)
    system = GPSL1CA()
    code_freq = get_code_frequency(system)
    fsHz = Float64(ustrip(Hz, fs))
    n = round(Int, seconds * fsHz)
    sig = zeros(ComplexF64, n)
    t = collect(0:n-1)
    for (prn, dop, phase) in sats
        code = Float64.(gen_code(n, system, prn, fs, code_freq, phase))
        carrier = cis.(2π .* dop ./ fsHz .* t)
        sig .+= amp .* code .* carrier
    end
    sig .+= noise_std .* (randn(n) .+ im .* randn(n))
    open(path, "w") do io
        buf = Vector{Complex{Int16}}(undef, n)
        @inbounds for i in 1:n
            re = clamp(round(Int, scale * real(sig[i])), -32768, 32767)
            im_ = clamp(round(Int, scale * imag(sig[i])), -32768, 32767)
            buf[i] = Complex{Int16}(re, im_)
        end
        write(io, buf)
    end
    return [s[1] for s in sats]
end
