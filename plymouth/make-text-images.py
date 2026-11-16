#!/usr/bin/env python3
"""Genera le immagini della scritta di avvio sotto il logo.

  plymouth/fabbri-hmi/text-0.png ... text-3.png   scritta con 0..3 puntini (animata da Plymouth)
  kiosk/background.png                            logo + KIOSK_TEXT: sfondo di Openbox finché Chrome non è aperto

Va rilanciato solo se cambiano testo, font o logo; le PNG generate sono nel
repository. Richiede Pillow e il font DejaVu Sans:
  python3 -m venv /tmp/venv && /tmp/venv/bin/pip install pillow
  /tmp/venv/bin/python plymouth/make-text-images.py

GAP deve restare uguale a `gap` in fabbri-hmi.script: Plymouth e lo sfondo di
Openbox mettono la scritta nello stesso punto, così il passaggio non si nota.
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

TEXT = "System starting up"  # Plymouth, seguita dai puntini animati
KIOSK_TEXT = "Loading HMI..."  # sfondo di Openbox (immagine fissa)
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
SIZE = 28
COLOR = (0, 40, 72, 255)  # blu scuro del logo
GAP = -40  # px tra il fondo di logo.png e la scritta (negativo: dentro il margine bianco del logo)

repo = Path(__file__).resolve().parent.parent
theme = repo / "plymouth" / "fabbri-hmi"
font = ImageFont.truetype(FONT, SIZE)
ascent, descent = font.getmetrics()
# Larghezza fissa (quella con tre puntini) e testo allineato a sinistra: i
# puntini compaiono senza far spostare la scritta.
width = int(font.getlength(TEXT + "...")) + 4
height = ascent + descent + 4

texts = []
for dots in range(4):
    img = Image.new("RGBA", (width, height), (255, 255, 255, 0))
    ImageDraw.Draw(img).text((2, 2), TEXT + "." * dots, font=font, fill=COLOR)
    img.save(theme / f"text-{dots}.png", optimize=True)
    texts.append(img)

logo = Image.open(theme / "logo.png").convert("RGBA")
# Stessa altezza delle immagini di Plymouth: il logo resta esattamente nella
# stessa posizione quando Plymouth lascia il posto a Openbox.
kiosk_w = int(font.getlength(KIOSK_TEXT)) + 4
kiosk_text = Image.new("RGBA", (kiosk_w, height), (255, 255, 255, 0))
ImageDraw.Draw(kiosk_text).text((2, 2), KIOSK_TEXT, font=font, fill=COLOR)
block_w = max(logo.width, kiosk_w)
block_h = logo.height + GAP + height
background = Image.new("RGBA", (block_w, block_h), (255, 255, 255, 255))
background.alpha_composite(logo, ((block_w - logo.width) // 2, 0))
background.alpha_composite(kiosk_text, ((block_w - kiosk_w) // 2, logo.height + GAP))
(repo / "kiosk").mkdir(exist_ok=True)
background.convert("RGB").save(repo / "kiosk" / "background.png", optimize=True)
print(f"text {width}x{height}, background {block_w}x{block_h}")
