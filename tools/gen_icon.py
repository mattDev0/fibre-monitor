"""Generate the 1024px iOS app icon: fibre cross-section (cladding ring + glowing core) over a pulse line."""
import sys
from PIL import Image, ImageDraw, ImageFilter

BG_TOP, BG_BOTTOM = (18, 92, 74), (4, 30, 26)
RING, CORE, PULSE = (255, 255, 255), (120, 255, 200), (120, 255, 200)


def render(size=1024):
    S = size * 4
    k = S / 100  # geometry in a 100-unit square
    img = Image.new("RGB", (S, S))
    px = img.load()
    for y in range(S):
        for x in range(S):
            u = (x + y) / (2 * S)
            px[x, y] = tuple(round(BG_TOP[i] + (BG_BOTTOM[i] - BG_TOP[i]) * u) for i in range(3))

    cx, cy = 50 * k, 42 * k
    # soft glow behind the core
    glow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(glow).ellipse([cx - 16 * k, cy - 16 * k, cx + 16 * k, cy + 16 * k], fill=170)
    glow = glow.filter(ImageFilter.GaussianBlur(9 * k))
    img = Image.composite(Image.new("RGB", (S, S), CORE), img, glow)

    d = ImageDraw.Draw(img)
    for r, w, alpha in [(24, 3.2, 255), (16, 2.2, 150)]:
        col = tuple(round(RING[i] * alpha / 255 + BG_TOP[i] * (1 - alpha / 255)) for i in range(3))
        d.ellipse([cx - r * k, cy - r * k, cx + r * k, cy + r * k], outline=col, width=round(w * k))
    d.ellipse([cx - 7 * k, cy - 7 * k, cx + 7 * k, cy + 7 * k], fill=CORE)

    pts = [(22, 80), (38, 80), (42, 73), (48, 88), (53, 76), (56, 80), (78, 80)]
    pts = [(x * k, y * k) for x, y in pts]
    w = round(3.4 * k)
    d.line(pts, fill=PULSE, width=w, joint="curve")
    for x, y in pts:
        d.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=PULSE)
    return img.resize((size, size), Image.LANCZOS)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "AppIcon.png"
    render(int(sys.argv[2]) if len(sys.argv) > 2 else 1024).save(out)
