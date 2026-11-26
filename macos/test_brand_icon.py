import json
import struct
import tempfile
import unittest
from pathlib import Path
from prepare_platform import (
    _replace_xcassets_icons,
    _write_windows_ico,
    IOS_ICON,
    LOGO_MARK,
    MACOS_ICON_DIR,
    OPAQUE_ICON,
)


class BrandIconChecks(unittest.TestCase):
    def test_native_sizes_and_transparent_png_entries(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'app.ico'
            _write_windows_ico(target, LOGO_MARK)
            data = target.read_bytes()
            self.assertEqual(struct.unpack_from('<HHH', data), (0, 1, 9))
            sizes = []
            for n in range(9):
                w, h, _, _, planes, bits, length, offset = struct.unpack_from('<BBBBHHII', data, 6 + n * 16)
                sizes.append(w or 256)
                self.assertEqual(w, h)
                self.assertEqual((planes, bits), (1, 32))
                png = data[offset:offset + length]
                self.assertEqual(png[:8], b'\x89PNG\r\n\x1a\n')
                self.assertEqual(struct.unpack_from('>II', png, 16), (w or 256, h or 256))
                self.assertEqual(png[25], 6)  # RGBA, not an opaque RGB square.
            self.assertEqual(sizes, [16, 20, 24, 32, 40, 48, 64, 128, 256])

    def test_apple_and_mark_brand_masters(self):
        # iOS icon master and fallback must be opaque RGB (PNG color type 2).
        for path, expected_size in ((IOS_ICON, (1024, 1024)), (OPAQUE_ICON, (512, 512))):
            data = path.read_bytes()
            self.assertEqual(data[:8], b'\x89PNG\r\n\x1a\n')
            self.assertEqual(struct.unpack_from('>II', data, 16), expected_size)
            self.assertEqual(data[25], 2)

        # In-app mark must be transparent RGBA 1254x1254.
        mark = LOGO_MARK.read_bytes()
        self.assertEqual(struct.unpack_from('>II', mark, 16), (1254, 1254))
        self.assertEqual(mark[25], 6)

        # macOS optical iconset maps exact slots via Contents.json without downscaling loss.
        with tempfile.TemporaryDirectory() as directory:
            iconset = Path(directory) / 'AppIcon.appiconset'
            iconset.mkdir()
            stub_png = (MACOS_ICON_DIR / 'icon_16x16.png').read_bytes()
            (iconset / 'app_icon_16.png').write_bytes(stub_png)
            (iconset / 'app_icon_32.png').write_bytes((MACOS_ICON_DIR / 'icon_32x32.png').read_bytes())
            (iconset / 'Contents.json').write_text(json.dumps({
                'images': [
                    {'filename': 'app_icon_16.png', 'scale': '1x', 'size': '16x16'},
                    {'filename': 'app_icon_32.png', 'scale': '2x', 'size': '16x16'},
                ]
            }), encoding='utf-8')
            _replace_xcassets_icons(iconset, MACOS_ICON_DIR)
            self.assertEqual(
                (iconset / 'app_icon_32.png').read_bytes(),
                (MACOS_ICON_DIR / 'icon_16x16@2x.png').read_bytes(),
            )


if __name__ == '__main__':
    unittest.main()
