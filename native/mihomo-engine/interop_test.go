package engine

import (
	"context"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	stdtls "crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/netip"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/component/ca"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/listener/sing_vless"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/sing-quic/hysteria2"
	"github.com/metacubex/sing/common/auth"
	"github.com/metacubex/sing/common/buf"
	M "github.com/metacubex/sing/common/metadata"
	N "github.com/metacubex/sing/common/network"
	mtls "github.com/metacubex/tls"
	utls "github.com/metacubex/utls"
	foundation "proxima.local/mihomo"
)

const interopUUID = "90d4903e-4bc6-4146-b67a-290c83bdd96a"
const interopSNI = "interop.test"
const interopPort = 23456

type interopHandler struct {
	tcp, udp atomic.Int32
	errors   chan error
}

func (h *interopHandler) NewError(_ context.Context, err error) {
	select {
	case h.errors <- err:
	default:
	}
}
func (h *interopHandler) NewConnection(ctx context.Context, c net.Conn, m M.Metadata) error {
	defer c.Close()
	if u, ok := auth.UserFromContext[string](ctx); !ok || u != "user" || m.Destination.Port != interopPort {
		return fmt.Errorf("unexpected authenticated stream destination: user=%q dest=%v", u, m.Destination)
	}
	h.tcp.Add(1)
	c.SetDeadline(time.Now().Add(4 * time.Second))
	b := make([]byte, 64)
	n, err := c.Read(b)
	if err != nil {
		return err
	}
	_, err = c.Write(b[:n])
	return err
}
func (h *interopHandler) NewPacketConnection(ctx context.Context, c N.PacketConn, m M.Metadata) error {
	defer c.Close()
	if u, ok := auth.UserFromContext[string](ctx); !ok || u != "user" {
		return fmt.Errorf("unexpected datagram user %q", u)
	}
	c.SetDeadline(time.Now().Add(4 * time.Second))
	b := buf.NewSize(1024)
	defer b.Release()
	dest, err := c.ReadPacket(b)
	if err != nil {
		return err
	}
	if dest.Port != interopPort {
		return fmt.Errorf("unexpected datagram destination %v", dest)
	}
	h.udp.Add(1)
	return c.WritePacket(b, dest)
}

func interopCert(t *testing.T) ([]byte, []byte) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	cert := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: interopSNI}, DNSNames: []string{interopSNI}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, cert, cert, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	pk, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: pk})
}
func interopSession(t *testing.T) *testProtector {
	t.Helper()
	fd, _ := pair(t)
	p := &testProtector{}
	token, err := foundation.Sessions.Prepare(fd, p)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { foundation.Sessions.Close(token) })
	return p
}
func interopProxy(t *testing.T, m map[string]any) C.Proxy {
	t.Helper()
	if err := admitProxy(m); err != nil {
		t.Fatal(err)
	}
	p, err := adapter.ParseProxy(m)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { p.Close() })
	return p
}
func interopStream(t *testing.T, p C.Proxy, wantSuccess bool) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	c, err := p.DialContext(ctx, &C.Metadata{NetWork: C.TCP, DstIP: netip.MustParseAddr("127.0.0.1"), DstPort: interopPort})
	if err == nil {
		defer c.Close()
		c.SetDeadline(time.Now().Add(4 * time.Second))
		_, err = c.Write([]byte("interop-stream"))
		if err == nil {
			b := make([]byte, len("interop-stream"))
			_, err = io.ReadFull(c, b)
			if err == nil && string(b) != "interop-stream" {
				err = fmt.Errorf("wrong response %q", b)
			}
		}
	}
	if wantSuccess && err != nil {
		t.Fatal(err)
	}
	if !wantSuccess && err == nil {
		t.Fatal("invalid credentials succeeded")
	}
	if !wantSuccess && (errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled)) {
		t.Fatalf("invalid credentials timed out rather than being rejected: %v", err)
	}
	if nerr, ok := err.(net.Error); !wantSuccess && ok && nerr.Timeout() {
		t.Fatalf("invalid credentials timed out rather than being rejected: %v", err)
	}
}
func TestInteropHysteria2(t *testing.T) {
	for _, obfs := range []string{"", "salamander"} {
		name := obfs
		if name == "" {
			name = "plain"
		}
		t.Run(name, func(t *testing.T) { interopHysteria2(t, obfs) })
	}
}

func interopHysteria2(t *testing.T, obfs string) {
	p := interopSession(t)
	certPEM, keyPEM := interopCert(t)
	if err := ca.AddCertificate(string(certPEM)); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(ca.ResetCertificate)
	cert, err := mtls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		t.Fatal(err)
	}
	h := &interopHandler{errors: make(chan error, 8)}
	options := hysteria2.ServiceOptions{Context: context.Background(), Logger: log.SingLogger, TLSConfig: &mtls.Config{Certificates: []mtls.Certificate{cert}, MinVersion: mtls.VersionTLS13, NextProtos: []string{"h3"}}, UDPTimeout: 4 * time.Second, UdpMTU: 1197, Handler: h}
	if obfs == "salamander" {
		options.SalamanderPassword = "obfs-secret"
	}
	s, err := hysteria2.NewService[string](options)
	if err != nil {
		t.Fatal(err)
	}
	s.UpdateUsers([]string{"user"}, []string{"secret"})
	l, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	if err = s.Start(l); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	mapping := map[string]any{"name": "hy2", "type": "hysteria2", "server": "127.0.0.1", "port": l.LocalAddr().(*net.UDPAddr).Port, "sni": interopSNI, "password": "secret"}
	if obfs != "" {
		mapping["obfs"], mapping["obfs-password"] = obfs, "obfs-secret"
	}
	proxy := interopProxy(t, mapping)
	interopStream(t, proxy, true)
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	meta := &C.Metadata{NetWork: C.UDP, DstIP: netip.MustParseAddr("127.0.0.1"), DstPort: interopPort}
	pc, err := proxy.ListenPacketContext(ctx, meta)
	if err != nil {
		t.Fatal(err)
	}
	defer pc.Close()
	pc.SetDeadline(time.Now().Add(4 * time.Second))
	if _, err = pc.WriteTo([]byte("interop-datagram"), meta.UDPAddr()); err != nil {
		t.Fatal(err)
	}
	b := make([]byte, 64)
	n, _, err := pc.ReadFrom(b)
	if err != nil || string(b[:n]) != "interop-datagram" {
		t.Fatalf("datagram %q: %v", b[:n], err)
	}
	mapping["password"] = "wrong"
	bad := interopProxy(t, mapping)
	interopStream(t, bad, false)
	if h.tcp.Load() != 1 || h.udp.Load() != 1 || p.protects.Load() < 2 {
		t.Fatalf("tcp=%d udp=%d protects=%d", h.tcp.Load(), h.udp.Load(), p.protects.Load())
	}
}

func TestInteropVLESSReality(t *testing.T) {
	for _, flow := range []string{"", "xtls-rprx-vision"} {
		name := flow
		if name == "" {
			name = "plain"
		}
		t.Run(name, func(t *testing.T) { interopVLESSReality(t, flow) })
	}
}

func interopVLESSReality(t *testing.T, flow string) {
	p := interopSession(t)
	certPEM, keyPEM := interopCert(t)
	cert, err := stdtls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		t.Fatal(err)
	}
	target, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		target.Close()
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	serve := func(l net.Listener, fn func(net.Conn)) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				c, e := l.Accept()
				if e != nil {
					return
				}
				wg.Add(1)
				go func() { defer wg.Done(); defer c.Close(); c.SetDeadline(time.Now().Add(4 * time.Second)); fn(c) }()
			}
		}()
	}
	// The pinned REALITY server mirrors the camouflage TLS record sizes. Disable
	// tickets on both servers so a synthetic TLS 1.3 target has compatible records.
	serve(target, func(c net.Conn) {
		_ = stdtls.Server(c, &stdtls.Config{Certificates: []stdtls.Certificate{cert}, MinVersion: stdtls.VersionTLS13, MaxVersion: stdtls.VersionTLS13, SessionTicketsDisabled: true}).Handshake()
	})
	key, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	h := &interopHandler{errors: make(chan error, 8)}
	service := sing_vless.NewService[string](h)
	service.UpdateUsers([]string{"user"}, []string{interopUUID}, []string{flow})
	config := &utls.RealityConfig{Config: utls.Config{SessionTicketsDisabled: true}, Dest: target.Addr().String(), Type: "tcp", ServerNames: map[string]bool{interopSNI: true}, PrivateKey: key.Bytes(), ShortIds: map[[8]byte]bool{{1, 2, 3, 4}: true}, DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
		if network != "tcp" || address != target.Addr().String() {
			return nil, fmt.Errorf("unexpected fallback %s %s", network, address)
		}
		return (&net.Dialer{}).DialContext(ctx, network, address)
	}}
	serve(listener, func(c net.Conn) {
		rc, e := utls.RealityServer(context.Background(), c, config)
		if e == nil {
			if e = service.NewConnection(context.Background(), rc, M.Metadata{}); e != nil {
				h.NewError(context.Background(), e)
			}
		}
	})
	t.Cleanup(func() { listener.Close(); target.Close(); wg.Wait() })
	mapping := map[string]any{"name": "reality", "type": "vless", "server": "127.0.0.1", "port": listener.Addr().(*net.TCPAddr).Port, "uuid": interopUUID, "tls": true, "servername": interopSNI, "client-fingerprint": "chrome", "reality-opts": map[string]any{"public-key": base64.RawURLEncoding.EncodeToString(key.PublicKey().Bytes()), "short-id": "01020304"}}
	if flow != "" {
		mapping["flow"] = flow
	}
	proxy := interopProxy(t, mapping)
	interopStream(t, proxy, true)
	mapping["uuid"] = "90d4903e-4bc6-4146-b67a-290c83bdd96b"
	bad := interopProxy(t, mapping)
	interopStream(t, bad, false)
	select {
	case err := <-h.errors:
		if !strings.Contains(err.Error(), "unknown UUID") {
			t.Fatalf("unexpected VLESS rejection: %v", err)
		}
	case <-time.After(4 * time.Second):
		t.Fatal("server did not report invalid UUID")
	}
	if h.tcp.Load() != 1 || p.protects.Load() < 2 {
		t.Fatalf("tcp=%d protects=%d", h.tcp.Load(), p.protects.Load())
	}
}
