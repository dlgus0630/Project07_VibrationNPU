function [next,y] = vib3d_supervisor_step(state,cls,valid,heartbeat,armed,clear_request,duty,watchdog_ticks)
% [읽기 안내] 한 샘플마다 판정 이력과 heartbeat를 보고 안전 정책 상태를 갱신합니다.
% 입력 state/출력 next는 5×1 상태, y는 7×1 관찰 출력입니다(아래 순서 참고).
% cls=0은 정상, 0이 아니면 이상입니다. valid=true일 때만 새 판정으로 셉니다.
% duty와 allowed_duty는 0~1 비율이며, watchdog_ticks는 초가 아닌 샘플 수입니다.
% [주1] 이 함수는 정책의 관찰 모델입니다. RTL 클럭 단위 재현이나 실제 구동기,
% 연구용 외력에 연결된 피드백 제어기가 아니므로 실제 정지 성능과 구분합니다.
% Sampled policy observer, not a cycle-accurate RTL model or plant feedback.
% state=[run_length latched cause watchdog_ticks abnormal_count].
% y=[run_length warning derated latched cause allowed_duty abnormal_count].
next=state;
if clear_request
    % [주2] 명시적인 해제 요청만 래치·원인·타이머를 초기화합니다.
    % 누적 이상 횟수(state(5))는 유지하여 장기 이력을 남깁니다.
    next(1:4)=0;
else
    if valid
        % [주3] 연속 이상 1회는 경고, 2회는 출력 제한, 3회는 래치 정지입니다.
        % 정상 판정은 연속 횟수를 끊지만 이미 걸린 래치는 자동 해제하지 않습니다.
        if cls~=0
            next(1)=min(3,state(1)+1);
            next(5)=min(65535,state(5)+1);
            if state(1)>=2
                next(2)=1;
                next(3)=double(bitor(uint8(next(3)),uint8(1)));
            end
        else
            next(1)=0;
        end
    end
    if ~armed || heartbeat
        % [주4] 비활성 상태이거나 heartbeat가 오면 타이머를 지웁니다.
        % 활성 중 신호가 끊긴 채 지정 샘플 수에 도달하면 원인 비트 2를 기록합니다.
        % 원인 비트 1은 이상 연속 검출입니다. OR 연산으로 두 원인을 함께 보존합니다.
        next(4)=0;
    elseif state(2)==0
        if state(4)>=watchdog_ticks-1
            next(2)=1;
            next(3)=double(bitor(uint8(next(3)),uint8(2)));
        else
            next(4)=state(4)+1;
        end
    end
end
warning_state=next(2)==0 && next(1)>=1;
derated=next(2)==0 && next(1)>=2;
allowed=max(0,min(1,duty));
% [주5] 허용 duty는 요청값을 0~1로 제한하고, 두 번 연속 이상이면 최대 25%입니다.
% 래치·비활성·해제 요청 중에는 0을 내보냅니다. y 자체는 기계 입력을 바꾸지 않습니다.
if derated, allowed=min(allowed,0.25); end
if next(2)~=0 || ~armed || clear_request, allowed=0; end
y=[next(1);double(warning_state);double(derated);next(2);next(3);allowed;next(5)];
end
