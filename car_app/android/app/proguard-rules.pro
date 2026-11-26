# Keep Sherpa-ONNX JNI classes and fields intact for native GetFieldID / GetMethodID lookups
-keep class com.k2fsa.sherpa.onnx.** { *; }
-dontwarn com.k2fsa.sherpa.onnx.**
