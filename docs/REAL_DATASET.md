# MPU-6500/9250 실측 데이터 수집 및 재학습

## 목적과 판정 조건

합성 데이터 결과는 실제 이상 진동 분류 성능으로 사용하지 않는다. 정상과 이상을 각각 독립된
acquisition run으로 반복 측정하고, run 전체를 train 또는 validation 중 한쪽에만 배치한다.
같은 run의 인접 window를 양쪽에 나누면 실제보다 높은 정확도가 나오므로 금지한다.

최소 수집량은 조건별 3 run, run별 60 window다. 포트폴리오 최종 평가는 조건별 6 run 이상을
권장한다. 정상/이상 run의 측정 순서를 번갈아 장시간 온도 변화가 한 class에만 섞이지 않게 한다.
모든 run에서 센서 위치와 전원 전압을 같게 유지한다. 현재 통제 실험은 정상 50% 고정 duty와
평균 duty가 같은 25%/75% 32 Hz 토크 리플을 비교한다. 이는 PL 기반 fault injection이며 자연 발생
베어링 고장 데이터로 표현하지 않는다.

## 수집 준비

1. [HARDWARE.md](HARDWARE.md)에 따라 MPU-6500/9250을 Zybo에 연결하고 모터 하우징 또는 고정 브래킷에
   단단히 부착한다.
2. 현재 공식 bitstream과 ARM ELF를 올리고 UART 115200 baud를 연다.
3. 정상 조건으로 모터를 운전해 속도가 안정된 뒤 수집을 시작한다.
4. `i` 명령 결과에서 현재 실물 MPU-6500은 `WHO_AM_I,0x70`, MPU-9250은 `WHO_AM_I,0x71`이고
   `SENSOR_READY,1`인지 확인한다. 수집 도구도 ID와 모델을 함께 확인하며, 다르면 저장하지 않는다.

## 독립 run 수집

포트 이름은 PC에서 확인한 실제 UART 장치로 바꾼다. 아래 한 명령이 64 sample window 60개를
수집한다. run 사이에는 모터를 완전히 정지했다가 같은 절차로 다시 기동한다.

```bash
python3 tools/capture_dataset.py capture --port /dev/ttyUSB1 \
  --condition normal --run-id normal_01 --windows 60 \
  --motor-duty-pct 50 --supply-v 12 \
  --note "constant 50% duty, fixed sensor mount" \
  --output measurements/normal_01.csv
```

정상 run을 반복한 뒤 SW0을 OFF로 내리고 SW3 fault injection을 켠 뒤 SW0을 다시 ON한다.
센서, 배선과 전원은 바꾸지 않는다.

```bash
python3 tools/capture_dataset.py capture --port /dev/ttyUSB1 \
  --condition abnormal --run-id abnormal_01 --windows 60 \
  --motor-duty-pct 50 --supply-v 12 \
  --note "25-75% duty at 32 Hz, mean duty 50%, PL fault injection" \
  --output measurements/abnormal_01.csv
```

각 CSV 옆 JSON에는 조건, 실험 설정, bitstream/ELF SHA-256이 저장된다. 데이터셋 생성 시 CSV와
JSON을 함께 검사한다. 폐루프 시험에서는 `--motor-duty-pct` 대신 `--motor-target-rpm`을 사용한다.
기존 파일을 실수로 덮어쓰지 않으며, 의도적인 재측정에서만 `--force`를
사용한다.

## 데이터셋 생성과 재학습

각 class의 마지막 1/3 run을 validation으로 쓰려면 다음처럼 생성한다.

```bash
python3 tools/capture_dataset.py build measurements/*.csv \
  --output measurements/real_dataset_v1
python3 tools/train_export.py --real-data measurements/real_dataset_v1
```

validation run을 직접 지정하려면 class마다 하나 이상 지정한다.

```bash
python3 tools/capture_dataset.py build measurements/*.csv \
  --validation-run normal_03 --validation-run abnormal_03 \
  --output measurements/real_dataset_v1
```

`dataset.json`에는 train/validation run ID와 각 원본 CSV의 SHA-256이 기록된다. 재학습은
`data/model.json`, weight memory, firmware header를 변경하므로 이후 MATLAB/Simulink, XSim,
Vivado implementation, Zybo replay, 실제 validation run 평가를 모두 다시 수행한다.

최종 보고에는 run별 confusion matrix, 전체 accuracy, normal을 abnormal로 판단한 비율, abnormal을
normal로 놓친 비율, PL latency와 자원 사용량을 함께 기록한다.

## 2026-09-14 최소 실측 데이터셋 결과

- 센서: MPU-6500, X축 ±2 g, 약 1 kHz, window당 64 sample
- 정상: 12.0 V, 50% 고정 duty, 독립 3 run × 60 window
- class 1: 12.0 V, 25%/75% duty를 32 Hz로 교대, 독립 3 run × 60 window
- 학습: `normal_50_01/02`, `fault_ripple_01/02`, 총 240 window
- 검증: `normal_50_03`, `fault_ripple_03`, 총 120 window
- FP32 정확도: 119/120 = 99.17%
- INT8 정확도: 118/120 = 98.33%
- INT8 혼동행렬: `[[58, 2], [0, 60]]`
- false positive: 2/60, false negative: 0/60

10-window 사전 파일럿에서 detrended raw RMS 평균은 정상 45.7 count, 주입 상태 90.6 count였다.
RTL과 동일한 네 band feature 중 1번과 3번 band의 평균 차이는 각각 pooled standard deviation의
3.97배와 4.03배였다. 정식 원본과 JSON sidecar는 `measurements/final_50pct/`, 실행 단위 분리 결과는
`measurements/dataset_50pct/`, 원본 해시와 split 근거는 `data/dataset_source.json`에 있다.

수집 순서는 정상 3 run 뒤 class 1을 3 run 측정했으므로 장시간 온도 추세가 class와 완전히 분리되지
않았을 가능성이 있다. 현재 결과는 통제된 장치 내 토크 리플 검출 성능이며, 자연 고장 일반화 또는
다른 모터로의 일반화 성능으로 확대 해석하지 않는다. 포트폴리오를 더 강화할 때는 조건을 번갈아
측정한 추가 run과 다른 날의 재검증 세트를 사용한다.
