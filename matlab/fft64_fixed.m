function [re,im,feat] = fft64_fixed(x)
% Handwritten arithmetic Golden; doubles represent every integer exactly here.
assert(numel(x)==64); x=double(x(:)); re=zeros(64,1); im=re;
for n=0:63
    a=n; r=0;
    for b=1:6, r=2*r+mod(a,2); a=floor(a/2); end
    re(n+1)=x(r+1);
end
twre=max(-32768,min(32767,round(32768*cos(-2*pi*(0:31)/64))));
twim=max(-32768,min(32767,round(32768*sin(-2*pi*(0:31)/64))));
for stage=1:6
    span=2^stage; half=span/2;
    for base=0:span:63
        for j=0:half-1
            a=base+j+1; b=a+half; t=j*64/span+1;
            tr=floor((re(b)*twre(t)-im(b)*twim(t))/32768);
            ti=floor((re(b)*twim(t)+im(b)*twre(t))/32768);
            ar=re(a); ai=im(a);
            re(a)=max(-32768,min(32767,floor((ar+tr)/2)));
            im(a)=max(-32768,min(32767,floor((ai+ti)/2)));
            re(b)=max(-32768,min(32767,floor((ar-tr)/2)));
            im(b)=max(-32768,min(32767,floor((ai-ti)/2)));
        end
    end
end
bands=[1 6;7 12;13 20;21 31]; feat=zeros(4,1);
for j=1:4
    idx=(bands(j,1):bands(j,2))+1;
    feat(j)=min(127,floor(sum(abs(re(idx))+abs(im(idx)))/32));
end
end
