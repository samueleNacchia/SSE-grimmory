package org.booklore.benchmark;

import org.booklore.model.dto.BookMetadata;
import org.openjdk.jmh.annotations.*;
import org.openjdk.jmh.infra.Blackhole;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;

@State(Scope.Benchmark)
@BenchmarkMode(Mode.AverageTime)
@OutputTimeUnit(TimeUnit.MICROSECONDS)
public class BookQueryStripBenchmark {

    private List<BookMetadata> metadataList;

    @Setup(Level.Trial)
    public void setup() {
        metadataList = new ArrayList<>(1000);
        for (int i = 0; i < 1000; i++) {
            BookMetadata m = BookMetadata.builder()
                    .title("Book " + i)
                    .titleLocked(i % 10 == 0) // solo il 10% ha il primo lock a true
                    .subtitleLocked(false)
                    .build();
            metadataList.add(m);
        }
    }

    // --- IMPROVEMENTS: short-circuit && senza alcuna allocazione ---
    @Benchmark
    public void improvementsComputeAllMetadataLocked(Blackhole bh) {
        int lockedCount = 0;
        for (int i = 0; i < metadataList.size(); i++) {
            if (computeAllMetadataLockedImprovements(metadataList.get(i))) {
                lockedCount++;
            }
        }
        bh.consume(lockedCount);
    }

    private boolean computeAllMetadataLockedImprovements(BookMetadata m) {
        return Boolean.TRUE.equals(m.getTitleLocked())
                && Boolean.TRUE.equals(m.getSubtitleLocked())
                && Boolean.TRUE.equals(m.getPublisherLocked())
                && Boolean.TRUE.equals(m.getPublishedDateLocked())
                && Boolean.TRUE.equals(m.getDescriptionLocked())
                && Boolean.TRUE.equals(m.getSeriesNameLocked())
                && Boolean.TRUE.equals(m.getSeriesNumberLocked())
                && Boolean.TRUE.equals(m.getSeriesTotalLocked())
                && Boolean.TRUE.equals(m.getIsbn13Locked())
                && Boolean.TRUE.equals(m.getIsbn10Locked())
                && Boolean.TRUE.equals(m.getOpenlibraryIdLocked())
                && Boolean.TRUE.equals(m.getAsinLocked())
                && Boolean.TRUE.equals(m.getGoodreadsIdLocked())
                && Boolean.TRUE.equals(m.getComicvineIdLocked())
                && Boolean.TRUE.equals(m.getHardcoverIdLocked())
                && Boolean.TRUE.equals(m.getHardcoverBookIdLocked())
                && Boolean.TRUE.equals(m.getDoubanIdLocked())
                && Boolean.TRUE.equals(m.getGoogleIdLocked())
                && Boolean.TRUE.equals(m.getPageCountLocked())
                && Boolean.TRUE.equals(m.getLanguageLocked())
                && Boolean.TRUE.equals(m.getAmazonRatingLocked())
                && Boolean.TRUE.equals(m.getAmazonReviewCountLocked())
                && Boolean.TRUE.equals(m.getGoodreadsRatingLocked())
                && Boolean.TRUE.equals(m.getGoodreadsReviewCountLocked())
                && Boolean.TRUE.equals(m.getHardcoverRatingLocked())
                && Boolean.TRUE.equals(m.getHardcoverReviewCountLocked())
                && Boolean.TRUE.equals(m.getDoubanRatingLocked())
                && Boolean.TRUE.equals(m.getDoubanReviewCountLocked())
                && Boolean.TRUE.equals(m.getLubimyczytacIdLocked())
                && Boolean.TRUE.equals(m.getLubimyczytacRatingLocked())
                && Boolean.TRUE.equals(m.getRanobedbIdLocked())
                && Boolean.TRUE.equals(m.getRanobedbRatingLocked())
                && Boolean.TRUE.equals(m.getAudibleIdLocked())
                && Boolean.TRUE.equals(m.getAudibleRatingLocked())
                && Boolean.TRUE.equals(m.getAudibleReviewCountLocked())
                && Boolean.TRUE.equals(m.getApplebooksIdLocked())
                && Boolean.TRUE.equals(m.getApplebooksRatingLocked())
                && Boolean.TRUE.equals(m.getApplebooksReviewCountLocked())
                && Boolean.TRUE.equals(m.getExternalUrlLocked())
                && Boolean.TRUE.equals(m.getCoverLocked())
                && Boolean.TRUE.equals(m.getAudiobookCoverLocked())
                && Boolean.TRUE.equals(m.getAuthorsLocked())
                && Boolean.TRUE.equals(m.getCategoriesLocked())
                && Boolean.TRUE.equals(m.getMoodsLocked())
                && Boolean.TRUE.equals(m.getTagsLocked())
                && Boolean.TRUE.equals(m.getReviewsLocked())
                && Boolean.TRUE.equals(m.getNarratorLocked())
                && Boolean.TRUE.equals(m.getAbridgedLocked())
                && Boolean.TRUE.equals(m.getAgeRatingLocked())
                && Boolean.TRUE.equals(m.getContentRatingLocked());
    }
}