#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成应用图标的两个矢量图层，写进 App/Resources/AppIcon.icon/Assets。

用法（在项目根目录）：  python3 scripts/app_icon.py

图标是 Icon Composer 的 .icon 格式：背景渐变、浅色与深色两套配色、玻璃效果都在
AppIcon.icon/icon.json 里；这里只负责画形状。画布 1024×1024，图形用纯白，
实际颜色由 icon.json 按外观填充。

构图：中间一个钥匙孔，外面三圈开口朝下的弧线当指纹纹路。外面两圈各断开一处，
断口错开，看起来像指纹而不是同心圆。
"""
import math
import os

CENTER = 512
STROKE = 44
OUT_DIR = "App/Resources/AppIcon.icon/Assets"

# (半径, 起始角, 终止角)。角度按屏幕坐标：0° 朝右，90° 朝下，顺时针画。
RIDGES = [
    (124, 138, 402),
    (204, 150, 338),
    (204, 358, 412),
    (284, 128, 236),
    (284, 256, 420),
]

KEYHOLE_Y = 478       # 钥匙孔圆心的纵坐标
KEYHOLE_RADIUS = 44


def point(radius, angle):
    t = math.radians(angle)
    return CENTER + radius * math.cos(t), CENTER + radius * math.sin(t)


def ridge(radius, start, end):
    """一段圆头弧线，画成实心轮廓。

    不用描边：生成旧系统后备图标（.icns）的渲染器不认 stroke，会把路径整块填实。
    """
    half = STROKE / 2
    outer, inner = radius + half, radius - half
    large = 1 if end - start > 180 else 0
    ox0, oy0 = point(outer, start)
    ox1, oy1 = point(outer, end)
    ix0, iy0 = point(inner, start)
    ix1, iy1 = point(inner, end)
    return (f'<path d="M{ox0:.2f} {oy0:.2f} '
            f'A{outer} {outer} 0 {large} 1 {ox1:.2f} {oy1:.2f} '
            f'A{half} {half} 0 0 1 {ix1:.2f} {iy1:.2f} '
            f'A{inner} {inner} 0 {large} 0 {ix0:.2f} {iy0:.2f} '
            f'A{half} {half} 0 0 1 {ox0:.2f} {oy0:.2f} Z" fill="#fff"/>')


def keyhole():
    c, y, r = CENTER, KEYHOLE_Y, KEYHOLE_RADIUS
    stem = (f'M{c - 17} {y + 20} L{c + 17} {y + 20} L{c + 27} {y + 112} '
            f'Q{c + 28} {y + 124} {c + 16} {y + 124} L{c - 16} {y + 124} '
            f'Q{c - 28} {y + 124} {c - 27} {y + 112} Z')
    return f'<circle cx="{c}" cy="{y}" r="{r}" fill="#fff"/><path d="{stem}" fill="#fff"/>'


def svg(body):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
            f'viewBox="0 0 1024 1024">{body}</svg>\n')


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    layers = {
        "ridges.svg": "".join(ridge(*r) for r in RIDGES),
        "keyhole.svg": keyhole(),
    }
    for name, body in layers.items():
        path = os.path.join(OUT_DIR, name)
        with open(path, "w") as f:
            f.write(svg(body))
        print("已写入", path)


if __name__ == "__main__":
    main()
