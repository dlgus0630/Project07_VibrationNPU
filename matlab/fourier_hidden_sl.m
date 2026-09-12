function h=fourier_hidden_sl(u)
M=evalin('base','VIB_MODEL');
h=max(0,min(127,floor((double(M.w1)*u(:)+M.b1(:))/2^M.shift1)));
end
