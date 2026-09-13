# MPU-6500/9250 실측 데이터 수집 및 재학습

## 목적과 판정 조건

합성 데이터 결과는 실제 이상 진동 분류 성능으로 사용하지 않는다. 정상과 이상을 각각 독립된
acquisition run으로 반복 측정하고, run 전체를 train 또는 validation 중 한쪽에만 배치한다.
같은 run의 인접 window를 양쪽에 나누면 실제보다 높은 정확도가 나오므로 금지한다.

최소 수집량은 조건별 3 run, run별 60 window다. 포트폴리오 최종 평가는 조건별 6 run 이상을
권장한다. 정상/이상 run의 측정 순서를 번갈아 장시간 온도 변화가 한 class에만 섞이지 않게 한다.
모든 run에서 센서 위치, 모터 목표 속도, 전원 전압을 같게 유지한다. 이상 조건은 한 가지 재현 가능한
물리 조건으로 고정하고 `--note`에 기록한다.

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
  --motor-target-rpm 40 --supply-v 12 \
  --note "baseline, fixed sensor mount" \
  --output measurements/normal_01.csv
```

정상 run을 반복한 뒤, 전원을 끄고 미리 정한 재현 가능한 이상 조건을 설치한다. 회전 중 손으로
누르거나 배선을 바꾸지 않는다. 같은 속도와 전압에서 이상 run을 수집한다.

```bash
python3 tools/capture_dataset.py capture --port /dev/ttyUSB1 \
  --condition abnormal --run-id abnormal_01 --windows 60 \
  --motor-target-rpm 40 --supply-v 12 \
  --note "same fixed abnormal condition" \
  --output measurements/abnormal_01.csv
```

각 CSV 옆 JSON에는 조건, 실험 설정, bitstream/ELF SHA-256이 저장된다. 데이터셋 생성 시 CSV와
JSON을 함께 검사한다. 기존 파일을 실수로 덮어쓰지 않으며, 의도적인 재측정에서만 `--force`를
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
