// Exercise the production release function with a controlled JNI invocation
// table. No test switches or replacement functions are shipped in the library.
#include <assert.h>
#include <stdio.h>

#include "../cmd/sessionbridge/bridge.c"

static jint environment_status;
static int release_count;
static int attach_count;
static int target_storage;
static jobject expected_target;

static void JNICALL delete_global_ref(JNIEnv *env, jobject target) {
    (void)env;
    assert(target == expected_target);
    release_count++;
}

static const struct JNINativeInterface_ env_functions = {
    .DeleteGlobalRef = delete_global_ref,
};
static JNIEnv test_environment = &env_functions;

static jint JNICALL get_env(JavaVM *vm, void **result, jint version) {
    (void)vm;
    assert(version == JNI_VERSION_1_6);
    *result = environment_status == JNI_OK ? &test_environment : NULL;
    return environment_status;
}

static jint JNICALL attach_thread(JavaVM *vm, void **result, void *args) {
    (void)vm;
    (void)result;
    (void)args;
    attach_count++;
    return JNI_ERR;
}

static const struct JNIInvokeInterface_ vm_functions = {
    .GetEnv = get_env,
    .AttachCurrentThread = attach_thread,
};
static JavaVM test_vm = &vm_functions;

// The included JNI entry points link against Go in production. This isolated
// release test must never enter them; abort rather than simulate a Go registry.
char *ProximaPrepare(int fd, uintptr_t callback, long long *token) {
    (void)fd;
    (void)callback;
    (void)token;
    abort();
}

char *ProximaClose(long long token) {
    (void)token;
    abort();
}

char *ProximaDuplicateTun(long long token, int *descriptor) {
    (void)token;
    (void)descriptor;
    abort();
}

int ProximaProtect(long long token, int fd) {
    (void)token;
    (void)fd;
    abort();
}

int main(void) {
    assert(JNI_OnLoad(&test_vm, NULL) == JNI_VERSION_1_6);
    protector *owner = calloc(1, sizeof(*owner));
    assert(owner != NULL);
    expected_target = (jobject)&target_storage;
    owner->target = expected_target;

    environment_status = JNI_ERR;
    assert(proxima_jni_release((uintptr_t)owner) == 0);
    assert(release_count == 0);
    assert(owner->target == expected_target);

    environment_status = JNI_EDETACHED;
    assert(proxima_jni_release((uintptr_t)owner) == 0);
    assert(release_count == 0);
    assert(attach_count == 0);
    assert(owner->target == expected_target);

    environment_status = JNI_OK;
    assert(proxima_jni_release((uintptr_t)owner) == 1);
    assert(release_count == 1);
    assert(attach_count == 0);
    puts("JNI release attachment retry tests passed");
    return 0;
}
