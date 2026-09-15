function value=source_digest(root)
% Byte-identical to tools/gates.py. JVM is available in normal MATLAB Online sessions.
d=dir(fullfile(root,'**','*'));paths={};
for k=1:numel(d)
    if d(k).isdir,continue;end
    full=fullfile(d(k).folder,d(k).name);rel=strrep(full(numel(root)+2:end),'\','/');
    parts=strsplit(rel,'/');
    if any(ismember(parts,{'artifacts','reports','build','measurements','__pycache__','.git'})),continue;end
    [~,~,ext]=fileparts(rel);
    if strcmpi(ext,'.md'),continue;end
    paths{end+1}=rel;
end
paths=sort(paths);md=java.security.MessageDigest.getInstance('SHA-256');
for k=1:numel(paths)
    md.update(typecast(uint8(unicode2native(paths{k},'UTF-8')),'int8'));
    f=fopen(fullfile(root,paths{k}),'rb');assert(f>=0,'Source missing');bytes=fread(f,Inf,'*uint8');fclose(f);
    md.update(typecast(bytes,'int8'));
end
value=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2)',1,[]));
end
