package org.booklore.benchmark;

import org.booklore.model.dto.Book;
import org.booklore.model.dto.Shelf;
import org.booklore.model.entity.UserBookFileProgressEntity;
import org.booklore.model.entity.UserBookProgressEntity;
import org.booklore.util.BookUtils;
import org.openjdk.jmh.annotations.*;
import org.openjdk.jmh.infra.Blackhole;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.TimeUnit;
import java.util.stream.Collectors;

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

    // --- BASELINE: codice attuale in BookService.getBookDTOs ---
    @Benchmark
    public void baselinePostProcessing(Blackhole bh) {
        Set<Long> bookIds = books.stream().map(Book::getId).collect(Collectors.toSet());

        books.forEach(book -> {
            UserBookProgressEntity up = progressMap.get(book.getId());
            UserBookFileProgressEntity fp = fileProgressMap.get(book.getId());
            if (up != null || fp != null) {
                bh.consume(up);
            }
            Set<Shelf> filtered = BookUtils.filterShelvesByUserId(book.getShelves(), userId);
            book.setShelves(!includeDescription && filtered != null && filtered.isEmpty() ? null : filtered);
        });

        bh.consume(bookIds);
        bh.consume(books);
    }
}