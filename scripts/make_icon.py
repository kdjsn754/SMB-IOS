"""生成 1024x1024 的 App 图标（无 alpha，符合 App Store 要求）。"""
from PIL import Image, ImageDraw

SIZE = 1024


def make_gradient(size: int) -> Image.Image:
    start = (43, 92, 230)
    end = (126, 63, 242)
    # 先画一张更大的渐变再旋转裁切，避免出现空白角
    big = size * 2
    base = Image.new("RGB", (big, big))
    draw = ImageDraw.Draw(base)
    for y in range(big):
        t = y / (big - 1)
        color = tuple(int(start[i] + (end[i] - start[i]) * t) for i in range(3))
        draw.line([(0, y), (big, y)], fill=color)
    rotated = base.rotate(-35, resample=Image.BICUBIC, expand=False)
    left = (big - size) // 2
    return rotated.crop((left, left, left + size, left + size))


def main() -> None:
    scale = 2
    canvas = SIZE * scale
    image = make_gradient(canvas).convert("RGBA")
    overlay = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    # 屏幕
    screen = (232 * scale, 250 * scale, 792 * scale, 742 * scale)
    draw.rounded_rectangle(screen, radius=96 * scale, fill=(255, 255, 255, 38),
                           outline=(255, 255, 255, 235), width=26 * scale)

    # 播放三角
    play = [
        (462 * scale, 386 * scale),
        (462 * scale, 606 * scale),
        (632 * scale, 496 * scale),
    ]
    draw.polygon(play, fill=(255, 255, 255, 255))

    # 底座
    draw.rounded_rectangle(
        (392 * scale, 790 * scale, 632 * scale, 822 * scale),
        radius=16 * scale, fill=(255, 255, 255, 200),
    )

    # 网络小圆点
    for cx in (452, 512, 572):
        draw.ellipse(
            (cx * scale - 13 * scale, 872 * scale, cx * scale + 13 * scale, 898 * scale),
            fill=(255, 255, 255, 170),
        )

    composed = Image.alpha_composite(image, overlay).convert("RGB")
    composed = composed.resize((SIZE, SIZE), Image.LANCZOS)
    composed.save("Sources/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
    print("icon written")


if __name__ == "__main__":
    main()
