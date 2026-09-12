#include <stdio.h>
#include <stdlib.h>
#include "golden.h"
static FILE *open_mem(const char *name) {
    char path[256];FILE *f;
    if(snprintf(path,sizeof path,"data/%s.mem",name)<0)exit(2);
    f=fopen(path,"r");if(!f){perror(path);exit(2);}return f;
}
static int value(FILE *f,int bits,int sign) {
    unsigned v;if(fscanf(f,"%x",&v)!=1){fputs("truncated vector\n",stderr);exit(2);}
    return sign && (v&(1U<<(bits-1)))?(int)v-(1<<bits):(int)v;
}
int main(void) {
    FILE *x=open_mem("samples"),*re=open_mem("fft_re"),*im=open_mem("fft_im");
    FILE *f=open_mem("features"),*h=open_mem("hidden"),*o=open_mem("logits"),*c=open_mem("class");
    int test,n;int16_t samples[64];inference_result r;
    for(test=0;test<20;test++) {
        for(n=0;n<64;n++)samples[n]=(int16_t)value(x,16,1);
        infer_integer(samples,&r);
        for(n=0;n<64;n++)if(r.re[n]!=value(re,16,1)||r.im[n]!=value(im,16,1))goto fail;
        for(n=0;n<4;n++)if(r.features[n]!=value(f,8,0)||r.hidden[n]!=value(h,8,0))goto fail;
        for(n=0;n<2;n++)if(r.logits[n]!=value(o,8,1))goto fail;
        if(r.class_id!=value(c,8,0))goto fail;
    }
    fclose(x);fclose(re);fclose(im);fclose(f);fclose(h);fclose(o);fclose(c);
    puts("HOST C PASS: 20 windows, 2560 FFT components, 220 result values");return 0;
fail:fprintf(stderr,"HOST C FAIL case %d element %d\n",test,n);return 1;
}
