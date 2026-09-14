#!/usr/bin/env python3
"""PC-only MLP training and INT8 export for synthetic or recorded vibration windows."""
import argparse,json
from pathlib import Path
import numpy as np
from model import features, npu, fft64, twiddles

ROOT=Path(__file__).resolve().parents[1]
DATA=ROOT/'data'

def mem(name, values, bits=16):
    (DATA/name).write_text(''.join(f'{int(x)&((1<<bits)-1):0{bits//4}x}\n' for x in values))

def dataset(seed,count):
    rng=np.random.default_rng(seed); waves=[];labels=[]
    t=np.arange(64)
    for i in range(count):
        fault=i%2;freq=rng.uniform(3.4,5.3);amp=rng.uniform(600,2600)
        x=amp*np.sin(2*np.pi*freq*t/64+rng.uniform(0,2*np.pi))
        x+=rng.normal(0,35,64)+rng.uniform(-2000,2000)
        if fault:
            x+=rng.uniform(.65,1.2)*amp*np.sin(2*np.pi*freq*2*t/64+rng.uniform(0,6.28))
            x+=rng.uniform(.25,.65)*amp*np.sin(2*np.pi*freq*3*t/64+rng.uniform(0,6.28))
            x+=rng.normal(0,rng.uniform(90,250),64)
        waves.append(np.clip(np.rint(x),-32768,32767).astype(int).tolist()); labels.append(fault)
    return waves,np.array(labels)

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--real-data',type=Path,help='Directory containing dataset.json and train/val_samples.csv, train/val_labels.csv')
    args=parser.parse_args()
    DATA.mkdir(parents=True,exist_ok=True)
    source='synthetic only; no real machine fault measurements'
    if args.real_data:
        meta=json.loads((args.real_data/'dataset.json').read_text())
        sensors=meta['sensor'] if isinstance(meta['sensor'],list) else [meta['sensor']]
        assert meta['sample_rate_hz']==1000 and sensors and set(sensors)<= {'MPU-6500','MPU-9250'} and meta['axis']=='X' and meta['range_g']==2
        assert meta['split_by']=='run_id','Split by separate acquisition runs, not adjacent overlapping windows.'
        waves=np.loadtxt(args.real_data/'train_samples.csv',delimiter=',',dtype=int,ndmin=2)
        val=np.loadtxt(args.real_data/'val_samples.csv',delimiter=',',dtype=int,ndmin=2)
        y=np.loadtxt(args.real_data/'train_labels.csv',dtype=int,ndmin=1)
        yv=np.loadtxt(args.real_data/'val_labels.csv',dtype=int,ndmin=1)
        assert waves.shape[1]==64 and val.shape[1]==64 and len(val)>=16
        for a,l in [(waves,y),(val,yv)]:
            assert len(a)==len(l) and set(l)=={0,1} and a.min()>=-32768 and a.max()<=32767
        assert not (set(map(tuple,waves))&set(map(tuple,val))),'Duplicate windows cross the train/validation split.'
        waves=waves.tolist();val=val.tolist();source='user-supplied real recordings; provenance in data/dataset_source.json'
        (DATA/'dataset_source.json').write_text(json.dumps(meta,indent=2)+'\n')
    else:
        waves,y=dataset(410,1600); val,yv=dataset(411,400)
        (DATA/'dataset_source.json').write_text(json.dumps({'type':'synthetic','sample_rate_hz':1000,'sensor_contract':'MPU-6500/9250 X +/-2g'},indent=2)+'\n')
    f=np.array([features(x) for x in waves]);fv=np.array([features(x) for x in val])
    x=f.astype(np.float32)/128; xv=fv.astype(np.float32)/128
    rng=np.random.default_rng(412)
    p=[rng.normal(0,.4,(4,4)).astype(np.float32),np.ones(4,dtype=np.float32)*.1,
       rng.normal(0,.4,(2,4)).astype(np.float32),np.zeros(2,dtype=np.float32)]
    m=[np.zeros_like(a) for a in p];v=[np.zeros_like(a) for a in p]
    history=[]
    for step in range(1,1601):
        z=x@p[0].T+p[1];h=np.clip(z,0,127/64)
        logits=h@p[2].T+p[3]
        ex=np.exp(logits-logits.max(axis=1,keepdims=True));prob=ex/ex.sum(axis=1,keepdims=True)
        delta=prob.copy();delta[np.arange(len(y)),y]-=1;delta/=len(y)
        dz=(delta@p[2])*((z>0)&(z<127/64))
        grads=[dz.T@x,dz.sum(axis=0),delta.T@h,delta.sum(axis=0)]
        for j,g in enumerate(grads):
            m[j]=.9*m[j]+.1*g;v[j]=.999*v[j]+.001*g*g
            p[j]-=.012*(m[j]/(1-.9**step))/(np.sqrt(v[j]/(1-.999**step))+1e-8)
        if step%100==0:
            history.append([step,float(-np.log(prob[np.arange(len(y)),y]+1e-12).mean())])
    def wquant(w):
        power=int(np.ceil(np.log2(np.max(np.abs(w))/127)))
        return np.clip(np.rint(w/(2.**power)),-127,127).astype(int),power
    w1,e1=wquant(p[0]);w2,e2=wquant(p[2])
    # Input 1/128, hidden 1/64, logits 1/16; power-of-two scales only.
    model={'w1':w1.tolist(),'b1':np.rint(p[1]/(2.**(e1-7))).astype(int).tolist(),
           'w2':w2.tolist(),'b2':np.rint(p[3]/(2.**(e2-6))).astype(int).tolist(),
           'shift1':1-e1,'shift2':2-e2,'input_scale':1/128,'hidden_scale':1/64,
           'output_scale':1/16,'weight1_scale':2.**e1,'weight2_scale':2.**e2}
    assert 0<model['shift1']<24 and 0<model['shift2']<24
    assert max(abs(b) for b in model['b1']+model['b2'])+4*128*128<2**31
    pred=np.argmax(np.clip(xv@p[0].T+p[1],0,127/64)@p[2].T+p[3],axis=1)
    qi=np.array([npu(a,model)[2] for a in fv])
    assert all(a.dtype==np.float32 for a in p)
    metrics={'dataset':source,
       'seed_train':410,'seed_val':411,'seed_weights':412,'train_count':len(y),'val_count':len(yv),
       'fp32_accuracy':float((pred==yv).mean()),'int8_accuracy':float((qi==yv).mean()),
       'fp32_int8_agreement':float((pred==qi).mean()),'confusion':[[int(((yv==a)&(qi==b)).sum()) for b in range(2)] for a in range(2)]}
    assert metrics['int8_accuracy']>=.9,metrics
    (DATA/'model.json').write_text(json.dumps(model,indent=2)+'\n')
    (DATA/'training_metrics.json').write_text(json.dumps(metrics,indent=2)+'\n')
    np.savez(DATA/'float_weights.npz',w1=p[0],b1=p[1],w2=p[2],b2=p[3])
    np.savetxt(DATA/'training_history.csv',history,delimiter=',',header='epoch,loss',comments='')
    for name,arr in [('train_samples',waves),('val_samples',val),('train_features',f),('val_features',fv)]:
        np.savetxt(DATA/(name+'.csv'),arr,fmt='%d',delimiter=',')
    np.savetxt(DATA/'train_labels.csv',y,fmt='%d');np.savetxt(DATA/'val_labels.csv',yv,fmt='%d')
    # Neuron pair 0/1, pair 2/3, then output pair 0/1. Each pair has four MACs.
    for lane in range(2): mem(f'w{lane}.mem',list(w1[lane])+list(w1[lane+2])+list(w2[lane]),8)
    mem('bias.mem',model['b1']+model['b2'],32);mem('shift.mem',[model['shift1'],model['shift2']],8)
    mem('tw_re.mem',[a for a,b in twiddles()]);mem('tw_im.mem',[b for a,b in twiddles()])
    order=[int(np.flatnonzero(yv==0)[0]),int(np.flatnonzero(yv==1)[0])]
    order += [i for i in range(len(val)) if i not in order][:14]
    cases=[val[i] for i in order]+[[0]*64,[32767]*64,[-32768]*64,[32767]+[0]*63]
    mem('samples.mem',[a for case in cases for a in case])
    mem('features.mem',[a for case in cases for a in features(case)],8)
    mem('hidden.mem',[a for case in cases for a in npu(features(case),model)[0]],8)
    mem('logits.mem',[a for case in cases for a in npu(features(case),model)[1]],8)
    mem('class.mem',[npu(features(case),model)[2] for case in cases],8)
    mem('fft_re.mem',[a for case in cases for a in fft64(case)[0]])
    mem('fft_im.mem',[a for case in cases for a in fft64(case)[1]])
    np.savetxt(DATA/'cases.csv',cases,fmt='%d',delimiter=',')
    # A header contains numerical constants only, never generated RTL.
    lines=['#ifndef MODEL_DATA_H','#define MODEL_DATA_H','#include <stdint.h>']
    for key,dims in [('w1','[4][4]'),('b1','[4]'),('w2','[2][4]'),('b2','[2]')]:
        valstr=str(model[key]).replace('[','{').replace(']','}')
        lines.append(f'static const int32_t {key}{dims} = {valstr};')
    for key in ['shift1','shift2']: lines.append(f'#define {key.upper()} {model[key]}')
    for name,items in [('tw_re',[a for a,b in twiddles()]),('tw_im',[b for a,b in twiddles()])]:
        lines.append(f'static const int16_t {name}[32] = '+str(items).replace('[','{').replace(']','}')+';')
    lines.append('static const int16_t demo_samples[2][64] = '+str(cases[:2]).replace('[','{').replace(']','}')+';')
    lines.append('#endif');(ROOT/'fourier/firmware/model_data.h').write_text('\n'.join(lines)+'\n')
    print(json.dumps(metrics,indent=2)); print('PC TRAIN/EXPORT PASS')

if __name__=='__main__': main()
