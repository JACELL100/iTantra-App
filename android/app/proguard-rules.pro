# Flutter's embedding is referenced from the manifest and from native code.
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# ONNX Runtime's Java bindings are called from JNI, so R8 cannot see the
# references and would otherwise strip them.
-keep class ai.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**

# The platform-channel entry points are invoked reflectively by Flutter.
-keep class org.itantra.flutterhost.** { *; }

# Play Core is not a dependency and never will be.
#
# Flutter's embedding ships a deferred-components path that references
# com.google.android.play.core. This app has no deferred components and no
# Play Core, so the referenced classes genuinely do not exist - which R8
# full mode treats as a build error rather than a warning. Suppressing it is
# the correct fix, not adding the dependency: pulling in Play Core would mean
# shipping a network-capable library into an app whose entire premise is that
# it has no internet permission, and it would add size to a build where size
# is scored.
-dontwarn com.google.android.play.core.**

-dontwarn org.jetbrains.annotations.**
