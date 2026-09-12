# Zybo Z7-20 배선 및 계측

## MPU-9250

| Zybo JE | 신호 | MPU-9250 |
|---|---|---|
| JE1 | SCLK | SCL/SCLK |
| JE2 | MOSI | SDA/SDI |
| JE3 | MISO | AD0/SDO |
| JE4 | CS | NCS/CS |
| JE5 또는 JE11 | GND | GND |
| JE6 또는 JE12 | 3.3 V | 3.3 V 지원이 확인된 VCC |

breakout 앞뒷면의 부품과 전원 표기를 확인하기 전에는 VCC를 연결하지 않는다. 펌웨어는 SPI mode 0,
1 MHz, WHO_AM_I `0x71`, X축 ±2 g, 명목 1 kHz를 사용한다. 센서는 회전축이 아니라 고정된
모터 하우징 또는 브래킷에 부착한다.

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

일반 접지형 오실로스코프의 probe ground는 회로 GND에만 연결한다. L298N OUT1/OUT2에 ground
clip을 연결하면 안 된다. 모터 차동 전압은 두 채널을 각각 OUT1/OUT2에 대고 `CH1-CH2`로 본다.

초기 bench supply 설정은 출력 OFF에서 배선하고 12.0 V, 전류 제한 0.3~0.5 A로 시작한다.
무부하 25% duty부터 확인하며 기동하지 않으면 오래 유지하지 않는다. 모터 정격·stall 전류가
확인되기 전에는 전류 제한을 임의로 크게 올리지 않는다.

