package mihomodns

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"testing"
	"time"
)

const processDrained = "DNS_RELAY_DRAINED_WITH_NATIVE_UPSTREAM_PENDING"

// A canceled native query can start more background work even after the relay
// returns. Use the same process boundary the production worker requires, rather
// than pretending an in-process fixture can safely replace its globals.
func runProcessTest(t *testing.T) {
	t.Helper()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, executable,
		"-test.run=^TestUDPCancellationDrainsRelayButNotNativeUpstreamWorker$",
		"-test.timeout=10s")
	cmd.Env = append(os.Environ(), "MIHOMO_DNS_PROCESS_TEST=1")
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("DNS worker did not exit cleanly: %v\n%s", err, output)
	}
	if !bytes.Contains(output, []byte(processDrained+"\n")) {
		t.Fatalf("DNS worker exited without observing relay drain:\n%s", output)
	}
}
