function o=fourier_logits_sl(u)
M=evalin('base','VIB_MODEL');
o=max(-128,min(127,floor((double(M.w2)*u(:)+M.b2(:))/2^M.shift2)));
end
