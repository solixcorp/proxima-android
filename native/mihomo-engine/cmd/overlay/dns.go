package main

// Opt-in single-session lifetime around the REAL DNSDialer, not a replacement
// transport. Admission forbids proxy/interface/skip-cert fragment overrides.
// This closes transport sockets and gates late native refresh/retry workers;
// those upstream workers still require process termination/reaping.
const dnsDialerSeam = `
var proximaDNS struct {
 sync.Mutex
 enabled bool
 stopped bool
 ctx context.Context
 cancel context.CancelFunc
 dials sync.WaitGroup
 sockets map[io.Closer]struct{}
}
func ProximaStartDNS() error {
 proximaDNS.Lock()
 defer proximaDNS.Unlock()
 if proximaDNS.enabled { return fmt.Errorf("DNS lifetime already consumed") }
 proximaDNS.enabled = true
 proximaDNS.ctx, proximaDNS.cancel = context.WithCancel(context.Background())
 proximaDNS.sockets = make(map[io.Closer]struct{})
 return nil
}
func proximaBeginDNS(ctx context.Context) (context.Context, func(), bool, error) {
 proximaDNS.Lock()
 defer proximaDNS.Unlock()
 if !proximaDNS.enabled { return ctx, func(){}, false, nil }
 if proximaDNS.stopped { return ctx, func(){}, true, net.ErrClosed }
 proximaDNS.dials.Add(1)
 ctx, cancel := context.WithCancel(ctx)
 stop := context.AfterFunc(proximaDNS.ctx, cancel)
 return ctx, func(){ stop(); cancel(); proximaDNS.dials.Done() }, true, nil
}
func proximaTrackDNS(c io.Closer) error {
 proximaDNS.Lock()
 defer proximaDNS.Unlock()
 if proximaDNS.stopped { return net.ErrClosed }
 proximaDNS.sockets[c] = struct{}{}
 return nil
}
func proximaForgetDNS(c io.Closer) {
 proximaDNS.Lock()
 delete(proximaDNS.sockets, c)
 proximaDNS.Unlock()
}
type proximaDNSConn struct { net.Conn; once sync.Once; err error }
func (c *proximaDNSConn) Close() error {
 c.once.Do(func(){ c.err = c.Conn.Close(); proximaForgetDNS(c) })
 return c.err
}
// miekg/dns distinguishes UDP from TCP by net.PacketConn, NOT the network
// argument. Preserve that capability or it writes TCP length prefixes to UDP.
type proximaDNSPacketStream struct { *proximaDNSConn; packet net.PacketConn }
func (c *proximaDNSPacketStream) ReadFrom(p []byte) (int, net.Addr, error) { return c.packet.ReadFrom(p) }
func (c *proximaDNSPacketStream) WriteTo(p []byte, addr net.Addr) (int, error) { return c.packet.WriteTo(p, addr) }
type proximaDNSPacketConn struct { net.PacketConn; once sync.Once; err error }
func (c *proximaDNSPacketConn) Close() error {
 c.once.Do(func(){ c.err = c.PacketConn.Close(); proximaForgetDNS(c) })
 return c.err
}
func (d *DNSDialer) DialContext(ctx context.Context, network, addr string) (net.Conn, error) {
 ctx, done, scoped, err := proximaBeginDNS(ctx)
 if err != nil { return nil, err }; defer done()
 c, err := d.proximaDialContext(ctx, network, addr)
 if err != nil || !scoped { return c, err }
 tracked := &proximaDNSConn{Conn: c}
 if err := proximaTrackDNS(tracked); err != nil { tracked.Close(); return nil, err }
 if pc, ok := c.(net.PacketConn); ok { return &proximaDNSPacketStream{proximaDNSConn: tracked, packet: pc}, nil }
 return tracked, nil
}
func (d *DNSDialer) ListenPacket(ctx context.Context, network, addr string) (net.PacketConn, error) {
 ctx, done, scoped, err := proximaBeginDNS(ctx)
 if err != nil { return nil, err }; defer done()
 c, err := d.proximaListenPacket(ctx, network, addr)
 if err != nil || !scoped { return c, err }
 tracked := &proximaDNSPacketConn{PacketConn: c}
 if err := proximaTrackDNS(tracked); err != nil { tracked.Close(); return nil, err }
 return tracked, nil
}
func ProximaStopDNS() {
 proximaDNS.Lock()
 if !proximaDNS.enabled { proximaDNS.Unlock(); return }
 proximaDNS.stopped = true
 proximaDNS.cancel()
 proximaDNS.Unlock()
 proximaDNS.dials.Wait()
 proximaDNS.Lock()
 sockets := make([]io.Closer, 0, len(proximaDNS.sockets))
 for socket := range proximaDNS.sockets { sockets = append(sockets, socket) }
 proximaDNS.Unlock()
 for _, socket := range sockets { _ = socket.Close() }
}
`
