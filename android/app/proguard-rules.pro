# The engine's JNI exports encode the class and native method names; its start
# and stop entry points also use GetFieldID("handle", "J").
-keep class kr.kimrasng.proxima.mihomo.NativeEngine {
    long handle;
    native <methods>;
}

# GetMethodID on the callback object's runtime class resolves protect(I)Z.
# Keep both the interface contract and each surviving implementation's method
# so R8 cannot rename, remove, or inline away this native-only invocation.
-keep interface kr.kimrasng.proxima.mihomo.NativeEngine$Protector {
    boolean protect(int);
}
-keepclassmembers class * implements kr.kimrasng.proxima.mihomo.NativeEngine$Protector {
    boolean protect(int);
}
