package org.booklore.benchmark;

import com.github.benmanes.caffeine.cache.Cache;
import com.github.benmanes.caffeine.cache.Caffeine;
import org.booklore.model.dto.Book;
import org.booklore.model.dto.BookMetadata;
import org.booklore.model.dto.Shelf;
import org.openjdk.jmh.annotations.*;
import org.openjdk.jmh.infra.Blackhole;
import tools.jackson.databind.ObjectMapper;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.time.Duration;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.zip.Deflater;
import java.util.zip.GZIPOutputStream;

@State(Scope.Benchmark)
@BenchmarkMode(Mode.AverageTime)
@OutputTimeUnit(TimeUnit.MICROSECONDS)
public class BookControllerSerializationBenchmark {

    private record CacheKey(Long userId, boolean withDescription, boolean stripForListView) {}
    private record CachedJsonResponse(byte[] plainBody, byte[] gzipBody, String eTag) {}

    private List<Book> books;
    private ObjectMapper objectMapper;
    private Cache<Object, CachedJsonResponse> jsonCache;
    private Long userId;
    private boolean withDescription;
    private boolean stripForListView;

    @Setup(Level.Trial)
    public void setup() throws IOException {
        userId = 1L;
        withDescription = false;
        stripForListView = true;
        objectMapper = new ObjectMapper();

        books = new ArrayList<>(1000);
        for (long i = 1; i <= 1000; i++) {
            Set<Shelf> shelves = HashSet.newHashSet(2);
            shelves.add(Shelf.builder().id(10L).name("Favorites").userId(1L).build());

            BookMetadata metadata = BookMetadata.builder()
                    .bookId(i)
                    .title("Sample Book Title Number " + i)
                    .publisher("Publisher " + (i % 20))
                    .language("en")
                    .pageCount(320)
                    .allMetadataLocked(false)
                    .build();

            Book book = Book.builder()
                    .id(i)
                    .libraryId(1L)
                    .metadata(metadata)
                    .shelves(shelves)
                    .build();

            books.add(book);
        }

        jsonCache = Caffeine.newBuilder()
                .maximumSize(200)
                .expireAfterWrite(Duration.ofMinutes(10))
                .build();

        // Pre-popola la cache per il benchmark di Cache Hit
        byte[] jsonBytes = objectMapper.writeValueAsBytes(books);
        byte[] gzipBytes = compressGzipFast(jsonBytes);
        String eTag = "\"books-" + Integer.toHexString(Arrays.hashCode(jsonBytes)) + "\"";
        jsonCache.put(new CacheKey(userId, withDescription, stripForListView),
                new CachedJsonResponse(jsonBytes, gzipBytes, eTag));
    }

    // --- IMPROVEMENTS (Cache Hit): lookup Caffeine + byte[] GZIP già pronti ---
    @Benchmark
    public void improvementsCachedJsonHit(Blackhole bh) {
        CacheKey key = new CacheKey(userId, withDescription, stripForListView);
        CachedJsonResponse cached = jsonCache.getIfPresent(key);
        bh.consume(cached.gzipBody());
        bh.consume(cached.eTag());
    }

    // --- IMPROVEMENTS (Cache Miss): serializzazione + GZIP BEST_SPEED + ETag ---
    @Benchmark
    public void improvementsCacheMissBuild(Blackhole bh) throws IOException {
        byte[] jsonBytes = objectMapper.writeValueAsBytes(books);
        byte[] gzipBytes = compressGzipFast(jsonBytes);
        String eTag = "\"books-" + Integer.toHexString(Arrays.hashCode(jsonBytes)) + "\"";
        CachedJsonResponse entry = new CachedJsonResponse(jsonBytes, gzipBytes, eTag);
        bh.consume(entry);
    }

    private static byte[] compressGzipFast(byte[] data) throws IOException {
        try (ByteArrayOutputStream baos = new ByteArrayOutputStream(Math.max(256, data.length / 6));
             GZIPOutputStream gzipOut = new GZIPOutputStream(baos) {
                 { def.setLevel(Deflater.BEST_SPEED); }
             }) {
            gzipOut.write(data);
            gzipOut.finish();
            return baos.toByteArray();
        }
    }
}