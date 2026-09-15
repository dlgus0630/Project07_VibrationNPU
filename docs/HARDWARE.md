# Zybo Z7-20 배선 및 계측

## MPU-6500/9250

| Zybo JE | 신호 | MPU-6500/9250 |
|---|---|---|
| JE1 | SCLK | SCL/SCLK |
| JE2 | MOSI | SDA/SDI |
| JE3 | MISO | AD0/SDO |
| JE4 | CS | NCS/CS |
| JE5 또는 JE11 | GND | GND |
| JE6 또는 JE12 | 3.3 V | 3.3 V 지원이 확인된 VCC |

사진의 보드는 `MPU-9250/6500` 공용 breakout이며 `VCC`, `GND`, `SCL/SCLK`, `SDA/SDI`,
`AD0/SDO`, `INT`, `NCS`, `FSYNC` 표기를 확인했다. 기판에 전원 부품은 보이지만 사진만으로
VCC 허용 전압과 신호 레벨까지 확정할 수 없다. 판매 사양 또는 전압 측정으로 확인한 뒤 Zybo의
3.3 V만 사용한다. PCB 표기는 두 센서에 공용이므로 실장 칩이 MPU-9250이라는 뜻은 아니다.
펌웨어의 `i` 명령으로 WHO_AM_I를 읽는다. `0x70`은 MPU-6500, `0x71`은 MPU-9250으로 구분해
기록하며 그 밖의 값은 거부한다. 현재 실물은 `0x70`이므로 MPU-6500이다. 현재 펌웨어는 SPI mode 0,
1 MHz, X축 ±2 g, 명목 1 kHz를 사용한다. 실측 MPU-6500은 4 kHz 내부 data-ready에
`SMPLRT_DIV=3`을 적용하고, MPU-9250은 `SMPLRT_DIV=0`을 사용한다. 센서는 회전축이 아니라 고정된 모터 하우징 또는
브래킷에 부착한다.

## L298N

| Zybo JD | 연결 |
|---|---|
| JD1 | ENA, ENA 점퍼 제거 |
| JD2 | IN1 |
| JD3 | IN2 |
| JD5 또는 JD11 | L298N 및 전원 공통 GND |

모터 전원 12 V는 L298N 모터 전원 단자에만 넣는다. Zybo 또는 센서 VCC에 연결하지 않는다.
ENA에는 10 kΩ 정도의 GND pull-down을 두면 FPGA 설정 전 구동을 막을 수 있다. 모터 연결 전에
PWM 0..3.3 V, 20 kHz와 IN1/IN2 상태를 오실로스코프로 확인한다.

사진의 L298N에는 점퍼가 장착된 것으로 보이지만 ENA 점퍼와 5V-EN 점퍼를 사진만으로 구별하기
어렵다. 실크 인쇄를 확인해 ENA 점퍼만 제거하고, 5V-EN과 논리 5 V 단자의 사용법은 모듈 사양에
맞춘다. Zybo 핀에는 L298N의 5 V를 연결하지 않는다.

일반 접지형 오실로스코프의 probe ground는 회로 GND에만 연결한다. L298N OUT1/OUT2에 ground
clip을 연결하면 안 된다. 모터 차동 전압은 두 채널을 각각 OUT1/OUT2에 대고 `CH1-CH2`로 본다.

초기 bench supply 설정은 출력 OFF에서 배선하고 12.0 V, 전류 제한 0.3~0.5 A로 시작한다.
무부하 25% duty부터 확인하며 기동하지 않으면 오래 유지하지 않는다. 모터 정격·stall 전류가
확인되기 전에는 전류 제한을 임의로 크게 올리지 않는다.

실측 진동 분류 수집에서는 12.0 V를 유지한다. 정상 조건은 `SW2=ON, SW1=OFF, SW3=OFF`의
50% 고정 duty다. fault injection 조건은 같은 스위치에서 SW3만 ON해 25%와 75% duty를
32 Hz로 교대한다. 이는 재현 가능한 토크 리플 시험이며 자연 발생 기계 고장으로 표현하지 않는다.

안전 supervisor 확장판은 첫 이상에서 warning, 두 번째 연속 이상에서 최대 25% PWM 제한,
세 번째 연속 이상에서 latch 정지한다. UART `f` 명령으로 각 상태와 fault cause를 읽는다.
watchdog 시험은 모터 구동 중 ARM만 의도적으로 정지해 500 ms 이후 PL이 차단하는지 확인하되,
배선이나 PSU 출력은 시험 도중 변경하지 않는다. 오실로스코프 CH1은 JD1, ground는 공통 GND에 두고
single-shot으로 정상 50%, 제한 25%, 최종 LOW를 기록한다.
