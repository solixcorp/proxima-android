package main

import _ "embed"

//go:embed replacements/tfo.go.txt
var protectedTFO string

var patches = []patch{
	{
		Path: "adapter/inbound/listen.go",
		Hash: "2eca8f9f4528dabccf594a91257af5a25068d3c8685841f8cb86139012d5986f",
		Edits: []edit{
			{Before: `"github.com/metacubex/mihomo/component/keepalive"`, After: `"github.com/metacubex/mihomo/component/keepalive"
"github.com/metacubex/mihomo/component/dialer"`},
			{Before: `lc.Control = func(network, address string, c syscall.RawConn) error {`, After: `lc.Control = func(network, address string, c syscall.RawConn) error {
		if hook := dialer.DefaultSocketHook; hook != nil {
			return hook(network, address, c)
		}`},
		},
	},
	{
		Path: "listener/redir/tcp.go",
		Hash: "b5d5864387a6075efdc212ba4cf79eb07b9b7f4b9c1d8fda38f8bbeb0f8eb321",
		Edits: []edit{
			{Before: `"net"`, After: `"net"
"context"`},
			{Before: `net.Listen("tcp", addr)`, After: `inbound.NewListenConfig().Listen(context.Background(), "tcp", addr)`},
		},
	},
	{
		Path: "listener/tproxy/tproxy.go",
		Hash: "791a046fa0f811f3b529bc8e43b2cc9729bd7cdcfa7d7e9c2d35600235a29e00",
		Edits: []edit{
			{Before: `"net"`, After: `"net"
"syscall"`},
			{Before: `"github.com/metacubex/mihomo/adapter/inbound"`, After: `"github.com/metacubex/mihomo/adapter/inbound"
"github.com/metacubex/mihomo/component/dialer"`},
			{Before: `lc := net.ListenConfig{}`, After: `lc := net.ListenConfig{Control: func(network, address string, c syscall.RawConn) error {
		if hook := dialer.DefaultSocketHook; hook != nil {
			if err := hook(network, address, c); err != nil { return err }
		}
		return setsockopt(c, address)
	}}`},
			{Before: `	tl := l.(*net.TCPListener)
	rc, err := tl.SyscallConn()
	if err != nil {
		return nil, err
	}

	err = setsockopt(rc, addr)
	if err != nil {
		return nil, err
	}

`, After: ``},
		},
	},
	{
		Path: "listener/tproxy/udp.go",
		Hash: "a047ea414c4ae6f5ca2565488ec86126221df070dc0b7e48e1fc72313a6b48bb",
		Edits: []edit{
			{Before: `"net"`, After: `"net"
"context"
"syscall"`},
			{Before: `"github.com/metacubex/mihomo/adapter/inbound"`, After: `"github.com/metacubex/mihomo/adapter/inbound"
"github.com/metacubex/mihomo/component/dialer"`},
			{Before: `l, err := net.ListenPacket("udp", addr)`, After: `lc := net.ListenConfig{Control: func(network, address string, c syscall.RawConn) error {
		if hook := dialer.DefaultSocketHook; hook != nil {
			if err := hook(network, address, c); err != nil { return err }
		}
		return setsockopt(c, address)
	}}
	l, err := lc.ListenPacket(context.Background(), "udp", addr)`},
			{Before: `	rc, err := c.SyscallConn()
	if err != nil {
		return nil, err
	}

	err = setsockopt(rc, addr)
	if err != nil {
		return nil, err
	}

`, After: ``},
		},
	},
	{
		Path: "listener/tproxy/udp_linux.go",
		Hash: "9b172e7f3e4172af462f03b773cef2bedbd539b0c3f1165b40f17eb22091f857",
		Edits: []edit{
			{Before: `"golang.org/x/sys/unix"`, After: `"github.com/metacubex/mihomo/component/dialer"

	"golang.org/x/sys/unix"`},
			{Before: `syscall.SOCK_DGRAM, 0)`, After: `syscall.SOCK_DGRAM|syscall.SOCK_CLOEXEC, 0)`},
			{Before: `	defer func() {
		if err != nil {
			syscall.Close(fd)
		}
	}()`, After: `	// File owns fd from here; FileConn duplicates it on success.
	fdFile := os.NewFile(uintptr(fd), fmt.Sprintf("net-udp-dial-%s", rAddr.String()))
	defer fdFile.Close()
	if hook := dialer.DefaultSocketHook; hook != nil {
		raw, rawErr := fdFile.SyscallConn()
		if rawErr != nil { return nil, rawErr }
		if err = hook(network, rAddr.String(), raw); err != nil { return nil, err }
	}`},
			{Before: `
	fdFile := os.NewFile(uintptr(fd), fmt.Sprintf("net-udp-dial-%s", rAddr.String()))
	defer fdFile.Close()

	c, err := net.FileConn(fdFile)`, After: `
	c, err := net.FileConn(fdFile)`},
		},
	},
	{
		Path: "component/dialer/dialer.go",
		Hash: "48c2967fb764218796ea3796c361d97304062270fff3f287717223021c16724d",
		Edits: []edit{
			{Before: `// ignore interfaceName, routingMark and tfo when DefaultSocketHook not null (in CMFA)`, After: `// ignore interfaceName and routingMark when DefaultSocketHook is installed`},
			{Before: `		if opt.tfo && !DisableTFO {
			return dialTFO(ctx, *dialer, network, address)
		}
	}

	return dialer.DialContext(ctx, network, address)`, After: `	}
	if opt.tfo && !DisableTFO && (network == "tcp" || network == "tcp4" || network == "tcp6") {
		return dialTFO(ctx, *dialer, network, address)
	}

	return dialer.DialContext(ctx, network, address)`},
		},
	},
	{
		Path:        "component/dialer/tfo.go",
		Hash:        "40b6a958fd8b1e595a49488494a5ee5ab8c98bf82f654469c525eeb69de11fdb",
		Replacement: protectedTFO,
	},
	{
		Path:  "tfo/tfo.go",
		Hash:  "3d880014596d89c5d11ddf1ce3b509d77b2f84e85f0658001d5d61ddc3f07b9a",
		Edits: []edit{},
	},
	{
		Path:  "tfo/tfo_linux.go",
		Hash:  "4822cab45f55b5d6ea5f31a05ddda0aa7c5f975ee0d089aa864aa4ff895b3f05",
		Edits: []edit{},
	},
	{
		Path:  "tfo/tfo_bsd+linux.go",
		Hash:  "0f1f287e4d3e9ab6ab6bbb58193e3b37d53f1e70dd2be00e64478fa313620cf3",
		Edits: []edit{},
	},
	{
		Path:  "tfo/tfo_supported.go",
		Hash:  "de4f5af270c9401b77e417c21833f78a519af2ec8c4b0f8022dc662983d012c7",
		Edits: []edit{},
	},
	{
		Path:  "tfo/tfo_bsd+windows.go",
		Hash:  "b3874879b19c0e5323642dc405eeed6e50ab6f6451862c0822f7aa78be6d9a8c",
		Edits: []edit{},
	},
	{
		Path:  "tfo/tfo_darwin.go",
		Hash:  "1d720ce2c749e4e1d838836e7ed3bc7294fda2a8a46951713c4e700c064b7844",
		Edits: []edit{},
	},
	{
		Path:  "tfo/tfo_listen_generic.go",
		Hash:  "d97930b13af0876a1c04f880be03c709588aecd85692ac22cbe6b9d704e673ec",
		Edits: []edit{},
	},
}
