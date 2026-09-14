# Fault latch 최종 빌드 기록

최종 소스 digest `6d4d77553522279e0fdff5f16ef9c07bd57a13865064e920da1e41eb77b50333`에
대해 MATLAB/Simulink와 XSim을 통과했다. 실행 소스가 같은 상태에서 Vivado 2024.2와
Vitis 2024.2로 최종 빌드했으며, 이후 변경은 최종 실측 결과를 반영한 문서뿐이다.
이 문서는 `artifacts/` 아래에 있어 source digest에 포함되지 않는다.

## 검증 결과

| 단계 | 결과 |
|---|---|
| MATLAB/Simulink | PASS, 반환 digest 일치 |
| XSim | 7/7 PASS |
| Vivado route | setup `+0.039 ns`, hold `+0.013 ns` |
| DRC | Error 0 |
| Slice LUT | 11,265 / 53,200 (21.17%) |
| Slice register | 7,272 / 106,400 (6.83%) |
| BRAM tile | 1 / 140 (0.71%) |
| DSP | 5 / 220 (2.27%) |
| Vitis platform/BSP/FSBL | PASS |
| Vitis ARM application | PASS; text 59,803 B, data 1,792 B, bss 22,996 B |

## 최종 artifact

| 파일 | SHA-256 |
|---|---|
| `fourier.bit` | `cc48b9e7577f06f7978887f3a582018285058b828409ace5b291ec34eb9e9360` |
| `fourier.xsa` | `9bb245d0958c871fa8820785b90f296f018fb4694bb7363e96b28e76fc31374b` |
| `fourier_app.elf` | `428f788bfcf8710d217aeca11d023babd43255dec8d8a219b3e8aecad1c66e46` |
| `fsbl.elf` | `b6645ffd48ab1d2f8cffb4af2b62704d0b691ca37683da58952f8bc72a8c5f44` |
| `ps7_init.tcl` | `24cc6d854aa7de05a066e50064ac5faf9589fff6b43236f23ccdbd1120b1e208` |
| `matlab_input.zip` | `fc2c20174e803ef64c4f6c26a83293e6e2ce68d3e17fc041b74da7e974debee9` |
| `matlab_results.zip` | `59a06415f3807f416744c68da69561724a946d96da6695b887b4932e10a2e7af` |

XSA 내부 bitstream과 `fourier.bit`의 SHA-256은 일치한다. 새 Vitis 작업공간으로 가져간
`main.c`, `golden.c`, `golden.h`, `model_data.h`는 저장소 원본과 바이트 단위로 일치한다.
ARM ELF에는 공동작성자나 생성 도구를 나타내는 표기가 없다.

실물에서는 정상 운전과 3회 연속 이상 판정 뒤 `LD1=ON` 및 PWM 차단을 확인했다.
SW0 OFF clear와 SW0 ON 재arm 뒤 모터 재회전도 확인했다. 상세 결과는
`artifacts/hardware_validation_2026-09-14.md`에 기록했다.
