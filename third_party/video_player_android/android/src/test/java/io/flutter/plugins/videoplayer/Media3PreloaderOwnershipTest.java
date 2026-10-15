package io.flutter.plugins.videoplayer;

import static org.junit.Assert.*;
import static org.mockito.Mockito.*;
import androidx.media3.exoplayer.offline.Downloader;
import androidx.media3.exoplayer.hls.offline.HlsDownloader;
import androidx.media3.exoplayer.offline.ProgressiveDownloader;
import java.io.IOException;
import java.lang.reflect.Field;
import java.util.Collections;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.mockito.MockedConstruction;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;

@RunWith(RobolectricTestRunner.class)
public class Media3PreloaderOwnershipTest {
  private static ThreadPoolExecutor drivers() throws Exception {
    Field f = Media3Preloader.class.getDeclaredField("DRIVER_EXECUTOR");
    f.setAccessible(true); return (ThreadPoolExecutor) f.get(null);
  }
  private static void awaitCompleted(ThreadPoolExecutor pool, long count) throws Exception {
    long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
    while (pool.getCompletedTaskCount() < count) {
      assertTrue("Native worker did not finish", System.nanoTime() < deadline);
      Thread.sleep(5);
    }
  }
  private static void enqueue(String id, String file, Media3Preloader.Listener listener) {
    Media3Preloader.enqueue(RuntimeEnvironment.getApplication(), id,
        "https://example.invalid/" + file + ".mp4", Collections.emptyMap(), null,
        false, 0, 0, 0, 0, listener);
  }
  @Test public void cancelledOrdinaryMp4DoesNotReportLateFailure() throws Exception {
    CountDownLatch started = new CountDownLatch(1), release = new CountDownLatch(1);
    ConcurrentLinkedQueue<String> errors = new ConcurrentLinkedQueue<>();
    ThreadPoolExecutor pool = drivers(); long before = pool.getCompletedTaskCount();
    try (MockedConstruction<ProgressiveDownloader> construction =
        mockConstruction(ProgressiveDownloader.class, (mock, context) -> {
          doAnswer(call -> { started.countDown(); assertTrue(release.await(5, TimeUnit.SECONDS));
            throw new IOException("neutral-late-failure"); }).when(mock).download(any());
        })) {
      enqueue("cancel", "old", (id, length, bytes, percent, finished, error) -> {
        if (error != null) errors.add(error);
      });
      assertTrue(started.await(5, TimeUnit.SECONDS));
      Media3Preloader.cancel("cancel"); release.countDown(); awaitCompleted(pool, before + 1);
      assertTrue("Canceled preload must not publish its late error", errors.isEmpty());
    } finally { release.countDown(); Media3Preloader.cancel("cancel"); }
  }
  @Test public void replacementDoesNotReceiveOldFailureAndStillFinishes() throws Exception {
    CountDownLatch oldStarted = new CountDownLatch(1), newStarted = new CountDownLatch(1);
    CountDownLatch oldRelease = new CountDownLatch(1), newRelease = new CountDownLatch(1);
    ConcurrentLinkedQueue<String> errors = new ConcurrentLinkedQueue<>();
    AtomicInteger finishes = new AtomicInteger(), latestBytes = new AtomicInteger();
    ThreadPoolExecutor pool = drivers(); long before = pool.getCompletedTaskCount();
    try (MockedConstruction<ProgressiveDownloader> construction =
        mockConstruction(ProgressiveDownloader.class, (mock, context) -> {
          boolean old = context.getCount() == 1;
          doAnswer(call -> {
            if (old) { oldStarted.countDown(); assertTrue(oldRelease.await(5, TimeUnit.SECONDS));
              throw new IOException("neutral-old-failure"); }
            Downloader.ProgressListener progress = call.getArgument(0);
            progress.onProgress(100, 60, 60); newStarted.countDown();
            assertTrue(newRelease.await(5, TimeUnit.SECONDS)); return null;
          }).when(mock).download(any());
        })) {
      Media3Preloader.Listener listener = (id, length, bytes, percent, finished, error) -> {
        if (error != null) errors.add(error);
        if (!finished) latestBytes.set((int) bytes);
        if (finished) finishes.incrementAndGet();
      };
      enqueue("replace", "old", listener); assertTrue(oldStarted.await(5, TimeUnit.SECONDS));
      enqueue("replace", "new", listener); assertTrue(newStarted.await(5, TimeUnit.SECONDS));
      assertEquals(60, latestBytes.get());
      oldRelease.countDown(); awaitCompleted(pool, before + 1);
      assertTrue("Old failure must not overwrite replacement progress", errors.isEmpty());
      assertEquals(1, Media3Preloader.activeTaskCount());
      newRelease.countDown(); awaitCompleted(pool, before + 2);
      assertEquals(1, finishes.get()); assertEquals(0, Media3Preloader.activeTaskCount());
    } finally { oldRelease.countDown(); newRelease.countDown(); Media3Preloader.cancel("replace"); }
  }
  @Test public void currentFailureStillReports() throws Exception {
    ConcurrentLinkedQueue<String> errors = new ConcurrentLinkedQueue<>();
    ThreadPoolExecutor pool = drivers(); long before = pool.getCompletedTaskCount();
    try (MockedConstruction<ProgressiveDownloader> construction =
        mockConstruction(ProgressiveDownloader.class, (mock, context) -> {
          doThrow(new IOException("neutral-current-failure")).when(mock).download(any());
        })) {
      enqueue("failure", "current", (id, length, bytes, percent, finished, error) -> {
        if (error != null) errors.add(error);
      });
      awaitCompleted(pool, before + 1); assertEquals(1, errors.size());
    } finally { Media3Preloader.cancel("failure"); }
  }
  @Test public void currentSuccessStillReportsFinished() throws Exception {
    AtomicInteger finishes = new AtomicInteger();
    ThreadPoolExecutor pool = drivers(); long before = pool.getCompletedTaskCount();
    try (MockedConstruction<ProgressiveDownloader> construction =
        mockConstruction(ProgressiveDownloader.class)) {
      enqueue("success", "current", (id, length, bytes, percent, finished, error) -> {
        assertNull(error); if (finished) finishes.incrementAndGet();
      });
      awaitCompleted(pool, before + 1); assertEquals(1, finishes.get());
    } finally { Media3Preloader.cancel("success"); }
  }
  @Test public void cancelledHlsDoesNotReportLateFailure() throws Exception {
    CountDownLatch started = new CountDownLatch(1), release = new CountDownLatch(1);
    ConcurrentLinkedQueue<String> errors = new ConcurrentLinkedQueue<>();
    ThreadPoolExecutor pool = drivers(); long before = pool.getCompletedTaskCount();
    HlsDownloader downloader = mock(HlsDownloader.class);
    doAnswer(call -> {
      started.countDown(); assertTrue(release.await(5, TimeUnit.SECONDS));
      throw new IOException("neutral-hls-late-failure");
    }).when(downloader).download(any());
    try (MockedConstruction<HlsDownloader.Factory> construction =
        mockConstruction(HlsDownloader.Factory.class, withSettings().defaultAnswer(RETURNS_SELF),
            (factory, context) -> when(factory.create(any())).thenReturn(downloader))) {
      Media3Preloader.enqueue(RuntimeEnvironment.getApplication(), "hls-cancel",
          "https://example.invalid/neutral.m3u8", Collections.emptyMap(), null,
          true, 0, 0, 0, 0, (id, length, bytes, percent, finished, error) -> {
            if (error != null) errors.add(error);
          });
      assertTrue(started.await(5, TimeUnit.SECONDS));
      Media3Preloader.cancel("hls-cancel");
      verify(downloader).cancel(); release.countDown(); awaitCompleted(pool, before + 1);
      assertTrue("Canceled HLS must not publish its late error", errors.isEmpty());
    } finally { release.countDown(); Media3Preloader.cancel("hls-cancel"); }
  }
}
