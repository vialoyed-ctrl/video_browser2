package io.flutter.plugins.videoplayer;

import static org.junit.Assert.*;
import static org.mockito.Mockito.*;
import android.content.Context;
import android.os.Looper;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.platform.PlatformViewRegistry;
import io.flutter.view.TextureRegistry;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.mockito.MockedStatic;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.Shadows;
import org.robolectric.annotation.LooperMode;

@RunWith(RobolectricTestRunner.class)
@LooperMode(LooperMode.Mode.PAUSED)
public class PreloadChannelOwnershipTest {
  private void call(VideoPlayerPlugin plugin, String name, Object arguments) throws Exception {
    Method method = VideoPlayerPlugin.class.getDeclaredMethod("handleMedia3CacheCall",
        MethodCall.class, MethodChannel.Result.class, Context.class);
    method.setAccessible(true);
    method.invoke(plugin, new MethodCall(name, arguments), mock(MethodChannel.Result.class),
        RuntimeEnvironment.getApplication());
  }
  private void check(String mode) throws Exception {
    boolean cancel = mode.equals("cancel") || mode.equals("cancelAll");
    boolean replace = mode.equals("replace");
    boolean terminal = mode.equals("success") || mode.equals("error");
    VideoPlayerPlugin plugin = new VideoPlayerPlugin();
    FlutterPlugin.FlutterPluginBinding binding = mock(FlutterPlugin.FlutterPluginBinding.class);
    if (mode.equals("detach")) {
      when(binding.getApplicationContext()).thenReturn(RuntimeEnvironment.getApplication());
      when(binding.getBinaryMessenger()).thenReturn(mock(BinaryMessenger.class));
      when(binding.getTextureRegistry()).thenReturn(mock(TextureRegistry.class));
      when(binding.getPlatformViewRegistry()).thenReturn(mock(PlatformViewRegistry.class));
      plugin.onAttachedToEngine(binding);
    }
    MethodChannel channel = mock(MethodChannel.class);
    Field field = VideoPlayerPlugin.class.getDeclaredField("media3CacheChannel");
    field.setAccessible(true); field.set(plugin, channel);
    List<Media3Preloader.Listener> listeners = new ArrayList<>();
    try (MockedStatic<Media3Preloader> nativeBoundary = mockStatic(Media3Preloader.class, invocation -> {
      if (invocation.getMethod().getName().equals("enqueue")) {
        listeners.add(invocation.getArgument(10));
      }
      return RETURNS_DEFAULTS.answer(invocation);
    })) {
      Map<String,Object> args = new HashMap<>();
      args.put("taskId", "queued"); args.put("url", "https://example.invalid/neutral.mp4");
      call(plugin, "preload", args);
      assertEquals(1, listeners.size());
      listeners.get(0).onPreloadProgress("queued", 100, 20, 20, mode.equals("success"),
          mode.equals("error") ? "neutral-error" : null);
      if (cancel) call(plugin, mode.equals("cancelAll") ? "cancelAllPreloads" : "cancelPreload", "queued");
      if (replace) call(plugin, "preload", args);
      if (mode.equals("detach")) {
        plugin.onDetachedFromEngine(binding);
        // Reattachment must not deliver queued events from the previous engine.
        plugin.onAttachedToEngine(binding);
        field.set(plugin, channel);
      }
      Shadows.shadowOf(Looper.getMainLooper()).idle();
      if (cancel || replace || mode.equals("detach")) verify(channel, never()).invokeMethod(eq("preloadProgress"), any());
      else verify(channel).invokeMethod(eq("preloadProgress"), any());
      if (cancel || terminal || mode.equals("detach")) {
        Field owners = VideoPlayerPlugin.class.getDeclaredField("preloadOwners");
        owners.setAccessible(true);
        assertTrue("Ended requests must release their tokens", ((Map<?, ?>) owners.get(plugin)).isEmpty());
      }
      if (terminal) {
        listeners.get(0).onPreloadProgress("queued", 100, 30, 30, false, null);
        Shadows.shadowOf(Looper.getMainLooper()).idle();
        verify(channel, times(1)).invokeMethod(eq("preloadProgress"), any());
      }
      if (replace) {
        listeners.get(1).onPreloadProgress("queued", 100, 60, 60, false, null);
        Shadows.shadowOf(Looper.getMainLooper()).idle();
        verify(channel).invokeMethod(eq("preloadProgress"), any());
      }
    }
  }
  @Test public void queuedProgressIsDroppedAfterCancellation() throws Exception { check("cancel"); }
  @Test public void queuedOldProgressIsDroppedAfterReplacement() throws Exception { check("replace"); }
  @Test public void currentProgressIsDelivered() throws Exception { check("current"); }
  @Test public void cancelAllDropsQueuedProgressAndReleasesTokens() throws Exception { check("cancelAll"); }
  @Test public void successReleasesTokenAndRejectsLaterEvents() throws Exception { check("success"); }
  @Test public void errorReleasesTokenAndRejectsLaterEvents() throws Exception { check("error"); }
  @Test public void detachedEngineEventsCannotReachReattachedChannel() throws Exception { check("detach"); }
}

