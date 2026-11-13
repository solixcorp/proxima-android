// Included once by each standalone bridge. Do not load two Go core libraries in
// one JVM: their Go package globals/registries are not shared.
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
    if (jvm == NULL) return NULL;
    jint result = (*jvm)->GetEnv(jvm, (void **)&env, JNI_VERSION_1_6);
    if (result == JNI_EDETACHED) {
#if defined(__ANDROID__)
        jint attached_result = (*jvm)->AttachCurrentThread(jvm, &env, NULL);
#else
        jint attached_result = (*jvm)->AttachCurrentThread(jvm, (void **)&env, NULL);
#endif
        if (attached_result != JNI_OK) return NULL;
        *attached = 1;
    } else if (result != JNI_OK) {
        return NULL;
    }
    return env;
}

// A callback exception or failed attachment/detachment always denies protection.
int proxima_jni_protect(uintptr_t callback, int fd) {
    if (callback == 0) return 0;
    int attached;
    JNIEnv *env = environment(&attached);
    if (env == NULL) return 0;
    protector *owner = (protector *)callback;
    jboolean protected = (*env)->CallBooleanMethod(env, owner->target, owner->protect, (jint)fd);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        protected = JNI_FALSE;
    }
    if (attached && (*jvm)->DetachCurrentThread(jvm) != JNI_OK) return 0;
    return protected == JNI_TRUE;
}

int proxima_jni_release(uintptr_t callback) {
    if (callback == 0 || jvm == NULL) return 0;
    // Never attach/detach for cleanup: a failed detach after freeing would make
    // a retry access freed ownership. Retain on error for an attached caller.
    JNIEnv *env = NULL;
    if ((*jvm)->GetEnv(jvm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) return 0;
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
