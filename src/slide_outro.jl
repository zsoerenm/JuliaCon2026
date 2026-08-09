# Slide 6 — the JuliaGNSS ecosystem and closing.

# (module, name, one-line description). The version is read from the loaded package at
# render time (via `pkgversion`) so it's always accurate rather than hard-coded.
const ECOSYSTEM = [
    (GNSSSignals, "GNSSSignals.jl", "PRN codes & signal definitions (GPS, Galileo, …)"),
    (Acquisition, "Acquisition.jl", "FM-DBZP acquisition — find satellites in noise"),
    (Tracking, "Tracking.jl", "PLL/DLL carrier & code tracking loops"),
    (GNSSDecoder, "GNSSDecoder.jl", "navigation message & ephemeris decoding"),
    (PositionVelocityTime, "PositionVelocityTime.jl", "PVT solution from pseudoranges"),
    (SignalChannels, "SignalChannels.jl", "SDR streaming (SoapySDR) & signal plumbing"),
    (GNSSReceiver, "GNSSReceiver.jl", "the full receiver: acquire → track → decode → PVT"),
]

_pkgver(mod) = try
    "v" * string(pkgversion(mod))
catch
    ""
end

function render_outro(m::PresentationModel, f::Frame, area::Rect, s)
    buf = f.buffer
    content = render(Block(; title = "The JuliaGNSS ecosystem — all past their v1.0 milestone",
            border_style = tstyle(:border), title_style = tstyle(:accent, bold = true)),
        area, buf)
    x = content.x + 2
    y = content.y + 1
    # Close the frame the title slide opened.
    set_string!(buf, x, y, "We started with Int16 samples and a sample rate.",
        tstyle(:text_dim); max_x = right(content)); y += 1
    set_string!(buf, x, y, "We ended with a position on a map — and the time to within nanoseconds.",
        tstyle(:secondary, bold = true); max_x = right(content)); y += 2
    set_string!(buf, x, y, "Composable, pure-Julia packages — stable and production ready:",
        tstyle(:text); max_x = right(content)); y += 2
    for (mod, name, desc) in ECOSYSTEM
        set_string!(buf, x, y, "• " * name, tstyle(:primary, bold = true); max_x = right(content))
        set_string!(buf, x + 27, y, _pkgver(mod), tstyle(:secondary, bold = true); max_x = right(content))
        set_string!(buf, x + 35, y, desc, tstyle(:text_dim); max_x = right(content))
        y += 1
    end
    y += 1
    set_string!(buf, x, y, "Next: Galileo E1/E5a alongside GPS, multi-antenna arrays, and more live hardware.",
        tstyle(:text); max_x = right(content)); y += 1
    set_string!(buf, x, y, "Issues, PRs and recordings all welcome — it is a small ecosystem and it is open.",
        tstyle(:text_dim); max_x = right(content)); y += 2
    set_string!(buf, x, y, "github.com/JuliaGNSS      Thank you!  ·  Questions?",
        tstyle(:success, bold = true); max_x = right(content))
    return
end
