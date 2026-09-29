#!/usr/bin/env python3
"""Throwaway CPU constrained-difference postfilter. Not AV1 CDEF or an AI model."""
from pathlib import Path
import hashlib, json, math, platform, subprocess, time
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
LAB = ROOT / '.build/restoration-lab'
STRENGTHS = (2., 4., 6.)
FRAMES = (12, 24, 48, 72, 84)
COEFF = np.array([.2126, .7152, .0722], dtype=np.float32)

def luma(rgb):
    return np.sum(rgb * COEFF, axis=-1)

def smoothstep(a, b, x):
    v = np.clip((x-a)/(b-a), 0., 1.)
    return v*v*(3.-2.*v)

def constrained_luma(y, strength, protect=None, strong_direction=False):
    """9 reads, float code domain; clamp-edge borders; 8 neighbours, 4 pairs."""
    p = np.pad(y, 1, mode='edge')
    h, w = y.shape
    neighbours = [p[1+dy:1+dy+h, 1+dx:1+dx+w]
                  for dy, dx in [(-1,0),(1,0),(0,-1),(0,1),(-1,-1),(1,1),(-1,1),(1,-1)]]
    costs = [np.abs(neighbours[i]-y)+np.abs(neighbours[i+1]-y)
             for i in range(0,8,2)]
    cmin, cmax = np.minimum.reduce(costs), np.maximum.reduce(costs)
    coherence = (cmax-cmin)/(cmax+cmin+(1e-3 if strong_direction else strength))
    # Optional single prespecified comparison: protect strongly coherent structures entirely.
    direction_gate = 1.-smoothstep(.50,.85,coherence) if strong_direction else 1.-.9*coherence
    gate = direction_gate*(1.-smoothstep(12.,32.,cmax))
    acc = np.zeros_like(y)
    for i, n in enumerate(neighbours):
        d = n-y
        constrained = np.sign(d)*np.minimum(np.abs(d),np.maximum(0.,strength-.5*np.abs(d)))
        acc += (2. if i < 4 else 1.)*constrained
    delta = np.clip(gate*acc/16., -2., 2.)
    if protect is not None:
        delta = np.where(protect, 0., delta)
    lo = np.minimum.reduce([y]+neighbours)
    hi = np.maximum.reduce([y]+neighbours)
    return np.clip(y+delta,lo,hi)

def candidate(rgb, strength, protect=None, clip_output=True, strong_direction=False):
    y = luma(rgb)
    q = constrained_luma(y,strength,protect,strong_direction)
    out=rgb+(q-y)[...,None]
    return np.clip(out,0.,255.) if clip_output else out

def mse(a,b,mask=None):
    diff=(a.astype(np.float64)-b.astype(np.float64))**2
    return float(np.mean(diff if mask is None else diff[mask]))

def psnr(m):
    return None if m == 0. else 10.*math.log10(255.*255./m)

def metrics(src, dst, truth):
    base, post = mse(src,truth), mse(dst,truth)
    by, py = mse(luma(src),luma(truth)), mse(luma(dst),luma(truth))
    return {'rgb_mse_before':base,'rgb_mse_after':post,'rgb_psnr_before':psnr(base),
        'rgb_psnr_after':psnr(post),'rgb_psnr_gain':psnr(post)-psnr(base) if base and post else None,
        'luma_mse_before':by,'luma_mse_after':py,
        'luma_mse_reduction_pct':100.*(1.-py/by) if by else None,
        'max_luma_delta_code':float(np.max(np.abs(luma(dst)-luma(src)))),
        'mean_abs_luma_delta_code':float(np.mean(np.abs(luma(dst)-luma(src))))}

def decode(path,w,h):
    # CPU libavcodec decode only. No Apple VT, no product pipeline or GPU calls.
    cmd=['ffmpeg','-v','error','-threads','1','-i',str(path),'-an','-sn','-dn',
         '-f','rawvideo','-pix_fmt','rgb24','-threads','1','pipe:1']
    data=subprocess.check_output(cmd)
    return np.frombuffer(data,dtype=np.uint8).reshape(-1,h,w,3)

def save(a,name):
    Image.fromarray(np.clip(np.rint(a),0,255).astype(np.uint8)).save(OUT/name)

def main():
    report={'scope':'CPU NumPy float32, SDR encoded luma, no temporal/GPU/product processing; unchanged decoded RGB baseline; sampled frames only.',
        'algorithm':'3x3 8-neighbour float constrained differences; continuous local directional coherence and edge gate; NOT full AV1 CDEF, not AI; no sharpening',
        'frames':list(FRAMES),'strengths_code':list(STRENGTHS),'cap_code':2,
        'environment':{'python':platform.python_version(),'machine':platform.machine(),'numpy':np.__version__},
        'inputs':{},'film':{},'still':{},'synthetic':{},'timing':{}}
    clean=decode(LAB/'clean-film.mp4',960,400)
    truths=np.array([np.asarray(Image.fromarray(f).resize((480,200),Image.Resampling.LANCZOS),dtype=np.float32) for f in clean])
    report['clean_reference_resize']='Pillow Lanczos on decoded 8-bit sRGB/RGB code values, 960x400 to480x200; not production CI Lanczos; same resized truth used for all candidates'
    for name in ['clean-film','compressed-film','noisy-film','heavy-noisy-film']:
        path=LAB/(name+'.mp4')
        report['inputs'][name]={'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'bytes':path.stat().st_size}
    for name in ['compressed-film','noisy-film','heavy-noisy-film']:
        frames=decode(LAB/(name+'.mp4'),480,200)
        assert len(frames)==len(clean)==96
        report['film'][name]={}
        src=frames[list(FRAMES)].astype(np.float32)
        truth=truths[list(FRAMES)]
        for s in STRENGTHS:
            dst=np.array([candidate(f,s) for f in src])
            report['film'][name][str(int(s))]=metrics(src,dst,truth)
            report['film'][name][str(int(s))]['per_frame_psnr_gains']=[metrics(a,b,c)['rgb_psnr_gain'] for a,b,c in zip(src,dst,truth)]
            # Clean same-frame control measures unwanted processing against input itself.
            clean_out=np.array([candidate(f,s) for f in truth])
            report['film'][name][str(int(s))]['clean_control_luma_mse']=mse(luma(clean_out),luma(truth))
            if s==4:
                save(src[1],name+'-frame024-before.png')
                save(dst[1],name+'-frame024-s4.png')
        del frames
    save(truths[24],'truth-frame024-480x200.png')
    # Independently captured CURRENT production TemporalRestorer float outputs (root supplied).
    # Clean reference is root's production CI Lanczos downsample, not Pillow.
    capture=ROOT/'.build/repair-v036/post-temporal'
    if capture.exists():
        def read_capture(name):
            a=np.fromfile(capture/name,dtype='<f4').reshape(200,480,4)
            assert np.isfinite(a).all()
            return a[...,:3]*255.
        temporal_truth=np.array([read_capture(f'clean-{n}.rgba32f') for n in FRAMES])
        report['post_temporal']={'scope':'CURRENT production TemporalRestorer float32 encoded SDR output; RGB code values; root-supplied current CI Lanczos clean reference; no extra8-bit quantization; source480x200; frames12/24/48/72/84; baseline, candidate and truth share identical final SDR [0,255] gamut clip; extended-range metrics also kept separately','variants':{}}
        for name in ['compressed-film','noisy-film','heavy-noisy-film']:
            report['post_temporal']['variants'][name]={}
            for stage in ['raw','temporal']:
                src=np.array([read_capture(f'{name}-{stage}-{n}.rgba32f') for n in FRAMES])
                report['post_temporal']['variants'][name][stage]={}
                for s in STRENGTHS:
                    dst=np.array([candidate(f,s) for f in src])
                    clipped_src=np.clip(src,0,255)
                    clipped_truth=np.clip(temporal_truth,0,255)
                    row=metrics(clipped_src,dst,clipped_truth)
                    report['post_temporal']['variants'][name][stage][str(int(s))]=row
                    row['per_frame_psnr_gains']=[metrics(a,b,c)['rgb_psnr_gain'] for a,b,c in zip(clipped_src,dst,clipped_truth)]
                    extended_dst=np.array([candidate(f,s,clip_output=False) for f in src])
                    row['without_any_output_clip']=metrics(src,extended_dst,temporal_truth)
                    row['source_rgb_range_code']=[float(np.min(src)),float(np.max(src))]
                    assert row['max_luma_delta_code']<=2.0001
                    assert row['without_any_output_clip']['max_luma_delta_code']<=2.0001
                    if s==4 and stage=='temporal':
                        save(src[1],name+'-production-temporal-frame024-before.png')
                        save(dst[1],name+'-production-temporal-frame024-s4.png')
    # Existing exact static frames, independent from ffmpeg video decode samples.
    still_truth=np.asarray(Image.open(LAB/'clean-film-24.png').convert('RGB').resize((480,200),Image.Resampling.LANCZOS),dtype=np.float32)
    for name in ['compressed-film','noisy-film']:
        src=np.asarray(Image.open(LAB/(name+'-24.png')).convert('RGB'),dtype=np.float32)
        report['still'][name]={str(int(s)):metrics(src,candidate(src,s),still_truth) for s in STRENGTHS}
    rng=np.random.default_rng(29092026)
    # Flats span code-domain brightness and noise scales; same deterministic noise shared per strength.
    flat=[]
    for level in [16.,64.,128.,192.]:
        for sigma in [2.,4.,8.]:
            truth=np.full((128,192),level,np.float32)
            noisy=np.clip(truth+rng.normal(0,sigma,truth.shape).astype(np.float32),0,255)
            base=mse(noisy,truth)
            row={'level':level,'sigma':sigma,'mse_before':base}
            for s in STRENGTHS:
                q=constrained_luma(noisy,s)
                row[str(int(s))]={'mse_after':mse(q,truth),'reduction_pct':100*(1-mse(q,truth)/base),'max_delta':float(np.max(np.abs(q-noisy)))}
            flat.append(row)
    report['synthetic']['flats']=flat
    textures=[]
    yy,xx=np.mgrid[:128,:192]
    for period in [2.,4.,8.]:
        for amp in [2.,4.,8.]:
            # Phase offset avoids vanishing sin at period2; report amplitude projection.
            carrier=np.cos(2.*np.pi*xx/period).astype(np.float32)
            truth=(96.+amp*carrier).astype(np.float32)
            row={'period_px':period,'amplitude_code':amp}
            for s in STRENGTHS:
                q=constrained_luma(truth,s)
                measured=float(np.sum((q[4:-4,4:-4]-96.)*carrier[4:-4,4:-4])/np.sum(carrier[4:-4,4:-4]**2))
                row[str(int(s))]={'clean_mse':mse(q,truth),'amplitude_retained':measured/amp,'max_delta':float(np.max(np.abs(q-truth)))}
            textures.append(row)
    report['synthetic']['clean_textures']=textures
    subtitles=[]
    for contrast in [2.,4.,8.,32.,191.]:
        truth=np.full((96,192),64.,np.float32)
        mask=np.zeros(truth.shape,bool)
        # Isolated 1px horizontal, vertical and diagonal strokes, representative tiny H/X glyphs.
        mask[20:53,30]=True; mask[20:53,48]=True; mask[36,30:49]=True
        for t in range(33):
            mask[20+t,70+t]=True;mask[20+t,102-t]=True
        truth[mask]=64.+contrast
        expanded=mask.copy()
        p=np.pad(mask,1)
        for dy in [-1,0,1]:
            for dx in [-1,0,1]:expanded |= p[1+dy:97+dy,1+dx:193+dx]
        row={'contrast':contrast,'stroke_count':int(np.sum(mask))}
        for s in STRENGTHS:
            q=constrained_luma(truth,s)
            binary=q>=(64.+contrast*.5)
            protected=constrained_luma(truth,s,expanded)
            row[str(int(s))]={'stroke_rmse':mse(q,truth,mask)**.5,'max_stroke_error':float(np.max(np.abs(q[mask]-truth[mask]))),
                'stroke_recall':float(np.mean(binary[mask])),'false_positive_count':int(np.sum(binary & ~mask)),
                'whole_mse':mse(q,truth),'known_region_protected_max_error':float(np.max(np.abs(protected-truth)))}
            if s==4 and contrast==4.:
                save(truth,'gray-subtitle-before.png');save(q,'gray-subtitle-s4.png')
        subtitles.append(row)
    report['synthetic']['one_pixel_subtitles']=subtitles
    edge=np.full((128,192),64.,np.float32);edge[:,96:]=192.
    ring=edge.copy()
    for offset,val in enumerate([6.,-4.,3.,-2.,1.]):
        ring[:,95-offset]+=val;ring[:,96+offset]-=val
    report['synthetic']['ringing_edge']={str(int(s)):{'mse_before':mse(ring,edge),
        'mse_after':mse(constrained_luma(ring,s),edge),
        'clean_edge_max_error':float(np.max(np.abs(constrained_luma(edge,s)-edge))),
        'overshoot':max(0.,float(np.max(constrained_luma(edge,s)))-192.),
        'undershoot':max(0.,64.-float(np.min(constrained_luma(edge,s))))} for s in STRENGTHS}
    # CPU-only wall time including allocations and boundary handling, no decode, no GPU extrapolation.
    for w,h in [(480,200),(1280,720),(1920,1080)]:
        y=rng.normal(96.,4.,(h,w)).astype(np.float32)
        for _ in range(2):constrained_luma(y,4.)
        samples=[]
        for _ in range(7):
            t=time.perf_counter();constrained_luma(y,4.);samples.append((time.perf_counter()-t)*1000.)
        report['timing'][f'{w}x{h}']={'scope':'NumPy luma filter CPU wall with allocations; excludes RGB transform, decode, upscale and playback',
            'samples_ms':samples,'median_ms':float(np.median(samples)),'p95_ms':float(np.percentile(samples,95))}
    # Exact functional invariants use broad random float values including near gamut limits.
    y=rng.uniform(0,255,(128,192)).astype(np.float32)
    checks=[]
    for s in STRENGTHS:
        q=constrained_luma(y,s)
        checks.append({'strength':s,'finite':bool(np.isfinite(q).all()),'max_delta':float(np.max(np.abs(q-y))),
            'flat_exact':bool(np.array_equal(constrained_luma(np.full_like(y,128),s),np.full_like(y,128))),
            'protected_exact':bool(np.array_equal(constrained_luma(y,s,np.ones_like(y,dtype=bool)),y))})
    report['invariants']=checks
    assert all(c['finite'] and c['max_delta']<=2.0001 and c['flat_exact'] and c['protected_exact'] for c in checks)
    (OUT/'results.json').write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
    compact={name:{s:round(v['rgb_psnr_gain'],6) for s,v in vals.items()} for name,vals in report['film'].items()}
    print(json.dumps({'film_psnr_gains_db':compact,'timing':report['timing'],'invariants':checks},indent=2))

if __name__=='__main__':main()
