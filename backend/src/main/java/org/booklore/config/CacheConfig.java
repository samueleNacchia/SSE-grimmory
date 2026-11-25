package org.booklore.config;

import com.github.benmanes.caffeine.cache.Caffeine;
import org.springframework.cache.CacheManager;
import org.springframework.cache.annotation.EnableCaching;
import org.springframework.cache.caffeine.CaffeineCacheManager;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import java.time.Duration;

@Configuration
@EnableCaching
public class CacheConfig {

    public static final String BOOKS_LIST_VIEW_CACHE = "booksListView";
    public static final String BOOKS_LIST_VIEW_JSON_CACHE = "booksListViewJson";

    @Bean
    public CacheManager cacheManager() {
        CaffeineCacheManager manager = new CaffeineCacheManager(
                BOOKS_LIST_VIEW_CACHE,
                BOOKS_LIST_VIEW_JSON_CACHE
        );
        manager.setCaffeine(Caffeine.newBuilder()
                .maximumSize(200)
                .expireAfterWrite(Duration.ofMinutes(10)));
        return manager;
    }
}