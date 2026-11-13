package main

/*
#include <stdlib.h>
#include <stdint.h>
int proxima_jni_protect(uintptr_t callback, int fd);
int proxima_jni_release(uintptr_t callback);
*/
import "C"

import (
	"errors"
	"runtime"
	"sync"
	"unsafe"

	engine "proxima.local/mihomo-engine"
)

type jniProtector struct{ callback C.uintptr_t }

func (p jniProtector) Protect(fd int) bool { return C.proxima_jni_protect(p.callback, C.int(fd)) != 0 }
func (p jniProtector) Close() error {
	if C.proxima_jni_release(p.callback) == 0 {
		return errors.New("retry engine stop from an attached JVM thread")
	}
	return nil
}

var handles = struct {
	sync.Mutex
	next     uint64
	sessions map[uint64]*engine.Session
}{sessions: make(map[uint64]*engine.Session)}

func nativeError(err error) *C.char {
	if err != nil {
		return C.CString(err.Error())
	}
	return nil
}

//export ProximaEngineStart
func ProximaEngineStart(data *C.char, size C.int, fd C.int, owner C.uintptr_t, root *C.char, handle *C.ulonglong) *C.char {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	directory := ""
	if root != nil {
		directory = C.GoString(root)
	}
	s, err := engine.StartWithOptions(C.GoBytes(unsafe.Pointer(data), size), int(fd), jniProtector{owner}, engine.Options{ProviderRoot: directory})
	if s != nil {
		handles.Lock()
		handles.next++
		id := handles.next
		handles.sessions[id] = s
		handles.Unlock()
		*handle = C.ulonglong(id)
	}
	return nativeError(err)
}

//export ProximaEngineStop
func ProximaEngineStop(id C.ulonglong, released *C.int) *C.char {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	handles.Lock()
	s := handles.sessions[uint64(id)]
	handles.Unlock()
	if s == nil {
		*released = 1
		return nil
	}
	err := s.Stop()
	if s.Released() {
		handles.Lock()
		delete(handles.sessions, uint64(id))
		handles.Unlock()
		*released = 1
	}
	return nativeError(err)
}

//export ProximaEngineVersion
func ProximaEngineVersion() *C.char { return C.CString(engine.Version()) }
func main()                         {}
