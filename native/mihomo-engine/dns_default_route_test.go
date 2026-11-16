package engine

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/ca"
	"github.com/metacubex/mihomo/component/resolver"
	D "github.com/miekg/dns"
)

func TestDefaultDNSFollowsSelectedProxy(t *testing.T) {
	if os.Getenv("PROXIMA_DEFAULT_DNS_CHILD") != "" {
		defaultDNSSelectedProxy(t)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestDefaultDNSFollowsSelectedProxy$", "-test.v")
	cmd.Env = append(os.Environ(), "PROXIMA_DEFAULT_DNS_CHILD=1", "PROXIMA_PROVIDER_CHILD=default-dns")
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("default DNS child: %v\n%s", err, output)
	}
}

func defaultDNSSelectedProxy(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	cert := &x509.Certificate{SerialNumber: big.NewInt(7), Subject: pkix.Name{CommonName: "local DoH test"}, DNSNames: []string{"provider.test"}, IPAddresses: []net.IP{net.ParseIP("1.1.1.1"), net.ParseIP("8.8.8.8"), net.ParseIP("127.0.0.1")}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, cert, cert, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})
	if err := ca.AddCertificate(string(certPEM)); err != nil {
		t.Fatal(err)
	}
	tlsCert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		t.Fatal(err)
	}
	var bootstrap, provider atomic.Int32
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/provider" {
			provider.Add(1)
			_, _ = w.Write([]byte("payload:\n  - example.org\n"))
			return
		}
		data, err := base64.RawURLEncoding.DecodeString(r.URL.Query().Get("dns"))
		if err != nil {
			t.Error(err)
			return
		}
		query := new(D.Msg)
		if err := query.Unpack(data); err != nil {
			t.Error(err)
			return
		}
		reply := new(D.Msg)
		reply.SetReply(query)
		answer := net.IPv4(192, 0, 2, 27)
		if query.Question[0].Name == "provider.test." || query.Question[0].Name == "proxy.test." || query.Question[0].Name == "management.test." {
			bootstrap.Add(1)
			answer = net.IPv4(127, 0, 0, 1)
		}
		reply.Answer = []D.RR{&D.A{Hdr: D.RR_Header{Name: query.Question[0].Name, Rrtype: D.TypeA, Class: D.ClassINET, Ttl: 60}, A: answer}}
		wire, _ := reply.Pack()
		w.Header().Set("Content-Type", "application/dns-message")
		_, _ = w.Write(wire)
	}))
	server.TLS = &tls.Config{Certificates: []tls.Certificate{tlsCert}, MinVersion: tls.VersionTLS12}
	server.StartTLS()
	defer server.Close()
	var count [2]atomic.Int32
	proxy := func(i int) *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method != http.MethodConnect || (r.Host != "1.1.1.1:443" && r.Host != "8.8.8.8:443") {
				http.Error(w, "unexpected target", 400)
				return
			}
			count[i].Add(1)
			remote, err := net.Dial("tcp", server.Listener.Addr().String())
			if err != nil {
				t.Error(err)
				return
			}
			client, rw, err := w.(http.Hijacker).Hijack()
			if err != nil {
				remote.Close()
				t.Error(err)
				return
			}
			_, _ = rw.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n")
			_ = rw.Flush()
			go func() {
				defer client.Close()
				defer remote.Close()
				go io.Copy(remote, client)
				_, _ = io.Copy(client, remote)
			}()
		}))
	}
	a, b := proxy(0), proxy(1)
	defer a.Close()
	defer b.Close()
	_, portA, _ := net.SplitHostPort(a.Listener.Addr().String())
	_, portB, _ := net.SplitHostPort(b.Listener.Addr().String())
	_, dnsPort, _ := net.SplitHostPort(server.Listener.Addr().String())
	config := strings.Replace(minimal, "MATCH,DIRECT", "MATCH,PROXY", 1) + fmt.Sprintf("dns: {default-nameserver: ['https://127.0.0.1:%s/dns-query']}\nrule-providers: {r: {type: http, behavior: domain, path: rules/r, url: 'https://provider.test:%s/provider'}}\nproxies: [{name: first, type: http, server: proxy.test, port: %s}, {name: second, type: http, server: proxy.test, port: %s}]\nproxy-groups: [{name: PROXY, type: select, proxies: [first, second]}]\n", dnsPort, dnsPort, portA, portB)
	fd, peer := pair(t)
	protector := &testProtector{}
	s, err := StartWithOptions([]byte(config), fd, protector, Options{ProviderRoot: testRoot})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Stop()
	if provider.Load() != 1 || bootstrap.Load() == 0 || count[0].Load()+count[1].Load() != 0 {
		t.Fatalf("provider bootstrap used proxy or failed: provider=%d bootstrap=%d proxies=%d/%d", provider.Load(), bootstrap.Load(), count[0].Load(), count[1].Load())
	}
	if _, err := resolver.DirectHostResolver.LookupIPv4(context.Background(), "management.test"); err != nil {
		t.Fatalf("direct management bootstrap failed: %v", err)
	}
	if count[0].Load()+count[1].Load() != 0 {
		t.Fatal("direct management bootstrap entered proxy")
	}
	query := func(name string) {
		q := new(D.Msg)
		q.SetQuestion(name, D.TypeA)
		payload, _ := q.Pack()
		if _, err := peer.Write(dnsUDP(payload)); err != nil {
			t.Fatal(err)
		}
		packet := dnsReadPacket(t, peer)
		dnsAssertAnswer(t, q, packet[28:])
	}
	query("first.example.")
	if bootstrap.Load() < 3 {
		t.Fatal("proxy hostname did not use separate bootstrap resolver")
	}
	if count[0].Load() == 0 || count[1].Load() != 0 {
		t.Fatalf("wrong initial proxy counts %d %d", count[0].Load(), count[1].Load())
	}
	if err := s.Select("PROXY", "second"); err != nil {
		t.Fatal(err)
	}
	query("second.example.")
	if count[1].Load() == 0 || protector.protects.Load() == 0 {
		t.Fatalf("selection/protection not used: proxy=%d protects=%d", count[1].Load(), protector.protects.Load())
	}
}
