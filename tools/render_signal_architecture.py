#!/usr/bin/env python3
"""Draw source-based signal architecture as editable SVG and high-resolution PNG.

Only repository port names, widths and mappings are used. The reference picture
provides layout style; none of its organization-specific content is reproduced.
"""
import ast
import csv
import hashlib
import html
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/architecture'
COLORS = {'bus': '#368c47', 'io': '#1688b5', 'module': '#3f4852', 'clock': '#8058a6'}


def parenthesized(text, start):
    opening = text.index('(', start)
    depth = 0
    for index in range(opening, len(text)):
        depth += (text[index] == '(') - (text[index] == ')')
        if depth == 0:
            return text[opening + 1:index], index + 1
    raise ValueError('Unbalanced parentheses')


def split_associations(text):
    depth = 0
    start = 0
    result = []
    for index, char in enumerate(text):
        depth += (char == '(') - (char == ')')
        if char == ',' and depth == 0:
            result.append(text[start:index].strip())
            start = index + 1
    result.append(text[start:].strip())
    return result


def integer_expression(text, constants):
    tree = ast.parse(text.strip().replace('/', '//'), mode='eval')
    def visit(node):
        if isinstance(node, ast.Expression):
            return visit(node.body)
        if isinstance(node, ast.Constant) and isinstance(node.value, int):
            return node.value
        if isinstance(node, ast.Name):
            return constants[node.id.upper()]
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.USub):
            return -visit(node.operand)
        if isinstance(node, ast.BinOp):
            left, right = visit(node.left), visit(node.right)
            operations = {ast.Add: lambda: left + right, ast.Sub: lambda: left - right,
                          ast.Mult: lambda: left * right, ast.FloorDiv: lambda: left // right}
            return operations[type(node.op)]()
        raise ValueError(text)
    return visit(tree)


def read_entities():
    entities = {}
    files = [ROOT / 'common/reset_sync.vhd', *sorted((ROOT / 'fourier/vhdl').glob('*.vhd'))]
    for path in files:
        text = re.sub(r'--[^\n]*', '', path.read_text())
        match = re.search(r'\bENTITY\s+(\w+)\s+IS', text, re.I)
        if not match:
            continue
        name = match[1].lower()
        constants = {}
        generic = re.search(r'\bGENERIC\s*\(', text[match.end():], re.I)
        port_start = re.search(r'\bPORT\s*\(', text[match.end():], re.I)
        assert port_start
        if generic and generic.start() < port_start.start():
            body, _ = parenthesized(text, match.end() + generic.start())
            for declaration in body.split(';'):
                item = re.match(r'\s*(\w+)\s*:\s*\w+\s*:=\s*(.+)', declaration)
                if item:
                    constants[item[1].upper()] = integer_expression(item[2], constants)
        body, _ = parenthesized(text, match.end() + port_start.start())
        ports = {}
        for declaration in body.split(';'):
            item = re.match(r'\s*([\w,\s]+?)\s*:\s*(INOUT|IN|OUT)\s+(.+)', declaration, re.I)
            assert item, declaration
            kind = item[3].strip()
            size = re.search(r'\((.+?)\s+DOWNTO\s+(.+?)\)', kind, re.I)
            width = 1
            if size:
                width = integer_expression(size[1], constants) - integer_expression(size[2], constants) + 1
            for port in item[1].split(','):
                ports[port.strip().lower()] = {'direction': item[2].upper(), 'width': width,
                                             'type': kind}
        entities[name] = {'source': path.relative_to(ROOT).as_posix(), 'ports': ports, 'text': text}
    return entities, files


ENTITIES, SOURCES = read_entities()


def port(entity, name):
    value = ENTITIES[entity]['ports'][name]
    return name if value['width'] == 1 else f"{name}[{value['width'] - 1}:0]"


def require(entity, *names):
    for name in names:
        assert name in ENTITIES[entity]['ports'], (entity, name)


class Drawing:
    def __init__(self, name, title, subtitle, width, height):
        self.name, self.width, self.height = name, width, height
        self.parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
                      '<defs><pattern id="hatch" width="16" height="16" patternUnits="userSpaceOnUse" patternTransform="rotate(35)">'
                      '<rect width="16" height="16" fill="#edf6fb"/><line x1="0" x2="0" y1="0" y2="16" stroke="#d9eaf3" stroke-width="2"/></pattern>']
        for kind, color in COLORS.items():
            self.parts.append(f'<marker id="{kind}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 z" fill="{color}"/></marker>')
        self.parts += ['</defs>', '<rect width="100%" height="100%" fill="white"/>',
                       '<style>text{font-family:"Noto Sans CJK KR","DejaVu Sans",sans-serif;fill:#202f3c}'
                       '.signal{font-family:"DejaVu Sans Mono",monospace;paint-order:stroke;stroke:#fff;stroke-width:6px;stroke-linejoin:round}'
                       '.small{fill:#536473}</style>']
        self.text(60, 65, title, 36, bold=True)
        self.text(60, 110, subtitle, 20)

    def text(self, x, y, lines, size=21, anchor='start', bold=False, color=None, signal=False):
        if isinstance(lines, str):
            lines = [lines]
        style = f'font-size:{size}px;' + ('font-weight:700;' if bold else '')
        if color:
            style += 'fill:' + color + ';'
        cls = ' class="signal"' if signal else ''
        self.parts.append(f'<text x="{x}" y="{y}" text-anchor="{anchor}" style="{style}"{cls}>')
        for index, line in enumerate(lines):
            self.parts.append(f'<tspan x="{x}" dy="{0 if index == 0 else size * 1.43}">{html.escape(line)}</tspan>')
        self.parts.append('</text>')

    def frame(self, x, y, w, h, title, fill='white', dashed=False):
        dash = ' stroke-dasharray="11 7"' if dashed else ''
        self.parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" fill="{fill}" stroke="#586d7c" stroke-width="2.5"{dash}/>')
        self.text(x + 20, y + 36, title, 25, bold=True)

    def node(self, x, y, w, h, title, lines=(), kind='rtl'):
        fills = {'rtl': '#ffffff', 'ip': '#eee7f5', 'memory': '#fff0db', 'ps': '#f0f2f3', 'io': '#eef7f4'}
        self.parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="15" fill="{fills[kind]}" stroke="#495b69" stroke-width="2.4"/>')
        self.text(x + w / 2, y + 37, title, 23, anchor='middle', bold=True)
        if lines:
            self.text(x + w / 2, y + 73, lines, 19, anchor='middle')

    def wire(self, points, kind='module', both=False, arrow=True):
        line = ' '.join(f'{x},{y}' for x, y in points)
        markers = f' marker-end="url(#{kind})"' if arrow else ''
        if both:
            markers += f' marker-start="url(#{kind})"'
        dash = ' stroke-dasharray="9 6"' if kind == 'clock' else ''
        weight = 4 if kind in ['io', 'bus'] else 2.6
        self.parts.append(f'<polyline points="{line}" fill="none" stroke="{COLORS[kind]}" stroke-width="{weight}"{markers}{dash}/>')

    def label(self, x, y, lines, size=18, anchor='start'):
        self.text(x, y, lines, size, anchor=anchor, signal=True)

    def junction(self, x, y):
        self.parts.append(f'<circle cx="{x}" cy="{y}" r="5" fill="{COLORS["module"]}"/>')

    def legend(self, y):
        self.frame(60, y, self.width - 120, 140, '범례 · Source-based module diagram')
        items = [('bus', 'AXI / BRAM 버스'), ('io', '경계 입출력'), ('module', '모듈 간 신호'), ('clock', '공통 클럭 / 리셋')]
        step = (self.width - 170) / 4
        for index, (kind, title) in enumerate(items):
            x = 85 + index * step
            self.wire([(x, y + 83), (x + 65, y + 83)], kind)
            self.text(x + 80, y + 90, title, 19)
        self.text(80, y + 125, '흰색: 사용자 RTL·프로세스 / 보라색: Xilinx IP / 주황색: 메모리 / [n:0]: 비트 폭 / ●: 접속점 / 교차선은 접속 아님', 17)

    def save(self):
        self.parts.append('</svg>')
        path = OUT / (self.name + '.svg')
        path.write_text('\n'.join(self.parts), encoding='utf-8')
        html_path = OUT / (self.name + '.html')
        html_path.write_text('<!doctype html><meta charset="utf-8"><style>html,body{margin:0;padding:0;background:white}svg{display:block}</style>' + path.read_text(), encoding='utf-8')
        command = ['/usr/bin/google-chrome', '--headless', '--no-sandbox', '--disable-gpu',
                   '--hide-scrollbars', '--force-device-scale-factor=1',
                   f'--window-size={self.width},{self.height}',
                   '--screenshot=' + str(OUT / (self.name + '.png')), html_path.as_uri()]
        result = subprocess.run(command, capture_output=True, text=True, timeout=90)
        assert result.returncode == 0, result.stderr[-1500:]
        return path


def overview():
    d = Drawing('01_system_signals', 'FPGA Module & Signal Architecture',
                'Zybo Z7-20 · Zynq-7000 · 실제 인스턴스/포트/내부 신호 기준 · Sheet 1 / 3', 2460, 2460)
    d.frame(350, 160, 1630, 2040, 'FPGA 영역 · Zynq PL / VHDL / FCLK_CLK0 = 100 MHz', 'url(#hatch)')
    d.node(35, 400, 270, 350, 'Zynq PS', ['ARM Cortex-A9 / C', 'PS UART ↔ PC', '센서 수집 / 64 samples', 'Golden Model 비교', 'MMIO / heartbeat'], 'ps')
    d.node(520, 265, 390, 100, 'FCLK_CLK0 / clock net', ['100 MHz → aclk / clk'], 'ps')
    d.node(1160, 265, 530, 100, 'reset / proc_sys_reset', ['FCLK_RESET0_N → ext_reset_in'], 'ip')
    d.wire([(305, 430), (330, 430), (330, 300), (520, 300)], 'clock')
    d.label(365, 285, 'FCLK_CLK0', 18)
    d.wire([(305, 455), (340, 455), (340, 220), (1425, 220), (1425, 265)], 'clock')
    d.label(960, 210, 'FCLK_RESET0_N', 18)
    d.text(610, 410, '동일 PL clock domain: accelerator / motor / AXI / BRAM', 19)
    d.text(1100, 445, 'peripheral_aresetn / interconnect_aresetn', 18, color=COLORS['clock'])
    d.node(490, 495, 420, 135, 'interconnect / SmartConnect', ['S00_AXI → M00_AXI / M01_AXI'], 'ip')
    d.wire([(305, 570), (490, 570)], 'bus', both=True)
    d.label(320, 545, 'M_AXI_GP0', 17)
    d.node(1190, 495, 560, 135, 'ram_controller / axi_bram_ctrl', ['S_AXI / 32-bit data / 4 KiB'], 'ip')
    d.wire([(910, 560), (1190, 560)], 'bus', both=True)
    d.label(955, 540, 'M01_AXI ↔ S_AXI', 18)
    d.node(1190, 700, 560, 150, 'memory / blk_mem_gen', ['True Dual-Port RAM', '1024 × 32 bit / Port A + Port B'], 'memory')
    d.wire([(1470, 630), (1470, 700)], 'bus', both=True)
    d.label(1490, 673, 'BRAM_PORTA', 18)

    d.frame(410, 920, 1470, 550, 'accelerator / axi_vibration_top · 내부 U_IMPL', '#e5f0f7')
    d.node(480, 1010, 520, 125, 'U_REGS / axi_registers', ['S_AXI / core 제어 / SPI 제어 / motor 상태'])
    d.wire([(700, 630), (700, 1010)], 'bus', both=True)
    d.label(720, 780, ['M00_AXI ↔ S_AXI', 's_axi_*', 'ADDR[11:0] / DATA[31:0]'], 18)
    d.node(1350, 1010, 450, 125, 'U_SPI / mpu_reg_spi', ['센서 register read/write / 1·2 byte'])
    d.wire([(1000, 1040), (1350, 1040)])
    d.label(1020, 1005, ['spi_start / spi_read', 'spi_address[6:0]'], 17)
    d.wire([(1350, 1100), (1000, 1100)])
    d.label(1020, 1130, ['spi_busy / spi_done', 'spi_read_data16[15:0]'], 17)
    d.node(1550, 1175, 250, 85, 'U_MISO_SYNC', ['input_sync / 2 FF'])
    d.wire([(1675, 1175), (1675, 1135)])
    d.label(1810, 1170, 'miso_synchronized', 15, anchor='end')
    d.node(2080, 1020, 320, 200, 'MPU-6500', ['모터 하우징 X축', 'SPI Mode 0', '외부 장치'], 'io')
    d.wire([(1800, 1050), (2080, 1050)], 'io')
    d.label(1820, 1005, ['mpu_sclk / mpu_mosi', 'mpu_cs_n'], 17)
    d.wire([(2080, 1190), (1930, 1190), (1930, 1220), (1800, 1220)], 'io')
    d.label(1945, 1250, 'mpu_miso', 18)
    d.node(480, 1280, 920, 135, 'U_CORE / vibration_core',
           ['FFT64 → 특징 4개 → INT8 NPU (2 PE)', 'U_FFT / U_NPU / 상태·결과 레지스터 · 상세 Sheet 3'])
    d.wire([(1470, 850), (1470, 885), (1270, 885), (1270, 1280)], 'bus', both=True)
    d.label(1290, 1180, ['M_BRAM / Port B', 'm_bram_addr[31:0]',
                         'm_bram_wdata[31:0]', 'm_bram_rdata[31:0]'], 17)
    d.wire([(590, 1135), (590, 1280)])
    d.label(610, 1200, 'core_start', 18)
    d.wire([(930, 1280), (930, 1135)])
    d.label(950, 1200, ['core_busy / core_done', 'features[31:0] / logits[15:0]'], 16)
    d.wire([(480, 1080), (390, 1080), (390, 690), (305, 690)])
    d.label(70, 805, 'irq → PS/IRQ_F2P', 18)

    d.frame(410, 1700, 1470, 440, 'motor / fourier_motor_control · 내부 U_IMPL · 상세 Sheet 2', '#e5f0f7')
    d.node(480, 1780, 360, 110, 'U_RUN / motor_run_control', ['arm / reference / duty 선택'])
    d.node(1110, 1780, 630, 110, 'U_SAFETY / safety_supervisor', ['class 판정 + PS watchdog → derate / latch'])
    d.node(480, 1970, 330, 105, 'U_ENCODER', ['encoder_speed_hybrid'])
    d.node(910, 1970, 300, 105, 'U_PID / pid_fixed', ['고정소수점 PI / AW'])
    d.node(1310, 1970, 360, 105, 'U_PWM / pwm_period', ['20 kHz / 주기별 duty 갱신'])
    d.wire([(810, 2020), (910, 2020)])
    d.label(830, 1945, 'measured_speed[12:0]', 16)
    d.wire([(1060, 1970), (1060, 1920), (780, 1920), (780, 1890)])
    d.label(820, 1905, 'pid_duty[12:0]', 17)
    d.wire([(840, 1840), (980, 1840), (980, 1900), (1490, 1900), (1490, 1970)])
    d.label(1130, 1935, 'requested_duty[12:0] / enabled', 17)
    d.wire([(1110, 1830), (840, 1830)])
    d.label(860, 1785, ['fault_latched', 'motor_derated'], 16)
    d.wire([(640, 1470), (640, 1700)])
    d.label(660, 1510, ['class_valid / class_id', 'ps_heartbeat', 'kp_gain[17:0] / ki_gain[17:0]', 'open_loop_duty[12:0] / control flags'], 18)
    d.wire([(1780, 1700), (1780, 1470)])
    d.label(1760, 1510, ['motor_fault → motor_fault_latched', 'motor_* / quad_* 상태', '속도[12:0] / 적분·위치[31:0]'], 17, anchor='end')
    d.label(60, 1770, ['motor_sw[3:0]', 'motor_stop'], 20)
    d.wire([(60, 1810), (410, 1810)], 'io')
    d.label(60, 1950, ['encoder_a', 'encoder_b'], 20)
    d.wire([(60, 1990), (410, 1990)], 'io')
    d.text(440, 2120, 'U_RESET / reset_sync · U_QUADRATURE / encoder_quadrature: 내부 연결은 Sheet 2 참조', 17)
    d.node(2080, 1900, 320, 145, 'L298N / DC Motor', ['외부 모터 구동부'], 'io')
    d.wire([(1880, 1980), (2080, 1980)], 'io')
    d.label(1900, 1900, ['motor_pwm', 'motor_in1', 'motor_in2'], 18)
    d.node(2080, 2100, 320, 95, 'LD0 / LD1', ['motor_armed / motor_fault'], 'io')
    d.wire([(1880, 2140), (2080, 2140)], 'io')
    d.legend(2260)
    return d.save()


def motor_detail():
    d = Drawing('02_motor_signals', 'Motor Control · Internal Signal Architecture',
                'fourier_motor_struct.vhd / entity fourier_motor_impl · U_IMPL 내부 연결 · Sheet 2 / 3', 2440, 2140)
    d.frame(280, 170, 1900, 1730, 'motor / fourier_motor_control', 'url(#hatch)')
    d.node(380, 255, 420, 125, 'U_RESET / reset_sync', ['async assertion / 2-clock release'])
    d.label(35, 260, ['reset_n', 'stop_button'], 22)
    d.wire([(35, 320), (380, 320)], 'io')
    d.label(400, 420, ['async_reset = NOT reset_n OR stop_button', 'rst → U_RUN / U_SAFETY / U_ENCODER / U_QUADRATURE / U_PWM'], 18)
    d.text(1500, 270, '공통 클럭', 22, bold=True)
    d.label(1500, 315, 'clk ← FCLK_CLK0 (100 MHz)', 21)
    d.label(1120, 365, 'controller_reset = rst OR NOT enabled', 19)
    d.wire([(800, 320), (1000, 320)], 'clock')
    d.label(830, 300, 'rst', 20)
    d.text(1015, 310, '내부 rst 배포', 18)

    d.node(380, 565, 560, 255, 'U_RUN / motor_run_control',
           ['SW 동기화 / OFF→ON arm', 'sample_tick / pid_start', 'reference / duty 선택 / derating'])
    d.node(1480, 565, 580, 255, 'U_SAFETY / safety_supervisor',
           ['연속 class 판정 / PS heartbeat', 'warning / derated / fault latch', '원인 / 누적 횟수 / watchdog count'])
    d.label(35, 600, 'sw[3:0]', 22)
    d.wire([(35, 645), (380, 645)], 'io')
    d.label(1450, 475, ['class_valid / class_id', 'ps_heartbeat'], 20)
    d.wire([(1770, 505), (1770, 565)])
    d.wire([(940, 610), (1480, 610)])
    d.label(1020, 585, ['armed_command → armed', 'clear_fault → clear'], 18)
    d.wire([(1480, 755), (940, 755)])
    d.label(1020, 715, ['latched → fault_latched', 'motor_derated → derated'], 18)
    d.wire([(2060, 690), (2370, 690)], 'io')
    d.label(2080, 575, ['motor_fault', 'motor_warning / motor_derated', 'motor_watchdog_fault', 'motor_fault_cause[1:0]'], 17)

    d.node(380, 1050, 560, 200, 'U_ENCODER / encoder_speed_hybrid',
           ['A 펄스 동기화 / 주기 + 창 방식', 'U_DIVIDER / unsigned_divider'])
    d.label(35, 1100, 'encoder_a', 22)
    d.wire([(35, 1150), (380, 1150)], 'io')
    d.wire([(540, 820), (540, 1050)])
    d.label(560, 925, 'sample_tick', 20)
    d.wire([(940, 1100), (1020, 1100), (1020, 925), (800, 925), (800, 820)])
    d.label(1035, 950, 'speed_valid', 19)

    d.node(1480, 1050, 580, 230, 'U_PID / pid_fixed',
           ['reference / measured / Q16 gains', 'PI / anti-windup / duty saturation', 'rst ← controller_reset'])
    d.wire([(940, 1180), (1480, 1180)])
    d.label(1035, 1150, 'measured_speed[12:0]', 20)
    d.wire([(940, 665), (1200, 665), (1200, 1080), (1480, 1080)])
    d.label(1220, 875, ['pid_start → start', 'speed_reference[12:0] → reference'], 17)
    d.wire([(1480, 1240), (1120, 1240), (1120, 810), (940, 810)])
    d.label(1135, 1000, ['pid_busy', 'pid_duty[12:0]'], 18)
    d.label(2100, 990, ['kp_gain[17:0]', 'ki_gain[17:0]', 'anti_windup_enable'], 17)
    d.wire([(2370, 1130), (2060, 1130)], 'io')
    d.label(35, 720, ['open_loop_enable', 'open_loop_duty[12:0]'], 17)
    d.wire([(35, 780), (380, 780)], 'io')

    d.node(380, 1510, 560, 245, 'U_QUADRATURE / encoder_quadrature',
           ['encoder_a / encoder_b', '방향 / 위치 / 불법 전이', '무펄스 timeout / position overflow'])
    d.label(35, 1570, ['encoder_a', 'encoder_b'], 22)
    d.wire([(35, 1625), (380, 1625)], 'io')
    d.node(1480, 1510, 580, 170, 'U_PWM / pwm_period',
           ['duty 0..4096 → 20 kHz PWM', 'enable ← enabled / rst ← rst'])
    d.wire([(940, 780), (1320, 780), (1320, 1555), (1480, 1555)])
    d.label(1340, 1390, ['requested_duty[12:0] → duty', 'enabled → enable'], 17)
    d.wire([(1320, 1460), (1050, 1460), (1050, 1555), (940, 1555)])
    d.junction(1320, 1460)
    d.label(950, 1420, ['enabled / requested_duty[12:0]', 'clear_fault'], 17)
    d.label(420, 1430, ['quad_position_wr_en', 'quad_position_wr_value[31:0]'], 18)
    d.wire([(660, 1460), (660, 1510)])
    d.wire([(2060, 1600), (2370, 1600)], 'io')
    d.label(2080, 1560, 'motor_pwm', 20)
    d.label(1500, 1760, ['motor_in1 = enabled', "motor_in2 = '0'", 'motor_armed = enabled'], 20)
    d.text(310, 1840, '검정 선: 이 파일의 local signal 이름 / 외부 모터·AXI 포트는 신호표에서 대응 관계 확인', 19)
    d.legend(1950)
    return d.save()


def core_detail():
    d = Drawing('03_fft_npu_signals', 'FFT / NPU · Internal Signal Architecture',
                'vibration_core_fsm.vhd / npu_2pe_fsm.vhd · 실제 포트 연결 · Sheet 3 / 3', 2420, 2170)
    d.frame(280, 180, 1870, 1710, 'U_CORE / vibration_core', 'url(#hatch)')
    d.node(400, 280, 590, 190, '순서 제어 / result registers',
           ['clocked_proc / nextstate_proc', 'result_capture_proc / handshake_proc',
            'cycle_count_proc / result_index_proc', 'FFT → NPU → STORE 11 words'])
    d.label(35, 300, ['clk / rst', 'start'], 22)
    d.wire([(35, 365), (400, 365)], 'io')
    d.wire([(2150, 350), (2370, 350)], 'io')
    d.label(2120, 245, ['busy / done', 'cycles[31:0] / npu_cycles[31:0]',
                       'features[31:0] / hidden[31:0]', 'logits[15:0] / class_id'], 18, anchor='end')
    d.node(400, 720, 590, 250, 'U_FFT / fft64_features',
           ['64-point radix-2 FFT', 'Q1.15 twiddle / 각 단계 /2', '4개 대역 특징 / INT8 범위'])
    d.wire([(550, 470), (550, 720)])
    d.label(570, 585, 'fft_start → start', 20)
    d.wire([(820, 720), (820, 470)])
    d.label(840, 585, ['fft_busy / fft_done', 'fft_features[31:0]'], 19)
    d.label(35, 775, ['bram_rdata[31:0]', 'low 16 bits'], 19)
    d.wire([(35, 845), (400, 845)], 'bus')
    d.label(410, 1030, ['sample_en → fft_sample_enable', 'sample_addr[5:0] → fft_sample_address[5:0]', 'sample_data[15:0] ← bram_rdata[15:0]'], 18)

    d.frame(1310, 620, 740, 860, 'U_NPU / npu_2pe', '#e5f0f7')
    d.node(1370, 720, 620, 160, '입력·가중치·양자화 제어',
           ['input_select / weight_select / quantize', '4 inputs → 4 ReLU → 2 logits'])
    d.wire([(990, 360), (1140, 360), (1140, 755), (1370, 755)])
    d.label(1160, 490, ['npu_start → start', 'features[31:0]'], 19)
    d.label(1110, 680, 'FFT 결과는 코어 레지스터에 저장 후 NPU로 전달', 16, anchor='middle')
    d.node(1370, 1160, 275, 180, 'U_PE0 / mac_pe', ['INT8 × INT8', 'INT32 accumulate'])
    d.node(1715, 1160, 275, 180, 'U_PE1 / mac_pe', ['INT8 × INT8', 'INT32 accumulate'])
    d.wire([(1455, 880), (1455, 1160)])
    d.label(1335, 970, ['input_value[7:0]', 'pe0_weight[7:0]', 'pe0_bias[31:0]', 'clear_mac / enable_mac'], 17)
    d.wire([(1800, 880), (1800, 1160)])
    d.label(1740, 970, ['input_value[7:0]', 'pe1_weight[7:0]', 'pe1_bias[31:0]', 'clear_mac / enable_mac'], 17)
    d.wire([(1590, 1160), (1590, 880)])
    d.label(1605, 1125, 'pe0_accumulator[31:0]', 15, anchor='end')
    d.wire([(1940, 1160), (1940, 880)])
    d.label(1970, 1125, 'pe1_accumulator[31:0]', 15, anchor='end')
    d.text(1400, 1415, 'ROM: w0.mem / w1.mem / bias.mem / shift.mem', 18)
    d.wire([(1310, 1360), (1190, 1360), (1190, 440), (990, 440)])
    d.label(1210, 1510, ['npu_done / npu_busy', 'npu_hidden[31:0]', 'npu_logits[15:0] / npu_class', 'npu_cycles[31:0]'], 19)

    d.node(400, 1510, 590, 210, 'BRAM 포트 선택 / result_write_proc',
           ['입력: word 0..63', '결과: word 256..266 / 11 words', 'byte address = word address << 2'])
    d.wire([(950, 970), (950, 1510)])
    d.wire([(990, 420), (1050, 420), (1050, 1480), (700, 1480), (700, 1510)])
    d.label(410, 1460, 'features / hidden / logits / class_id', 17)
    d.wire([(400, 1600), (35, 1600)], 'bus')
    d.label(35, 1400, ['bram_en', 'bram_we[3:0]', 'bram_addr[9:0]', 'bram_wdata[31:0]'], 19)
    d.text(310, 1835, '공통: clk / rst → FFT·NPU·두 PE. 코어가 완료 결과를 보관하고 BRAM에 기록한다.', 18)
    d.legend(1960)
    return d.save()


def export_tables():
    rows = []
    for entity, item in sorted(ENTITIES.items()):
        for name, info in item['ports'].items():
            rows.append({'entity': entity, 'port': name, 'direction': info['direction'],
                         'bits': info['width'], 'source': item['source']})
    with (OUT / 'module_ports.csv').open('w', newline='', encoding='utf-8-sig') as stream:
        writer = csv.DictWriter(stream, fieldnames=['entity', 'port', 'direction', 'bits', 'source'])
        writer.writeheader()
        writer.writerows(rows)
    mappings = []
    for parent, item in ENTITIES.items():
        text = item['text']
        for instance in re.finditer(r'(\w+)\s*:\s*ENTITY\s+work\.(\w+)(?:\(\w+\))?', text, re.I):
            child = instance[2].lower()
            start = re.search(r'PORT\s+MAP\s*\(', text[instance.end():], re.I)
            assert start and child in ENTITIES, (parent, child)
            body, _ = parenthesized(text, instance.end() + start.start())
            for association in split_associations(body):
                formal, actual = [value.strip() for value in association.split('=>', 1)]
                info = ENTITIES[child]['ports'][formal.lower()]
                mappings.append({'parent': parent, 'instance': instance[1], 'child_entity': child,
                                 'port': formal, 'direction': info['direction'], 'bits': info['width'],
                                 'local_signal_or_expression': actual, 'source': item['source']})
    with (OUT / 'port_connections.csv').open('w', newline='', encoding='utf-8-sig') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(mappings[0]))
        writer.writeheader()
        writer.writerows(mappings)
    # Physical board boundary names differ from some module formal port names.
    board_map = {'motor_sw': ('fourier_motor_control', 'sw'),
                 'motor_stop': ('fourier_motor_control', 'stop_button')}
    for name in ['encoder_a', 'encoder_b', 'motor_pwm', 'motor_in1', 'motor_in2', 'motor_armed', 'motor_fault']:
        board_map[name] = ('fourier_motor_control', name)
    for name in ['mpu_sclk', 'mpu_mosi', 'mpu_miso', 'mpu_cs_n']:
        board_map[name] = ('axi_vibration_top', name)
    pins = {}
    for line in (ROOT / 'fourier/constraints/zybo_z7_20.xdc').read_text().splitlines():
        match = re.match(r'set_property PACKAGE_PIN (\w+) \[get_ports (.+)\]', line)
        if match:
            pins[match[2].strip('{}')] = match[1]
    board_rows = []
    for name, (entity, formal) in board_map.items():
        info = ENTITIES[entity]['ports'][formal]
        names = [name] if info['width'] == 1 else [f'{name}[{bit}]' for bit in range(info['width'])]
        assert all(item in pins for item in names), (name, names)
        board_rows.append({'board_port': name, 'direction': info['direction'], 'bits': info['width'],
                           'module_port': entity + '.' + formal,
                           'package_pin': '; '.join(item + '=' + pins[item] for item in names)})
    with (OUT / 'board_ports.csv').open('w', newline='', encoding='utf-8-sig') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(board_rows[0]))
        writer.writeheader()
        writer.writerows(board_rows)
    tcl = (ROOT / 'vivado/create_fourier.tcl').read_text()
    bd = []
    modules = {'accelerator': 'axi_vibration_top', 'motor': 'fourier_motor_control'}
    for line in tcl.splitlines():
        if not line.startswith('net '):
            continue
        endpoints = line.split()[1:]
        widths = []
        for endpoint in endpoints:
            cell, pin = endpoint.split('/', 1)
            if cell in modules:
                widths.append(ENTITIES[modules[cell]]['ports'][pin.lower()]['width'])
        assert not widths or len(set(widths)) == 1, (line, widths)
        bd.append({'endpoints': endpoints, 'custom_rtl_bits': widths[0] if widths else None})
    manifest = {'source_sha256': {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in [*SOURCES, Path(__file__).resolve(), ROOT / 'vivado/create_fourier.tcl', ROOT / 'fourier/constraints/zybo_z7_20.xdc']},
                'entities': len(ENTITIES), 'port_rows': len(rows), 'port_map_rows': len(mappings),
                'board_port_groups': len(board_rows),
                'bd_nets': bd, 'note': 'Conceptual module drawings, based on source ports and mappings; not a Vivado screenshot.'}
    (OUT / 'signal_manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')


def check_local_signal_widths():
    expected = {
        'axi_vibration_impl': {'core_start': 1, 'core_busy': 1, 'core_done': 1,
                              'spi_address': 7, 'spi_write_data': 8, 'spi_read_data16': 16,
                              'miso_synchronized': 1, 'bram_word_address': 10},
        'fourier_motor_impl': {'armed_command': 1, 'clear_fault': 1, 'fault_latched': 1,
                              'enabled': 1, 'sample_tick': 1, 'speed_valid': 1, 'pid_start': 1,
                              'pid_duty': 13, 'requested_duty': 13, 'measured_speed': 13,
                              'speed_reference': 13, 'controller_reset': 1},
        'vibration_core': {'fft_start': 1, 'fft_busy': 1, 'fft_done': 1, 'fft_features': 32,
                           'fft_sample_enable': 1, 'fft_sample_address': 6,
                           'npu_start': 1, 'npu_hidden': 32, 'npu_logits': 16, 'npu_class': 1},
        'npu_2pe': {'input_value': 8, 'pe0_weight': 8, 'pe1_weight': 8,
                   'pe0_bias': 32, 'pe1_bias': 32, 'pe0_accumulator': 32, 'pe1_accumulator': 32,
                   'clear_mac': 1, 'enable_mac': 1},
    }
    for entity, signals in expected.items():
        actual = {name: info['width'] for name, info in ENTITIES[entity]['ports'].items()}
        for declaration in re.finditer(r'\bSIGNAL\s+([^:;]+):\s*([^;]+);', ENTITIES[entity]['text'], re.I):
            size = re.search(r'\((\d+)\s+DOWNTO\s+(\d+)\)', declaration[2], re.I)
            bits = int(size[1]) - int(size[2]) + 1 if size else 1
            for name in declaration[1].split(','):
                actual[name.strip().lower()] = bits
        for name, bits in signals.items():
            assert actual[name] == bits, (entity, name, actual[name], bits)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    require('axi_vibration_top', 's_axi_awaddr', 's_axi_wdata', 'm_bram_addr', 'class_valid', 'class_id')
    require('fourier_motor_control', 'motor_pwm', 'motor_armed', 'motor_fault', 'encoder_a', 'encoder_b')
    check_local_signal_widths()
    export_tables()
    for drawing in [overview, motor_detail, core_detail]:
        print(drawing())
    print('SOURCE PORT CHECK PASS; SVG / PNG / CSV signal tables exported.')


if __name__ == '__main__':
    main()
