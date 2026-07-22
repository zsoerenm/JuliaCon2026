# Slide 2 — acquisition. Left: a live 32-PRN search bar (CN0 per PRN); detected PRNs are
# green, the cursor/selected PRN highlighted. Right: the 3D correlation surface of the
# selected PRN (sixel/kitty; braille fallback). Only the selected PRN gets store_power_bins.

const CN0_LO = 40.0    # acquisition-time noise floor sits ~40 dBHz; sats rise above it
const CN0_HI = 54.0
const SPINNER = collect("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

function render_acquisition(m::PresentationModel, f::Frame, area::Rect, s)
    buf = f.buffer
    cols = split_layout(Layout(Horizontal, [Percent(42), Fill()]), area)
    left, rightp = cols[1], cols[2]

    # ── Left: per-PRN CN0 bars ──
    ndet = length(s.detected)
    spin = s.acquiring ? SPINNER[mod(m.tick ÷ 3, 10)+1] : ' '
    lc = render(Block(; title = "Acquisition search  $(spin)  ($ndet/32 detected)",
            border_style = tstyle(:border), title_style = tstyle(:accent, bold = true)),
        left, buf)
    if isempty(s.acq_results)
        set_string!(buf, lc.x + 2, lc.y + 1, "Acquiring…", tstyle(:text_dim); max_x = right(lc))
    else
        cn0 = fill(NaN, 32)
        for r in s.acq_results
            1 <= r.prn <= 32 && (cn0[r.prn] = r.CN0)
        end
        plot_h = lc.height - 2                      # leave a row for axis labels
        baseline = lc.y + plot_h
        avail_w = lc.width - 2
        step = max(1, avail_w ÷ 32)
        selected = s.selected_prn
        cursor_prn = ndet > 0 ? s.detected[clamp(s.cursor, 1, ndet)] : nothing
        for p in 1:32
            x = lc.x + 1 + (p - 1) * step
            x > right(lc) && break
            v = cn0[p]
            det = p in s.detected               # CFAR detection from the receiver-grade test
            z = isnan(v) ? 0.0 : clamp((v - CN0_LO) / (CN0_HI - CN0_LO), 0.0, 1.0)
            h = round(Int, z * (plot_h - 1))
            style = if p == selected
                tstyle(:accent, bold = true)
            elseif det
                tstyle(:success)
            else
                tstyle(:text_dim, dim = true)
            end
            for r in 0:h
                set_char!(buf, x, baseline - r, '█', style)
            end
            # cursor marker under the bar
            if p == cursor_prn
                set_char!(buf, x, baseline + 1, '▲', tstyle(:accent, bold = true))
            end
        end
        set_string!(buf, lc.x + 1, bottom(lc),
            "PRN 1……………………………………32   CN0 $(round(Int,CN0_LO))–$(round(Int,CN0_HI)) dBHz",
            tstyle(:text_dim); max_x = right(lc))
    end

    # ── Right: correlation heatmap of the selected PRN ──
    mode = s.acq_zoom ? "zoom" : "full code"
    title = s.selected_prn === nothing ? "Correlation surface ($mode)" :
            "Correlation surface — PRN $(s.selected_prn) ($mode)"
    rc = render(Block(; title = title, border_style = tstyle(:border),
            title_style = tstyle(:accent, bold = true)), rightp, buf)
    if s.surface === nothing
        msg = s.selected_prn === nothing ? "Select a detected PRN (↑/↓, Enter)" :
              "Computing surface for PRN $(s.selected_prn)…"
        set_string!(buf, rc.x + 2, rc.y + 1, msg, tstyle(:text_dim); max_x = right(rc))
    else
        # Colored isometric ridge surface drawn straight into the buffer (no sixel).
        surfarea = Rect(rc.x, rc.y, rc.width, rc.height - 1)
        draw_acq_surface!(buf, surfarea, s.surface)
        set_string!(buf, rc.x + 1, bottom(rc),
            "power over Doppler × code-phase — peak = the satellite",
            tstyle(:text_dim); max_x = right(rc))
    end
    return
end
