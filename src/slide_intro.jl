# Slide 0 — the frame. Three clocks set the pace of the whole talk, and the receiver is
# established as knowing nothing at all, so the position at the end has to be earned.
# The pipeline diagram lives in the persistent header now (`_render_pipeline!`), so this
# slide spends its space on the story instead of repeating it.

# (label, value, what it means). The antagonists, in the order they bite.
const CLOCKS = (
    ("50 bit/s", "what the satellites send.", "Nothing can make it faster — we wait."),
    ("10 MSPS", "what the antenna delivers.", "Fall behind once and it is over."),
    ("12 minutes", "what I have.", "All three have to fit in this talk."),
)

# Encoded once, at precompile time, and baked into the cache — the matrix never changes.
const GNSSRECEIVER_URL = "https://github.com/JuliaGNSS/GNSSReceiver.jl"
const GNSSRECEIVER_QR = qr_matrix(GNSSRECEIVER_URL)

function render_intro(m::PresentationModel, f::Frame, area::Rect, s)
    buf = f.buffer
    content = render(Block(; title = "JuliaCon 2026", border_style = tstyle(:border),
            title_style = tstyle(:accent, bold = true)), area, buf)
    x = content.x + 2
    y = content.y + 1

    # QR to GNSSReceiver.jl, parked in the right margin. Drawn first so the text below can
    # clip against it rather than run underneath.
    qrw, qrh = qr_size(GNSSRECEIVER_QR)
    textmax = right(content)
    if content.width >= qrw + 46 && content.height >= qrh + 3
        qrx = right(content) - qrw
        qry = content.y + 1
        draw_qr!(buf, qrx, qry, GNSSRECEIVER_QR; max_x = right(content), max_y = bottom(content))
        cap = "GNSSReceiver.jl"
        set_string!(buf, qrx + max(0, (qrw - length(cap)) ÷ 2), qry + qrh + 1, cap,
            tstyle(:primary, bold = true); max_x = right(content))
        set_string!(buf, qrx + max(0, (qrw - length("github.com/JuliaGNSS")) ÷ 2), qry + qrh + 2,
            "github.com/JuliaGNSS", tstyle(:text_dim); max_x = right(content))
        textmax = qrx - 3
    end
    set_string!(buf, x, y, "Real-Time GNSS Positioning with JuliaGNSS",
        tstyle(:title, bold = true); max_x = right(content)); y += 1
    set_string!(buf, x, y, "From SDR Signals to Your Location",
        tstyle(:secondary); max_x = right(content)); y += 2
    set_string!(buf, x, y, "Sören Schönbrod  ·  JuliaGNSS", tstyle(:text); max_x = right(content)); y += 2

    # What the receiver is given — i.e. almost nothing.
    set_string!(buf, x, y, "This receiver is handed a stream of Int16 numbers and a sample rate.",
        tstyle(:text); max_x = right(content)); y += 1
    set_string!(buf, x, y, "Not the time. Not the place. No almanac. Nothing else.",
        tstyle(:text_dim); max_x = right(content)); y += 2

    # The three clocks.
    set_string!(buf, x, y, "Three clocks decide how this goes:", tstyle(:text); max_x = right(content))
    y += 1
    for (label, what, why) in CLOCKS
        y > bottom(content) - 3 && break
        set_string!(buf, x + 2, y, rpad(label, 12), tstyle(:primary, bold = true); max_x = right(content))
        set_string!(buf, x + 15, y, rpad(what, 27), tstyle(:text); max_x = right(content))
        set_string!(buf, x + 43, y, why, tstyle(:text_dim); max_x = right(content))
        y += 1
    end
    y += 1

    # Streaming heartbeat — the samples are already flowing before any slide needs them.
    streaming = s.chunk_count > 0
    dots = ("   ", ".  ", ".. ", "...")[mod(m.tick ÷ 8, 4)+1]
    if streaming
        set_string!(buf, x, y, "● streaming live samples$(dots)",
            tstyle(:success, bold = true); max_x = right(content))
        set_string!(buf, x, y + 1, "$(s.chunk_count) chunks received — the receiver itself does not start until we reach Decoding",
            tstyle(:text_dim); max_x = right(content))
    else
        set_string!(buf, x, y, "○ waiting for the sample stream$(dots)",
            tstyle(:warning); max_x = right(content))
    end
    y += 3
    y > bottom(content) && return
    set_string!(buf, x, y, "By the end: a position, and the time to within nanoseconds. Earned on stage.",
        tstyle(:secondary, bold = true); max_x = right(content))
    return
end
