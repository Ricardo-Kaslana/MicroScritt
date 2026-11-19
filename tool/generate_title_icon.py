#!/usr/bin/env python3
"""生成 Windows 标题栏图标(亮/暗双态)。

标题栏图标与应用图标(app_icon.ico)分离:应用图标保留浅灰方底,标题栏只用
透明底的品牌胶囊。Windows 标题栏底色跟随系统主题,深色胶囊在暗色标题栏上
几乎不可见,因此输出亮色/暗色两套胶囊底色,由 runner 按当前主题二选一。

几何与 assets/branding/title-icon-*.svg 一致:1024 画布内胶囊占 94% 宽、高为
宽的 0.34,三点取品牌蓝/绿/橙。每档尺寸按 8 倍超采样绘制后缩放,保证 16px
档仍有干净边缘。小尺寸写 BMP 条目、大尺寸写 PNG 条目,兼顾兼容与体积。

用法:python tool/generate_title_icon.py
依赖:Pillow
"""

import io
import struct
from pathlib import Path

from PIL import Image, ImageDraw

# 标题栏在 100%–200% 缩放下会取 16/20/24/32 等小图;大图供预览与任务栏场景。
SIZES = (16, 20, 24, 32, 40, 48, 64, 128, 256)

SUPERSAMPLE = 8
CAPSULE_WIDTH_RATIO = 0.94
CAPSULE_ASPECT = 0.34
DOT_DIAMETER_RATIO = 0.4667  # 点径 / 胶囊高,与应用图标母版一致
DOT_SPACING_RATIO = 0.5833  # 相邻点中心距 / 胶囊高,与应用图标母版一致

DOTS = (
    (0x40, 0x9C, 0xFF, 0xFF),
    (0x30, 0xD1, 0x58, 0xFF),
    (0xFF, 0x9F, 0x0A, 0xFF),
)
CAPSULE_LIGHT = (0x1C, 0x1C, 0x1E, 0xFF)
CAPSULE_DARK = (0xF2, 0xF2, 0xF7, 0xFF)

ROOT = Path(__file__).resolve().parent.parent
OUTPUT_DIR = ROOT / "windows" / "runner" / "resources"


def render(size: int, capsule: tuple[int, int, int, int]) -> Image.Image:
    """按目标尺寸渲染方形透明画布,8 倍超采样后缩回。"""
    canvas = size * SUPERSAMPLE
    image = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    width = canvas * CAPSULE_WIDTH_RATIO
    height = width * CAPSULE_ASPECT
    left = (canvas - width) / 2
    top = (canvas - height) / 2
    draw.rounded_rectangle(
        (left, top, left + width, top + height),
        radius=height / 2,
        fill=capsule,
    )

    diameter = height * DOT_DIAMETER_RATIO
    spacing = height * DOT_SPACING_RATIO
    center = canvas / 2
    for index, color in enumerate(DOTS):
        cx = center + (index - 1) * spacing
        draw.ellipse(
            (cx - diameter / 2, center - diameter / 2,
             cx + diameter / 2, center + diameter / 2),
            fill=color,
        )

    return image.resize((size, size), Image.Resampling.LANCZOS)


def _payload(image: Image.Image) -> bytes:
    """小图用 32bpp DIB,大图用 PNG,均为 ICO 直接支持的图像数据。"""
    buffer = io.BytesIO()
    if image.width >= 128:
        image.save(buffer, format="PNG", optimize=True)
        return buffer.getvalue()

    image.save(buffer, format="DIB")
    data = buffer.getvalue()
    # ICO 内 DIB 的 biHeight 记的是 XOR + AND 两张位图的总高。
    return data[:8] + struct.pack("<I", image.height * 2) + data[12:]


def write_ico(path: Path, capsule: tuple[int, int, int, int]) -> None:
    frames = [(size, render(size, capsule)) for size in SIZES]
    payloads = [_payload(image) for _, image in frames]

    header = struct.pack("<HHH", 0, 1, len(frames))
    directory = bytearray()
    offset = 6 + 16 * len(frames)
    for (size, _), payload in zip(frames, payloads):
        directory += struct.pack(
            "<BBBBHHII",
            size if size < 256 else 0,
            size if size < 256 else 0,
            0,
            0,
            1,
            32,
            len(payload),
            offset,
        )
        offset += len(payload)

    path.write_bytes(header + bytes(directory) + b"".join(payloads))
    print(f"wrote {path} ({path.stat().st_size} bytes)")


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    write_ico(OUTPUT_DIR / "title_icon_light.ico", CAPSULE_LIGHT)
    write_ico(OUTPUT_DIR / "title_icon_dark.ico", CAPSULE_DARK)


if __name__ == "__main__":
    main()