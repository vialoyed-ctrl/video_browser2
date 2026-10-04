import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../data/models/pornhub_models.dart';

/// Shared two-column playlist card with a wide cover and video count.
class PornHubPlaylistCard extends StatelessWidget {
  const PornHubPlaylistCard({
    super.key,
    required this.playlist,
    required this.onTap,
    this.selected = false,
  });
  final PornHubPlaylist playlist;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final fallback = ColoredBox(
      color: colors.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.playlist_play_rounded,
          size: 36,
          color: colors.onSurfaceVariant,
        ),
      ),
    );
    return Material(
      color: selected ? colors.primaryContainer : colors.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? colors.primary : colors.outlineVariant,
          width: selected ? 1.5 : 0.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (playlist.coverUrl?.isNotEmpty == true)
                    CachedNetworkImage(
                      imageUrl: playlist.coverUrl!,
                      httpHeaders: const {'Referer': 'https://cn.pornhub.com/'},
                      fit: BoxFit.cover,
                      memCacheWidth: 600,
                      placeholder: (_, _) => fallback,
                      errorWidget: (_, _, _) => fallback,
                    )
                  else
                    fallback,
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        '${playlist.videoCount} 个视频',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Text(
                playlist.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.25,
                  fontWeight: FontWeight.w600,
                  color: selected
                      ? colors.onPrimaryContainer
                      : colors.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
