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

static JNIEnv *environment(int *attached) {
    JNIEnv *env = NULL;
    *attached = 0;
    if (jvm == NULL) {
        return NULL;
    }
    jint result = (*jvm)->GetEnv(jvm, (void **)&env, JNI_VERSION_1_6);
    if (result == JNI_EDETACHED) {
        // Android's C JNI signature differs from the desktop JDK signature.
#if defined(__ANDROID__)
        jint attached_result = (*jvm)->AttachCurrentThread(jvm, &env, NULL);
#else
        jint attached_result = (*jvm)->AttachCurrentThread(jvm, (void **)&env, NULL);
#endif
        if (attached_result != JNI_OK) {
            return NULL;
        }
        *attached = 1;
    } else if (result != JNI_OK) {
        return NULL;
    }
    return env;
}

// A Java exception, missing JVM attachment, or false return always denies the
// socket. Never let a pending Java exception cross a Go callback boundary.
int proxima_jni_protect(uintptr_t callback, int fd) {
    if (callback == 0) {
        return 0;
    }
    int attached;
    JNIEnv *env = environment(&attached);
    if (env == NULL) {
        return 0;
    }
    protector *owner = (protector *)callback;
    jboolean protected = (*env)->CallBooleanMethod(env, owner->target, owner->protect, (jint)fd);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        protected = JNI_FALSE;
    }
    if (attached && (*jvm)->DetachCurrentThread(jvm) != JNI_OK) {
        return 0;
    }
    return protected == JNI_TRUE;
}

int proxima_jni_release(uintptr_t callback) {
    if (callback == 0 || jvm == NULL) {
        return 0;
    }
    // Cleanup must run on an already attached thread, normally the Java close
    // caller. Failure leaves the owner intact for that caller to retry. Avoid
    // any fallible detach after freeing it: an error then could cause a retry
    // against an already freed owner.
    JNIEnv *env = NULL;
    if ((*jvm)->GetEnv(jvm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        return 0;
    }
    protector *owner = (protector *)callback;
    (*env)->DeleteGlobalRef(env, owner->target);
    free(owner);
    return 1;
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
