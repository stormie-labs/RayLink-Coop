// Anomaly Coop unit tests: TZ R32 W3 (temp/r30/design/R32-final.md §1 W3, §6 test_relay_echo.cpp, §8a A10), the relay down and the
// member hook up.
//
// Down: a fact a map server reported reaches every other copy once. The world applies it under the EchoOf of the reporting level; what
// it records then (a holder change, a death) keeps that level until the frame's flush, when the scope is over (verify-replication's
// trap): the flush sends it under that EchoOf again, so that level's players (levels::passes_to) and its map server (the mode's
// delivery, reconcile::echo_reaches) do not get back what they said. In Coop no EchoOf is ever opened: the flush is today's.
//
// Up: a member joined or left a squad on a map server (stock register_member / unregister_member): LevelSide::level_entity_up
// Joined / Left. Never on the world server, in Coop or in single player (no level side there), never while a copy applies the world's
// word, the world applies a journal entry itself (coop_join_member / coop_leave_member / coop_bind_members) or a load binds members
// again (on_after_game_load).
#include "test_util.h"

#include "coop_reconcile.h"
#include "support/fake_mode.h"

#include <algorithm>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <regex>
#include <string>
#include <vector>

using namespace coop;

namespace
{
constexpr size_t npos = std::string::npos;

// anomaly-coop/<rel>, the project root above this source file, without '\r'
std::string project_file(const std::string& rel)
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	here.resize(slash == std::string::npos ? 0 : slash);
	std::ifstream f(here + "/../" + rel, std::ios::binary);
	std::string text((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
	text.erase(std::remove(text.begin(), text.end(), '\r'), text.end());
	return text;
}

std::string project_root()
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	here.resize(slash == std::string::npos ? 0 : slash);
	return here + "/..";
}

// // and /* */ comments dropped (the calls looked for here hold neither in a string)
std::string code_of(const std::string& src)
{
	const std::string a = std::regex_replace(src, std::regex(R"(/\*[\s\S]*?\*/)"), " ");
	return std::regex_replace(a, std::regex(R"(//[^\n]*)"), " ");
}

// The body of the function whose definition starts with `head` (up to its closing brace at the start of a line), "" if missing.
std::string body_of(const std::string& code, const std::string& head)
{
	const size_t at = code.find(head);
	if (at == npos)
	{
		t::report_failure(__FILE__, __LINE__, "no function " + head);
		return std::string();
	}
	const size_t end = code.find("\n}", at);
	return code.substr(at, end == npos ? npos : end - at);
}

std::string events_code() { return code_of(project_file("engine/src/xrGame/coop/coop_events.cpp")); }
std::string group_code() { return code_of(project_file("engine/src/xrGame/alife_online_offline_group.cpp")); }
std::string members_code() { return code_of(project_file("engine/src/xrGame/coop/coop_squad_members.cpp")); }
std::string squad_journal_code() { return code_of(project_file("engine/src/xrGame/coop/srv/coop_squad_journal.cpp")); }
} // namespace

// ---------------------------------------------------------------- the rule (xrCoop/coop_reconcile.h)

TEST(relay_echo_two_records_of_one_object_keep_the_level_only_when_both_came_from_it)
{
	using reconcile::kNoEcho;
	using reconcile::merged_echo;
	CHECK_EQ(merged_echo(5, 5), uint16_t(5)); // the map server of level 5 moved it twice: its players and it have both
	CHECK_EQ(merged_echo(5, kNoEcho), kNoEcho); // the world moved it too: everybody gets the last state
	CHECK_EQ(merged_echo(kNoEcho, 5), kNoEcho);
	CHECK_EQ(merged_echo(5, 6), kNoEcho); // two levels said something of it: both need the last state
	CHECK_EQ(merged_echo(kNoEcho, kNoEcho), kNoEcho);
	CHECK_EQ(kNoEcho, uint16_t(0xFFFF)); // = levels::wire::kNoLevel (the static_assert in coop_events.cpp)
}

TEST(relay_echo_skips_the_source_bridge_and_reaches_every_other)
{
	using reconcile::echo_reaches;
	using reconcile::kNoEcho;
	// The world server relays a holder change level 3's map server reported to the bridges of levels 1, 3 and 7
	std::vector<uint16_t> got;
	for (const uint16_t bridge_level : {uint16_t(1), uint16_t(3), uint16_t(7)})
		if (echo_reaches(3, bridge_level))
			got.push_back(bridge_level);
	CHECK_EQ(got.size(), size_t(2));
	CHECK(std::find(got.begin(), got.end(), uint16_t(3)) == got.end()); // the reporter has it: A10, an echo would undo a later move
	// a change of the world's own reaches every bridge
	for (const uint16_t bridge_level : {uint16_t(1), uint16_t(3), uint16_t(7)})
		CHECK(echo_reaches(kNoEcho, bridge_level));
}

// ---------------------------------------------------------------- the relay in the engine (coop_events.cpp)

TEST(relay_echo_a_holder_change_and_a_death_keep_the_level_that_reported_them)
{
	const std::string events = events_code();
	const std::string parent = body_of(events, "void host_on_parent_changed(u16 item, u16 old_parent, u16 new_parent)");
	const std::string died = body_of(events, "void host_on_death(u16 victim, u16 killer)");
	// read when the change is recorded: the EchoOf of the report is over when the frame's flush runs
	CHECK(parent.find("levels::echo_now()") != npos);
	CHECK(died.find("levels::echo_now()") != npos);
	CHECK(parent.find("reconcile::merged_echo(") != npos); // the first old parent of the frame stays, the echo merges
	CHECK(events.find("struct ParentChange") != npos);
	CHECK(events.find("struct Death") != npos);
	// the store keeps it with the change
	CHECK(events.find("xr_map<u16, ParentChange> g_parent_changes;") != npos);
	CHECK(events.find("xr_vector<Death> g_deaths;") != npos);
	CHECK(events.find("static_assert(reconcile::kNoEcho == levels::wire::kNoLevel") != npos);
}

TEST(relay_echo_the_flush_sends_under_the_echo_it_kept)
{
	const std::string events = events_code();
	const std::string flush = body_of(events, "void host_flush()");
	CHECK(flush.find("relay(Msg::EntityParent, w, c.second.echo)") != npos);
	CHECK(flush.find("relay(Msg::EntityDied, w, d.echo)") != npos);
	CHECK(flush.find("relay(Msg::PlayerDied, w, d.echo)") != npos);
	CHECK(flush.find("net::host_broadcast(Msg::EntityParent") == npos); // every parent and death goes through relay
	CHECK(flush.find("net::host_broadcast(Msg::EntityDied") == npos);
	const std::string relay = body_of(events, "void relay(Msg type, const Writer& w, u16 echo)");
	CHECK(relay.find("levels::with_echo(echo, [&] { net::host_broadcast(type, w); });") != npos);
	// no echo: the broadcast goes out untouched (levels::with_echo opens no scope for wire::kNoLevel)
	const std::string with = project_file("engine/src/xrGame/coop/coop_levels.h");
	const size_t none = with.find("if (echo == wire::kNoLevel)");
	const size_t scope = with.find("const EchoOf scope(echo);");
	CHECK(none != npos);
	CHECK(scope != npos);
	CHECK(none < scope);
}

// ---------------------------------------------------------------- the relay end to end on the world server (D finding 1, A10)

namespace
{
// whitespace runs collapsed to one space
std::string collapse(const std::string& s) { return std::regex_replace(s, std::regex(R"(\s+)"), " "); }
std::string srv_mode_code() { return code_of(project_file("engine/src/xrGame/coop/srv/coop_srv_mode.cpp")); }
std::string levels_alife_code() { return code_of(project_file("engine/src/xrGame/coop/srv/coop_levels_alife.cpp")); }
} // namespace

// The world server's delivery to its map servers (to_bridges: deliver and deliver_links) skips the bridge of the level whose report
// the world applies now (the EchoOf it holds, or the one the flush opens again): that map server said it. Every other bridge gets it,
// and a change of the world's own (no echo) reaches every bridge.
TEST(relay_echo_the_worlds_delivery_skips_the_reporting_bridge_only)
{
	const std::string to = collapse(body_of(srv_mode_code(), "void to_bridges(Msg type, const Writer& payload, Lane lane, PeerId except)"));
	CHECK(to.find("if (bridge != except && reconcile::echo_reaches(levels::echo_now(), mapserver::level_of_bridge(bridge)))") != npos);
	CHECK(to.find("net::to_peer(bridge, type, payload, lane)") != npos);
	const std::string mode = srv_mode_code();
	CHECK(mode.find("#include \"xrCoop/coop_reconcile.h\"") != npos);

	// the decision to_bridges makes, replayed: bridges 11, 13, 17 lead levels 1, 3, 7
	struct Bridge
	{
		PeerId peer;
		uint16_t level;
	};
	const Bridge bridges[] = {{PeerId(11), uint16_t(1)}, {PeerId(13), uint16_t(3)}, {PeerId(17), uint16_t(7)}};
	const auto sent_to = [&](uint16_t echo, PeerId except) {
		std::vector<PeerId> got;
		for (const Bridge& b : bridges)
			if (b.peer != except && reconcile::echo_reaches(echo, b.level))
				got.push_back(b.peer);
		return got;
	};
	// level 3's map server reported a holder change; the world applied it under EchoOf(3) and relays it under the echo it kept
	const std::vector<PeerId> from_three = sent_to(3, kInvalidPeer);
	CHECK_EQ(from_three.size(), size_t(2));
	CHECK(std::find(from_three.begin(), from_three.end(), PeerId(13)) == from_three.end());
	CHECK(std::find(from_three.begin(), from_three.end(), PeerId(11)) != from_three.end());
	CHECK(std::find(from_three.begin(), from_three.end(), PeerId(17)) != from_three.end());
	// the world's own change: every bridge; `except` still skips its peer
	CHECK_EQ(sent_to(reconcile::kNoEcho, kInvalidPeer).size(), size_t(3));
	CHECK_EQ(sent_to(reconcile::kNoEcho, PeerId(17)).size(), size_t(2));
}

// The world's apply of a map server's Parent or Died records the relay: the stock ALife attach / detach and on_death it uses run no
// server event, so apply_entry calls the events hooks itself, inside the EchoOf it holds, after a real change only. The hook reads
// levels::echo_now() when it records, and the flush sends it under that echo (above): players and bridges of other levels hear it,
// the reporting level does not get it back.
TEST(relay_echo_the_worlds_apply_of_a_parent_or_a_death_is_relayed_under_its_echo)
{
	const std::string code = levels_alife_code();
	const std::string apply = body_of(code, "ApplyVerdict apply_entry(PeerId author, const journal::Entry& e, uint8_t& why,");
	const size_t scope = apply.find("const EchoOf echo(level);");
	REQUIRE(scope != npos);

	const size_t died_apply = apply.find("host_apply_death(victim, killer, st);");
	const size_t died_hook = apply.find("events::host_on_death(victim, killer);");
	CHECK(died_apply != npos);
	CHECK(died_hook != npos);
	CHECK(scope < died_apply);
	CHECK(died_apply < died_hook);
	const size_t was_alive = apply.find("const bool was_alive =");
	CHECK(was_alive != npos && was_alive < died_apply); // a body dead here already is no new death: nothing recorded

	const size_t parent_apply = apply.find("host_apply_parent(item, parent, pos);");
	const size_t parent_hook = apply.find("events::host_on_parent_changed(item, old_parent, now_parent);");
	CHECK(parent_apply != npos);
	CHECK(parent_hook != npos);
	CHECK(scope < parent_apply);
	CHECK(parent_apply < parent_hook);
	CHECK(collapse(apply).find("if (now_parent != old_parent) events::host_on_parent_changed(item, old_parent, now_parent);") != npos);

	CHECK(code.find("#include \"../coop_events.h\"") != npos);
}

// Coop: the relay changes nothing there. An EchoOf is opened only by the server layer's apply of a map server's report; the Core opens
// one only again around what it recorded under one (host_process_events, relay). So echo_now() is kNoLevel in Coop.
TEST(relay_echo_is_inert_in_coop_no_core_or_hostplay_file_makes_an_echo_up)
{
	namespace fs = std::filesystem;
	const std::string root = project_root() + "/engine/src/xrGame/coop";
	std::vector<std::string> openers;
	for (const fs::directory_entry& f : fs::recursive_directory_iterator(root))
	{
		if (!f.is_regular_file() || f.path().extension() != ".cpp")
			continue;
		if (f.path().generic_string().find("/srv/") != npos)
			continue; // the server layer opens it for a map server's report
		std::ifstream in(f.path(), std::ios::binary);
		const std::string text((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
		if (text.find("EchoOf") == npos)
			continue;
		const std::string code = code_of(text);
		const std::regex opener(R"(EchoOf\s+\w+\(([^)]*)\))"); // a scope made: `EchoOf name(level)`, not EchoOf::EchoOf(...)
		for (auto it = std::sregex_iterator(code.begin(), code.end(), opener); it != std::sregex_iterator(); ++it)
			openers.push_back(f.path().filename().string() + ":" + (*it)[1].str());
	}
	std::sort(openers.begin(), openers.end());
	// the Core opens it in one place, levels::with_echo (coop_levels.h); its two callers pass the echo they recorded
	const std::vector<std::string> expected = {};
	CHECK(project_file("engine/src/xrGame/coop/coop_levels.h").find("const EchoOf scope(echo);") != npos);
	CHECK(project_file("engine/src/xrGame/coop/coop_entities.cpp").find("levels::with_echo(ev.echo, ") != npos);
	CHECK(project_file("engine/src/xrGame/coop/coop_events.cpp").find("levels::with_echo(echo, ") != npos);
	CHECK_EQ(openers.size(), expected.size());
	for (size_t i = 0; i < openers.size() && i < expected.size(); ++i)
		CHECK_EQ(openers[i], expected[i]);
	// and outside a scope there is no echo
	const std::string levels = project_file("engine/src/xrGame/coop/coop_levels.cpp");
	CHECK(levels.find("LevelId echo = wire::kNoLevel; // EchoOf") != npos);
}

// ---------------------------------------------------------------- the member hook (alife_online_offline_group.cpp -> coop_squad_members.cpp)

TEST(member_hook_register_and_unregister_raise_joined_and_left)
{
	const std::string group = group_code();
	const std::string reg = body_of(group, "void CSE_ALifeOnlineOfflineGroup::register_member(ALife::_OBJECT_ID member_id)");
	const size_t insert = reg.find("m_members.insert(std::make_pair(member_id, monster));");
	const size_t joined = reg.find("coop::squad::member_up(ID, member_id, true);");
	const size_t first = reg.find("if (!empty)");
	CHECK(insert != npos);
	CHECK(joined != npos);
	CHECK(insert < joined); // after the change, as every hook of the journal
	CHECK(joined < first); // before the early return of a squad that had members
	const std::string unreg = body_of(group, "void CSE_ALifeOnlineOfflineGroup::unregister_member(ALife::_OBJECT_ID member_id)");
	size_t lefts = 0;
	for (size_t at = unreg.find("coop::squad::member_up(ID, member_id, false);"); at != npos;
	     at = unreg.find("coop::squad::member_up(ID, member_id, false);", at + 1))
		++lefts;
	CHECK_EQ(lefts, size_t(2)); // an id never bound (a squad from the wire) and a bound member alike
	CHECK(unreg.find("m_members.erase(I);") < unreg.rfind("coop::squad::member_up(ID, member_id, false);"));
}

TEST(member_hook_goes_up_through_the_level_side_only)
{
	const std::string hook = body_of(members_code(), "void member_up(ALife::_OBJECT_ID squad, ALife::_OBJECT_ID member, bool joined)");
	const size_t quiet = hook.find("if (g_quiet)");
	const size_t applying = hook.find("entities::client_applying()");
	const size_t side = hook.find("LevelSide* side = mode().level()");
	const size_t up = hook.find("side->level_entity_up(joined ? EntityUp::Joined : EntityUp::Left, squad, member);");
	CHECK(quiet != npos);
	CHECK(applying != npos);
	CHECK(side != npos);
	CHECK(up != npos);
	CHECK(quiet < up && applying < up && side < up);
	// a squad whose release is under way (its destructor takes the members out) says nothing: its Destroy does
	CHECK(hook.find("ai().alife().objects().object(squad, true)") != npos);
	// no mode check of its own: the level side is the mode's answer (docs/MODES.md section 4)
	CHECK(hook.find("is_map_server") == npos);
	CHECK(hook.find("decides_world") == npos);
}

TEST(member_hook_is_quiet_where_members_are_bound_again_or_the_world_applies_a_journal_entry)
{
	const std::string group = group_code();
	const std::string journal = squad_journal_code();
	for (const char* head : {"void CSE_ALifeOnlineOfflineGroup::on_after_game_load()",
	         "bool CSE_ALifeOnlineOfflineGroup::coop_bind_members(bool forget)",
	         "bool CSE_ALifeOnlineOfflineGroup::coop_join_member(ALife::_OBJECT_ID member_id)",
	         "bool CSE_ALifeOnlineOfflineGroup::coop_leave_member(ALife::_OBJECT_ID member_id)"})
	{
		const std::string body = body_of(group.find(head) != npos ? group : journal, head);
		CHECK_EQ(std::string(head) + (body.find("const coop::squad::MemberQuiet quiet;") != npos ? " is quiet" : " raises"),
		    std::string(head) + " is quiet");
	}
	// per thread: the ALife's thread and the main thread do not quiet each other
	const std::string members = members_code();
	CHECK(members.find("thread_local int g_quiet = 0;") != npos);
	CHECK(members.find("MemberQuiet::MemberQuiet() { ++g_quiet; }") != npos);
	CHECK(members.find("MemberQuiet::~MemberQuiet() { --g_quiet; }") != npos);
}

// Package A's finding 2 (fix round 2, proposal for the bind): the world binds a member a map server's new squad lists (that squad's
// Spawn came before the Left of the old one: a split or a recruit into a new squad in one frame). The member leaves its old squad's
// list first, as coop_join_member does, so it is never listed in two squads, also when the old squad's Left is refused later.
TEST(member_bind_takes_a_member_out_of_its_old_squad_first)
{
	const std::string journal = squad_journal_code();
	const std::string bind = body_of(journal, "bool CSE_ALifeOnlineOfflineGroup::coop_bind_members(bool forget)");
	const size_t other = bind.find("if (monster->m_group_id != 0xffff && monster->m_group_id != ID)");
	const size_t leave = bind.find("old->coop_leave_member(monster->ID);");
	const size_t bound = bind.find("monster->m_group_id = ID;");
	CHECK(other != npos);
	CHECK(leave != npos);
	CHECK(bound != npos);
	CHECK(other < leave && leave < bound); // out of the old list, then into this one
	CHECK(bind.find("alife().scheduled().remove(monster, true);") > leave); // its registries are this squad's after the leave
	// a creature already gone from the old squad's list (coop_join_member left it first) is not left twice: the old squad id is gone
	const std::string join = body_of(journal, "bool CSE_ALifeOnlineOfflineGroup::coop_join_member(ALife::_OBJECT_ID member_id)");
	CHECK(join.find("old->coop_leave_member(member_id);") < join.find("coop_bind_members(false);"));
}

// Coop: the bind is the world server's (a squad of a map server came as a packet): no Core or hostplay file calls it.
TEST(member_bind_is_not_reached_in_coop)
{
	namespace fs = std::filesystem;
	const std::string root = project_root() + "/engine/src/xrGame/coop";
	std::vector<std::string> callers;
	for (const fs::directory_entry& f : fs::recursive_directory_iterator(root))
	{
		if (!f.is_regular_file() || f.path().extension() != ".cpp" || f.path().generic_string().find("/srv/") != npos)
			continue;
		std::ifstream in(f.path(), std::ios::binary);
		const std::string text((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
		if (code_of(text).find("coop_bind_members(") != npos)
			callers.push_back(f.path().filename().string());
	}
	CHECK_EQ(callers.size(), size_t(0));
}

// Per mode: the hook raises where the mode has a level side, and only there.
TEST(member_hook_raises_on_a_map_server_only)
{
	for (const t::ModeCase& c : t::mode_cases())
	{
		t::FakeMode m(c);
		const bool raises = m.level() != nullptr;
		const bool map_server = !std::strcmp(c.name, "map_server");
		CHECK_EQ(std::string(c.name) + (raises ? " raises" : " is silent"), std::string(c.name) + (map_server ? " raises" : " is silent"));
	}
}

TEST(member_hook_coop_host_and_client_are_silent)
{
	for (const char* name : {"coop_host", "coop_client"})
	{
		t::FakeMode m(t::mode_case(name));
		CHECK_EQ(std::string(m.level() ? "side" : "none"), std::string("none")); // one process: the host's books are the world's
	}
}

TEST(member_hook_world_server_and_its_players_are_silent)
{
	for (const char* name : {"world_server", "server_client", "none"})
	{
		t::FakeMode m(t::mode_case(name));
		CHECK_EQ(std::string(m.level() ? "side" : "none"), std::string("none")); // the world applies Joined / Left, it raises none
	}
}

// ---------------------------------------------------------------- the world answers its map servers itself (coop_trunk.cpp)

TEST(relay_a_map_servers_asks_are_the_world_servers_to_answer)
{
	const std::string trunk = code_of(project_file("engine/src/xrGame/coop/srv/coop_trunk.cpp"));
	const std::string in = body_of(trunk, "bool host_incoming(PeerId from, Msg type, Lane lane, const u8* packet, size_t size)");
	const size_t bridge = in.find("if (is_bridge(from))");
	const size_t tunnel = in.find("route_incoming(");
	CHECK(bridge != npos);
	CHECK(tunnel != npos);
	CHECK(bridge < tunnel); // a bridge's StateDumpRequest / EntityResync is never tunnelled back to a map server
}

// ---------------------------------------------------------------- W5.1: who repairs which row of the world's roster, per mode

// client_on_roster skips a row whose object this process writes (writing::writes: Mode::writer_of over the root is This; a mirror
// writes nothing). The writer is the truth of its object: the non-writer repairs towards it, never the other way.
namespace
{
bool repairs(const t::FakeMode& m, const writer::RootFacts& root)
{
	return m.writer_of(root).is != writer::WriterIs::This;
}
} // namespace

TEST(repair_a_coop_client_repairs_every_row)
{
	t::FakeMode m(t::mode_case("coop_client"));
	CHECK(repairs(m, writer::RootFacts{writer::RootKind::Resident, 0x700, 3}));
	CHECK(repairs(m, writer::RootFacts{writer::RootKind::Unit, 0x300, 3}));
	CHECK(repairs(m, writer::RootFacts{writer::RootKind::None, 0x900, writer::kNoLevel}));
}

TEST(repair_a_server_player_repairs_every_row)
{
	t::FakeMode m(t::mode_case("server_client"));
	CHECK(repairs(m, writer::RootFacts{writer::RootKind::Resident, 0x700, 3}));
	CHECK(repairs(m, writer::RootFacts{writer::RootKind::Unit, 0x300, 3}));
}

TEST(repair_a_map_server_skips_what_it_writes_and_repairs_what_its_world_writes)
{
	constexpr uint16_t kMine = 3, kOther = 4;
	t::FakeMode m(t::mode_case("map_server"));
	m.lead(kMine, writer::Lead::Leads, coop::kHostPeer);
	m.own_level(kMine);
	m.holds(0x300, kMine, coop::kHostPeer);
	CHECK(!repairs(m, writer::RootFacts{writer::RootKind::Resident, 0x700, kMine})); // a box of its own map
	CHECK(!repairs(m, writer::RootFacts{writer::RootKind::Unit, 0x300, kMine})); // a squad it holds
	CHECK(repairs(m, writer::RootFacts{writer::RootKind::Unit, 0x301, kMine})); // a squad at home in the world, on its map
	CHECK(repairs(m, writer::RootFacts{writer::RootKind::Resident, 0x701, kOther})); // a box of another map nobody leads
	CHECK(repairs(m, writer::RootFacts{writer::RootKind::None, 0x900, writer::kNoLevel})); // money, story, records
}

// ---------------------------------------------------------------- W3 receive + W8.4: a repeated spawn, per mode

// client_on_spawn of an id it has, same kind (a repeat): the initial state of the tail goes into the copy's entity only where this
// process is not the object's writer (writing::writes); the writer's own state stands. The same rule decides the world server's take
// of a map server's spawn (host_spawn_from_leader).
TEST(receive_a_repeat_takes_the_writers_state_on_a_copy_only)
{
	constexpr uint16_t kA = 3;
	const writer::RootFacts box{writer::RootKind::Resident, 0x700, kA};
	for (const char* name : {"coop_client", "server_client"})
	{
		t::FakeMode m(t::mode_case(name));
		CHECK_EQ(std::string(name) + (repairs(m, box) ? " takes it" : " keeps its own"), std::string(name) + " takes it");
	}
	{
		t::FakeMode m(t::mode_case("map_server"));
		m.lead(kA, writer::Lead::Leads, coop::kHostPeer);
		m.own_level(kA);
		CHECK(!repairs(m, box)); // its own box: a repeat from its world leaves it alone
	}
	{
		t::FakeMode m(t::mode_case("world_server"));
		m.lead(kA, writer::Lead::Leads, 41); // the map server of A writes the box; its spawn's state is the writer's
		CHECK(repairs(m, box));
	}
	{
		t::FakeMode m(t::mode_case("coop_host"));
		CHECK(!repairs(m, box)); // the co-op host writes everything; it gets no EntitySpawn anyway
	}
}

// ---------------------------------------------------------------- WP5 fix round (verify-D findings 2, 3, 4, 6, 7), per mode

// Finding 2, Coop: the host moved an item into client C's inventory and it did not finish in 15 s. C asks for the item and for his own
// character (the host's proxy is his actor here): Spawn only for what is missing, so his character's answer is no subtree of all he
// carries (the host masks a player's character to Spawn: nothing at all goes for it).
TEST(repair_coop_client_a_stalled_move_asks_no_spawn_of_his_own_character)
{
	CHECK_EQ(reconcile::stalled_ask(/*here*/ true) & reconcile::Spawn, 0);
	CHECK_EQ(reconcile::stalled_ask(/*here*/ false) & reconcile::Spawn, int(reconcile::Spawn)); // a holder he lacks still comes
}

// Finding 2, Server: the same rule on a server player (the map server of his level moved it) and on a map server (its world moved it).
TEST(repair_server_a_stalled_move_asks_no_spawn_of_what_is_here)
{
	for (const char* name : {"server_client", "map_server"})
	{
		t::FakeMode m(t::mode_case(name));
		CHECK_EQ(std::string(name) + ((reconcile::stalled_ask(true) & reconcile::Spawn) ? " asks a spawn" : " asks none"),
		    std::string(name) + " asks none");
	}
}

// Finding 3: who compares its world's digest in the mapless view. The copies of a world: a co-op client and a server player share
// their host's map (every fact counts, as before); a map server leads a map of its own (what is online there is its own business).
TEST(repair_only_a_map_server_compares_the_mapless_view)
{
	for (const char* name : {"coop_client", "server_client", "map_server"})
	{
		t::FakeMode m(t::mode_case(name));
		const bool mapless = m.leads_level(); // coop_entities.cpp compares_mapless()
		const bool map_server = !std::strcmp(name, "map_server");
		CHECK_EQ(std::string(name) + (mapless ? " mapless" : " every fact"), std::string(name) + (map_server ? " mapless" : " every fact"));
	}
}

// Finding 4: coop_squad_complete (the srv Lua puts the squad in its smart) is raised where the squad's map is led apart from its world,
// for a squad of that map only.
TEST(squad_complete_is_raised_on_a_map_server_for_its_own_map_only)
{
	constexpr uint16_t kMine = 3, kOther = 4;
	for (const t::ModeCase& c : t::mode_cases())
	{
		t::FakeMode m(c);
		const bool own = reconcile::squad_complete_here(m.level() != nullptr, kMine, kMine);
		const bool map_server = !std::strcmp(c.name, "map_server");
		CHECK_EQ(std::string(c.name) + (own ? " raises" : " is silent"), std::string(c.name) + (map_server ? " raises" : " is silent"));
		CHECK(!reconcile::squad_complete_here(m.level() != nullptr, kOther, kMine)); // another map's squad: nobody here
	}
}

// Finding 7: another kind under an id this process writes is a stale word of the world: the writer's object stands. Per mode.
TEST(receive_a_stale_spawn_never_replaces_what_this_process_writes)
{
	constexpr uint16_t kA = 3;
	const uint16_t ak = reconcile::kind_of("wpn_ak74"), medkit = reconcile::kind_of("medkit");
	const writer::RootFacts box{writer::RootKind::Resident, 0x700, kA};
	const auto known = [&](const t::FakeMode& m) { return reconcile::spawn_of_known(ak, medkit, !repairs(m, box)); };
	for (const char* name : {"coop_client", "server_client"})
	{
		t::FakeMode m(t::mode_case(name));
		CHECK(known(m) == reconcile::Known::Replace); // a mirror writes nothing: the writer's object comes, as before
	}
	{
		t::FakeMode m(t::mode_case("map_server"));
		m.lead(kA, writer::Lead::Leads, coop::kHostPeer);
		m.own_level(kA);
		CHECK(known(m) == reconcile::Known::Keep); // its own box, released and made again: the echo of the old spawn goes nowhere
	}
	{
		t::FakeMode m(t::mode_case("world_server"));
		m.lead(kA, writer::Lead::Leads, 41); // the map server of A writes the box: its journal's spawn replaces a stale copy
		CHECK(known(m) == reconcile::Known::Replace);
	}
	{
		t::FakeMode m(t::mode_case("world_server")); // nobody leads A: the world writes the box, its own object stands
		CHECK(known(m) == reconcile::Known::Keep);
	}
}

// Finding 6: a repeated spawn's item state (and the decider's versions with it) goes into an offline copy only. Per mode.
TEST(receive_a_repeat_takes_state_into_an_offline_copy_only)
{
	constexpr uint16_t kA = 3;
	const writer::RootFacts box{writer::RootKind::Resident, 0x700, kA};
	{
		t::FakeMode m(t::mode_case("coop_client"));
		CHECK(reconcile::repeat_takes_state(!repairs(m, box), /*game object here*/ false));
		CHECK(!reconcile::repeat_takes_state(!repairs(m, box), /*game object here*/ true)); // its object's state and versions stand
	}
	{
		t::FakeMode m(t::mode_case("server_client"));
		CHECK(reconcile::repeat_takes_state(!repairs(m, box), false));
		CHECK(!reconcile::repeat_takes_state(!repairs(m, box), true));
	}
	{
		t::FakeMode m(t::mode_case("map_server"));
		m.lead(kA, writer::Lead::Leads, coop::kHostPeer);
		m.own_level(kA);
		CHECK(!reconcile::repeat_takes_state(!repairs(m, box), false)); // its own box: the writer's state stands
	}
}
