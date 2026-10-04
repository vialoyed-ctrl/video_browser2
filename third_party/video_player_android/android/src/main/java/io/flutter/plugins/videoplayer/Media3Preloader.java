// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import android.content.Context;
import android.net.Uri;
import android.os.SystemClock;
import android.util.Log;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.media3.common.C;
import androidx.media3.common.MediaItem;
import androidx.media3.common.StreamKey;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.datasource.DataSource;
import androidx.media3.datasource.DefaultDataSource;
import androidx.media3.datasource.DefaultHttpDataSource;
import androidx.media3.datasource.cache.CacheDataSource;
import androidx.media3.exoplayer.hls.offline.HlsDownloader;
import androidx.media3.exoplayer.hls.playlist.HlsMultivariantPlaylist;
import androidx.media3.exoplayer.offline.Downloader;
import androidx.media3.exoplayer.offline.ProgressiveDownloader;
import java.io.IOException;
import java.io.InterruptedIOException;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Fills the shared Media3 playback cache ahead of playback.
 *
 * <p>Playback itself only ever caches what the decoder happens to read, so the first open of a
 * video is always a cold network start. This class uses Media3's own offline primitives —
 * {@link HlsDownloader} for the 91 HLS source and {@link ProgressiveDownloader} for the Hanime1
 * progressive MP4 source — to write the same bytes into the same {@code SimpleCache} under the
 * same cache key factory that the player reads through. Preloaded bytes are therefore real playback
 * bytes, not a second copy.
 *
 * <p>Two executors are used on purpose. Media3's downloaders submit their internal work to the
 * executor they were constructed with and then <em>block</em> the calling thread until it finishes;
 * running both on one pool would let the drivers starve the workers and deadlock. The driver pool
 * also doubles as the concurrency cap.
 */
@UnstableApi
final class Media3Preloader {

  private static final String TAG = "VideoPlayerPreload";

  /** Reports progress back to the Dart side. */
  interface Listener {
    /**
     * @param taskId the caller supplied task identifier.
     * @param contentLength total bytes, or {@link C#LENGTH_UNSET} when unknown.
     * @param bytesDownloaded bytes currently held in the cache for this resource.
     * @param percentDownloaded 0..100, or {@link C#PERCENTAGE_UNSET} when unknown.
     * @param finished true once the requested window is fully cached.
     * @param error non-null when the download failed.
     */
    void onPreloadProgress(
        String taskId,
        long contentLength,
        long bytesDownloaded,
        float percentDownloaded,
        boolean finished,
        @Nullable String error);
  }

  /** Runs {@link Downloader#download} and blocks on it. Size is the concurrency cap. */
  private static final ExecutorService DRIVER_EXECUTOR =
      Executors.newFixedThreadPool(2, runnable -> newThread(runnable, "media3-preload-driver"));

  /** Runs the downloaders' internal per-segment work. Must not be the driver pool. */
  private static final ExecutorService IO_EXECUTOR =
      Executors.newFixedThreadPool(3, runnable -> newThread(runnable, "media3-preload-io"));

  private static final ExecutorService PORNHUB_IO_EXECUTOR =
      Executors.newFixedThreadPool(6, runnable -> newThread(runnable, "media3-ph-cache-io"));

  private static final Map<String, Entry> TASKS = new ConcurrentHashMap<>();
  private static final AtomicInteger SEQUENCE = new AtomicInteger();

  private Media3Preloader() {}

  @NonNull
  private static Thread newThread(@NonNull Runnable runnable, @NonNull String name) {
    Thread thread = new Thread(runnable, name + "-" + SEQUENCE.incrementAndGet());
    thread.setDaemon(true);
    return thread;
  }

  /**
   * Queues a preload.
   *
   * @param context application context.
   * @param taskId caller supplied identifier, also used to cancel.
   * @param url the media URL as handed to the player (signature included).
   * @param headers request headers, normally User-Agent plus Referer.
   * @param isHls true for an HLS playlist, false for a progressive MP4.
   * @param variantIndex for HLS multivariant playlists, which variant to cache. Ignored for media
   *     playlists, which have no variants to choose between.
   * @param positionBytes for progressive MP4, the byte offset to start from.
   * @param lengthBytes for progressive MP4, how many bytes to cache, or {@link C#LENGTH_UNSET} for
   *     the whole resource.
   * @param durationUs for HLS, how much media to cache from the start, or {@link C#TIME_UNSET} for
   *     the whole playlist.
   * @param listener progress callback, may be null.
   */
  static void enqueue(
      @NonNull Context context,
      @NonNull String taskId,
      @NonNull String url,
      @NonNull Map<String, String> headers,
      @Nullable String userAgent,
      boolean isHls,
      int variantIndex,
      long positionBytes,
      long lengthBytes,
      long durationUs,
      @Nullable Listener listener) {
    if (url.isEmpty()) {
      return;
    }
    // Replacing an in-flight task for the same id keeps a burst of identical requests (list scroll,
    // repeated taps) from stacking redundant downloads of the same resource.
    cancel(taskId);

    final MediaItem mediaItem;
    try {
      mediaItem = buildMediaItem(url, isHls, variantIndex);
    } catch (Exception error) {
      report(listener, taskId, C.LENGTH_UNSET, 0, C.PERCENTAGE_UNSET, false, error.toString());
      return;
    }

    // A non-positive bound means "no bound" on the Dart side, which keeps the channel contract
    // free of Media3's sentinel constants.
    final long effectiveLengthBytes = lengthBytes > 0 ? lengthBytes : C.LENGTH_UNSET;
    final long effectiveDurationUs = durationUs > 0 ? durationUs : C.TIME_UNSET;

    final CacheDataSource.Factory cacheFactory;
    try {
      cacheFactory =
          Media3PlaybackCache.createCacheDataSourceFactory(context, buildUpstream(context, headers, userAgent));
    } catch (Exception error) {
      Log.w(TAG, "Preload cache unavailable for " + taskId, error);
      report(listener, taskId, C.LENGTH_UNSET, 0, C.PERCENTAGE_UNSET, false, error.toString());
      return;
    }

    final String host = Uri.parse(url).getHost();
    final boolean isPornHub = host != null && host.endsWith(".phncdn.com");
    final ExecutorService mediaExecutor = isPornHub ? PORNHUB_IO_EXECUTOR : IO_EXECUTOR;
    final Downloader downloader;
    try {
      downloader =
          isHls
              ? new HlsDownloader.Factory(cacheFactory)
                  .setExecutor(mediaExecutor)
                  .setStartPositionUs(0)
                  .setDurationUs(effectiveDurationUs)
                  .create(mediaItem)
              : new ProgressiveDownloader(
                  mediaItem, cacheFactory, mediaExecutor, positionBytes, effectiveLengthBytes);
    } catch (Exception error) {
      Log.w(TAG, "Could not create preloader for " + taskId, error);
      report(listener, taskId, C.LENGTH_UNSET, 0, C.PERCENTAGE_UNSET, false, error.toString());
      return;
    }

    final Entry entry = new Entry(taskId, downloader, isPornHub);
    TASKS.put(taskId, entry);

    DRIVER_EXECUTOR.execute(
        () -> {
          String failure = null;
          try {
            downloader.download(
                (contentLength, bytesDownloaded, percentDownloaded) -> {
                  if (!entry.shouldReport(contentLength, bytesDownloaded, percentDownloaded)) return;
                  report(
                        listener,
                        taskId,
                        contentLength,
                        bytesDownloaded,
                        percentDownloaded,
                        false,
                        null);
                });
          } catch (InterruptedIOException | InterruptedException interrupted) {
            // Cancelation is a normal outcome, not a failure worth surfacing.
            failure = null;
          } catch (IOException error) {
            if (!entry.throttleProgress || !entry.cancelled) {
              failure = error.toString();
              Log.w(TAG, "Preload failed for " + taskId, error);
            }
          } catch (Exception error) {
            if (!entry.throttleProgress || !entry.cancelled) {
              failure = error.toString();
              Log.w(TAG, "Preload aborted for " + taskId, error);
            }
          } finally {
            // Only the entry that is still registered may clear the slot; a replacement task for
            // the same id owns it otherwise.
            final boolean ownsSlot = TASKS.remove(taskId, entry);
            final boolean mayReport = !entry.throttleProgress || (ownsSlot && !entry.cancelled);
            if (mayReport && failure != null) {
              report(listener, taskId, C.LENGTH_UNSET, 0, C.PERCENTAGE_UNSET, false, failure);
            } else if (mayReport && !entry.cancelled) {
              report(listener, taskId, entry.throttleProgress ? entry.contentLength : C.LENGTH_UNSET,
                  entry.throttleProgress ? entry.bytesDownloaded : 0, 100f, true, null);
            }
          }
        });
  }

  static void cancel(@NonNull String taskId) {
    final Entry entry = TASKS.remove(taskId);
    if (entry == null) {
      return;
    }
    entry.cancelled = true;
    try {
      entry.downloader.cancel();
    } catch (Exception error) {
      Log.w(TAG, "Cancel failed for " + taskId, error);
    }
  }

  static void cancelAll() {
    for (String taskId : TASKS.keySet()) {
      cancel(taskId);
    }
  }

  static int activeTaskCount() {
    return TASKS.size();
  }

  @NonNull
  private static MediaItem buildMediaItem(@NonNull String url, boolean isHls, int variantIndex) {
    MediaItem.Builder builder = new MediaItem.Builder().setUri(url);
    if (isHls) {
      // Restricting to one variant keeps a multivariant playlist from caching every bitrate at
      // once. A media playlist ignores the key entirely (HlsMediaPlaylist.copy returns itself),
      // so the common single-playlist case still gets fully cached.
      List<StreamKey> streamKeys =
          Collections.singletonList(
              new StreamKey(HlsMultivariantPlaylist.GROUP_INDEX_VARIANT, variantIndex));
      builder.setStreamKeys(streamKeys);
    }
    return builder.build();
  }

  @NonNull
  private static DataSource.Factory buildUpstream(
      @NonNull Context context,
      @NonNull Map<String, String> headers,
      @Nullable String userAgent) {
    DefaultHttpDataSource.Factory httpFactory = new DefaultHttpDataSource.Factory();
    if (userAgent != null && !userAgent.isEmpty()) {
      httpFactory.setUserAgent(userAgent);
    }
    httpFactory.setAllowCrossProtocolRedirects(true);
    httpFactory.setConnectTimeoutMs(HTTP_CONNECT_TIMEOUT_MS);
    httpFactory.setReadTimeoutMs(HTTP_READ_TIMEOUT_MS);
    if (!headers.isEmpty()) {
      httpFactory.setDefaultRequestProperties(headers);
    }
    return new DefaultDataSource.Factory(context, httpFactory);
  }

  private static final int HTTP_CONNECT_TIMEOUT_MS = 5000;
  private static final int HTTP_READ_TIMEOUT_MS = 15000;

  private static void report(
      @Nullable Listener listener,
      @NonNull String taskId,
      long contentLength,
      long bytesDownloaded,
      float percentDownloaded,
      boolean finished,
      @Nullable String error) {
    if (listener == null) {
      return;
    }
    try {
      listener.onPreloadProgress(
          taskId, contentLength, bytesDownloaded, percentDownloaded, finished, error);
    } catch (Exception error2) {
      Log.w(TAG, "Progress listener threw for " + taskId, error2);
    }
  }

  static final class Entry {
    final String taskId;
    final Downloader downloader;
    volatile boolean cancelled;
    final boolean throttleProgress;
    volatile long contentLength = C.LENGTH_UNSET;
    volatile long bytesDownloaded;
    private long lastReportMs = -1;
    private long lastLogMs = -1;

    Entry(@NonNull String taskId, @NonNull Downloader downloader, boolean throttleProgress) {
      this.taskId = taskId;
      this.downloader = downloader;
      this.throttleProgress = throttleProgress;
    }

    synchronized boolean shouldReport(long length, long bytes, float percent) {
      if (cancelled) return false;
      contentLength = length;
      bytesDownloaded = bytes;
      final long now = SystemClock.elapsedRealtime();
      if (throttleProgress && lastReportMs >= 0 && now - lastReportMs < 250) return false;
      lastReportMs = now;
      if (throttleProgress && (lastLogMs < 0 || now - lastLogMs >= 5000)) {
        lastLogMs = now;
        Log.i(TAG, "PornHub cache task=" + taskId + " bytes=" + bytes + " percent=" + percent);
      }
      return true;
    }
  }
}
