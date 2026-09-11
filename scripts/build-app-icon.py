#!/usr/bin/env python3
"""Build Snake's ICNS container from the standard PNG iconset."""

from pathlib import Path
import struct


PROJECT_DIR = Path(__file__).resolve().parent.parent
ICONSET_DIR = PROJECT_DIR / "Resources" / "AppIcon.iconset"
OUTPUT_PATH = PROJECT_DIR / "Resources" / "AppIcon.icns"

ICON_ENTRIES = (
    (b"icp4", "icon_16x16.png"),
    (b"ic11", "icon_16x16@2x.png"),
    (b"icp5", "icon_32x32.png"),
    (b"ic12", "icon_32x32@2x.png"),
    (b"ic07", "icon_128x128.png"),
    (b"ic13", "icon_128x128@2x.png"),
    (b"ic08", "icon_256x256.png"),
    (b"ic14", "icon_256x256@2x.png"),
    (b"ic09", "icon_512x512.png"),
    (b"ic10", "icon_512x512@2x.png"),
)


def make_chunk(kind: bytes, payload: bytes) -> bytes:
    return kind + struct.pack(">I", len(payload) + 8) + payload


def main() -> None:
    chunks = [
        make_chunk(kind, (ICONSET_DIR / filename).read_bytes())
        for kind, filename in ICON_ENTRIES
    ]
    body = b"".join(chunks)
    OUTPUT_PATH.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)


if __name__ == "__main__":
    main()
