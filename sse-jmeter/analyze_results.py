import os
import re
import statistics
import pandas as pd
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import ScalarFormatter

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
RESULTS_DIR = os.path.join(SCRIPT_DIR, "results")
RUNS_HISTORY_CSV = os.path.join(SCRIPT_DIR, "runs_history.csv")
SUMMARY_CSV = os.path.join(SCRIPT_DIR, "summary_analysis.csv")
STRESS_CURVE_CSV = os.path.join(SCRIPT_DIR, "stress_curve_history.csv")
SPIKE_CURVE_CSV = os.path.join(SCRIPT_DIR, "spike_curve_history.csv")
STRESS_PLOT_PNG = os.path.join(SCRIPT_DIR, "stress_knee_point.png")
SPIKE_PLOT_PNG = os.path.join(SCRIPT_DIR, "spike_response.png")

KNOWN_TEST_TYPES = {"load", "stress", "spike", "soak"}
FILENAME_RE = re.compile(r"^(eb|jm)_([a-zA-Z0-9_-]+)_run(\d+)_(\d{8}_\d{6}(?:_\d{3})?)\.(csv|jtl)$")

METRICS_LABELS = [
    ("total_energy_j", "Energia Totale (J)"),
    ("energy_per_req_mj", "Energia / Richiesta OK (mJ)"),
    ("avg_power_w", "Potenza Media (W)"),
    ("duration_s", "Durata Run (s)"),
    ("throughput_rps", "Throughput (req/s)"),
    ("latency_mean_ms", "Latenza Media (ms)"),
    ("latency_median_ms", "Latenza Mediana (ms)"),
    ("latency_p95_ms", "Latenza p95 (ms)"),
    ("latency_p99_ms", "Latenza p99 (ms)"),
    ("avg_bytes", "Dimensione Media Risposta (B)"),
]


def _split_phase_and_test_type(raw_tag: str) -> tuple[str, str]:
    parts = raw_tag.rsplit("_", 1)
    if len(parts) == 2 and parts[1].lower() in KNOWN_TEST_TYPES:
        return parts[0], parts[1].lower()
    return raw_tag, "load"


def parse_energibridge(filepath: str, sample_interval_s: float = 0.2) -> dict:
    df = pd.read_csv(filepath)
    df.columns = [c.strip() for c in df.columns]
    if df.empty:
        raise ValueError(f"File EnergiBridge vuoto: {filepath}")

    time_col = next((c for c in df.columns if c.lower().startswith("time")), None)
    if time_col:
        numeric = pd.to_numeric(df[time_col], errors="coerce").dropna()
        span = float(numeric.max() - numeric.min()) if len(numeric) >= 2 else 0.0
        duration_s = span / 1000.0 if numeric.abs().max() >= 1e6 else span
    else:
        duration_s = len(df) * sample_interval_s

    if duration_s <= 0:
        duration_s = len(df) * sample_interval_s

    energy_cols = [c for c in df.columns if "ENERGY" in c.upper() and "(J)" in c.upper()]
    power_cols = [c for c in df.columns if "POWER" in c.upper() and "(W)" in c.upper()]

    if energy_cols:
        primary_col = next((c for c in energy_cols if "PACKAGE" in c.upper()), energy_cols[0])
        series = pd.to_numeric(df[primary_col], errors="coerce").dropna()
        diffs = series.diff().dropna()
        if (diffs < 0).any():
            raise ValueError(f"Contatore energia decrescente in '{primary_col}' ({filepath}).")
        total_j = float(diffs.sum())
        if total_j > 0:
            return {"duration_s": duration_s, "total_energy_j": total_j, "avg_power_w": total_j / duration_s}

    if not power_cols:
        raise ValueError(f"Nessuna colonna ENERGY (J) o POWER (W) trovata in {filepath}.")

    primary_col = next((c for c in power_cols if "PACKAGE" in c.upper()), power_cols[0])
    avg_w = float(pd.to_numeric(df[primary_col], errors="coerce").dropna().mean())
    return {"duration_s": duration_s, "avg_power_w": avg_w, "total_energy_j": avg_w * duration_s}


def parse_jmeter(filepath: str) -> dict:
    df = pd.read_csv(filepath)
    df.columns = [c.strip() for c in df.columns]
    if df.empty:
        raise ValueError(f"File JMeter vuoto: {filepath}")

    total_reqs = len(df)
    success_reqs = int((df["success"].astype(str).str.lower() == "true").sum())
    error_rate = ((total_reqs - success_reqs) / total_reqs * 100.0) if total_reqs > 0 else 0.0

    elapsed = pd.to_numeric(df["elapsed"], errors="coerce").dropna()
    ts = pd.to_numeric(df["timeStamp"], errors="coerce").dropna()
    total_time_s = ((ts + elapsed).max() - ts.min()) / 1000.0

    return {
        "requests": total_reqs,
        "success_reqs": success_reqs,
        "error_rate_pct": error_rate,
        "throughput_rps": (success_reqs / total_time_s) if total_time_s > 0 else 0.0,
        "latency_mean_ms": float(elapsed.mean()),
        "latency_median_ms": float(elapsed.median()),
        "latency_p95_ms": float(np.percentile(elapsed, 95)),
        "latency_p99_ms": float(np.percentile(elapsed, 99)),
        "avg_bytes": float(pd.to_numeric(df["bytes"], errors="coerce").mean()) if "bytes" in df.columns else 0.0,
    }


def _extract_time_windows(filepath: str, phase: str, window_s: int, is_stress: bool) -> pd.DataFrame:
    df = pd.read_csv(filepath)
    df.columns = [c.strip() for c in df.columns]
    if df.empty or not {"timeStamp", "elapsed", "success"}.issubset(df.columns):
        return pd.DataFrame()

    df["timeStamp"] = pd.to_numeric(df["timeStamp"], errors="coerce")
    df["elapsed"] = pd.to_numeric(df["elapsed"], errors="coerce")
    df["is_ok"] = df["success"].astype(str).str.lower() == "true"
    df = df.dropna(subset=["timeStamp", "elapsed"]).sort_values("timeStamp")
    if df.empty:
        return pd.DataFrame()

    df["window_idx"] = ((df["timeStamp"] - df["timeStamp"].min()) // (window_s * 1000)).astype(int)
    has_threads = "allThreads" in df.columns
    if has_threads:
        df["allThreads"] = pd.to_numeric(df["allThreads"], errors="coerce")

    rows = []
    max_w = df["window_idx"].max()
    for w_idx, w_df in df.groupby("window_idx"):
        if is_stress and len(w_df) < 2:
            continue
        span_s = max((w_df["timeStamp"].max() - w_df["timeStamp"].min()) / 1000.0, 0.5)
        if w_idx == max_w and span_s < (window_s * 0.75):
            continue

        ok_reqs = int(w_df["is_ok"].sum())
        active_users = float(w_df["allThreads"].median()) if has_threads and w_df["allThreads"].notna().any() else float((w_idx + 1) * 3)
        row = {
            "phase": phase,
            "elapsed_s": int(w_idx * window_s),
            "active_users": active_users,
            "throughput_rps": ok_reqs / float(window_s),
            "latency_p95_ms": float(np.percentile(w_df["elapsed"], 95)),
        }
        if is_stress:
            row["user_bin"] = max(5, int(np.ceil(active_users / 5) * 5))
        rows.append(row)

    return pd.DataFrame(rows)


def _detect_knee_point(curve_df: pd.DataFrame) -> dict | None:
    if len(curve_df) < 3:
        return None
    sub = curve_df.sort_values("user_bin").reset_index(drop=True)
    peak_idx = int(sub["throughput_rps"].idxmax())
    sub_to_peak = sub.iloc[: peak_idx + 1]
    if len(sub_to_peak) < 3:
        row = sub.iloc[peak_idx]
        return {"user_bin": row["user_bin"], "throughput_rps": row["throughput_rps"]}

    x = sub_to_peak["user_bin"].to_numpy(dtype=float)
    y = sub_to_peak["throughput_rps"].to_numpy(dtype=float)
    x_norm = (x - x[0]) / max(x[-1] - x[0], 1e-9)
    y_norm = (y - y[0]) / max(y[-1] - y[0], 1e-9)
    knee_row = sub_to_peak.iloc[int(np.argmax(np.abs(y_norm - x_norm) / np.sqrt(2.0)))]
    return {"user_bin": int(knee_row["user_bin"]), "throughput_rps": float(knee_row["throughput_rps"])}


def generate_stress_knee_plot(curve_df: pd.DataFrame, output_png: str = STRESS_PLOT_PNG):
    if curve_df.empty:
        return

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(11, 8.5), sharex=True, dpi=150)
    colors = ["#1f77b4", "#2ca02c", "#d62728", "#9467bd"]
    phases = sorted(curve_df["phase"].unique(), key=lambda p: (0 if p == "baseline" else 1, p))

    for idx, phase in enumerate(phases):
        color = colors[idx % len(colors)]
        agg = (
            curve_df[curve_df["phase"] == phase]
            .groupby("user_bin", as_index=False)
            .agg(throughput_rps=("throughput_rps", "median"), throughput_std=("throughput_rps", "std"), latency_p95_ms=("latency_p95_ms", "median"))
            .sort_values("user_bin")
        )
        agg["throughput_std"] = agg["throughput_std"].fillna(0.0)

        y_thr = np.maximum(0.5, agg["throughput_rps"])
        ax1.plot(agg["user_bin"], y_thr, marker="o", linewidth=2.2, color=color, label=f"{phase} (mediana)")
        ax1.fill_between(agg["user_bin"], np.maximum(0.5, agg["throughput_rps"] - agg["throughput_std"]), np.maximum(0.5, agg["throughput_rps"] + agg["throughput_std"]), color=color, alpha=0.14)

        knee = _detect_knee_point(agg)
        if knee:
            knee_y = max(0.5, knee["throughput_rps"])
            ax1.scatter([knee["user_bin"]], [knee_y], color=color, s=130, zorder=6, edgecolors="black", linewidths=1.5)
            ax1.axvline(knee["user_bin"], color=color, linestyle="--", alpha=0.55, linewidth=1.2)
            y_offset = -42 if knee["throughput_rps"] > (curve_df["throughput_rps"].max() * 0.25) else 22
            ax1.annotate(
                f"Knee {phase}\n({knee['user_bin']:.0f} utenti, {knee['throughput_rps']:.1f} req/s)",
                xy=(knee["user_bin"], knee_y), xytext=(14 + idx * 6, y_offset), textcoords="offset points",
                fontsize=8.5, fontweight="bold", color=color, zorder=10,
                bbox=dict(boxstyle="round,pad=0.3", fc="white", ec=color, alpha=0.95),
                arrowprops=dict(arrowstyle="->", color=color, lw=1.2),
            )

        ax2.plot(agg["user_bin"], np.maximum(1.0, agg["latency_p95_ms"]), marker="s", linewidth=2.0, color=color, label=f"{phase} p95")
        if knee:
            ax2.axvline(knee["user_bin"], color=color, linestyle="--", alpha=0.55, linewidth=1.2)

    for ax, ylabel, yticks, ylim_max in [
        (ax1, "Throughput (req/s - log)", [1, 2, 5, 10, 25, 50, 100, 150, 250], max(200, curve_df["throughput_rps"].max() * 1.5)),
        (ax2, "Latenza p95 (ms - log)", [10, 25, 50, 100, 250, 500, 1000, 5000, 15000], max(20000, curve_df["latency_p95_ms"].max() * 1.5)),
    ]:
        ax.set_yscale("log")
        ax.set_ylim(0.5 if ax == ax1 else 5, ylim_max)
        ax.set_yticks(yticks)
        ax.yaxis.set_major_formatter(ScalarFormatter())
        ax.set_ylabel(ylabel, fontsize=10.5, fontweight="bold")
        ax.grid(True, which="both", linestyle=":", alpha=0.55)
        ax.legend(loc="center right", frameon=True)

    ax1.set_title("Stress Test: Curva di Saturazione e Punto di Ginocchio (Knee Point)", fontsize=12.5, fontweight="bold", pad=12)
    ax2.set_xlabel("Utenti Concorrenti (allThreads)", fontsize=10.5, fontweight="bold")
    plt.tight_layout()
    fig.savefig(output_png)
    plt.close(fig)
    print(f"Grafico Stress Test salvato: {output_png}")


def generate_spike_plot(spike_df: pd.DataFrame, output_png: str = SPIKE_PLOT_PNG):
    if spike_df.empty:
        return

    fig, (ax1, ax2, ax3) = plt.subplots(3, 1, figsize=(11, 10), sharex=True, dpi=150, gridspec_kw={"height_ratios": [2.2, 2.2, 1.1]})
    colors = ["#1f77b4", "#2ca02c", "#d62728", "#9467bd"]
    phases = sorted(spike_df["phase"].unique(), key=lambda p: (0 if p == "baseline" else 1, p))

    for idx, phase in enumerate(phases):
        color = colors[idx % len(colors)]
        agg = (
            spike_df[spike_df["phase"] == phase]
            .groupby("elapsed_s", as_index=False)
            .agg(throughput_rps=("throughput_rps", "median"), throughput_std=("throughput_rps", "std"), latency_p95_ms=("latency_p95_ms", "median"), active_users=("active_users", "median"))
            .sort_values("elapsed_s")
        )
        agg["throughput_std"] = agg["throughput_std"].fillna(0.0)

        ax1.plot(agg["elapsed_s"], agg["throughput_rps"], marker="o", markersize=4, linewidth=2.2, color=color, label=f"{phase} (mediana)")
        ax1.fill_between(agg["elapsed_s"], np.maximum(0.0, agg["throughput_rps"] - agg["throughput_std"]), agg["throughput_rps"] + agg["throughput_std"], color=color, alpha=0.14)

        peak = agg.iloc[int(agg["throughput_rps"].idxmax())]
        ax1.scatter([peak["elapsed_s"]], [peak["throughput_rps"]], color=color, s=110, zorder=6, edgecolors="black", linewidths=1.3)
        ax1.annotate(
            f"Picco {phase}: {peak['throughput_rps']:.1f} req/s @ {int(peak['elapsed_s'])}s",
            xy=(peak["elapsed_s"], peak["throughput_rps"]), xytext=(12, -16 - idx * 22), textcoords="offset points",
            fontsize=8.5, fontweight="bold", color=color, bbox=dict(boxstyle="round,pad=0.25", fc="white", ec=color, alpha=0.92),
            arrowprops=dict(arrowstyle="->", color=color, lw=1.1),
        )

        y_lat = np.maximum(1.0, agg["latency_p95_ms"])
        ax2.plot(agg["elapsed_s"], y_lat, marker="s", markersize=4, linewidth=2.0, color=color, label=f"{phase} p95")
        lat_peak = agg.iloc[int(agg["latency_p95_ms"].idxmax())]
        ax2.scatter([lat_peak["elapsed_s"]], [max(1.0, lat_peak["latency_p95_ms"])], color=color, s=100, zorder=6, edgecolors="black", linewidths=1.3)
        ax2.annotate(
            f"Max p95 {phase}: {lat_peak['latency_p95_ms']:.0f} ms @ {int(lat_peak['elapsed_s'])}s",
            xy=(lat_peak["elapsed_s"], max(1.0, lat_peak["latency_p95_ms"])), xytext=(12, -16 - idx * 22), textcoords="offset points",
            fontsize=8.5, fontweight="bold", color=color, bbox=dict(boxstyle="round,pad=0.25", fc="white", ec=color, alpha=0.92),
            arrowprops=dict(arrowstyle="->", color=color, lw=1.1),
        )

        if agg["active_users"].notna().any():
            ax3.step(agg["elapsed_s"], agg["active_users"], where="post", linewidth=2.0, color=color, label=f"{phase} utenti")

    ax1.set_title("Spike Test: Risposta al Picco Improvviso e Tempo di Recupero", fontsize=12.5, fontweight="bold", pad=12)
    ax1.set_ylabel("Throughput (req/s)", fontsize=10.5, fontweight="bold")
    ax2.set_yscale("log")
    ax2.set_ylim(5, max(5000, spike_df["latency_p95_ms"].max() * 1.6))
    ax2.set_yticks([10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 15000])
    ax2.yaxis.set_major_formatter(ScalarFormatter())
    ax2.set_ylabel("Latenza p95 (ms - log)", fontsize=10.5, fontweight="bold")
    ax3.set_xlabel("Tempo Trascorso (s)", fontsize=10.5, fontweight="bold")
    ax3.set_ylabel("Utenti Attivi", fontsize=10.5, fontweight="bold")

    for ax in (ax1, ax2, ax3):
        ax.grid(True, which="both", linestyle=":", alpha=0.55)
        ax.legend(loc="upper right", frameon=True)

    plt.tight_layout()
    fig.savefig(output_png)
    plt.close(fig)
    print(f"Grafico Spike Test salvato: {output_png}")


def _merge_history(existing_df: pd.DataFrame, new_df: pd.DataFrame, key_cols: list[str]) -> pd.DataFrame:
    if new_df.empty:
        return existing_df
    if existing_df.empty:
        return new_df
    updated_keys = set(new_df[key_cols].itertuples(index=False, name=None))
    mask = existing_df[key_cols].apply(tuple, axis=1).isin(updated_keys)
    return pd.concat([existing_df[~mask], new_df], ignore_index=True)


def run_analysis():
    existing_df = pd.read_csv(RUNS_HISTORY_CSV) if os.path.isfile(RUNS_HISTORY_CSV) else pd.DataFrame()
    existing_stress_df = pd.read_csv(STRESS_CURVE_CSV) if os.path.isfile(STRESS_CURVE_CSV) else pd.DataFrame()
    existing_spike_df = pd.read_csv(SPIKE_CURVE_CSV) if os.path.isfile(SPIKE_CURVE_CSV) else pd.DataFrame()

    grouped = {}
    if os.path.isdir(RESULTS_DIR):
        for fname in sorted(os.listdir(RESULTS_DIR)):
            match = FILENAME_RE.match(fname)
            if not match:
                continue
            kind, raw_tag, run_num, ts, _ = match.groups()
            phase, test_type = _split_phase_and_test_type(raw_tag)
            key = (phase, test_type, int(run_num))
            grouped.setdefault(key, {})[kind] = os.path.join(RESULTS_DIR, fname)
            grouped[key]["timestamp"] = ts

    rows, stress_parts, spike_parts = [], [], []
    for (phase, test_type, run_num), files in sorted(grouped.items()):
        row = {"phase": phase, "test_type": test_type, "run": run_num, "timestamp": files.get("timestamp", "")}
        if "eb" in files:
            row.update(parse_energibridge(files["eb"]))
        if "jm" in files:
            row.update(parse_jmeter(files["jm"]))
            if test_type == "stress":
                stress_parts.append(_extract_time_windows(files["jm"], phase, window_s=3, is_stress=True))
            elif test_type == "spike":
                spike_parts.append(_extract_time_windows(files["jm"], phase, window_s=2, is_stress=False))

        if "total_energy_j" in row and row.get("success_reqs", 0) > 0:
            row["energy_per_req_mj"] = (row["total_energy_j"] / row["success_reqs"]) * 1000.0
        rows.append(row)

    df = _merge_history(existing_df, pd.DataFrame(rows), ["phase", "test_type"])
    stress_df = _merge_history(existing_stress_df, pd.concat(stress_parts, ignore_index=True) if stress_parts else pd.DataFrame(), ["phase"])
    spike_df = _merge_history(existing_spike_df, pd.concat(spike_parts, ignore_index=True) if spike_parts else pd.DataFrame(), ["phase"])

    if df.empty:
        print("Nessun dato da analizzare.")
        return

    df = df.sort_values(
        by=["phase", "test_type", "run"],
        key=lambda col: col.map(lambda p: (0 if p == "baseline" else 1, p)) if col.name == "phase" else col,
    ).reset_index(drop=True)

    if "error_rate_pct" in df.columns and (df["error_rate_pct"] > 0).any():
        print("\n[!] ATTENZIONE: Alcune run presentano error_rate_pct > 0%.")

    # Calcolo mediane ordinate per (phase, test_type) con baseline sempre per prima
    agg_rows = []
    medians_map = {}
    sorted_groups = sorted(
        df.groupby(["phase", "test_type"]),
        key=lambda item: (0 if item[0][0] == "baseline" else 1, item[0][0], item[0][1]),
    )

    for (phase, test_type), p_group in sorted_groups:
        medians_map.setdefault(test_type, {})[phase] = {
            col: float(statistics.median(p_group[col].dropna()))
            for col, _ in METRICS_LABELS if col in p_group.columns and not p_group[col].dropna().empty
        }
        row_summary = {"phase": phase, "test_type": test_type, "runs": len(p_group)}
        row_summary.update({f"{k}_median": round(v, 4) for k, v in medians_map[test_type][phase].items()})
        agg_rows.append(row_summary)

    # Stampa a schermo SOLO il confronto Baseline vs altre fasi
    for test_type in sorted(medians_map.keys()):
        phases_dict = medians_map[test_type]
        if "baseline" in phases_dict:
            b_meds = phases_dict["baseline"]
            for target_phase in [p for p in phases_dict if p != "baseline"]:
                print("\n" + "=" * 76)
                print(f"CONFRONTO [{test_type.upper()}] BASELINE vs {target_phase.upper()} (Mediane)")
                print("=" * 76)
                t_meds = phases_dict[target_phase]
                for col, label in METRICS_LABELS:
                    if col in b_meds and col in t_meds and b_meds[col] != 0:
                        delta = ((t_meds[col] - b_meds[col]) / b_meds[col]) * 100.0
                        print(f"  {label:<32}: {b_meds[col]:10.2f} -> {t_meds[col]:10.2f}  ({delta:+.2f}%)")

    # Salvataggio storico, summary e grafici
    print("\n" + "-" * 76)
    df.to_csv(RUNS_HISTORY_CSV, index=False)
    pd.DataFrame(agg_rows).to_csv(SUMMARY_CSV, index=False)
    print(f"Storico salvato: {RUNS_HISTORY_CSV}")
    print(f"Summary salvato: {SUMMARY_CSV}")

    if not stress_df.empty:
        stress_df.to_csv(STRESS_CURVE_CSV, index=False)
        generate_stress_knee_plot(stress_df, STRESS_PLOT_PNG)
    if not spike_df.empty:
        spike_df.to_csv(SPIKE_CURVE_CSV, index=False)
        generate_spike_plot(spike_df, SPIKE_PLOT_PNG)
    print("-" * 76 + "\n")


if __name__ == "__main__":
    run_analysis()