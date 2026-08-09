# Slide 7 — why Julia. The argument is made from this repository rather than from a
# benchmark table: everything on this slide is a line of code that had to exist for the
# previous six slides to work, and none of it required forking a package.

# (headline, evidence lines). Kept as data so the slide stays a slide and not a wall.
const JULIA_POINTS = (
    ("Extend a package from the outside",
        ("src/triangle_correlator.jl defines a many-tap correlator — 120 lines, in *this* repo:",
            "    struct TriangleCorrelator <: AbstractEarlyPromptLateCorrelator …",
            "Tracking.jl has never heard of it, and tracks with it at full speed.")),
    ("Reach inside without forking",
        ("The decoding slide reads the live navigation decoder through one closure:",
            "    receive(chan, system, fs; extract = nav_data_of_interest)",
            "No plugin API, no patch — the channel's element type follows the function.")),
    ("One language all the way down",
        ("10 MSPS from one stream, fanned out to four consumers, no C in the hot loop.",
            "    Complex{Int16} samples → Tracking's integer backend, chosen by dispatch",
            "The same source code runs on a recording and on the SDR on this desk.")),
)

function render_julia(m::PresentationModel, f::Frame, area::Rect, s)
    buf = f.buffer
    c = render(Block(; title = "Why Julia — the evidence is this repository",
            border_style = tstyle(:border), title_style = tstyle(:accent, bold = true)),
        area, buf)
    (c.width < 40 || c.height < 12) && return
    x = c.x + 2
    y = c.y + 1

    for (headline, lines) in JULIA_POINTS
        y > bottom(c) - 2 && break
        set_string!(buf, x, y, "▸ " * headline, tstyle(:primary, bold = true); max_x = right(c))
        y += 1
        for l in lines
            y > bottom(c) - 1 && break
            # Indented lines are code; everything else is prose.
            style = startswith(l, "    ") ? tstyle(:secondary) : tstyle(:text_dim)
            set_string!(buf, x + 2, y, l, style; max_x = right(c))
            y += 1
        end
        y += 1
    end

    y = min(y, bottom(c) - 1)
    set_string!(buf, x, y,
        "…and 3 s from `julia run.jl` to the first frame, because the compile workload is in the cache.",
        tstyle(:text_dim); max_x = right(c))
    y += 1
    set_string!(buf, x, y,
        "Composable enough to prototype in, fast enough to keep up with the antenna.",
        tstyle(:success, bold = true); max_x = right(c))
    return
end
