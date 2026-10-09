// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.util.LongSparseArray;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.OptIn;
import androidx.media3.common.C;
import androidx.media3.common.util.UnstableApi;
import io.flutter.FlutterInjector;
import io.flutter.Log;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.Result;
import io.flutter.plugins.videoplayer.platformview.PlatformVideoViewFactory;
import io.flutter.plugins.videoplayer.platformview.PlatformViewVideoPlayer;
import io.flutter.plugins.videoplayer.texture.TextureVideoPlayer;
import io.flutter.view.TextureRegistry;
import java.util.HashMap;
import java.util.Map;

/** Android platform implementation of the VideoPlayerPlugin. */
public class VideoPlayerPlugin implements FlutterPlugin, AndroidVideoPlayerApi {
  private static final String TAG = "VideoPlayerPlugin";
  private final LongSparseArray<VideoPlayer> videoPlayers = new LongSparseArray<>();
  private FlutterState flutterState;
  @Nullable private MethodChannel media3CacheChannel;
  private final VideoPlayerOptions sharedOptions = new VideoPlayerOptions();
  private long nextPlayerIdentifier = 1;

  /** Preload progress originates on a worker thread; channel replies must run on the main one. */
  private final Handler mainHandler = new Handler(Looper.getMainLooper());

  /** Register this with the v2 embedding for the plugin to respond to lifecycle callbacks. */
  public VideoPlayerPlugin() {}

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    final FlutterInjector injector = FlutterInjector.instance();
    this.flutterState =
        new FlutterState(
            binding.getApplicationContext(),
            binding.getBinaryMessenger(),
            injector.flutterLoader()::getLookupKeyForAsset,
            injector.flutterLoader()::getLookupKeyForAsset,
            binding.getTextureRegistry());
    flutterState.startListening(this, binding.getBinaryMessenger());

    media3CacheChannel =
        new MethodChannel(binding.getBinaryMessenger(), "video_browser/media3_cache");
    media3CacheChannel.setMethodCallHandler(
        (call, result) -> handleMedia3CacheCall(call, result, binding.getApplicationContext()));

    binding
        .getPlatformViewRegistry()
        .registerViewFactory(
            "plugins.flutter.dev/video_player_android",
            new PlatformVideoViewFactory(videoPlayers::get));
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    if (flutterState == null) {
      Log.wtf(TAG, "Detached from the engine before registering to it.");
    }
    flutterState.stopListening(binding.getBinaryMessenger());
    if (media3CacheChannel != null) {
      media3CacheChannel.setMethodCallHandler(null);
      media3CacheChannel = null;
    }
    flutterState = null;
    onDestroy();
  }

  @OptIn(markerClass = UnstableApi.class)
  private void handleMedia3CacheCall(
      @NonNull MethodCall call, @NonNull Result result, @NonNull Context context) {
    if ("setScrubbingMode".equals(call.method)) {
      if (!(call.arguments instanceof Map)) {
        result.error("invalid_scrubbing_mode", "Expected playerId and enabled", null);
        return;
      }
      final Map<?, ?> args = (Map<?, ?>) call.arguments;
      final Object rawPlayerId = args.get("playerId");
      final Object rawEnabled = args.get("enabled");
      if (!(rawPlayerId instanceof Number) || !(rawEnabled instanceof Boolean)) {
        result.error("invalid_scrubbing_mode", "Expected numeric playerId and boolean enabled", null);
        return;
      }
      final VideoPlayer player = videoPlayers.get(((Number) rawPlayerId).longValue());
      if (player == null) {
        result.error("player_not_found", "The video player is no longer active", null);
        return;
      }
      try {
        player.setScrubbingMode((Boolean) rawEnabled);
        result.success(null);
      } catch (RuntimeException error) {
        result.error("scrubbing_mode_failed", error.getMessage(), null);
      }
      return;
    }
    if ("setMaxCacheBytes".equals(call.method)) {
      if (!(call.arguments instanceof Number)) {
        result.error("invalid_cache_limit", "Expected cache size in bytes", null);
        return;
      }
      Media3PlaybackCache.setMaxCacheBytes(((Number) call.arguments).longValue());
      result.success(null);
      return;
    }
    if ("getCacheSizeBytes".equals(call.method)) {
      Media3PlaybackCache.getCacheSpace(
          context,
          (bytes, error) ->
              mainHandler.post(
                  () -> {
                    if (error == null) {
                      result.success(bytes);
                    } else {
                      result.error("cache_size_failed", error.getMessage(), null);
                    }
                  }));
      return;
    }
    if ("clear".equals(call.method)) {
      Media3PlaybackCache.clear(
          context,
          error -> {
            if (error == null) {
              result.success(null);
            } else {
              result.error("cache_clear_failed", error.getMessage(), null);
            }
          });
      return;
    }
    if ("preload".equals(call.method)) {
      handlePreload(call, result, context);
      return;
    }
    if ("cancelPreload".equals(call.method)) {
      final String taskId = asString(call.arguments);
      if (taskId == null || taskId.isEmpty()) {
        result.error("invalid_task_id", "Expected a preload task id", null);
        return;
      }
      Media3Preloader.cancel(taskId);
      result.success(null);
      return;
    }
    if ("cancelAllPreloads".equals(call.method)) {
      Media3Preloader.cancelAll();
      result.success(null);
      return;
    }
    if ("getPreloadStatus".equals(call.method)) {
      result.success(Media3Preloader.activeTaskCount());
      return;
    }
    result.notImplemented();
  }

  /**
   * Queues one preload into the shared playback cache.
   *
   * <p>Arguments arrive as a map so the contract can grow without a new channel. Only {@code taskId}
   * and {@code url} are required.
   */
  private void handlePreload(
      @NonNull MethodCall call, @NonNull Result result, @NonNull Context context) {
    if (!(call.arguments instanceof Map)) {
      result.error("invalid_preload", "Expected a map of preload arguments", null);
      return;
    }
    final Map<?, ?> args = (Map<?, ?>) call.arguments;
    final String taskId = asString(args.get("taskId"));
    final String url = asString(args.get("url"));
    if (taskId == null || taskId.isEmpty() || url == null || url.isEmpty()) {
      result.error("invalid_preload", "Both taskId and url are required", null);
      return;
    }

    final Map<String, String> headers = new HashMap<>();
    final Object rawHeaders = args.get("headers");
    if (rawHeaders instanceof Map) {
      for (Map.Entry<?, ?> entry : ((Map<?, ?>) rawHeaders).entrySet()) {
        if (entry.getKey() instanceof String && entry.getValue() instanceof String) {
          headers.put((String) entry.getKey(), (String) entry.getValue());
        }
      }
    }

    Media3Preloader.enqueue(
        context,
        taskId,
        url,
        headers,
        asString(args.get("userAgent")),
        asBoolean(args.get("isHls"), false),
        asInt(args.get("variantIndex"), 0),
        asLong(args.get("positionBytes"), 0L),
        asLong(args.get("lengthBytes"), C.LENGTH_UNSET),
        asLong(args.get("durationUs"), C.TIME_UNSET),
        this::emitPreloadProgress);
    result.success(null);
  }

  /**
   * Forwards preload progress to Dart.
   *
   * <p>Callbacks originate on a preload worker thread; {@link MethodChannel#invokeMethod} must run
   * on the platform thread, hence the hop.
   */
  private void emitPreloadProgress(
      String taskId,
      long contentLength,
      long bytesDownloaded,
      float percentDownloaded,
      boolean finished,
      @Nullable String error) {
    final Map<String, Object> payload = new HashMap<>();
    payload.put("taskId", taskId);
    payload.put("contentLength", contentLength);
    payload.put("bytesDownloaded", bytesDownloaded);
    payload.put("percent", (double) percentDownloaded);
    payload.put("finished", finished);
    payload.put("error", error);
    mainHandler.post(
        () -> {
          final MethodChannel channel = media3CacheChannel;
          if (channel != null) {
            channel.invokeMethod("preloadProgress", payload);
          }
        });
  }

  @Nullable
  private static String asString(@Nullable Object value) {
    return value instanceof String ? (String) value : null;
  }

  private static boolean asBoolean(@Nullable Object value, boolean fallback) {
    return value instanceof Boolean ? (Boolean) value : fallback;
  }

  private static int asInt(@Nullable Object value, int fallback) {
    return value instanceof Number ? ((Number) value).intValue() : fallback;
  }

  private static long asLong(@Nullable Object value, long fallback) {
    return value instanceof Number ? ((Number) value).longValue() : fallback;
  }

  private void disposeAllPlayers() {
    for (int i = 0; i < videoPlayers.size(); i++) {
      videoPlayers.valueAt(i).dispose();
    }
    videoPlayers.clear();
  }

  public void onDestroy() {
    // The whole FlutterView is being destroyed. Here we release resources acquired for all
    // instances
    // of VideoPlayer. Once https://github.com/flutter/flutter/issues/19358 is resolved this may
    // be replaced with just asserting that videoPlayers.isEmpty().
    // https://github.com/flutter/flutter/issues/20989 tracks this.
    disposeAllPlayers();
  }

  @Override
  public void initialize() {
    disposeAllPlayers();
  }

  @OptIn(markerClass = UnstableApi.class)
  @Override
  public long createForPlatformView(@NonNull CreationOptions options) {
    final VideoAsset videoAsset = videoAssetWithOptions(options);

    long id = nextPlayerIdentifier++;
    final String streamInstance = Long.toString(id);
    VideoPlayerOptions playerOptions = new VideoPlayerOptions(sharedOptions);
    playerOptions.backBufferDurationMs = options.getBackBufferDurationMs();

    VideoPlayer videoPlayer =
        PlatformViewVideoPlayer.create(
            flutterState.applicationContext,
            VideoPlayerEventCallbacks.bindTo(flutterState.binaryMessenger, streamInstance),
            videoAsset,
            playerOptions);

    registerPlayerInstance(videoPlayer, id);
    return id;
  }

  @OptIn(markerClass = UnstableApi.class)
  @Override
  public @NonNull TexturePlayerIds createForTextureView(@NonNull CreationOptions options) {
    final VideoAsset videoAsset = videoAssetWithOptions(options);

    long id = nextPlayerIdentifier++;
    final String streamInstance = Long.toString(id);
    TextureRegistry.SurfaceProducer handle = flutterState.textureRegistry.createSurfaceProducer();
    VideoPlayerOptions playerOptions = new VideoPlayerOptions(sharedOptions);
    playerOptions.backBufferDurationMs = options.getBackBufferDurationMs();

    VideoPlayer videoPlayer =
        TextureVideoPlayer.create(
            flutterState.applicationContext,
            VideoPlayerEventCallbacks.bindTo(flutterState.binaryMessenger, streamInstance),
            handle,
            videoAsset,
            playerOptions);

    registerPlayerInstance(videoPlayer, id);
    return new TexturePlayerIds(id, handle.id());
  }

  private @NonNull VideoAsset videoAssetWithOptions(@NonNull CreationOptions options) {
    final @NonNull String uri = options.getUri();
    if (uri.startsWith("asset:")) {
      return VideoAsset.fromAssetUrl(uri);
    } else if (uri.startsWith("rtsp:")) {
      return VideoAsset.fromRtspUrl(uri);
    } else {
      VideoAsset.StreamingFormat streamingFormat = VideoAsset.StreamingFormat.UNKNOWN;
      PlatformVideoFormat formatHint = options.getFormatHint();
      if (formatHint != null) {
        switch (formatHint) {
          case SS:
            streamingFormat = VideoAsset.StreamingFormat.SMOOTH;
            break;
          case DASH:
            streamingFormat = VideoAsset.StreamingFormat.DYNAMIC_ADAPTIVE;
            break;
          case HLS:
            streamingFormat = VideoAsset.StreamingFormat.HTTP_LIVE;
            break;
        }
      }
      return VideoAsset.fromRemoteUrl(
          uri, streamingFormat, options.getHttpHeaders(), options.getUserAgent());
    }
  }

  private void registerPlayerInstance(VideoPlayer player, long id) {
    // Set up the instance-specific API handler, and make sure it is removed when the player is
    // disposed.
    BinaryMessenger messenger = flutterState.binaryMessenger;
    final String channelSuffix = Long.toString(id);
    VideoPlayerInstanceApi.Companion.setUp(messenger, player, channelSuffix);
    player.setDisposeHandler(
        () -> VideoPlayerInstanceApi.Companion.setUp(messenger, null, channelSuffix));

    videoPlayers.put(id, player);
  }

  @NonNull
  private VideoPlayer getPlayer(long playerId) {
    VideoPlayer player = videoPlayers.get(playerId);

    // Avoid a very ugly un-debuggable NPE that results in returning a null player.
    if (player == null) {
      String message = "No player found with playerId <" + playerId + ">";
      if (videoPlayers.size() == 0) {
        message += " and no active players created by the plugin.";
      }
      throw new IllegalStateException(message);
    }

    return player;
  }

  @Override
  public void dispose(long playerId) {
    VideoPlayer player = getPlayer(playerId);
    player.dispose();
    videoPlayers.remove(playerId);
  }

  @Override
  public void setMixWithOthers(boolean mixWithOthers) {
    sharedOptions.mixWithOthers = mixWithOthers;
  }

  @Override
  public @NonNull String getLookupKeyForAsset(@NonNull String asset, @Nullable String packageName) {
    return packageName == null
        ? flutterState.keyForAsset.get(asset)
        : flutterState.keyForAssetAndPackageName.get(asset, packageName);
  }

  private interface KeyForAssetFn {
    String get(String asset);
  }

  private interface KeyForAssetAndPackageName {
    String get(String asset, String packageName);
  }

  private static final class FlutterState {
    final Context applicationContext;
    final BinaryMessenger binaryMessenger;
    final KeyForAssetFn keyForAsset;
    final KeyForAssetAndPackageName keyForAssetAndPackageName;
    final TextureRegistry textureRegistry;

    FlutterState(
        Context applicationContext,
        BinaryMessenger messenger,
        KeyForAssetFn keyForAsset,
        KeyForAssetAndPackageName keyForAssetAndPackageName,
        TextureRegistry textureRegistry) {
      this.applicationContext = applicationContext;
      this.binaryMessenger = messenger;
      this.keyForAsset = keyForAsset;
      this.keyForAssetAndPackageName = keyForAssetAndPackageName;
      this.textureRegistry = textureRegistry;
    }

    void startListening(VideoPlayerPlugin methodCallHandler, BinaryMessenger messenger) {
      AndroidVideoPlayerApi.Companion.setUp(messenger, methodCallHandler);
    }

    void stopListening(BinaryMessenger messenger) {
      AndroidVideoPlayerApi.Companion.setUp(messenger, null);
    }
  }
}
