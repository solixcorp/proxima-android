#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include "_cgo_export.h"

// Shared, audited callback ownership and attached-thread release implementation.
#include "../../../mihomo/jni/protector.inc"

JNIEXPORT void JNICALL
Java_kr_kimrasng_proxima_mihomo_NativeEngine_startNative(
    JNIEnv *env, jobject self, jbyteArray config, jint fd, jobject target) {
    if (config == NULL || target == NULL) {
        throw_error(env, "java/lang/IllegalArgumentException", "configuration and protector are required");
        return;
    }
    jclass self_class = (*env)->GetObjectClass(env, self);
    if (self_class == NULL) return;
    jfieldID handle_field = (*env)->GetFieldID(env, self_class, "handle", "J");
    (*env)->DeleteLocalRef(env, self_class);
    if (handle_field == NULL) return;
    jclass target_class = (*env)->GetObjectClass(env, target);
    if (target_class == NULL) return;
    jmethodID method = (*env)->GetMethodID(env, target_class, "protect", "(I)Z");
    (*env)->DeleteLocalRef(env, target_class);
    if (method == NULL) return;
    protector *owner = calloc(1, sizeof(*owner));
    if (owner == NULL) {
        throw_error(env, "java/lang/OutOfMemoryError", "allocate socket protector");
        return;
    }
    owner->protect = method;
    owner->target = (*env)->NewGlobalRef(env, target);
    if (owner->target == NULL) { free(owner); return; }
    jsize size = (*env)->GetArrayLength(env, config);
    jbyte *bytes = (*env)->GetByteArrayElements(env, config, NULL);
    if (bytes == NULL) { proxima_jni_release((uintptr_t)owner); return; }
    unsigned long long handle = 0;
    char *error = ProximaEngineStart((char *)bytes, size, fd, (uintptr_t)owner, &handle);
    (*env)->ReleaseByteArrayElements(env, config, bytes, JNI_ABORT);
    (*env)->SetLongField(env, self, handle_field, (jlong)handle);
    report_error(env, error);
}

JNIEXPORT void JNICALL
Java_kr_kimrasng_proxima_mihomo_NativeEngine_stopNative(JNIEnv *env, jobject self) {
    jclass cls = (*env)->GetObjectClass(env, self);
    if (cls == NULL) return;
    jfieldID field = (*env)->GetFieldID(env, cls, "handle", "J");
    (*env)->DeleteLocalRef(env, cls);
    if (field == NULL) return;
    jlong handle = (*env)->GetLongField(env, self, field);
    int released = 0;
    char *error = ProximaEngineStop((unsigned long long)handle, &released);
    if (released) (*env)->SetLongField(env, self, field, 0);
    report_error(env, error);
}

JNIEXPORT jstring JNICALL
Java_kr_kimrasng_proxima_mihomo_NativeEngine_version(JNIEnv *env, jclass cls) {
    (void)cls;
    char *version = ProximaEngineVersion();
    jstring result = (*env)->NewStringUTF(env, version);
    free(version);
    return result;
}
