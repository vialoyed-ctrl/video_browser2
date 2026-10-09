package io.flutter.plugins.videoplayer;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.media3.common.C;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.datasource.DataSource;
import androidx.media3.datasource.cache.Cache;
import androidx.media3.datasource.cache.CacheDataSource;
import androidx.media3.datasource.cache.CacheEvictor;
import androidx.media3.datasource.cache.CacheSpan;
import androidx.media3.datasource.cache.SimpleCache;
import androidx.media3.database.StandaloneDatabaseProvider;
import java.io.File;
import java.util.NavigableSet;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Shared bounded disk cache for network playback. */
@UnstableApi
final class Media3PlaybackCache {
  private static final String TAG = "VideoPlayerCache";
  private static final long MIB = 1024L * 1024L;
  private static final long DEFAULT_MAX_CACHE_BYTES = 500L * MIB;
  private static final long MIN_CACHE_BYTES = 50L * MIB;
  private static final long MAX_CACHE_BYTES = 4096L * MIB;
  private static final String CACHE_DIRECTORY = "video_browser_media3";
  private static final ExecutorService CACHE_EXECUTOR =
      Executors.newSingleThreadExecutor(runnable -> {
        Thread thread = new Thread(runnable, "media3-cache-maintenance");
        thread.setDaemon(true);
        return thread;
      });
  private static final Handler MAIN_HANDLER = new Handler(Looper.getMainLooper());

  @Nullable private static Cache cache;
  @Nullable private static MutableLruCacheEvictor evictor;
  private static long maxCacheBytes = DEFAULT_MAX_CACHE_BYTES;

  private Media3PlaybackCache() {}

  @NonNull
  static DataSource.Factory wrap(@NonNull Context context, @NonNull DataSource.Factory upstream) {
    try {
      CacheDataSource.Factory factory =
          new CacheDataSource.Factory()
              .setCache(getCache(context))
              .setUpstreamDataSourceFactory(upstream)
              // Re-signed URLs must map back onto the bytes already on disk, otherwise the
              // cache only ever grows and never gets reused across sessions.
              .setCacheKeyFactory(Media3CacheKeyFactory.INSTANCE)
              // A damaged or unavailable cache must never prevent network playback.
              .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR);
      return factory;
    } catch (Exception error) {
      Log.w(TAG, "Disk cache unavailable; using the network data source", error);
      return upstream;
    }
  }

  /**
   * Builds a {@link CacheDataSource.Factory} for writing into the shared playback cache.
   *
   * <p>Used by {@link Media3Preloader}: the downloader and the player must agree on both the cache
   * instance and the key factory, otherwise preloaded bytes land under a key the player never
   * looks up.
   *
   * @param context application context, used to reach the shared cache.
   * @param upstream the network data source, already carrying the source's Referer/UA headers.
   */
  @NonNull
  static CacheDataSource.Factory createCacheDataSourceFactory(
      @NonNull Context context, @NonNull DataSource.Factory upstream) {
    return new CacheDataSource.Factory()
        .setCache(getCache(context))
        .setUpstreamDataSourceFactory(upstream)
        .setCacheKeyFactory(Media3CacheKeyFactory.INSTANCE)
        .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR);
  }

  static synchronized void setMaxCacheBytes(long requestedBytes) {
    maxCacheBytes = Math.max(MIN_CACHE_BYTES, Math.min(requestedBytes, MAX_CACHE_BYTES));
    Cache currentCache = cache;
    MutableLruCacheEvictor currentEvictor = evictor;
    if (currentCache != null && currentEvictor != null) {
      long newLimit = maxCacheBytes;
      CACHE_EXECUTOR.execute(() -> currentEvictor.setMaxBytes(currentCache, newLimit));
    }
  }

  static void clear(Context context, @NonNull ClearCallback callback) {
    CACHE_EXECUTOR.execute(
        () -> {
          Exception failure = null;
          try {
            Cache currentCache;
            synchronized (Media3PlaybackCache.class) {
              currentCache = cache;
            }
            if (currentCache == null) {
              deleteRecursively(new File(context.getCacheDir(), CACHE_DIRECTORY));
            } else {
              for (String key : currentCache.getKeys()) {
                currentCache.removeResource(key);
              }
            }
          } catch (Exception error) {
            failure = error;
          }
          Exception result = failure;
          MAIN_HANDLER.post(() -> callback.onComplete(result));
        });
  }

  /** Reads the shared cache size off the platform thread. SimpleCache may need to be restored
   * from its on-disk database on the first query, so callers must not run this synchronously on
   * the UI thread. */
  static void getCacheSpace(
      @NonNull Context context, @NonNull CacheSpaceCallback callback) {
    CACHE_EXECUTOR.execute(
        () -> {
          try {
            final long bytes = getCache(context).getCacheSpace();
            callback.onComplete(bytes, null);
          } catch (Exception error) {
            callback.onComplete(0L, error);
          }
        });
  }

  @NonNull
  private static synchronized Cache getCache(@NonNull Context context) {
    if (cache == null) {
      File directory = new File(context.getCacheDir(), CACHE_DIRECTORY);
      MutableLruCacheEvictor newEvictor = new MutableLruCacheEvictor(maxCacheBytes);
      cache =
          new SimpleCache(
              directory,
              newEvictor,
              new StandaloneDatabaseProvider(context.getApplicationContext()));
      evictor = newEvictor;
      // Enforce a limit on entries restored from the previous app process.
      newEvictor.evictToLimit(cache);
      Log.i(TAG, "Media3 playback disk cache ready (max " + (maxCacheBytes / MIB) + " MiB)");
    }
    return cache;
  }

  private static void deleteRecursively(@NonNull File file) {
    File[] children = file.listFiles();
    if (children != null) {
      for (File child : children) deleteRecursively(child);
    }
    if (file.exists() && !file.delete()) {
      throw new IllegalStateException("Unable to remove cache entry: " + file);
    }
  }

  interface ClearCallback {
    void onComplete(@Nullable Exception error);
  }

  interface CacheSpaceCallback {
    void onComplete(long bytes, @Nullable Exception error);
  }

  /** A small mutable LRU evictor so the existing cache-size setting applies. */
  private static final class MutableLruCacheEvictor implements CacheEvictor {
    private volatile long maxBytes;

    MutableLruCacheEvictor(long maxBytes) {
      this.maxBytes = maxBytes;
    }

    synchronized void setMaxBytes(Cache cache, long value) {
      maxBytes = value;
      evictToLimit(cache);
    }

    @Override
    public void onCacheInitialized() {}

    @Override
    public void onStartFile(Cache cache, String key, long position, long length) {
      evict(cache, length == C.LENGTH_UNSET ? 0 : Math.max(0, length));
    }

    @Override
    public void onSpanAdded(Cache cache, CacheSpan span) {
      evict(cache, 0);
    }

    @Override
    public void onSpanRemoved(Cache cache, CacheSpan span) {}

    @Override
    public void onSpanTouched(Cache cache, CacheSpan oldSpan, CacheSpan newSpan) {}

    @Override
    public boolean requiresCacheSpanTouches() {
      return true;
    }

    synchronized void evictToLimit(Cache cache) {
      evict(cache, 0);
    }

    private void evict(Cache cache, long incomingBytes) {
      while (cache.getCacheSpace() + incomingBytes > maxBytes) {
        CacheSpan oldest = null;
        Set<String> keys = cache.getKeys();
        for (String key : keys) {
          NavigableSet<CacheSpan> spans = cache.getCachedSpans(key);
          for (CacheSpan span : spans) {
            if (oldest == null || span.lastTouchTimestamp < oldest.lastTouchTimestamp) {
              oldest = span;
            }
          }
        }
        if (oldest == null) return;
        cache.removeSpan(oldest);
      }
    }
  }
}
