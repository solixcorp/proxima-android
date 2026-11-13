#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include "_cgo_export.h"

// Shared, audited callback ownership and attached-thread release implementation.
#include "../../../mihomo/jni/protector.inc"

JNIEXPORT void JNICALL
Java_kr_kimrasng_proxima_mihomo_NativeEngine_startNative(
    JNIEnv *env, jobject self, jbyteArray config, jint fd, jobject target, jstring directory) {
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
    const char *root = directory == NULL ? NULL : (*env)->GetStringUTFChars(env, directory, NULL);
    if (directory != NULL && root == NULL) {
        (*env)->ReleaseByteArrayElements(env, config, bytes, JNI_ABORT);
        proxima_jni_release((uintptr_t)owner);
        return;
    }
    char *error = ProximaEngineStart((char *)bytes, size, fd, (uintptr_t)owner, (char *)root, &handle);
    if (root != NULL) (*env)->ReleaseStringUTFChars(env, directory, root);
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

JNIEXPORT jlongArray JNICALL
Java_kr_kimrasng_proxima_mihomo_NativeEngine_trafficStatsNative(JNIEnv *env, jclass cls, jlong handle) {
    (void)cls;
    long long up = 0, down = 0;
    char *error = ProximaEngineTrafficStats((unsigned long long)handle, &up, &down);
    if (error != NULL) { report_error(env, error); return NULL; }
    jlong values[2] = {(jlong)up, (jlong)down};
    jlongArray result = (*env)->NewLongArray(env, 2);
    if (result != NULL) (*env)->SetLongArrayRegion(env, result, 0, 2, values);
    return result;
}

JNIEXPORT jint JNICALL
Java_kr_kimrasng_proxima_mihomo_NativeEngine_delayTestNative(JNIEnv *env, jclass cls, jlong handle,
                                                         jbyteArray name, jbyteArray url, jint timeout) {
    (void)cls;
    if (name == NULL || url == NULL) {
        throw_error(env, "java/lang/IllegalArgumentException", "proxy name and HTTPS URL are required");
        return 0;
    }
    jsize ns = (*env)->GetArrayLength(env, name), us = (*env)->GetArrayLength(env, url);
    if (ns > 8192 || us > 8192) {
        throw_error(env, "java/lang/IllegalArgumentException", "probe name/URL exceeds 8192 UTF-8 bytes");
        return 0;
    }
    // Normal UTF-8, not JNI Modified UTF-8 (proxy names may contain emoji).
    // Never pin a JVM array while a network operation is running.
    char *n = malloc((size_t)ns + 1), *u = malloc((size_t)us + 1);
    if (n == NULL || u == NULL) {
        free(n); free(u);
        throw_error(env, "java/lang/OutOfMemoryError", "copy probe input");
        return 0;
    }
    (*env)->GetByteArrayRegion(env, name, 0, ns, (jbyte *)n);
    (*env)->GetByteArrayRegion(env, url, 0, us, (jbyte *)u);
    n[ns] = 0; u[us] = 0;
    if ((*env)->ExceptionCheck(env)) { free(n); free(u); return 0; }
    int delay = 0;
    char *error = ProximaEngineDelayTest((unsigned long long)handle, (char *)n, (char *)u, timeout, &delay);
    free(n); free(u);
    report_error(env, error);
    return (jint)delay;
}

JNIEXPORT jbyteArray JNICALL
Java_kr_kimrasng_proxima_mihomo_NativeEngine_connectionsSnapshotNative(JNIEnv *env, jclass cls, jlong handle) {
    (void)cls;
    void *data = NULL;
    int size = 0;
    char *error = ProximaEngineConnectionsSnapshot((unsigned long long)handle, &data, &size);
    if (error != NULL) { free(data); report_error(env, error); return NULL; }
    jbyteArray result = (*env)->NewByteArray(env, (jsize)size);
    if (result != NULL) (*env)->SetByteArrayRegion(env, result, 0, (jsize)size, (const jbyte *)data);
    free(data);
    return result;
}
