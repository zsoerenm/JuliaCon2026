# Slide 1 — live power spectrum (periodogram) of the incoming samples. The GPS signals
# sit BELOW the noise floor, so this looks essentially flat.
#
# This is the talk's cold open, and the flatness IS the content: "I promised you a GPS
# receiver — here is the signal, and there is no signal." So the caption states the fact
# and then poses the question the rest of the talk answers, rather than explaining it
# away. Two rows, because the question has to read from the back of the room.

function render_spectrum(m::PresentationModel, f::Frame, area::Rect, s)
    buf = f.buffer
    pg = s.periodogram
    block = Block(; title = "Power spectral density [dB] — live", border_style = tstyle(:border),
        title_style = tstyle(:accent, bold = true))
    if pg === nothing
        content = render(block, area, buf)
        set_string!(buf, content.x + 2, content.y + 1, "Waiting for the sample stream…",
            tstyle(:text_dim); max_x = right(content))
        return
    end
    freqs_mhz = Float64.(pg.freqs) ./ 1e6      # PeriodogramData.freqs are plain Hz
    powers = Float64.(pg.powers)
    # Downsample to keep the chart light and smooth
    n = length(powers)
    step = max(1, n ÷ 600)
    xs = freqs_mhz[1:step:end]
    ys = powers[1:step:end]
    data = collect(zip(Float64.(xs), Float64.(ys)))
    # Sliding-window min/max (from the model) so the y-axis is stable yet adapts to
    # recent conditions; fall back to the current frame's extent until it has accumulated.
    ylo = isfinite(s.pg_ymin) ? s.pg_ymin : minimum(ys)
    yhi = isfinite(s.pg_ymax) ? s.pg_ymax : maximum(ys)
    pad = max(1.0, (yhi - ylo) * 0.05)
    # Reserve two rows for the caption so it doesn't overwrite the chart's x-axis labels.
    rows = split_layout(Layout(Vertical, [Fill(), Fixed(2)]), area)
    chartarea, noterow = rows[1], rows[2]
    chart = Chart([DataSeries(data; label = "PSD [dB]", style = tstyle(:primary))];
        block = block, x_label = "Frequency [MHz]", y_label = "",
        y_bounds = (ylo - pad, yhi + pad), show_legend = false)
    render(chart, chartarea, buf)
    set_string!(buf, noterow.x + 2, noterow.y,
        "Ten satellites are in this picture. Every one of them is ~18 dB under that noise floor.",
        tstyle(:text_dim); max_x = right(noterow))
    set_string!(buf, noterow.x + 2, noterow.y + 1,
        "So: how do you receive something that is quieter than the silence?",
        tstyle(:accent, bold = true); max_x = right(noterow))
    return
end
