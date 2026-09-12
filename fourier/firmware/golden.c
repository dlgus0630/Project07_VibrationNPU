// Portable independent C reference, shared by host verification and Zynq ARM.
#include "golden.h"
#include "model_data.h"
static int32_t floor_shift(int64_t v,unsigned shift) {
    int64_t d=(int64_t)1<<shift;
    return (int32_t)(v>=0?v/d:-((-v+d-1)/d));
}
static int32_t clamp(int32_t v,int32_t low,int32_t high) { return v<low?low:v>high?high:v; }
void infer_integer(const int16_t samples[64],inference_result *r) {
    unsigned n,s,j,base,k;
    for(n=0;n<64;n++) {
        unsigned reverse=0,v=n;
        for(j=0;j<6;j++){reverse=(reverse<<1)|(v&1);v>>=1;}
        r->re[reverse]=samples[n];r->im[reverse]=0;
    }
    for(s=1;s<=6;s++) {
        unsigned span=1U<<s,half=span/2;
        for(base=0;base<64;base+=span)for(j=0;j<half;j++) {
            unsigned a=base+j,b=a+half,t=j*64/span;
            int32_t ar=r->re[a],ai=r->im[a];
            int32_t tr=floor_shift((int64_t)r->re[b]*tw_re[t]-(int64_t)r->im[b]*tw_im[t],15);
            int32_t ti=floor_shift((int64_t)r->re[b]*tw_im[t]+(int64_t)r->im[b]*tw_re[t],15);
            r->re[a]=(int16_t)clamp(floor_shift(ar+tr,1),-32768,32767);
            r->im[a]=(int16_t)clamp(floor_shift(ai+ti,1),-32768,32767);
            r->re[b]=(int16_t)clamp(floor_shift(ar-tr,1),-32768,32767);
            r->im[b]=(int16_t)clamp(floor_shift(ai-ti,1),-32768,32767);
        }
    }
    for(n=0;n<4;n++)r->features[n]=0;
    {uint32_t sums[4]={0,0,0,0};
        for(k=1;k<32;k++) {
            unsigned band=k<=6?0:k<=12?1:k<=20?2:3;
            int32_t re=r->re[k],im=r->im[k];
            sums[band]+=(uint32_t)((re<0?-re:re)+(im<0?-im:im));
        }
        for(n=0;n<4;n++)r->features[n]=(uint8_t)clamp((int32_t)(sums[n]>>5),0,127);
    }
    for(n=0;n<4;n++) {
        int64_t acc=b1[n];for(j=0;j<4;j++)acc+=(int32_t)r->features[j]*w1[n][j];
        r->hidden[n]=(uint8_t)clamp(floor_shift(acc,SHIFT1),0,127);
    }
    for(n=0;n<2;n++) {
        int64_t acc=b2[n];for(j=0;j<4;j++)acc+=(int32_t)r->hidden[j]*w2[n][j];
        r->logits[n]=(int8_t)clamp(floor_shift(acc,SHIFT2),-128,127);
    }
    r->class_id=(uint8_t)(r->logits[1]>r->logits[0]);
}
