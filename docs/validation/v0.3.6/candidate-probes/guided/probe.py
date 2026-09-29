#!/usr/bin/env python3
"""Throwaway CPU self-guided Y' probe. No GPU, app code, or learned models.

The formula averages both a and b. It is not the unaveraged local shrinker.
All filtering/thresholds operate on normalized sRGB-encoded channel luma.
The float64 path is the numerical reference; FP32 local sums are only checked.
"""
from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
import platform
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[3]
BASE = ROOT / ".build/restoration-lab"
OUT = Path(__file__).resolve().parent
OUT.mkdir(parents=True, exist_ok=True)
W = np.array([0.2126, 0.7152, 0.0722])
CONFIGS = [(1, 2), (1, 4), (2, 2), (2, 4)]
NAMES = [f"r{r}_eps{s}sq_cap2" for r, s in CONFIGS]
FRAMES = [0, 24, 48, 72, 95]
DECODE_COMMANDS = []


def box(x, r):
    """Separable box average with replicate-edge boundaries, float64 sums."""
    q = np.asarray(x, dtype=np.float64)
    for axis in (1, 0):
        pads = [(0, 0)] * q.ndim
        pads[axis] = (r, r)
        z = np.pad(q, pads, mode="edge")
        sums = np.cumsum(z, axis=axis, dtype=np.float64)
        pads[axis] = (1, 0)
        sums = np.pad(sums, pads, mode="constant")
        a = [slice(None)] * q.ndim
        b = [slice(None)] * q.ndim
        a[axis] = slice(2 * r + 1, None)
        b[axis] = slice(None, -(2 * r + 1))
        q = (sums[tuple(a)] - sums[tuple(b)]) / (2 * r + 1)
    return q


def box_fp32_local(x, r):
    """Small separable FP32 sums; avoids long FP32 cumulative-sum cancellation."""
    q = np.asarray(x, dtype=np.float32)
    for axis in (1, 0):
        pads = [(0, 0)] * q.ndim
        pads[axis] = (r, r)
        z = np.pad(q, pads, mode="edge")
        v = np.zeros_like(q)
        for k in range(2 * r + 1):
            s = [slice(None)] * q.ndim
            s[axis] = slice(k, k + q.shape[axis])
            v += z[tuple(s)]
        q = v / np.float32(2 * r + 1)
    return q


def guided(rgb, r, sigma_code, use_fp32=False):
    """Self-guided luma, additive RGB correction, no sharpening."""
    dtype = np.float32 if use_fp32 else np.float64
    bx = box_fp32_local if use_fp32 else box
    x = np.asarray(rgb, dtype=dtype)
    y = x @ W.astype(dtype)
    stats = bx(np.stack([y, y * y], axis=-1), r)
    mu = stats[..., 0]
    variance = np.maximum(dtype(0), stats[..., 1] - mu * mu)
    eps = dtype((sigma_code / 255) ** 2)
    a = variance / (variance + eps)
    b = (1 - a) * mu
    averaged = bx(np.stack([a, b], axis=-1), r)
    q = averaged[..., 0] * y + averaged[..., 1]
    correction = np.clip(q - y, -2 / 255, 2 / 255)
    return np.clip(x + correction[..., None], 0, 1)


def all_outputs(rgb):
    return {"original": rgb, **{n: guided(rgb, *c) for n, c in zip(NAMES, CONFIGS)}}


def metrics(x, ref, original):
    e = (x - ref) * 255
    delta = (x - original) * 255
    mse = float(np.mean(e * e))
    return {
        "rgb_mse_code2": mse,
        "rgb_psnr_db": 10 * math.log10(255**2 / mse) if mse > 1e-24 else None,
        "luma_mse_code2": float(np.mean((e @ W) ** 2)),
        "rms_change_code": float(np.sqrt(np.mean(delta * delta))),
        "max_abs_change_code": float(np.max(np.abs(delta))),
        "cap_pixel_fraction": float(np.mean(np.max(np.abs(delta), axis=-1) >= 2 - 1e-8)),
    }


def gray(y):
    return np.repeat((np.asarray(y, dtype=np.float64) / 255)[..., None], 3, axis=-1)


def to_img(x):
    return Image.fromarray(np.rint(np.clip(x, 0, 1) * 255).astype(np.uint8))


def read_img(path):
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.float64) / 255


def decode(path, indices, resize=None):
    selection = "+".join(f"eq(n\\,{n})" for n in indices)
    vf = f"select={selection}"
    if resize:
        vf += f",scale={resize[0]}:{resize[1]}:flags=bicubic"
    cmd = ["ffmpeg", "-v", "error", "-hwaccel", "none", "-threads", "1", "-filter_threads", "1", "-i", str(path), "-vf", vf, "-vsync", "0", "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"]
    DECODE_COMMANDS.append(cmd)
    raw = subprocess.run(cmd, check=True, stdout=subprocess.PIPE).stdout
    width, height = resize or (480, 200)
    result = np.frombuffer(raw, dtype=np.uint8).reshape(-1, height, width, 3)
    assert len(result) == len(indices), (path, result.shape, indices)
    return result.astype(np.float64) / 255


def numerical_checks():
    rng = np.random.default_rng(2909)
    y = rng.random((7, 9))
    errs = []
    for r in (1, 2):
        padded = np.pad(y, r, mode="edge")
        direct = np.array([[padded[i:i+2*r+1, j:j+2*r+1].mean() for j in range(9)] for i in range(7)])
        errs.append(float(np.max(np.abs(box(y, r) - direct))))
    # Independent slow local-model evaluation, including mean(a), mean(b).
    r, eps = 1, (2 / 255)**2
    image = rng.random((9, 11)) * 0.1 + 0.4
    padded = np.pad(image, r, mode="edge")
    a, b = np.zeros_like(image), np.zeros_like(image)
    for i in range(9):
        for j in range(11):
            window = padded[i:i+3, j:j+3]
            mean, var = window.mean(), window.var()
            a[i, j] = var / (var + eps)
            b[i, j] = (1-a[i, j]) * mean
    ap, bp = np.pad(a, r, mode="edge"), np.pad(b, r, mode="edge")
    q = np.array([[ap[i:i+3, j:j+3].mean() * image[i, j] + bp[i:i+3, j:j+3].mean() for j in range(11)] for i in range(9)])
    expected = image + np.clip(q-image, -2/255, 2/255)
    actual = guided(np.repeat(image[..., None], 3, axis=-1), 1, 2)[..., 0]
    oracle_error = float(np.max(np.abs(expected-actual)) * 255)
    assert max(errs) < 1e-12
    assert oracle_error < 1e-9
    fp32_results = {}
    for level in (16, 64, 128, 192, 240):
        xx = np.arange(128)[None, :]
        test = gray(np.broadcast_to(level + 2*np.sin(2*np.pi*xx/8), (64,128)))
        for name, cfg in zip(NAMES, CONFIGS):
            exact = guided(test, *cfg)
            fp32 = guided(test, *cfg, use_fp32=True)
            fp32_results[f"gray{level}_{name}"] = float(np.max(np.abs(exact-fp32))*255)
    return {"box_vs_direct_max_normalized_error": max(errs), "full_averaged_ab_vs_direct_max_code_error": oracle_error, "fp32_local_box_max_code_error": max(fp32_results.values()), "fp32_cases": fp32_results}


def run_flats():
    rows = []
    rng = np.random.default_rng(20260929)
    for level in (16, 64, 128, 192):
        ref = gray(np.full((96,128), level))
        for sigma in (0, 2, 4, 8):
            y = np.full((96,128), level, dtype=float) + rng.normal(0, sigma, (96,128))
            original = gray(np.clip(y,0,255))
            for method, out in all_outputs(original).items():
                row = {"level":level, "noise_sigma_code":sigma, "method":method, **metrics(out[8:-8,8:-8], ref[8:-8,8:-8], original[8:-8,8:-8])}
                rows.append(row)
    return rows


def run_texture():
    rows = []
    xx, yy = np.meshgrid(np.arange(128),np.arange(96))
    rng = np.random.default_rng(311)
    for level in (64,128,192):
        for amp in (2,4,8):
            for period in (4,8,16):
                wave = np.sin(2*np.pi*xx/period)
                ref = gray(level+amp*wave)
                crop = np.s_[8:-8,16:-16]
                wv = wave[crop]
                for sigma in (0,2):
                    original = gray(level+amp*wave+rng.normal(0,sigma,wave.shape))
                    for method,out in all_outputs(original).items():
                        modulation = float(np.sum(((out@W)[crop]*255-level)*wv)/np.sum(wv*wv)/amp)
                        rows.append({"level":level,"amplitude_code":amp,"peak_to_peak_code":2*amp,"period_px":period,"noise_sigma_code":sigma,"method":method,"modulation_ratio":modulation, **metrics(out[crop],ref[crop],original[crop])})
    return rows


GLYPHS = {
    "F":["11111","10000","10000","11110","10000","10000","10000"],
    "I":["111","010","010","010","010","010","111"],
    "L":["10000","10000","10000","10000","10000","10000","11111"],
    "M":["10001","11011","10101","10101","10001","10001","10001"],
    "2":["01110","10001","00001","00010","00100","01000","11111"],
    "4":["00010","00110","01010","10010","11111","00010","00010"],
}


def components(mask):
    pending=set(map(tuple,np.argwhere(mask)))
    result=0
    while pending:
        result+=1
        stack=[pending.pop()]
        while stack:
            i,j=stack.pop()
            for di in (-1,0,1):
                for dj in (-1,0,1):
                    p=(i+di,j+dj)
                    if p in pending:
                        pending.remove(p);stack.append(p)
    return result


def run_subtitles():
    mask=np.zeros((48,128),bool)
    x=14
    for ch in "FILM24":
        glyph=np.array([[v=="1" for v in row] for row in GLYPHS[ch]])
        mask[20:27,x:x+glyph.shape[1]]=glyph
        x+=glyph.shape[1]+3
    for n in range(12):
        mask[17+n,80+n]=True
        mask[17+n,106-n]=True
    near=box(mask.astype(float),2)>0
    halo=near & ~mask
    rows=[]
    previews=[]
    for label,bg,fg in (("white",32,235),("gray",64,96),("weak_gray",64,68)):
        original=gray(np.where(mask,fg,bg))
        for method,out in all_outputs(original).items():
            val=(out@W)*255
            predicted=val > (bg+fg)/2
            rows.append({"fixture":label,"background_code":bg,"foreground_code":fg,"method":method,"stroke_mean_abs_error_code":float(np.abs(val[mask]-fg).mean()),"stroke_min_contrast_ratio":float((val[mask].min()-bg)/(fg-bg)),"stroke_mean_contrast_ratio":float((val[mask].mean()-bg)/(fg-bg)),"halo_mean_abs_error_code":float(np.abs(val[halo]-bg).mean()),"foreground_recall":float(predicted[mask].mean()),"background_false_positive_fraction":float(predicted[~mask].mean()),"input_components_8connected":components(mask),"output_components_8connected":components(predicted), **metrics(out,original,original)})
            previews.append((f"{label} {method}", out))
    return rows, previews


def run_step():
    x=np.full((64,128),64.)
    x[:,64:]=192
    original=gray(x)
    rows=[]
    for method,out in all_outputs(original).items():
        y=(out@W)*255
        rows.append({"method":method,"minimum_code":float(y.min()),"maximum_code":float(y.max()),"undershoot_code":float(max(0,64-y.min())),"overshoot_code":float(max(0,y.max()-192)),"max_edge_change_code":float(np.abs(y[:,62:66]-x[:,62:66]).max())})
    return rows


def run_film():
    rows=[]
    preview=[]
    # Decode the clean PNG through the same explicitly specified software scaler.
    reference=decode(BASE/"clean-film-24.png",[0],(480,200))[0]
    to_img(reference).save(OUT/"clean-film-24-bicubic480.png")
    for variant in ("noisy","compressed"):
        original=read_img(BASE/f"{variant}-film-24.png")
        preview.extend([(f"{variant} reference",reference),(f"{variant} original",original)])
        for method,out in all_outputs(original).items():
            rows.append({"source":"existing_png","variant":variant,"frame":24,"method":method,**metrics(out,reference,original)})
            if method!="original":
                preview.append((f"{variant} {method}",out))
                to_img(out).save(OUT/f"{variant}-film-24-{method}.png")
    references=decode(BASE/"clean-film.mp4",FRAMES,(480,200))
    for variant in ("compressed","noisy","heavy-noisy"):
        originals=decode(BASE/f"{variant}-film.mp4",FRAMES)
        for frame,original,ref in zip(FRAMES,originals,references):
            for method,out in all_outputs(original).items():
                rows.append({"source":"software_decode_mp4","variant":variant,"frame":frame,"method":method,**metrics(out,ref,original)})
    aggregate=[]
    for variant in ("compressed","noisy","heavy-noisy"):
        for method in ("original",*NAMES):
            subset=[r for r in rows if r["source"]=="software_decode_mp4" and r["variant"]==variant and r["method"]==method]
            mse=float(np.mean([r["rgb_mse_code2"] for r in subset]))
            baseline=[r for r in rows if r["source"]=="software_decode_mp4" and r["variant"]==variant and r["method"]=="original"]
            psnr=10*math.log10(255**2/mse)
            base_psnr=10*math.log10(255**2/np.mean([r["rgb_mse_code2"] for r in baseline]))
            aggregate.append({"variant":variant,"method":method,"frames":FRAMES,"rgb_mse_code2":mse,"rgb_psnr_db":psnr,"delta_psnr_db":psnr-base_psnr,"luma_mse_code2":float(np.mean([r["luma_mse_code2"] for r in subset])),"per_frame_delta_psnr_min_db":min(r["rgb_psnr_db"]-b["rgb_psnr_db"] for r,b in zip(subset,baseline)),"per_frame_delta_psnr_max_db":max(r["rgb_psnr_db"]-b["rgb_psnr_db"] for r,b in zip(subset,baseline)),"max_abs_change_code":max(r["max_abs_change_code"] for r in subset)})
    return rows,aggregate,preview


def contact_sheet(items,columns,path,scale=1):
    width=max(x.shape[1] for _,x in items)*scale
    height=max(x.shape[0] for _,x in items)*scale
    sheet=Image.new("RGB",(width*columns,(height+24)*math.ceil(len(items)/columns)),(18,18,18))
    draw=ImageDraw.Draw(sheet)
    for i,(label,x) in enumerate(items):
        xpos=(i%columns)*width;ypos=(i//columns)*(height+24)
        img=to_img(x)
        if scale!=1:img=img.resize((img.width*scale,img.height*scale),Image.Resampling.NEAREST)
        draw.text((xpos+4,ypos+5),label,fill=(235,235,235))
        sheet.paste(img,(xpos,ypos+24))
    sheet.save(path)


def run_post_temporal():
    base=ROOT/".build/repair-v036/post-temporal"
    rows=[]
    range_rows={}
    def read(name):
        x=np.fromfile(base/name,dtype="<f4").reshape(200,480,4)[...,:3].astype(np.float64)
        clipped=np.clip(x,0,1)
        range_rows[name]={"min":float(x.min()),"max":float(x.max()),"out_of_range_channel_fraction":float(np.mean((x<0)|(x>1))),"shared_clamp_max_change_code":float(np.max(np.abs(clipped-x))*255)}
        return clipped
    frames=[12,24,48,72,84]
    if not (base/"clean-12.rgba32f").exists():
        return {"available":False}
    for frame in frames:
        ref=read(f"clean-{frame}.rgba32f")
        for variant in ("compressed-film","noisy-film","heavy-noisy-film"):
            for stage in ("raw","temporal"):
                original=read(f"{variant}-{stage}-{frame}.rgba32f")
                for method,out in all_outputs(original).items():
                    row={"frame":frame,"variant":variant,"stage":stage,"method":method,**metrics(out,ref,original)}
                    assert row["max_abs_change_code"] <= 2+1e-8, row
                    rows.append(row)
    aggregate=[]
    for variant in ("compressed-film","noisy-film","heavy-noisy-film"):
        for stage in ("raw","temporal"):
            base_rows=[r for r in rows if r["variant"]==variant and r["stage"]==stage and r["method"]=="original"]
            base_mse=np.mean([r["rgb_mse_code2"] for r in base_rows])
            for method in ("original",*NAMES):
                subset=[r for r in rows if r["variant"]==variant and r["stage"]==stage and r["method"]==method]
                mse=np.mean([r["rgb_mse_code2"] for r in subset])
                aggregate.append({"variant":variant,"stage":stage,"method":method,"rgb_mse_code2":float(mse),"rgb_psnr_db":10*math.log10(255**2/mse),"delta_psnr_db":10*math.log10(base_mse/mse),"luma_mse_code2":float(np.mean([r["luma_mse_code2"] for r in subset])),"per_frame_delta_psnr_min_db":min(r["rgb_psnr_db"]-b["rgb_psnr_db"] for r,b in zip(subset,base_rows)),"per_frame_delta_psnr_max_db":max(r["rgb_psnr_db"]-b["rgb_psnr_db"] for r,b in zip(subset,base_rows)),"rms_change_code":float(np.sqrt(np.mean([r["rms_change_code"]**2 for r in subset]))),"max_abs_change_code":max(r["max_abs_change_code"] for r in subset)})
    hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(base.glob("*.rgba32f"))}
    return {"available":True,"scope":"5 same-PTS float32 exports supplied by root: production TemporalRestorer already run. This probe reads CPU files only, excludes alpha, no added 8-bit quantization. Reference uses root CI Lanczos downsample. Input, baseline and reference all first share clamp to display SDR [0,1] because exports contain extended-range channels; this shared preprocessing is not counted as filter gain. Not full-video statistics or playback.","frames":frames,"rows":rows,"aggregate":aggregate,"input_ranges_and_shared_clamp":range_rows,"input_sha256":hashes}


def main():
    checks=numerical_checks()
    flat=run_flats();texture=run_texture();subtitles,sub_previews=run_subtitles()
    film,film_aggregate,film_previews=run_film()
    inputs={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [*(BASE/f"{v}-film.mp4" for v in ("clean","compressed","noisy","heavy-noisy")),*(BASE/f"{v}-film-24.png" for v in ("clean","compressed","noisy"))]}
    result={"scope":"CPU-only numerical probe of source-size images, including root-supplied temporal exports. Not production filter integration, GPU timing, display quality or full-video proof.","environment":{"python":sys.version,"numpy":np.__version__,"platform":platform.platform()},"algorithm":{"domain":"Y prime = dot(sRGB encoded RGB, Rec709 weights); no linear-light threshold substitution","radius":[1,2],"epsilon":[(2/255)**2,(4/255)**2],"max_luma_adjustment_code":2,"rgb_update":"add bounded q-Y to each RGB channel, clamp [0,1]","boundary":"replicate edge","work_type":"float64 numerical reference; independent small local FP32 comparison","coefficient_average":"q = box(a)*Y + box(b)","quantization":"metrics use floating output before 8-bit quantization; PNG previews quantized only","reference_resize":"ffmpeg supplement uses software bicubic, 960x400 -> 480x200; differs from v0.3.5 Lanczos reference so do not compare absolute PSNR across reports. Primary post-temporal exports use root CI Lanczos reference.","synthetic_input":"continuous encoded grayscale floats, seeded Gaussian noise; texture not quantized"},"checks":checks,"flat":flat,"weak_texture":texture,"subtitles":subtitles,"step":run_step(),"film":film,"film_five_frame_aggregate":film_aggregate,"post_temporal":run_post_temporal(),"input_sha256":inputs,"decode_commands":DECODE_COMMANDS}
    (OUT/"report.json").write_text(json.dumps(result,indent=2)+"\n")
    contact_sheet(film_previews,6,OUT/"film-contact.png")
    contact_sheet(sub_previews,5,OUT/"subtitles-contact.png",4)
    print(json.dumps({"checks":checks,"film_aggregate":film_aggregate,"post_temporal":result["post_temporal"].get("aggregate",[])},indent=2))


if __name__=="__main__":
    main()
