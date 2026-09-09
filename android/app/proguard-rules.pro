# Flutter's embedding is referenced from the manifest and from native code.
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# ONNX Runtime's Java bindings are called from JNI, so R8 cannot see the
# references and would otherwise strip them.
-keep class ai.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**

# The platform-channel entry points are invoked reflectively by Flutter.
-keep class org.itantra.flutterhost.** { *; }

-dontwarn org.jetbrains.annotations.**
