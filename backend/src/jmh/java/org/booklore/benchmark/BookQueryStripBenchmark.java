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

    // --- BASELINE: alloca Boolean[51] per ognuno dei 1000 libri ---
    @Benchmark
    public void baselineComputeAllMetadataLocked(Blackhole bh) {
        int lockedCount = 0;
        for (int i = 0; i < metadataList.size(); i++) {
            if (computeAllMetadataLockedBaseline(metadataList.get(i))) {
                lockedCount++;
            }
        }
        bh.consume(lockedCount);
    }

    private boolean computeAllMetadataLockedBaseline(BookMetadata m) {
        Boolean[] bookLocks = {
                m.getTitleLocked(), m.getSubtitleLocked(), m.getPublisherLocked(),
                m.getPublishedDateLocked(), m.getDescriptionLocked(), m.getSeriesNameLocked(),
                m.getSeriesNumberLocked(), m.getSeriesTotalLocked(), m.getIsbn13Locked(),
                m.getIsbn10Locked(), m.getOpenlibraryIdLocked(), m.getAsinLocked(), m.getGoodreadsIdLocked(),
                m.getComicvineIdLocked(), m.getHardcoverIdLocked(), m.getHardcoverBookIdLocked(),
                m.getDoubanIdLocked(), m.getGoogleIdLocked(), m.getPageCountLocked(),
                m.getLanguageLocked(), m.getAmazonRatingLocked(), m.getAmazonReviewCountLocked(),
                m.getGoodreadsRatingLocked(), m.getGoodreadsReviewCountLocked(),
                m.getHardcoverRatingLocked(), m.getHardcoverReviewCountLocked(),
                m.getDoubanRatingLocked(), m.getDoubanReviewCountLocked(),
                m.getLubimyczytacIdLocked(), m.getLubimyczytacRatingLocked(),
                m.getRanobedbIdLocked(), m.getRanobedbRatingLocked(),
                m.getAudibleIdLocked(), m.getAudibleRatingLocked(), m.getAudibleReviewCountLocked(),
                m.getApplebooksIdLocked(), m.getApplebooksRatingLocked(), m.getApplebooksReviewCountLocked(),
                m.getExternalUrlLocked(), m.getCoverLocked(), m.getAudiobookCoverLocked(),
                m.getAuthorsLocked(), m.getCategoriesLocked(), m.getMoodsLocked(),
                m.getTagsLocked(), m.getReviewsLocked(), m.getNarratorLocked(),
                m.getAbridgedLocked(), m.getAgeRatingLocked(), m.getContentRatingLocked()
        };

        boolean hasAnyLock = false;
        for (Boolean lock : bookLocks) {
            if (Boolean.TRUE.equals(lock)) {
                hasAnyLock = true;
            } else {
                return false;
            }
        }
        return hasAnyLock;
    }
}