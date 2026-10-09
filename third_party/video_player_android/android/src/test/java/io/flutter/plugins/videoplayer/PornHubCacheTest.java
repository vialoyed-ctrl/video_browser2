package io.flutter.plugins.videoplayer;

import static org.junit.Assert.*;
import static org.mockito.Mockito.mock;
import androidx.media3.exoplayer.offline.Downloader;
import java.time.Duration;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.shadows.ShadowSystemClock;

@RunWith(RobolectricTestRunner.class)
public class PornHubCacheTest {
  @Test public void freshCdnSignaturesReuseTheSameSegment() {
    String first = "https://im-h.phncdn.com/token1,100/hls/c6251/videos/202609/17/123/1080.mp4/seg-1.ts?hdnea=old";
    String fresh = "https://em-h.phncdn.com/hls/c6251/videos/202609/17/123/1080.mp4/seg-1.ts?validto=200&hash=new";
    assertEquals(Media3CacheKeyFactory.normalize(first), Media3CacheKeyFactory.normalize(fresh));
    assertNotEquals(Media3CacheKeyFactory.normalize(first), Media3CacheKeyFactory.normalize(fresh.replace("seg-1", "seg-2")));
    assertNotEquals(Media3CacheKeyFactory.normalize(first), Media3CacheKeyFactory.normalize(fresh.replace("1080", "720")));
    assertNotEquals(Media3CacheKeyFactory.normalize(first), Media3CacheKeyFactory.normalize(fresh.replace("/123/", "/456/")));
  }

  @Test public void manifestsRetainTheirFreshSignedReferences() {
    String manifest = "https://im-h.phncdn.com/token,100/hls/c/videos/123/master.m3u8?hash=new";
    assertEquals(manifest, Media3CacheKeyFactory.normalize(manifest));
    assertEquals("https://other.example/videos/movie.ts?quality=1080", Media3CacheKeyFactory.normalize("https://other.example/videos/movie.ts?quality=1080"));
  }

  @Test public void byteCallbacksAreBoundedAndCancelledJobsStopReporting() {
    Media3Preloader.Entry entry = new Media3Preloader.Entry("ph", mock(Downloader.class), true);
    assertTrue(entry.shouldReport(100000, 1, 0));
    for (int i = 2; i <= 10000; i++) assertFalse(entry.shouldReport(100000, i, 10));
    assertEquals(10000, entry.bytesDownloaded);
    ShadowSystemClock.advanceBy(Duration.ofMillis(250));
    assertTrue(entry.shouldReport(100000, 20000, 20));
    entry.cancelled = true;
    ShadowSystemClock.advanceBy(Duration.ofMillis(250));
    assertFalse(entry.shouldReport(100000, 30000, 30));
  }
}
