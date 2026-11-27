package org.booklore.benchmark;

import org.booklore.model.dto.Book;
import org.booklore.model.dto.BookMetadata;
import org.booklore.model.dto.Shelf;
import org.openjdk.jmh.annotations.*;
import org.openjdk.jmh.infra.Blackhole;
import tools.jackson.databind.ObjectMapper;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.TimeUnit;
import java.util.zip.GZIPOutputStream;

@State(Scope.Benchmark)
@BenchmarkMode(Mode.AverageTime)
@OutputTimeUnit(TimeUnit.MICROSECONDS)
public class BookControllerSerializationBenchmark {

    private List<Book> books;
    private ObjectMapper objectMapper;

    @Setup(Level.Trial)
    public void setup() {
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
    }

    // --- BASELINE: serializzazione Jackson + GZIP ad ogni richiesta HTTP ---
    @Benchmark
    public void baselineSerializationAndGzip(Blackhole bh) throws IOException {
        byte[] jsonBytes = objectMapper.writeValueAsBytes(books);
        byte[] gzipBytes = compressGzipDefault(jsonBytes);
        bh.consume(gzipBytes);
    }

    private static byte[] compressGzipDefault(byte[] data) throws IOException {
        try (ByteArrayOutputStream baos = new ByteArrayOutputStream(data.length / 4);
             GZIPOutputStream gzipOut = new GZIPOutputStream(baos)) {
            gzipOut.write(data);
            gzipOut.finish();
            return baos.toByteArray();
        }
    }
}