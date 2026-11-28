package org.booklore.mapper.v2;

import org.booklore.mapper.ComicMetadataMapper;
import org.booklore.mapper.ShelfMapper;
import org.booklore.model.dto.*;
import org.booklore.model.entity.*;
import org.booklore.model.enums.BookFileType;
import org.mapstruct.AfterMapping;
import org.mapstruct.Mapper;
import org.mapstruct.Mapping;
import org.mapstruct.MappingTarget;
import org.mapstruct.Named;
import org.mapstruct.ReportingPolicy;
import org.mapstruct.BeanMapping;
import org.mapstruct.Context;

import java.util.Comparator;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;
import java.util.ArrayList;
import java.util.Collections;

@Mapper(componentModel = "spring", uses = {ShelfMapper.class, ComicMetadataMapper.class}, unmappedTargetPolicy = ReportingPolicy.IGNORE)
public interface BookMapperV2 {

    @Mapping(source = "library.id", target = "libraryId")
    @Mapping(source = "library.name", target = "libraryName")
    @Mapping(source = "libraryPath", target = "libraryPath", qualifiedByName = "mapLibraryPathIdOnly")
    @Mapping(source = "bookFiles", target = "primaryFile", qualifiedByName = "mapPrimaryFile")
    @Mapping(source = "bookFiles", target = "alternativeFormats", qualifiedByName = "mapAlternativeFormats")
    @Mapping(source = "bookFiles", target = "supplementaryFiles", qualifiedByName = "mapSupplementaryFiles")
    @Mapping(target = "metadata", qualifiedByName = "mapMetadata")
    Book toDTO(BookEntity bookEntity, @Context boolean isListView);
    default Book toDTO(BookEntity bookEntity) { return toDTO(bookEntity, false); }

    @Mapping(source = "library.id", target = "libraryId")
    @Mapping(source = "library.name", target = "libraryName")
    @Mapping(target = "libraryPath", ignore = true)
    @Mapping(target = "primaryFile", ignore = true)
    @Mapping(target = "alternativeFormats", ignore = true)
    @Mapping(target = "supplementaryFiles", ignore = true)
    @Mapping(target = "metadata", qualifiedByName = "mapMetadataForListView")
    Book toListViewDTO(BookEntity bookEntity, @Context boolean isListView);

    @Named("mapMetadata")
    @Mapping(target = "description", ignore = true)
    @Mapping(target = "authors", source = "authors", qualifiedByName = "mapAuthors")
    @Mapping(target = "categories", source = "categories", qualifiedByName = "mapCategories")
    @Mapping(target = "moods", source = "moods", qualifiedByName = "mapMoods")
    @Mapping(target = "tags", source = "tags", qualifiedByName = "mapTags")
    BookMetadata mapMetadata(BookMetadataEntity metadataEntity);

    @AfterMapping
    default void mapAudiobookMetadata(BookEntity bookEntity, @MappingTarget Book book, @Context boolean isListView) {
        if (isListView || book.getMetadata() == null) {
            return;
        }

        BookMetadataEntity metadataEntity = bookEntity.getMetadata();
        BookMetadata metadata = book.getMetadata();

        if (metadataEntity != null) {
            metadata.setNarrator(metadataEntity.getNarrator());
            metadata.setAbridged(metadataEntity.getAbridged());
            metadata.setNarratorLocked(metadataEntity.getNarratorLocked());
            metadata.setAbridgedLocked(metadataEntity.getAbridgedLocked());
        }

        BookFileEntity audiobookFile = bookEntity.getBookFiles() != null
                ? bookEntity.getBookFiles().stream()
                    .filter(bf -> bf.getBookType() == BookFileType.AUDIOBOOK && bf.isBook())
                    .min(Comparator.comparingLong(BookFileEntity::getId))
                    .orElse(null)
                : null;

        if (audiobookFile != null && audiobookFile.getDurationSeconds() != null) {
            List<AudiobookMetadata.ChapterInfo> chapters = null;
            if (audiobookFile.getChapters() != null) {
                chapters = audiobookFile.getChapters().stream()
                        .map(ch -> AudiobookMetadata.ChapterInfo.builder()
                                .index(ch.getIndex())
                                .title(ch.getTitle())
                                .startTimeMs(ch.getStartTimeMs())
                                .endTimeMs(ch.getEndTimeMs())
                                .durationMs(ch.getDurationMs())
                                .build())
                        .toList();
            }

            metadata.setAudiobookMetadata(
                    AudiobookMetadata.builder()
                            .durationSeconds(audiobookFile.getDurationSeconds())
                            .bitrate(audiobookFile.getBitrate())
                            .sampleRate(audiobookFile.getSampleRate())
                            .channels(audiobookFile.getChannels())
                            .codec(audiobookFile.getCodec())
                            .chapterCount(audiobookFile.getChapterCount())
                            .chapters(chapters)
                            .build()
            );
        }
    }

    @Named("mapAuthors")
    default List<String> mapAuthors(List<AuthorEntity> authors) {
        return authors == null ? List.of() :
                authors.stream().map(AuthorEntity::getName).toList();
    }

    @Named("mapCategories")
    default Set<String> mapCategories(Set<CategoryEntity> categories) {
        return categories == null ? Set.of() :
                categories.stream().map(CategoryEntity::getName).collect(Collectors.toSet());
    }

    @Named("mapMoods")
    default Set<String> mapMoods(Set<MoodEntity> moods) {
        return moods == null ? Set.of() :
                moods.stream().map(MoodEntity::getName).collect(Collectors.toSet());
    }

    @Named("mapTags")
    default Set<String> mapTags(Set<TagEntity> tags) {
        return tags == null ? Set.of() :
                tags.stream().map(TagEntity::getName).collect(Collectors.toSet());
    }

    @Named("mapPrimaryFile")
    default BookFile mapPrimaryFile(Set<BookFileEntity> bookFiles) {
        BookFileEntity primary = getPrimaryBookFile(bookFiles);
        return toBookFile(primary);
    }

    @Named("mapAlternativeFormats")
    default List<BookFile> mapAlternativeFormats(Set<BookFileEntity> bookFiles) {
        if (bookFiles == null) return Collections.emptyList();
        BookFileEntity primary = getPrimaryBookFile(bookFiles);
        return bookFiles.stream()
                .filter(BookFileEntity::isBook)
                .filter(bf -> !bf.equals(primary))
                .map(this::toBookFile)
                .sorted(Comparator.comparingLong(BookFile::getId))
                .toList();
    }

    @Named("mapSupplementaryFiles")
    default List<BookFile> mapSupplementaryFiles(Set<BookFileEntity> bookFiles) {
        if (bookFiles == null) return Collections.emptyList();
        return bookFiles.stream()
                .filter(bf -> !bf.isBook())
                .map(this::toBookFile)
                .toList();
    }

    default BookFileEntity getPrimaryBookFile(Set<BookFileEntity> bookFiles) {
        if (bookFiles == null || bookFiles.isEmpty()) return null;

        List<BookFileEntity> bookFormats = bookFiles.stream()
                .filter(BookFileEntity::isBook)
                .sorted(Comparator.comparingLong(BookFileEntity::getId))
                .toList();

        if (bookFormats.isEmpty()) return null;

        BookFileEntity firstBook = bookFormats.getFirst();
        LibraryEntity library = firstBook.getBook() != null ? firstBook.getBook().getLibrary() : null;

        if (library != null && library.getFormatPriority() != null && !library.getFormatPriority().isEmpty()) {
            for (BookFileType format : library.getFormatPriority()) {
                var match = bookFormats.stream()
                        .filter(bf -> bf.getBookType() == format)
                        .findFirst();
                if (match.isPresent()) {
                    return match.get();
                }
            }
        }
        return firstBook;
    }

    default BookFile toBookFile(BookFileEntity entity) {
        if (entity == null) return null;
        return BookFile.builder()
                .id(entity.getId())
                .bookId(entity.getBook().getId())
                .fileName(entity.getFileName())
                .filePath(entity.getFullFilePath().toString())
                .fileSubPath(entity.getFileSubPath())
                .isBook(entity.isBook())
                .bookType(entity.getBookType())
                .archiveType(entity.getArchiveType())
                .fileSizeKb(entity.getFileSizeKb())
                .extension(extractExtension(entity))
                .description(entity.getDescription())
                .addedOn(entity.getAddedOn())
                .build();
    }

    default String extractExtension(BookFileEntity entity) {
        if (entity == null) return null;
        String fileName;
        if (entity.isFolderBased()) {
            var firstFile = entity.getFirstAudioFile();
            fileName = firstFile != null ? firstFile.getFileName().toString() : null;
        } else {
            fileName = entity.getFileName();
        }
        if (fileName == null) return null;
        int lastDot = fileName.lastIndexOf('.');
        return lastDot > 0 ? fileName.substring(lastDot + 1).toLowerCase() : null;
    }

    @Named("mapLibraryPathIdOnly")
    default LibraryPath mapLibraryPathIdOnly(LibraryPathEntity entity) {
        if (entity == null) return null;
        return LibraryPath.builder()
                .id(entity.getId())
                .build();
    }

    @Named("mapMetadataForListView")
    @BeanMapping(ignoreByDefault = true)
    @Mapping(target = "bookId", source = "bookId")
    @Mapping(target = "title", source = "title")
    @Mapping(target = "publisher", source = "publisher")
    @Mapping(target = "publishedDate", source = "publishedDate")
    @Mapping(target = "seriesName", source = "seriesName")
    @Mapping(target = "seriesNumber", source = "seriesNumber")
    @Mapping(target = "isbn13", source = "isbn13")
    @Mapping(target = "isbn10", source = "isbn10")
    @Mapping(target = "pageCount", source = "pageCount")
    @Mapping(target = "language", source = "language")
    @Mapping(target = "amazonRating", source = "amazonRating")
    @Mapping(target = "amazonReviewCount", source = "amazonReviewCount")
    @Mapping(target = "goodreadsRating", source = "goodreadsRating")
    @Mapping(target = "goodreadsReviewCount", source = "goodreadsReviewCount")
    @Mapping(target = "hardcoverRating", source = "hardcoverRating")
    @Mapping(target = "hardcoverReviewCount", source = "hardcoverReviewCount")
    @Mapping(target = "ranobedbRating", source = "ranobedbRating")
    @Mapping(target = "ageRating", source = "ageRating")
    @Mapping(target = "contentRating", source = "contentRating")
    @Mapping(target = "coverUpdatedOn", source = "coverUpdatedOn")
    @Mapping(target = "narrator", source = "narrator")
    @Mapping(target = "authors", source = "authors", qualifiedByName = "mapAuthorsNullable")
    @Mapping(target = "categories", source = "categories", qualifiedByName = "mapCategoriesNullable")
    @Mapping(target = "moods", source = "moods", qualifiedByName = "mapMoodsNullable")
    @Mapping(target = "tags", source = "tags", qualifiedByName = "mapTagsNullable")
    @Mapping(target = "comicMetadata", source = "comicMetadata", qualifiedByName = "toListViewComicMetadata")
    BookMetadata mapMetadataForListView(BookMetadataEntity metadataEntity);

    @Named("mapAuthorsNullable")
    default List<String> mapAuthorsNullable(List<AuthorEntity> authors) {
        if (authors == null || authors.isEmpty()) return Collections.emptyList();
        return authors.stream().map(AuthorEntity::getName).toList();
    }

    @Named("mapCategoriesNullable")
    default Set<String> mapCategoriesNullable(Set<CategoryEntity> categories) {
        if (categories == null || categories.isEmpty()) return Collections.emptySet();
        return categories.stream().map(CategoryEntity::getName).collect(Collectors.toSet());
    }

    @Named("mapMoodsNullable")
    default Set<String> mapMoodsNullable(Set<MoodEntity> moods) {
        if (moods == null || moods.isEmpty()) return Collections.emptySet();
        return moods.stream().map(MoodEntity::getName).collect(Collectors.toSet());
    }

    @Named("mapTagsNullable")
    default Set<String> mapTagsNullable(Set<TagEntity> tags) {
        if (tags == null || tags.isEmpty()) return Collections.emptySet();
        return tags.stream().map(TagEntity::getName).collect(Collectors.toSet());
    }

    @AfterMapping
    default void mapFilesAndAudiobookSinglePass(BookEntity bookEntity, @MappingTarget Book book, @Context boolean isListView) {
        if (!isListView) {
            return;
        }
        Set<BookFileEntity> bookFiles = bookEntity.getBookFiles();
        if (bookFiles == null || bookFiles.isEmpty()) {
            return;
        }

        List<BookFileEntity> bookFormats = new ArrayList<>();
        List<BookFile> supplementary = null;
        BookFileEntity firstAudiobook = null;

        for (BookFileEntity bf : bookFiles) {
            if (bf.isBook()) {
                bookFormats.add(bf);
                if (bf.getBookType() == BookFileType.AUDIOBOOK &&
                        (firstAudiobook == null || bf.getId() < firstAudiobook.getId())) {
                    firstAudiobook = bf;
                }
            } else {
                if (supplementary == null) supplementary = new ArrayList<>();
                supplementary.add(toBookFile(bf));
            }
        }

        if (!bookFormats.isEmpty()) {
            bookFormats.sort(Comparator.comparingLong(BookFileEntity::getId));
            BookFileEntity primary = bookFormats.getFirst();
            LibraryEntity library = primary.getBook() != null ? primary.getBook().getLibrary() : null;

            if (library != null && library.getFormatPriority() != null && !library.getFormatPriority().isEmpty()) {
                outer:
                for (BookFileType format : library.getFormatPriority()) {
                    for (BookFileEntity bf : bookFormats) {
                        if (bf.getBookType() == format) {
                            primary = bf;
                            break outer;
                        }
                    }
                }
            }

            book.setPrimaryFile(toBookFile(primary));

            if (bookFormats.size() > 1) {
                List<BookFile> alternatives = new ArrayList<>(bookFormats.size() - 1);
                for (BookFileEntity bf : bookFormats) {
                    if (bf != primary) {
                        alternatives.add(toBookFile(bf));
                    }
                }
                book.setAlternativeFormats(alternatives);
            }
        }

        if (supplementary != null && !supplementary.isEmpty()) {
            book.setSupplementaryFiles(supplementary);
        }

        if (book.getMetadata() != null && firstAudiobook != null && firstAudiobook.getDurationSeconds() != null) {
            book.getMetadata().setAudiobookMetadata(
                    AudiobookMetadata.builder()
                            .durationSeconds(firstAudiobook.getDurationSeconds())
                            .bitrate(firstAudiobook.getBitrate())
                            .sampleRate(firstAudiobook.getSampleRate())
                            .channels(firstAudiobook.getChannels())
                            .codec(firstAudiobook.getCodec())
                            .chapterCount(firstAudiobook.getChapterCount())
                            .build()
            );
        }
    }
}
