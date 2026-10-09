// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import android.net.Uri;
import androidx.annotation.NonNull;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.datasource.DataSpec;
import androidx.media3.datasource.cache.CacheKeyFactory;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * A {@link CacheKeyFactory} that survives re-signed media URLs.
 *
 * <p>Both supported content sources hand the player a *time limited* direct URL:
 *
 * <ul>
 *   <li>91 / 91porny style HLS: {@code https://cdn/.../seg_0042.ts?t=1759300000}
 *   <li>Hanime1 progressive MP4: {@code https://vdownload.hembed.com/408437-1080p.mp4?secure=...}
 * </ul>
 *
 * <p>Media3's default key is {@code dataSpec.key != null ? key : dataSpec.uri.toString()}, i.e.
 * the <em>entire</em> URL including the signature. Because the signature is re-issued for every
 * playback session, the same video produced a brand new cache entry each time: the disk cache grew
 * but the second open of the same video never hit it. This factory strips the volatile signature
 * parameters so that a re-signed URL maps back onto the entry that already holds the bytes.
 *
 * <p>The path is deliberately left untouched, so distinct segments keep distinct keys — Media3
 * requires that one cache key identifies one whole resource, and a range request for
 * {@code seg_0042.ts} must not collide with {@code seg_0043.ts}.
 */
@UnstableApi
final class Media3CacheKeyFactory implements CacheKeyFactory {

  /**
   * Query parameter names known to carry a per-request signature rather than resource identity.
   *
   * <p>Kept deliberately small and lower-cased: dropping a parameter that actually selects a
   * different resource would merge two videos into one cache entry, which is far worse than
   * occasionally missing the cache. {@code t} and {@code secure} are the two observed in this app;
   * the rest cover the common CDN conventions.
   */
  private static final Set<String> VOLATILE_QUERY_PARAMS =
      Collections.unmodifiableSet(
          new HashSet<>(
              Arrays.asList(
                  // Observed in this app.
                  "t",
                  "secure",
                  // PornHub HLS direct links: master.m3u8?validfrom=..&validto=..&ipa=1&hdl=-1&hash=..
                  // The signature is re-issued per session, so without these the same video
                  // would land under a new cache key every time it is opened.
                  "validfrom",
                  "validto",
                  "ipa",
                  "hdl",
                  // Common CDN signature conventions.
                  "sign",
                  "signature",
                  "sig",
                  "token",
                  "auth",
                  "expires",
                  "expire",
                  "timestamp",
                  "ts",
                  "nonce",
                  "md5",
                  "hash",
                  "vkey",
                  "wssecret",
                  "wstime",
                  "st",
                  "et",
                  // 91porny style mirrors.
                  "k",
                  "h")));

  /**
   * Extra volatile parameters that are only safe to strip for a specific host.
   *
   * <p>PornHub serves HLS from two different hosts with two different signature schemes:
   *
   * <ul>
   *   <li>{@code ev-h.phncdn.com/.../master.m3u8?validfrom=..&validto=..&ipa=1&hdl=-1&hash=..}
   *   <li>{@code hv-h.phncdn.com/.../master.m3u8?h=<sig>&e=<expiry>&f=1}
   * </ul>
   *
   * <p>The first scheme is fully covered by {@link #VOLATILE_QUERY_PARAMS}. The second is not:
   * {@code h} is listed but {@code e} / {@code f} are not, so every re-sign produced a new cache
   * key and the entry was never reused — the same video re-downloaded from scratch on each open.
   * {@code e} / {@code f} are far too generic to strip globally (another source could use them to
   * select a different resource), so they are scoped to the CDN host they were observed on.
   */
  private static final Map<String, Set<String>> VOLATILE_BY_HOST =
      Collections.unmodifiableMap(
          new HashMap<String, Set<String>>() {
            {
              put(
                  "phncdn.com",
                  Collections.unmodifiableSet(new HashSet<>(Arrays.asList("e", "f"))));
            }
          });

  static final Media3CacheKeyFactory INSTANCE = new Media3CacheKeyFactory();

  private Media3CacheKeyFactory() {}

  /** Returns the extra volatile parameter names that apply to {@code host}. */
  private static Set<String> volatileForHost(@NonNull String host) {
    final String lower = host.toLowerCase(Locale.US);
    for (Map.Entry<String, Set<String>> entry : VOLATILE_BY_HOST.entrySet()) {
      if (lower.endsWith(entry.getKey())) {
        return entry.getValue();
      }
    }
    return Collections.emptySet();
  }

  @Override
  public String buildCacheKey(@NonNull DataSpec dataSpec) {
    if (dataSpec.key != null) {
      // An explicitly supplied key always wins, matching the default implementation.
      return dataSpec.key;
    }
    return normalize(dataSpec.uri.toString());
  }

  /**
   * Returns {@code url} with volatile signature parameters removed.
   *
   * <p>If nothing was removed the original string is returned byte for byte, so unsigned URLs keep
   * exactly the default cache key and their existing cache entries stay reachable.
   */
  @NonNull
  static String normalize(@NonNull String url) {
    final Uri uri;
    try {
      uri = Uri.parse(url);
    } catch (Exception error) {
      return url;
    }

    // PornHub signs both query parameters and path prefixes, and rotates CDN
    // hosts. Preserve resource identity (video, rendition and segment path),
    // while allowing identical media bytes to survive a freshly signed route.
    // Manifests keep their signed URLs: cached relative references may expire.
    final String cdnHost = uri.getHost();
    final String mediaPath = uri.getEncodedPath();
    if (cdnHost != null && cdnHost.endsWith(".phncdn.com") && mediaPath != null) {
      if (mediaPath.endsWith(".m3u8")) return url;
      int start = mediaPath.indexOf("/hls/");
      if (start < 0) start = mediaPath.indexOf("/videos/");
      if (start >= 0) {
        Uri.Builder stable = uri.buildUpon().authority("media.phncdn.com")
            .encodedPath(mediaPath.substring(start)).clearQuery();
        for (String name : uri.getQueryParameterNames()) {
          String lower = name.toLowerCase(Locale.US);
          if (VOLATILE_QUERY_PARAMS.contains(lower) || volatileForHost(cdnHost).contains(lower)
              || lower.equals("hdnea")) continue;
          for (String value : uri.getQueryParameters(name)) stable.appendQueryParameter(name, value);
        }
        return stable.build().toString();
      }
    }

    final Set<String> names;
    try {
      names = uri.getQueryParameterNames();
    } catch (UnsupportedOperationException error) {
      // Opaque URI (e.g. a non-hierarchical scheme): no query to normalise.
      return url;
    }
    if (names == null || names.isEmpty()) {
      return url;
    }

    // Collect first, decide after: a stable parameter may appear before a volatile one, and
    // appending conditionally while iterating would silently drop it.
    // 全局名单之外，再叠加该 host 专属的额外名单（如 phncdn 的 e/f）。
    final String host = uri.getHost();
    final Set<String> hostVolatile = volatileForHost(host == null ? "" : host);

    final List<String> keptNames = new ArrayList<>(names.size());
    boolean strippedAny = false;
    for (String name : names) {
      final String lower = name.toLowerCase(Locale.US);
      if (VOLATILE_QUERY_PARAMS.contains(lower) || hostVolatile.contains(lower)) {
        strippedAny = true;
        continue;
      }
      keptNames.add(name);
    }

    if (!strippedAny) {
      // Nothing volatile found — preserve the original string exactly, so unsigned URLs keep
      // their existing cache entries.
      return url;
    }

    final Uri.Builder builder = uri.buildUpon().clearQuery();
    for (String name : keptNames) {
      for (String value : uri.getQueryParameters(name)) {
        builder.appendQueryParameter(name, value);
      }
    }
    return builder.build().toString();
  }
}
