#!/usr/bin/env python3
"""產生 VoiceType 的圖示。母題是錄音面板上的音量波形，識別上連得起來。

輸出：
  assets/logo.png      512x512 彩色，給落地頁與設定視窗用
  assets/menubar.png   44x44 單色透明，給 macOS 選單列用（template 模式）

要換成自己的 Logo 的話不用跑這個，直接放檔案就好：
  ~/.config/voicetype/logo.png      建議 512x512 PNG，透明背景
  ~/.config/voicetype/menubar.png   建議 44x44 PNG，純黑 + 透明（選單列會自動反色）
"""
from PIL import Image, ImageDraw
import os

HERE = os.path.dirname(os.path.abspath(__file__))
# 波形的相對高度，中間高兩側低，跟錄音面板的視覺一致
BARS = [0.34, 0.62, 1.0, 0.72, 0.44]


def rounded(draw, box, r, fill):
    draw.rounded_rectangle(box, radius=r, fill=fill)


def waveform(draw, cx, cy, w, h, color, gap_ratio=0.42):
    n = len(BARS)
    bw = w / (n + (n - 1) * gap_ratio)
    gap = bw * gap_ratio
    x = cx - w / 2
    for frac in BARS:
        bh = h * frac
        rounded(draw, (x, cy - bh / 2, x + bw, cy + bh / 2), bw / 2, color)
        x += bw + gap


def make_logo(size=512):
    S = size
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    pad = S * 0.06
    rounded(d, (pad, pad, S - pad, S - pad), S * 0.235, (18, 18, 22, 255))
    waveform(d, S / 2, S / 2, S * 0.56, S * 0.52, (255, 255, 255, 255))
    # 左下角一顆紅點＝正在錄音，跟面板上的紅點對應
    r = S * 0.052
    cx, cy = S * 0.295, S * 0.705
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(242, 63, 63, 255))
    img.save(os.path.join(HERE, "logo.png"))
    return img


def make_menubar(size=44):
    # 選單列圖示要單色：純黑 + 透明，macOS 的 template 模式會自己處理深淺色反轉。
    # 不能放彩色圖，深色選單列上會變成一團黑。
    S = size
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    waveform(d, S / 2, S / 2, S * 0.78, S * 0.72, (0, 0, 0, 255))
    img.save(os.path.join(HERE, "menubar.png"))
    return img


if __name__ == "__main__":
    make_logo()
    make_menubar()
    print("已產生 assets/logo.png 與 assets/menubar.png")
