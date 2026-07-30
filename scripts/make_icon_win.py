"""Render Packaging/Wend.ico from Packaging/Wend.icns — the Windows half of make_icon.sh.

The icns is the single source of the artwork for both platforms, so the Windows icon can't
drift from the Mac one: it is downsampled from the same 1024x1024 render that
scripts/icon_render.swift produces, not drawn a second time. Regenerate it after editing
icon_render.swift, the same way make_icon.sh regenerates the icns.

Only the built Wend.ico is committed, matching how Wend.icns is handled.

    python scripts/make_icon_win.py [icns] [ico]

Needs Pillow (`pip install Pillow`).
"""

import sys

from PIL import Image

# The sizes Windows actually asks for: 16 in the notification area and small Explorer
# views, 32 on the desktop and in Alt-Tab, 48 in medium-icon view, 256 for the extra-large
# views. 24/64/128 fill in the scaling steps so a HiDPI shell never has to stretch a badly
# mismatched size — the stamped exe is checked for exactly these.
SIZES = [16, 24, 32, 48, 64, 128, 256]


def main() -> int:
    icns = sys.argv[1] if len(sys.argv) > 1 else "Packaging/Wend.icns"
    ico = sys.argv[2] if len(sys.argv) > 2 else "Packaging/Wend.ico"

    source = Image.open(icns).convert("RGBA")
    if source.size != (1024, 1024):
        print(f"expected a 1024x1024 icns, got {source.size}", file=sys.stderr)
        return 1

    # Pillow's ICO writer only emits sizes no larger than the image it is saving, so this
    # has to be driven from the full-size render. The frames are pre-resized rather than
    # left to it: it uses `thumbnail`, and at 16px the double-chevron is a few pixels of
    # stroke that a cheaper filter turns to mush.
    frames = [source.resize((n, n), Image.LANCZOS) for n in SIZES]
    source.save(ico, format="ICO", sizes=[(n, n) for n in SIZES], append_images=frames)

    print(f"wrote {ico}  sizes={SIZES}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
