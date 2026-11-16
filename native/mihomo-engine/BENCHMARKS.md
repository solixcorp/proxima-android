# Host benchmarks (2026-11-13)

Host: macOS darwin/arm64, Apple M3, Go 1.27.1, non-race. Other build and test jobs were running, so results are indicative, not a controlled comparison or Android performance claim. No remote service is used. A non-loopback IPv4 interface is required.

| Benchmark | Result | Scope |
|---|---:|---|
| `BenchmarkTrafficStats` | 18.31–21.73 ns/op, 0 B/op, 0 allocs/op (3 runs) | Go getter with an active in-memory management object; excludes JNI, Binder and Android |
| `BenchmarkMipstackUDP` | 60,093 ns/round trip, 0.13 MB/s, 2,103 B/op, 44 allocs/op (1 run) | Serial 4-byte payload each way, raw IP socketpair → mipstack → protected DIRECT host UDP echo → raw IP reply. Includes scheduler, local host sockets and deadline calls |
| `BenchmarkMipstackTCP` | 41,584 ns/round trip, 0.19 MB/s, 2,197 B/op, 10 allocs/op (1 run) | Serial 4-byte payload each way on one established raw-IP TCP connection to a local echo server; includes packet generation, acknowledgments, scheduler, host sockets and deadline calls |

The previous getter result in `VERIFICATION.md` was 10.19 ns/op; different system load and run conditions prevent attributing the difference to code or treating it as a regression. MB/s counts the 8 bytes of application payload per round trip, not aggregate link bandwidth. Four-byte serial ping/pong is latency-limited and is not a saturation benchmark.

Reproduce after `bash build.sh host` in this directory (it prepares the pinned overlay and `build/engine.mod`); use the generated `build/overlay.json` and set `GOTOOLCHAIN=local`, `GOMODCACHE=$PWD/build/go-mod`, `GOCACHE=$PWD/build/go-cache`, and `GOFLAGS="-mod=readonly -modfile=$PWD/build/engine.mod -overlay=$PWD/build/overlay.json"`. Run `go test -run '^$' -bench '^BenchmarkTrafficStats$' -benchmem -count=3 .` and `go test -run '^$' -bench '^BenchmarkMipstackUDP$' -benchtime=2s -benchmem -count=1 .`. Run each packet benchmark in a **separate process**, because an engine process cannot start a second session. The analogous TCP command uses `^BenchmarkMipstackTCP$`.

These are host direct-path round trips, not proxy encryption/QUIC throughput, device radio behavior, VPN permission, or end-to-end interoperability.
