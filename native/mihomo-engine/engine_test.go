package engine

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/tunnel"
	"golang.org/x/sys/unix"
	foundation "proxima.local/mihomo"
	"proxima.local/mihomo/session"
)

const minimal = "find-process-mode: off\nlog-level: silent\nprofile: {store-selected: false}\ntun: {enable: true, stack: mips, mtu: 1500, auto-route: false, auto-detect-interface: false, dns-hijack: [], inet6-address: []}\nrules: ['MATCH,DIRECT']\n"

type testProtector struct {
	closed   atomic.Int32
	protects atomic.Int32
	fail     atomic.Bool
}

func (p *testProtector) Protect(int) bool { p.protects.Add(1); return true }
func (p *testProtector) Close() error {
	if p.fail.Swap(false) {
		return errors.New("injected attached-thread release failure")
	}
	p.closed.Add(1)
	return nil
}

func pair(t *testing.T) (int, *os.File) {
	t.Helper()
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, fd := range fds {
		if err := unix.SetNonblock(fd, true); err != nil {
			t.Fatal(err)
		}
	}
	peer := os.NewFile(uintptr(fds[1]), "engine-peer")
	if err := peer.SetReadDeadline(time.Time{}); err != nil {
		t.Fatal(err)
	} // warm poller before fd baseline
	t.Cleanup(func() { unix.Close(fds[0]); peer.Close() })
	return fds[0], peer
}

func fdCount(t *testing.T) int {
	t.Helper()
	for _, path := range []string{"/dev/fd", "/proc/self/fd"} {
		entries, err := os.ReadDir(path)
		if err == nil {
			return len(entries)
		}
	}
	t.Fatal("cannot count process descriptors")
	return 0
}

func TestStartRollbackBeforeSemanticParsing(t *testing.T) {
	fd, _ := pair(t)
	before := fdCount(t)
	for _, input := range []struct {
		config string
		fd     int
	}{
		{minimal, -1}, {"broken: [", fd}, {"mode: bogus", fd},
		{strings.Replace(minimal, "stack: mips", "stack: system", 1), fd},
		{minimal + "proxy-providers: {x: {type: http}}\n", fd},
		{minimal + "dns: {enhanced-mode: fake-ip}\n", fd},
		{minimal + "unknown-engine-option: true\n", fd},
		{strings.Replace(minimal, "stack: mips, ", "", 1), fd},
		{strings.Replace(minimal, "mtu: 1500", "mtu: 1500, file-descriptor: 0", 1), fd},
		{strings.Replace(minimal, "mtu: 1500", "mtu: 1500, unknown-option: true", 1), fd},
	} {
		for i := 0; i < 30; i++ {
			p := &testProtector{}
			s, err := Start([]byte(input.config), input.fd, p)
			if err == nil || s != nil || p.closed.Load() != 1 {
				t.Fatalf("bad rollback: %v %v closed=%d", s, err, p.closed.Load())
			}
		}
	}
	if after := fdCount(t); after != before {
		t.Fatalf("startup leaked fds: before=%d after=%d", before, after)
	}
	if tunnel.Status() == tunnel.Running {
		t.Fatal("failed startup published running")
	}
	if _, err := unix.FcntlInt(uintptr(fd), unix.F_GETFD, 0); err != nil {
		t.Fatal("closed borrowed fd", err)
	}
}

func TestDuplicateLeaseDoesNotCloseExistingLease(t *testing.T) {
	fd, _ := pair(t)
	owner := &testProtector{}
	token, err := foundation.Sessions.Prepare(fd, owner)
	if err != nil {
		t.Fatal(err)
	}
	defer foundation.Sessions.Close(token)
	before := fdCount(t)
	p := &testProtector{}
	s, err := Start([]byte(minimal), fd, p)
	if s != nil || !errors.Is(err, session.ErrBusy) || p.closed.Load() != 1 || owner.closed.Load() != 0 {
		t.Fatalf("busy lease rollback: %v", err)
	}
	if fdCount(t) != before {
		t.Fatal("duplicate lease leaked fd")
	}
	if err := foundation.Sessions.Protect(token, fd); err != nil {
		t.Fatal("old lease revoked", err)
	}
}

func TestCoreLifecycleIsolated(t *testing.T) {
	for _, scenario := range []string{"parse", "blocking", "constructor", "stack-start", "success", "release", "read-failure"} {
		t.Run(scenario, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestEngineChild$", "-test.v")
			cmd.Env = append(os.Environ(), "PROXIMA_ENGINE_CHILD="+scenario)
			if output, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("child %s: %v\n%s", scenario, err, output)
			}
		})
	}
}

func TestEngineChild(t *testing.T) {
	scenario := os.Getenv("PROXIMA_ENGINE_CHILD")
	if scenario == "" {
		t.Skip("subprocess only")
	}
	fd, peer := pair(t)
	config := minimal
	if scenario == "success" {
		config = strings.Replace(config, "log-level: silent", "log-level: debug", 1)
	}
	switch scenario {
	case "parse":
		config = strings.Replace(config, "MATCH,DIRECT", "IP-CIDR,invalid,DIRECT", 1)
	case "blocking":
		if err := unix.SetNonblock(fd, false); err != nil {
			t.Fatal(err)
		}
	case "constructor":
		config = strings.Replace(config, "mtu: 1500", "mtu: 1500, congestion-controller: invalid", 1)
	case "stack-start":
		config = strings.Replace(config, "mtu: 1500", "mtu: 1", 1)
	}
	p := &testProtector{}
	before := fdCount(t)
	s, err := Start([]byte(config), fd, p)
	if scenario == "parse" || scenario == "blocking" || scenario == "constructor" || scenario == "stack-start" {
		if err == nil || s != nil {
			t.Fatalf("expected real startup failure: %v", err)
		}
		if p.closed.Load() != 1 || fdCount(t) != before {
			t.Fatalf("failed startup fd/owner leak: %d -> %d, closed=%d, %v", before, fdCount(t), p.closed.Load(), err)
		}
		if tunnel.Status() == tunnel.Running {
			t.Fatal("failed startup marked running")
		}
	} else {
		if err != nil {
			t.Fatal(err)
		}
		if scenario == "success" {
			actualRoundTrip(t, fd, peer, p)
		}
		if scenario == "release" {
			p.fail.Store(true)
		}
		if scenario == "read-failure" {
			// Empty datagram is a terminal packet read, not a fabricated stack.
			if _, err := peer.Write(nil); err != nil {
				t.Fatal(err)
			}
			select {
			case <-s.Done():
			case <-time.After(5 * time.Second):
				t.Fatal("input exit did not shut down engine")
			}
			if s.Wait() == nil {
				t.Fatal("input failure was not surfaced")
			}
		}
		stopErr := s.Stop()
		if scenario == "release" {
			if stopErr == nil || p.closed.Load() != 0 {
				t.Fatal("release failure lost ownership", stopErr)
			}
			if _, err := foundation.Sessions.DuplicateTun(s.token); !errors.Is(err, session.ErrInactive) {
				t.Fatal("failed release left active lease", err)
			}
			stopErr = s.Stop()
		}
		if scenario != "read-failure" && stopErr != nil {
			t.Fatal(stopErr)
		}
		var wg sync.WaitGroup
		for i := 0; i < 12; i++ {
			wg.Add(1)
			go func() { defer wg.Done(); _ = s.Stop() }()
		}
		wg.Wait()
		if p.closed.Load() != 1 || fdCount(t) != before {
			t.Fatalf("stop leaked descriptors or double-released callback: %d -> %d, closed=%d", before, fdCount(t), p.closed.Load())
		}
		if tunnel.Status() == tunnel.Running {
			t.Fatal("stop left running core")
		}
	}
	if _, err := unix.FcntlInt(uintptr(fd), unix.F_GETFD, 0); err != nil {
		t.Fatal("closed caller's original", err)
	}
	if _, err := Start([]byte(minimal), fd, &testProtector{}); !errors.Is(err, ErrProcessUsed) {
		t.Fatal("core process reused", err)
	}
	if _, err := foundation.Sessions.Prepare(fd, &testProtector{}); !errors.Is(err, session.ErrRetired) {
		t.Fatal("old workers can reach a replacement lease", err)
	}
}

func actualRoundTrip(t *testing.T, fd int, peer *os.File, p *testProtector) {
	t.Helper()
	// Mipstack correctly rejects foreign loopback destinations on a raw device.
	// Bind a local host interface instead; no external server is contacted.
	addresses, err := net.InterfaceAddrs()
	if err != nil {
		t.Fatal(err)
	}
	var localIP net.IP
	for _, address := range addresses {
		if network, ok := address.(*net.IPNet); ok && network.IP.To4() != nil && !network.IP.IsLoopback() {
			localIP = network.IP.To4()
			break
		}
	}
	if localIP == nil {
		t.Fatal("packet round trip requires a local non-loopback IPv4 interface")
	}
	sink, err := net.ListenUDP("udp4", &net.UDPAddr{IP: localIP})
	if err != nil {
		t.Fatal(err)
	}
	defer sink.Close()
	if err := sink.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}
	packet := make([]byte, 32)
	packet[0], packet[8], packet[9] = 0x45, 64, 17
	binary.BigEndian.PutUint16(packet[2:4], uint16(len(packet)))
	copy(packet[12:16], []byte{10, 0, 0, 2})
	copy(packet[16:20], localIP)
	var checksum uint32
	for i := 0; i < 20; i += 2 {
		checksum += uint32(binary.BigEndian.Uint16(packet[i:]))
	}
	for checksum>>16 != 0 {
		checksum = (checksum & 65535) + (checksum >> 16)
	}
	binary.BigEndian.PutUint16(packet[10:12], ^uint16(checksum))
	binary.BigEndian.PutUint16(packet[20:22], 34001)
	binary.BigEndian.PutUint16(packet[22:24], uint16(sink.LocalAddr().(*net.UDPAddr).Port))
	binary.BigEndian.PutUint16(packet[24:26], 12)
	copy(packet[28:], "ping")
	if _, err := peer.Write(packet); err != nil {
		t.Fatal(err)
	}
	data := make([]byte, 128)
	n, addr, err := sink.ReadFromUDP(data)
	if err != nil {
		t.Fatal("core did not consume raw IP", err)
	}
	if !bytes.Equal(data[:n], []byte("ping")) || p.protects.Load() == 0 {
		t.Fatal("not real protected core traffic")
	}
	if _, err := sink.WriteToUDP([]byte("pong"), addr); err != nil {
		t.Fatal(err)
	}
	if err := peer.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}
	n, err = peer.Read(data)
	if err != nil {
		t.Fatal(err)
	}
	if n < 28 || string(data[28:n]) != "pong" {
		t.Fatal(fmt.Sprintf("bad raw reply: %x", data[:n]))
	}
}
