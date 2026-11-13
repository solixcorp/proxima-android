package main

const healthCheckSeam = `
var proximaHealthWorkers syncatomic.Int64
func ProximaActiveHealthChecks() int64 { return proximaHealthWorkers.Load() }
func (hc *HealthCheck) proximaBegin() bool {
 hc.lifeMu.Lock(); defer hc.lifeMu.Unlock()
 if hc.stopped { return false }
 hc.workers.Add(1); proximaHealthWorkers.Add(1); return true
}
func (hc *HealthCheck) proximaDone() { proximaHealthWorkers.Add(-1); hc.workers.Done() }
func (hc *HealthCheck) proximaGo(fn func()) {
 if !hc.proximaBegin() { return }
 go func(){ defer hc.proximaDone(); fn() }()
}
`

const resolverSeam = `
// One lifetime for the admitted resolver graph, including bootstrap, fallback,
// stale-cache refresh, retries and singleflight work. Internal jobs are added
// while an admitted parent is counted; only public entry points close admission.
var proximaDNSWorkers struct {
 sync.Mutex
 enabled, stopped bool
 ctx context.Context
 cancel context.CancelFunc
 wg sync.WaitGroup
 clients []io.Closer
 active int
}
func ProximaStart() {
 proximaDNSWorkers.Lock(); defer proximaDNSWorkers.Unlock()
 if proximaDNSWorkers.enabled { panic("DNS lifetime already consumed") }
 proximaDNSWorkers.enabled = true
 proximaDNSWorkers.ctx, proximaDNSWorkers.cancel = context.WithCancel(context.Background())
}
func proximaDNSContext() context.Context {
 proximaDNSWorkers.Lock(); defer proximaDNSWorkers.Unlock()
 if !proximaDNSWorkers.enabled { return context.Background() }
 return proximaDNSWorkers.ctx
}
func proximaDNSBegin(ctx context.Context) (context.Context, func(), bool) {
 proximaDNSWorkers.Lock(); defer proximaDNSWorkers.Unlock()
 if !proximaDNSWorkers.enabled { return ctx, func(){}, true }
 if proximaDNSWorkers.stopped { return ctx, func(){}, false }
 proximaDNSWorkers.wg.Add(1); proximaDNSWorkers.active++
 child, cancel := context.WithCancel(ctx)
 stop := context.AfterFunc(proximaDNSWorkers.ctx, cancel)
 return child, func(){ stop(); cancel(); proximaDNSDone() }, true
}
func proximaDNSAdd() {
 proximaDNSWorkers.Lock(); defer proximaDNSWorkers.Unlock()
 if proximaDNSWorkers.enabled { proximaDNSWorkers.wg.Add(1); proximaDNSWorkers.active++ }
}
func proximaDNSDone() {
 proximaDNSWorkers.Lock(); defer proximaDNSWorkers.Unlock()
 if proximaDNSWorkers.enabled { proximaDNSWorkers.active--; proximaDNSWorkers.wg.Done() }
}
func proximaDNSGo(fn func()) {
 proximaDNSAdd()
 go func(){ defer proximaDNSDone(); fn() }()
}
func proximaDNSRegister(c dnsClient) {
 proximaDNSWorkers.Lock(); defer proximaDNSWorkers.Unlock()
 if proximaDNSWorkers.enabled { if closer, ok := c.(io.Closer); ok { proximaDNSWorkers.clients = append(proximaDNSWorkers.clients, closer) } }
}
func (r *Resolver) proximaDoChan(key string, fn func() (*D.Msg, error)) <-chan singleflight.Result[*D.Msg] {
 ch := make(chan singleflight.Result[*D.Msg], 1)
 // Use the real singleflight's synchronous Do inside a counted job, rather
 // than its unobservable DoChan goroutine (including ignored retry results).
 proximaDNSGo(func(){ value, err, shared := r.group.Do(key, fn); ch <- singleflight.Result[*D.Msg]{Val: value, Err: err, Shared: shared} })
 return ch
}
func ProximaCancel() {
 proximaDNSWorkers.Lock()
 if !proximaDNSWorkers.enabled { proximaDNSWorkers.Unlock(); return }
 proximaDNSWorkers.stopped = true
 proximaDNSWorkers.cancel()
 proximaDNSWorkers.Unlock()
}
func ProximaStop() {
 ProximaCancel()
 proximaDNSWorkers.wg.Wait()
 // No exchange/refresh can recreate clients now. Close native HTTP/2, QUIC
 // and DoT pools explicitly instead of relying on runtime finalizers.
 for _, c := range proximaDNSWorkers.clients { _ = c.Close() }
 proximaDNSWorkers.clients = nil
}
func ProximaActiveWorkers() int {
 proximaDNSWorkers.Lock(); defer proximaDNSWorkers.Unlock(); return proximaDNSWorkers.active
}
`
