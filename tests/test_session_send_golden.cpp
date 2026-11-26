// Anomaly Coop unit tests: what a host's Session puts on the wire for each peer. Bare ENet clients join a real host over
// 127.0.0.1 and record every packet they get (its channel and every byte): the bytes, the lane and the order of what send() and
// broadcast() hand the transport stay exactly these, whichever way the session builds its packets. The host's counters of the
// same sends are pinned with them.
#include "test_util.h"

#include <enet/enet.h>

#include <cstddef>
#include <vector>

using namespace coop;

namespace
{
// A joined player that speaks the protocol by hand and keeps every game message it gets as it came.
struct WireClient
{
	struct Packet
	{
		uint8_t channel = 0;
		std::vector<uint8_t> bytes; // the 2-byte type first
	};

	ENetHost* host = nullptr;
	ENetPeer* peer = nullptr;
	bool connected = false;
	bool welcomed = false;
	std::vector<Packet> got;

	WireClient() { enet_initialize(); }
	~WireClient()
	{
		if (host)
			enet_host_destroy(host);
		enet_deinitialize();
	}
	WireClient(const WireClient&) = delete;
	WireClient& operator=(const WireClient&) = delete;

	void service()
	{
		ENetEvent ev;
		while (host && enet_host_service(host, &ev, 0) > 0)
		{
			if (ev.type == ENET_EVENT_TYPE_CONNECT)
				connected = true;
			else if (ev.type == ENET_EVENT_TYPE_RECEIVE)
			{
				const uint16_t type =
					ev.packet->dataLength >= 2 ? uint16_t(ev.packet->data[0] | (ev.packet->data[1] << 8)) : 0;
				if (type == uint16_t(Msg::Welcome))
					welcomed = true;
				if (type >= uint16_t(Msg::GameBase))
				{
					Packet p;
					p.channel = ev.channelID;
					p.bytes.assign(ev.packet->data, ev.packet->data + ev.packet->dataLength);
					got.push_back(std::move(p));
				}
				enet_packet_destroy(ev.packet);
			}
		}
	}

	bool join(t::Node& at, uint16_t port, const char* nick)
	{
		host = enet_host_create(nullptr, 1, size_t(Lane::Count), 0, 0);
		if (!host)
			return false;
		ENetAddress addr;
		enet_address_set_host(&addr, "127.0.0.1");
		addr.port = port;
		peer = enet_host_connect(host, &addr, size_t(Lane::Count), 0);
		if (!peer || !t::pump_until({&at.s}, 3000, [&] {
				service();
				return connected;
			}))
			return false;
		HelloMsg h;
		h.build_id = at.cfg.build_id;
		h.content_fp = manifest_fingerprint(at.cfg.manifest);
		h.key = generate_player_key();
		h.nick = nick;
		Writer w;
		h.write(w);
		std::vector<uint8_t> buf = {uint8_t(Msg::Hello), 0};
		buf.insert(buf.end(), w.data().begin(), w.data().end());
		enet_peer_send(peer, 0, enet_packet_create(buf.data(), buf.size(), ENET_PACKET_FLAG_RELIABLE));
		enet_host_flush(host);
		return t::pump_until({&at.s}, 3000, [&] {
			service();
			return welcomed;
		});
	}

	// The game messages of one channel, in the order they came.
	std::vector<std::vector<uint8_t>> on(Lane lane) const
	{
		std::vector<std::vector<uint8_t>> out;
		for (const Packet& p : got)
			if (p.channel == uint8_t(lane))
				out.push_back(p.bytes);
		return out;
	}
};

Writer payload_of(size_t size, uint8_t seed)
{
	Writer w;
	for (size_t i = 0; i < size; ++i)
		w.u8(uint8_t(seed + i * 7));
	return w;
}

std::vector<uint8_t> packet_of(Msg type, const Writer& payload)
{
	std::vector<uint8_t> out = {uint8_t(uint16_t(type)), uint8_t(uint16_t(type) >> 8)};
	out.insert(out.end(), payload.data().begin(), payload.data().end());
	return out;
}

struct Joined
{
	t::Node host;
	WireClient one, two;

	explicit Joined(uint16_t port) : host("Boss", port)
	{
		std::string err;
		host.cfg.mode = SessionMode::Coop;
		REQUIRE(host.host(&err));
		REQUIRE(one.join(host, port, "One"));
		REQUIRE(two.join(host, port, "Two"));
		REQUIRE(host.s.joined_count() == 2);
		pump(100); // the PeerLists of both joins are out
		one.got.clear();
		two.got.clear();
	}

	void pump(uint32_t ms)
	{
		t::pump_until({&host.s}, ms, [&] {
			one.service();
			two.service();
			return false;
		});
	}

	bool pump_until_got(size_t n_one, size_t n_two)
	{
		return t::pump_until({&host.s}, 3000, [&] {
			one.service();
			two.service();
			return one.got.size() >= n_one && two.got.size() >= n_two;
		});
	}

	uint64_t out_bytes(PeerId id) const
	{
		for (const PeerTraffic& p : host.s.peer_traffic())
			if (p.id == id)
				return p.out_bytes;
		return 0;
	}
};
} // namespace

TEST(session_send_golden_broadcast_and_send_bytes_per_peer)
{
	Joined j(t::port(37970));
	const Writer brief = payload_of(17, 3);
	const Writer state = payload_of(40, 11);
	const Writer to_one = payload_of(5, 200);
	const Writer not_one = payload_of(9, 50);
	const Writer big = payload_of(3000, 1); // over one MTU: fragments
	const Writer big_state = payload_of(2500, 77);
	const Writer bulk = payload_of(600, 9);
	const uint64_t before_one = j.out_bytes(1), before_two = j.out_bytes(2);

	j.host.s.broadcast(Lane::Reliable, Msg::EntityEvent, brief);
	j.host.s.broadcast(Lane::Unreliable, Msg::EntitySnapshot, state);
	j.host.s.send(1, Lane::Reliable, Msg::EntityHealth, to_one);
	j.host.s.broadcast(Lane::Reliable, Msg::EntityEvent, not_one, 1);
	j.host.s.broadcast(Lane::Reliable, Msg::EntityState, big);
	j.host.s.broadcast(Lane::Unreliable, Msg::EntitySnapshot, big_state);
	j.host.s.broadcast(Lane::Bulk, Msg::EntitySpawn, bulk);
	REQUIRE(j.pump_until_got(6, 6));
	j.pump(50); // nothing more comes

	const std::vector<std::vector<uint8_t>> one_reliable = {packet_of(Msg::EntityEvent, brief),
		packet_of(Msg::EntityHealth, to_one), packet_of(Msg::EntityState, big)};
	const std::vector<std::vector<uint8_t>> two_reliable = {packet_of(Msg::EntityEvent, brief),
		packet_of(Msg::EntityEvent, not_one), packet_of(Msg::EntityState, big)};
	const std::vector<std::vector<uint8_t>> unreliable = {packet_of(Msg::EntitySnapshot, state),
		packet_of(Msg::EntitySnapshot, big_state)};
	const std::vector<std::vector<uint8_t>> bulk_lane = {packet_of(Msg::EntitySpawn, bulk)};
	CHECK(j.one.on(Lane::Reliable) == one_reliable);
	CHECK(j.two.on(Lane::Reliable) == two_reliable);
	CHECK(j.one.on(Lane::Unreliable) == unreliable);
	CHECK(j.two.on(Lane::Unreliable) == unreliable);
	CHECK(j.one.on(Lane::Bulk) == bulk_lane);
	CHECK(j.two.on(Lane::Bulk) == bulk_lane);
	CHECK_EQ(j.one.got.size(), size_t(6));
	CHECK_EQ(j.two.got.size(), size_t(6));

	// The host counts every packet it hands the transport, per type and per link.
	CHECK_EQ(j.host.s.stats(uint16_t(Msg::EntityEvent)).sent_count, uint64_t(3));
	CHECK_EQ(j.host.s.stats(uint16_t(Msg::EntityEvent)).sent_bytes, uint64_t(2 * (2 + 17) + (2 + 9)));
	CHECK_EQ(j.host.s.stats(uint16_t(Msg::EntitySnapshot)).sent_count, uint64_t(4));
	CHECK_EQ(j.host.s.stats(uint16_t(Msg::EntitySnapshot)).sent_bytes, uint64_t(2 * (2 + 40) + 2 * (2 + 2500)));
	CHECK_EQ(j.host.s.stats(uint16_t(Msg::EntityHealth)).sent_count, uint64_t(1));
	CHECK_EQ(j.host.s.stats(uint16_t(Msg::EntityState)).sent_count, uint64_t(2));
	CHECK_EQ(j.host.s.stats(uint16_t(Msg::EntityState)).sent_bytes, uint64_t(2 * (2 + 3000)));
	CHECK_EQ(j.host.s.stats(uint16_t(Msg::EntitySpawn)).sent_count, uint64_t(2));
	CHECK_EQ(j.out_bytes(1) - before_one, uint64_t((2 + 17) + (2 + 40) + (2 + 5) + (2 + 3000) + (2 + 2500) + (2 + 600)));
	CHECK_EQ(j.out_bytes(2) - before_two, uint64_t((2 + 17) + (2 + 40) + (2 + 9) + (2 + 3000) + (2 + 2500) + (2 + 600)));
}

TEST(session_send_golden_many_broadcasts_keep_their_order)
{
	Joined j(t::port(37971));
	std::vector<std::vector<uint8_t>> want;
	for (uint8_t i = 0; i < 60; ++i)
	{
		const Writer w = payload_of(size_t(i) * 37 % 1900 + 1, i); // some over one MTU
		j.host.s.broadcast(Lane::Reliable, Msg::EntityState, w);
		want.push_back(packet_of(Msg::EntityState, w));
		if (i % 10 == 9)
			j.host.s.update(t::now_ms()); // the transport flushes between some of them
	}
	REQUIRE(j.pump_until_got(want.size(), want.size()));
	CHECK(j.one.on(Lane::Reliable) == want);
	CHECK(j.two.on(Lane::Reliable) == want);
}

TEST(session_send_golden_netsim_delays_the_same_bytes)
{
	Joined j(t::port(37972));
	NetSim sim;
	sim.lag_ms = 20;
	j.host.s.set_netsim(sim);
	const Writer a = payload_of(30, 5), b = payload_of(2000, 6);
	j.host.s.broadcast(Lane::Reliable, Msg::EntityEvent, a);
	j.host.s.broadcast(Lane::Reliable, Msg::EntityState, b, 2);
	REQUIRE(j.pump_until_got(2, 1));
	j.pump(50);
	const std::vector<std::vector<uint8_t>> one = {packet_of(Msg::EntityEvent, a), packet_of(Msg::EntityState, b)};
	const std::vector<std::vector<uint8_t>> two = {packet_of(Msg::EntityEvent, a)};
	CHECK(j.one.on(Lane::Reliable) == one);
	CHECK(j.two.on(Lane::Reliable) == two);
	// NetSim off again: the next broadcast goes out at once, with the same bytes.
	j.host.s.set_netsim(NetSim());
	j.host.s.broadcast(Lane::Reliable, Msg::EntityEvent, a);
	REQUIRE(j.pump_until_got(3, 2));
	CHECK(j.one.on(Lane::Reliable).back() == packet_of(Msg::EntityEvent, a));
	CHECK(j.two.on(Lane::Reliable).back() == packet_of(Msg::EntityEvent, a));
}
