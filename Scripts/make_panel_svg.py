#!/usr/bin/env python3
"""Draw the MemoryClip panel, 1:1 with Design tokens.

    python3 Scripts/make_panel_svg.py Scripts/panel-icons docs/screenshots/panel.svg
    python3 Scripts/make_panel_svg.py Scripts/panel-icons docs/screenshots/preview.svg preview

The panel and the dropdown show live clipboard contents and cannot be
screenshotted for a public repo, so the illustration is drawn instead. Every
size here is the token PanelView and ClipCardView actually lay out with, from
Sources/MemoryClip/UI/DesignSystem.swift: panel 1080x308, panelTopPadding 10,
topBarHeight 44, card 200 square, cardSpace 16, loose 16, cardHeader 40,
roomy 12, panelFooterHeight 34, Radius.panel 28, Radius.card 16.

The `preview` variant is the same panel with the preview pane open, which is
where the pane lives: PanelView stacks it between the card strip and the
footer, behind a resize handle, so the panel grows by
previewResizeHandleHeight + previewPaneHeight and the footer moves down.
Inside it, PreviewView's own order — the translation over the clip, each on
its own pane at Radius.pane with Space.roomy around and between them.

The source-app icons in Scripts/panel-icons are the real ones, exported at 40px
from the system apps with NSWorkspace.icon(forFile:) — the same call the card
header makes — and embedded as data URIs.
"""
import base64, os, sys

ICONS = sys.argv[1] if len(sys.argv) > 1 else "Scripts/panel-icons"
OUT = sys.argv[2] if len(sys.argv) > 2 else "docs/screenshots/panel.svg"
PREVIEW = (sys.argv[3] if len(sys.argv) > 3 else "panel") == "preview"

M = 40                      # wallpaper margin around the panel
PW = 1080                   # Design.Size.panelWidth
PX, PY = M, M

TOP_PAD, TOPBAR = 10, 44    # panelTopPadding, topBarHeight
CARD, GAP, PADH = 200, 16, 16
HEADER = 40                 # cardHeader
FOOTER_H = 34               # panelFooterHeight
HANDLE_H, PANE_H = 10, 250  # previewResizeHandleHeight, previewPaneHeight
GRIP_W = 36                 # previewResizeGripWidth
ROOMY = 12                  # Space.roomy — the pane's padding, and its gutter
PANE_R = 16                 # Radius.pane

PH = 308 + (HANDLE_H + PANE_H if PREVIEW else 0)    # Design.Size.panelHeight
W, H = PW + 2 * M, PH + 2 * M

CARD_Y = PY + TOP_PAD + TOPBAR + 8          # + Space.normal top padding
HANDLE_Y = CARD_Y + CARD + 12               # + cardBottomPadding
PANE_Y = HANDLE_Y + HANDLE_H
FOOTER_Y = PY + PH - FOOTER_H

# The panes inside the preview take Palette.chrome over the panel, outlined
# with Palette.hairline — the same pair designPane() applies.
PANE_FILL, PANE_FILL_OP = "#ffffff", 0.035
PANE_STROKE, PANE_STROKE_OP = "#ffffff", 0.10

CJK = ("'PingFang SC', 'Hiragino Sans GB', 'Heiti SC', 'Noto Sans SC', "
       "'Source Han Sans SC', sans-serif")

# Colours sampled from the previous real capture, and from Design.Palette.
HEADER_FILL = "#35353a"
BODY_FILL = "#2a2a2d"
SEL_HEADER = "#35496c"
SEL_BODY = "#2d4164"
SEL_BORDER = "#b3c7e8"
LABEL = "#f2f2f7"
SECOND = "#98989d"
ACCENT = "#0a84ff"

# The clip the preview is open on, and the three lines of it the card can
# hold before its own text runs out of card.
ZH = ["本产品保修期为自购买之日起十二个月。",
      "保修不包括人为损坏、进水或未经授权的拆修。",
      "请保留购买凭证，办理保修时需要出示。"]
ZH_EN = ["This product is covered by a twelve-month warranty from the date of purchase.",
         "The warranty does not cover accidental damage, water damage or unauthorised",
         "repairs. Keep your proof of purchase; you will need to show it to claim."]

CLIPS = [
    dict(app="Messages", icon="messages", time="2 minutes ago", selected=True,
         lines=["Dinner Saturday at 8, the", "little place on Rue Lepic.", "Booked under my name."],
         stat="74 characters", key="⌘1"),
    dict(app="Safari", icon="safari", time="9 minutes ago", glyph="text",
         lines=["Rechta algéroise — pour 6 :", "500 g de rechta fraîche, 1",
                "poulet fermier, 4 navets, 2", "courgettes et un bâton de", "cannelle."],
         stat="118 characters · noted", key="⌘2"),
    dict(app="Mail", icon="mail", time="17 minutes ago", glyph="text",
         lines=["Booking confirmed — Hôtel", "Sainte-Anne, 2 nights from", "14 Sep. Ref 8FJ2QK."],
         stat="72 characters · in calendar", key="⌘3"),
    dict(app="Calculator", icon="calculator", time="24 minutes ago", glyph="text",
         lines=["86.40/4"], stat="7 characters", calc="= 21.6", key="⌘4"),
    dict(app="Screenshot", icon="screenshot", time="31 minutes ago", glyph="camera",
         receipt=True, stat="Screenshot · text found", key="⌘5"),
]

# The preview is open on a clip in a language the user does not read, so that
# is the selected card: the pane below is showing this one.
if PREVIEW:
    CLIPS = [
        dict(app="Safari", icon="safari", time="2 minutes ago", selected=True,
             lines=["本产品保修期为自购买之日起", "十二个月。保修不包括人为损",
                    "坏、进水或未经授权的拆修。", "请保留购买凭证，办理保修时",
                    "需要出示。"],
             font=CJK, stat="59 characters", key="⌘1"),
    ] + [c for c in CLIPS if c["app"] != "Safari"]
    # The strip is newest first, so the clip that took the front of it takes
    # the front of the clock too — the one it displaced moves down a slot.
    CLIPS[1]["time"] = "9 minutes ago"
    for n, clip in enumerate(CLIPS):
        clip["selected"] = n == 0
        clip["key"] = f"⌘{n + 1}"

CHIPS = [("All", "#98989d", True), ("Text", "#0a84ff", False), ("Images", "#30d158", False),
         ("Links", "#40c8e0", False), ("Files", "#ff375f", False), ("Colors", "#ff9f0a", False)]


def data_uri(name):
    with open(os.path.join(ICONS, name + "-sm.png"), "rb") as fh:
        return "data:image/png;base64," + base64.b64encode(fh.read()).decode()


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(x, y, s, size, fill, weight=None, anchor=None, family=None, opacity=None):
    a = f' font-size="{size}" fill="{fill}"'
    if weight: a += f' font-weight="{weight}"'
    if anchor: a += f' text-anchor="{anchor}"'
    if family: a += f' font-family="{family}"'
    if opacity: a += f' fill-opacity="{opacity}"'
    return f'<text x="{x}" y="{y}"{a}>{esc(s)}</text>'


def chip_width(label):
    # 12 + dot 7 + 6 + label + 12, label at 11pt medium
    return 37 + len(label) * 6.1


out = [
    f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
    f'viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
    f'font-family="-apple-system, BlinkMacSystemFont, \'SF Pro Text\', \'Helvetica Neue\', Arial, sans-serif">',
    '<defs>',
    '<linearGradient id="wall" x1="0" y1="0" x2="1" y2="1">'
    '<stop offset="0" stop-color="#141a33"/><stop offset="0.5" stop-color="#2a1c3f"/>'
    '<stop offset="1" stop-color="#0d2630"/></linearGradient>',
    '<radialGradient id="g1" cx="0.16" cy="0.1" r="0.6">'
    '<stop offset="0" stop-color="#4c5cff" stop-opacity="0.4"/>'
    '<stop offset="1" stop-color="#4c5cff" stop-opacity="0"/></radialGradient>',
    '<radialGradient id="g2" cx="0.88" cy="0.95" r="0.65">'
    '<stop offset="0" stop-color="#00b8a0" stop-opacity="0.34"/>'
    '<stop offset="1" stop-color="#00b8a0" stop-opacity="0"/></radialGradient>',
    '<radialGradient id="g3" cx="0.68" cy="0.05" r="0.45">'
    '<stop offset="0" stop-color="#ff6fb5" stop-opacity="0.22"/>'
    '<stop offset="1" stop-color="#ff6fb5" stop-opacity="0"/></radialGradient>',
    '<linearGradient id="glass" x1="0" y1="0" x2="0" y2="1">'
    '<stop offset="0" stop-color="#ffffff" stop-opacity="0.14"/>'
    '<stop offset="0.55" stop-color="#ffffff" stop-opacity="0.06"/>'
    '<stop offset="1" stop-color="#ffffff" stop-opacity="0.03"/></linearGradient>',
    '<linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">'
    '<stop offset="0" stop-color="#ffffff" stop-opacity="0.4"/>'
    '<stop offset="0.35" stop-color="#ffffff" stop-opacity="0.12"/>'
    '<stop offset="1" stop-color="#ffffff" stop-opacity="0.07"/></linearGradient>',
    '<filter id="panelShadow" x="-15%" y="-25%" width="130%" height="160%">'
    '<feDropShadow dx="0" dy="16" stdDeviation="20" flood-color="#000" flood-opacity="0.5"/></filter>',
    '<filter id="cardShadow" x="-10%" y="-10%" width="120%" height="120%">'
    '<feDropShadow dx="0" dy="1" stdDeviation="1.5" flood-color="#000" flood-opacity="0.42"/></filter>',
]
# a clip path per card so nothing spills out of the rounded square
for i in range(len(CLIPS)):
    cx = PX + PADH + i * (CARD + GAP)
    out.append(f'<clipPath id="cc{i}"><rect x="{cx}" y="{CARD_Y}" width="{CARD}" height="{CARD}" rx="16"/></clipPath>')
out.append(f'<clipPath id="panelClip"><rect x="{PX}" y="{PY}" width="{PW}" height="{PH}" rx="28"/></clipPath>')
out.append('</defs>')

# ---- desktop behind the glass
out.append(f'<rect width="{W}" height="{H}" fill="url(#wall)"/>')
for g in ("g1", "g2", "g3"):
    out.append(f'<rect width="{W}" height="{H}" fill="url(#{g})"/>')

# ---- the panel: a translucent slab, not a window
out.append(f'<g filter="url(#panelShadow)">')
out.append(f'<rect x="{PX}" y="{PY}" width="{PW}" height="{PH}" rx="28" fill="#0b0b10" fill-opacity="0.55"/>')
out.append(f'<rect x="{PX}" y="{PY}" width="{PW}" height="{PH}" rx="28" fill="url(#glass)"/>')
out.append('</g>')

out.append('<g clip-path="url(#panelClip)">')

# ---- top bar
bar_mid = PY + TOP_PAD + TOPBAR / 2
mx, my = PX + PADH + 6.5, bar_mid
out.append(f'<g fill="none" stroke="{SECOND}" stroke-width="1.5" stroke-linecap="round">'
           f'<circle cx="{mx}" cy="{my - 1}" r="4.6"/>'
           f'<path d="M{mx + 3.4} {my + 2.4} L{mx + 6.6} {my + 5.6}"/></g>')
out.append(text(PX + PADH + 25, bar_mid + 4.5, "Search clips", 13, SECOND))

cx = PX + PADH + 25 + 162
chip_y = bar_mid - 12.5
for label, dot, on in CHIPS:
    w = chip_width(label)
    if on:
        out.append(f'<rect x="{cx}" y="{chip_y}" width="{w:.1f}" height="25" rx="12.5" '
                   f'fill="{ACCENT}" fill-opacity="0.22"/>')
        out.append(f'<rect x="{cx + 0.75}" y="{chip_y + 0.75}" width="{w - 1.5:.1f}" height="23.5" rx="11.75" '
                   f'fill="none" stroke="{ACCENT}" stroke-opacity="0.75" stroke-width="1.5"/>')
    else:
        out.append(f'<rect x="{cx}" y="{chip_y}" width="{w:.1f}" height="25" rx="12.5" '
                   f'fill="#ffffff" fill-opacity="0.055"/>')
        out.append(f'<rect x="{cx + 0.5}" y="{chip_y + 0.5}" width="{w - 1:.1f}" height="24" rx="12" '
                   f'fill="none" stroke="#ffffff" stroke-opacity="0.1"/>')
    out.append(f'<circle cx="{cx + 12 + 3.5}" cy="{bar_mid}" r="3.5" fill="{dot}"/>')
    out.append(text(cx + 12 + 7 + 6, bar_mid + 4, label, 11, LABEL if on else SECOND, weight="500"))
    cx += w + 6

# ---- cards
for i, clip in enumerate(CLIPS):
    x = PX + PADH + i * (CARD + GAP)
    y = CARD_Y
    sel = clip.get("selected", False)
    out.append(f'<g filter="url(#cardShadow)"><g clip-path="url(#cc{i})">')
    out.append(f'<rect x="{x}" y="{y}" width="{CARD}" height="{HEADER}" fill="{SEL_HEADER if sel else HEADER_FILL}"/>')
    out.append(f'<rect x="{x}" y="{y + HEADER}" width="{CARD}" height="{CARD - HEADER}" '
               f'fill="{SEL_BODY if sel else BODY_FILL}"/>')

    # header: app icon, name, time
    out.append(f'<image x="{x + 12}" y="{y + 10}" width="20" height="20" '
               f'xlink:href="{data_uri(clip["icon"])}"/>')
    out.append(text(x + 40, y + 18, clip["app"], 11, LABEL, weight="600"))
    out.append(text(x + 40, y + 31, clip["time"], 10, SECOND))

    # header trailing: pin + trash on the selected card, the kind glyph otherwise
    if sel:
        px_, py_ = x + 154, y + 20
        out.append(f'<g stroke="{SECOND}" stroke-width="1.3" fill="none" stroke-linecap="round" stroke-linejoin="round">'
                   f'<path d="M{px_ - 3.5} {py_ - 5} h7 l-1 6 l2.5 3 h-10 l2.5 -3 z"/>'
                   f'<path d="M{px_} {py_ + 4} v3.5"/></g>')
        tx, ty = x + 176, y + 20
        out.append(f'<g stroke="{SECOND}" stroke-width="1.3" fill="none" stroke-linecap="round" stroke-linejoin="round">'
                   f'<path d="M{tx - 5} {ty - 3.5} h10"/>'
                   f'<path d="M{tx - 2} {ty - 3.5} v-1.6 h4 v1.6"/>'
                   f'<path d="M{tx - 4} {ty - 2} l0.7 7.2 h6.6 l0.7 -7.2"/></g>')
    elif clip.get("glyph") == "camera":
        gx, gy = x + 176, y + 20
        out.append(f'<g stroke="{SECOND}" stroke-width="1.3" fill="none" stroke-linecap="round">'
                   f'<path d="M{gx - 6} {gy - 3} v-2 a1.6 1.6 0 0 1 1.6 -1.6 h2"/>'
                   f'<path d="M{gx + 6} {gy - 3} v-2 a1.6 1.6 0 0 0 -1.6 -1.6 h-2"/>'
                   f'<path d="M{gx - 6} {gy + 3} v2 a1.6 1.6 0 0 0 1.6 1.6 h2"/>'
                   f'<path d="M{gx + 6} {gy + 3} v2 a1.6 1.6 0 0 1 -1.6 1.6 h-2"/>'
                   f'<circle cx="{gx}" cy="{gy}" r="2.4"/></g>')
    else:
        gx, gy = x + 170, y + 15
        out.append(f'<g stroke="{SECOND}" stroke-width="1.3" stroke-linecap="round">'
                   + "".join(f'<path d="M{gx} {gy + n * 3.4} h{ln}"/>' for n, ln in enumerate((12, 7.5, 12, 7.5)))
                   + '</g>')

    # body
    if clip.get("receipt"):
        rw, rh = 150, 112
        rx_, ry_ = x + 12 + (176 - rw) / 2, y + 52
        out.append(f'<rect x="{rx_}" y="{ry_}" width="{rw}" height="{rh}" rx="6" fill="#f4f1ea"/>')
        out.append(text(rx_ + rw / 2, ry_ + 22, "L'ÉPICERIE DU COIN", 8.5, "#3a3a38",
                        weight="700", anchor="middle"))
        rows = [("Pain de campagne", "3,20"), ("Olives de Kabylie", "5,40"),
                ("Semoule fine 1 kg", "2,10"), ("Menthe fraîche", "1,30")]
        for n, (item, price) in enumerate(rows):
            ry = ry_ + 40 + n * 13
            out.append(text(rx_ + 12, ry, item, 8, "#57564f"))
            out.append(text(rx_ + rw - 12, ry, price, 8, "#57564f", anchor="end"))
        out.append(f'<path d="M{rx_ + 12} {ry_ + 96} H{rx_ + rw - 12}" stroke="#c9c5ba" stroke-width="1"/>')
        out.append(text(rx_ + 12, ry_ + 106, "TOTAL", 8.5, "#3a3a38", weight="700"))
        out.append(text(rx_ + rw - 12, ry_ + 106, "12,00 €", 8.5, "#3a3a38", weight="700", anchor="end"))
    else:
        for n, line in enumerate(clip["lines"]):
            out.append(text(x + 12, y + 63 + n * 15, line, 12, LABEL,
                            family=clip.get("font")))

    # card footer: stat line, calc result, keycap
    out.append(text(x + 12, y + 185, clip["stat"], 10, SECOND))
    if clip.get("calc"):
        out.append(text(x + 12 + len(clip["stat"]) * 5.1 + 6, y + 185, clip["calc"], 10, LABEL, weight="600"))
    kw = 21
    out.append(f'<rect x="{x + 188 - kw}" y="{y + 174}" width="{kw}" height="14" rx="4" '
               f'fill="#ffffff" fill-opacity="0.06"/>')
    out.append(f'<rect x="{x + 188 - kw + 0.5}" y="{y + 174.5}" width="{kw - 1}" height="13" rx="3.5" '
               f'fill="none" stroke="#ffffff" stroke-opacity="0.1"/>')
    out.append(text(x + 188 - kw / 2, y + 185, clip["key"], 10, SECOND, weight="600", anchor="middle",
                    family="ui-monospace, SFMono-Regular, Menlo, monospace"))
    out.append('</g>')
    if sel:
        out.append(f'<rect x="{x + 1}" y="{y + 1}" width="{CARD - 2}" height="{CARD - 2}" rx="15" '
                   f'fill="none" stroke="{SEL_BORDER}" stroke-width="2"/>')
    out.append('</g>')

# ---- the preview pane, under a resize handle
#
# Sizes are PreviewView's own: the pane is padded by roomy, the translation
# and the clip are panes of their own with roomy between them, and the clip
# takes whatever the translation leaves — the translation is bounded, the
# clip is what the preview is for.
if PREVIEW:
    grip_y = HANDLE_Y + HANDLE_H / 2 - 1
    out.append(f'<rect x="{PX + PW / 2 - GRIP_W / 2}" y="{grip_y}" width="{GRIP_W}" height="2" '
               f'rx="1" fill="#ffffff" fill-opacity="0.18"/>')

    px_ = PX + ROOMY
    pw_ = PW - 2 * ROOMY
    tr_y = PANE_Y + ROOMY
    tr_h = 96

    def pane(x, y, w, h):
        out.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{PANE_R}" '
                   f'fill="{PANE_FILL}" fill-opacity="{PANE_FILL_OP}"/>')
        out.append(f'<rect x="{x + 0.5}" y="{y + 0.5}" width="{w - 1}" height="{h - 1}" '
                   f'rx="{PANE_R - 0.5}" fill="none" stroke="{PANE_STROKE}" '
                   f'stroke-opacity="{PANE_STROKE_OP}"/>')

    # the translation, over the clip
    pane(px_, tr_y, pw_, tr_h)
    out.append(text(px_ + ROOMY, tr_y + 23, "Chinese, Simplified → English", 11, SECOND))
    for n, line in enumerate(ZH_EN):
        out.append(text(px_ + ROOMY, tr_y + 45 + n * 17.5, line, 13, LABEL))

    # the clip as it was copied
    cl_y = tr_y + tr_h + ROOMY
    cl_h = PANE_H - 2 * ROOMY - tr_h - ROOMY
    pane(px_, cl_y, pw_, cl_h)
    for n, line in enumerate(ZH):
        out.append(text(px_ + ROOMY, cl_y + 27 + n * 28, line, 13.5, LABEL, family=CJK))

# ---- panel footer
fy = FOOTER_Y + FOOTER_H / 2
ax = PX + PADH + 6
out.append(f'<g stroke="{LABEL}" stroke-opacity="0.85" stroke-width="1.2" fill="none" stroke-linejoin="round">'
           f'<rect x="{ax - 6}" y="{fy - 6}" width="10" height="11" rx="2.5"/>'
           f'<circle cx="{ax + 5.5}" cy="{fy - 5}" r="2.6" fill="{LABEL}" fill-opacity="0.85" stroke="none"/></g>')
out.append(text(PX + PADH + 20, fy + 4, "All Apps", 11, LABEL, opacity="0.9"))
out.append(f'<path d="M{PX + PADH + 71} {fy - 1.5} l3.5 3.5 l3.5 -3.5" stroke="{SECOND}" stroke-width="1.3" '
           f'fill="none" stroke-linecap="round" stroke-linejoin="round"/>')

out.append(text(PX + PW - PADH - 34, fy + 4, "8 clips", 11, SECOND, anchor="end"))
tx, ty = PX + PW - PADH - 11, fy
out.append(f'<g stroke="{SECOND}" stroke-width="1.3" fill="none" stroke-linecap="round" stroke-linejoin="round">'
           f'<path d="M{tx - 5.5} {ty - 4} h11"/>'
           f'<path d="M{tx - 2.2} {ty - 4} v-1.8 h4.4 v1.8"/>'
           f'<path d="M{tx - 4.4} {ty - 2.4} l0.8 8 h7.2 l0.8 -8"/></g>')

out.append('</g>')
# rim light on the glass edge, drawn last so nothing paints over it
out.append(f'<rect x="{PX + 0.5}" y="{PY + 0.5}" width="{PW - 1}" height="{PH - 1}" rx="27.5" '
           f'fill="none" stroke="url(#rim)"/>')
out.append('</svg>')

with open(OUT, "w") as fh:
    fh.write("\n".join(out) + "\n")
print(OUT, os.path.getsize(OUT), "bytes")
