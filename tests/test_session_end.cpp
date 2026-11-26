// Anomaly Coop unit tests: how a client's session ended, for what the player is told in the main menu (Session::end_code), and
// the client's own limit on a silent host (Session::drop_silent_host).
// Live 2026-11-01: the host went silent, the client's countdown read 0 at 30 s, ENet let go of the link at 51.6 s.
#include "test_util.h"

using namespace coop;

namespace
{
void join(t::Node& host, t::Node& cl, uint16_t port)
{
	std::string err;
	host.cfg.mode = SessionMode::Coop;
	REQUIRE(host.host(&err));
	REQUIRE(cl.connect(port, &err));
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return cl.s.is_active() && host.s.peers().size() == 1; }));
}
} // namespace

TEST(session_end_host_quit_on_purpose)
{
	t::Node host("Boss", t::port(37220)), cl("Alice", t::port(37220));
	join(host, cl, t::port(37220));
	host.s.shutdown("left the session");
	REQUIRE(t::pump_until({&cl.s}, 3000, [&] { return cl.disconnected; }));
	CHECK_EQ(cl.s.end_code(), std::string(kEndHostLeft));
	CHECK_EQ(cl.disc_reason, std::string("left the session"));
}

TEST(session_end_host_silent_is_a_lost_connection)
{
	t::Node host("Boss", t::port(37221)), cl("Alice", t::port(37221));
	cl.cfg.peer_timeout_ms = 800;
	join(host, cl, t::port(37221));
	REQUIRE(t::pump_until({&cl.s}, 15000, [&] { return cl.disconnected; })); // the host's process stands still
	CHECK_EQ(cl.s.end_code(), std::string(kEndLost));
}

TEST(session_end_kick_keeps_the_reason)
{
	t::Node host("Boss", t::port(37222)), cl("Alice", t::port(37222));
	join(host, cl, t::port(37222));
	host.s.kick(cl.s.self(), RejectReason::Kicked, "ask the host why");
	REQUIRE(t::pump_until({&host.s, &cl.s}, 3000, [&] { return cl.disconnected; }));
	CHECK_EQ(cl.s.end_code(), std::string(reject_reason_name(RejectReason::Kicked)));
	CHECK(cl.disc_reason.find("ask the host why") != std::string::npos);
}

TEST(session_end_a_refusal_after_joining_is_named_by_its_reason)
{
	t::Node host("Boss", t::port(37223)), cl("Alice", t::port(37223));
	join(host, cl, t::port(37223));
	host.s.kick(cl.s.self(), RejectReason::HostNotReady, "host is not in a game right now, try again later");
	REQUIRE(t::pump_until({&host.s, &cl.s}, 3000, [&] { return cl.disconnected; }));
	CHECK_EQ(cl.s.end_code(), std::string(reject_reason_name(RejectReason::HostNotReady)));
}

TEST(session_end_a_refusal_at_the_door_still_goes_to_on_rejected)
{
	t::Node host("Boss", t::port(37224)), cl("Alice", t::port(37224));
	cl.cfg.build_id = "another-build";
	std::string err;
	host.cfg.mode = SessionMode::Coop;
	REQUIRE(host.host(&err));
	REQUIRE(cl.connect(t::port(37224), &err));
	REQUIRE(t::pump_until({&host.s, &cl.s}, 3000, [&] { return cl.rejected || cl.disconnected; }));
	CHECK(cl.rejected); // the version mismatch has its own window (coop_ui.on_rejected), with the reason of the host
	CHECK(!cl.disconnected);
	CHECK(cl.reject.reason == RejectReason::BuildMismatch);
}

TEST(session_end_a_client_lets_a_silent_host_go_at_its_own_limit)
{
	t::Node host("Boss", t::port(37225)), cl("Alice", t::port(37225));
	join(host, cl, t::port(37225)); // peer_timeout_ms is 15 s here: ENet alone would wait for all of it
	const uint64_t t0 = t::now_ms();
	cl.s.drop_silent_host();
	CHECK(cl.disconnected); // at once: the manager calls it from its frame, between pumps
	CHECK(t::now_ms() - t0 < 1000);
	CHECK(!cl.s.is_active());
	CHECK_EQ(cl.disc_reason, std::string("connection to host lost"));
	CHECK_EQ(cl.s.end_code(), std::string(kEndLost));
}

TEST(session_end_a_host_has_no_host_to_lose)
{
	t::Node host("Boss", t::port(37226)), cl("Alice", t::port(37226));
	join(host, cl, t::port(37226));
	host.s.drop_silent_host();
	CHECK(host.s.is_active());
	t::pump_for({&host.s, &cl.s}, 100);
	CHECK(!cl.disconnected);
	CHECK_EQ(host.s.peers().size(), size_t(1));
}

TEST(session_end_a_new_session_forgets_the_last_end)
{
	t::Node host("Boss", t::port(37227)), cl("Alice", t::port(37227));
	join(host, cl, t::port(37227));
	host.s.shutdown("left the session");
	REQUIRE(t::pump_until({&cl.s}, 3000, [&] { return cl.disconnected; }));
	std::string err;
	host.cfg.mode = SessionMode::Coop;
	REQUIRE(host.host(&err));
	cl.disconnected = false;
	REQUIRE(cl.connect(t::port(37227), &err));
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return cl.s.is_active() && host.s.peers().size() == 1; }));
	CHECK_EQ(cl.s.end_code(), std::string(kEndLost)); // what a session that is cut off later reports unless it knows better
}
