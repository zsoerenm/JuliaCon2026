# QR code rendering for the terminal.
#
# Two Unicode half-blocks per cell, so a 37x37 module matrix (version 3 + the mandatory
# 4-module quiet zone) fits in 37 columns x 19 rows instead of 37x37 — square-ish on a
# terminal grid, where cells are about twice as tall as they are wide.
#
# Colours are set explicitly to BLACK ON WHITE rather than inherited from the terminal
# theme. A QR code drawn light-on-dark is inverted, and while some scanners cope, plenty
# do not — and this one has to work from the back of a conference room, once, on the
# first try.

using QRCoders: qrcode, Low

const QR_DARK = Style(fg = ColorRGB(0x00, 0x00, 0x00), bg = ColorRGB(0xff, 0xff, 0xff))

# Glyph for a (top, bottom) module pair. `true` = dark module. Foreground is black and
# background white, so the *unset* half shows through as white.
_qr_glyph(top::Bool, bot::Bool) = top ? (bot ? '█' : '▀') : (bot ? '▄' : ' ')

"""
    qr_matrix(text) -> BitMatrix

Encode `text` at error-correction level `Low` (the largest payload per version — this is
a screen at close range, not a label on a crate). `true` is a dark module; the quiet zone
is included.
"""
qr_matrix(text::AbstractString) = qrcode(text; eclevel = Low())

"""
    qr_size(m) -> (width, height)

Terminal cells needed to draw matrix `m` with half-blocks.
"""
qr_size(m) = (size(m, 2), cld(size(m, 1), 2))

"""
    draw_qr!(buf, x, y, m; max_x, max_y)

Draw QR matrix `m` with its top-left module at `(x, y)`, clipped to `max_x`/`max_y`.
Rows are consumed in pairs. An odd final row is drawn as a top-half only, which keeps its
lower half white — that lands in the quiet zone, so no module is lost.
"""
function draw_qr!(buf, x::Int, y::Int, m; max_x::Int, max_y::Int)
    nrows, ncols = size(m)
    for (row, r) in enumerate(1:2:nrows)
        yy = y + row - 1
        yy > max_y && break
        for col in 1:ncols
            xx = x + col - 1
            xx > max_x && break
            top = m[r, col]
            bot = r + 1 <= nrows ? m[r+1, col] : false
            set_char!(buf, xx, yy, _qr_glyph(top, bot), QR_DARK)
        end
    end
    return
end
