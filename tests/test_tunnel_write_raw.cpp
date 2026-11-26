// Anomaly Coop unit tests: TunnelMsg::write_raw writes a Tunnel from a packet the caller holds. Its bytes are those of
// TunnelMsg::write (golden), and it refuses what write refuses, writing nothing.
#include "test_util.h"
#include "srv/coop_levels_wire.h"

#include <cstdint>
#include <vector>

using namespace coop;
using namespace coop::levels::wire;

TEST(tunnel_write_raw_golden_bytes)
{
	const std::vector<uint8_t> packet = {0x10, 0x01, 0xAA, 0xBB, 0xCC};
	Writer w;
	REQUIRE(TunnelMsg::write_raw(w, 0x01020304u, TunnelMsg::LaneBulk, packet.data(), packet.size()));
	const std::vector<uint8_t> golden = {0x04, 0x03, 0x02, 0x01, 0x04, 0x05, 0x00, 0x10, 0x01, 0xAA, 0xBB, 0xCC};
	CHECK(w.data() == golden);
}

TEST(tunnel_write_raw_is_write)
{
	TunnelMsg m;
	m.peer = 7;
	m.flags = TunnelMsg::AllOnMap | TunnelMsg::LaneUnreliable;
	m.packet = {0x22, 0x01, 1, 2, 3, 4, 5, 6, 7, 8};
	Writer a;
	Writer b;
	REQUIRE(m.write(a));
	REQUIRE(TunnelMsg::write_raw(b, m.peer, m.flags, m.packet.data(), m.packet.size()));
	CHECK(a.data() == b.data());

	TunnelMsg back;
	Reader r(b.ptr(), b.size());
	REQUIRE(back.read(r));
	CHECK(r.remaining() == 0);
	CHECK(back.peer == m.peer && back.flags == m.flags && back.packet == m.packet);
}

TEST(tunnel_write_raw_refuses_a_packet_over_the_limit_and_writes_nothing)
{
	const std::vector<uint8_t> last(kMaxTunnelPacket, 0x01);
	Writer fits;
	CHECK(TunnelMsg::write_raw(fits, 1, 0, last.data(), last.size()));
	CHECK_EQ(fits.size(), size_t(4 + 1 + 2) + kMaxTunnelPacket);

	const std::vector<uint8_t> over(kMaxTunnelPacket + 1, 0x01);
	Writer w;
	w.u8(0x5A);
	CHECK(!TunnelMsg::write_raw(w, 1, 0, over.data(), over.size()));
	CHECK_EQ(w.size(), size_t(1));

	TunnelMsg m;
	m.packet = over;
	Writer v;
	CHECK(!m.write(v));
	CHECK_EQ(v.size(), size_t(0));
}
