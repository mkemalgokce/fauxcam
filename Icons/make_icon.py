#!/usr/bin/env python3
"""Generate the FauxCam app icon and menubar template as SVG.

Concept: a camera aperture (the lens = what FauxCam does) wearing two pointed
fox ears (faux ~ fox). One mark, two meanings, legible down to 16px.

Outputs to stdout:
  --kind app       full-color rounded-square app tile
  --kind template  monochrome black-on-transparent menubar glyph
"""
import argparse
import math

CANVAS = 1024
CENTER_X = 512.0
APERTURE_CENTER_Y = 566.0
LENS_OUTER_RADIUS = 208.0
APERTURE_OPENING_RADIUS = 80.0
BLADE_COUNT = 6
BLADE_SWIRL_DEGREES = 40.0
SEAM_STROKE_WIDTH = 16.0


def aperture_mask_geometry():
    """Hexagon opening polygon points and blade seam line segments."""
    opening_points = []
    seam_segments = []
    swirl = math.radians(BLADE_SWIRL_DEGREES)
    for blade_index in range(BLADE_COUNT):
        vertex_angle = math.radians(60.0 * blade_index - 90.0)
        vertex_x = CENTER_X + APERTURE_OPENING_RADIUS * math.cos(vertex_angle)
        vertex_y = APERTURE_CENTER_Y + APERTURE_OPENING_RADIUS * math.sin(vertex_angle)
        opening_points.append((vertex_x, vertex_y))

        outer_x = CENTER_X + LENS_OUTER_RADIUS * math.cos(vertex_angle + swirl)
        outer_y = APERTURE_CENTER_Y + LENS_OUTER_RADIUS * math.sin(vertex_angle + swirl)
        seam_segments.append(((vertex_x, vertex_y), (outer_x, outer_y)))
    return opening_points, seam_segments


def aperture_mask(mask_id):
    opening_points, seam_segments = aperture_mask_geometry()
    polygon = " ".join(f"{x:.2f},{y:.2f}" for x, y in opening_points)
    seams = "".join(
        f'<line x1="{a[0]:.2f}" y1="{a[1]:.2f}" x2="{b[0]:.2f}" y2="{b[1]:.2f}" '
        f'stroke="black" stroke-width="{SEAM_STROKE_WIDTH}" stroke-linecap="round"/>'
        for a, b in seam_segments
    )
    return (
        f'<mask id="{mask_id}">'
        f'<rect width="{CANVAS}" height="{CANVAS}" fill="white"/>'
        f'<polygon points="{polygon}" fill="black"/>'
        f"{seams}"
        f"</mask>"
    )


def ears(fill, inner_fill=None):
    """Two broad fox ears leaning outward from behind the lens."""
    left = f'<polygon points="332,232 476,386 296,402" fill="{fill}"/>'
    right = f'<polygon points="692,232 728,402 548,386" fill="{fill}"/>'
    inner = ""
    if inner_fill is not None:
        inner_left = f'<polygon points="358,288 437,372 340,378" fill="{inner_fill}"/>'
        inner_right = f'<polygon points="666,288 684,378 587,372" fill="{inner_fill}"/>'
        inner = inner_left + inner_right
    return left + right + inner


def glyph(fill, mask_id, inner_fill=None):
    lens = (
        f'<circle cx="{CENTER_X}" cy="{APERTURE_CENTER_Y}" r="{LENS_OUTER_RADIUS}" '
        f'fill="{fill}" mask="url(#{mask_id})"/>'
    )
    return ears(fill, inner_fill) + lens


def app_icon():
    mask_id = "aperture"
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" viewBox="0 0 {CANVAS} {CANVAS}">
  <defs>
    <linearGradient id="tile" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FF8A4C"/>
      <stop offset="1" stop-color="#E8521F"/>
    </linearGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.22"/>
      <stop offset="0.45" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="18" stdDeviation="22" flood-color="#000000" flood-opacity="0.22"/>
    </filter>
    {aperture_mask(mask_id)}
  </defs>
  <g filter="url(#shadow)">
    <rect x="100" y="100" width="824" height="824" rx="185" fill="url(#tile)"/>
    <rect x="100" y="100" width="824" height="824" rx="185" fill="url(#sheen)"/>
  </g>
  {glyph("#FFFFFF", mask_id, inner_fill="#F0683A")}
</svg>'''


def template_icon():
    mask_id = "aperture"
    crop_x, crop_y, crop_w, crop_h = 270, 206, 484, 596
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{crop_w}" height="{crop_h}" viewBox="{crop_x} {crop_y} {crop_w} {crop_h}">
  <defs>
    {aperture_mask(mask_id)}
  </defs>
  {glyph("#000000", mask_id)}
</svg>'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--kind", choices=["app", "template"], required=True)
    args = parser.parse_args()
    print(app_icon() if args.kind == "app" else template_icon())


if __name__ == "__main__":
    main()
