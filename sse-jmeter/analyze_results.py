import os
import re
import statistics
from datetime import datetime
import pandas as pd
import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
RESULTS_DIR = os.path.join(SCRIPT_DIR, "results")
RUNS_HISTORY_CSV = os.path.join(SCRIPT_DIR, "runs_history.csv")
SUMMARY_CSV = os.path.join(SCRIPT_DIR, "summary_analysis.csv")

KNOWN_TEST_TYPES = {"load", "stress", "spike", "soak"}

# Supporta:
# - eb_<phase>_<test_type>_run<N>_<timestamp>.csv (es. eb_optimized_v3_stress_run1_20261125_120000_000.csv)
# - eb_<phase>_run<N>_<timestamp>.csv (retrocompatibilità, test_type="load")
FILENAME_RE = re.compile(
    r"^(eb|jm)_([a-zA-Z0-9_-]+)_run(\d+)_(\d{8}_\d{6}(?:_\d{3})?)\.(csv|jtl)$"
)

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
    """Separa phase e test_type gestendo anche fasi con underscore (es. optimized_v3_stress)."""
    parts = raw_tag.rsplit("_", 1)
    if len(parts) == 2 and parts[1].lower() in KNOWN_TEST_TYPES:
        return parts[0], parts[1].lower()
    return raw_tag, "load"


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


def collect_runs(results_dir: str, history_csv: str = RUNS_HISTORY_CSV) -> pd.DataFrame:
    existing_df = pd.DataFrame()
    if os.path.isfile(history_csv):
        existing_df = pd.read_csv(history_csv)
        if not existing_df.empty and "test_type" not in existing_df.columns:
            existing_df["test_type"] = "load"

    grouped = {}
    if os.path.isdir(results_dir):
        for fname in sorted(os.listdir(results_dir)):
            match = FILENAME_RE.match(fname)
            if not match:
                continue
            kind, raw_tag, run_num, ts, _ = match.groups()
            phase, test_type = _split_phase_and_test_type(raw_tag)
            key = (phase, test_type, int(run_num))
            if kind in grouped.get(key, {}):
                raise ValueError(
                    f"File duplicato per fase='{phase}', test='{test_type}', run={run_num}: '{fname}'. "
                    "Sposta o elimina i risultati delle campagne precedenti prima di rieseguire."
                )
            grouped.setdefault(key, {})[kind] = os.path.join(results_dir, fname)
            grouped[key].setdefault("timestamp", ts)

    rows = []
    for (phase, test_type, run_num), files in sorted(grouped.items()):
        if "eb" not in files or "jm" not in files:
            missing = "EnergiBridge" if "eb" not in files else "JMeter"
            print(f"ATTENZIONE: run {phase}/{test_type}/run{run_num} senza file {missing}; metriche parziali.")
        row = {
            "phase": phase,
            "test_type": test_type,
            "run": run_num,
            "timestamp": files.get("timestamp", ""),
        }
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

    new_df = pd.DataFrame(rows)

    if new_df.empty:
        return existing_df
    if existing_df.empty:
        return new_df

    # Sostituisci nello storico interno le combinazioni (phase, test_type) appena rieseguite
    updated_pairs = set(zip(new_df["phase"], new_df["test_type"]))
    mask = existing_df.apply(lambda r: (r["phase"], r["test_type"]) in updated_pairs, axis=1)
    existing_df = existing_df[~mask]

    combined_df = pd.concat([existing_df, new_df], ignore_index=True)
    return combined_df.sort_values(by=["phase", "test_type", "run"]).reset_index(drop=True)


def build_aggregated_summary(df: pd.DataFrame) -> pd.DataFrame:
    """Costruisce 1 riga elaborata per ogni coppia (phase, test_type) con mediane, medie, std e delta% vs baseline."""
    agg_rows = []
    baseline_medians = {}

    # Prima passata: calcola statistiche per ogni (phase, test_type)
    for (phase, test_type), group in df.groupby(["phase", "test_type"], sort=True):
        row = {
            "phase": phase,
            "test_type": test_type,
            "runs": int(len(group)),
            "requests_median": float(group["requests"].median()) if "requests" in group.columns else np.nan,
            "error_rate_pct_mean": float(group["error_rate_pct"].mean()) if "error_rate_pct" in group.columns else 0.0,
        }
        if phase == "baseline":
            baseline_medians[test_type] = {}

        for col, _ in METRICS_LABELS:
            if col not in group.columns:
                continue
            vals = group[col].dropna().tolist()
            if not vals:
                continue
            med_v = float(statistics.median(vals))
            mean_v = float(statistics.mean(vals))
            std_v = float(statistics.stdev(vals)) if len(vals) > 1 else 0.0

            row[f"{col}_median"] = round(med_v, 4)
            row[f"{col}_mean"] = round(mean_v, 4)
            row[f"{col}_std"] = round(std_v, 4)

            if phase == "baseline":
                baseline_medians[test_type][col] = med_v

        agg_rows.append(row)

    # Seconda passata: calcola i delta% sulle mediane rispetto alla baseline dello stesso test_type
    for row in agg_rows:
        phase = row["phase"]
        test_type = row["test_type"]
        b_meds = baseline_medians.get(test_type, {})
        for col, _ in METRICS_LABELS:
            med_key = f"{col}_median"
            delta_key = f"{col}_delta_pct"
            if phase == "baseline" or med_key not in row or col not in b_meds:
                row[delta_key] = 0.0 if phase == "baseline" else np.nan
            else:
                b_val = b_meds[col]
                t_val = row[med_key]
                row[delta_key] = round(((t_val - b_val) / b_val) * 100.0, 2) if b_val != 0 else np.nan

    return pd.DataFrame(agg_rows)


def _save_csv_with_fallback(df: pd.DataFrame, target_path: str, label: str):
    try:
        df.to_csv(target_path, index=False)
        print(f"{label} esportato in: {target_path}")
    except PermissionError:
        base, ext = os.path.splitext(target_path)
        fallback_path = f"{base}_{datetime.now().strftime('%Y%m%d_%H%M%S')}{ext}"
        df.to_csv(fallback_path, index=False)
        print(f"[!] '{target_path}' è aperto in un altro programma. Esportato in: {fallback_path}")


def print_summary(df: pd.DataFrame, summary_csv: str = SUMMARY_CSV, history_csv: str = RUNS_HISTORY_CSV):
    if df.empty:
        print("Nessun file eb_*.csv o jm_*.jtl trovato nella cartella results e nessuno storico presente.")
        return

    print("\n" + "=" * 80)
    print("DETTAGLIO SINGOLE RUN")
    print("=" * 80)
    cols_to_show = [
        c for c in [
            "phase", "test_type", "run", "requests", "error_rate_pct",
            "total_energy_j", "energy_per_req_mj", "avg_power_w",
            "throughput_rps", "latency_mean_ms", "latency_p95_ms"
        ] if c in df.columns
    ]
    print(df[cols_to_show].to_string(index=False, float_format=lambda x: f"{x:.2f}"))

    if "error_rate_pct" in df.columns and (df["error_rate_pct"] > 0).any():
        print("\n[!] ATTENZIONE: Alcune run presentano error_rate_pct > 0%. Verifica i log prima di confrontare.")

    # Raggruppamento per scenario di test e fase
    for test_type, t_group in df.groupby("test_type", sort=True):
        print("\n" + "#" * 80)
        print(f"SCENARIO DI TEST: {test_type.upper()}")
        print("#" * 80)

        summary_by_phase = {}
        for phase, group in t_group.groupby("phase", sort=True):
            print(f"\n>>> FASE: {phase.upper()} [{test_type}] (n = {len(group)} run)")
            summary_by_phase[phase] = {}
            for col, label in METRICS_LABELS:
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

        if "baseline" in summary_by_phase:
            b_stats = summary_by_phase["baseline"]
            other_phases = [p for p in summary_by_phase if p != "baseline"]
            for target_phase in other_phases:
                print("\n" + "=" * 80)
                print(f"CONFRONTO [{test_type.upper()}] BASELINE vs {target_phase.upper()} (basato sulle mediane)")
                print("=" * 80)
                t_stats = summary_by_phase[target_phase]
                for col, label in METRICS_LABELS:
                    if col in b_stats and col in t_stats:
                        b_med = b_stats[col][1]
                        t_med = t_stats[col][1]
                        if b_med != 0:
                            delta_pct = ((t_med - b_med) / b_med) * 100.0
                            print(f"  {label:<32}: {b_med:10.2f} -> {t_med:10.2f}  ({delta_pct:+.2f}%)")

    # Esporta sia lo storico delle singole run sia la tabella aggregata (1 riga per phase + test_type)
    print("\n" + "-" * 80)
    _save_csv_with_fallback(df, history_csv, "Storico singole run")
    agg_df = build_aggregated_summary(df)
    _save_csv_with_fallback(agg_df, summary_csv, "Summary elaborato (1 riga per fase/test)")
    print("-" * 80 + "\n")


if __name__ == "__main__":
    results_df = collect_runs(RESULTS_DIR, RUNS_HISTORY_CSV)
    print_summary(results_df, SUMMARY_CSV, RUNS_HISTORY_CSV)