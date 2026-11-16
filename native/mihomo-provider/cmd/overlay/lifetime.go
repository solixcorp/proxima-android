package main

const fetcherSeam = `
var proximaWorkers atomic.Int64
// Counts admitted operations and polling loops, excluding process-global actors.
func ProximaActiveWorkers() int64 { return proximaWorkers.Load() }
func (f *Fetcher[V]) ProximaCancel() {
 f.lifeMu.Lock(); defer f.lifeMu.Unlock(); f.stopped = true; f.ctxCancel()
}
// The gate serializes owner-driven updates with polling and joins ALL admitted
// operations, not just the timer. Never Close reentrantly from onUpdate.
func (f *Fetcher[V]) begin() error {
 f.lifeMu.Lock(); defer f.lifeMu.Unlock()
 if f.stopped { return context.Canceled }
 f.calls.Add(1)
 proximaWorkers.Add(1)
 return nil
}
func (f *Fetcher[V]) end() { proximaWorkers.Add(-1); f.calls.Done() }
func (f *Fetcher[V]) Initial() (V, error) {
 if err := f.begin(); err != nil { return lo.Empty[V](), err }; defer f.end()
 f.opMu.Lock(); defer f.opMu.Unlock()
 value, err := f.initial(); f.lastErr = err
 return value, err
}
func (f *Fetcher[V]) Update() (V, bool, error) {
 if err := f.begin(); err != nil { return lo.Empty[V](), false, err }; defer f.end()
 f.opMu.Lock(); defer f.opMu.Unlock()
 value, same, err := f.update(); f.lastErr = err
 return value, same, err
}
func (f *Fetcher[V]) SideUpdate(buf []byte) (V, bool, error) {
 if err := f.begin(); err != nil { return lo.Empty[V](), false, err }; defer f.end()
 f.opMu.Lock(); defer f.opMu.Unlock()
 value, same, err := f.sideUpdate(buf); f.lastErr = err
 return value, same, err
}
func (f *Fetcher[V]) ProximaLastError() error {
 f.opMu.Lock(); defer f.opMu.Unlock(); return f.lastErr
}
func (f *Fetcher[V]) proximaAttempt() float64 {
 f.opMu.Lock(); defer f.opMu.Unlock(); return f.backoff.Attempt()
}
`

const httpSeam = `
// net/http may detach dialing from Request.Context. A per-fetch gate explicitly
// reattaches every redirect's native dial to the original fetch context and
// joins it before the body completes. Late transport retries fail before socket
// creation, even after net/http has already returned a cancellation error.
type proximaHTTP struct {
 sync.Mutex
 ctx context.Context
 cancel context.CancelFunc
 stopped bool
 dials sync.WaitGroup
 sockets map[*proximaHTTPConn]struct{}
}
func newProximaHTTP(ctx context.Context) *proximaHTTP {
 ctx, cancel := context.WithCancel(ctx)
 return &proximaHTTP{ctx:ctx, cancel:cancel, sockets:make(map[*proximaHTTPConn]struct{})}
}
func (s *proximaHTTP) dial(ctx context.Context, network, address string) (net.Conn, error) {
 s.Lock()
 if s.stopped { s.Unlock(); return nil, net.ErrClosed }
 s.dials.Add(1)
 s.Unlock()
 defer s.dials.Done()
 ctx, cancel := context.WithCancel(ctx)
 stop := context.AfterFunc(s.ctx, cancel)
 defer func(){ stop(); cancel() }()
 // Provider initialization precedes tunnel readiness and must never resolve
 // through a rule-routed main resolver that may itself need this provider.
 c, err := dialer.DialContext(ctx, network, address, dialer.WithResolver(resolver.ProxyServerHostResolver))
 if err != nil { return nil, err }
 s.Lock()
 defer s.Unlock()
 if s.stopped { _ = c.Close(); return nil, net.ErrClosed }
 tracked := &proximaHTTPConn{Conn:c, scope:s}
 s.sockets[tracked] = struct{}{}
 return tracked, nil
}
type proximaHTTPConn struct { net.Conn; scope *proximaHTTP; once sync.Once; err error }
func (c *proximaHTTPConn) Close() error {
 c.once.Do(func(){ c.err=c.Conn.Close(); c.scope.Lock(); delete(c.scope.sockets,c); c.scope.Unlock() })
 return c.err
}
func (s *proximaHTTP) close() {
 s.Lock(); s.stopped=true; s.cancel()
 sockets:=make([]*proximaHTTPConn,0,len(s.sockets))
 for c:=range s.sockets { sockets=append(sockets,c) }
 s.Unlock()
 for _,c:=range sockets { _=c.Close() }
 s.dials.Wait()
}
type proximaBody struct {
 io.ReadCloser
 once sync.Once
 err error
 closeTransport func()
}
func (b *proximaBody) Close() error {
 b.once.Do(func() { b.err = b.ReadCloser.Close(); b.closeTransport() })
 return b.err
}
`
