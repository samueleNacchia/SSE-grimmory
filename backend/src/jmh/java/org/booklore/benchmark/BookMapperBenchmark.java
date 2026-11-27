package org.booklore.benchmark;

import org.booklore.mapper.ComicMetadataMapper;
import org.booklore.mapper.ShelfMapper;
import org.booklore.mapper.v2.BookMapperV2;
import org.booklore.model.dto.Book;
import org.booklore.model.entity.*;
import org.booklore.model.enums.BookFileType;
import org.mapstruct.factory.Mappers;
import org.openjdk.jmh.annotations.*;
import org.openjdk.jmh.infra.Blackhole;

import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.time.Instant;
import java.time.LocalDate;
import java.util.*;
import java.util.concurrent.TimeUnit;

@State(Scope.Benchmark)
@BenchmarkMode(Mode.AverageTime)
@OutputTimeUnit(TimeUnit.MILLISECONDS)
public class BookMapperBenchmark {

    private BookMapperV2 mapper;
    private List<BookEntity> bookEntities;

    @Setup(Level.Trial)
    public void setup() {
        mapper = createMapperWithDependencies();
        bookEntities = new ArrayList<>(1000);

        LibraryEntity library = new LibraryEntity();
        library.setId(1L);
        library.setName("Main Library");
        library.setFormatPriority(List.of(BookFileType.EPUB, BookFileType.PDF));

        LibraryPathEntity libraryPath = new LibraryPathEntity();
        libraryPath.setId(10L);
        libraryPath.setPath("/books");

        for (long i = 1; i <= 1000; i++) {
            BookEntity book = new BookEntity();
            book.setId(i);
            book.setLibrary(library);
            book.setLibraryPath(libraryPath);

            BookMetadataEntity metadata = new BookMetadataEntity();
            metadata.setBookId(i);
            metadata.setTitle("Title " + i);
            metadata.setSubtitle("Subtitle " + i);
            metadata.setPublisher("Publisher " + (i % 15));
            metadata.setPublishedDate(LocalDate.of(2020, 1, 1));
            metadata.setDescription("Long description text that gets ignored in list view...");
            metadata.setIsbn13("978000000" + String.format("%04d", i));
            metadata.setPageCount(300);
            metadata.setLanguage("en");
            metadata.setGoodreadsId("gr-" + i);
            metadata.setAsin("B00" + i);
            metadata.setTitleLocked(false);
            metadata.setAuthorsLocked(true);

            AuthorEntity author = new AuthorEntity();
            author.setId(i);
            author.setName("Author " + (i % 50));
            metadata.setAuthors(List.of(author));

            CategoryEntity category = new CategoryEntity();
            category.setId(i);
            category.setName("Fiction");
            metadata.setCategories(Set.of(category));

            metadata.setMoods(Collections.emptySet());
            metadata.setTags(Collections.emptySet());
            book.setMetadata(metadata);

            BookFileEntity f1 = new BookFileEntity();
            f1.setId(i * 10 + 1);
            f1.setBook(book);
            f1.setFileName("book_" + i + ".epub");
            f1.setFileSubPath("author");
            f1.setBookType(BookFileType.EPUB);
            f1.setFileSizeKb(1024L);
            f1.setAddedOn(Instant.now());

            BookFileEntity f2 = new BookFileEntity();
            f2.setId(i * 10 + 2);
            f2.setBook(book);
            f2.setFileName("book_" + i + ".pdf");
            f2.setFileSubPath("author");
            f2.setBookType(BookFileType.PDF);
            f2.setFileSizeKb(2048L);
            f2.setAddedOn(Instant.now());

            Set<BookFileEntity> files = new LinkedHashSet<>();
            files.add(f1);
            files.add(f2);
            book.setBookFiles(files);

            bookEntities.add(book);
        }
    }

    // --- BASELINE: mapping completo toDTO(bookEntity) ---
    @Benchmark
    public void baselineFullDtoMapping(Blackhole bh) {
        int size = bookEntities.size();
        List<Book> result = new ArrayList<>(size);
        for (int i = 0; i < size; i++) {
            result.add(mapper.toDTO(bookEntities.get(i)));
        }
        bh.consume(result);
    }

    private BookMapperV2 createMapperWithDependencies() {
        BookMapperV2 instance = Mappers.getMapper(BookMapperV2.class);
        ShelfMapper shelfMapper = instantiateMapper(ShelfMapper.class);
        ComicMetadataMapper comicMapper = instantiateMapper(ComicMetadataMapper.class);

        injectDependency(instance, ShelfMapper.class, shelfMapper);
        injectDependency(instance, ComicMetadataMapper.class, comicMapper);
        return instance;
    }

    private <T> T instantiateMapper(Class<T> mapperClass) {
        try {
            return Mappers.getMapper(mapperClass);
        } catch (RuntimeException ignored) {
            try {
                Class<?> implClass = Class.forName(mapperClass.getName() + "Impl");
                Constructor<?> ctor = implClass.getDeclaredConstructor();
                ctor.setAccessible(true);
                return mapperClass.cast(ctor.newInstance());
            } catch (Exception ex) {
                throw new IllegalStateException("Impossibile istanziare " + mapperClass.getName(), ex);
            }
        }
    }

    private void injectDependency(Object target, Class<?> fieldType, Object value) {
        if (target == null || value == null) return;
        Class<?> current = target.getClass();
        while (current != null) {
            for (Field field : current.getDeclaredFields()) {
                if (fieldType.isAssignableFrom(field.getType())) {
                    try {
                        field.setAccessible(true);
                        field.set(target, value);
                    } catch (IllegalAccessException ignored) {
                    }
                }
            }
            current = current.getSuperclass();
        }
    }
}