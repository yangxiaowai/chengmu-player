#!/usr/bin/env python3
"""One prespecified S4 direction-gate comparison, no parameter search."""
import json, time
import numpy as np
from probe import ROOT, OUT, FRAMES, constrained_luma, candidate, luma, mse, metrics

def evaluate():
    capture=ROOT/'.build/repair-v036/post-temporal'
    def read(name):return np.fromfile(capture/name,dtype='<f4').reshape(200,480,4)[...,:3]*255.
    truth=np.array([read(f'clean-{n}.rgba32f') for n in FRAMES])
    modes={'original_s4':False,'strong_direction_s4':True}
    r={'scope':'Exactly one requested direction-gate change at S4; samephi/3x3/edgegate/cap. OriginalS4 vs stronger coherence protection. CPU only.',
       'gate':'coherence=(cmax-cmin)/(cmax+cmin+1e-3); gate=(1-smoothstep(.50,.85,coherence))*(1-smoothstep(12,32,cmax))',
       'film':{},'flats':[],'textures':[],'subtitles':[],'invariants':{},'timing':{}}
    for name in ['compressed-film','noisy-film','heavy-noisy-film']:
        src=np.array([read(f'{name}-temporal-{n}.rgba32f') for n in FRAMES])
        r['film'][name]={}
        for mode,strong in modes.items():
            dst=np.array([candidate(a,4,strong_direction=strong) for a in src])
            row=metrics(np.clip(src,0,255),dst,np.clip(truth,0,255))
            row['per_frame_psnr_gain']=[metrics(np.clip(a,0,255),b,np.clip(c,0,255))['rgb_psnr_gain'] for a,b,c in zip(src,dst,truth)]
            q=np.array([candidate(a,4,clip_output=False,strong_direction=strong) for a in src])
            row['no_clip_psnr_gain']=metrics(src,q,truth)['rgb_psnr_gain']
            r['film'][name][mode]=row
            assert row['max_luma_delta_code']<=2.0001
    rng=np.random.default_rng(29092026)
    for level in [16.,64.,128.,192.]:
        for sigma in [2.,4.,8.]:
            clean=np.full((128,192),level,np.float32)
            noisy=np.clip(clean+rng.normal(0,sigma,clean.shape).astype(np.float32),0,255)
            row={'level':level,'sigma':sigma,'mse_before':mse(noisy,clean)}
            for mode,strong in modes.items():
                q=constrained_luma(noisy,4,strong_direction=strong)
                row[mode]={'mse_after':mse(q,clean),'reduction_pct':100*(1-mse(q,clean)/mse(noisy,clean)),
                    'max_delta':float(np.max(np.abs(q-noisy)))}
            r['flats'].append(row)
    yy,xx=np.mgrid[:128,:192]
    for period in [2.,4.,8.]:
        for amp in [2.,4.,8.]:
            carrier=np.cos(2*np.pi*xx/period).astype(np.float32)
            clean=(96+amp*carrier).astype(np.float32)
            row={'period_px':period,'amplitude_code':amp}
            for mode,strong in modes.items():
                q=constrained_luma(clean,4,strong_direction=strong)
                measured=float(np.sum((q[4:-4,4:-4]-96)*carrier[4:-4,4:-4])/np.sum(carrier[4:-4,4:-4]**2))
                row[mode]={'mse':mse(q,clean),'amplitude_retained':measured/amp,'max_delta':float(np.max(np.abs(q-clean)))}
            r['textures'].append(row)
    for contrast in [2.,4.,8.,32.,191.]:
        clean=np.full((96,192),64.,np.float32)
        mask=np.zeros(clean.shape,bool)
        mask[20:53,30]=True;mask[20:53,48]=True;mask[36,30:49]=True
        for t in range(33):mask[20+t,70+t]=True;mask[20+t,102-t]=True
        clean[mask]=64+contrast
        row={'contrast':contrast,'stroke_count':int(mask.sum())}
        for mode,strong in modes.items():
            q=constrained_luma(clean,4,strong_direction=strong)
            binary=q>=64+contrast*.5
            missing=mask & ~binary
            row[mode]={'stroke_rmse':mse(q,clean,mask)**.5,'max_stroke_error':float(np.max(np.abs(q[mask]-clean[mask]))),
              'recall':float(np.mean(binary[mask])),'false_positive':int(np.sum(binary & ~mask)),
              'lost_stroke_yx':np.argwhere(missing).tolist(),'whole_mse':mse(q,clean)}
        r['subtitles'].append(row)
    # Additional diagonal/2D weak structures to make the directional protection boundary explicit.
    r['additional_texture']={}
    for name,carrier in {'diagonal_sine4':np.cos(2*np.pi*(xx+yy)/4),
        'checkerboard2':np.where((xx+yy)%2,1.,-1.),
        'crossed_sine4':(np.cos(2*np.pi*xx/4)+np.cos(2*np.pi*yy/4))/2}.items():
        carrier=carrier.astype(np.float32);clean=(96+2*carrier).astype(np.float32)
        r['additional_texture'][name]={}
        for mode,strong in modes.items():
            q=constrained_luma(clean,4,strong_direction=strong)
            retained=float(np.sum((q[4:-4,4:-4]-96)*carrier[4:-4,4:-4])/(2*np.sum(carrier[4:-4,4:-4]**2)))
            r['additional_texture'][name][mode]={'amplitude_retained':retained,'mse':mse(q,clean),'max_delta':float(np.max(np.abs(q-clean)))}
    # New mode clean-film deviation, exact constants/strong edge and bound.
    clean_out=np.array([candidate(a,4,strong_direction=True) for a in truth])
    r['invariants']['clean_film_luma_mse']=mse(luma(np.clip(truth,0,255)),luma(clean_out))
    edge=np.full((128,192),64,np.float32);edge[:,96:]=192
    r['invariants']['strong_edge_exact']=bool(np.array_equal(constrained_luma(edge,4,strong_direction=True),edge))
    flat=np.full_like(edge,128)
    r['invariants']['flat_exact']=bool(np.array_equal(constrained_luma(flat,4,strong_direction=True),flat))
    for w,h in [(480,200),(1280,720),(1920,1080)]:
        y=rng.normal(96,4,(h,w)).astype(np.float32)
        r['timing'][f'{w}x{h}']={}
        for mode,strong in modes.items():
            for _ in range(2):constrained_luma(y,4,strong_direction=strong)
            ts=[]
            for _ in range(5):
                t=time.perf_counter();constrained_luma(y,4,strong_direction=strong);ts.append((time.perf_counter()-t)*1000)
            r['timing'][f'{w}x{h}'][mode]={'median_ms':float(np.median(ts)),'p95_ms':float(np.percentile(ts,95)),'samples':ts}
    assert r['invariants']['strong_edge_exact'] and r['invariants']['flat_exact']
    (OUT/'direction-results.json').write_text(json.dumps(r,indent=2)+'\n')
    print(json.dumps(r,indent=2))

if __name__=='__main__':evaluate()
