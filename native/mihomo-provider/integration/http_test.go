package integration

import (
	"context"
	"encoding/pem"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/ca"
	"github.com/metacubex/mihomo/component/resource"
	"proxima.local/mihomo-provider/boundary"
)

func trust(t *testing.T, server *httptest.Server) {
	t.Helper()
	check(t, ca.AddCertificate(string(pem.EncodeToMemory(&pem.Block{
		Type: "CERTIFICATE", Bytes: server.Certificate().Raw,
	}))))
}

func TestHTTPVehicleRejectsInitialUnsafeURLs(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		fmt.Fprint(w, "must not be read")
	}))
	defer server.Close()
	for _, raw := range []string{server.URL, strings.Replace(server.URL, "http://", "https://user:pass@", 1), "https:///a", "file:///etc/hosts"} {
		t.Run(raw, func(t *testing.T) {
			vehicle := resource.NewHTTPVehicle(raw, testPath(t), "", nil, time.Second, 0)
			_, _, err := vehicle.Read(context.Background(), utils.HashType{})
			if !errors.Is(err, boundary.ErrURL) {
				t.Fatalf("unsafe URL error = %v", err)
			}
		})
	}
	if requests.Load() != 0 {
		t.Fatalf("unsafe request reached server: %d", requests.Load())
	}
}

func TestHTTPVehicleRejectsUnsafeRedirects(t *testing.T) {
	for _, userinfo := range []bool{false, true} {
		t.Run(fmt.Sprint(userinfo), func(t *testing.T) {
			var requests atomic.Int32
			target := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				requests.Add(1)
				fmt.Fprint(w, "leaked")
			}))
			defer target.Close()
			trust(t, target)
			location := strings.Replace(target.URL, "https:", "http:", 1)
			if userinfo {
				location = strings.Replace(target.URL, "https://", "https://user:secret@", 1)
			}
			origin := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				http.Redirect(w, r, location, http.StatusFound)
			}))
			defer origin.Close()
			trust(t, origin)
			vehicle := resource.NewHTTPVehicle(origin.URL, testPath(t), "", nil, time.Second, 0)
			_, _, err := vehicle.Read(context.Background(), utils.HashType{})
			if !errors.Is(err, boundary.ErrURL) || requests.Load() != 0 {
				t.Fatalf("redirect error = %v; target requests = %d", err, requests.Load())
			}
		})
	}
}

func TestHTTPVehicleKeepsRedirectHeadersSizeLimitAndETag(t *testing.T) {
	var conditional atomic.Int32
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" {
			http.Redirect(w, r, "/data", http.StatusTemporaryRedirect)
			return
		}
		if r.Header.Get("X-Provider") != "retained" {
			http.Error(w, "missing configured header", http.StatusBadRequest)
			return
		}
		if r.Header.Get("If-None-Match") == `"v1"` {
			conditional.Add(1)
			w.WriteHeader(http.StatusNotModified)
			return
		}
		w.Header().Set("ETag", `"v1"`)
		fmt.Fprint(w, "payload trailing")
	}))
	defer server.Close()
	trust(t, server)
	resource.SetETag(true)
	defer resource.SetETag(false)
	vehicle := resource.NewHTTPVehicle(server.URL, testPath(t), "", map[string][]string{"X-Provider": {"retained"}}, time.Second, 7)
	buf, hash, err := vehicle.Read(context.Background(), utils.HashType{})
	check(t, err)
	if string(buf) != "payload" {
		t.Fatalf("size-limited result = %q", buf)
	}
	buf, repeated, err := vehicle.Read(context.Background(), hash)
	check(t, err)
	if buf != nil || !repeated.Equal(hash) || conditional.Load() != 1 {
		t.Fatalf("ETag round trip: body=%q hash=%v conditional=%d", buf, repeated, conditional.Load())
	}
}

func TestHTTPVehicleVerifiesCertificates(t *testing.T) {
	ca.ResetCertificate()
	defer ca.ResetCertificate()
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "untrusted")
	}))
	defer server.Close()
	vehicle := resource.NewHTTPVehicle(server.URL, testPath(t), "", nil, time.Second, 0)
	_, _, err := vehicle.Read(context.Background(), utils.HashType{})
	if err == nil || !strings.Contains(err.Error(), "certificate") {
		t.Fatalf("untrusted certificate error = %v", err)
	}
}

func TestHTTPVehicleBoundsRedirectLoops(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		http.Redirect(w, r, "/", http.StatusFound)
	}))
	defer server.Close()
	trust(t, server)
	vehicle := resource.NewHTTPVehicle(server.URL, testPath(t), "", nil, 5*time.Second, 0)
	_, _, err := vehicle.Read(context.Background(), utils.HashType{})
	if err == nil || !strings.Contains(err.Error(), "10 redirects") || requests.Load() != 10 {
		t.Fatalf("loop error=%v requests=%d", err, requests.Load())
	}
}
