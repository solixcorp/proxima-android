package mihomodns

import (
	"context"
	"fmt"

	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/sing/common/buf"
	M "github.com/metacubex/sing/common/metadata"
	N "github.com/metacubex/sing/common/network"
	D "github.com/miekg/dns"
)

// HandleUDP returns false without touching request or writer for an unselected
// destination. Otherwise it consumes request on every outcome and synchronously
// relays a single datagram. The caller must keep writer and its transport alive
// until this method returns. WritePacket consumes the reply on success; on
// error this method releases it, matching sing_tun's ownership convention.
//
// The TUN dispatcher may run this in its own joined goroutine. Stop suppresses
// replies after canceled resolution; a write already entered may finish until
// the TUN owner interrupts the transport. Wait includes these pending writes.
func (s *Session) HandleUDP(ctx context.Context, request *buf.Buffer, destination M.Socksaddr, writer N.PacketWriter) (bool, error) {
	if !s.Matches(destination.AddrPort()) {
		return false, nil
	}
	op, err := s.begin(ctx)
	if err != nil {
		request.Release()
		return true, err
	}
	defer s.finish(op)
	defer request.Release()
	ctx, cancel := context.WithTimeout(op.ctx, resolver.DefaultDnsRelayTimeout)
	defer cancel()

	query := new(D.Msg)
	if err = query.Unpack(request.Bytes()); err != nil {
		return true, fmt.Errorf("parse DNS datagram: %w", err)
	}
	limit := min(max(resolver.RequestUDPSize(query), D.MinMsgSize), resolver.SafeDnsPacketSize)
	options := N.ReadWaitOptions{
		FrontHeadroom: N.CalculateFrontHeadroom(writer),
		RearHeadroom:  N.CalculateRearHeadroom(writer),
		MTU:           resolver.SafeDnsPacketSize,
	}
	reply := options.NewPacketBuffer()
	payload, err := resolver.RelayDnsPacket(ctx, request.Bytes(), reply.FreeBytes())
	if err != nil {
		reply.Release()
		return true, fmt.Errorf("relay DNS datagram: %w", err)
	}
	if err = ctx.Err(); err != nil {
		reply.Release()
		return true, err
	}
	if len(payload) > limit {
		// Native Truncate retains OPT records, even ones larger than the UDP
		// budget. Re-encode a complete TC response instead of clipping wire bytes
		// or sending an oversized datagram. Native relay normalizes to at most
		// one question; its header, question and an empty root OPT fit in 512.
		response := new(D.Msg)
		if err = response.Unpack(payload); err != nil {
			reply.Release()
			return true, fmt.Errorf("parse oversized DNS reply: %w", err)
		}
		opt := response.IsEdns0()
		response.Answer, response.Ns, response.Extra = nil, nil, nil
		response.Truncated = true
		response.Compress = true
		if opt != nil {
			// Retain native EDNS flags, version and extended RCODE. Option data
			// and answer records remain available through the native TCP relay.
			opt.Hdr.Name = "."
			opt.Option = nil
			response.Extra = []D.RR{opt}
		}
		payload, err = response.PackBuffer(reply.FreeBytes())
		if err != nil {
			reply.Release()
			return true, fmt.Errorf("pack truncated DNS reply: %w", err)
		}
	}
	// Copy the bounded native or re-encoded result into the packet buffer while
	// preserving writer headroom, without assuming the result aliases its target.
	if _, err = reply.Write(payload); err != nil {
		reply.Release()
		return true, fmt.Errorf("buffer DNS reply: %w", err)
	}
	if err = writer.WritePacket(reply, destination); err != nil {
		reply.Release()
		return true, fmt.Errorf("write DNS reply: %w", err)
	}
	return true, nil
}
