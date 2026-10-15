# iOS 16 / iPhone 8 personal installation

This branch adds iOS while leaving the original Android checkout unchanged.
Minimum iOS version: 16.0. Architecture: arm64, including iPhone 8.

GitHub Actions builds an unsigned release IPA. Download the `playback-warehouse-ios16`
artifact from the `Build iOS 16 IPA` workflow and extract the IPA. On Windows, import
the IPA into Sideloadly, connect the iPhone, and sign with your own Apple Account.
Enter passwords and verification codes only in the local signing tool.
Free provisioning lasts seven days; refresh before expiry. Trust your developer
profile and enable Developer Mode on the phone when prompted.

Downloads remain in the app Documents folder, which is exposed through iOS Files
and file sharing. iOS can suspend downloads and the local media proxy when the app
is backgrounded; foreground playback/download testing is required on the device.

The existing Android Media3 cache is untouched. iOS uses video_player's
AVFoundation backend and the existing Dart loopback proxies. The media_utils bridge
uses a minimal LGPL FFmpeg 8.0.1 build to remux TS downloads to valid MP4 files,
without re-encoding. FFmpeg sources, license, build script, and relinking objects
are included in the separate CI artifact. No Apple credentials are used in CI.

Downloads: tap Open for the iOS system video player, or Export > Save to Files. Existing downloads are rebased after re-signing, and old TS files mislabeled as MP4 are repaired without deleting the source. Keep the same Apple account and bundle ID when updating; do not uninstall the old app if you want to preserve downloads.

## Updated source compatibility

This iOS release includes the shared application updates from source commit
`91d52e32cb27189be2fff4b09596992d78e35554`: the fourth content source,
its search/navigation, consistent appended-page rows and page jumps, and the
restored primary-source activity feed. iOS remains at minimum version 16.0
with the same bundle ID `com.vialoyed.videoBrowser`.

The native FFmpeg bridge and its AAC stream-parameter probing, HLS timestamp
repair, legacy TS-in-MP4 repair, system playback, export, and Documents path
recovery are preserved. Source updates are merged into this branch instead
of replacing the iOS files. The build continues to gate IPA compilation on
real native TS remux/decode regression tests and the complete Flutter suite.

## Source sync 2026-10-15 (2.0.4+2029)

Merged the source checkout at `aa04643777f8673d7066a9fb6b7449e3c2cf14c6`.
Includes the source's player ownership/disposal and scrub-release changes,
download cancellation and resume lifecycle, shared paging and tablet/card
layouts, and account-boundary fixes. Android native media caching remains
separate from the iOS AVFoundation and Dart loopback playback paths.

All previous iOS media fixes remain: AAC stream parameter probing, TS to MP4,
HLS timestamp reset handling, legacy TS file repair, playback/export, and
Documents path recovery. The download merge retains the new run ownership
checks and continues to reject failed iOS remuxes instead of renaming TS to MP4.
The source's APK installation feature remains Android-only.

The bundle identifier remains `com.vialoyed.videoBrowser`, minimum iOS 16.0.
Sign with the same account and bundle ID and update over the existing app;
do not uninstall if existing downloads must be kept.
