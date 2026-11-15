#!/usr/bin/env python3
"""Independent SciPy check of the default illustrative 6-DOF equations.

This does NOT execute, translate, or certify MATLAB/Simulink. The constants
below intentionally form a separate equation implementation. Source hashes
bind the report to the files present when it was produced; they do not prove
that those files implement these equations. No hardware pass marker is made.

Dependencies: numpy, scipy, matplotlib. Run from any directory:
    python3 Project07_VibrationNPU/tools/check_research_reference.py
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import tempfile

import numpy as np
import scipy
from scipy.linalg import block_diag, eigh, expm

ROOT = Path(__file__).resolve().parents[1]
FS = 1000.0
DT = 1 / FS
GRAVITY = 9.80665
MASS = 0.62
BODY = np.array([0.120, 0.065, 0.060])
MOUNTS = np.array([[-0.045, -0.025, -0.040], [-0.045, 0.025, -0.040],
                   [0.045, -0.025, -0.040], [0.045, 0.025, -0.040]])
SENSOR = np.array([0.036, 0.015, 0.030])
FORCE_POINT = np.array([0.040, 0, 0.008])


def cross_matrix(r: np.ndarray) -> np.ndarray:
    x, y, z = r
    return np.array([[0, -z, y], [z, 0, -x], [-y, x, 0]])


def plant(dt: float = DT) -> dict:
    """Assemble mount energies and exact held-input state transition."""
    lx, ly, lz = BODY
    inertia = np.diag(MASS / 12 * np.array([ly * ly + lz * lz,
                                           lx * lx + lz * lz,
                                           lx * lx + ly * ly]))
    mass = block_diag(MASS * np.eye(3), inertia)
    stiffness = np.zeros((6, 6))
    damping = np.zeros((6, 6))
    factors = [1, 0.94, 1.08, 1.02]
    angles = np.deg2rad([15, -15, -12, 12])
    for r, factor, angle in zip(MOUNTS, factors, angles):
        c, s = np.cos(angle), np.sin(angle)
        rotation = np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])
        h = np.column_stack([np.eye(3), -cross_matrix(r)])
        km = rotation @ np.diag(factor * np.array([1800, 2100, 2700])) @ rotation.T
        cm = rotation @ np.diag(factor * np.array([2.1, 2.3, 2.8])) @ rotation.T
        stiffness += h.T @ km @ h
        damping += h.T @ cm @ h
    a = np.block([[np.zeros((6, 6)), np.eye(6)],
                  [-np.linalg.solve(mass, stiffness), -np.linalg.solve(mass, damping)]])
    b = np.vstack([np.zeros((6, 6)), np.linalg.solve(mass, np.eye(6))])
    transition = expm(np.block([[a, b], [np.zeros((6, 18))]]) * dt)
    hs = np.column_stack([np.eye(3), -cross_matrix(SENSOR)])
    ca, da = hs @ a[6:], hs @ b[6:]
    cg = np.zeros((3, 12))
    cg[0, 4], cg[1, 3] = -GRAVITY, GRAVITY
    eigenvalues, modes = eigh(stiffness, mass)
    hz = np.sqrt(eigenvalues) / (2 * np.pi)
    zeta = np.diag(modes.T @ damping @ modes) / (2 * np.sqrt(eigenvalues))
    return dict(M=mass, C=damping, K=stiffness, A=a, B=b,
                Ad=transition[:12, :12], Bd=transition[:12, 12:],
                Ca=ca, Da=da, Cg=cg, modes=modes, hz=hz, zeta=zeta)


def excitation(scenario: str, duration: float = 8.0) -> dict:
    t = np.arange(round(duration / DT) + 1) * DT
    ramp = np.clip(t, 0, 1)
    ramp = 3 * ramp**2 - 2 * ramp**3
    rpm = 1400 + 400 * ramp + 8 * np.sin(2 * np.pi * 0.7 * t)
    omega = rpm * 2 * np.pi / 60
    angle = np.r_[0, np.cumsum((omega[:-1] + omega[1:]) * DT / 2)]
    omega_dot = np.gradient(omega, DT)
    unbalance = 7e-6 if scenario == "unbalance" else 0.5e-6
    force = np.column_stack([
        0.025 * np.sin(angle + 0.3),
        unbalance * (omega**2 * np.cos(angle) + omega_dot * np.sin(angle)),
        unbalance * (omega**2 * np.sin(angle) - omega_dot * np.cos(angle)),
    ])
    torque = np.zeros((t.size, 3))
    torque[:, 0] = 0.0003 * np.sin(2 * angle)
    if scenario == "misalignment":
        force += np.column_stack([0.24 * np.sin(2 * angle + 0.4),
                                  0.10 * np.cos(2 * angle), 0.10 * np.sin(2 * angle)])
        torque[:, 1] = 0.0015 * np.sin(2 * angle + 0.2)
    elif scenario == "ripple":
        phi = 2 * np.pi * 32 * t
        wave = np.sin(phi) + np.sin(3 * phi) / 3 + np.sin(5 * phi) / 5
        force[:, 0] += 0.30 * wave
        torque[:, 0] += 0.0035 * wave
    elif scenario not in ("normal", "unbalance"):
        raise ValueError(scenario)
    wrench = np.column_stack([force, torque + np.cross(FORCE_POINT, force)])
    return dict(t=t, rpm=rpm, angle=angle, wrench=wrench, scenario=scenario)


def simulate(p: dict, data: dict, initial: np.ndarray | None = None) -> dict:
    states = np.zeros((data["t"].size, 12))
    if initial is not None:
        states[0] = initial
    for i in range(states.shape[0] - 1):
        states[i + 1] = p["Ad"] @ states[i] + p["Bd"] @ data["wrench"][i]
    acceleration = states @ p["Ca"].T + data["wrench"] @ p["Da"].T
    specific_force = acceleration + states @ p["Cg"].T + [0, 0, GRAVITY]
    q, v = states[:, :6], states[:, 6:]
    energy = 0.5 * np.sum((q @ p["K"]) * q + (v @ p["M"]) * v, axis=1)
    return dict(**data, state=states, accel=acceleration, specific_force=specific_force, energy=energy)


def welch(x: np.ndarray, length: int = 1024) -> tuple[np.ndarray, np.ndarray]:
    """Explicit periodic-Hann, one-sided PSD in (m/s^2)^2/Hz."""
    x = np.asarray(x)
    if x.ndim == 1:
        x = x[:, None]
    length = min(length, x.shape[0])
    window = 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(length) / length)
    segments = []
    for first in range(0, x.shape[0] - length + 1, length // 2):
        segment = x[first:first + length] - x[first:first + length].mean(axis=0)
        power = abs(np.fft.rfft(segment * window[:, None], axis=0))**2 / (FS * sum(window**2))
        power[1:-1] *= 2
        segments.append(power)
    return np.fft.rfftfreq(length, 1 / FS), np.mean(segments, axis=0)


def verify(p: dict) -> tuple[dict, dict]:
    checks = []

    def check(name, value, bound, relation="le"):
        value, bound = float(value), float(bound)
        success = bool(np.isfinite(value) and (value <= bound if relation == "le" else value > bound))
        checks.append(dict(name=name, value=value, relation=relation, bound=bound, passed=success))
        if not success:
            raise AssertionError(f"{name}: {value} failed {relation} {bound}")

    for name in ["M", "C", "K"]:
        check(name + " symmetry", np.linalg.norm(p[name] - p[name].T), 1e-10)
        check(name + " positive definiteness", np.linalg.eigvalsh(p[name]).min(), 0, "gt")
    poles = np.linalg.eigvals(p["A"])
    check("Continuous asymptotic stability", poles.real.max(), -1e-8)
    radius = abs(np.linalg.eigvals(p["Ad"])).max()
    check("Discrete asymptotic stability", radius, 1 - 1e-8)
    check("Mass-normalized modes", np.linalg.norm(p["modes"].T @ p["M"] @ p["modes"] - np.eye(6)), 1e-10)
    ph = plant(DT / 2)
    check("ZOH state semigroup", np.linalg.norm(p["Ad"] - ph["Ad"] @ ph["Ad"]) / np.linalg.norm(p["Ad"]), 1e-10)
    check("ZOH input semigroup", np.linalg.norm(p["Bd"] - ph["Ad"] @ ph["Bd"] - ph["Bd"]) / np.linalg.norm(p["Bd"]), 1e-10)
    load = np.array([0.10, -0.08, 0.12, 0.001, -0.002, 0.001])
    equilibrium = np.r_[np.linalg.solve(p["K"], load), np.zeros(6)]
    check("Static equilibrium state", np.linalg.norm(p["Ad"] @ equilibrium + p["Bd"] @ load - equilibrium), 1e-11)
    check("Static equilibrium acceleration", np.linalg.norm(p["Ca"] @ equilibrium + p["Da"] @ load), 1e-9)
    alpha = np.array([1, 2, -3])
    check("Sensor lever arm", np.linalg.norm(p["Da"] @ p["M"] @ np.r_[np.zeros(3), alpha] - np.cross(alpha, SENSOR)), 1e-12)
    tilt = np.zeros(12)
    tilt[3:5] = [0.01, -0.02]
    check("Linear gravity projection", np.linalg.norm(p["Cg"] @ tilt - GRAVITY * np.array([0.02, 0.01, 0])), 1e-12)
    zero = excitation("normal", 0.2)
    zero["wrench"][:] = 0
    rest = simulate(p, zero)
    check("Zero dynamic state", abs(rest["state"]).max(), 1e-12)
    check("Rest specific force +1g", abs(rest["specific_force"] - [0, 0, GRAVITY]).max(), 1e-12)
    initial = np.r_[[1e-4, -2e-4, 1e-4, 0.001, -0.002, 0.001], np.zeros(6)]
    free = simulate(p, zero, initial)
    check("Passive free decay", max(0.0, np.diff(free["energy"]).max()), 1e-12)
    n = np.arange(1024)
    frequency, psd = welch(np.sqrt(2) * np.sin(2 * np.pi * 64 * n / 1024))
    check("One-sided PSD Parseval", abs(psd.sum() * FS / 1024 - 1), 1e-10)
    check("Known-tone frequency", abs(frequency[np.argmax(psd)] - 62.5), 1e-10)
    omega = 2 * np.pi * 20
    augmented = np.block([[p["A"], p["B"][:, :1], np.zeros((12, 1))],
                          [np.zeros((1, 13)), np.array([[omega]])],
                          [np.zeros((1, 12)), np.array([[-omega, 0]])]])
    reference = (expm(augmented * 0.2) @ np.r_[np.zeros(13), 1])[:12]
    errors = []
    for step, discrete in [(DT, p), (DT / 2, ph)]:
        state = np.zeros(12)
        for k in range(round(0.2 / step)):
            state = discrete["Ad"] @ state + discrete["Bd"][:, 0] * np.sin(omega * k * step)
        difference = state - reference
        errors.append(float(np.sqrt(difference @ block_diag(p["K"], p["M"]) @ difference)))
    ratio = errors[1] / errors[0]
    check("Continuous forcing dt-refinement ratio", ratio, 0.75)
    scenarios = {}
    metrics = {}
    for scenario in ["normal", "unbalance", "misalignment", "ripple"]:
        result = simulate(p, excitation(scenario))
        scenarios[scenario] = result
        check(scenario + " finite states", float(not np.isfinite(result["state"]).all()), 0)
        max_angle = abs(result["state"][:, 3:6]).max()
        check(scenario + " small-angle regime", max_angle, 0.05)
        metrics[scenario] = dict(
            dynamic_acceleration_rms_m_s2=np.std(result["accel"][result["t"] >= 2], axis=0).tolist(),
            max_angle_rad=float(max_angle), max_specific_force_g=float(abs(result["specific_force"]).max() / GRAVITY))
    report = dict(status="PASS_INDEPENDENT_REFERENCE", checks=checks,
                  nominal_modal_hz=p["hz"].tolist(), projected_damping_ratio=p["zeta"].tolist(),
                  maximum_continuous_pole_real=float(poles.real.max()), discrete_spectral_radius=float(radius),
                  dt_convergence=dict(coarse_dt_s=DT, fine_dt_s=DT / 2,
                                      energy_norm_errors=errors, fine_to_coarse_error_ratio=ratio),
                  scenarios=metrics)
    return report, scenarios


def preview(p: dict, results: dict, path: Path) -> None:
    # Only cache setup is global; all preview and report artifacts stay in outdir.
    os.environ.setdefault("MPLCONFIGDIR", tempfile.mkdtemp(prefix="vib3d_mpl_"))
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from mpl_toolkits.mplot3d.art3d import Poly3DCollection

    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 10,
                         "axes.spines.top": False, "axes.spines.right": False,
                         "axes.titleweight": "bold", "axes.labelcolor": "#24394b",
                         "text.color": "#183147", "figure.facecolor": "#fbfcfe"})
    fig = plt.figure(figsize=(16, 10), facecolor="#fbfcfe")
    grid = fig.add_gridspec(2, 2, top=0.83, bottom=0.16, left=0.06, right=0.95,
                           wspace=0.23, hspace=0.60)
    fig.text(0.055, 0.95, "6-DOF vibration | 3D research preview", fontsize=25, fontweight="bold")
    fig.text(0.055, 0.913, "Independent Python reference  /  synthetic, uncalibrated parameters", fontsize=13, color="#456071")
    fig.text(0.055, 0.88, "MATLAB and Simulink were not executed.  Shaft: +X  |  sampling: 1 kHz  |  force + moment coupling at four mounts", fontsize=10.5)
    colors = {"normal": "#7c8f9d", "unbalance": "#d45b3d", "misalignment": "#795bb5", "ripple": "#168694"}
    result = results["unbalance"]
    after = np.flatnonzero(result["t"] >= 2)
    index = after[np.argmax(np.linalg.norm(result["state"][after, :3], axis=1))]
    q = result["state"][index, :6]
    gain = 80

    def move(points):
        points = np.atleast_2d(points)
        return points + gain * (q[:3] + np.cross(q[3:], points))

    ax = fig.add_subplot(grid[0, 0], projection="3d")
    ax.set_title("A  Coupled housing and sensor geometry", loc="left", pad=14)
    corners = np.array([[-1, -1, -1], [1, -1, -1], [1, 1, -1], [-1, 1, -1],
                        [-1, -1, 1], [1, -1, 1], [1, 1, 1], [-1, 1, 1]]) * BODY / 2
    faces = [[0, 1, 2, 3], [4, 5, 6, 7], [0, 1, 5, 4], [2, 3, 7, 6], [0, 3, 7, 4], [1, 2, 6, 5]]
    deformed = move(corners) * 1000
    ax.add_collection3d(Poly3DCollection([deformed[f] for f in faces], facecolors="#65a7bc", edgecolors="#23637c", alpha=0.24, linewidths=1.2))
    base = np.array([[-80, -50, -70], [90, -50, -70], [90, 50, -70], [-80, 50, -70]])
    ax.add_collection3d(Poly3DCollection([base], facecolors="#dce4ea", edgecolors="#a1b3c0", alpha=0.8))
    for mount, top in zip(MOUNTS, move(MOUNTS)):
        anchor = np.array([mount[0], mount[1], -0.07])
        phase = np.linspace(0, 1, 90)
        spring = anchor + phase[:, None] * (top - anchor)
        spring[:, 0] += 0.0025 * np.sin(phase * 12 * np.pi)
        spring[:, 1] += 0.0025 * np.cos(phase * 12 * np.pi)
        ax.plot(*(spring * 1000).T, color="#516e84", lw=1.2)
    sensor = move(SENSOR)[0] * 1000
    ax.scatter(*sensor, color="#d45b3d", s=70, marker="s", depthshade=False)
    ax.text(*(sensor + [5, 4, 12]), "XYZ sensor", color="#b5442f", fontsize=9)
    shaft = move([[0.060, 0, 0], [0.105, 0, 0]]) * 1000
    ax.plot(*shaft.T, color="#183147", lw=4)
    phi = np.linspace(0, 2 * np.pi, 120)
    circle = move(np.column_stack([np.full_like(phi, 0.087), 0.023 * np.cos(phi), 0.023 * np.sin(phi)])) * 1000
    ax.plot(*circle.T, color="#d79e3b", lw=2)
    ax.text(90, 0, 38, "shaft +X", fontsize=9)
    ax.set(xlabel="X (mm)", ylabel="Y (mm)", zlabel="Z (mm)",
           xlim=(-85, 115), ylim=(-60, 60), zlim=(-75, 65))
    ax.set_box_aspect((2, 1.2, 1.4)); ax.view_init(23, -53)
    ax.text2D(0.01, -0.30, f"Unbalance snapshot at {result['t'][index]:.3f} s.\nDisplayed deformation x{gain}.", transform=ax.transAxes, fontsize=9)

    orbit = fig.add_subplot(grid[0, 1], projection="3d")
    orbit.set_title("B  Physical CG orbit: unbalance case", loc="left", pad=14)
    tail = result["t"] >= 7.6
    positions = result["state"][tail, :3] * 1e6
    orbit.plot(*positions.T, color=colors["unbalance"], lw=1.1)
    orbit.scatter(*positions[0], color="#183147", s=22, label="7.6 s")
    orbit.set(xlabel="X (um)", ylabel="Y (um)", zlabel="Z (um)")
    ranges = np.ptp(positions, axis=0)
    orbit.set_box_aspect(np.maximum(ranges, 1)); orbit.view_init(25, -52)
    orbit.text2D(0.01, -0.30, "Motion shown at physical scale.\nUnbalance trajectory, 7.6-8.0 s.", transform=orbit.transAxes, fontsize=9)

    spectral = fig.add_subplot(grid[1, 0])
    spectral.set_title("C  X-sensor dynamic acceleration spectrum", loc="left", pad=12)
    for name, trace in results.items():
        frequencies, power = welch(trace["accel"][trace["t"] >= 2, 0])
        spectral.semilogy(frequencies, power[:, 0], color=colors[name], label=name, lw=1.5)
    spectral.set(xlim=(0, 180), ylim=(1e-12, 1), xlabel="Frequency (Hz)", ylabel="PSD ((m/s^2)^2/Hz)")
    spectral.grid(True, alpha=0.18, which="major")
    spectral.legend(ncol=2, loc="upper right", frameon=False, fontsize=9)
    spectral.text(0, -0.32, "Periodic Hann 1024 samples; 50% overlap; 2 s transient removed.\nDynamic sensor acceleration excludes gravity, bias and sampled sensor noise.", transform=spectral.transAxes, fontsize=9)

    modal = fig.add_subplot(grid[1, 1])
    modal.set_title("D  Six coupled rigid-body modes", loc="left", pad=12)
    locations = np.arange(1, 7)
    bars = modal.bar(locations, p["hz"], color="#277f99", width=0.58)
    for rect, hz, zeta in zip(bars, p["hz"], p["zeta"]):
        modal.text(rect.get_x() + rect.get_width() / 2, hz + 1.1,
                   f"{hz:.2f} Hz\nzeta~{zeta:.3f}", ha="center", va="bottom", fontsize=9)
    modal.set(xticks=locations, ylim=(0, 48), xlabel="Mode index", ylabel="Undamped natural frequency (Hz)")
    modal.grid(axis="y", alpha=0.18); modal.set_axisbelow(True)
    modal.text(0, -0.32, "Positive-definite M, C and K; stable continuous and discrete dynamics.\nzeta is projected modal damping for nonproportional damping.", transform=modal.transAxes, fontsize=9)
    fig.text(0.055, 0.022, "Reference scope: physical equation checks only. No measured fault-accuracy claim; the deployed FPGA classifier remains X-only / 64 samples.", fontsize=9, color="#546979")
    fig.savefig(path, dpi=180, facecolor=fig.get_facecolor())
    plt.close(fig)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--outdir", type=Path, default=ROOT / "reports/research_offline")
    parser.add_argument("--no-preview", action="store_true")
    args = parser.parse_args()
    args.outdir.mkdir(parents=True, exist_ok=True)
    matrices = plant()
    report, results = verify(matrices)
    sources = sorted((ROOT / "matlab/research").glob("*.m"))
    sources += [ROOT / "RUN_RESEARCH_STUDY.m", Path(__file__).resolve()]
    report.update(
        schema_version=1,
        scope="Independent numerical implementation of default illustrative physical equations only",
        matlab_executed=False, simulink_executed=False,
        limitations=[
            "No MATLAB code, generated Simulink model or HDL was executed by this checker.",
            "Constants are independently stated in Python; this is not a parser or automatic equivalence proof.",
            "Source SHA256 identifies the audited snapshot, not proof of MATLAB source correctness.",
            "Scenario traces omit sensor noise/bias/quantization and do not validate classifier accuracy.",
            "Mechanical parameters are illustrative and uncalibrated; rotor RPM is not measured gearbox RPM.",
        ],
        dependencies=dict(python=platform.python_version(), numpy=np.__version__, scipy=scipy.__version__),
        source_sha256={str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources},
    )
    if not args.no_preview:
        preview_path = args.outdir / "reference_preview_3d.png"
        preview(matrices, results, preview_path)
        report["preview"] = preview_path.name
        report["preview_sha256"] = hashlib.sha256(preview_path.read_bytes()).hexdigest()
    path = args.outdir / "reference_check.json"
    path.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    print(f"PASS: {len(report['checks'])} independent physical-equation checks")
    print("MATLAB/Simulink execution: NOT PERFORMED")
    print(f"Natural frequencies (Hz): {np.round(matrices['hz'], 6).tolist()}")
    print(f"Time-step refinement error ratio: {report['dt_convergence']['fine_to_coarse_error_ratio']:.9f}")
    print(f"Report: {path}")


if __name__ == "__main__":
    main()
