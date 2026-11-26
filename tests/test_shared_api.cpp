// Anomaly Coop unit tests: the small shared API the cleanup packages adopt (Mode::decides_here, Session::for_each_joined and
// joined_count, Writer::patch_u16 / patch_u32 / varu_size). Each answers what the spelling it replaces answered.
#include "test_util.h"

#include "coop_session.h"
#include "coop_wire.h"
#include "support/fake_mode.h"

#include <string>
#include <vector>

using namespace coop;

TEST(shared_api_decides_here_is_world_or_level_for_every_kind)
{
	for (const t::ModeCase& c : t::mode_cases())
	{
		t::FakeMode m(c);
		CHECK_EQ(m.decides_here(), m.decides_world() || m.leads_level());
	}
}

TEST(shared_api_writer_patch_and_varu_size)
{
	Writer w;
	w.u8(7);
	const size_t count_at = w.size();
	w.u16(0);
	const size_t size_at = w.size();
	w.u32(0);
	w.str("abc");
	w.patch_u16(count_at, 0xbeef);
	w.patch_u32(size_at, 0x01020304u);

	Writer same;
	same.u8(7);
	same.u16(0xbeef);
	same.u32(0x01020304u);
	same.str("abc");
	CHECK(w.data() == same.data());

	const uint64_t values[] = {0, 1, 0x7f, 0x80, 0x3fff, 0x4000, 0xffffffffull, ~0ull};
	for (const uint64_t v : values)
	{
		Writer one;
		one.varu(v);
		CHECK_EQ(Writer::varu_size(v), one.size());
	}
}

TEST(shared_api_for_each_joined_walks_peers_in_order)
{
	const uint16_t port = 39873;
	t::Node host("host", port), a("alice", port), b("bob", port);
	host.cfg.mode = SessionMode::Coop;
	std::string err;
	REQUIRE(host.host(&err));
	CHECK_EQ(host.s.joined_count(), size_t(0));
	REQUIRE(a.connect(port, &err));
	REQUIRE(t::pump_until({&host.s, &a.s}, 5000, [&] { return a.s.is_active() && host.s.peers().size() == 1; }));
	REQUIRE(b.connect(port, &err));
	REQUIRE(t::pump_until({&host.s, &a.s, &b.s}, 5000, [&] { return b.s.is_active() && host.s.peers().size() == 2; }));
	REQUIRE(t::pump_until({&host.s, &a.s, &b.s}, 5000, [&] { return a.s.peers().size() == 2 && b.s.peers().size() == 2; }));

	for (Session* s : {&host.s, &a.s, &b.s})
	{
		const std::vector<PeerInfo> copy = s->peers();
		std::vector<PeerId> walked;
		std::vector<std::string> nicks;
		s->for_each_joined([&](const PeerInfo& p) {
			walked.push_back(p.id);
			nicks.push_back(p.nick);
		});
		CHECK_EQ(s->joined_count(), copy.size());
		REQUIRE(walked.size() == copy.size());
		for (size_t i = 0; i < copy.size(); ++i)
		{
			CHECK_EQ(walked[i], copy[i].id);
			CHECK_EQ(nicks[i], copy[i].nick);
		}
	}
}
