#include <jni.h>
#include <stdint.h>
#include <stdlib.h>

#include "_cgo_export.h"

#include "../../jni/protector.inc"

JNIEXPORT jlong JNICALL
Java_kr_kimrasng_proxima_mihomo_NativeSession_prepareNative(
    JNIEnv *env, jclass cls, jint fd, jobject target) {
    (void)cls;
    if (target == NULL) {
        throw_error(env, "java/lang/IllegalArgumentException", "protector is required");
        return 0;
    }
    jclass target_class = (*env)->GetObjectClass(env, target);
    if (target_class == NULL) {
        return 0;
    }
    jmethodID method = (*env)->GetMethodID(env, target_class, "protect", "(I)Z");
    (*env)->DeleteLocalRef(env, target_class);
    if (method == NULL) {
        return 0;
    }
    protector *owner = calloc(1, sizeof(*owner));
    if (owner == NULL) {
        throw_error(env, "java/lang/OutOfMemoryError", "allocate socket protector");
        return 0;
    }
    owner->target = (*env)->NewGlobalRef(env, target);
    owner->protect = method;
    if (owner->target == NULL) {
        free(owner);
        return 0;
    }
    long long token = 0;
    char *error = ProximaPrepare(fd, (uintptr_t)owner, &token);
    if (error != NULL) {
        (*env)->DeleteGlobalRef(env, owner->target);
        free(owner);
        report_error(env, error);
        return 0;
    }
    return (jlong)token;
}

JNIEXPORT void JNICALL
Java_kr_kimrasng_proxima_mihomo_NativeSession_closeNative(
    JNIEnv *env, jclass cls, jlong token) {
    (void)cls;
    report_error(env, ProximaClose((long long)token));
}

JNIEXPORT jint JNICALL
Java_kr_kimrasng_proxima_mihomo_NativeSession_duplicateTunNative(
    JNIEnv *env, jclass cls, jlong token) {
    (void)cls;
    int fd = -1;
    report_error(env, ProximaDuplicateTun((long long)token, &fd));
    return (jint)fd;
}

JNIEXPORT jboolean JNICALL
Java_kr_kimrasng_proxima_mihomo_NativeSession_protectNative(
    JNIEnv *env, jclass cls, jlong token, jint fd) {
    (void)env;
    (void)cls;
    return ProximaProtect((long long)token, fd) ? JNI_TRUE : JNI_FALSE;
}
