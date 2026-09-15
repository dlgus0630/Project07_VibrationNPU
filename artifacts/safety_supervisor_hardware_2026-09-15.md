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
25% figure is the RTL cap on the duty request; the actual JD1 duty percentage was not captured with an
oscilloscope during this specific live-SW3 trial. The duty math itself (50% -> 25% -> 0%) was independently
confirmed with a scope on the UART `x` persistent-fault trial below, which exercises the same `pwm_period`
and derate-clamp logic from a different trigger source; see "Oscilloscope confirmation of JD1 duty cycle".
The class 1 windows come from the controlled 32 Hz torque-ripple switch, which is an injected condition and
not a naturally occurring bearing fault.

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

## Oscilloscope confirmation of JD1 duty cycle

The persistent-fault trial above proved the register-level state transitions but not the physical PWM duty
cycle; the derate evidence was `derated=1` in the status register, not a measured waveform. This closes that
gap. A Tektronix TBS 1102B-EDU was probed on JD1 (L298N ENA/PWM) with common GND, 25.0 us/div, Duty Cycle and
Period measurement on CH1, while the same UART `x` sequence used above was repeated on the safety-supervisor
build.

| Step | AXI status | Scope duty | Scope period | RTL prediction | Match |
|---|---|---:|---:|---:|---|
| baseline (armed, no injection) | all clear | 50.0% | 50.00 us | 50.0% (`threshold=2500/5000`) | yes |
| after 1st `x` (warning) | `warning=1` | 50.0% | 50.00 us | 50.0%, unchanged | yes |
| after 2nd `x` (derated) | `derated=1` | 25.0% | 50.00 us | 25.0% (`threshold=1250/5000`) | yes |
| after 3rd `x` (latched) | `latched=1, cause=1` | 0% (flat, scope reports `?`) | invalid | 0% (`enable=0`) | yes |
| SW0 OFF -> ON (clear/rearm) | all clear, `abnormal_total=3` retained | 50.0% | 50.00 us | 50.0% | yes |

At the latched step the scope's own duty/period/frequency readouts turned into `?`-flagged garbage (for
example a spurious "66.6%?" duty and "3.333 MHz?" frequency) because there is no periodic edge left to lock
onto; the trigger status line also fell from `Trig'd` to `Auto`. That failure to measure is itself the
confirmation that the PWM line is a static low, not a fast signal outside the scope's range.

Every measured duty cycle matches the `pwm_period` calculation exactly (`scaled=(duty*PERIOD)>>12` with
`PERIOD=5000` at the 100 MHz PL clock), including the unchanged 50.0% through the warning step, which is the
detail most likely to be wrong if the derate compare (`requested_duty>13'd1024`) had an off-by-one error.

This trial reused the same physical setup as the persistent-fault trial (UART `x` command, not the live SW3
torque-ripple switch), so it demonstrates the classifier-latch and derate paths, not a live-sensor derate
recovery with a scope attached. The watchdog path's physical cutoff latency is still not scope-measured; the
1.010 s JTAG-halt trial above only bounds it, and a single-shot capture on JD1 during a watchdog trip is the
remaining gap.

Screenshots: `measurements/scope_captures_2026-09-15/jd1_pwm_baseline_50pct.jpg`,
`jd1_pwm_derated_25pct.jpg`, `jd1_pwm_latched_0pct.jpg`.

## Correction: the watchdog trip latency is not 500 ms, and not "within 1.010 s"

The "Watchdog response" section above states the halt-to-trip stop happened "within the 1.010 s halt
interval" and separately that the RTL timeout is 500 ms. Both statements are misleading on their own, and a
follow-up session bisected the real value with scripted (not manually-typed) JTAG timing.

Method: `stop` on Cortex-A9 #0, a Tcl `after <N>` wait, `con`, then either a UART `f` read or a direct
`mrd -force -value 0x43c00004` over JTAG (which works while the core is still halted, since ARM memory-mapped
debug access does not require the core to be running). The UART route was cross-checked against the direct
JTAG register read and the two agreed. `armed` was confirmed 1 throughout (the motor was audibly running) and
UART was confirmed unresponsive during the halt (see `probe_during_halt.py`), ruling out "wrong core halted"
or "watchdog counter held at 0 by `!armed`" as explanations.

| Halt duration | Result |
|---:|---|
| 380 - 500 ms (7 steps) | never tripped |
| 700 ms | never tripped |
| 778 ms (continuous poll, still halted) | never tripped |
| 1489 ms (continuous poll, still halted) | never tripped |
| **1600 ms** | **tripped** |
| 1700 ms | tripped |
| 2000 ms | tripped |
| 3000 ms (confirmed latched while still halted, before resume) | tripped |

The real trip threshold sits in **(1489 ms, 1600 ms]**, roughly 3x the RTL-computed 50,000,000-cycle / 500 ms
figure. Yesterday's "1.010 s" data point is now understood to have most likely included unscripted, manual
command-entry time between `stop` and `con` that was not actually 1.010 s of halted duration -- the clean,
scripted 1.010 s-equivalent range (700 ms, 778 ms) here did not trip.

Root cause is not identified. What has been ruled out:

- Wrong halt target: `mrd -force -value` during the halt reads a live, correct baseline (`raw=2`, matching the
  known `sticky_done=1` idle state seen over UART), and UART is confirmed silent during the halt.
- Wrong parameter value: `open_checkpoint` on `reports/fourier_safety/fourier_safety.dcp` shows
  `watchdog_count_reg[0..25]`, a 26-bit counter -- exactly `ceil(log2(50000000))`, which is the width a
  50,000,000-target counter needs. A 3x larger effective target (about 150,000,000) would need a 28-bit
  counter, so the register width argues the constant elaborated correctly and the extra delay is not a
  simple parameter-propagation bug.
- Wrong clock: the same `clk` net drives `pwm_period` in the same module, and the oscilloscope measured
  exactly 50.00 us / 20.00 kHz for the PWM period earlier in this document, matching the 100 MHz assumption
  independently.

What is not yet identified: why `watchdog_count` takes roughly 3x longer than its target to reach
`WATCHDOG_CYCLES-1` while genuinely halted the whole time. Diagnosing this further needs visibility into the
counter itself, which is not exposed over AXI; the practical next step is an ILA on `watchdog_count` (or a
debug output pin) in a future rebuild, not something resolved by more black-box halt trials.

Trial log: `measurements/watchdog_bisection_2026-09-15/trials.csv`.

## Raw evidence

- `artifacts/safety_logs_2026-09-15/safety_normal_01_cause2.csv` (first, unexplained `cause=2` event)
- `artifacts/safety_logs_2026-09-15/safety_normal_interleaved.csv`
- `artifacts/safety_logs_2026-09-15/safety_abnormal_trial1.csv` through `safety_abnormal_trial3.csv`
- `artifacts/safety_logs_2026-09-15/safety_persistent_trial1.csv` through `safety_persistent_trial3.csv`
- `artifacts/safety_logs_2026-09-15/watchdog_repro_psu_off.csv`
- `artifacts/safety_logs_2026-09-15/watchdog_arm_halt_2026-09-15.csv`
- `artifacts/safety_logs_2026-09-15/watchdog_status_after_halt.csv`
- `artifacts/safety_logs_2026-09-15/watchdog_status_after_clear.csv`
