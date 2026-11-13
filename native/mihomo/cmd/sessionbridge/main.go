package main

/*
#include <stdlib.h>
#include "bridge_jni.h"
*/
import "C"

import (
	"errors"

	bridge "proxima.local/mihomo"
	"proxima.local/mihomo/session"
)

var errRelease = errors.New("protector release requires an attached JVM thread; retry close from Java")

type jniProtector struct {
	callback C.uintptr_t
}

func (p jniProtector) Protect(fd int) bool {
	return C.proxima_jni_protect(p.callback, C.int(fd)) != 0
}

func (p jniProtector) Close() error {
	if C.proxima_jni_release(p.callback) == 0 {
		return errRelease
	}
	return nil
}

func nativeError(err error) *C.char {
	if err != nil {
		return C.CString(err.Error())
	}
	return nil
}

//export ProximaPrepare
func ProximaPrepare(fd C.int, callback C.uintptr_t, token *C.longlong) *C.char {
	id, err := bridge.Sessions.Prepare(int(fd), jniProtector{callback: callback})
	*token = C.longlong(id)
	return nativeError(err)
}

//export ProximaClose
func ProximaClose(token C.longlong) *C.char {
	return nativeError(bridge.Sessions.Close(session.Token(token)))
}

//export ProximaDuplicateTun
func ProximaDuplicateTun(token C.longlong, descriptor *C.int) *C.char {
	fd, err := bridge.Sessions.DuplicateTun(session.Token(token))
	*descriptor = C.int(fd)
	return nativeError(err)
}

//export ProximaProtect
func ProximaProtect(token C.longlong, fd C.int) C.int {
	if bridge.Sessions.Protect(session.Token(token), int(fd)) != nil {
		return 0
	}
	return 1
}

func main() {}
