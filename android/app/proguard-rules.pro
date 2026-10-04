# Flutter & Engine
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.**

# VideoPlayer & ExoPlayer (Media3)
-keep class io.flutter.plugins.videoplayer.** { *; }
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**

# Plugins
-keep class com.mr.flutter.plugin.filepicker.** { *; }
-keep class com.crazecoder.openfilex.** { *; }
-keep class io.github.ponnamkarthik.toast.** { *; }
-keep class dev.fluttercommunity.plus.wakelock.** { *; }
# General keep rules for JNI and annotations
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes InnerClasses
-keepattributes EnclosingMethod
-keepclassmembers enum * { *; }

-dontwarn **
