#!/usr/bin/env python3
"""Render four RTL FSMs and seven subsystem behavior sheets from current VHDL.

The four CASE/next_state transition graphs are extracted from their source.
Other sheets explain concurrent counters/flags/protocols and are labelled as
behavior diagrams. Graphviz DOT, SVG and PNG remain editable/reproducible.
"""
from pathlib import Path
import hashlib
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/state_diagrams'
FONT = 'Noto Sans CJK KR'
SHEETS = []
# Invisible edges arrange independent panels vertically without implying a
# hardware connection. Real inter-panel feedback is drawn without rank impact.
PANEL_LAYOUT = {
    '05_spi_behavior': [('high', 'miso'), ('ff1', 'notes')],
    '06_motor_run_behavior': [('on', 'ol'), ('limit', 'tick'), ('start', 'notes')],
    '07_safety_behavior': [('latched', 'wd0'), ('wdtrip', 'simple'), ('simple', 'notes')],
    '08_axi_behavior': [('b', 'ar'), ('r', 'status'), ('status', 'pulses'), ('pulses', 'notes')],
    '09_speed_divider_behavior': [('valid', 'di'), ('run', 'notes')],
    '10_quadrature_behavior': [('p11', 'pos'), ('pos', 'illegal'), ('illegal', 'notes'),
                               ('timeout', 'notes'), ('overflow', 'notes')],
    '11_reset_pwm_behavior': [('r00', 'disabled'), ('count', 'notes')],
}


def quote(value):
    return json.dumps(str(value), ensure_ascii=False)


class Graph:
    def __init__(self, stem, title, subtitle, entities, fsm=False):
        self.stem, self.entities, self.fsm = stem, entities, fsm
        self.parts = [
            'digraph G {',
            f'graph [fontname={quote(FONT)}, fontsize=24, rankdir=TB, '
            'bgcolor="white", pad=0.45, nodesep=0.5, ranksep=0.65, '
            'compound=true, dpi=150, labelloc=t, labeljust=l, '
            f'label={quote(title + chr(10) + subtitle)}];',
            f'node [fontname={quote(FONT)}, fontsize=17, shape=box, '
            'style="rounded,filled", fillcolor="#edf5fc", color="#476681", '
            'penwidth=1.6, margin="0.22,0.14"];',
            f'edge [fontname={quote(FONT)}, fontsize=14, color="#405b70", '
            'fontcolor="#263e50", penwidth=1.5, arrowsize=0.8];',
        ]

    def node(self, key, title, body='', kind='state'):
        colors = {'state': '#edf5fc', 'logic': '#eff7f0', 'action': '#fff3dd',
                  'fault': '#fcebec', 'note': '#f5f5f4', 'decision': '#fff7e9'}
        label = title + ('\n' + body if body else '')
        shape = 'diamond' if kind == 'decision' else 'box'
        self.parts.append(f'{quote(key)} [label={quote(label)}, shape={shape}, '
                          f'fillcolor={quote(colors[kind])}];')

    def edge(self, start, end, label='', dashed=False, **kwargs):
        attrs = {'label': label}
        if dashed:
            attrs.update(style='dashed', color='#987290')
        attrs.update(kwargs)
        self.parts.append(f'{quote(start)} -> {quote(end)} [' +
                          ', '.join(f'{key}={quote(value)}' for key, value in attrs.items()) + '];')

    def panel(self, key, title):
        self.parts.append(f'subgraph cluster_{key} {{ label={quote(title)}; '
                          'fontsize=20; color="#b3c5d2"; style="rounded"; margin=22;')

    def end_panel(self):
        self.parts.append('}')

    def note(self, key, body):
        self.node(key, '읽는 기준 / 코드 근거', body, 'note')

    def save(self):
        for start, end in PANEL_LAYOUT.get(self.stem, []):
            self.edge(start, end, style='invis', weight='20')
        self.parts.append('}')
        dot = OUT / (self.stem + '.dot')
        dot.write_text('\n'.join(self.parts) + '\n', encoding='utf-8')
        for format_name in ['svg', 'png']:
            result = subprocess.run(['dot', '-T' + format_name, str(dot), '-o',
                                     str(OUT / (self.stem + '.' + format_name))],
                                    capture_output=True, text=True, timeout=60)
            assert result.returncode == 0, result.stderr
        SHEETS.append({'stem': self.stem, 'kind': 'RTL FSM' if self.fsm else '동작도',
                       'entities': self.entities})


FSM = {
    '01_core_fsm': {
        'entity': 'vibration_core', 'file': 'vibration_core_fsm.vhd',
        'title': '01 · 가속기 전체 실행 FSM · 6 states',
        'actions': {
            'IDLE': 'start 수락: busy=1 / cycles=0',
            'FSTART': 'fft_start=1 (이 상태 한 클럭)',
            'FWAIT': 'fft_done 관측 시 features 저장',
            'NSTART': 'npu_start=1 (이 상태 한 클럭)',
            'NWAIT': 'npu_done 관측 시 hidden/logits/class 저장\nresult_index=0',
            'STORE': 'word 256 + result_index에 기록\nfeatures 4 + hidden 4 + logits 2 + class 1',
        },
        'notes': 'clocked_proc / nextstate_proc\nresult_capture_proc / result_index_proc / result_write_proc\n'
                 'handshake_proc: STORE의 index=10 처리 에지에서 busy=0, done=1\n'
                 '기본 done=0이므로 완료 펄스는 한 클럭. STORE 반복에서 index 증가.',
    },
    '02_fft_fsm': {
        'entity': 'fft64_features', 'file': 'fft64_features_fsm.vhd',
        'title': '02 · FFT64 + 4-band feature FSM · 9 states',
        'actions': {
            'IDLE': 'start 수락: busy=1 / load_index=0',
            'LREQ': 'sample_en=1 / sample_addr=load_index',
            'LWAIT': 'BRAM 읽기 대기 한 상태',
            'LSTORE': 'bit-reverse 위치에 INT16 입력 저장\nimag=0 / 미완료 시 load_index 증가',
            'READ_STATE': 'A/B 복소 값과 twiddle 레지스터 적재',
            'MULT': '복소 곱을 산술 >>15 후 저장',
            'WRITE_STATE': 'butterfly A ± B·W /2, INT16 포화\n메모리와 pair/group/stage 순번 갱신',
            'FACC': 'bin 1..31의 |Re|+|Im| 대역 누적\n미완료 시 frequency_bin 증가',
            'FINISH': '4개 대역 합 >>5 / 0..127 포화\nfeatures 저장 / busy=0 / done=1',
        },
        'notes': 'load_index: 0..63 / fft_stage: 1..6\n'
                 'last_pair: pair_index=half_span-1\nlast_group: group_base+group_span>=64\n'
                 'last_stage: fft_stage=6\n대역: 1..6 / 7..12 / 13..20 / 21..31\n'
                 '실제 상태 이름 READ_STATE, WRITE_STATE를 유지한다.',
    },
    '03_npu_fsm': {
        'entity': 'npu_2pe', 'file': 'npu_2pe_fsm.vhd',
        'title': '03 · INT8 2-PE NPU FSM · 4 states',
        'actions': {
            'IDLE': 'start 수락: 입력 특징 저장 / hidden=0\nneuron_pair=0 / busy=1 / cycles=0',
            'INIT': 'clear_mac=1 → 두 PE에 bias 적재\ninput_index=0',
            'MAC': 'enable_mac=1 → 두 뉴런 동시 누산\n입력 0..3 / 미완료 시 input_index 증가',
            'PACK': '양자화 후 두 결과 저장\npair 0/1: hidden ReLU / pair 2: logits·class',
        },
        'notes': 'neuron_pair=0: 은닉 뉴런 0·1, =1: 은닉 뉴런 2·3, =2: 두 logits\n'
                 '마지막 PACK 처리 에지: busy=0 / done=1\n'
                 '그 외 PACK 처리 에지: neuron_pair 증가\n'
                 'U_PE0 / U_PE1: mac_pe / rst > clear(bias) > enable(acc+x×w) > hold\n'
                 'class_id = (quantized1 > quantized0). 같은 점수는 class 0.',
    },
    '04_pi_fsm': {
        'entity': 'pid_fixed', 'file': 'pid_controller_fsm.vhd',
        'title': '04 · 고정소수점 PI + anti-windup FSM · 11 states',
        'actions': {
            'IDLE': 'start 수락: error_reg=reference-measured\ny_hold 저장 / busy=1',
            'FILTER': '측정 변화 필터 derivative와 y_previous 저장\n제어 계산의 d_term은 0',
            'PRODUCTS': 'P=(Kp×error)>>16 저장\n적분 후보 하위 합 + carry 저장 / d_term=0',
            'PRODUCTS_HI': '상위 합 + 이전 carry 결합\n적분 후보를 -4096..4096으로 제한',
            'PROPOSE_ADD': 'proposed_sum=P+integral_candidate',
            'PROPOSE_SUB': 'proposed_value=proposed_sum-d_term',
            'SELECT_STATE': 'anti-windup 선택값을 integral / selected_i에 저장',
            'OUTPUT_ADD': 'output_sum=P+selected_i',
            'OUTPUT_SUB': 'output_value=output_sum-d_term',
            'CLAMP': 'duty=clamp(output_value, 0, 4096)',
            'FINISH': 'busy=0 / done=1 (한 클럭)',
        },
        'notes': 'clocked_proc / nextstate_proc와 계산 레지스터 프로세스는 병렬 동작.\n'
                 'anti_windup_enable=1 AND\n'
                 '[(proposed_value>4096 AND error_reg>0) OR (proposed_value<0 AND error_reg<0)]\n'
                 '이면 이전 integral 유지. 그 외에는 새 후보 선택.\n'
                 'Kp/Ki: signed 18-bit Q16. ki_gain에는 Ts가 반영되어 있다.\n'
                 '상위 모터에서 rst=controller_reset=rst OR NOT enabled.',
    },
}


def extract_fsm(file):
    source = (ROOT / 'fourier/vhdl' / file).read_text()
    text = re.sub(r'--[^\n]*', '', source)
    proc = re.search(r'nextstate_proc\s*:\s*PROCESS.*?END PROCESS nextstate_proc;', text, re.S | re.I)
    assert proc, file
    body = re.search(r'CASE state IS(.*?)END CASE;', proc[0], re.S | re.I)[1]
    branches = list(re.finditer(r'WHEN\s+(\w+)\s*=>', body, re.I))
    edges, states = [], []
    for index, match in enumerate(branches):
        name = match[1]
        branch = body[match.end():branches[index+1].start() if index+1 < len(branches) else len(body)]
        if name.upper() == 'OTHERS':
            assert re.search(r'next_state\s*<=\s*IDLE', branch, re.I)
            continue
        states.append(name)
        conditional = re.search(r'IF\s+(.*?)\s+THEN(.*?)END IF;', branch, re.S | re.I)
        if conditional:
            condition = ' '.join(conditional[1].split())
            choices = re.split(r'\bELSE\b', conditional[2], flags=re.I)
            target = re.search(r'next_state\s*<=\s*(\w+)', choices[0], re.I)[1]
            edges.append((name, target, condition))
            target_else = re.search(r'next_state\s*<=\s*(\w+)', choices[1], re.I)[1] if len(choices) == 2 else name
            edges.append((name, target_else, 'NOT (' + condition + ')'))
        else:
            edges.append((name, re.search(r'next_state\s*<=\s*(\w+)', branch, re.I)[1], '다음 clk'))
    assert len(set(states)) == len(states)
    assert all(a in states and b in states for a,b,_ in edges)
    codes = {name: int(re.search(r'CONSTANT\s+'+name+r'\s*:\s*integer\s*:=\s*(\d+)', text, re.I)[1]) for name in states}
    return states, codes, edges


def actual_fsms():
    transition_manifest = {}
    for stem, spec in FSM.items():
        states, codes, edges = extract_fsm(spec['file'])
        assert set(states) == set(spec['actions']), spec['file']
        entities = [spec['entity']] + (['mac_pe'] if spec['entity']=='npu_2pe' else [])
        g = Graph(stem, spec['title'],
                  'RTL 상태천이도 · 실선: nextstate_proc에서 추출 · 파선: 공통 reset / 복구', entities, True)
        for state in states:
            g.node(state, state + '  [' + str(codes[state]) + ']', spec['actions'][state])
        for a, b, condition in edges:
            g.edge(a,b,condition)
        g.node('reset', '모든 상태 / 미사용 인코딩', 'rst=1: 다음 상승 에지에 IDLE\nOTHERS: 다음 상태 IDLE', 'note')
        g.edge('reset', 'IDLE', '우선 reset / 예외 복구', True)
        g.note('notes', spec['notes'] + '\n노드 동작: 해당 현재 상태에서 처리하는 클럭 기준.\n'
               '조건 불충족 self-loop는 next_state 기본값=state에서 추출.')
        g.edge(states[-1], 'notes', '', True, style='invis')
        g.save()
        transition_manifest[spec['entity']] = {'source': 'fourier/vhdl/'+spec['file'],
                                               'states': codes, 'edges': edges,
                                               'reset': 'rst=1 -> IDLE', 'others': 'IDLE'}
    return transition_manifest


def spi():
    g=Graph('05_spi_behavior', '05 · SPI Mode-0 전송 동작',
            'busy / sclk / bitcnt 기반 프로토콜 · 상자의 IDLE/LOW/HIGH는 설명용 이름',
            ['mpu_reg_spi','input_sync'])
    g.panel('spi','mpu_reg_spi · transaction_proc / spi_divider_proc / receive_*_proc')
    g.node('idle','IDLE 관점 · busy=0','cs_n=1 / sclk=0')
    g.node('low','LOW 관점 · busy=1, sclk=0','clock_tick 대기 / CS 유지')
    g.node('high','HIGH 관점 · busy=1, sclk=1','clock_tick 대기 / CS 유지')
    g.edge('idle','idle','start=0')
    g.edge('idle','low','start_accepted=start AND NOT busy\ncs_n=0 / mosi=rd / divcnt=0\nread_two=1: bitcnt=23, 그 외 15')
    g.edge('low','low','clock_tick=0')
    g.edge('low','high','clock_tick=1 / sclk=1\nrx <= rx(22:0) & miso')
    g.edge('high','high','clock_tick=0')
    g.edge('high','low','clock_tick=1 AND bitcnt>0\nsclk=0 / bitcnt-- / 다음 MOSI 비트')
    g.edge('high','idle','transfer_complete: clock_tick=1 AND bitcnt=0\nbusy=0 / cs_n=1 / sclk=0 / done=1\nrdata=rx(7:0), 24-bit이면 rdata16=rx(15:0)')
    g.end_panel()
    g.panel('sync','input_sync · input_sync_proc · 별도 병렬 입력 경로')
    g.node('miso','mpu_miso','비동기 입력', 'logic')
    g.node('ff0','sync_pipe(0)','첫 번째 플립플롭', 'logic')
    g.node('ff1','sync_pipe(1)','두 번째 플립플롭 → U_SPI.miso', 'logic')
    g.edge('miso','ff0','clk');g.edge('ff0','ff1','clk')
    g.end_panel()
    g.note('notes','clock_tick = busy AND divcnt=HALF_DIV-1\n'
           'HALF_DIV=max(1, ceil(CLK_HZ/(2×SPI_HZ))). 실제 상위 CLK_HZ=100 MHz.\n'
           'rst=1: 동기 초기화 / input_sync의 sync_pipe=00.\n'
           'busy=1 동안 새 start 수락 없음. done은 매 클럭 기본 0.\n'
           '이 도면은 busy/sclk 조건에서 도출한 전송 동작도다.')
    g.save()


def motor():
    g=Graph('06_motor_run_behavior', '06 · 모터 운전 허용 · 출력 선택 · PI 기동',
            'motor_run_control의 병렬 프로세스를 세 구역으로 표현 · 별도 enum FSM 없음',
            ['motor_run_control','fourier_motor_impl','fourier_motor_control'])
    g.panel('arm','arm_control_proc · warmup_count / seen_off / armed')
    g.node('warm','초기 대기','warmup_count=0..4 / armed=0')
    g.node('wait','OFF 관측 대기','warmup_count=4 / seen_off=0 / armed=0')
    g.node('off','OFF 확인','seen_off=1 / armed=0')
    g.node('on','운전 명령 유지','armed=1 / seen_off=1')
    g.edge('warm','warm','warmup_count<4 / count++')
    g.edge('warm','wait','warmup_count=4 AND sw_sync(0)=1')
    g.edge('warm','off','warmup_count=4 AND sw_sync(0)=0')
    g.edge('wait','wait','sw_sync(0)=1')
    g.edge('wait','off','sw_sync(0)=0')
    g.edge('off','off','sw_sync(0)=0')
    g.edge('off','on','sw_sync(0)=1')
    g.edge('on','off','sw_sync(0)=0')
    g.edge('on','on','sw_sync(0)=1')
    g.node('reset','모든 운전 조건','rst=1 → warmup=0 / seen_off=0 / armed=0','note')
    g.edge('reset','warm','reset 우선',True)
    g.end_panel()
    g.panel('duty','drive_select_proc · 조합 선택 우선순위')
    g.node('ol','open_loop_enable=1?','', 'decision')
    g.node('open','requested_duty=open_loop_duty','', 'action')
    g.node('ripple','sw_sync(3)=1?','', 'decision')
    g.node('ri','requested_duty=1024 또는 3072','fault_phase에 따라 25% / 75%','action')
    g.node('pi','requested_duty=pid_duty','', 'action')
    g.node('limit','안전 출력 제한','derated=1 AND requested_duty>1024이면 duty=1024\n그 외 duty=requested_duty','logic')
    g.edge('ol','open','예');g.edge('ol','ripple','아니오')
    g.edge('ripple','ri','예');g.edge('ripple','pi','아니오')
    for a in ['open','ri','pi']:g.edge(a,'limit')
    g.end_panel()
    g.panel('control','독립 카운터와 제어 시작 경로')
    g.node('tick','sample_tick_proc','CLK_HZ/100 주기마다 sample_tick 한 클럭','logic')
    g.node('speed','encoder_speed_hybrid','tick 스냅샷 → 계산 후 speed_valid','logic')
    g.node('start','pid_start_proc','speed_valid=1 AND enabled=1 AND pid_busy=0\n이면 pid_start=1, 그 외 0','logic')
    g.edge('tick','speed');g.edge('speed','start')
    g.end_panel()
    g.note('notes','sw는 switch_sync_proc의 두 FF로 동기화. clear_fault=NOT sw_sync(0).\n'
           'enabled=armed AND NOT rst AND reset_n AND NOT stop_button AND NOT fault_latched\n'
           'armed 명령과 실제 enabled 출력은 구분한다. fault가 armed 레지스터를 직접 지우지는 않는다.\n'
           'speed_reference={0, sw_sync(2:1), 10개 0}.\n'
           'fourier_motor_control → U_IMPL/fourier_motor_impl에서 연결하며 wrapper 자체에는 FSM이 없다.')
    g.save()


def safety():
    g=Graph('07_safety_behavior','07 · 연속 이상 감시 · PS watchdog · 정지 latch',
            '병렬 counter / flag에서 도출한 관측 상태 · TRIP_CONSEC=3 / DERATE_CONSEC=2 기준',
            ['safety_supervisor','fault_latch'])
    g.panel('class','safety_supervisor · classification_count_proc / fault_latch_proc')
    g.node('c0','연속 이상 0 · latched=0','warning=0 / derated=0')
    g.node('c1','연속 이상 1 · latched=0','warning=1 / derated=0')
    g.node('c2','연속 이상 2 · latched=0','warning=1 / derated=1')
    g.node('latched','latched=1','warning=0 / derated=0\n정상 분류만으로 latch 해제 안 됨','fault')
    g.edge('c0','c1','class_valid=1 AND class_id=1')
    g.edge('c1','c2','class_valid=1 AND class_id=1')
    g.edge('c2','latched','class_valid=1 AND class_id=1\n이전 consec_count>=TRIP_CONSEC-1\nfault_cause(0)=1')
    for node in ['c0','c1','c2']:
        g.edge(node,node,'class_valid=0')
    for node in ['c1','c2']:
        g.edge(node,'c0','class_valid=1 AND class_id=0')
    g.edge('latched','latched','정상: consec_count=0, latch 유지\n이상: 연속/누적 계수, latch 유지')
    g.edge('latched','c0','rst=1 OR clear=1\nlatch / fault_cause / 연속 계수 초기화',True)
    g.end_panel()
    g.panel('watchdog','watchdog_count_proc · 위 분류 경로와 동시에 동작')
    g.node('wd0','watchdog_count=0','rst OR clear OR NOT armed OR heartbeat','logic')
    g.node('wdcount','watchdog 계수','armed=1 / heartbeat=0 / latched=0','logic')
    g.node('wdtrip','watchdog trip','이전 watchdog_count>=WATCHDOG_CYCLES-1\narmed=1 AND heartbeat=0 AND latched=0','decision')
    g.edge('wd0','wdcount','감시 조건 성립')
    g.edge('wdcount','wdcount','임계값 전까지 count++')
    g.edge('wdcount','wd0','NOT armed OR heartbeat OR rst OR clear')
    g.edge('wdcount','wdtrip','임계값 도달')
    g.edge('wdtrip','latched','latched=1 / fault_cause(1)=1',constraint='false')
    g.end_panel()
    g.panel('standalone','독립 fault_latch entity · 현재 상위 RTL에서 인스턴스되지 않음')
    g.node('simple','fault_count_proc','rst OR clear: latch=0 / count=0\nvalid 정상: count=0 / latch 유지\nvalid 이상: count 증가, 이전 count>=CONSEC-1이면 latch=1','logic')
    g.end_panel()
    g.note('notes','NORMAL/WARNING/DERATE/FAULT는 설명용 관측 구분이며 RTL에 이 이름의 state 레지스터는 없다.\n'
           'DERATE 구간에서는 warning도 1이다. 정상 분류는 연속 횟수만 초기화한다.\n'
           'abnormal_count는 rst에서만 0: clear는 누적 횟수를 보존.\n'
           '어느 관측 상태에서나 rst/clear → latch=0 / 연속 계수=0 / 원인=0.\n'
           'safety_supervisor의 rst/clear는 새 fault보다 우선한다.\n'
           '분류/heartbeat fault는 같은 클럭에 둘 다 기록될 수 있다.\n'
           '아래 독립 fault_latch를 위 supervisor 안에 연결한 도면은 아니다.')
    g.save()


def axi():
    g=Graph('08_axi_behavior','08 · AXI4-Lite 독립 수신 · 응답 · 제어 상태',
            'address_pending / data_pending / BVALID / RVALID의 프로토콜 동작 · enum FSM 없음',
            ['axi_registers','axi_vibration_impl','axi_vibration_top'])
    g.panel('write','write_address_proc / write_data_proc / write_response_proc / register_write_proc')
    g.node('empty','AW=미보관 / W=미보관','BVALID=0 / AWREADY=1 / WREADY=1')
    g.node('addr','AW만 보관','address_pending=1 / data_pending=0')
    g.node('data','W만 보관','address_pending=0 / data_pending=1')
    g.node('both','AW와 W 보관 완료','write_commit=address_pending AND data_pending AND NOT BVALID')
    g.node('b','쓰기 응답 대기','write_commit 처리 에지: pending 0 / BVALID=1\n주소·WSTRB·busy 조건에 따라 OKAY 또는 SLVERR')
    g.edge('empty','addr','AWVALID AND AWREADY')
    g.edge('empty','data','WVALID AND WREADY')
    g.edge('empty','both','AW / W handshake가 같은 클럭')
    g.edge('addr','both','W handshake');g.edge('data','both','AW handshake')
    g.edge('both','b','다음 clk / register write 또는 거부')
    g.edge('b','b','BREADY=0 / 응답 보존')
    g.edge('b','empty','BREADY=1 / BVALID=0')
    g.end_panel()
    g.panel('read','register_read_proc · 쓰기 경로와 병렬')
    g.node('ar','RVALID=0 / ARREADY=aresetn','읽기 주소 수락 가능')
    g.node('r','RVALID=1 / ARREADY=0','AR handshake 시점의 RDATA/RRESP 보관')
    g.edge('ar','r','ARVALID AND ARREADY')
    g.edge('r','r','RREADY=0 / 데이터·응답 유지')
    g.edge('r','ar','RREADY=1')
    g.end_panel()
    g.panel('sticky','status_latch_proc / 명령 펄스 · 위 경로와 병렬')
    g.node('status','완료·오류 보관','core_done → sticky_done=1 → irq\nspi_done → spi_done_sticky=1\nCONTROL clear/start가 같은 클럭 완료보다 우선','logic')
    g.node('pulses','register_write_proc','수락된 쓰기에서만 core_start / spi_start\nps_heartbeat / quad_position_wr_en 한 클럭 발생\ncore busy 중 START: SLVERR / sticky_error','logic')
    g.end_panel()
    g.note('notes','aresetn=0: 모든 프로토콜 pending/valid와 sticky 상태 초기화.\n'
           'AW/W는 각각 독립 수신하며, 두 보관 비트가 모두 1인 다음 처리 에지에 commit.\n'
           'BVALID 동안 새 AW/W 수락 없음. RVALID 동안 새 AR 수락 없음.\n'
           'axi_vibration_top → U_IMPL/axi_vibration_impl → U_REGS, U_CORE, U_SPI, U_MISO_SYNC.\n'
           '두 구조 연결 entity에는 자체 FSM이 없다. BRAM byte 주소=word 주소 <<2.')
    g.save()


def encoder():
    g=Graph('09_speed_divider_behavior','09 · 인코더 하이브리드 속도 추정 · 정수 나눗셈',
            '모드 flag / snapshot / busy 기반 동작 · HIGH=14 / LOW=10 기본값',
            ['encoder_speed_hybrid','unsigned_divider'])
    g.panel('speed','encoder_speed_hybrid · 동시에 동작하는 두 추정 경로')
    g.node('a','encoder_a → 2 FF → pulse','상승 에지 검출','logic')
    g.node('period','저속 주기 추정','두 번째 펄스부터, divider_busy=0일 때 역수 요청\nperiod_divisor=period_count+1\ndone 시 제한·1/4 필터 / timeout 시 valid=0','logic')
    g.node('window','고속 창 추정','window_count + 이번 pulse\n범위 제한 후 정규화 곱셈','logic')
    g.edge('a','period');g.edge('a','window')
    g.node('snap','sample_tick: 조건과 값을 스냅샷','speed_snapshot_proc → speed_calc_pending=1','action')
    g.edge('period','snap','period_speed / valid / timeout')
    g.edge('window','snap','window_total / product / 이전 mode')
    g.node('invalid','period_valid_snap=0 OR\nperiod_timeout_snap=1?','','decision')
    g.node('zero','speed=0 / high_speed_mode=0','','action')
    g.node('hi','window_total_snap>=14?','','decision')
    g.node('hs','창 방식 / high_speed_mode=1','','action')
    g.node('lo','window_total_snap<=10?','','decision')
    g.node('ls','주기 방식 / high_speed_mode=0','','action')
    g.node('hold','11..13: 이전 모드 선택','high_speed_mode_snap=1이면 창 방식\n그 외 주기 방식','action')
    g.node('valid','speed_valid=1 한 클럭','speed_output_proc: pending을 보는 다음 처리 에지','logic')
    g.edge('snap','invalid','다음 clk / pending=1')
    g.edge('invalid','zero','예');g.edge('invalid','hi','아니오')
    g.edge('hi','hs','예');g.edge('hi','lo','아니오')
    g.edge('lo','ls','예');g.edge('lo','hold','아니오')
    for node in ['zero','hs','ls','hold']:g.edge(node,'valid')
    g.end_panel()
    g.panel('divider','unsigned_divider · divide_proc · 별도 busy/done 경로')
    g.node('di','busy=0','start 대기')
    g.node('run','busy=1 / count=0..WIDTH-1','shift → compare/subtract → quotient 비트 추가')
    g.edge('di','di','start=1 AND divisor=0\nquotient=all ones / done=1')
    g.edge('di','run','start=1 AND divisor/=0\n피연산자 저장 / 작업값=0 / count=0')
    g.edge('run','run','count<WIDTH-1 / count++')
    g.edge('run','di','count=WIDTH-1\nquotient=next_quotient / busy=0 / done=1')
    g.end_panel()
    g.note('notes','rst=1: 추정값·모드·카운터·divider 초기화. 출력 speed는 0..4096.\n'
           '고속/저속 결정 전에 period_valid/timeout 조건을 먼저 평가한다.\n'
           'sample_tick과 같은 클럭의 pulse도 window_total에 포함한다.\n'
           'LOW/HIGH 문구는 실제 high_speed_mode flag의 설명이며 새 state 인코딩을 가정하지 않는다.\n'
           'divider start는 busy=0에서만 수락하고 done은 기본 0인 한 클럭 펄스다.')
    g.save()


def quadrature():
    g=Graph('10_quadrature_behavior','10 · A/B 위상 전이 · 위치 · 오류 감시',
            'state는 이전 A/B 위상 2비트 · 제어 순서 FSM과 구분하는 입력 위상 전이도',
            ['encoder_quadrature'])
    g.panel('phase','phase_decode_comb_proc · state & state_now')
    for code in ['00','10','11','01']:g.node('p'+code,'A/B = '+code,'이전 관측 위상')
    codes=['00','10','11','01']
    for a,b in zip(codes,codes[1:]+codes[:1]):
        g.edge('p'+a,'p'+b,'정방향 / direction=0\nposition+1')
        g.edge('p'+b,'p'+a,'역방향 / direction=1\nposition-1')
    g.edge('p00','p11','두 비트 동시 변화: illegal',True,dir='both')
    g.edge('p10','p01','두 비트 동시 변화: illegal',True,dir='both')
    g.end_panel()
    g.panel('position','position_proc · 우선순위')
    g.node('pos','상승 에지 위치 갱신','1. rst → position=0\n2. position_wr_en → preset 저장\n3. moved AND valid_forward → +1\n4. moved AND valid_backward → -1\n5. 그 외 유지','logic')
    g.end_panel()
    g.panel('fault','fault_status_proc / timeout_count_proc · 위상 디코드와 병렬')
    g.node('illegal','불법 전이','moved AND NOT valid_forward AND NOT valid_backward\nillegal_transition_fault=1 / count 포화 증가','fault')
    g.node('timeout','무펄스 timeout','NOT moved AND enabled AND duty/=0\nAND timeout_count>=TIMEOUT_CLOCKS-1 → timeout_fault=1','fault')
    g.node('overflow','위치 overflow','유효한 정/역방향 전이에서 부호 범위 초과\n→ overflow_fault=1','fault')
    g.end_panel()
    g.note('notes','rst=1: 입력 동기화 / 이전 위상=00 / 위치·방향·오류 초기화.\n'
           'state_now=a_sync(1)&b_sync(1). moved이면 다음 비교용 state를 갱신한다.\n'
           '동일 위상은 이동 없음. 불법 전이는 위치와 방향을 바꾸지 않는다.\n'
           'position preset이 같은 클럭 이동보다 우선하지만, 오류 검사는 별도 프로세스다.\n'
           'clear는 오류 flag만 초기화: illegal count와 timeout_count를 초기화하지 않는다.\n'
           'rst 이외에 clear와 새 오류가 겹치면 뒤에 기록되는 새 오류가 우선한다.')
    g.save()


def reset_pwm():
    g=Graph('11_reset_pwm_behavior','11 · 리셋 동기 해제 · PWM 주기와 duty 적재',
            'reset_pipe / count / threshold 레지스터의 실제 갱신 조건 · enum FSM 없음',
            ['reset_sync','pwm_period'])
    g.panel('reset','reset_sync · 비동기 인가 / 두 클럭 동기 해제')
    g.node('r11','reset_pipe=11','sync_reset=1')
    g.node('r10','reset_pipe=10','sync_reset=1')
    g.node('r00','reset_pipe=00','sync_reset=0')
    g.edge('r11','r10','async_reset=0 / rising_edge(clk)')
    g.edge('r10','r00','async_reset=0 / rising_edge(clk)')
    g.edge('r00','r00','async_reset=0 / rising_edge(clk)')
    g.node('any','어느 reset_pipe 값에서나','async_reset=1 → 즉시 11\n클럭을 기다리지 않음','note')
    g.edge('any','r11','비동기 인가',True)
    g.end_panel()
    g.panel('pwm','pwm_period · 카운터와 threshold는 병렬 레지스터')
    g.node('disabled','rst=1 OR enable=0','조합 경로: pwm=0 즉시\n다음 clk: count=0 / threshold=0 / active_duty=0')
    g.node('count','enable=1 AND rst=0','count=0..PERIOD-1\ncount<threshold이면 pwm=1, 그 외 0')
    g.edge('disabled','count','enable=1 AND rst=0')
    g.edge('count','count','count<PERIOD-1 / 다음 clk count++\nthreshold / active_duty 유지',tailport='w',headport='w')
    g.edge('count','count','count=PERIOD-1 / 다음 clk count=0\nthreshold=floor(min(duty,4096)×PERIOD/4096)\nactive_duty=min(duty,4096)',tailport='e',headport='e')
    g.edge('count','disabled','rst=1 OR enable=0')
    g.end_panel()
    g.note('notes','모터 async_reset=NOT reset_n OR stop_button. reset_pipe 초기값은 11.\n'
           'PWM 기본 PERIOD=5000: 상위 100 MHz에서 20 kHz.\n'
           'duty는 count=PERIOD-1을 처리하는 에지에서만 적재한다.\n'
           'reset/disable 후 재활성 시 threshold=0인 첫 주기를 보낸 뒤 첫 duty가 반영된다.\n'
           '운전 차단은 주기 경계를 기다리지 않는 조합 경로다.\n'
           'reset_sync의 동기 해제 지연은 두 클럭이다.')
    g.save()


def write_index(transitions):
    entities={}
    paths=[ROOT/'common/reset_sync.vhd',*sorted((ROOT/'fourier/vhdl').glob('*.vhd'))]
    packages=[]
    for path in paths:
        text=re.sub(r'--[^\n]*','',path.read_text())
        match=re.search(r'\bENTITY\s+(\w+)\s+IS',text,re.I)
        if match:entities[match[1].lower()]=path.relative_to(ROOT).as_posix()
        elif re.search(r'\bPACKAGE\s+\w+\s+IS',text,re.I):packages.append(path.relative_to(ROOT).as_posix())
    coverage={name:[] for name in entities}
    for sheet in SHEETS:
        for name in sheet['entities']:
            assert name in coverage,name
            coverage[name].append(sheet['stem'])
    assert all(coverage.values()),[name for name,value in coverage.items() if not value]
    manifest={'source_sha256':{p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
                               for p in [*paths,Path(__file__).resolve()]},
              'fsm_count':len(transitions),
              'state_count':sum(len(x['states']) for x in transitions.values()),
              'sheet_count':len(SHEETS),'sheets':SHEETS,'coverage':coverage,'fsms':transitions,
              'packages_without_fsm':packages,
              'note':'FSM edges extracted from nextstate_proc; behavior sheets manually traced to concurrent RTL processes.'}
    (OUT/'state_manifest.json').write_text(json.dumps(manifest,indent=2,ensure_ascii=False)+'\n')
    lines=['# 시스템별 상태천이도·동작도','',
           '포트폴리오 본문에는 가속기 순서 제어·FFT·NPU·PI의 **핵심 FSM 4장**을 권장한다.',
           '전체 자료는 **11장**이며, 현재 VHDL의 **20개 entity**를 도면별로 대응했다.',
           '코드의 상태 이름·조건·인코딩을 유지하고 리셋·대기 반복·완료 처리를 표시했다.','',
           '## 도면 목록','',
           '| 번호 / 도면 | 종류 | PNG | 확대용 SVG | 편집용 DOT |',
           '|---|---|---|---|---|']
    titles=['가속기 전체 실행','FFT64·대역 특징','INT8 NPU·MAC PE','PI·anti-windup',
            'SPI·입력 동기화','모터 운전·출력 선택','안전·watchdog·fault latch',
            'AXI 수신·응답·상태','하이브리드 속도·divider','A/B 위상·위치·진단','리셋·PWM']
    for i,(s,title) in enumerate(zip(SHEETS,titles),1):
        stem=s['stem']
        lines.append(f'| {i}. {title} | {s["kind"]} | [보기]({stem}.png) | [확대]({stem}.svg) | [원본]({stem}.dot) |')
    lines += ['', '## 먼저 볼 그림', '', '![가속기 순서 제어 FSM](01_core_fsm.png)', '',
              '가속기 전체 실행은 `IDLE → FSTART → FWAIT → NSTART → NWAIT → STORE → IDLE`다.',
              '`FWAIT`, `NWAIT`, `STORE`에서는 완료 조건까지 머무르며, 마지막 BRAM 기록 처리 에지에 `done`이 발생한다.','',
              '## 표기와 범위','',
              '- **1~4번은 실제 RTL FSM**이다. `nextstate_proc`의 `CASE state`, `IF`, `next_state` 대입에서 화살표를 추출한다.',
              '- 파선의 공통 reset 표기는 각 상태에 적용된다. 1~4번 FSM의 reset은 상승 에지에서 적용된다.',
              '- 조건이 거짓일 때의 self-loop도 `next_state <= state` 기본값을 반영한다.',
              '- 노드 안 동작은 해당 **현재 상태를 처리하는 활성 클럭 에지** 기준이다. 조합 출력은 별도로 표시한다.',
              '- **5~11번은 회로의 동작도**다. 설명용 모드·단계 이름을 RTL의 추가 상태나 추가 클럭으로 해석하지 않는다.',
              '- 10번은 이전 A/B 위상과 현재 위상의 실제 전이다. `state`라는 변수 이름만으로 제어 FSM으로 분류하지 않는다.',
              '- 서로 다른 패널은 동시에 동작하는 프로세스다. 패널 배치 순서가 실행 순서를 뜻하지 않는다.',
              '- `fault_latch`는 독립 entity이며 현재 상위 RTL에서는 인스턴스되지 않는다. 실제 통합 안전 경로는 `safety_supervisor`다.',
              '- `axi_vibration_top`, `fourier_motor_control`은 `U_IMPL` 연결용 최상위다. `*_impl`은 하위 모듈 연결 계층이며 별도 상태를 추가하지 않는다.',
              '- `vibration_types`, `vibration_regs`는 타입·함수·주소 상수 패키지라 자체 상태천이도가 없다.','',
              '## 코드와 도면 대응','', '| entity | 도면 | 근거 소스 |','|---|---|---|']
    for name,source in sorted(entities.items()):
        refs=' · '.join(f'[{stem[:2]}]({stem}.svg)' for stem in coverage[name])
        lines.append(f'| `{name}` | {refs} | [{Path(source).name}](../../{source}) |')
    lines += ['', '## 상태 전이 표', '',
              '다음 표의 상태와 조건은 현재 소스에서 추출한 결과다. `다음 clk`는 무조건 전이다.',
              '`rst=1`에서는 상태 레지스터가 `IDLE`로 초기화되고, 미사용 인코딩의 `OTHERS`도 다음 상태가 `IDLE`다.','']
    for entity,item in transitions.items():
        lines += [f'### `{entity}` · {len(item["states"])} states','',
                  '| 현재 상태 | 조건 | 다음 상태 |','|---|---|---|']
        for a,b,condition in item['edges']:
            lines.append(f'| `{a}` | `{condition}` | `{b}` |')
        lines.append('')
    lines += ['## 생성과 확인','',
              '`python3 tools/render_state_diagrams.py`로 DOT·SVG·PNG와 상태/소스 매니페스트를 생성한다.',
              '렌더링에는 Graphviz `dot`과 `Noto Sans CJK KR` 글꼴을 사용한다.',
              '상태 전이 추출, 20개 entity 대응, 소스 SHA-256은 [state_manifest.json](state_manifest.json)에 기록한다.',
              '5~11번은 소스 프로세스를 읽고 작성한 설명도이므로 코드 변경 시 조건과 우선순위도 함께 검토한다.','',
              '[모듈·신호 연결도](../architecture/README.md) · [포트폴리오 전체 아키텍처](../PORTFOLIO_ARCHITECTURE.md)','']
    (OUT/'README.md').write_text('\n'.join(lines),encoding='utf-8')
    return manifest


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    transitions=actual_fsms()
    for draw in [spi,motor,safety,axi,encoder,quadrature,reset_pwm]:draw()
    manifest=write_index(transitions)
    print(f"PASS: {manifest['fsm_count']} source FSMs / {manifest['state_count']} states / "
          f"{manifest['sheet_count']} sheets / {len(manifest['coverage'])} entities covered")


if __name__=='__main__':main()
