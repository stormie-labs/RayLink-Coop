// Server-only ownership audit: a round is proved by one full book from each challenged bridge.
#include "test_util.h"

#include "srv/coop_levels_wire.h"
#include "coop_world_gate.h"
#include "srv/coop_levels_audit.h"
#include "srv/coop_levels_accept.h"
#include "coop_writer_rules.h"
#include "srv/coop_session_srv.h"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <regex>
#include <string_view>

using namespace coop;
using namespace coop::levels::wire;

namespace
{
constexpr PeerId kA = mapserver::bridge_peer(1);
constexpr PeerId kB = mapserver::bridge_peer(2);
constexpr uint32_t kFull = xfer::kAllBuckets;

struct AuditLog
{
	std::vector<std::string> lines;

	template <class... Args>
	void operator()(const char* format, Args... args)
	{
		char line[128];
		std::snprintf(line, sizeof(line), format, args...);
		lines.emplace_back(line);
	}
};

// The audited hooks live in xrGame, which the native test binary does not link.
std::string_view function_body(const std::string& code, const char* name)
{
	std::smatch match;
	const std::regex definition(std::string(R"(\bvoid\s+)") + name + R"(\s*\([^;{}]*\)\s*\{)");
	if (!std::regex_search(code, match, definition))
		return {};

	const size_t start = static_cast<size_t>(match.position() + match.length());
	int depth = 1;
	for (size_t i = start; i < code.size(); ++i)
	{
		if (code[i] == '{')
			++depth;
		else if (code[i] == '}' && --depth == 0)
			return std::string_view(code).substr(start, i - start);
	}
	return {};
}

bool appears_before(std::string_view body, std::string_view first, std::string_view second)
{
	const size_t second_pos = body.find(second);
	return second_pos != std::string_view::npos && body.find(first) < second_pos;
}
} // namespace

TEST(levels_audit_round_logs_begin_and_one_ack_per_bridge)
{
	srv::LevelsAudit audit;
	AuditLog log;
	const uint32_t round = audit.begin({kA, kB}, log);
	CHECK_EQ(round, 1u);
	REQUIRE(log.lines.size() == 1);
	CHECK_EQ(log.lines.front(), "[coop] levels audit begin round=1 bridges=2");
	CHECK(audit.reply(round, kB, kFull, log));
	CHECK(audit.reply(round, kA, kFull, log));
	REQUIRE(log.lines.size() == 3);
	CHECK_EQ(log.lines[1], "[coop] levels audit ack round=1 peer=258 mask=ffffffff");
	CHECK_EQ(log.lines[2], "[coop] levels audit ack round=1 peer=257 mask=ffffffff");
}

TEST(levels_audit_round_refuses_late_replies_from_a_previous_round)
{
	srv::LevelsAudit audit;
	AuditLog log;
	const uint32_t old = audit.begin({kA, kB}, log);
	CHECK(audit.reply(old, kA, kFull, log));
	const uint32_t current = audit.begin({kA, kB}, log);
	CHECK_EQ(current, 2u);
	CHECK_EQ(log.lines.back(), "[coop] levels audit begin round=2 bridges=2");
	CHECK(!audit.reply(old, kA, kFull, log)); // late duplicate
	CHECK(!audit.reply(old, kB, kFull, log)); // first reply, but round superseded
	REQUIRE(log.lines.size() == 5);
	CHECK_EQ(log.lines[3], "[coop] levels audit refused round=1 peer=257 mask=ffffffff total=1");
	CHECK_EQ(log.lines[4], "[coop] levels audit refused round=1 peer=258 mask=ffffffff total=2");
	CHECK(audit.reply(current, kB, kFull, log));
	CHECK(audit.reply(current, kA, kFull, log));
}

TEST(levels_audit_round_refuses_a_connection_that_was_not_challenged)
{
	srv::LevelsAudit audit;
	AuditLog log;
	const uint32_t round = audit.begin({kA}, log);
	CHECK(!audit.reply(round, kB, kFull, log));
	REQUIRE(log.lines.size() == 2);
	CHECK_EQ(log.lines.back(), "[coop] levels audit refused round=1 peer=258 mask=ffffffff total=1");
	CHECK(audit.reply(round, kA, kFull, log));
}

TEST(levels_audit_round_refuses_a_bridge_challenged_only_in_an_earlier_round)
{
	srv::LevelsAudit audit;
	AuditLog log;
	audit.begin({kA, kB}, log);
	const uint32_t current = audit.begin({kA}, log);
	CHECK(!audit.reply(current, kB, kFull, log));
	CHECK_EQ(log.lines.back(), "[coop] levels audit refused round=2 peer=258 mask=ffffffff total=1");
	CHECK(audit.reply(current, kA, kFull, log));
}

TEST(levels_audit_round_refuses_duplicate_and_partial_replies_without_using_another_slot)
{
	srv::LevelsAudit audit;
	AuditLog log;
	const uint32_t round = audit.begin({kA, kB}, log);
	CHECK(audit.reply(round, kA, kFull, log));
	CHECK(!audit.reply(round, kA, kFull, log));
	CHECK(!audit.reply(round, kB, 1u, log));
	REQUIRE(log.lines.size() == 4);
	CHECK_EQ(log.lines[2], "[coop] levels audit refused round=1 peer=257 mask=ffffffff total=1");
	CHECK_EQ(log.lines[3], "[coop] levels audit refused round=1 peer=258 mask=00000001 total=2");
	CHECK(audit.reply(round, kB, kFull, log));
}

TEST(levels_audit_round_disconnect_and_reset_remove_pending_replies)
{
	srv::LevelsAudit audit;
	AuditLog log;
	const uint32_t round = audit.begin({kA, kB}, log);
	audit.disconnect(kA);
	CHECK(!audit.reply(round, kA, kFull, log)); // a new connection using the same slot
	CHECK(audit.reply(round, kB, kFull, log)); // the other bridge still owes its reply
	const uint32_t next = audit.begin({kA}, log);
	CHECK(audit.reply(next, kA, kFull, log)); // after its own new challenge
	const uint32_t before_reset = audit.begin({kA}, log);
	audit.clear();
	CHECK(!audit.reply(before_reset, kA, kFull, log));
	CHECK_EQ(audit.begin({}, log), before_reset + 1);
	CHECK_EQ(log.lines.back(), "[coop] levels audit begin round=4 bridges=0");
	CHECK(!audit.reply(before_reset + 1, kA, kFull, log));
}

TEST(levels_audit_round_wire_keeps_ids_senders_and_world_gate)
{
	static_assert(static_cast<uint16_t>(Msg::LevelResync) == 0x01DAu);
	static_assert(static_cast<uint16_t>(Msg::LevelEntity) == 0x01D5u);
	static_assert(static_cast<uint8_t>(LevelEntityHead::Report) == 6u);
	CHECK_EQ(msg_sender(Msg::LevelResync), MsgSender::HostOnly);
	CHECK_EQ(msg_sender(Msg::LevelEntity), MsgSender::TrunkOnly);
	CHECK_EQ(wgate::need_of(Msg::LevelResync), wgate::Need::Drop);
	CHECK_EQ(wgate::need_of(Msg::LevelEntity), wgate::Need::Hold);
}

TEST(levels_audit_round_wire_legacy_request_and_report_have_the_same_prefix)
{
	const uint32_t expected = 0xFEDCBA98u;
	LevelResyncMsg request;
	request.mask = kFull;
	Writer down;
	request.write(down);
	srv::write_audit_round(down, 0);
	CHECK_EQ(down.size(), size_t(4));
	Reader legacy_down(down.ptr(), down.size());
	LevelResyncMsg decoded_request;
	uint32_t round = expected;
	REQUIRE(decoded_request.read(legacy_down) && srv::read_audit_round(legacy_down, round));
	CHECK_EQ(round, 0u);
	srv::write_audit_round(down, expected);
	CHECK(down.data() == std::vector<uint8_t>({0xff, 0xff, 0xff, 0xff, 0x98, 0xba, 0xdc, 0xfe}));
	Reader extended_down(down.ptr(), down.size());
	REQUIRE(decoded_request.read(extended_down)); // the legacy reader can use the base message
	CHECK_EQ(decoded_request.mask, kFull);
	REQUIRE(srv::read_audit_round(extended_down, round));
	CHECK_EQ(round, expected);
	CHECK_EQ(extended_down.remaining(), size_t(0));

	LevelEntityHead head;
	head.op = LevelEntityHead::Report;
	LevelReportBody book;
	book.buckets = kFull;
	book.rows.push_back({9, 42});
	Writer up;
	head.write(up);
	REQUIRE(book.write(up));
	srv::write_audit_round(up, 0);
	CHECK_EQ(up.size(), size_t(13));
	Reader legacy_up(up.ptr(), up.size());
	LevelReportBody decoded_book;
	REQUIRE(head.read(legacy_up) && decoded_book.read(legacy_up) && srv::read_audit_round(legacy_up, round));
	CHECK_EQ(round, 0u);
	srv::write_audit_round(up, expected);
	CHECK_EQ(up.size(), size_t(17));
	Reader extended_up(up.ptr(), up.size());
	REQUIRE(head.read(extended_up) && decoded_book.read(extended_up)); // legacy readers use the same rows
	CHECK_EQ(head.op, LevelEntityHead::Report);
	CHECK_EQ(decoded_book.buckets, kFull);
	REQUIRE(decoded_book.rows.size() == 1);
	CHECK_EQ(decoded_book.rows[0].id, 9u);
	CHECK_EQ(decoded_book.rows[0].gen, 42u);
	REQUIRE(srv::read_audit_round(extended_up, round));
	CHECK_EQ(round, expected);
	CHECK_EQ(extended_up.remaining(), size_t(0));
}

TEST(levels_audit_round_wire_refuses_malformed_extensions)
{
	const uint8_t bytes[] = {1, 2, 3, 4, 5};
	for (const size_t size : {1u, 2u, 3u, 5u})
	{
		Reader bad(bytes, size);
		uint32_t round = 0;
		CHECK(!srv::read_audit_round(bad, round));
	}
	const uint8_t zero[4] = {};
	Reader bad(zero, sizeof(zero));
	uint32_t round = 0;
	CHECK(!srv::read_audit_round(bad, round));
}

TEST(levels_audit_round_transport_disconnect_clears_the_challenged_bridge_slot)
{
	const uint16_t port = t::port(39357);
	t::Node world("world", port), first("first", port), replacement("replacement", port);
	world.cfg.host_plays = false;
	srv::SessionSrv bridges(world.s);
	srv::LevelsAudit audit;
	AuditLog log;
	uint32_t left = 0;
	uint32_t replies = 0;
	bridges.on_bridge_left([&](PeerId from, const std::string&) {
		audit.disconnect(from);
		++left;
	});
	world.s.on(Msg::LevelEntity, [&](PeerId from, Reader& r) {
		LevelEntityHead head;
		LevelReportBody body;
		uint32_t round = 0;
		if (head.read(r) && head.op == LevelEntityHead::Report && body.read(r) && srv::read_audit_round(r, round) && round)
		{
			audit.reply(round, from, body.buckets, log);
			++replies;
		}
	});
	world.cfg.mode = SessionMode::Server;
	REQUIRE(world.host());
	const auto join_bridge = [&](t::Node& node, uint8_t token) {
		node.cfg.hello_role = kHelloRoleMapServer;
		node.cfg.hello_token.fill(token);
		bridges.issue_bridge(1, node.cfg.hello_token);
		return node.connect(port) && t::pump_until({&world.s, &node.s}, 5000, [&] { return node.welcomed; });
	};
	uint32_t heard_round = 0;
	const auto receive_request = [&](PeerId from, Reader& r) {
		LevelResyncMsg request;
		REQUIRE(from == kHostPeer && request.read(r) && request.mask == kFull);
		REQUIRE(srv::read_audit_round(r, heard_round));
	};
	first.s.on(Msg::LevelResync, receive_request);
	replacement.s.on(Msg::LevelResync, receive_request);
	const auto challenge = [&] {
		const uint32_t round = audit.begin(bridges.bridges(), log);
		LevelResyncMsg request;
		request.mask = kFull;
		Writer w;
		request.write(w);
		srv::write_audit_round(w, round);
		world.s.send(kA, Lane::Reliable, Msg::LevelResync, w);
		return round;
	};
	REQUIRE(join_bridge(first, 17));
	const uint32_t old = challenge();
	REQUIRE(t::pump_until({&world.s, &first.s}, 5000, [&] { return heard_round == old; }));
	// The old connection leaves without replying. A new transport can acquire the same peer ID.
	first.s.shutdown("audit test replacement");
	REQUIRE(t::pump_until({&world.s}, 5000, [&] { return left == 1; }));
	REQUIRE(join_bridge(replacement, 18));
	REQUIRE(replacement.s.self() == kA);
	const auto report = [&](uint32_t round) {
		LevelEntityHead head;
		head.op = LevelEntityHead::Report;
		LevelReportBody body;
		body.buckets = kFull;
		Writer w;
		head.write(w);
		REQUIRE(body.write(w));
		srv::write_audit_round(w, round);
		replacement.s.send(kHostPeer, Lane::Reliable, Msg::LevelEntity, w);
	};
	report(old);
	REQUIRE(t::pump_until({&world.s, &replacement.s}, 5000, [&] { return replies == 1; }));
	CHECK_EQ(log.lines.back(), "[coop] levels audit refused round=1 peer=257 mask=ffffffff total=1");
	const uint32_t current = challenge();
	REQUIRE(t::pump_until({&world.s, &replacement.s}, 5000, [&] { return heard_round == current; }));
	report(heard_round);
	REQUIRE(t::pump_until({&world.s, &replacement.s}, 5000, [&] { return replies == 2; }));
	CHECK_EQ(log.lines.back(), "[coop] levels audit ack round=2 peer=257 mask=ffffffff");
}

TEST(levels_audit_round_xfer_hooks)
{
	const auto path = std::filesystem::path(__FILE__).parent_path().parent_path()
	    / "engine/src/xrGame/coop/srv/coop_levels_xfer.cpp";
	std::ifstream in(path, std::ios::binary);
	REQUIRE(in.is_open());
	std::ostringstream source;
	source << in.rdbuf();
	// Skip comments and literals so only code supplies braces and calls.
	const std::regex comments_and_literals(R"cpp(//[^\r\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\\r\n])*"|'(?:\\.|[^'\\\r\n])')cpp");
	const std::string code = std::regex_replace(source.str(), comments_and_literals, " ");

	const auto reset = function_body(code, "xfer_reset");
	CHECK(reset.find("g.manual_audit.clear()") != std::string_view::npos);

	const auto disconnect = function_body(code, "xfer_host_disconnect");
	CHECK(appears_before(disconnect, "g.manual_audit.disconnect(peer)", "if (!g.keeper.connected(peer))"));

	const auto audit = function_body(code, "xfer_audit_now");
	CHECK(appears_before(audit, "g.manual_audit.begin(", "send_resync(bridge, xfer::kAllBuckets, round)"));

	const auto resync = function_body(code, "client_on_resync");
	CHECK(appears_before(resync, "srv::read_audit_round(r, round)", "srv::write_audit_round(w, round)"));

	const auto report = function_body(code, "host_on_report");
	CHECK(appears_before(report, "g.manual_audit.reply(round, from, m.buckets", "g.keeper.audit("));
}

// ---------------------------------------------------------------- R32 WP4 (W5.2): the auditor compares content (membership)

TEST(levels_audit_members_digest_is_the_content_not_the_order)
{
	CHECK_EQ(srv::members_digest({}), uint64_t(0)); // no members: "not compared", as a non-squad
	CHECK(srv::members_digest({0x9001, 0x9002}) != 0);
	CHECK_EQ(srv::members_digest({0x9002, 0x9001}), srv::members_digest({0x9001, 0x9002}));
	CHECK_EQ(srv::members_digest({0x9001, 0x9001, 0x9002}), srv::members_digest({0x9001, 0x9002}));
	CHECK(srv::members_digest({0x9001}) != srv::members_digest({0x9001, 0x9002})); // a member extra
	CHECK(srv::members_digest({0x9001, 0x9003}) != srv::members_digest({0x9001, 0x9002})); // another member
	// in the level hash: the same (id, gen) with other members is another bucket hash, so the bucket is asked for
	xfer::Entry world{0x9100, 4, xfer::kNoParent, true, srv::members_digest({0x9101, 0x9102})};
	xfer::Entry map = world;
	CHECK(xfer::mismatched(xfer::hash_of({world}), xfer::hash_of({map})) == 0);
	map.digest = srv::members_digest({0x9101}); // the world's copy lost no member, the writer did lose one
	CHECK(xfer::mismatched(xfer::hash_of({world}), xfer::hash_of({map})) != 0);
}

// W5: the non-writer heals towards the writer: a member the writer (the map server that holds the squad) lists and the world lacks
// joins the world's squad; a member the world has and the writer does not list leaves it.
TEST(levels_audit_membership_heals_towards_the_writer)
{
	const srv::MemberHeal missing = srv::heal_members({0x9101}, {0x9101, 0x9102});
	CHECK(missing.join == std::vector<uint16_t>({0x9102}));
	CHECK(missing.leave.empty());
	const srv::MemberHeal extra = srv::heal_members({0x9101, 0x9102, 0x9103}, {0x9102});
	CHECK(extra.join.empty());
	CHECK(extra.leave == std::vector<uint16_t>({0x9101, 0x9103}));
	const srv::MemberHeal both = srv::heal_members({0x9103, 0x9101}, {0x9102, 0x9101, 0x9102});
	CHECK(both.join == std::vector<uint16_t>({0x9102}));
	CHECK(both.leave == std::vector<uint16_t>({0x9103}));
	CHECK(srv::heal_members({0x9101, 0x9102}, {0x9102, 0x9101}).empty());
	// applied, the world's list is the writer's
	std::vector<uint16_t> world = {0x9101, 0x9103, 0x9104};
	const std::vector<uint16_t> writer = {0x9104, 0x9101, 0x9105};
	const srv::MemberHeal h = srv::heal_members(world, writer);
	for (const uint16_t id : h.leave)
		world.erase(std::remove(world.begin(), world.end(), id), world.end());
	world.insert(world.end(), h.join.begin(), h.join.end());
	CHECK_EQ(srv::members_digest(world), srv::members_digest(writer));
}

TEST(levels_audit_report_carries_the_members_of_held_squads)
{
	LevelEntityHead head;
	head.op = LevelEntityHead::Report;
	LevelReportBody book;
	book.buckets = kFull;
	book.rows.push_back({0x9100, 4});
	book.rows.push_back({0x9200, 2});
	std::vector<srv::MemberRow> members(2);
	members[0].squad = 0x9100;
	members[0].members = {0x9101, 0x9102};
	members[1].squad = 0x9200; // a squad with no member left
	Writer up;
	head.write(up);
	REQUIRE(book.write(up));
	REQUIRE(srv::write_members(up, members));
	srv::write_audit_round(up, 77);
	Reader r(up.ptr(), up.size());
	LevelEntityHead h2;
	LevelReportBody b2;
	std::vector<srv::MemberRow> m2;
	uint32_t round = 0;
	REQUIRE(h2.read(r) && b2.read(r) && srv::read_members(r, m2) && srv::read_audit_round(r, round));
	CHECK_EQ(round, 77u);
	CHECK_EQ(r.remaining(), size_t(0));
	REQUIRE(m2.size() == 2);
	CHECK_EQ(m2[0].squad, uint16_t(0x9100));
	CHECK(m2[0].members == members[0].members);
	CHECK(m2[1].members.empty());
	// no round: the members end the report
	Writer plain;
	REQUIRE(srv::write_members(plain, members));
	Reader rp(plain.ptr(), plain.size());
	REQUIRE(srv::read_members(rp, m2));
	REQUIRE(srv::read_audit_round(rp, round));
	CHECK_EQ(round, 0u);
}

TEST(levels_audit_members_refuse_malformed_lists)
{
	std::vector<srv::MemberRow> rows;
	{
		Writer w; // cut inside a row
		w.u16(1);
		w.u16(0x9100);
		w.u8(2);
		w.u16(0x9101);
		Reader r(w.ptr(), w.size());
		CHECK(!srv::read_members(r, rows));
		CHECK(rows.empty());
	}
	{
		Writer w; // a squad listed twice
		w.u16(2);
		w.u16(0x9100);
		w.u8(0);
		w.u16(0x9100);
		w.u8(0);
		Reader r(w.ptr(), w.size());
		CHECK(!srv::read_members(r, rows));
	}
	{
		Writer w; // kNoObject as a member
		w.u16(1);
		w.u16(0x9100);
		w.u8(1);
		w.u16(0xffff);
		Reader r(w.ptr(), w.size());
		CHECK(!srv::read_members(r, rows));
	}
	{
		Writer w; // a count the packet cannot hold
		w.u16(5000);
		Reader r(w.ptr(), w.size());
		CHECK(!srv::read_members(r, rows));
	}
	std::vector<srv::MemberRow> too_many(1);
	too_many[0].squad = 0x9100;
	too_many[0].members.assign(srv::kMaxMembers + 1, 0x9101);
	Writer w;
	CHECK(!srv::write_members(w, too_many));
	CHECK_EQ(w.size(), size_t(0));
}

// The engine hooks of the content audit (xrGame is not linked here: its source is read).
TEST(levels_audit_membership_hooks)
{
	const auto path = std::filesystem::path(__FILE__).parent_path().parent_path()
	    / "engine/src/xrGame/coop/srv/coop_levels_xfer.cpp";
	std::ifstream in(path, std::ios::binary);
	REQUIRE(in.is_open());
	std::ostringstream source;
	source << in.rdbuf();
	const std::regex comments_and_literals(R"cpp(//[^\r\n]*|/\*[\s\S]*?\*/|"(?:\.|[^"\\r\n])*"|'(?:\.|[^'\\r\n])')cpp");
	const std::string code = std::regex_replace(source.str(), comments_and_literals, " ");

	const auto report = function_body(code, "host_on_report");
	CHECK(appears_before(report, "srv::read_members(r, members)", "srv::read_audit_round(r, round)"));
	CHECK(appears_before(report, "g.keeper.audit(", "host_heal_members(from, members)")); // after the ledger's own heal

	const auto heal = function_body(code, "host_heal_members");
	CHECK(appears_before(heal, "g.keeper.holder_of(row.squad) != u32(from)", "srv::heal_members(world, row.members)")); // the writer's word only
	// review WP4 #9: each change is a Joined / Left entry through the world's one acceptance, never a join on the holder's word alone
	CHECK(heal.find("host_heal_member(from, wire::LevelEntityHead::Joined, row.squad, id)") != std::string_view::npos);
	CHECK(heal.find("host_heal_member(from, wire::LevelEntityHead::Left, row.squad, id)") != std::string_view::npos);
	CHECK(heal.find("coop_join_member(") == std::string_view::npos);
	CHECK(code.find("host_apply_heal(from, e, why, g.received.last(u32(from)))") != std::string::npos); // host_apply_fact's rule (fix round 2 of A)

	const auto resync = function_body(code, "client_on_resync");
	CHECK(appears_before(resync, "srv::write_members(w, members)", "srv::write_audit_round(w, round)"));

	const auto audit = function_body(code, "client_audit");
	CHECK(appears_before(audit, "e.digest = held_members_digest(e.id)", "xfer::hash_of(mine)"));
}

// Review WP4 #9: the heal of a membership is the journal's Joined / Left, so the same rule decides it. A creature in a squad another
// map server writes is not taken from it on this map server's word (the two would take it from each other every audit round); one
// in another squad this map server writes, or a Left of its own squad, is taken.
TEST(levels_audit_heal_of_a_foreign_member_is_refused)
{
	namespace w = coop::writer;
	namespace acc = coop::levels::accept;
	const w::Process world{w::ProcessKind::World, w::kNoLevel, coop::kHostPeer};
	const auto held_by = [&](coop::PeerId bridge) {
		w::Seat s;
		s.hold = w::Hold::Held;
		s.holder = bridge;
		s.holder_level = 5;
		return w::writer_of(w::RootFacts{w::RootKind::Unit, 0x9100, 5}, world, s);
	};
	acc::Facts join;
	join.op = LevelEntityHead::Joined;
	join.sender = kA;
	join.sender_level = 5;
	join.exists = true;
	join.two_roots = true;
	join.writer_new = held_by(kA); // the squad it joins: kA's
	join.writer = held_by(kB); // the squad it is in: kB's
	const acc::Verdict foreign = acc::accepts(join);
	CHECK(!foreign.ok);
	CHECK_EQ(foreign.why, uint8_t(coop::levels::journal::NotWriter));
	join.writer = held_by(kA); // in another squad kA holds
	CHECK(acc::accepts(join).ok);
	acc::Facts leave;
	leave.op = LevelEntityHead::Left;
	leave.sender = kA;
	leave.sender_level = 5;
	leave.exists = true;
	leave.writer = held_by(kA);
	CHECK(acc::accepts(leave).ok);
	leave.writer = held_by(kB);
	CHECK(!acc::accepts(leave).ok);
}
