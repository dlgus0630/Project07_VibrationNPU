#!/usr/bin/env python3
import argparse
import csv
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('csv_path', type=Path)
    parser.add_argument('--settle-band', type=float, default=0.02)
    parser.add_argument('--settle-window-s', type=float, default=1.0)
    args = parser.parse_args()

    rows = []
    with args.csv_path.open() as f:
        for row in csv.DictReader(f):
            rows.append((float(row['time_s']), float(row['target_rpm']), float(row['measured_rpm'])))

    initial_target = rows[0][1]
    final_target = rows[-1][1]
    step_index = next(i for i, r in enumerate(rows) if abs(r[1] - final_target) < 1e-6 and abs(r[1] - initial_target) > 1e-6)
    step_time = rows[step_index][0]

    post = [r for r in rows if r[0] >= step_time]
    delta = final_target - post[0][2]
    low = post[0][2] + 0.1 * delta
    high = post[0][2] + 0.9 * delta

    t_low = next((r[0] for r in post if (r[2] >= low if delta > 0 else r[2] <= low)), None)
    t_high = next((r[0] for r in post if (r[2] >= high if delta > 0 else r[2] <= high)), None)
    rise_time = (t_high - t_low) if (t_low is not None and t_high is not None) else None

    peak = max((r[2] for r in post), default=None) if delta > 0 else min((r[2] for r in post), default=None)
    overshoot_pct = ((peak - final_target) / abs(delta) * 100.0) if (peak is not None and delta != 0) else None

    tail = [r for r in rows if r[0] >= rows[-1][0] - args.settle_window_s]
    steady_rpm = sum(r[2] for r in tail) / len(tail)
    steady_err_pct = (steady_rpm - final_target) / final_target * 100.0

    band = max(args.settle_band * abs(final_target), 0.25)
    settle_time = None
    for r in reversed(post):
        if abs(r[2] - final_target) > band:
            idx = post.index(r)
            settle_time = post[idx + 1][0] - step_time if idx + 1 < len(post) else None
            break
    else:
        settle_time = 0.0

    print(f'step_time_s={step_time:.3f} initial_target={initial_target:.4f} final_target={final_target:.4f}')
    print(f'rise_time_10_90_s={rise_time}')
    print(f'overshoot_pct={overshoot_pct}')
    print(f'settling_time_2pct_s={settle_time}')
    print(f'steady_state_rpm={steady_rpm:.4f}')
    print(f'steady_state_error_pct={steady_err_pct:.4f}')


if __name__ == '__main__':
    main()
