function f=fourier_features_sl(u)
bands=[1 6;7 12;13 20;21 31]; f=zeros(4,1);
for j=1:4
    idx=(bands(j,1):bands(j,2))+1;
    f(j)=min(127,floor(sum(abs(u(idx))+abs(u(idx+64)))/32));
end
end
