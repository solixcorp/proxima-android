#ifndef PROXIMA_SESSION_JNI_H
#define PROXIMA_SESSION_JNI_H

#include <stdint.h>

int proxima_jni_protect(uintptr_t callback, int fd);
int proxima_jni_release(uintptr_t callback);

#endif
