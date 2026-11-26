// Ядро: без проверок режима (docs/MODES.md)
#include "test_util.h"
#include "coop_transport.h"

#include <algorithm>
#include <array>
#include <memory>

using namespace coop;

namespace
{
using Clock = std::chrono::steady_clock;

PeerTraffic traffic_of(const Session& session, PeerId id)
{
	const auto rows = session.peer_traffic();
	const auto it = std::find_if(rows.begin(), rows.end(), [id](const PeerTraffic& row) { return row.id == id; });
	REQUIRE(it != rows.end());
	return *it;
}

Writer packet_body(size_t packet_bytes)
{
	const std::vector<uint8_t> body(packet_bytes - 2, 0x5a); // Transport adds the u16 message type.
	Writer w;
	w.bytes(body.data(), body.size());
	return w;
}
} // namespace

TEST(seat_bench_transport_counts_exact_bytes_and_resets_reused_slot)
{
	using namespace net;
	const uint16_t port = t::port(38930);
	Transport host, client;
	REQUIRE(host.listen(port, 1, nullptr));
	const auto connect = [&] {
		PeerHandle server_peer = nullptr;
		PeerHandle client_peer = client.connect("127.0.0.1", port, nullptr);
		REQUIRE(client_peer);
		const auto end = Clock::now() + std::chrono::seconds(5);
		bool client_connected = false;
		while ((!server_peer || !client_connected) && Clock::now() < end)
		{
			Event ev;
			if (host.service(ev) == 1 && ev.type == Event::Type::Connect)
				server_peer = ev.peer;
			if (client.service(ev) == 1 && ev.type == Event::Type::Connect)
				client_connected = true;
			std::this_thread::sleep_for(std::chrono::milliseconds(1));
		}
		REQUIRE(server_peer && client_connected);
		return std::make_pair(server_peer, client_peer);
	};
	const auto [server_peer, client_peer] = connect();
	const std::array<uint8_t, 10> payload{};
	REQUIRE(host.send(server_peer, Lane::Reliable,
		Transport::make_packet(Lane::Reliable, 0x100, payload.data(), payload.size(), nullptr, 0, nullptr)));
	REQUIRE(client.send(client_peer, Lane::Reliable,
		Transport::make_packet(Lane::Reliable, 0x100, payload.data(), 3, nullptr, 0, nullptr)));
	CHECK(!host.send(nullptr, Lane::Reliable,
		Transport::make_packet(Lane::Reliable, 0x100, payload.data(), payload.size(), nullptr, 0, nullptr)));
	bool host_received = false, client_received = false;
	const auto receive = [](Transport& transport, bool& received, size_t bytes) {
		Event ev;
		if (transport.service(ev) == 1 && ev.type == Event::Type::Receive)
		{
			CHECK(!received);
			CHECK_EQ(ev.bytes.size(), bytes);
			received = true;
		}
	};
	const auto pump_pair = [&] {
		receive(host, host_received, 5);
		receive(client, client_received, 12);
	};
	REQUIRE(t::pump_until({}, 5000, [&] {
		pump_pair();
		return host_received && client_received;
	}));
	const auto single = [](const Transport& transport, PeerHandle peer) {
		const auto rows = transport.traffic({peer});
		REQUIRE(rows.size() == 1);
		return rows.front();
	};
	Transport::Traffic server_stats;
	REQUIRE(t::pump_until({}, 2000, [&] {
		pump_pair();
		server_stats = single(host, server_peer);
		return server_stats.out_5s && server_stats.in_5s;
	}));
	CHECK_EQ(server_stats.out_bytes, uint64_t(12));
	CHECK_EQ(server_stats.in_bytes, uint64_t(5));
	CHECK_EQ(server_stats.out_5s, uint64_t(12));
	CHECK_EQ(server_stats.in_5s, uint64_t(5));
	const auto client_stats = single(client, client_peer);
	CHECK_EQ(client_stats.out_bytes, uint64_t(5));
	CHECK_EQ(client_stats.in_bytes, uint64_t(12));
	Transport::Traffic expired;
	REQUIRE(t::pump_until({}, 6000, [&] {
		pump_pair();
		expired = single(host, server_peer);
		return !expired.out_5s && !expired.in_5s;
	}));
	CHECK_EQ(expired.out_5s, uint64_t(0));
	CHECK_EQ(expired.in_5s, uint64_t(0));
	CHECK_EQ(expired.out_bytes, uint64_t(12));

	client.disconnect_now(client_peer);
	const auto end = Clock::now() + std::chrono::seconds(5);
	Event ev;
	do
	{
		host.service(ev, 1);
	} while (ev.type != Event::Type::Disconnect && Clock::now() < end);
	REQUIRE(ev.type == Event::Type::Disconnect);
	client.destroy();
	const auto reused = connect();
	CHECK_EQ(reused.first, server_peer);
	const auto fresh = single(host, reused.first);
	CHECK_EQ(fresh.out_bytes, uint64_t(0));
	CHECK_EQ(fresh.in_bytes, uint64_t(0));
	CHECK_EQ(fresh.out_5s, uint64_t(0));
	CHECK_EQ(fresh.in_5s, uint64_t(0));

	// Both peers have slot zero on different ENet hosts. A transport takes only its own peers (each has a lock of its own,
	// another host's peer is another lock's): a send through the foreign handle is refused and counts toward neither slot zero.
	CHECK(!host.send(reused.second, Lane::Reliable,
		Transport::make_packet(Lane::Reliable, 0x100, payload.data(), 3, nullptr, 0, nullptr)));
	CHECK_EQ(single(host, reused.first).out_bytes, uint64_t(0));
	CHECK_EQ(single(client, reused.second).out_bytes, uint64_t(0));

	// A valid send on the same reliable lane must arrive without the rejected packet preceding it.
	REQUIRE(client.send(reused.second, Lane::Reliable,
		Transport::make_packet(Lane::Reliable, 0x100, payload.data(), payload.size(), nullptr, 0, nullptr)));
	host_received = false;
	REQUIRE(t::pump_until({}, 5000, [&] {
		client.service(ev);
		receive(host, host_received, payload.size() + 2);
		return host_received;
	}));
	CHECK_EQ(single(host, reused.first).in_bytes, uint64_t(payload.size() + 2));
}

TEST(seat_bench_coop_session_peer_traffic_counts_both_directions)
{
	const uint16_t port = t::port(38931);
	t::Node host("Boss", port), client("Alice", port);
	host.cfg.mode = SessionMode::Coop;
	unsigned host_received = 0, client_received = 0;
	host.s.on(Msg::ScriptEvent, [&](PeerId from, Reader& r) {
		CHECK_EQ(from, client.welcome.slot);
		CHECK_EQ(r.remaining(), size_t(10));
		++host_received;
	});
	client.s.on(Msg::ScriptEvent, [&](PeerId from, Reader& r) {
		CHECK_EQ(from, kHostPeer);
		CHECK_EQ(r.remaining(), size_t(3));
		++client_received;
	});
	REQUIRE(host.host());
	REQUIRE(client.connect(port));
	REQUIRE(t::pump_until({&host.s, &client.s}, 5000, [&] { return client.welcomed; }));
	t::pump_for({&host.s, &client.s}, 100);
	const PeerId id = client.welcome.slot;
	const auto before_host = traffic_of(host.s, id);
	const auto before_client = traffic_of(client.s, kHostPeer);
	CHECK_EQ(host.s.peer_traffic().size(), size_t(1)); // The playing host's own seat has no transport.
	CHECK_EQ(client.s.peer_traffic().size(), size_t(1));
	for (unsigned i = 0; i < 37; ++i)
	{
		client.s.send(kHostPeer, Lane::Reliable, Msg::ScriptEvent, packet_body(12));
		host.s.send(id, Lane::Reliable, Msg::ScriptEvent, packet_body(5));
	}
	REQUIRE(t::pump_until({&host.s, &client.s}, 5000, [&] { return host_received == 37 && client_received == 37; }));
	const auto after_host = traffic_of(host.s, id);
	const auto after_client = traffic_of(client.s, kHostPeer);
	CHECK_EQ(after_host.out_bytes - before_host.out_bytes, uint64_t(37 * 5));
	CHECK_EQ(after_host.in_bytes - before_host.in_bytes, uint64_t(37 * 12));
	CHECK_EQ(after_client.out_bytes - before_client.out_bytes, uint64_t(37 * 12));
	CHECK_EQ(after_client.in_bytes - before_client.in_bytes, uint64_t(37 * 5));
	host.s.shutdown("bench over");
	CHECK(host.s.peer_traffic().empty());
}

TEST(seat_bench_server_sixteen_clients_ten_seconds)
{
	const uint16_t port = t::port(38932);
	constexpr size_t seats = 16, unreliable_bytes = 1100, reliable_bytes = 200;
	constexpr unsigned seconds = 10, frames_hz = 60, unreliable_hz = 15, reliable_hz = 5;
	constexpr unsigned frames = seconds * frames_hz;
	constexpr unsigned unreliable_packets = seconds * unreliable_hz, reliable_packets = seconds * reliable_hz;
	std::array<unsigned, seats> unreliable{}, reliable{};
	t::Node host("World server", port);
	host.cfg.host_plays = false;
	host.cfg.max_players = seats;
	host.cfg.mode = SessionMode::Server;
	REQUIRE(host.host());

	std::array<std::unique_ptr<t::Node>, seats> clients;
	for (size_t i = 0; i < seats; ++i)
	{
		clients[i] = std::make_unique<t::Node>("Client" + std::to_string(i + 1), port);
		clients[i]->s.on(Msg::PlayerState, [&, i](PeerId from, Reader& r) {
			CHECK_EQ(from, kHostPeer);
			CHECK_EQ(r.remaining() + 2, unreliable_bytes);
			++unreliable[i];
		});
		clients[i]->s.on(Msg::ScriptEvent, [&, i](PeerId from, Reader& r) {
			CHECK_EQ(from, kHostPeer);
			CHECK_EQ(r.remaining() + 2, reliable_bytes);
			++reliable[i];
		});
		REQUIRE(clients[i]->connect(port));
	}
	const auto update_clients = [&] {
		for (auto& client : clients)
			client->s.update(t::now_ms());
	};
	REQUIRE(t::pump_until({&host.s}, 5000, [&] {
		update_clients();
		return std::all_of(clients.begin(), clients.end(), [](const auto& c) { return c->welcomed; });
	}));
	t::pump_until({&host.s}, 100, [&] {
		update_clients();
		return false;
	});
	const auto before = host.s.peer_traffic();
	REQUIRE(before.size() == seats);

	const Writer snapshots = packet_body(unreliable_bytes);
	const Writer events = packet_body(reliable_bytes);
	Clock::duration host_update_time{};
	const auto start = Clock::now();
	for (unsigned frame = 0; frame < frames; ++frame)
	{
		std::this_thread::sleep_until(start + std::chrono::microseconds(1000000LL * frame / frames_hz));
		if (frame % (frames_hz / unreliable_hz) == 0)
			host.s.broadcast(Lane::Unreliable, Msg::PlayerState, snapshots);
		if (frame % (frames_hz / reliable_hz) == 0)
			host.s.broadcast(Lane::Reliable, Msg::ScriptEvent, events);
		const auto update_start = Clock::now();
		host.s.update(t::now_ms());
		host_update_time += Clock::now() - update_start;
		update_clients();
	}
	std::this_thread::sleep_until(start + std::chrono::seconds(seconds));
	const double elapsed = std::chrono::duration<double>(Clock::now() - start).count();
	REQUIRE(t::pump_until({&host.s}, 3000, [&] {
		update_clients();
		return std::all_of(reliable.begin(), reliable.end(), [reliable_packets](unsigned n) { return n == reliable_packets; });
	}));

	const auto after = host.s.peer_traffic();
	REQUIRE(after.size() == seats);
	uint64_t out = 0, in = 0;
	unsigned unreliable_delivered = 0, reliable_delivered = 0;
	for (size_t i = 0; i < seats; ++i)
	{
		CHECK(unreliable[i] * 100 >= unreliable_packets * 95 && unreliable[i] <= unreliable_packets);
		CHECK_EQ(reliable[i], reliable_packets);
		CHECK_EQ(before[i].id, after[i].id);
		CHECK_EQ(after[i].out_bytes - before[i].out_bytes,
			uint64_t(unreliable_packets * unreliable_bytes + reliable_packets * reliable_bytes));
		out += after[i].out_bytes - before[i].out_bytes;
		in += after[i].in_bytes - before[i].in_bytes;
		unreliable_delivered += unreliable[i];
		reliable_delivered += reliable[i];
	}
	std::printf("    16 seats: unreliable %u/%u, reliable %u/%u, host out %.0f B/s in %.0f B/s, update %.1f us/frame (%u frames)\n",
		unreliable_delivered, unsigned(seats * unreliable_packets), reliable_delivered,
		unsigned(seats * reliable_packets), double(out) / elapsed, double(in) / elapsed,
		std::chrono::duration<double, std::micro>(host_update_time).count() / frames, frames);
}
