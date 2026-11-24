import os
import re
import statistics
import pandas as pd
import numpy as np

RESULTS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")

# Pattern nome file: eb_<phase>_run<N>_<timestamp>.csv e jm_<phase>_run<N>_<timestamp>.jtl
FILENAME_RE = re.compile(r"^(eb|jm)_([a-zA-Z0-9_-]+)_run(\d+)_(\d{8}_\d{6}(?:_\d{3})?)\.(csv|jtl)$")


def _energybridge_duration(df: pd.DataFrame, time_col: str, sample_interval_s: float) -> float:
    values = df[time_col]
    normalized_name = time_col.strip().lower()

    if "delta" in normalized_name:
        deltas = pd.to_numeric(values, errors="coerce").dropna()
        if deltas.empty:
            raise ValueError(f"Colonna delta senza valori numerici in {time_col}.")
        return float(deltas.sum()) / 1000.0

    numeric = pd.to_numeric(values, errors="coerce").dropna()
    if len(numeric) >= 2:
        span = float(numeric.max() - numeric.min())
        if re.search(r"\b(ns|nanoseconds?)\b", normalized_name):
            return span / 1_000_000_000.0
        if re.search(r"\b(us|µs|microseconds?)\b", normalized_name):
            return span / 1_000_000.0
        if re.search(r"\b(ms|milliseconds?)\b", normalized_name) or numeric.abs().max() >= 1e11:
            return span / 1000.0

        # Inferenza basata sul passo mediano di campionamento (es. 200 ms -> step ~ 200)
        step = float(np.median(np.diff(numeric)))
        if step >= 10_000:
            return span / 1_000_000.0
        if step >= 10:
            return span / 1000.0
        return span

    timestamps = pd.to_datetime(values, errors="coerce", utc=True).dropna()
    if len(timestamps) >= 2:
        return float((timestamps.max() - timestamps.min()).total_seconds())
    return len(df) * sample_interval_s


def parse_energibridge(filepath: str, sample_interval_s: float = 0.2) -> dict:
    df = pd.read_csv(filepath)
    df.columns = [c.strip() for c in df.columns]
    if df.empty:
        raise ValueError(f"File EnergiBridge vuoto: {filepath}")

    time_col = next(
        (c for c in df.columns if re.match(r"^(?:time|timestamp|delta)(?:$|[\s_(\[])", c.strip(), re.IGNORECASE)),
        None,
    )
    duration_s = _energybridge_duration(df, time_col, sample_interval_s) if time_col else len(df) * sample_interval_s
    if duration_s <= 0:
        raise ValueError(f"Durata EnergiBridge nulla o negativa in {filepath}: {duration_s}.")

    energy_cols = [
        c for c in df.columns
        if "ENERGY" in c.upper() and re.search(r"(?:\(\s*J\s*\)|\[\s*J\s*\]|_J\b|\bjoules?\b)", c, re.IGNORECASE)
    ]
    power_cols = [
        c for c in df.columns
        if "POWER" in c.upper() and re.search(r"(?:\(\s*W\s*\)|\[\s*W\s*\]|_W\b|\bwatts?\b)", c, re.IGNORECASE)
    ]

    metrics = {"duration_s": duration_s}
    energy_found = False

    if energy_cols:
        # Priorità a PACKAGE_ENERGY o CPU_ENERGY come energia primaria
        primary_col = next(
            (c for c in energy_cols if "PACKAGE" in c.upper()),
            next((c for c in energy_cols if "CPU" in c.upper()), energy_cols[0]),
        )
        for col in energy_cols:
            series = pd.to_numeric(df[col], errors="coerce").dropna()
            if len(series) >= 2:
                diffs = series.diff().dropna()
                if (diffs < 0).any():
                    raise ValueError(
                        f"Contatore energia decrescente in '{col}' ({filepath}); "
                        "run non valida: verificare reset o rollover."
                    )
                total_j = float(diffs.sum())
                if total_j > 0:
                    metrics[col] = total_j
                    if col == primary_col:
                        metrics["total_energy_j"] = total_j
                        metrics["avg_power_w"] = total_j / duration_s
                        energy_found = True

    if not energy_found:
        if not power_cols:
            raise ValueError(
                f"Nessuna colonna ENERGY (>0 J) o POWER (W) trovata in {filepath}. Colonne: {list(df.columns)}"
            )
        primary_col = next(
            (c for c in power_cols if "PACKAGE" in c.upper()),
            next((c for c in power_cols if "CPU" in c.upper()), power_cols[0]),
        )
        power_values = pd.to_numeric(df[primary_col], errors="coerce").dropna()
        if power_values.empty:
            raise ValueError(f"Nessun campione di potenza valido per '{primary_col}' in {filepath}.")
        avg_w = float(power_values.mean())
        metrics["avg_power_w"] = avg_w
        metrics["total_energy_j"] = avg_w * duration_s

    return metrics


def parse_jmeter(filepath: str) -> dict:
    df = pd.read_csv(filepath)
    df.columns = [c.strip() for c in df.columns]
    if df.empty:
        raise ValueError(f"File JMeter vuoto: {filepath}")

    required_cols = {"success", "elapsed", "timeStamp"}
    missing_cols = required_cols.difference(df.columns)
    if missing_cols:
        raise ValueError(f"Colonne JTL mancanti in {filepath}: {', '.join(sorted(missing_cols))}")

    total_reqs = len(df)
    success_col = df["success"].astype(str).str.lower() == "true"
    success_reqs = int(success_col.sum())
    error_rate = ((total_reqs - success_reqs) / total_reqs * 100.0) if total_reqs > 0 else 0.0

    elapsed = pd.to_numeric(df["elapsed"], errors="coerce").dropna()
    if elapsed.empty:
        raise ValueError(f"Nessun valore elapsed valido nel JTL: {filepath}")

    timestamp = pd.to_numeric(df["timeStamp"], errors="coerce")
    valid_timing = pd.DataFrame({
        "timestamp": timestamp,
        "elapsed": pd.to_numeric(df["elapsed"], errors="coerce")
    }).dropna()
    if valid_timing.empty:
        raise ValueError(f"Nessun timestamp/elapsed valido nel JTL: {filepath}")

    total_time_s = (
                           (valid_timing["timestamp"] + valid_timing["elapsed"]).max() - valid_timing["timestamp"].min()
                   ) / 1000.0

    throughput = success_reqs / total_time_s if total_time_s > 0 else 0.0
    avg_bytes = pd.to_numeric(df["bytes"], errors="coerce").mean() if "bytes" in df.columns else 0.0

    return {
        "requests": total_reqs,
        "success_reqs": success_reqs,
        "error_rate_pct": error_rate,
        "jm_duration_s": total_time_s,
        "throughput_rps": throughput,
        "latency_mean_ms": float(elapsed.mean()),
        "latency_median_ms": float(elapsed.median()),
        "latency_p95_ms": float(np.percentile(elapsed, 95)),
        "latency_p99_ms": float(np.percentile(elapsed, 99)),
        "avg_bytes": float(avg_bytes),
    }


def collect_runs(results_dir: str) -> pd.DataFrame:
    if not os.path.isdir(results_dir):
        raise FileNotFoundError(f"Cartella risultati non trovata: {results_dir}")

    grouped = {}
    for fname in sorted(os.listdir(results_dir)):
        match = FILENAME_RE.match(fname)
        if not match:
            continue
        kind, phase, run_num, ts, _ = match.groups()
        key = (phase, int(run_num))
        if kind in grouped.get(key, {}):
            raise ValueError(
                f"File duplicato per fase='{phase}', run={run_num}: '{fname}'. "
                "Sposta o elimina i risultati delle campagne precedenti prima di rieseguire."
            )
        grouped.setdefault(key, {})[kind] = os.path.join(results_dir, fname)
        grouped[key].setdefault("timestamp", ts)

    rows = []
    for (phase, run_num), files in sorted(grouped.items()):
        if "eb" not in files or "jm" not in files:
            missing = "EnergiBridge" if "eb" not in files else "JMeter"
            print(f"ATTENZIONE: run {phase}/run{run_num} senza file {missing}; metriche parziali.")
        row = {"phase": phase, "run": run_num, "timestamp": files.get("timestamp", "")}
        if "eb" in files:
            row.update(parse_energibridge(files["eb"]))
        if "jm" in files:
            row.update(parse_jmeter(files["jm"]))

        if "total_energy_j" in row:
            useful_reqs = row.get("success_reqs", 0)
            if useful_reqs > 0:
                row["energy_per_req_j"] = row["total_energy_j"] / useful_reqs
                row["energy_per_req_mj"] = row["energy_per_req_j"] * 1000.0
            else:
                row["energy_per_req_j"] = np.nan
                row["energy_per_req_mj"] = np.nan

        rows.append(row)

    return pd.DataFrame(rows)


def print_summary(df: pd.DataFrame, results_dir: str = RESULTS_DIR):
    if df.empty:
        print("Nessun file eb_*.csv o jm_*.jtl trovato nella cartella results.")
        return

    print("\n" + "=" * 80)
    print("DETTAGLIO SINGOLE RUN")
    print("=" * 80)
    cols_to_show = [
        c for c in [
            "phase", "run", "requests", "error_rate_pct",
            "total_energy_j", "energy_per_req_mj", "avg_power_w",
            "throughput_rps", "latency_mean_ms", "latency_p95_ms"
        ] if c in df.columns
    ]
    print(df[cols_to_show].to_string(index=False, float_format=lambda x: f"{x:.2f}"))

    if "error_rate_pct" in df.columns and (df["error_rate_pct"] > 0).any():
        print("\n[!] ATTENZIONE: Alcune run presentano error_rate_pct > 0%. Verifica i log prima di confrontare.")

    print("\n" + "=" * 80)
    print("RIEPILOGO STATISTICO PER FASE (Media ± Dev.Std | Mediana)")
    print("=" * 80)

    metrics_labels = [
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

    summary_by_phase = {}
    for phase, group in df.groupby("phase"):
        print(f"\n>>> FASE: {phase.upper()} (n = {len(group)} run)")
        summary_by_phase[phase] = {}
        for col, label in metrics_labels:
            if col not in group.columns:
                continue
            vals = group[col].dropna().tolist()
            if not vals:
                continue
            mean_v = statistics.mean(vals)
            med_v = statistics.median(vals)
            std_v = statistics.stdev(vals) if len(vals) > 1 else 0.0
            summary_by_phase[phase][col] = (mean_v, med_v, std_v)
            print(f"  {label:<32}: {mean_v:10.2f} ± {std_v:7.2f}  |  Mediana: {med_v:10.2f}")

    # Confronto automatico Baseline vs Optimized se presenti entrambi
    if "baseline" in summary_by_phase and "optimized" in summary_by_phase:
        print("\n" + "=" * 80)
        print("CONFRONTO BASELINE vs OPTIMIZED (basato sulle mediane)")
        print("=" * 80)
        b_stats = summary_by_phase["baseline"]
        o_stats = summary_by_phase["optimized"]
        for col, label in metrics_labels:
            if col in b_stats and col in o_stats:
                b_med = b_stats[col][1]
                o_med = o_stats[col][1]
                if b_med != 0:
                    delta_pct = ((o_med - b_med) / b_med) * 100.0
                    print(f"  {label:<32}: {b_med:10.2f} -> {o_med:10.2f}  ({delta_pct:+.2f}%)")

    # Esporta tabella riepilogativa in CSV per il report/paper
    out_csv = os.path.join(results_dir, "summary_analysis.csv")
    df.to_csv(out_csv, index=False)
    print(f"\nTabella completa esportata in: {out_csv}\n")


if __name__ == "__main__":
    results_df = collect_runs(RESULTS_DIR)
    print_summary(results_df, RESULTS_DIR)