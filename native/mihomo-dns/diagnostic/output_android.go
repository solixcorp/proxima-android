//go:build android && cgo

package diagnostic

/*
#cgo LDFLAGS: -llog
#include <android/log.h>
#include <stdlib.h>
*/
import "C"
import "unsafe"

func writeLog(message string) {
	tag := C.CString("ProximaDNS")
	text := C.CString(message)
	defer C.free(unsafe.Pointer(tag))
	defer C.free(unsafe.Pointer(text))
	C.__android_log_write(C.ANDROID_LOG_WARN, tag, text)
}
