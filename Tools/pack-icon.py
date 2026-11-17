#!/usr/bin/env python3
"""Package native-drawn PNG sizes as a modern macOS ICNS (no image libraries)."""
import pathlib
import struct
import sys

source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
entries = [(b'icp4', 'icon_16x16.png'), (b'icp5', 'icon_32x32.png'),
           (b'icp6', 'icon_32x32@2x.png'), (b'ic07', 'icon_128x128.png'),
           (b'ic08', 'icon_256x256.png'), (b'ic09', 'icon_512x512.png'),
           (b'ic10', 'icon_512x512@2x.png')]
chunks = []
for kind, filename in entries:
    data = (source / filename).read_bytes()
    chunks.append(kind + struct.pack('>I', len(data) + 8) + data)
body = b''.join(chunks)
target.write_bytes(b'icns' + struct.pack('>I', len(body) + 8) + body)
