// O6-srv (round after builds 55-58; triage 2026-11-23): the Server layer's engine tails of R32 (temp/r30/design/R32-final.md §8a A21-A25).
//   1  the replay window (§8a A22 open item a): a starting map server says Ready only in a frame after the one that queued its level's
//      done-records, once its Lua was up in that frame: the script delivery of that frame (coop_sync.cpp: script::frame before
//      mode().frame()) handed them to Lua before any player that Ready lets in can retry an op (journal::done::ReplayGate);
//   2  the world learns an info portion of a non-actor object that a map server's own logic gives or takes: the Core's InventoryOwner
//      asks the mode's level side (LevelSide::level_info_up), the map server journals Info, the world writes its record (set_info);
//   3  the world server's memory guard also reads the commit left (report #938: the world server died of out-of-memory with 0.6 GB of
//      commit free): no map server starts under a commit floor, an operator line says so; the low-memory notices carry no '!';
//   4  the needs-data refusals (#1644-#1649) carry their data: the section (name, or the crc of the entry) and the parent now, the
//      ItemFacts uses refusal one text per branch; Parent + Unknown keeps its Fetch (reasoning in the test).
// Coop: none of it runs there (no level side, no map server, no journal); the tests named *_coop_* read that.
// Fix round (the verifier's findings): 3 counts the map servers still loading as if they had their commit (two starts in one load
// window no longer pass one look), bounds a wait for the commit alone (kCommitWaitMs: the look cannot see a growable page file's room)
// except under kCommitHardBytes (#938's ground); 1's glue test also pins that the gate is fed every frame, not in a new holder's alone.
#include "test_util.h"

#include "coop_initial_rules.h"
#include "srv/coop_levels_dynamic.h"
#include "srv/coop_levels_journal.h"
#include "srv/coop_levels_memory.h"

#include <filesystem>
#include <fstream>
#include <regex>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

using namespace coop;
using namespace coop::levels;
namespace jd = coop::levels::journal::done;
using Head = wire::LevelEntityHead;

namespace
{
// ---------------------------------------------------------------- the engine's source (comments blanked, string literals kept)

std::string o6_root() { return std::filesystem::path(__FILE__).parent_path().parent_path().string(); }

std::string o6_src() { return o6_root() + "/engine/src"; }

std::string o6_read(const std::string& path)
{
	std::ifstream in(path, std::ios::binary);
	std::ostringstream s;
	s << in.rdbuf();
	return s.str();
}

// // and /* */ comments blanked, string and char literals kept
std::string o6_code(const std::string& src)
{
	std::string out = src;
	bool line = false, block = false, str = false, chr = false;
	for (size_t i = 0; i < out.size(); ++i)
	{
		const char c = out[i];
		const char n = i + 1 < out.size() ? out[i + 1] : '\0';
		if (chr)
		{
			if (c == '\\')
				++i;
			else if (c == '\'')
				chr = false;
		}
		else if (line)
		{
			if (c == '\n')
				line = false;
			else
				out[i] = ' ';
		}
		else if (block)
		{
			if (c == '*' && n == '/')
			{
				out[i] = out[i + 1] = ' ';
				++i;
				block = false;
			}
			else if (c != '\n')
				out[i] = ' ';
		}
		else if (str)
		{
			if (c == '\\')
				++i;
			else if (c == '"')
				str = false;
		}
		else if (c == '/' && n == '/')
		{
			line = true;
			out[i] = out[i + 1] = ' ';
			++i;
		}
		else if (c == '/' && n == '*')
		{
			block = true;
			out[i] = out[i + 1] = ' ';
			++i;
		}
		else if (c == '"')
			str = true;
		else if (c == '\'')
			chr = true;
	}
	return out;
}

std::string o6_file(const std::string& rel) { return o6_code(o6_read(o6_src() + "/" + rel)); }

// The body of the first definition `<head>(...) {` (head a regex, e.g. R"(bool\s+CInventoryOwner::OnReceiveInfo)"), "" for none.
std::string o6_body(const std::string& code, const std::string& head)
{
	std::smatch m;
	const std::regex rx(head + R"(\s*\([^;{}]*\)\s*(const\s*)?(override\s*)?\{)");
	if (!std::regex_search(code, m, rx))
		return "";
	const size_t start = size_t(m.position() + m.length());
	int depth = 1;
	for (size_t i = start; i < code.size(); ++i)
	{
		if (code[i] == '{')
			++depth;
		else if (code[i] == '}' && --depth == 0)
			return code.substr(start, i - start);
	}
	return "";
}

// Whitespace runs as one space: a check reads a call however it is wrapped.
std::string o6_flat(const std::string& s)
{
	std::string out;
	bool space = false;
	for (const char c : s)
	{
		if (c == ' ' || c == '\t' || c == '\r' || c == '\n')
			space = true;
		else
		{
			if (space && !out.empty())
				out += ' ';
			space = false;
			out += c;
		}
	}
	return out;
}

bool o6_has(const std::string& body, std::string_view what) { return body.find(what) != std::string::npos; }

bool o6_before(const std::string& body, std::string_view first, std::string_view second)
{
	const size_t a = body.find(first);
	const size_t b = body.find(second);
	return a != std::string::npos && b != std::string::npos && a < b;
}

size_t o6_count(const std::string& body, std::string_view what)
{
	size_t n = 0;
	for (size_t at = body.find(what); at != std::string::npos; at = body.find(what, at + what.size()))
		++n;
	return n;
}

// The braces open at `at` (comments blanked, so only code braces count; string literals of the bodies read here hold none).
int o6_depth(const std::string& body, size_t at)
{
	int depth = 0;
	for (size_t i = 0; i < at && i < body.size(); ++i)
		depth += body[i] == '{' ? 1 : (body[i] == '}' ? -1 : 0);
	return depth;
}

// The closing brace of the block whose head starts at `head` (its first '{'), npos for none.
size_t o6_block_end(const std::string& body, size_t head)
{
	const size_t open = body.find('{', head);
	if (open == std::string::npos)
		return std::string::npos;
	int depth = 0;
	for (size_t i = open; i < body.size(); ++i)
	{
		if (body[i] == '{')
			++depth;
		else if (body[i] == '}' && --depth == 0)
			return i;
	}
	return std::string::npos;
}

constexpr uint64_t kMiB = 1024ull * 1024ull;
} // namespace

// ================================================================ 1: the replay window (§8a A22 open item a)

TEST(srv_o6_replay_gate_waits_a_later_frame_with_lua)
{
	jd::ReplayGate g;
	CHECK(g.settled()); // nothing replayed: Ready as before
	g.frame(5, true);
	CHECK(g.settled());

	// frame K = 10 queued the records in levels::frame, after that frame's script delivery: the same frame never settles it
	g.queued(10);
	CHECK(!g.settled());
	g.frame(10, true);
	CHECK(!g.settled());
	// the next frame, Lua not up (no level, no actor or no live session): its script delivery handed nothing over
	g.frame(11, false);
	CHECK(!g.settled());
	// a later frame with Lua up: its script delivery ran before the server's frame and gave the engine's queue whole
	g.frame(12, true);
	CHECK(g.settled());
	g.frame(13, false); // stays settled
	CHECK(g.settled());

	// a new world's replay arms it again; reset (a new holder, a session end) clears it
	g.queued(40);
	CHECK(!g.settled());
	g.reset();
	CHECK(g.settled());
	g.queued(41);
	g.frame(42, true);
	CHECK(g.settled());

	// the frame loop as xfer_client_frame runs it (verifier finding 3): frame K is a new holder's (reset, the replay queues, the feed of
	// that frame), every later frame feeds the gate again; with Lua up it is settled by K + 1, so Ready comes one frame later
	jd::ReplayGate loop;
	const uint32_t K = 100;
	for (uint32_t f = K; f <= K + 3; ++f)
	{
		if (f == K)
		{
			loop.reset();
			loop.queued(f);
		}
		loop.frame(f, true);
		CHECK_EQ(loop.settled(), f >= K + 1);
	}
	// fed in frame K alone (the feed inside the new holder's block): never settled, Ready never said
	jd::ReplayGate once;
	once.queued(K);
	once.frame(K, true);
	CHECK(!once.settled());
}

TEST(srv_o6_ready_waits_for_the_replay)
{
	const std::string xfer = o6_file("xrGame/coop/srv/coop_levels_xfer.cpp");
	REQUIRE(!xfer.empty());
	// the replay arms the gate only when it queued a record, after queueing them (one frame of Device's count)
	const std::string replay = o6_body(xfer, R"(void\s+client_replay_done)");
	REQUIRE(!replay.empty());
	CHECK(o6_before(replay, "queue_callback(\"coop_op_done\"", "g.replay_gate.queued(Device.dwFrame)"));
	CHECK(std::regex_search(o6_flat(replay), std::regex(R"(if \(!records\.empty\(\)\) \{? ?g\.replay_gate\.queued\(Device\.dwFrame\);)")));
	// every frame of its world sees whether its Lua is up (coop_script.cpp lua_ready(): the level and the actor, which world_up()
	// at the top of the function reads, and a live session: net::live()), after the replay of a new holder
	const std::string frame = o6_body(xfer, R"(void\s+xfer_client_frame)");
	REQUIRE(!frame.empty());
	CHECK(o6_before(frame, "world_up()", "g.replay_gate.frame(Device.dwFrame, net::live())"));
	CHECK(o6_before(frame, "client_replay_done();", "g.replay_gate.frame(Device.dwFrame, net::live())"));
	// a new holder's world starts clear (its replay arms it again), so does a session's end
	CHECK(o6_before(frame, "g.replay_gate.reset();", "client_replay_done();"));
	CHECK(o6_has(o6_body(xfer, R"(void\s+xfer_reset)"), "g.replay_gate.reset();"));
	// verifier finding 3 (fix round): the feed runs every frame. Inside the new holder's block it would run in frame K alone, which never
	// settles the gate (above), and Ready would never be said. So: one feed, after that block's closing brace, at the depth of the
	// frame's other every-frame calls (the block's own head, client_flush_up), with nothing but comments between the block and it.
	CHECK_EQ(o6_count(frame, "g.replay_gate.frame("), size_t(1));
	const size_t holder = frame.find("if (!g.holder || g.holder_world != join::world_generation())");
	REQUIRE(holder != std::string::npos);
	const size_t holder_end = o6_block_end(frame, holder);
	REQUIRE(holder_end != std::string::npos);
	CHECK(o6_has(frame.substr(holder, holder_end - holder), "client_replay_done();"));
	const size_t feed = frame.find("g.replay_gate.frame(Device.dwFrame, net::live());");
	REQUIRE(feed != std::string::npos);
	CHECK(feed > holder_end);
	CHECK_EQ(o6_depth(frame, feed), o6_depth(frame, holder));
	const size_t flush = frame.find("client_flush_up();");
	REQUIRE(flush != std::string::npos);
	CHECK_EQ(o6_depth(frame, feed), o6_depth(frame, flush));
	CHECK(feed > holder_end && o6_flat(frame.substr(holder_end + 1, feed - holder_end - 1)).empty());
	const std::string heard = o6_body(xfer, R"(bool\s+xfer_replay_heard)");
	REQUIRE(!heard.empty());
	CHECK(o6_has(heard, "g.replay_gate.settled()"));
	// mapserver::server_frame says Ready only once the replay was heard
	const std::string map = o6_file("xrGame/coop/srv/coop_mapserver.cpp");
	const std::string serve = o6_body(map, R"(void\s+server_frame)");
	REQUIRE(!serve.empty());
	const size_t ready = serve.find("say_state(wire::ServerState::Ready);");
	REQUIRE(ready != std::string::npos);
	const std::string gate = o6_flat(serve.substr(0, ready));
	CHECK(o6_has(gate, "if (!me.ready_said && mgr().is_live_client() && world_up() && !Device.dwPrecacheFrame && levels::xfer_replay_heard())"));
	// the order of a frame the gate counts on: the script delivery before the mode's frame, the transfers before the map server's step
	const std::string sync = o6_file("xrGame/coop/coop_sync.cpp");
	const size_t table = sync.find("kFrame[] = {"); // the frame pass of the module table
	REQUIRE(table != std::string::npos);
	CHECK(o6_before(sync.substr(table, sync.find("};", table) - table), "&script::frame}", "mode().frame();"));
	const std::string script = o6_file("xrGame/coop/coop_script.cpp");
	const std::string sframe = o6_body(script, R"(void\s+frame)");
	CHECK(o6_before(sframe, "if (!lua_ready())", "deliver_engine();"));
	CHECK(o6_has(o6_flat(o6_body(script, R"(bool\s+lua_ready)")), "if (!g_pGameLevel || !g_actor) return false; return net::live();"));
	const std::string levels = o6_file("xrGame/coop/coop_levels.cpp");
	CHECK(o6_before(o6_body(levels, R"(void\s+frame)"), "xfer_client_frame();", "mapserver::server_frame();"));
	// the engine's queue goes to Lua whole (no budget, unlike the inbox)
	const std::string deliver = o6_body(script, R"(void\s+deliver_engine)");
	CHECK(o6_has(deliver, "while (!g_engine.empty())"));
	CHECK(!o6_has(deliver, "budget"));
}

// ================================================================ 2: a map server's NPC info reaches the world's record

TEST(srv_o6_info_up_core_caller)
{
	const std::string owner = o6_file("xrGame/inventory_owner_info.cpp");
	REQUIRE(!owner.empty());
	// given: after the registry took it (a known one returns before: the echo of GE_INFO_TRANSFER says nothing again)
	const std::string give = o6_body(owner, R"(bool\s+CInventoryOwner::OnReceiveInfo)");
	REQUIRE(!give.empty());
	CHECK(o6_before(give, "known_info.push_back(", "coop_info_up(this, info_id, true);"));
	CHECK(o6_before(give, "return false;", "coop_info_up(this, info_id, true);"));
	CHECK(o6_before(give, "coop::story::on_info(this, info_id, true)", "coop_info_up(this, info_id, true);"));
	// taken: after the registry let it go (one it never had returns before)
	const std::string take = o6_body(owner, R"(void\s+CInventoryOwner::OnDisableInfo)");
	REQUIRE(!take.empty());
	CHECK(o6_before(take, "known_info.erase(it);", "coop_info_up(this, info_id, false);"));
	CHECK(o6_before(take, "if (known_info.end() == it) return;", "coop_info_up(this, info_id, false);"));
	// the hook asks the mode's level side, nothing else: no mode check (docs/MODES.md §3); the actor's infos are the story's
	const std::string hook = o6_flat(o6_body(owner, R"(void\s+coop_info_up)"));
	REQUIRE(!hook.empty());
	CHECK(o6_has(hook, "const u16 id = owner->object_id();"));
	CHECK(o6_has(hook, "if (id == 0 || !info_id.size()) return;"));
	CHECK(o6_has(hook, "if (coop::LevelSide* side = coop::mode().level()) side->level_info_up(id, info_id.c_str(), on);"));
	for (const char* word : {"is_map_server", "decides_world", "leads_level", "is_host", "dedicated", "mapserver", "levels::"})
		CHECK(!o6_has(hook, word));
	CHECK(o6_has(owner, "#include \"xrCoop/coop_mode.h\""));
	// one caller each, and the stock body otherwise as it was (TransferInfo still sends GE_INFO_TRANSFER and applies here)
	CHECK_EQ(o6_count(owner, "coop_info_up(this,"), size_t(2));
	const std::string transfer = o6_flat(o6_body(owner, R"(void\s+CInventoryOwner::TransferInfo)"));
	CHECK(o6_has(transfer, "CGameObject::u_EventGen(P, GE_INFO_TRANSFER, pThisObject->ID());"));
	CHECK(o6_has(transfer, "CGameObject::u_EventSend(P);"));
	CHECK(o6_has(transfer, "if (add_info) OnReceiveInfo(info_id); else OnDisableInfo(info_id);"));
	CHECK(!o6_has(transfer, "coop_info_up"));
}

TEST(srv_o6_info_up_journaled_and_applied)
{
	// the map server's side: level_info_up journals it (levels::up_info), the flush writes an Info entry in the world's numbering
	const std::string srv = o6_file("xrGame/coop/srv/coop_srv_mode.cpp");
	CHECK(o6_has(o6_flat(srv), "void level_info_up(u16 id, const char* info, bool on) override { levels::up_info(id, info, on); }"));
	const std::string xfer = o6_file("xrGame/coop/srv/coop_levels_xfer.cpp");
	const std::string up = o6_flat(o6_body(xfer, R"(void\s+up_info)"));
	REQUIRE(!up.empty());
	CHECK(o6_has(up, "if (!is_map_server() || entities::client_applying() || !info || !*info) return;")); // its world's word: no echo
	CHECK(o6_has(up, "g.up.push_back(State::Up{wire::LevelEntityHead::Info, id, u16(on ? 1 : 0), journal::ObjectHead(), info});"));
	const std::string flush = o6_body(xfer, R"(void\s+client_flush_up)");
	const size_t at = flush.find("case Head::Info:");
	REQUIRE(at != std::string::npos);
	const std::string info_case = o6_flat(flush.substr(at, flush.find("break;", at) - at));
	CHECK(o6_has(info_case, "body.id = join::to_host(u.a);"));
	CHECK(o6_has(info_case, "journal_body(Head::Info, body, body.id);"));
	// the entry as it travels (pure)
	journal::InfoBody b;
	b.id = 0x1234;
	b.on = 0;
	b.info = "mar_quest_scientist_done";
	Writer w(64);
	REQUIRE(b.write(w));
	Reader r(w.ptr(), w.size());
	journal::InfoBody got;
	REQUIRE(got.read(r));
	CHECK(got.id == 0x1234 && got.on == 0 && got.info == "mar_quest_scientist_done");
	// an Info names no object head and is repaired only on a word about the copy
	CHECK(!journal::names_object(Head::Info));
	CHECK(journal::repair_of(Head::Info, journal::Refused) == journal::Repair::None);
	// the world: its one acceptance, then its record of the object (the registry alife():give_info writes), never a player's
	const std::string alife = o6_file("xrGame/coop/srv/coop_levels_alife.cpp");
	const std::string entry = o6_body(alife, R"(ApplyVerdict\s+apply_entry)");
	const size_t info_at = entry.find("if (e.op == H::Info)");
	REQUIRE(info_at != std::string::npos);
	const std::string applies = o6_flat(entry.substr(info_at, entry.find("return applied(e.op);", info_at) - info_at));
	CHECK(o6_before(applies, "accept::accepts(f)", "set_info(b.id, b.info, b.on != 0);"));
	CHECK(o6_before(applies, "world::is_player_character(obj)", "set_info(b.id, b.info, b.on != 0);"));
	const std::string set = o6_flat(o6_body(alife, R"(void\s+set_info)"));
	CHECK(o6_has(set, "CInfoPortionRegistry& reg = alife_rw().registry().get<CInfoPortionRegistry>();"));
	CHECK(o6_has(set, "if (on && it == known->end()) known->push_back(name); else if (!on && it != known->end()) known->erase(it);"));
}

TEST(srv_o6_info_up_coop_has_no_level_side)
{
	// Coop: both co-op modes answer no level side, so the Core's hook does nothing there; their files never journal an info
	const std::string hostplay = o6_file("xrGame/coop/hostplay/coop_hostplay_mode.cpp");
	REQUIRE(!hostplay.empty());
	// both co-op modes answer it in their common base (CoopModeBase)
	CHECK_EQ(o6_count(hostplay, "LevelSide* level() override { return nullptr; }"), size_t(1));
	CHECK_EQ(o6_count(hostplay, "final : public CoopModeBase"), size_t(2));
	CHECK(!o6_has(hostplay, "level_info_up"));
	for (const auto& f : std::filesystem::directory_iterator(o6_src() + "/xrGame/coop/hostplay"))
		if (f.is_regular_file())
			CHECK(!o6_has(o6_read(f.path().string()), "level_info_up"));
	// none (single player, before a session) has none either; of the server's modes only the map server has one
	const std::string mode = o6_file("xrCoop/coop_mode.h");
	CHECK(o6_has(mode, "virtual LevelSide* level() { return nullptr; }"));
	const std::string srv = o6_file("xrGame/coop/srv/coop_srv_mode.cpp");
	CHECK_EQ(o6_count(srv, "LevelSide* level() override { return nullptr; }"), size_t(2)); // the world server, a player's machine
	CHECK_EQ(o6_count(srv, "LevelSide* level() override { return &map_level_side(); }"), size_t(1));
}

// ================================================================ 3: the commit guard (report #938)

TEST(srv_o6_commit_floor)
{
	// the floor: what a map server commits when it is up and what the world server may still need
	static_assert(kCommitFloorBytes == kMapServerCommitBytes + kCommitHeadroomBytes, "the floor is a map server and the headroom");
	static_assert(kCommitFloorBytes >= 2048 * kMiB, "a map server alone commits 1.0-1.7 GB");
	static_assert(kCommitBackBytes > kCommitFloorBytes, "a band, no flapping");
	// report #938: 0.6 GB of commit left is low, whatever the physical memory says
	CHECK(commit_low(false, 600 * kMiB));
	CHECK(commit_low(false, kCommitFloorBytes - 1));
	CHECK(!commit_low(false, kCommitFloorBytes));
	CHECK(commit_low(true, kCommitFloorBytes + 1)); // once low, until it is clearly back
	CHECK(commit_low(true, kCommitBackBytes - 1));
	CHECK(!commit_low(true, kCommitBackBytes));
	CHECK(commit_low(false, 0));

	// the look: physical and commit, each with its own border; a start waits on the commit alone, lingering on either
	MemoryLook m;
	CHECK(!m.phys_low && !m.commit_low);
	m = look_memory(m, 8192 * kMiB, 600 * kMiB); // #938: plenty of RAM, no commit
	CHECK(!m.phys_low && m.commit_low);
	CHECK(!may_start_map_server(m));
	CHECK(short_of_memory(m));
	m = look_memory(m, 8192 * kMiB, kCommitFloorBytes + 1); // inside the band: still low
	CHECK(m.commit_low && !may_start_map_server(m));
	m = look_memory(m, 8192 * kMiB, kCommitBackBytes);
	CHECK(!m.commit_low && may_start_map_server(m) && !short_of_memory(m));
	m = look_memory(m, 1024 * kMiB, 16384 * kMiB); // short of RAM, plenty of commit: no lingering, but a start goes on
	CHECK(m.phys_low && !m.commit_low);
	CHECK(short_of_memory(m) && may_start_map_server(m));
	CHECK_EQ(m.phys_low, memory_low(false, 1024 * kMiB)); // the physical rule is the one of build 50
	m = look_memory(m, kLowMemoryBytes + 1, 16384 * kMiB); // its border keeps its own band
	CHECK(m.phys_low);
}

TEST(srv_o6_start_room_counts_the_loading)
{
	// Verifier finding 1 (fix round): a map server takes its 1.0-1.7 GB over its 30-90 s load, the look is up to 2 s old, and host_frame
	// launches every level that wants one in the same pass. Each server still loading counts as if it had its kMapServerCommitBytes now.
	// The failure scenario: 3.2 GB of commit left, two levels want a map server in the same frame.
	const uint64_t left = 3277 * kMiB;
	const MemoryLook m = look_memory(MemoryLook(), 8192 * kMiB, left);
	REQUIRE(!m.commit_low);
	CHECK(start_room(m, left, 0, 0) == StartRoom::Go); // the first one starts
	CHECK(start_room(m, left, 1, 0) == StartRoom::Loading); // the second waits for it: together they would leave 0.2 GB
	CHECK(starts(StartRoom::Go) && starts(StartRoom::GoUnsure));
	CHECK(!starts(StartRoom::Loading) && !starts(StartRoom::Commit) && !starts(StartRoom::HardFloor));
	CHECK_EQ(commit_after_starting(left, 1), left - kMapServerCommitBytes);
	CHECK_EQ(commit_after_starting(left, 3), uint64_t(0)); // no wrap
	CHECK_EQ(commit_after_starting(left, 0), left);
	// room for a third next to two loading ones, and one byte less
	const uint64_t plenty = 2 * kMapServerCommitBytes + kCommitFloorBytes;
	CHECK(start_room(look_memory(MemoryLook(), 8192 * kMiB, plenty), plenty, 2, 0) == StartRoom::Go);
	CHECK(start_room(look_memory(MemoryLook(), 8192 * kMiB, plenty - 1), plenty - 1, 2, 0) == StartRoom::Loading);
	// a loading server holds a start whatever the wait's clock says: the commit's time limit never runs past a load
	const MemoryLook low = look_memory(MemoryLook(), 8192 * kMiB, 2400 * kMiB);
	REQUIRE(low.commit_low);
	CHECK(start_room(low, 2400 * kMiB, 1, 10ull * kCommitWaitMs) == StartRoom::Loading);
	CHECK(start_room(low, 64ull * 1024 * kMiB, 1, 0) == StartRoom::Loading); // still low by its band: no start while one loads
}

TEST(srv_o6_commit_wait_has_a_time_limit)
{
	// Verifier finding 2 (fix round): ullAvailPageFile is the room under the commit limit of now (this PC 2026-11-23: limit 52184 MB =
	// RAM 32636 MB + its page file 19547 MB, AutomaticManagedPagefile on), and Windows grows a page file it manages only when the
	// commit charge comes near that limit. So a commit left under the floor may be room nobody asked Windows for yet, and a start that
	// waits for the commit alone (nothing else loads) goes ahead after kCommitWaitMs - unless it would leave this PC under 0.5 GB:
	// report #938's ground (the world server died with 0.6 GB free), where it keeps waiting.
	static_assert(kCommitHardBytes == kMapServerCommitBytes + 512 * kMiB, "a start under it would leave the PC under 0.5 GB");
	static_assert(kCommitHardBytes < kCommitFloorBytes, "a band where the wait is bounded");
	static_assert(kCommitWaitMs >= 2 * 15000, "longer than an empty map server needs to stop (kStopTimeoutMs) and a look after it");
	static_assert(kCommitWaitMs < kStartTimeoutMs, "shorter than the load the players wait for anyway");
	const uint64_t growable = 2400 * kMiB; // the failure scenario: 2.4 GB left under a limit Windows could still raise
	const MemoryLook low = look_memory(MemoryLook(), 8192 * kMiB, growable);
	REQUIRE(low.commit_low);
	CHECK(start_room(low, growable, 0, 0) == StartRoom::Commit);
	CHECK(start_room(low, growable, 0, kCommitWaitMs - 1) == StartRoom::Commit);
	CHECK(start_room(low, growable, 0, kCommitWaitMs) == StartRoom::GoUnsure);
	CHECK(start_room(low, kCommitHardBytes, 0, kCommitWaitMs) == StartRoom::GoUnsure);
	CHECK(start_room(low, kCommitHardBytes - 1, 0, kCommitWaitMs) == StartRoom::HardFloor);
	CHECK(start_room(low, 600 * kMiB, 0, 100ull * kCommitWaitMs) == StartRoom::HardFloor); // #938
	CHECK(start_room(low, 600 * kMiB, 0, 0) == StartRoom::Commit);
	// the commit back over its band: a start goes at once, whatever the clock
	const MemoryLook back = look_memory(low, 8192 * kMiB, kCommitBackBytes);
	REQUIRE(!back.commit_low);
	CHECK(start_room(back, kCommitBackBytes, 0, 0) == StartRoom::Go);

	// The clock of one start's wait (StartWait): it runs from the first frame of the wait, starts over at every frame another server
	// loads, and a start ends the wait (the next one begins at 0).
	StartWait w;
	CHECK(!w.waiting());
	CHECK(w.step(low, growable, 0, 1000) == StartRoom::Commit);
	CHECK(w.waiting());
	CHECK(w.step(low, growable, 0, 1000 + kCommitWaitMs - 1) == StartRoom::Commit);
	CHECK_EQ(w.waited_ms(), uint64_t(kCommitWaitMs - 1));
	const uint64_t loads_at = 1000 + kCommitWaitMs;
	CHECK(w.step(low, growable, 1, loads_at) == StartRoom::Loading); // another one loads: its clock starts over here
	CHECK_EQ(w.waited_ms(), uint64_t(0));
	CHECK(w.step(low, growable, 1, loads_at + 90000) == StartRoom::Loading); // a whole load long
	const uint64_t up_at = loads_at + 90001; // it is up: the wait for the commit alone runs from its last loading frame
	CHECK(w.step(low, growable, 0, up_at) == StartRoom::Commit);
	CHECK(w.step(low, growable, 0, loads_at + 90000 + kCommitWaitMs - 1) == StartRoom::Commit);
	CHECK(w.step(low, growable, 0, loads_at + 90000 + kCommitWaitMs) == StartRoom::GoUnsure);
	CHECK_EQ(w.waited_ms(), uint64_t(kCommitWaitMs)); // what the start's line says
	CHECK(!w.waiting()); // it started: the wait is over
	CHECK(w.step(low, growable, 0, up_at + 500000) == StartRoom::Commit); // a later start waits from 0 again
	CHECK_EQ(w.waited_ms(), uint64_t(0));
	// under the hard floor the clock runs on, the start never goes by itself; the commit back ends it at once
	StartWait h;
	CHECK(h.step(low, 600 * kMiB, 0, 0) == StartRoom::Commit);
	CHECK(h.step(low, 600 * kMiB, 0, 10ull * kCommitWaitMs) == StartRoom::HardFloor);
	CHECK(h.waiting());
	CHECK(h.step(back, kCommitBackBytes, 0, 10ull * kCommitWaitMs + 1) == StartRoom::Go);
	CHECK(!h.waiting());
	// a clock that went back (a value older than the start of the wait) counts as no time
	StartWait b;
	CHECK(b.step(low, growable, 0, 5000) == StartRoom::Commit);
	CHECK(b.step(low, growable, 0, 10) == StartRoom::Commit);
	CHECK_EQ(b.waited_ms(), uint64_t(0));
}

TEST(srv_o6_memory_guard_glue)
{
	const std::string map = o6_file("xrGame/coop/srv/coop_mapserver.cpp");
	const std::string raw = o6_read(o6_src() + "/xrGame/coop/srv/coop_mapserver.cpp");
	REQUIRE(!map.empty());
	const std::string check = o6_flat(o6_body(map, R"(void\s+check_memory)"));
	REQUIRE(!check.empty());
	CHECK(o6_has(check, "g.memory = levels::look_memory(g.memory, m.ullAvailPhys, m.ullAvailPageFile);"));
	CHECK(o6_has(check, "g.commit_mb = m.ullAvailPageFile / (1024 * 1024);"));
	CHECK(o6_has(check, "g.commit_bytes = m.ullAvailPageFile;")); // the start rule reads bytes, not the line's MB
	CHECK(o6_has(check, "g.low_memory = levels::short_of_memory(g.memory);"));
	// the notices are the operator's, no fault: no '!' after the tag
	CHECK(!o6_has(check, "\"! [coop] map servers"));
	CHECK(o6_has(check, "::Msg(\"[coop] map servers: this PC has %llu MB of %llu MB physical memory free"));
	CHECK(o6_has(check, "::Msg(\"[coop] map servers: %llu MB of commit left"));
	// a start waits (it does not count as a failure: no lost()) while the servers still loading would take the room or the commit is
	// low (levels::start_room, the clock of its wait levels::StartWait); it asks with the count of loading servers of this very moment,
	// so a server started earlier in the same pass counts (verifier finding 1), and says why it waits once per reason
	const std::string host = o6_body(map, R"(void\s+host_frame)");
	REQUIRE(!host.empty());
	const size_t want = host.find("else if (s.life.want_start())");
	REQUIRE(want != std::string::npos);
	const std::string start = o6_flat(host.substr(want, host.find("else if (s.life.want_stop(now))", want) - want));
	CHECK(o6_before(start, "const levels::StartRoom room = s.start_wait.step(g.memory, g.commit_bytes, starting_now(), now);",
	    "if (!levels::starts(room))"));
	CHECK(o6_before(start, "if (!levels::starts(room)) tell_wait(level, s, room);", "launch(level, s, join::host_world_epoch())"));
	CHECK(o6_before(start, "s.life.started(now);", "launch(level, s, join::host_world_epoch())"));
	CHECK(!o6_has(start.substr(0, start.find("launch(")), "s.life.lost()"));
	CHECK(!o6_has(start, "may_start_map_server")); // the look alone does not decide a start any more
	// the loading ones: Starting, counted over all servers when asked
	const std::string loading = o6_flat(o6_body(map, R"(u32\s+starting_now)"));
	REQUIRE(!loading.empty());
	CHECK(o6_has(loading, "for (const auto& it : g.servers) n += it.second.life.state() == levels::ServerState::Starting ? 1u : 0u;"));
	// the lines: once per reason, the operator's (no '!'); a start after the time limit says so
	const std::string tell = o6_flat(o6_body(map, R"(void\s+tell_wait)"));
	REQUIRE(!tell.empty());
	CHECK(o6_has(tell, "if (s.start_told == room) return; s.start_told = room;"));
	CHECK(o6_has(tell, "::Msg(\"[coop] map server of level %u [%s] waits: %llu MB of commit left on this PC"));
	CHECK(o6_has(tell, "::Msg(\"[coop] map server of level %u [%s] waits for %u map server(s) still loading"));
	CHECK(o6_has(tell, "::Msg(\"[coop] map server of level %u [%s] still waits after %u s"));
	CHECK(!o6_has(tell, "\"! [coop]"));
	CHECK(o6_has(start, "if (room == levels::StartRoom::GoUnsure) ::Msg(\"[coop] map server of level %u [%s] starts after %u s of waiting"));
	CHECK(o6_has(start, "s.start_told = levels::StartRoom::Go;"));
	CHECK(!o6_has(start, "\"! [coop]"));
	// the guard's numbers in the status line
	CHECK(o6_has(o6_flat(raw), "g.commit_mb"));
	// the rule is the server's: the Core never names it
	for (const auto& f : std::filesystem::directory_iterator(o6_src() + "/xrGame/coop"))
		if (f.is_regular_file())
			CHECK(!o6_has(o6_read(f.path().string()), "coop_levels_memory.h"));
}

// ================================================================ 4: the needs-data refusals carry their data

TEST(srv_o6_uses_the_store_cannot_keep_are_staged)
{
	// the two cases the uses store cannot keep (coop_initial_rules.h uses_store -> Refuse): the world stages the uses (coop_items.cpp
	// host_take_item_facts), so neither refuses an ItemFacts: a map server's loot on the ground (drinks and kits of a scripted section)
	const std::vector<uint8_t> none;
	std::vector<uint8_t> ground(initial::kHeldEatableSize + 4, 0);
	ground[initial::kSyncItemsAt] = 1; // an item on the ground writes its physics state after a non-zero count
	CHECK(initial::uses_store(none, nullptr, 2, true, false) == initial::UsesStore::Refuse); // a scripted section, no writer's bytes
	CHECK(initial::uses_store(ground, nullptr, 2, false, true) == initial::UsesStore::Refuse); // bytes here of an item on the ground
	const std::string items = o6_read(o6_src() + "/xrGame/coop/coop_items.cpp");
	CHECK(!o6_has(items, "the uses cannot be stored"));
	CHECK(o6_has(items, "stage_uses(id, facts.uses);"));
}

TEST(srv_o6_object_note)
{
	CHECK_EQ(journal::object_note(true, "wpn_ak74", 0x1a2b, 0x0400, false, wire::kNoObject), std::string("here: section 'wpn_ak74', parent 1024"));
	CHECK_EQ(journal::object_note(true, "wpn_ak74", 0, wire::kNoObject, false, wire::kNoObject), std::string("here: section 'wpn_ak74', no parent"));
	// the world has no such object (#1646/#1649): the section its entry named and where the entry puts it
	CHECK_EQ(journal::object_note(false, nullptr, 0x1a2b, wire::kNoObject, true, 0x0401), std::string("not here, its entry names section crc 0x1a2b, moved to 1025"));
	CHECK_EQ(journal::object_note(false, nullptr, 0x1a2b, wire::kNoObject, true, wire::kNoObject), std::string("not here, its entry names section crc 0x1a2b, put down"));
	CHECK_EQ(journal::object_note(false, nullptr, 0, wire::kNoObject, false, wire::kNoObject), std::string("not here"));
	CHECK_EQ(journal::object_note(true, nullptr, 0, 7, false, wire::kNoObject), std::string("here: section '?', parent 7"));
	CHECK_EQ(journal::object_note(true, "bandage", 0, 3, true, 9), std::string("here: section 'bandage', parent 3, moved to 9"));
}

TEST(srv_o6_refusal_lines_carry_data)
{
	const std::string alife = o6_file("xrGame/coop/srv/coop_levels_alife.cpp");
	REQUIRE(!alife.empty());
	// every refusal line of the world names the object as it sees it (or the crc its entry named) and, for a move, where it goes
	const std::string refuse = o6_flat(o6_body(alife, R"(ApplyVerdict\s+refuse)"));
	REQUIRE(!refuse.empty());
	CHECK(o6_has(refuse, "journal::object_note("));
	CHECK(o6_has(refuse, "seen.crc"));
	CHECK(o6_has(refuse, "seen.move, seen.to"));
	CHECK(o6_has(refuse, "here->ID_Parent"));
	CHECK(o6_has(refuse, "\"! [coop] levels: %s of object %u from map server %u refused (%u so far): %s%s%s; %s\""));
	const std::string entry = o6_body(alife, R"(ApplyVerdict\s+apply_entry)");
	REQUIRE(!entry.empty());
	CHECK(o6_has(o6_flat(entry), "Seen seen; seen.crc = h.crc;"));
	// a Parent names where its entry puts the object
	const size_t parent = entry.find("case H::Parent:");
	REQUIRE(parent != std::string::npos);
	const std::string pcase = o6_flat(entry.substr(parent, entry.find("case H::State:", parent) - parent));
	CHECK(o6_has(pcase, "to_seen.move = true; to_seen.to = parent;"));
	CHECK(o6_has(pcase, "return refused_by(author, e.op, item, v, why, to_seen);"));
	CHECK(o6_has(pcase, "return refuse(author, e.op, item, journal::Unknown, why, \"its new holder is not here\", to_seen);"));
	// the Item case keeps its row (tests/test_item_baseline.cpp pins it): refuse() names the branch, the world has the item there
	const size_t item = entry.find("case H::Item:");
	REQUIRE(item != std::string::npos);
	const std::string icase = o6_flat(entry.substr(item, entry.find("case H::Tent:", item) - item));
	CHECK(o6_has(icase, "if (!taken) return refuse(author, e.op, h.id, journal::Refused, why, no);"));
	// the map server's own line names its object as it has it, in the world's numbering
	const std::string xfer = o6_file("xrGame/coop/srv/coop_levels_xfer.cpp");
	const std::string ack = o6_flat(o6_body(xfer, R"(void\s+client_on_journal_ack)"));
	REQUIRE(!ack.empty());
	CHECK(o6_has(ack, "journal::object_note("));
	CHECK(o6_has(ack, "join::to_host(mine->ID_Parent)"));
	CHECK(o6_has(ack, "\"! [coop] levels: the world refused %s of object %u in batch %u (%u so far): %s; %s\""));
}

TEST(srv_o6_parent_unknown_still_fetches)
{
	// The decision (O6, item 4): a Parent the world refuses as Unknown (it has no such object) keeps its Fetch: the map server asks for
	// the world's copy (StateDumpRequest Replace) and the world answers EntityDestroy. Repair::None would lose no world state, but it is
	// not shown that it loses none at all: (1) when the world released the object first, its own EntityDestroy reaches the map server
	// anyway, both ends agree; (2) when the world never got its Spawn, Fetch removes the item players see now, None keeps it on the map
	// server only, where its next hand-over or a player's move through the world loses it anyway (its later ups are refused as well);
	// (3) when the id is of the world's own numbering and the world freed it, None leaves a copy under an id the world may give a new
	// object, the very duplicate W5 repairs. Until the data of these lines (O6) names the cause, the rule stays.
	CHECK(journal::repair_of(Head::Parent, journal::Unknown) == journal::Repair::Fetch);
	CHECK(journal::repair_of(Head::Parent, journal::Refused) == journal::Repair::None);
	CHECK(journal::repair_of(Head::Item, journal::Refused) == journal::Repair::None); // the uses refusal repairs nothing
	CHECK(journal::repair_of(Head::Spawn, journal::Unknown) == journal::Repair::ReleaseKeepId);
}
