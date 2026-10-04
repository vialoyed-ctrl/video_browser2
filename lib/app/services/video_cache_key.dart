/// Stable filesystem key shared by HLS and MP4 cache stores.
///
/// `String.hashCode` is intended for in-process collections, not a persisted
/// cache namespace. A small deterministic FNV-1a suffix keeps the same video
/// address mapped to the same directory after an app restart.
String videoCacheKey(String id) {
  final uri = Uri.tryParse(id);
  final viewKey = uri?.queryParameters['viewkey'];
  if (viewKey != null && viewKey.isNotEmpty) {
    return 'vk_${_safePart(viewKey)}';
  }

  final safeId = _safePart(id);
  final prefix = safeId.length > 28 ? safeId.substring(0, 28) : safeId;
  if (safeId.length <= 28) return safeId;

  var hash = 0x811c9dc5;
  for (final byte in id.codeUnits) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return '${prefix}_${hash.toRadixString(16).padLeft(8, '0')}';
}

String _safePart(String value) =>
    value.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
