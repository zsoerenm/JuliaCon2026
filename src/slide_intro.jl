# Slide 0 — title, speaker, pipeline diagram, and a "streaming" heartbeat that proves
# samples are already flowing (the SDR is warm before any slide needs it).

function render_intro(m::PresentationModel, f::Frame, area::Rect, s)
    buf = f.buffer
    content = render(Block(; title = "JuliaCon 2026", border_style = tstyle(:border),
            title_style = tstyle(:accent, bold = true)), area, buf)
    x = content.x + 2
    y = content.y + 1
    set_string!(buf, x, y, "Real-Time GNSS Positioning with JuliaGNSS",
        tstyle(:title, bold = true); max_x = right(content)); y += 1
    set_string!(buf, x, y, "From SDR Signals to Your Location",
        tstyle(:secondary); max_x = right(content)); y += 2
    set_string!(buf, x, y, "Sören Schönbrod  ·  JuliaGNSS", tstyle(:text); max_x = right(content)); y += 2

    # Pipeline diagram
    set_string!(buf, x, y, "The receiver pipeline:", tstyle(:text_dim); max_x = right(content)); y += 1
    stages = ["Samples", "Acquisition", "Tracking", "Decoding", "PVT"]
    cx = x
    for (i, st) in enumerate(stages)
        label = " " * st * " "
        style = i == 5 ? tstyle(:success, bold = true) : tstyle(:primary, bold = true)
        set_string!(buf, cx, y, "[" * st * "]", style; max_x = right(content))
        cx += length(st) + 2
        if i < length(stages)
            set_string!(buf, cx, y, " → ", tstyle(:text_dim); max_x = right(content))
            cx += 3
        end
    end
    y += 2

    # Streaming heartbeat
    streaming = s.chunk_count > 0
    dots = ("   ", ".  ", ".. ", "...")[mod(m.tick ÷ 8, 4)+1]
    if streaming
        set_string!(buf, x, y, "● streaming live samples$(dots)",
            tstyle(:success, bold = true); max_x = right(content))
        set_string!(buf, x, y + 1, "$(s.chunk_count) chunks received — receiver warming up in the background",
            tstyle(:text_dim); max_x = right(content))
    else
        set_string!(buf, x, y, "○ waiting for the sample stream$(dots)",
            tstyle(:warning); max_x = right(content))
    end
    y += 3
    set_string!(buf, x, y, "Use → to walk through: spectrum · acquisition · tracking · PVT · ecosystem",
        tstyle(:text_dim); max_x = right(content))
    return
end
