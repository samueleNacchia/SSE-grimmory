package org.booklore.config;

import jakarta.persistence.PostPersist;
import jakarta.persistence.PostRemove;
import jakarta.persistence.PostUpdate;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.cache.Cache;
import org.springframework.cache.CacheManager;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

@Component
public class BookCacheEvictionListener {

    private static CacheManager cacheManager;

    @Autowired
    public void setCacheManager(CacheManager manager) {
        BookCacheEvictionListener.cacheManager = manager;
    }

    @PostPersist
    @PostUpdate
    @PostRemove
    public void onBookMutated(Object entity) {
        if (TransactionSynchronizationManager.isActualTransactionActive()) {
            TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
                @Override
                public void afterCommit() {
                    evictBooksListView();
                }
            });
        } else {
            evictBooksListView();
        }
    }

    public static void evictBooksListView() {
        if (cacheManager != null) {
            Cache dtoCache = cacheManager.getCache(CacheConfig.BOOKS_LIST_VIEW_CACHE);
            if (dtoCache != null) {
                dtoCache.clear();
            }
            Cache jsonCache = cacheManager.getCache(CacheConfig.BOOKS_LIST_VIEW_JSON_CACHE);
            if (jsonCache != null) {
                jsonCache.clear();
            }
        }
    }
}