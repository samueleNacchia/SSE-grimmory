import json
from pathlib import Path

BASELINE_FILE = Path("jmh-baseline.json")
IMPROVEMENTS_FILE = Path("jmh-improvements.json")

UNIT_TO_US = {
    "ns/op": 1e-3,
    "us/op": 1.0,
    "µs/op": 1.0,
    "ms/op": 1e3,
    "s/op": 1e6,
}

COMPARISONS = [
    (
        "1. BookMapperV2",
        "BookMapperBenchmark.baselineFullDtoMapping",
        "BookMapperBenchmark.improvementsListViewDtoMapping",
    ),
    (
        "2. ComicMetadataMapper",
        "ComicMetadataMapperBenchmark.mapComicMetadata",
        "ComicMetadataMapperBenchmark.mapComicMetadata",
    ),
    (
        "3. BookQueryService.computeAllMetadataLocked",
        "BookQueryStripBenchmark.baselineComputeAllMetadataLocked",
        "BookQueryStripBenchmark.improvementsComputeAllMetadataLocked",
    ),
    (
        "4. BookService.getBookDTOs",
        "BookListPostProcessingBenchmark.baselinePostProcessing",
        "BookListPostProcessingBenchmark.improvementsPostProcessing",
    ),
    (
        "5a. BookController (Cache Miss)",
        "BookControllerSerializationBenchmark.baselineSerializationAndGzip",
        "BookControllerSerializationBenchmark.improvementsCacheMissBuild",
    ),
    (
        "5b. BookController (Cache Hit GZIP)",
        "BookControllerSerializationBenchmark.baselineSerializationAndGzip",
        "BookControllerSerializationBenchmark.improvementsCachedJsonHit",
    ),
]


def load_scores_us(path: Path) -> dict[str, float]:
    with path.open(encoding="utf-8") as f:
        data = json.load(f)

    scores = {}
    for entry in data:
        key = ".".join(entry["benchmark"].split(".")[-2:])
        metric = entry["primaryMetric"]
        unit = metric["scoreUnit"]
        if unit not in UNIT_TO_US:
            raise ValueError(f"Unità JMH non supportata: {unit}")
        scores[key] = metric["score"] * UNIT_TO_US[unit]
    return scores


def main() -> None:
    base = load_scores_us(BASELINE_FILE) if BASELINE_FILE.exists() else {}
    opt = load_scores_us(IMPROVEMENTS_FILE) if IMPROVEMENTS_FILE.exists() else {}

    print(f"{'Benchmark':<44} {'Base (µs)':>11} {'Opt (µs)':>11} {'Speedup':>10}")
    print("-" * 79)

    for label, b_key, o_key in COMPARISONS:
        if b_key not in base or o_key not in opt:
            continue
        b_us = base[b_key]
        o_us = opt[o_key]
        speedup = b_us / o_us if o_us > 0 else float("inf")
        print(f"{label:<44} {b_us:>11,.3f} {o_us:>11,.3f} {speedup:>9,.2f}x")


if __name__ == "__main__":
    main()