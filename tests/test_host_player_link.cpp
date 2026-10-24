// Anomaly Coop unit tests: the host player through the internal channel (F3a T7, docs/plans/2026-10-24-f3a-split-levels.md
// §1.2). The world server lives in the host's process; the host player is its client over the LocalLink (peer 0), with the
// same messages and handlers as a remote client. F3a T7 moves the F3 modules onto the link: the host player's rest,
// checkpoint claims, life reports and revives, new character, money transfers, coop.sync requests and Lua events go to
// the world server as messages, and its answers come back as messages, at the next pump.
//
// The game's handlers live in xrGame (no unit tests there): these tests drive the real gate of the link (link_enabled),
// the real hosting Session (its sender check and world gate for peer 0) and the real wire layouts of each module, with
// handlers that answer the way the world server answers. One request in, the world handler runs once with from = 0, the
// answer reaches the host player's handler at the next pump, once. The last test reads the module sources: the direct
// branches "if the host - itself" that the link replaces must not come back next to it (Review Focus 1: nothing may run
// twice in the host's process).
#include "test_util.h"
#include "coop_local_link.h"
#include "coop_protocol.h"
#include "coop_session.h"
#include "coop_rest_rules.h"
#include "coop_checkpoint_source_rules.h"
#include "coop_death_rules.h"
#include "coop_death_items.h"
#include "coop_ledger.h"
#include "coop_syncnet.h"
#include "coop_revive_hold.h"

#include <cstdint>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

using namespace coop;

namespace
{
// A hosting session with the host player's end of the link attached, gated like the game (Manager: set_gate(&link_enabled)).
struct HostWithLink
{
	LocalLink link; // outlives the session it is attached to
	t::Node host;
	explicit HostWithLink(uint16_t port) : host("Boss", port) { link.set_gate(&link_enabled); }
	~HostWithLink() { host.s.attach_local(nullptr); }
	bool start()
	{
		if (!host.host())
			return false;
		host.s.attach_local(&link);
		return true;
	}
	void update() { host.s.update(t::now_ms()); }
	// The host player sends to his world server (net::client_send in the host's process).
	bool player_sends(Msg type, const Writer& w, Lane lane = Lane::Reliable) { return link.push_to_server(type, lane, w); }
	// The world server sends its player (net::host_send(0, ...)).
	void server_sends(Msg type, const Writer& w, Lane lane = Lane::Reliable) { host.s.send(kHostPeer, lane, type, w); }
};

bool contains(const std::vector<std::string>& v, const std::string& s)
{
	for (const std::string& x : v)
		if (x == s)
			return true;
	return false;
}
} // namespace

// ============================================================================ the gate

TEST(t7_link_carries_the_moved_types)
{
	// Moved by F3a T7, both ways (the gate is one table for both directions).
	const Msg moved[] = {Msg::RestRequest, Msg::RestState, Msg::RestSleep, Msg::CheckpointClaim, Msg::CheckpointState,
		Msg::PlayerWounded, Msg::PlayerRevive, Msg::PlayerRules, Msg::NewCharacter, Msg::DeathMarker, Msg::ReqMoney,
		Msg::MoneyBalance, Msg::SyncRequest, Msg::SyncResult, Msg::ScriptEvent};
	for (Msg m : moved)
	{
		if (!link_enabled(m))
			t::report_failure(__FILE__, __LINE__, std::string("not on the link: ") + msg_name(m));
	}
	// Kept off on purpose (task-7-report.md): the coop.sync store and its effects are one copy in the host's process (no
	// mirror to keep in step); PlayerShot is cosmetic and the host player's own shots are his; PlayerDied is the engine
	// death relay of coop_events (the actor never dies in a session).
	const Msg kept_off[] = {Msg::SyncSet, Msg::SyncFull, Msg::SyncCast, Msg::PlayerShot, Msg::PlayerDied};
	for (Msg m : kept_off)
	{
		if (link_enabled(m))
			t::report_failure(__FILE__, __LINE__, std::string("on the link, but kept off on purpose: ") + msg_name(m));
	}
}

// ============================================================================ rest

TEST(t7_rest_host_player_lies_down_through_the_link)
{
	HostWithLink h(37651);
	REQUIRE(h.start());
	std::vector<PeerId> asked_from;
	std::vector<rest::Request> asked;
	std::vector<std::string> order;
	std::vector<rest::StateMsg> states;
	std::vector<uint8_t> sleeps;
	h.host.s.on(Msg::RestRequest, [&](PeerId from, Reader& r) {
		rest::Request rq;
		CHECK(rest::read_request(r, rq));
		asked.push_back(rq);
		asked_from.push_back(from);
		// the world server: the book says everybody sleeps, the sleepers get RestState then RestSleep (start_sleep)
		rest::StateMsg m;
		rest::Entry e;
		e.character = 0;
		e.state = rest::State::Sleeping;
		e.hours = rq.hours;
		m.entries.push_back(e);
		Writer w;
		rest::write_state(w, m);
		h.server_sends(Msg::RestState, w);
		Writer s;
		rest::write_sleep(s, rq.hours);
		h.server_sends(Msg::RestSleep, s);
	});
	h.link.on(Msg::RestState, [&](PeerId from, Reader& r) {
		CHECK_EQ(from, kHostPeer);
		rest::StateMsg m;
		CHECK(rest::read_state(r, m));
		states.push_back(m);
		order.push_back("state");
	});
	h.link.on(Msg::RestSleep, [&](PeerId from, Reader& r) {
		CHECK_EQ(from, kHostPeer);
		uint8_t hours = 0;
		CHECK(rest::read_sleep(r, hours));
		sleeps.push_back(hours);
		order.push_back("sleep");
	});

	rest::Request rq;
	rq.op = rest::Op::LieDown;
	rq.hours = 6;
	Writer w;
	rest::write_request(w, rq);
	REQUIRE(h.player_sends(Msg::RestRequest, w));
	CHECK(asked.empty()); // never inside the push
	h.update();
	REQUIRE(asked.size() == size_t(1));
	CHECK_EQ(asked_from[0], kHostPeer);
	CHECK(asked[0].op == rest::Op::LieDown);
	CHECK_EQ(int(asked[0].hours), 6);
	CHECK(states.empty()); // the answer waits for the next pump, as a remote client's answer waits for the net
	h.update();
	REQUIRE(states.size() == size_t(1));
	REQUIRE(states[0].entries.size() == size_t(1));
	CHECK(states[0].entries[0].state == rest::State::Sleeping);
	CHECK(sleeps == (std::vector<uint8_t>{6}));
	CHECK(order == (std::vector<std::string>{"state", "sleep"})); // the sleeper reads "sleeping" before his RestSleep
	for (int i = 0; i < 5; ++i)
		h.update();
	CHECK_EQ(asked.size(), size_t(1)); // one request, one run of the world's handler
	CHECK_EQ(states.size(), size_t(1)); // one answer
	CHECK_EQ(sleeps.size(), size_t(1));

	// The book every 5 s goes to every player (net::host_broadcast): the host player gets it once, a refusal in his copy.
	rest::StateMsg refused;
	refused.refused = rest::Refusal::Place;
	Writer b;
	rest::write_state(b, refused);
	h.host.s.broadcast(Lane::Reliable, Msg::RestState, b);
	h.update();
	REQUIRE(states.size() == size_t(2));
	CHECK(states[1].refused == rest::Refusal::Place);
	// ... and not when the broadcast leaves him out (a relay of his own report)
	h.host.s.broadcast(Lane::Reliable, Msg::RestState, b, kHostPeer);
	h.update();
	CHECK_EQ(states.size(), size_t(2));
}

// ============================================================================ checkpoints

TEST(t7_checkpoint_claim_of_the_host_player_through_the_link)
{
	HostWithLink h(37652);
	REQUIRE(h.start());
	std::vector<checkpoint::ClaimWhat> claims;
	std::vector<PeerId> claim_from;
	std::vector<checkpoint::StateMsg> answers;
	h.host.s.on(Msg::CheckpointClaim, [&](PeerId from, Reader& r) {
		checkpoint::ClaimWhat what = checkpoint::ClaimWhat::Tent;
		float p[3];
		CHECK(checkpoint::read_claim(r, what, p));
		claims.push_back(what);
		claim_from.push_back(from);
		// pack_for found no tent of his there: refused "far", to him alone (sources::refuse)
		Writer w;
		checkpoint::write_refusal(w, 0, what, checkpoint::Refusal::Far);
		h.server_sends(Msg::CheckpointState, w);
	});
	h.link.on(Msg::CheckpointState, [&](PeerId from, Reader& r) {
		CHECK_EQ(from, kHostPeer);
		checkpoint::StateMsg m;
		CHECK(checkpoint::read_state(r, m));
		answers.push_back(m);
	});
	const float at[3] = {10.f, 0.5f, -3.f};
	Writer w;
	checkpoint::write_claim(w, checkpoint::ClaimWhat::Pack, at);
	REQUIRE(h.player_sends(Msg::CheckpointClaim, w));
	h.update();
	REQUIRE(claims.size() == size_t(1));
	CHECK(claims[0] == checkpoint::ClaimWhat::Pack); // the host player's Fold is a pack-up claim like a client's
	CHECK_EQ(claim_from[0], kHostPeer);
	CHECK(answers.empty());
	h.update();
	REQUIRE(answers.size() == size_t(1));
	CHECK(answers[0].refused());
	CHECK_EQ(answers[0].character, uint16_t(0));
	CHECK(answers[0].reason == checkpoint::Refusal::Far);
	CHECK(answers[0].what == checkpoint::ClaimWhat::Pack);

	// A camp change with the group view on goes to everybody (flush_outbox): once to the host player.
	checkpoint::Record r;
	r.level = "l01_escape";
	r.pos[0] = 1.f;
	r.pos[1] = 2.f;
	r.pos[2] = 3.f;
	r.level_vertex = 7;
	r.game_vertex = 3;
	r.kind = checkpoint::Kind::Tent;
	r.source = 900;
	Writer s;
	checkpoint::write_state(s, 0, false, r);
	h.host.s.broadcast(Lane::Reliable, Msg::CheckpointState, s);
	h.update();
	h.update();
	REQUIRE(answers.size() == size_t(2));
	CHECK(!answers[1].refused());
	CHECK(answers[1].record.kind == checkpoint::Kind::Tent);
	CHECK_EQ(answers[1].record.source, uint16_t(900));
}

// ============================================================================ survival: down, dead, revived, new character

TEST(t7_survival_host_player_through_the_link)
{
	HostWithLink h(37653);
	REQUIRE(h.start());
	struct Report
	{
		PeerId from;
		uint16_t id;
		uint8_t life;
		uint16_t seq;
	};
	std::vector<Report> reports;
	std::vector<uint8_t> server_ops; // PlayerRevive ops the world server took from the host player
	std::vector<uint8_t> player_ops; // PlayerRevive ops the host player took from the world server
	int new_characters = 0;
	std::vector<death::Rules> rules;
	h.host.s.on(Msg::PlayerWounded, [&](PeerId from, Reader& r) {
		Report rep;
		rep.from = from;
		rep.id = r.u16();
		rep.life = r.u8();
		rep.seq = r.u16();
		r.u32();
		r.str();
		CHECK(r.ok());
		reports.push_back(rep);
		if (rep.life == 2) // Dead: the death mode decides (checkpoint): evacuated, the order goes to its owner
		{
			Writer w;
			w.u8(revive::OpEvacuate);
			w.u16(0);
			w.u16(rep.seq);
			w.u32(30000);
			h.server_sends(Msg::PlayerRevive, w);
		}
	});
	h.host.s.on(Msg::PlayerRevive, [&](PeerId from, Reader& r) {
		CHECK_EQ(from, kHostPeer);
		const uint8_t op = r.u8();
		server_ops.push_back(op);
		CHECK(revive::is_client_op(op)); // only requests come from a player
		// the revive went through: Done to the reviver (host_answer)
		revive::DoneMsg done;
		done.target = 501;
		done.seq = 3;
		Writer w;
		done.write(w);
		h.server_sends(Msg::PlayerRevive, w);
	});
	h.host.s.on(Msg::NewCharacter, [&](PeerId from, Reader&) {
		CHECK_EQ(from, kHostPeer);
		++new_characters;
	});
	h.link.on(Msg::PlayerRevive, [&](PeerId from, Reader& r) {
		CHECK_EQ(from, kHostPeer);
		player_ops.push_back(r.u8());
	});
	h.link.on(Msg::PlayerRules, [&](PeerId from, Reader& r) {
		CHECK_EQ(from, kHostPeer);
		death::Rules got;
		CHECK(got.read(r));
		rules.push_back(got);
	});

	// He bled out: his Dead report goes to the world server (send_my_state), which answers his owner with Evacuate.
	Writer dead;
	dead.u16(0);
	dead.u8(2);
	dead.u16(4);
	dead.u32(0);
	dead.str("Boss");
	REQUIRE(h.player_sends(Msg::PlayerWounded, dead));
	h.update();
	REQUIRE(reports.size() == size_t(1));
	CHECK_EQ(reports[0].from, kHostPeer);
	CHECK_EQ(int(reports[0].life), 2);
	CHECK_EQ(reports[0].seq, uint16_t(4));
	CHECK(player_ops.empty());
	h.update();
	CHECK(player_ops == (std::vector<uint8_t>{uint8_t(revive::OpEvacuate)}));

	// He revives a client: his Request goes to the world server, Done comes back.
	Writer req;
	req.u8(revive::OpRequest);
	req.u16(501);
	req.u16(3);
	req.u16(1200);
	REQUIRE(h.player_sends(Msg::PlayerRevive, req));
	h.update();
	CHECK(server_ops == (std::vector<uint8_t>{uint8_t(revive::OpRequest)}));
	h.update();
	CHECK(player_ops == (std::vector<uint8_t>{uint8_t(revive::OpEvacuate), uint8_t(revive::OpDone)}));

	// Hardcore, out of the run: his NewCharacter is a client's request (no payload).
	REQUIRE(h.player_sends(Msg::NewCharacter, Writer()));
	h.update();
	CHECK_EQ(new_characters, 1);

	// The rules every 5 s go to every player: the host player takes them like a client.
	death::Rules world;
	world.mode = death::Mode::Hardcore;
	world.bleedout_ms = 45000;
	Writer rw;
	world.write(rw);
	h.host.s.broadcast(Lane::Reliable, Msg::PlayerRules, rw);
	h.update();
	REQUIRE(rules.size() == size_t(1));
	CHECK(rules[0] == world);

	for (int i = 0; i < 5; ++i)
		h.update();
	CHECK_EQ(reports.size(), size_t(1)); // nothing ran twice
	CHECK_EQ(server_ops.size(), size_t(1));
	CHECK_EQ(player_ops.size(), size_t(2));
	CHECK_EQ(new_characters, 1);
	CHECK_EQ(rules.size(), size_t(1));
}

// ============================================================================ death markers

TEST(t7_death_marker_reaches_the_host_player_once)
{
	HostWithLink h(37654);
	REQUIRE(h.start());
	std::vector<death::Marker> markers;
	h.link.on(Msg::DeathMarker, [&](PeerId from, Reader& r) {
		CHECK_EQ(from, kHostPeer);
		death::Marker m;
		CHECK(death::read(r, m));
		markers.push_back(m);
	});
	death::Marker m;
	m.character = 0;
	m.object = 4100;
	m.drop = death::Drop::Corpse;
	Writer w;
	death::write(w, m);
	h.host.s.broadcast(Lane::Reliable, Msg::DeathMarker, w); // send_markers: net::host_broadcast
	CHECK(markers.empty());
	h.update();
	REQUIRE(markers.size() == size_t(1));
	CHECK_EQ(markers[0].object, uint16_t(4100));
	CHECK(markers[0].drop == death::Drop::Corpse);
	h.update();
	CHECK_EQ(markers.size(), size_t(1));
}

// ============================================================================ money

TEST(t7_money_transfer_of_the_host_player_through_the_link)
{
	HostWithLink h(37655);
	REQUIRE(h.start());
	std::vector<ledger::MoneyReq> reqs;
	std::vector<ledger::MoneyBalanceMsg> balances;
	h.host.s.on(Msg::ReqMoney, [&](PeerId from, Reader& r) {
		CHECK_EQ(from, kHostPeer);
		ledger::MoneyReq q;
		CHECK(ledger::read(r, q));
		reqs.push_back(q);
		// the transfer is refused by the session's rules: the answer carries the note (host_on_req -> send_balance)
		ledger::MoneyBalanceMsg m;
		m.balance = 5000;
		m.acked_seq = q.seq;
		m.note = ledger::note_refused(q, ledger::Verdict::TransfersOff);
		Writer w(ledger::kMoneyBalanceSize);
		ledger::write(w, m);
		h.server_sends(Msg::MoneyBalance, w);
	});
	h.link.on(Msg::MoneyBalance, [&](PeerId from, Reader& r) {
		CHECK_EQ(from, kHostPeer);
		ledger::MoneyBalanceMsg m;
		CHECK(ledger::read(r, m));
		balances.push_back(m);
	});
	const ledger::MoneyReq q{7, -300, ledger::Cause::Transfer, 2};
	Writer w(ledger::kMoneyReqSize);
	ledger::write(w, q);
	REQUIRE(h.player_sends(Msg::ReqMoney, w));
	h.update();
	REQUIRE(reqs.size() == size_t(1));
	CHECK(reqs[0].cause == ledger::Cause::Transfer);
	CHECK_EQ(reqs[0].delta, int32_t(-300));
	CHECK_EQ(reqs[0].ref, uint32_t(2));
	CHECK(balances.empty());
	h.update();
	REQUIRE(balances.size() == size_t(1));
	CHECK_EQ(balances[0].acked_seq, uint32_t(7));
	CHECK(balances[0].note.kind == ledger::NoteKind::Refused);
	CHECK(balances[0].note.verdict == ledger::Verdict::TransfersOff);
	CHECK_EQ(balances[0].note.peer, uint32_t(2));

	// A gift from a client to the host player: his balance and the "received" note, to him alone.
	ledger::MoneyBalanceMsg gift;
	gift.balance = 5300;
	gift.note = ledger::note_received(1, 300);
	Writer g(ledger::kMoneyBalanceSize);
	ledger::write(g, gift);
	h.server_sends(Msg::MoneyBalance, g);
	h.update();
	REQUIRE(balances.size() == size_t(2));
	CHECK(balances[1].note.kind == ledger::NoteKind::Received);
	CHECK_EQ(balances[1].note.amount, int32_t(300));
}

// ============================================================================ coop.sync requests

TEST(t7_sync_request_of_the_host_player_through_the_link)
{
	HostWithLink h(37656);
	REQUIRE(h.start());
	std::vector<syncnet::Request> taken;
	std::vector<syncnet::Result> results;
	h.host.s.on(Msg::SyncRequest, [&](PeerId from, Reader& r) {
		CHECK_EQ(from, kHostPeer);
		syncnet::Request q;
		CHECK(syncnet::read_request(r, q));
		taken.push_back(q);
		syncnet::Result a;
		a.id = q.id;
		a.ok = true;
		a.value = syncstore::make_string("done");
		Writer w;
		syncnet::write_result(w, a);
		h.server_sends(Msg::SyncResult, w);
	});
	h.link.on(Msg::SyncResult, [&](PeerId from, Reader& r) {
		CHECK_EQ(from, kHostPeer);
		syncnet::Result a;
		CHECK(syncnet::read_result(r, a));
		results.push_back(a);
	});
	syncnet::Request q;
	q.id = 41;
	q.name = "mod.buy";
	q.args = syncstore::make_number(3);
	Writer w;
	syncnet::write_request(w, q);
	REQUIRE(h.player_sends(Msg::SyncRequest, w));
	h.update();
	REQUIRE(taken.size() == size_t(1));
	CHECK(taken[0].name == "mod.buy");
	CHECK(results.empty());
	h.update();
	REQUIRE(results.size() == size_t(1));
	CHECK_EQ(results[0].id, uint32_t(41));
	CHECK(results[0].ok);
}

// ============================================================================ Lua events

TEST(t7_script_event_of_the_host_process_to_peer_0_through_the_link)
{
	// coop.send_event(name, payload, 0) in the host's process: the host player's event to his world server (menu.new_character)
	// and the world's to its host player (menu.char_offer) are one delivery to the one Lua state, with from = 0.
	HostWithLink h(37657);
	REQUIRE(h.start());
	std::vector<PeerId> from_seen;
	std::vector<std::string> names;
	h.host.s.on(Msg::ScriptEvent, [&](PeerId from, Reader& r) {
		r.u32(); // wire origin
		const int32_t target = r.i32();
		names.push_back(r.str());
		r.str();
		CHECK(r.ok());
		CHECK_EQ(target, int32_t(0));
		from_seen.push_back(from);
	});
	Writer w;
	w.u32(0);
	w.i32(0);
	w.str("menu.new_character");
	w.str("{faction=\"dolg\"}");
	REQUIRE(h.player_sends(Msg::ScriptEvent, w));
	h.update();
	CHECK(from_seen == (std::vector<PeerId>{kHostPeer}));
	CHECK(contains(names, "menu.new_character"));
	h.update();
	CHECK_EQ(from_seen.size(), size_t(1));
}

// ============================================================================ fix round 1: the host player's new life

TEST(t7r1_spectator_takes_any_respawn_as_his_new_life)
{
	// The only Respawn a spectator is sent is his new life (Ruling F3-7: out of the run nobody is respawned): the world
	// may name a fall it never heard of (its records start over with a world, reported_seq unknown) - he takes it anyway.
	using death::RespawnTake;
	CHECK(death::take_respawn(death::kLifeSpectating, 5, 5) == RespawnTake::NewLife);
	CHECK(death::take_respawn(death::kLifeSpectating, 5, 9) == RespawnTake::NewLife); // another fall named
	CHECK(death::take_respawn(death::kLifeSpectating, 5, death::kNewLifeSeq) == RespawnTake::NewLife);
	// a standing or dead owner: his fall only, and the new-life order (no fall) never moves him
	CHECK(death::take_respawn(death::kLifeDead, 5, 5) == RespawnTake::Respawn);
	CHECK(death::take_respawn(death::kLifeAlive, 5, 5) == RespawnTake::Respawn); // owed after a leave or a world change
	CHECK(death::take_respawn(death::kLifeDead, 5, 4) == RespawnTake::Stale);
	CHECK(death::take_respawn(death::kLifeAlive, 5, 6) == RespawnTake::Stale);
	CHECK(death::take_respawn(death::kLifeAlive, 5, death::kNewLifeSeq) == RespawnTake::Stale);
	CHECK(death::take_respawn(death::kLifeDead, 0, death::kNewLifeSeq) == RespawnTake::Stale);
	CHECK(death::take_respawn(death::kLifeWounded, 5, 5) == RespawnTake::Stale);
	CHECK(death::take_respawn(death::kLifeRespawning, 5, 5) == RespawnTake::Stale); // a duplicate while he stands up
}

TEST(t7r1_lost_new_life_order_is_sent_again)
{
	constexpr uint32_t kRetry = 10000;
	const uint8_t spect = death::kLifeSpectating;
	// The world gave him a new life (not out, no retirement) but he still reports Spectating: the order did not reach him.
	death::NewLife none; // the world's record of him starts over with a world: the order of the old one is unknown
	CHECK(death::new_life_lost(spect, false, false, none, 50000, kRetry)); // order lost across a reload -> healed
	death::NewLife sent;
	sent.sent = true;
	sent.at = 1000;
	// the Spectating report that crossed the order on its way: not again yet
	CHECK(!death::new_life_lost(spect, false, false, sent, 1500, kRetry));
	CHECK(!death::new_life_lost(spect, false, false, sent, 1000 + kRetry - 1, kRetry));
	CHECK(death::new_life_lost(spect, false, false, sent, 1000 + kRetry, kRetry)); // still a spectator: lost, again
	// nothing to heal: out of the run (he may ask himself), his retirement under way, or he is no spectator
	CHECK(!death::new_life_lost(spect, true, false, none, 50000, kRetry));
	CHECK(!death::new_life_lost(spect, false, true, none, 50000, kRetry));
	for (uint8_t life : {death::kLifeAlive, death::kLifeWounded, death::kLifeDead, death::kLifeRespawning})
		CHECK(!death::new_life_lost(life, false, false, none, 50000, kRetry)); // never a standing player
}

// ============================================================================ no direct branch next to the link

namespace
{
std::string coop_source(const char* file)
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	here.resize(slash == std::string::npos ? 0 : slash);
	const std::string path = (here.empty() ? std::string("tests") : here) + "/../engine/src/xrGame/coop/" + file;
	std::ifstream in(path, std::ios::binary);
	std::ostringstream all;
	all << in.rdbuf();
	return all.str();
}

// // and /* */ comments blanked (a comment may say what was there before).
std::string code_only(const std::string& src)
{
	std::string out = src;
	bool line = false, block = false, str = false;
	for (size_t i = 0; i < out.size(); ++i)
	{
		const char c = out[i];
		const char n = i + 1 < out.size() ? out[i + 1] : '\0';
		if (line)
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
			out[i] = ' ';
		}
		else if (c == '/' && n == '*')
		{
			block = true;
			out[i] = out[i + 1] = ' ';
			++i;
		}
		else if (c == '"')
			str = true;
	}
	return out;
}
} // namespace

TEST(t7_direct_host_branches_gone)
{
	// What the host's process did for its own player directly, next to the handlers of a remote client's message. With
	// the type on the link the same message comes from peer 0 and runs the handler: both would run (Review Focus 1).
	struct Banned
	{
		const char* file;
		const char* code;
		const char* what;
	};
	const Banned banned[] = {
		{"coop_survival.cpp", "host_on_state(0,", "the host's own life report applied without a message"},
		{"coop_survival.cpp", "host_on_revive_request(0,", "the host's own revive request applied directly"},
		{"coop_survival.cpp", "host_on_revive_begin(0,", "the host's own revive hold applied directly"},
		{"coop_survival.cpp", "host_on_revive_cancel(0,", "the host's own revive cancel applied directly"},
		{"coop_survival.cpp", "host_new_character(0)", "the host's own new character started directly"},
		{"coop_survival.cpp", "reply_to == kHostPeer", "an answer to the host applied directly"},
		{"coop_survival.cpp", "host_finish_own", "the host stood up at his arrival point by itself"},
		{"coop_rest.cpp", "host_request(0,", "the host's own lie-down taken without a message"},
		{"coop_rest.cpp", "tell_lua(g_host.group.entries()", "the host's Lua told the book directly, not its player's copy"},
		{"coop_checkpoint_sources.cpp", "host_claim_tent(0,", "the host's own tent claim taken without a message"},
		{"coop_checkpoint_sources.cpp", "packs up his tents with the stock tent bag", "the host player's pack-up refused"},
		{"coop_checkpoint_sources.cpp", "queue_callback(kRefusedCallback", "a claim refusal told to the host's Lua directly"},
		{"coop_checkpoints.cpp", "may_see(0, p.character", "the host's own camp change told to its Lua directly"},
		{"coop_money.cpp", "|| from == kHostPeer", "the host player's ReqMoney refused"},
		{"coop_money.cpp", "host_give(", "the host's transfer settled without a message"},
		{"coop_death.cpp", "fire_marker_callback(m.character, m.object", "the host's marker callback fired directly"},
		{"coop_sync_api.cpp", "h.from == kHostPeer", "the host's own coop.sync request answered without a message"},
	};
	for (const Banned& b : banned)
	{
		const std::string src = code_only(coop_source(b.file));
		if (src.size() < 1000)
		{
			t::report_failure(__FILE__, __LINE__, std::string("cannot read ") + b.file);
			continue;
		}
		if (src.find(b.code) != std::string::npos)
			t::report_failure(__FILE__, __LINE__, std::string(b.file) + ": '" + b.code + "' - " + b.what);
	}
}
