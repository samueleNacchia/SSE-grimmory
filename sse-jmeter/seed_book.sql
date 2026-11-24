USE grimmory;

INSERT IGNORE INTO library (id, name, watch, organization_mode, metadata_source)
VALUES (1, 'Benchmark Library', 0, 'BOOK_PER_FILE', 'EMBEDDED');

INSERT IGNORE INTO library_path (id, library_id, path)
VALUES (1, 1, '/books');

INSERT IGNORE INTO author (id, name) VALUES
(1, 'Isaac Asimov'), (2, 'Ursula K. Le Guin'), (3, 'Italo Calvino'),
(4, 'Umberto Eco'), (5, 'Octavia E. Butler'), (6, 'Frank Herbert'),
(7, 'Elena Ferrante'), (8, 'Haruki Murakami'), (9, 'Margaret Atwood'),
(10, 'Primo Levi');

INSERT IGNORE INTO category (id, name) VALUES
(1, 'Science Fiction'), (2, 'Literary Fiction'), (3, 'History'),
(4, 'Philosophy'), (5, 'Fantasy');

INSERT IGNORE INTO tag (id, name) VALUES
(1, 'Classic'), (2, 'Award Winner'), (3, 'Must Read'),
(4, 'Translated'), (5, 'Series'), (6, 'Hardcover');

DROP PROCEDURE IF EXISTS seed_books;
DELIMITER //
CREATE PROCEDURE seed_books()
BEGIN
    DECLARE i INT DEFAULT 1;
    WHILE i <= 1000 DO
        INSERT IGNORE INTO book (id, library_id, library_path_id, read_status, deleted, is_physical)
        VALUES (
            i,
            1,
            1,
            ELT((i MOD 4) + 1, 'UNREAD', 'READING', 'READ', 'PAUSED'),
            0,
            0
        );

        INSERT IGNORE INTO book_metadata (
            book_id, title, subtitle, publisher, published_date, description,
            isbn_13, page_count, language, rating, review_count, series_name, series_number
        )
        VALUES (
            i,
            CONCAT('Benchmark Book Title #', i),
            CONCAT('An analytical study of software sustainability vol. ', i),
            ELT((i MOD 4) + 1, 'Mondadori', 'Einaudi', 'Penguin Classics', 'Tor Books'),
            DATE_ADD('1970-01-01', INTERVAL (i * 15) DAY),
            REPEAT(CONCAT('Detailed synopsis and metadata block for benchmark book ', i, '. '), 8),
            LPAD(CONCAT('9788800', i), 13, '0'),
            150 + (i MOD 650),
            ELT((i MOD 3) + 1, 'en', 'it', 'fr'),
            ROUND(3.0 + ((i MOD 20) / 10.0), 1),
            10 + (i MOD 500),
            IF(i MOD 3 = 0, CONCAT('Chronicles of Series ', (i MOD 25) + 1), NULL),
            IF(i MOD 3 = 0, (i MOD 10) + 1, NULL)
        );

        INSERT IGNORE INTO book_file (book_id, file_name, file_sub_path, file_size_kb, is_book, book_type)
        VALUES (
            i,
            CONCAT('book_', i, '.epub'),
            '/',
            1024 + (i MOD 4096),
            1,
            'EPUB'
        );

        INSERT IGNORE INTO book_metadata_author_mapping (book_id, author_id)
        VALUES (i, (i MOD 10) + 1), (i, ((i + 3) MOD 10) + 1);

        INSERT IGNORE INTO book_metadata_category_mapping (book_id, category_id)
        VALUES (i, (i MOD 5) + 1);

        INSERT IGNORE INTO book_metadata_tag_mapping (book_id, tag_id)
        VALUES (i, (i MOD 6) + 1), (i, ((i + 2) MOD 6) + 1);

        SET i = i + 1;
    END WHILE;
END //
DELIMITER ;

CALL seed_books();
DROP PROCEDURE IF EXISTS seed_books;

SELECT COUNT(*) AS libri_benchmark FROM book WHERE id BETWEEN 1 AND 1000;