function v=fourier_fft_sl(u)
[a,b]=fft64_fixed(u); v=[a;b];
end
