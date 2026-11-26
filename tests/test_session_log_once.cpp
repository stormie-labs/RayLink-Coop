// Anomaly Coop unit tests: a line the session logs once is logged once per session. A long-running host goes through many
// sessions; one that ended must not silence the same line of the next one.
#include "test_util.h"

#include <string>

using namespace coop;

namespace
{
size_t count_lines(const t::Node& n, const std::string& needle)
{
	size_t k = 0;
	for (const std::string& line : n.log)
		k += line.find(needle) != std::string::npos;
	return k;
}
} // namespace

TEST(session_log_once_per_session_not_per_process)
{
	t::Node host("Boss", t::port(37975));
	host.cfg.mode = SessionMode::Coop;
	const std::string line = "send(EntityEvent): peer 5 is not joined, ignored";
	std::string err;
	REQUIRE(host.host(&err));
	host.s.send(5, Lane::Reliable, Msg::EntityEvent, Writer());
	host.s.send(5, Lane::Reliable, Msg::EntityEvent, Writer());
	CHECK_EQ(count_lines(host, line), size_t(1));
	host.s.send(6, Lane::Reliable, Msg::EntityEvent, Writer()); // another peer has its own line
	CHECK_EQ(count_lines(host, "peer 6 is not joined"), size_t(1));

	host.s.shutdown("next session");
	REQUIRE(host.host(&err));
	host.s.send(5, Lane::Reliable, Msg::EntityEvent, Writer());
	host.s.send(5, Lane::Reliable, Msg::EntityEvent, Writer());
	CHECK_EQ(count_lines(host, line), size_t(2));
	host.s.shutdown("done");
}

TEST(session_log_once_a_client_line_comes_back_in_the_next_session)
{
	t::Node host("Boss", t::port(37976)), cl("Alice", t::port(37976));
	host.cfg.mode = SessionMode::Coop;
	std::string err;
	REQUIRE(host.host(&err));
	const auto join = [&] {
		REQUIRE(cl.connect(t::port(37976), &err));
		REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return cl.s.is_active() && host.s.joined_count() == 1; }));
	};
	const std::string line = "clients can only send to the host (peer 0), ignored";
	join();
	cl.s.send(3, Lane::Reliable, Msg::EntityEvent, Writer());
	cl.s.send(3, Lane::Reliable, Msg::EntityEvent, Writer());
	CHECK_EQ(count_lines(cl, line), size_t(1));
	cl.s.shutdown("leaving");
	REQUIRE(t::pump_until({&host.s}, 3000, [&] { return host.s.joined_count() == 0; }));
	join();
	cl.s.send(3, Lane::Reliable, Msg::EntityEvent, Writer());
	CHECK_EQ(count_lines(cl, line), size_t(2));
}
