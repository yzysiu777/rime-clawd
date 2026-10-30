"""把 Clawd --render-demo 输出的 PNG 帧合成 GIF。用法：python3 make_gif.py <帧目录> <输出.gif>"""
import glob
import sys

from PIL import Image

frames_dir, out = sys.argv[1], sys.argv[2]
paths = sorted(glob.glob(frames_dir + "/f*.png"))
frames = []
for p in paths:
    im = Image.open(p).convert("RGB")
    frames.append(im.quantize(colors=96, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE))
frames[0].save(out, save_all=True, append_images=frames[1:], duration=40, loop=0, optimize=True, disposal=1)
print(f"{out}: {len(frames)} 帧")
