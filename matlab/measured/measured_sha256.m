function value = measured_sha256(path)
% 역할: 원본 파일이 바뀌었는지 비교할 수 있도록 내용의 지문을 만듭니다.
% 입력 path는 파일 경로, 출력 value는 64자리 SHA-256 16진수 문자열입니다.
% [주1] 텍스트로 해석하지 않고 바이트 그대로 읽어 줄바꿈/인코딩 변화도 구분합니다.
% [주2] 1 MiB씩 나누어 읽어 큰 파일도 메모리 부담을 줄이고, onCleanup으로 파일을 닫습니다.
% 해시 일치는 비교 대상 파일과 같다는 뜻이며, 측정 정확도나 실험 조건 자체의 증명은 아닙니다.
%MEASURED_SHA256 SHA-256 of the exact file bytes, with no text conversion.
% A normal desktop/Online MATLAB JVM is required. No shell is invoked.
assert(usejava('jvm'), 'Measured:JVMRequired', ...
    'SHA-256 verification requires MATLAB with its JVM enabled.');
fid = fopen(path, 'rb');
assert(fid >= 0, 'Measured:MissingFile', 'Cannot read file: %s', path);
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
digest = java.security.MessageDigest.getInstance('SHA-256');
while ~feof(fid)
    bytes = fread(fid, 1048576, '*uint8');
    if ~isempty(bytes)
        digest.update(typecast(bytes, 'int8'));
    end
end
value = lower(reshape(dec2hex(typecast(digest.digest(), 'uint8'), 2).', 1, []));
end
