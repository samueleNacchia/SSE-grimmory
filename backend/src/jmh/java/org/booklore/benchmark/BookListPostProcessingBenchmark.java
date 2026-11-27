package org.booklore.benchmark;

import org.booklore.model.dto.Book;
import org.booklore.model.dto.Shelf;
import org.booklore.model.entity.UserBookFileProgressEntity;
import org.booklore.model.entity.UserBookProgressEntity;
import org.openjdk.jmh.annotations.*;
import org.openjdk.jmh.infra.Blackhole;

import java.util.*;
import java.util.concurrent.TimeUnit;

@State(Scope.Benchmark)
@BenchmarkMode(Mode.AverageTime)
@OutputTimeUnit(TimeUnit.MICROSECONDS)
public class BookListPostProcessingBenchmark {

    private List<Book> books;
    private Map<Long, UserBookProgressEntity> progressMap;
    private Map<Long, UserBookFileProgressEntity> fileProgressMap;
    private Long userId;
    private boolean includeDescription;

    @Setup(Level.Invocation)
    public void setupInvocation() {
        userId = 1L;
        includeDescription = false;
        books = new ArrayList<>(1000);
        progressMap = HashMap.newHashMap(1000);
        fileProgressMap = HashMap.newHashMap(1000);

        for (long i = 1; i <= 1000; i++) {
            Set<Shelf> shelves = HashSet.newHashSet(4);
            Shelf s1 = Shelf.builder()
                    .id(10L)
                    .userId(1L)
                    .build();

            Shelf s2 = Shelf.builder()
                    .id(20L)
                    .userId(2L)
                    .build();

            shelves.add(s1);
            shelves.add(s2);

            Book b = Book.builder()
                    .id(i)
                    .shelves(shelves)
                    .build();

            books.add(b);
        }
    }

    // --- IMPROVEMENTS: pre-sizing + ciclo diretto + shallow copy cache-safe ---
    @Benchmark
    public void improvementsPostProcessing(Blackhole bh) {
        int size = books.size();
        Set<Long> bookIds = HashSet.newHashSet(size);
        List<Book> result = new ArrayList<>(size);

        for (int i = 0; i < size; i++) {
            Book cachedBook = books.get(i);
            Book book = cachedBook.toBuilder().build();
            Long id = book.getId();
            bookIds.add(id);

            UserBookProgressEntity up = progressMap.get(id);
            UserBookFileProgressEntity fp = fileProgressMap.get(id);
            if (up != null || fp != null) {
                bh.consume(up);
            }

            Set<Shelf> rawShelves = cachedBook.getShelves();
            if (rawShelves == null || rawShelves.isEmpty()) {
                book.setShelves(includeDescription ? Collections.emptySet() : null);
            } else {
                Set<Shelf> filtered = null;
                for (Shelf shelf : rawShelves) {
                    if (userId.equals(shelf.getUserId())) {
                        if (filtered == null) {
                            filtered = HashSet.newHashSet(rawShelves.size());
                        }
                        filtered.add(shelf);
                    }
                }
                book.setShelves(!includeDescription && filtered == null ? null : filtered);
            }
            result.add(book);
        }

        bh.consume(bookIds);
        bh.consume(result);
    }
}