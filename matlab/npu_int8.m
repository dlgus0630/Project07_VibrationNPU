function [hidden,logits,cls] = npu_int8(feat,M)
a=double(M.w1)*double(feat(:))+double(M.b1(:));
hidden=max(0,min(127,floor(a/2^M.shift1)));
b=double(M.w2)*hidden+double(M.b2(:));
logits=max(-128,min(127,floor(b/2^M.shift2)));
cls=double(logits(2)>logits(1));
end
