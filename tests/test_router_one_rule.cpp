// Anomaly Coop unit tests: coop.route.of and coop.route.rule_of answer one rule, and coop.route.note_batch counts in bounded steps.
// The counters run here (xrCoop/coop_routes.h); the router's Lua functions (xrGame/coop/coop_router.cpp) need the engine, so their
// shape is read from the source: one place computes the domain, one reads the script key, both functions are one template.
#include "test_util.h"

#include "coop_routes.h"

#include <fstream>
#include <sstream>
#include <string>

using coop::routes::Counters;
using coop::routes::Domain;
using coop::routes::Outcome;

namespace
{
bool same(const Counters& a, const Counters& b)
{
	for (size_t d = 0; d < Counters::kDomains; ++d)
	{
		const Counters::Totals& x = a.totals(Domain(d));
		const Counters::Totals& y = b.totals(Domain(d));
		if (x.ran != y.ran || x.skipped != y.skipped || x.errors != y.errors)
			return false;
	}
	return a.top_skipped(Counters::kMaxPairs + 10) == b.top_skipped(Counters::kMaxPairs + 10) &&
		a.latest_new_skips(Counters::kMaxPairs + 10) == b.latest_new_skips(Counters::kMaxPairs + 10) &&
		a.pairs_tracked() == b.pairs_tracked() && a.pairs_dropped() == b.pairs_dropped();
}
} // namespace

TEST(route_counters_count_in_one_step_as_single_notes)
{
	Counters one, many;
	struct Row
	{
		Domain d;
		Outcome o;
		const char* script;
		const char* callback;
		uint64_t count;
	};
	const Row rows[] = {
		{Domain::Host, Outcome::Ran, "a", "actor_on_update", 7},
		{Domain::Owner, Outcome::Skipped, "a", "actor_on_update", 3},
		{Domain::Owner, Outcome::Skipped, "b", "", 5},
		{Domain::Level, Outcome::Error, "c", "npc_on_update", 2},
		{Domain::View, Outcome::Skipped, "a", "actor_on_update", 4}, // an existing pair grows
		{Domain::Host, Outcome::Skipped, "", "x", 6}, // no script: totals only
		{Domain::None, Outcome::Ran, "d", "y", 1},
	};
	for (const Row& r : rows)
	{
		one.note(r.d, r.o, r.script, r.callback, r.count);
		for (uint64_t k = 0; k < r.count; ++k)
			many.note(r.d, r.o, r.script, r.callback);
	}
	CHECK(same(one, many));
	one.note(Domain::Host, Outcome::Ran, "z", "", 0); // a count of nothing counts nothing
	CHECK(same(one, many));

	// past the pair limit: the same pairs kept, the same skips dropped
	Counters full_one, full_many;
	for (size_t i = 0; i < Counters::kMaxPairs + 3; ++i)
	{
		const std::string script = "s" + std::to_string(i);
		full_one.note(Domain::Owner, Outcome::Skipped, script, "cb", 1 + i % 4);
		for (size_t k = 0; k < 1 + i % 4; ++k)
			full_many.note(Domain::Owner, Outcome::Skipped, script, "cb");
	}
	CHECK(full_one.pairs_dropped() > 0);
	CHECK(same(full_one, full_many));
}

namespace
{
std::string router_code()
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	here.resize(slash == std::string::npos ? 0 : slash);
	std::ifstream in(here + "/../engine/src/xrGame/coop/coop_router.cpp", std::ios::binary);
	std::ostringstream s;
	s << in.rdbuf();
	std::string out;
	for (char c : s.str())
		if (c != '')
			out += c;
	for (size_t at = out.find("//"); at != std::string::npos; at = out.find("//", at)) // comments out
	{
		const size_t end = out.find('\n', at);
		for (size_t i = at; i < (end == std::string::npos ? out.size() : end); ++i)
			out[i] = ' ';
	}
	return out;
}

std::string body_of(const std::string& code, const std::string& head)
{
	const size_t at = code.find(head);
	if (at == std::string::npos)
		return std::string();
	const size_t open = code.find('{', at);
	int depth = 0;
	for (size_t i = open; i < code.size(); ++i)
	{
		if (code[i] == '{')
			++depth;
		else if (code[i] == '}' && --depth == 0)
			return code.substr(open, i - open + 1);
	}
	return std::string();
}

size_t count_of(const std::string& text, const std::string& what)
{
	size_t n = 0;
	for (size_t at = text.find(what); at != std::string::npos; at = text.find(what, at + 1))
		++n;
	return n;
}
} // namespace

TEST(route_of_and_rule_of_are_one_rule_in_the_source)
{
	const std::string code = router_code();
	REQUIRE(!code.empty());
	// one computation of the domain (the table's route and the Level upgrade), one reader of the script key
	CHECK_EQ(count_of(code, "g.table.route("), size_t(1));
	CHECK_EQ(count_of(code, "level_behaviour("), size_t(1));
	CHECK_EQ(count_of(code, "lua_getinfo(L, \">S\""), size_t(1));
	const std::string rule = body_of(code, "Domain rule_now(");
	CHECK(rule.find("g.table.route(") != std::string::npos);
	CHECK(rule.find("level_behaviour(") != std::string::npos);
	// the cache holds rule_now's answers only
	const std::string cached = body_of(code, "Domain route_of(");
	REQUIRE(!cached.empty());
	CHECK(cached.find("rule_now(callback, script)") != std::string::npos);
	CHECK_EQ(count_of(cached, "g.cache.emplace("), size_t(1));
	// of and rule_of: one function, which answers rule_now (cached or not) for every input, an empty callback too
	CHECK(code.find("{\"of\", &l_rule<true>},") != std::string::npos);
	CHECK(code.find("{\"rule_of\", &l_rule<false>},") != std::string::npos);
	const std::string answer = body_of(code, "int l_rule(lua_State* L)");
	REQUIRE(!answer.empty());
	CHECK(answer.find("script_of(L, 2)") != std::string::npos);
	CHECK(answer.find("d = route_of(callback, script);") != std::string::npos);
	CHECK(answer.find("d = rule_now(callback, script);") != std::string::npos);
	CHECK(code.find("int l_of(") == std::string::npos);
	CHECK(code.find("int l_rule_of(") == std::string::npos);
}

TEST(route_note_batch_is_bounded_in_the_source)
{
	const std::string code = router_code();
	const std::string batch = body_of(code, "int l_note_batch(lua_State* L)");
	REQUIRE(!batch.empty());
	CHECK(code.find("constexpr int kNoteBatchRows = 256;") != std::string::npos);
	CHECK(batch.find("n < kNoteBatchRows ? n : kNoteBatchRows") != std::string::npos); // rows past the cap are not read
	// under the lock: one addition per row, the count in one step
	CHECK(batch.find("g.counters.note(r.d, r.o, r.script, r.callback, r.count);") != std::string::npos);
	CHECK(batch.find("k < r.count") == std::string::npos);
	// the refused rows are counted and logged
	CHECK(batch.find("g.batch_refusals.allow()") != std::string::npos);
	CHECK(batch.find("note_batch refused") != std::string::npos);
}
