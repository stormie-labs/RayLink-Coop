// Anomaly Coop unit tests: the transport's helper thread pumps ENet between the owner's frames (owner 2026-10-24:
// "frames must not affect the ping"). Events it takes wait in an inbox for the owner; what the owner believes about a
// peer must stay true until it has seen the event that changes it, exactly as when the owner pumped ENet alone.
#include "test_util.h"

#include "coop_transport.h"

#include <chrono>
#include <thread>
#include <vector>

using namespace coop;

namespace
{
// The owner side of one transport: every event its service() hands out, in order.
struct Side
{
	net::Transport tr;
	std::vector<net::Event> got;

	void pump()
	{
		net::Event ev;
		while (tr.service(ev) > 0)
			got.push_back(std::move(ev));
	}
	size_t count(net::Event::Type type) const
	{
		size_t n = 0;
		for (const net::Event& e : got)
			n += e.type == type;
		return n;
	}
	// Index in `got` of the n-th (0-based) event of `type`; got.size() if there is none.
	size_t index(net::Event::Type type, size_t n = 0) const
	{
		for (size_t i = 0; i < got.size(); ++i)
			if (got[i].type == type && n-- == 0)
				return i;
		return got.size();
	}
};

template <class F>
bool pump_until(std::initializer_list<Side*> sides, uint32_t ms, F done)
{
	const uint64_t start = t::now_ms();
	for (;;)
	{
		for (Side* s : sides)
			s->pump();
		if (done())
			return true;
		if (t::now_ms() - start >= ms)
			return false;
		std::this_thread::sleep_for(std::chrono::milliseconds(1));
	}
}

// Only the other sides pump: the host's owner is between frames (its helper keeps its link, it sees no events).
void others_for(std::initializer_list<Side*> sides, uint32_t ms)
{
	pump_until(sides, ms, [] { return false; });
}

net::Packet small_packet(uint16_t type)
{
	const uint8_t body[4] = {1, 2, 3, 4};
	return net::Transport::make_packet(Lane::Reliable, type, body, sizeof(body), nullptr, 0, {});
}

void connect_one(Side& host, Side& cl, uint16_t port, net::PeerHandle* host_side, net::PeerHandle* client_side)
{
	std::string err;
	REQUIRE(host.tr.listen(port, 4, &err));
	*client_side = cl.tr.connect("127.0.0.1", port, &err);
	REQUIRE(*client_side != nullptr);
	REQUIRE(pump_until({&host, &cl}, 5000, [&] {
		return host.count(net::Event::Type::Connect) == 1 && cl.count(net::Event::Type::Connect) == 1;
	}));
	*host_side = host.got[host.index(net::Event::Type::Connect)].peer;
}
} // namespace

// A leaves and B arrives while the host's owner is between frames. Its helper must not free A's slot (ENet frees it
// when it hands out the DISCONNECT): B would take it, and what the owner still sends "to A" would reach B.
TEST(transport_helper_keeps_a_left_peers_slot_until_the_owner_saw_it_leave)
{
	constexpr uint16_t kPort = 37901;
	Side host, a, b;
	net::PeerHandle on_a = nullptr, a_peer = nullptr;
	connect_one(host, a, kPort, &on_a, &a_peer);

	host.pump(); // the owner's last frame for now
	net::Transport::disconnect_now(a_peer);
	std::this_thread::sleep_for(std::chrono::milliseconds(100)); // the host's helper took A's goodbye
	std::string err;
	REQUIRE(b.tr.connect("127.0.0.1", kPort, &err) != nullptr);
	REQUIRE(pump_until({&b}, 1500, [&] { return b.count(net::Event::Type::Connect) == 1; })); // the helper let B in

	// The owner has not seen A leave: it still sends to A.
	CHECK(!host.tr.send(on_a, Lane::Reliable, small_packet(0x7001)));
	others_for({&b}, 300);
	CHECK_EQ(b.count(net::Event::Type::Receive), size_t(0));

	// Its next frame: A's leave, then B, on another slot.
	REQUIRE(pump_until({&host, &b}, 2000, [&] {
		return host.count(net::Event::Type::Disconnect) == 1 && host.count(net::Event::Type::Connect) == 2;
	}));
	CHECK(host.got[host.index(net::Event::Type::Disconnect)].peer == on_a);
	CHECK(host.index(net::Event::Type::Disconnect) < host.index(net::Event::Type::Connect, 1));
	CHECK(host.got[host.index(net::Event::Type::Connect, 1)].peer != on_a);
}

// The helper took A's packets into the inbox; then the owner resets A (a replaced link, a kick). ENet would have wiped
// them with the peer's queues: the owner must not get them after the reset.
TEST(transport_helper_inbox_forgets_a_peer_the_owner_reset)
{
	constexpr uint16_t kPort = 37902;
	Side host, a;
	net::PeerHandle on_a = nullptr, a_peer = nullptr;
	connect_one(host, a, kPort, &on_a, &a_peer);

	host.pump();
	for (uint16_t i = 0; i < 3; ++i)
		REQUIRE(a.tr.send(a_peer, Lane::Reliable, small_packet(uint16_t(0x7010 + i))));
	a.tr.flush();
	others_for({&a}, 150); // the host's helper took them
	net::Transport::reset(on_a);
	host.pump();
	CHECK_EQ(host.count(net::Event::Type::Receive), size_t(0));
}

// Between the owner's frames the helper hands nothing over, but the link stays prompt: a packet sent to us is
// delivered at the owner's next frame, in order, and nothing is lost or duplicated.
TEST(transport_helper_hands_over_packets_in_order)
{
	constexpr uint16_t kPort = 37903;
	Side host, a;
	net::PeerHandle on_a = nullptr, a_peer = nullptr;
	connect_one(host, a, kPort, &on_a, &a_peer);

	host.pump();
	for (uint16_t i = 0; i < 50; ++i)
		REQUIRE(a.tr.send(a_peer, Lane::Reliable, small_packet(uint16_t(0x7100 + i))));
	a.tr.flush();
	others_for({&a}, 150);
	REQUIRE(pump_until({&host, &a}, 2000, [&] { return host.count(net::Event::Type::Receive) == 50; }));
	others_for({&host, &a}, 50);
	CHECK_EQ(host.count(net::Event::Type::Receive), size_t(50));
	uint16_t want = 0x7100;
	for (const net::Event& e : host.got)
		if (e.type == net::Event::Type::Receive)
		{
			REQUIRE(e.bytes.size() >= 2);
			CHECK_EQ(uint16_t(e.bytes[0] | (e.bytes[1] << 8)), want);
			++want;
		}
}

// A sends its last word (a Reject, a Bye) and leaves while the host's owner is between frames. The helper took the
// packet before the goodbye came: the owner gets it, then the DISCONNECT (vault ENet gotcha 10: the goodbye wiped it).
TEST(transport_helper_hands_over_a_leaving_peers_last_packet)
{
	constexpr uint16_t kPort = 37904;
	Side host, a;
	net::PeerHandle on_a = nullptr, a_peer = nullptr;
	connect_one(host, a, kPort, &on_a, &a_peer);

	host.pump();
	REQUIRE(a.tr.send(a_peer, Lane::Reliable, small_packet(0x7201)));
	a.tr.flush();
	others_for({&a}, 100); // the host's helper took it
	net::Transport::disconnect_now(a_peer);
	std::this_thread::sleep_for(std::chrono::milliseconds(100)); // and the goodbye
	REQUIRE(pump_until({&host}, 2000, [&] { return host.count(net::Event::Type::Disconnect) == 1; }));
	REQUIRE(host.count(net::Event::Type::Receive) == 1);
	CHECK(host.index(net::Event::Type::Receive) < host.index(net::Event::Type::Disconnect));
}
