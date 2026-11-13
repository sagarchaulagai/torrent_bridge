"""Generate Android launcher icons from assets/icon.svg using resvg_py."""

from pathlib import Path
import resvg_py
from PIL import Image
import io

ROOT = Path(__file__).resolve().parent.parent
SVG_PATH = ROOT / "assets" / "icon.svg"
RES_DIR = ROOT / "android" / "app" / "src" / "main" / "res"

MIPMAP_SIZES = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

# Adaptive icon foreground sizes (108dp base)
ADAPTIVE_FG_SIZES = {
    "drawable-mdpi": 108,
    "drawable-hdpi": 162,
    "drawable-xhdpi": 216,
    "drawable-xxhdpi": 324,
    "drawable-xxxhdpi": 432,
}


def render_svg_to_png(svg_str: str, size: int) -> bytes:
    png_bytes = resvg_py.svg_to_bytes(
        svg_string=svg_str,
        width=size,
        height=size,
    )
    return bytes(png_bytes)


def build_foreground_svg(svg_str: str) -> str:
    """Create a transparent-background version of icon.svg scaled into the 108dp safe zone."""
    # Original viewBox is 512x512; adaptive icon safe zone is ~66/108 (61%) of the 108dp canvas.
    # Scaling the artwork by 0.68 centered in 512x512 keeps it comfortably inside the safe zone.
    return """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
  <defs>
    <linearGradient id="play" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#FFFFFF"/>
      <stop offset="100%" stop-color="#FFE3C7"/>
    </linearGradient>
    <filter id="drop" x="-30%" y="-30%" width="160%" height="170%">
      <feDropShadow dx="0" dy="10" stdDeviation="11" flood-color="#8A2900" flood-opacity=".5"/>
    </filter>
    <filter id="dropSoft" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0" dy="5" stdDeviation="6" flood-color="#8A2900" flood-opacity=".35"/>
    </filter>
  </defs>
  <g transform="translate(256 256) scale(0.72) translate(-256 -256)">
    <g transform="translate(-16 0)">
      <path d="M170 170 L170 342 L300 256 Z"
            fill="url(#play)" stroke="url(#play)" stroke-width="28"
            stroke-linejoin="round" filter="url(#drop)"/>
      <g fill="none" stroke="#FFFFFF" stroke-width="22" stroke-linecap="round"
         filter="url(#dropSoft)">
        <path d="M344.4 218.7 A58 58 0 0 1 344.4 293.3" opacity=".95"/>
        <path d="M376.6 191.7 A100 100 0 0 1 376.6 320.3" opacity=".6"/>
      </g>
    </g>
  </g>
</svg>
"""


def main() -> None:
    svg_str = SVG_PATH.read_text(encoding="utf-8")

    # 1. Legacy mipmap ic_launcher.png files
    for folder, size in MIPMAP_SIZES.items():
        out_dir = RES_DIR / folder
        out_dir.mkdir(parents=True, exist_ok=True)
        out_path = out_dir / "ic_launcher.png"
        png_bytes = render_svg_to_png(svg_str, size)
        out_path.write_bytes(png_bytes)
        with Image.open(io.BytesIO(png_bytes)) as img:
            print(f"Wrote {out_path.relative_to(ROOT)} ({img.size[0]}x{img.size[1]}, {img.mode})")

    # 2. Adaptive icon foreground PNGs
    fg_svg = build_foreground_svg(svg_str)
    for folder, size in ADAPTIVE_FG_SIZES.items():
        out_dir = RES_DIR / folder
        out_dir.mkdir(parents=True, exist_ok=True)
        out_path = out_dir / "ic_launcher_foreground.png"
        png_bytes = render_svg_to_png(fg_svg, size)
        out_path.write_bytes(png_bytes)
        with Image.open(io.BytesIO(png_bytes)) as img:
            print(f"Wrote {out_path.relative_to(ROOT)} ({img.size[0]}x{img.size[1]}, {img.mode})")


if __name__ == "__main__":
    main()
