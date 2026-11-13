/* Host-only JNI packet fixture. Never linked into the diagnostic library. */
#include <jni.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static void fail(JNIEnv *env, const char *message) {
    jclass cls = (*env)->FindClass(env, "java/lang/IllegalStateException");
    if (cls != NULL) {
        (*env)->ThrowNew(env, cls, message);
        (*env)->DeleteLocalRef(env, cls);
    }
}

JNIEXPORT jintArray JNICALL Java_NativeDiagnosticsTest_openPair(JNIEnv *env, jclass cls) {
    (void)cls;
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_DGRAM, 0, pair) != 0) {
        fail(env, strerror(errno));
        return NULL;
    }
    for (int i = 0; i < 2; i++) {
        int flags = fcntl(pair[i], F_GETFL);
        if (flags == -1 || fcntl(pair[i], F_SETFL, flags | O_NONBLOCK) == -1) {
            close(pair[0]); close(pair[1]);
            fail(env, strerror(errno));
            return NULL;
        }
    }
    jintArray result = (*env)->NewIntArray(env, 2);
    if (result == NULL) { close(pair[0]); close(pair[1]); return NULL; }
    jint values[2] = {pair[0], pair[1]};
    (*env)->SetIntArrayRegion(env, result, 0, 2, values);
    return result;
}

JNIEXPORT void JNICALL Java_NativeDiagnosticsTest_sendPacket(JNIEnv *env, jclass cls, jint fd, jbyteArray bytes) {
    (void)cls;
    jsize length = (*env)->GetArrayLength(env, bytes);
    jbyte *data = (*env)->GetByteArrayElements(env, bytes, NULL);
    if (data == NULL) return;
    ssize_t sent = write(fd, data, (size_t)length);
    (*env)->ReleaseByteArrayElements(env, bytes, data, JNI_ABORT);
    if (sent != length) fail(env, "packet fixture write failed");
}

JNIEXPORT jbyteArray JNICALL Java_NativeDiagnosticsTest_receivePacket(JNIEnv *env, jclass cls, jint fd) {
    (void)cls;
    struct pollfd event = {.fd = fd, .events = POLLIN};
    if (poll(&event, 1, 5000) != 1) { fail(env, "packet reply deadline"); return NULL; }
    jbyte bytes[1500];
    ssize_t length = read(fd, bytes, sizeof(bytes));
    if (length < 0) { fail(env, strerror(errno)); return NULL; }
    jbyteArray result = (*env)->NewByteArray(env, (jsize)length);
    if (result != NULL) (*env)->SetByteArrayRegion(env, result, 0, (jsize)length, bytes);
    return result;
}

JNIEXPORT jboolean JNICALL Java_NativeDiagnosticsTest_unboundSocket(JNIEnv *env, jclass cls, jint fd) {
    (void)env; (void)cls;
    struct sockaddr_storage address;
    socklen_t length = sizeof(address);
    if (getsockname(fd, (struct sockaddr *)&address, &length) != 0) return JNI_FALSE;
    if (address.ss_family == AF_INET) return ((struct sockaddr_in *)&address)->sin_port == 0;
    if (address.ss_family == AF_INET6) return ((struct sockaddr_in6 *)&address)->sin6_port == 0;
    return JNI_FALSE;
}

JNIEXPORT void JNICALL Java_NativeDiagnosticsTest_closeFD(JNIEnv *env, jclass cls, jint fd) {
    (void)cls;
    if (close(fd) != 0) fail(env, strerror(errno));
}
