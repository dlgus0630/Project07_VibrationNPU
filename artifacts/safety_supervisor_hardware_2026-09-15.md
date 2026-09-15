# Safety supervisor hardware validation — 2026-09-15

## Test configuration

- Board: Zybo Z7-20
- Sensor: MPU-6500 over SPI, `WHO_AM_I=0x70`
- Motor/driver: JGB37-520 12 V / L298N
- Supply: 12.0 V, 0.5 A current limit
- Normal drive: SW2 ON, SW1/SW3 OFF, 50% requested duty
- Safety policy: one abnormal window warns, two consecutive windows cap PWM at 25%, three latch the drive off
- Watchdog: PS heartbeat every 100 ms, PL timeout 500 ms

## Artifacts

| Artifact | SHA-256 |
|---|---|
| `fourier_safety_supervisor.bit` | `a57f472a1c4f31c3baa10cf35126dbf65b2e4557dc1b1296f290e3dd5aceb255` |
| `fourier_safety_supervisor.xsa` | `344c6a754543682bf382fea537357506bdc3d15db90fb5c3a177d0c814a865b1` |
| `fourier_safety_supervisor.elf` | `be278a0fe3efc8fd9039983a5a125ef6dc10b759de91e713e65274a34af39a21` |

The ELF adds heartbeat service inside the blocking sensor-acquisition window and UART command `x` for one
deterministic pass of a stored, previously measured abnormal window through the same FFT64/INT8-NPU path.

## Real-sensor response

Normal rotation was approximately 0.13 A. Three live sensor windows were class 0, CPU/PL matched 3/3, and
warning, derate, latch, and watchdog remained clear.

With the 32 Hz controlled torque-ripple switch enabled:

| Window | NPU class | warning | derated | latched | Result |
|---:|---:|---:|---:|---:|---|
| 1 | 1 | 1 | 0 | 0 | warning, motor continues |
| 2 | 1 | 1 | 1 | 0 | derated bit set, RTL caps PWM request at 25% |
| 3 | 0 | 0 | 0 | 0 | vibration returned to normal after mitigation |

This is the intended recovery path: the supervisor does not stop the motor when output limiting removes the
detected condition. The lifetime abnormal count remained 2.

The derate evidence here is the AXI `0x04`/`0x4C` register state (`derated=1`), not a measured duty cycle. The
25% figure is the RTL cap on the duty request; the actual JD1 duty percentage was never captured with an
oscilloscope or any other instrument. The class 1 windows come from the controlled 32 Hz torque-ripple switch,
which is an injected condition and not a naturally occurring bearing fault.

## Persistent-fault and rearm response

To exercise the persistent branch reproducibly, UART `x` passed one stored real abnormal sensor window through
the CPU golden model and PL FFT64/INT8 NPU per command. All three CPU/PL comparisons matched.

| Injection | NPU class | warning | derated | latched | cause | Motor |
|---:|---:|---:|---:|---:|---:|---|
| 1 | 1 | 1 | 0 | 0 | 0 | running |
| 2 | 1 | 1 | 1 | 0 | 0 | limited |
| 3 | 1 | 0 | 0 | 1 | 1 | stopped |

After the third result the motor stopped and supply current fell from about 0.13 A to 0.01 A. A later status
read still reported `latched=1`, `cause=1`, and `consecutive=3`. SW0 OFF cleared latch/cause/consecutive while
preserving the lifetime abnormal count of 3. SW0 ON then restarted the motor at approximately 0.13 A.

## Watchdog response

One early normal run reported `cause=2`, captured in
`artifacts/safety_logs_2026-09-15/safety_normal_01_cause2.csv`. It was not a mechanical or classification
event: all three windows were class 0 and the lifetime abnormal count was zero. The root cause was never
identified. After SW0 clear, an armed five-second test and an exact three-window sensor reproduction both kept
watchdog clear, so the trip could not be reproduced on demand. The firmware was then hardened to emit heartbeat
during sensor acquisition, and the powered normal 3/3 test also kept watchdog clear. Because the original event
never recurred, that hardening is a plausible mitigation rather than a confirmed fix for a diagnosed cause.

The final deliberate test armed the motor at approximately 0.13 A, halted Cortex-A9 #0 through JTAG for
1.010 s, and then resumed it. The PL latched the motor off while the ARM was stopped. After resume the register
read was `latched=1`, `watchdog=1`, `cause=2`, `consecutive=0`; the motor was stopped at approximately 0.01 A.
This distinguishes the watchdog trip from a classifier trip. SW0 OFF cleared latch/watchdog/cause while keeping
the lifetime abnormal count at 3, and SW0 ON restarted the motor at approximately 0.13 A.

The RTL timeout is 50,000,000 cycles at 100 MHz, or 500 ms. This test proves that the stop occurred within the
1.010 s halt interval. It does not measure the exact physical cutoff latency; a JD1 oscilloscope single-shot is
required before reporting a measured 500 ms value.

## Raw evidence

- `artifacts/safety_logs_2026-09-15/safety_normal_01_cause2.csv` (first, unexplained `cause=2` event)
- `artifacts/safety_logs_2026-09-15/safety_normal_interleaved.csv`
- `artifacts/safety_logs_2026-09-15/safety_abnormal_trial1.csv` through `safety_abnormal_trial3.csv`
- `artifacts/safety_logs_2026-09-15/safety_persistent_trial1.csv` through `safety_persistent_trial3.csv`
- `artifacts/safety_logs_2026-09-15/watchdog_repro_psu_off.csv`
- `artifacts/safety_logs_2026-09-15/watchdog_arm_halt_2026-09-15.csv`
- `artifacts/safety_logs_2026-09-15/watchdog_status_after_halt.csv`
- `artifacts/safety_logs_2026-09-15/watchdog_status_after_clear.csv`
