#!/usr/bin/env python3
"""Render archived MATLAB values with Python, after verifying the integer reference.

These images are not MATLAB GUI screenshots and do not record a new MATLAB run.
Run from any folder; input hashes are listed in docs/evidence/capture_manifest.json.
"""
from pathlib import Path
import json
import shutil
import sys
import numpy as np
from scipy.io import loadmat
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'tools'))
from model import fft64, features, npu
d=loadmat(root/'docs/evidence/2026-09-17_matlab_reference.mat',simplify_cells=True)
cases=np.loadtxt(root/'data/cases.csv',delimiter=',',dtype=np.int64)
recorded=np.loadtxt(root/'data/val_samples.csv',delimiter=',',dtype=np.int64)
assert all(np.any(np.all(recorded == x,axis=1)) for x in cases[:16])
m=json.loads((root/'data/model.json').read_text())
for key in ['w1','w2','b1','b2','shift1','shift2']:
    assert np.array_equal(np.asarray(d['M'][key]),np.asarray(m[key])),key
for k,x in enumerate(cases):
    re,im,_=fft64(x); f=features(x); h,o,_=npu(f,m)
    for key,actual in [('expected_r',re),('expected_i',im),('expected_f',f),('expected_h',h),('expected_o',o)]:
        np.testing.assert_array_equal(d[key][k],actual)
dest=root/'docs/images'
plt.rcParams.update({'font.size':11,'axes.spines.top':False,'axes.spines.right':False})
fig,axes=plt.subplots(1,3,figsize=(14,6),constrained_layout=True)
for ax,key,title in zip(axes,['expected_f','expected_h','expected_o'],['4 band features','4 hidden activations','2 output logits']):
    a=d[key][:16]; im=ax.imshow(a,aspect='auto',cmap='viridis' if key!='expected_o' else 'coolwarm')
    ax.set(title=title,xlabel='Channel index',ylabel='Recorded Golden case index (0..15)',xticks=range(a.shape[1]),yticks=range(0,16,2))
    fig.colorbar(im,ax=ax,label='Integer code')
fig.suptitle('Archived MATLAB Golden: 16 recorded validation frames (synthetic edge cases excluded)\nReplotted from 2026-09-17 .mat using Python; no new MATLAB run',fontsize=14)
fig.savefig(dest/'matlab_saved_npu_tensors.png',dpi=170);plt.close(fig)
fig,axes=plt.subplots(2,1,figsize=(13,7),constrained_layout=True)
for k in [0,1]:
    axes[0].plot(np.arange(64),cases[k],'.-',label=f'case {k}')
    magnitude=np.hypot(d['expected_r'][k],d['expected_i'][k])
    axes[1].plot(np.arange(1,32)*1000/64,magnitude[1:32],'.-',label=f'case {k}')
axes[0].set(title='Original 64-sample input frames',xlabel='Sample index',ylabel='Raw X counts')
axes[1].set(title='Saved integer FFT output: magnitude, bins 1..31 (DC omitted from display)',xlabel='Nominal frequency (Hz), fs=1000 Hz',ylabel='FFT/64 magnitude (counts)')
for ax in axes: ax.grid(alpha=.25); ax.legend()
fig.suptitle('Archived MATLAB integer FFT reference\nPython rendering of saved values; no Hann window / no PSD normalization',fontsize=14)
fig.savefig(dest/'matlab_saved_fft.png',dpi=170);plt.close(fig)
print('20 archived MATLAB cases match the current independent integer reference. Saved 2 plots.')
