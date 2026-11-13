package main

/*
#include <stdint.h>
#include <stdlib.h>
int diagnostic_protect(uintptr_t callback, int fd);
*/
import "C"

import (
	"errors"
	"net/netip"
	"sync"

	diagnostics "proxima.local/mihomo-app"
)

var bridge struct {
	sync.Mutex
	active   *diagnostics.Session
	callback C.uintptr_t
}

func nativeError(err error) *C.char {
	if err == nil {
		return nil
	}
	return C.CString(err.Error())
}

//export DiagStart
func DiagStart(fd C.int, callback C.uintptr_t, stack *C.char, mtu C.int, target, upstream, network *C.char) *C.char {
	bridge.Lock()
	defer bridge.Unlock()
	if bridge.active != nil {
		return nativeError(diagnostics.ErrProcessUsed)
	}
	if mtu <= 0 {
		return nativeError(errors.New("positive diagnostic MTU is required"))
	}
	destination, err := netip.ParseAddrPort(C.GoString(target))
	if err != nil {
		return nativeError(err)
	}
	server, err := netip.ParseAddrPort(C.GoString(upstream))
	if err != nil {
		return nativeError(err)
	}
	active, err := diagnostics.Start(int(fd), diagnostics.Options{
		Stack: C.GoString(stack), MTU: uint32(mtu), Destination: destination,
		Upstream: server, Network: C.GoString(network),
	}, func(fd int) bool { return C.diagnostic_protect(callback, C.int(fd)) != 0 })
	if err != nil {
		return nativeError(err)
	}
	bridge.active, bridge.callback = active, callback
	return nil
}

//export DiagWait
func DiagWait(token C.longlong) *C.char {
	bridge.Lock()
	active := bridge.active
	bridge.Unlock()
	if token != 1 || active == nil {
		return nativeError(errors.New("invalid diagnostic handle"))
	}
	return nativeError(active.Wait())
}

//export DiagStop
func DiagStop(token C.longlong, released *C.uintptr_t) *C.char {
	bridge.Lock()
	defer bridge.Unlock()
	*released = 0
	if token != 1 || bridge.active == nil {
		return nativeError(errors.New("invalid diagnostic handle"))
	}
	err := bridge.active.Stop()
	// Stop always drains callback admission, including a failed diagnostic.
	// Return its JNI owner once to the attached Java caller for destruction.
	*released, bridge.callback = bridge.callback, 0
	return nativeError(err)
}

func main() {}
