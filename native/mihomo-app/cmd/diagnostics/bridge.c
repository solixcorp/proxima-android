#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include "_cgo_export.h"

typedef struct {
    jobject target;
    jmethodID protect;
} protector;

static JavaVM *jvm;

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    jvm = vm;
    return JNI_VERSION_1_6;
}

int diagnostic_protect(uintptr_t callback, int fd) {
    JNIEnv *env = NULL;
    int attached = 0;
    if (callback == 0 || jvm == NULL) return 0;
    jint result = (*jvm)->GetEnv(jvm, (void **)&env, JNI_VERSION_1_6);
    if (result == JNI_EDETACHED) {
#if defined(__ANDROID__)
        result = (*jvm)->AttachCurrentThread(jvm, &env, NULL);
#else
        result = (*jvm)->AttachCurrentThread(jvm, (void **)&env, NULL);
#endif
        if (result != JNI_OK) return 0;
        attached = 1;
    } else if (result != JNI_OK) {
        return 0;
    }
    protector *owner = (protector *)callback;
    jboolean allowed = (*env)->CallBooleanMethod(env, owner->target, owner->protect, (jint)fd);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        allowed = JNI_FALSE;
    }
    if (attached && (*jvm)->DetachCurrentThread(jvm) != JNI_OK) return 0;
    return allowed == JNI_TRUE;
}

static void throw_error(JNIEnv *env, const char *type, const char *message) {
    jclass cls = (*env)->FindClass(env, type);
    if (cls != NULL) {
        (*env)->ThrowNew(env, cls, message);
        (*env)->DeleteLocalRef(env, cls);
    }
}

static void report_error(JNIEnv *env, char *error) {
    if (error != NULL) {
        throw_error(env, "java/lang/IllegalStateException", error);
        free(error);
    }
}

JNIEXPORT jlong JNICALL
Java_kr_kimrasng_proxima_mihomo_NativeDiagnostics_startNative(
    JNIEnv *env, jclass cls, jint fd, jobject target, jstring stack,
    jint mtu, jstring destination, jstring upstream, jstring network) {
    (void)cls;
    if (target == NULL || stack == NULL || destination == NULL || upstream == NULL || network == NULL) {
        throw_error(env, "java/lang/IllegalArgumentException", "diagnostic arguments are required");
        return 0;
    }
    jclass target_class = (*env)->GetObjectClass(env, target);
    if (target_class == NULL) return 0;
    jmethodID method = (*env)->GetMethodID(env, target_class, "protect", "(I)Z");
    (*env)->DeleteLocalRef(env, target_class);
    if (method == NULL) return 0;
    protector *owner = calloc(1, sizeof(*owner));
    if (owner == NULL) {
        throw_error(env, "java/lang/OutOfMemoryError", "allocate diagnostic protector");
        return 0;
    }
    owner->target = (*env)->NewGlobalRef(env, target);
    owner->protect = method;
    if (owner->target == NULL) { free(owner); return 0; }
    const char *s = NULL, *d = NULL, *u = NULL, *n = NULL;
    char *error = NULL;
    jlong token = 0;
    s = (*env)->GetStringUTFChars(env, stack, NULL);
    if (s == NULL) goto cleanup;
    d = (*env)->GetStringUTFChars(env, destination, NULL);
    if (d == NULL) goto cleanup;
    u = (*env)->GetStringUTFChars(env, upstream, NULL);
    if (u == NULL) goto cleanup;
    n = (*env)->GetStringUTFChars(env, network, NULL);
    if (n == NULL) goto cleanup;
    error = DiagStart(fd, (uintptr_t)owner, (char *)s, mtu, (char *)d, (char *)u, (char *)n);
    if (error == NULL) token = 1;
cleanup:
    if (s != NULL) (*env)->ReleaseStringUTFChars(env, stack, s);
    if (d != NULL) (*env)->ReleaseStringUTFChars(env, destination, d);
    if (u != NULL) (*env)->ReleaseStringUTFChars(env, upstream, u);
    if (n != NULL) (*env)->ReleaseStringUTFChars(env, network, n);
    if (token == 0) {
        (*env)->DeleteGlobalRef(env, owner->target);
        free(owner);
    }
    report_error(env, error);
    return token;
}

JNIEXPORT void JNICALL
Java_kr_kimrasng_proxima_mihomo_NativeDiagnostics_awaitNative(JNIEnv *env, jclass cls, jlong token) {
    (void)cls;
    report_error(env, DiagWait(token));
}

JNIEXPORT void JNICALL
Java_kr_kimrasng_proxima_mihomo_NativeDiagnostics_stopNative(JNIEnv *env, jclass cls, jlong token) {
    (void)cls;
    uintptr_t released = 0;
    char *error = DiagStop(token, &released);
    if (released != 0) {
        protector *owner = (protector *)released;
        (*env)->DeleteGlobalRef(env, owner->target);
        free(owner);
    }
    report_error(env, error);
}
