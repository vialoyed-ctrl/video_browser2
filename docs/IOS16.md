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
