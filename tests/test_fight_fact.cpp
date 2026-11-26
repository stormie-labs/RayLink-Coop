// INTEG-C (F5-PRG-4, rv_F5-PRG-4 blocker 2): the reputation an honest fight gives a player reaches the keeper of his record. In the
// Server mode the fight happens on a map server, the record is the world server's: the map server tells the fact up (a Relation op of
// its own, numbered in its process), the world server's script checks the sender, his route and the order (coop_srv_progress.script)
// and applies it (coop.progress.apply_verified_fight) before his machine hears it. In the co-op the host keeps both and nothing goes
// up. The wire and the bounds: xrCoop/coop_fight_fact.h; the engine's wiring is read from the sources (no xrGame in this target).
#include "test_util.h"
#include "coop_fight_fact.h"
#include "support/fake_mode.h"

#include <cstdint>
#include <fstream>
#include <iterator>
#include <limits>
#include <string>
#include <string_view>

namespace
{
using coop::fight::FactMsg;

std::string game_source(const char* file)
{
	const std::string here = __FILE__;
	const auto slash = here.find_last_of("\\/");
	const auto dir = slash == std::string::npos ? std::string(".") : here.substr(0, slash);
	std::ifstream in(dir + "/../engine/src/xrGame/coop/" + file, std::ios::binary);
	return {std::istreambuf_iterator<char>(in), {}};
}

std::string_view section(std::string_view source, std::string_view start, std::string_view end)
{
	const size_t first = source.find(start);
	REQUIRE(first != std::string_view::npos);
	const size_t last = source.find(end, first + start.size());
	REQUIRE(last != std::string_view::npos);
	return source.substr(first, last - first);
}

size_t at(std::string_view code, std::string_view what)
{
	const size_t p = code.find(what);
	CHECK(p != std::string_view::npos);
	return p;
}

bool read_back(const coop::Writer& w, FactMsg& out)
{
	coop::Reader r(w.ptr(), w.size());
	REQUIRE(r.u8() == coop::fight::kRelOp);
	return out.read(r);
}
} // namespace

TEST(fight_fact_round_trip_and_exact_payload)
{
	FactMsg m;
	m.epoch = 7;
	m.fact = 3;
	m.character = 0x2a;
	m.delta = -15;
	coop::Writer w;
	m.write(w);
	FactMsg back;
	REQUIRE(read_back(w, back));
	CHECK_EQ(back.epoch, 7u);
	CHECK_EQ(back.fact, 3u);
	CHECK_EQ(back.character, 0x2au);
	CHECK_EQ(back.delta, -15);

	coop::Writer trailing;
	m.write(trailing);
	trailing.u8(0);
	CHECK(!read_back(trailing, back));
	coop::Writer short_one;
	short_one.bytes(w.ptr(), w.size() - 1);
	CHECK(!read_back(short_one, back));
}

TEST(fight_fact_bounds)
{
	const auto ok = [](uint32_t fact, uint16_t character, int32_t delta) {
		FactMsg m;
		m.epoch = 1;
		m.fact = fact;
		m.character = character;
		m.delta = delta;
		coop::Writer w;
		m.write(w);
		FactMsg back;
		coop::Reader r(w.ptr(), w.size());
		r.u8();
		return back.read(r);
	};
	CHECK(ok(1, 1, 1));
	CHECK(ok(1, 65534, coop::fight::kMaxDelta));
	CHECK(ok(1, 65534, -coop::fight::kMaxDelta));
	CHECK(!ok(0, 1, 1)); // fact ids start at 1
	CHECK(!ok(1, 0, 1)); // id 0 is a process's own actor, never a player's character in the world's numbering
	CHECK(!ok(1, 0xffff, 1));
	CHECK(!ok(1, 1, 0)); // nothing to apply
	CHECK(!ok(1, 1, coop::fight::kMaxDelta + 1));
	CHECK(!ok(1, 1, -coop::fight::kMaxDelta - 1));
	CHECK(!ok(1, 1, std::numeric_limits<int32_t>::min()));
}

TEST(fight_fact_numbering_and_clamp)
{
	coop::fight::Facts facts;
	CHECK_EQ(facts.next(), 1u);
	CHECK_EQ(facts.next(), 2u);
	CHECK_EQ(coop::fight::bounded(50), 50);
	CHECK_EQ(coop::fight::bounded(coop::fight::kMaxDelta * 3), coop::fight::kMaxDelta);
	CHECK_EQ(coop::fight::bounded(-coop::fight::kMaxDelta * 3), -coop::fight::kMaxDelta);
}

// Only a map server has a level side: its fights go up; every other kind keeps its own books (the co-op host applies and tells the
// player as before; a world server, a client and none have no fights of a player's character here).
TEST(fight_fact_goes_up_only_from_a_level_side)
{
	for (const t::ModeCase& c : t::mode_cases())
	{
		t::FakeMode m(c);
		m.side().trunk[5] = 0x2a;
		const std::string_view name(c.name);
		if (coop::LevelSide* l = m.level())
		{
			l->level_fight_reputation(0x2a, 35);
			l->level_fight_reputation(0x2b, 10); // nobody of this level: nothing
			REQUIRE(m.side().fights.size() == size_t(1));
			CHECK_EQ(m.side().fights[0].first, 0x2au);
			CHECK_EQ(m.side().fights[0].second, 35);
		}
		CHECK_EQ(m.level() != nullptr, name == "map_server");
	}
}

TEST(fight_fact_engine_wiring)
{
	const std::string relations = game_source("coop_story_relations.cpp");
	REQUIRE(!relations.empty());
	const auto flush = section(relations, "void host_flush_rep_deltas()", "\n}");
	const size_t side = at(flush, "if (LevelSide* l = mode().level())");
	const size_t up = at(flush, "l->level_fight_reputation(it.first, it.second)");
	const size_t own = at(flush, "host_apply_fight(peer, it.first, it.second)");
	CHECK(side < up);
	CHECK(up < own);
	const auto request = section(relations, "void host_on_relation_request(PeerId from, u8 op, Reader& r)", "\n}");
	at(request, "case RelUpFightFact:");
	at(request, "progress::host_fight_fact(from, f.epoch, f.fact, f.character, f.delta)");
	const std::string story_progress = game_source("coop_story_progress.cpp");
	REQUIRE(!story_progress.empty());
	const auto apply = section(story_progress, "bool host_apply_fight(PeerId peer, u16 character, int delta)", "\n}");
	const size_t base = at(apply, "host_add_reported_reputation(peer, delta)");
	const size_t tell = at(apply, "net::host_send(peer, Msg::Relation, w)");
	CHECK(base < tell);

	const std::string progress = game_source("coop_progress.cpp");
	REQUIRE(!progress.empty());
	const auto fact = section(progress, "bool host_fight_fact(PeerId from, u32 epoch, u32 fact, u16 character, int delta)", "\n}");
	at(fact, "on_verified_fight");
	at(progress, "\"apply_verified_fight\"");

	const std::string srv = game_source("srv/coop_srv_mode.cpp");
	REQUIRE(!srv.empty());
	const auto level = section(srv, "class MapLevelSide final", "\n};");
	at(level, "void level_fight_reputation(u16 character, int delta) override");
	at(level, "level_peer_of(character) == kInvalidPeer");
	at(level, "join::to_host(character)");
	at(level, "net::client_send(Msg::Relation, w)");
}
