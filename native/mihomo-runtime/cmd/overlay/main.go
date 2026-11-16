// Command overlay creates a checksum-gated build overlay, never edits the cache.
package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"go/format"
	"os"
	"path/filepath"
	"strings"
)

const originalSHA256 = "0bc87ae1a2cf43abbb71353d10ea356a433c65cbd807b065863a54aa6c146267"

func patched(source []byte) ([]byte, error) {
	if fmt.Sprintf("%x", sha256.Sum256(source)) != originalSHA256 {
		return nil, fmt.Errorf("sing-tun v0.4.28 stack_mipstack.go checksum mismatch")
	}
	text := string(source)
	for _, edit := range [][2]string{
		{"\"strings\"\n", "\"strings\"\n\t\"sync\"\n"},
		{"type Mipstack struct {\n", "type Mipstack struct {\n\tpacketLoops sync.WaitGroup\n\tpacketReadDone chan struct{}\n\tpacketReadErr error\n"},
		{"\ts := &Mipstack{\n", "\ts := &Mipstack{\n\t\tpacketReadDone: make(chan struct{}),\n"},
		{"\tgo s.readLoop()\n\tgo s.writeLoop()\n", "\ts.packetLoops.Add(2)\n\tgo func() { defer s.packetLoops.Done(); defer close(s.packetReadDone); s.readLoop() }()\n\tgo func() { defer s.packetLoops.Done(); s.writeLoop() }()\n"},
		{
			"\t\tif err != nil {\n\t\t\tif E.IsClosed(err) {\n\t\t\t\treturn\n\t\t\t}\n\t\t\ts.logger.Error(E.Cause(err, \"read packet\"))\n\t\t}\n",
			"\t\tif err != nil {\n\t\t\ts.packetReadErr = err\n\t\t\tif !E.IsClosed(err) {\n\t\t\t\ts.logger.Error(E.Cause(err, \"read packet\"))\n\t\t\t}\n\t\t\treturn\n\t\t}\n",
		},
	} {
		if strings.Count(text, edit[0]) != 1 {
			return nil, fmt.Errorf("overlay anchor must occur exactly once: %q", edit[0])
		}
		text = strings.Replace(text, edit[0], edit[1], 1)
	}
	text += `
// WaitPacketLoops joins only the device read and stack write loops.
// The owner MUST close the device and call Close before waiting. Start and
// Close remain serialized by the owner. This is not a provider/flow-worker join.
func (s *Mipstack) WaitPacketLoops() {
	s.packetLoops.Wait()
}

// PacketReadDone closes when the device read loop exits. The owner still must
// close the device and stack and join all owned work.
func (s *Mipstack) PacketReadDone() <-chan struct{} {
	return s.packetReadDone
}

// PacketReadError reports the final raw-device read error after loop exit.
// The closed channel publishes packetReadErr; no unsynchronized read occurs.
// Before exit it returns nil. Expected shutdown may report os.ErrClosed.
func (s *Mipstack) PacketReadError() error {
	select {
	case <-s.packetReadDone:
		return s.packetReadErr
	default:
		return nil
	}
}
`
	return format.Source([]byte(text))
}

func main() {
	if len(os.Args) != 3 {
		panic("usage: overlay <sing-tun-module-dir> <output-dir>")
	}
	sourcePath, err := filepath.Abs(filepath.Join(os.Args[1], "stack_mipstack.go"))
	if err != nil {
		panic(err)
	}
	source, err := os.ReadFile(sourcePath)
	if err != nil {
		panic(err)
	}
	result, err := patched(source)
	if err != nil {
		panic(err)
	}
	out, err := filepath.Abs(os.Args[2])
	if err != nil {
		panic(err)
	}
	if err = os.MkdirAll(out, 0755); err != nil {
		panic(err)
	}
	// Keep generated source artifacts out of the parent module's ./... scan.
	if err = os.WriteFile(filepath.Join(out, "go.mod"), []byte("module proxima.local/mihomo-runtime-build\n"), 0644); err != nil {
		panic(err)
	}
	// Go 1.27 rejects -overlay replacements beneath GOMODCACHE. Stage the
	// verified module in our generated build directory, then overlay that copy.
	staged := filepath.Join(out, "sing-tun")
	if err = os.RemoveAll(staged); err != nil {
		panic(err)
	}
	if err = os.CopyFS(staged, os.DirFS(filepath.Dir(sourcePath))); err != nil {
		panic(err)
	}
	destination := filepath.Join(out, "stack_mipstack.go")
	if err = os.WriteFile(destination, result, 0644); err != nil {
		panic(err)
	}
	overlay, err := json.MarshalIndent(struct {
		Replace map[string]string
	}{map[string]string{filepath.Join(staged, "stack_mipstack.go"): destination}}, "", "  ")
	if err != nil {
		panic(err)
	}
	if err = os.WriteFile(filepath.Join(out, "overlay.json"), overlay, 0644); err != nil {
		panic(err)
	}
	module, err := os.ReadFile("go.mod")
	if err != nil {
		panic(err)
	}
	module = append(module, []byte(fmt.Sprintf("\nreplace github.com/metacubex/sing-tun => %q\n", staged))...)
	if err = os.WriteFile(filepath.Join(out, "runtime.mod"), module, 0644); err != nil {
		panic(err)
	}
	sums, err := os.ReadFile("go.sum")
	if err != nil {
		panic(err)
	}
	if err = os.WriteFile(filepath.Join(out, "runtime.sum"), sums, 0644); err != nil {
		panic(err)
	}
	fmt.Println("Checksum verified; generated joined-packet-loop overlay")
}
