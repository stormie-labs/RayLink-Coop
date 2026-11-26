// R32 WP4 (W3 "Up", W2b refusal answers, W5 repair, §5, §8a A11): the map server's level journal (xrCoop/srv/coop_levels_journal.h).
// The batcher keeps a frame's facts in order and cuts them under 1 MiB; every op goes through a batch and back; a malformed batch is
// refused whole; the world remembers each bridge's last batch; the Ack carries the refusals and the id block; each refusal has its
// repair towards the world.
#include "test_util.h"

#include "coop_writer_rules.h"
#include "srv/coop_levels_accept.h"
#include "srv/coop_levels_journal.h"
#include "srv/coop_levels_keeper.h"
#include "srv/coop_levels_root_gen.h"

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <map>
#include <regex>
#include <set>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

using namespace coop;
using namespace coop::levels;
using Head = wire::LevelEntityHead;
namespace jr = coop::levels::journal;

namespace
{
jr::ObjectHead head(uint16_t id, uint32_t gen = 0) { return jr::ObjectHead{id, jr::section_crc("wpn_ak74"), gen}; }

jr::Entry destroy_of(uint16_t id, uint32_t gen = 0)
{
	Writer w;
	w.u16(id);
	jr::Entry e;
	REQUIRE(jr::object_entry(Head::Destroy, head(id, gen), w, e));
	return e;
}

jr::Entry parent_of(uint16_t item, uint16_t parent)
{
	Writer w;
	w.u16(item);
	w.u16(parent);
	const float p[3] = {1.f, 2.f, 3.f};
	w.vec3(p);
	jr::Entry e;
	REQUIRE(jr::object_entry(Head::Parent, head(item), w, e));
	return e;
}

jr::Entry spawn_of(uint16_t id)
{
	Writer w; // today's EntitySpawn layout starts with the id; its tail is its reader's
	w.u16(id);
	w.u16(0xffff);
	w.u8(1);
	jr::Entry e;
	REQUIRE(jr::object_entry(Head::Spawn, head(id), w, e));
	return e;
}

jr::Entry tent_of(uint16_t tent, uint16_t character)
{
	Writer w;
	w.u16(tent);
	w.u16(character);
	jr::Entry e;
	REQUIRE(jr::object_entry(Head::Tent, head(tent), w, e));
	return e;
}

jr::Entry member_of(uint8_t op, uint16_t squad, uint16_t member)
{
	jr::MemberBody b;
	b.squad = squad;
	b.member = member;
	jr::Entry e;
	REQUIRE(jr::body_entry(op, b, e));
	return e;
}

jr::Entry money_of(uint32_t peer, int64_t delta)
{
	Writer w;
	w.u32(peer);
	w.u64(uint64_t(delta));
	w.u8(1);
	jr::Entry e;
	e.op = Head::Money;
	e.body = w.data();
	return e;
}

jr::Entry carry_of(uint16_t part, uint16_t total, size_t bytes)
{
	jr::CarryBody b;
	b.part = part;
	b.total = total;
	b.blob.assign(bytes, uint8_t(part));
	jr::Entry e;
	REQUIRE(jr::body_entry(Head::Carry, b, e));
	return e;
}

// One entry of every op a journal carries, with a body its reader takes.
std::vector<jr::Entry> every_op()
{
	std::vector<jr::Entry> out;
	out.push_back(destroy_of(0x9001, 3));
	out.push_back(parent_of(0x9002, 0x9003));
	{
		Writer w;
		w.u16(0x9004);
		w.u16(0xffff);
		jr::Entry e;
		REQUIRE(jr::object_entry(Head::Died, head(0x9004), w, e));
		out.push_back(e);
	}
	{
		Writer w;
		w.u16(0x9005);
		w.u32(7);
		jr::Entry e;
		REQUIRE(jr::object_entry(Head::State, head(0x9005), w, e));
		out.push_back(e);
	}
	{
		jr::ItemFactsBody b;
		b.item = 0x9006;
		b.section = "medkit";
		b.blob = {1, 2, 3};
		b.source = jr::ItemFactsBody::Decider;
		Writer w;
		REQUIRE(b.write(w));
		jr::Entry e;
		REQUIRE(jr::object_entry(Head::Item, head(0x9006), w, e));
		out.push_back(e);
	}
	out.push_back(spawn_of(0x9007));
	out.push_back(money_of(3, -250));
	out.push_back(tent_of(0x9008, 0x10));
	{
		Writer w;
		w.u16(0x10);
		w.u8(1);
		jr::Entry e;
		REQUIRE(jr::object_entry(Head::Stash, head(0x10), w, e));
		out.push_back(e);
	}
	{
		wire::LevelLogicBody b;
		b.id = 0x9009;
		b.bytes = {9, 9};
		Writer w;
		REQUIRE(b.write(w));
		jr::Entry e;
		REQUIRE(jr::object_entry(Head::Logic, head(0x9009), w, e));
		out.push_back(e);
	}
	out.push_back(member_of(Head::Joined, 0x9100, 0x9101));
	out.push_back(member_of(Head::Left, 0x9100, 0x9102));
	{
		jr::InfoBody b;
		b.id = 0x9101;
		b.info = "companion_wait";
		jr::Entry e;
		REQUIRE(jr::body_entry(Head::Info, b, e));
		out.push_back(e);
	}
	{
		jr::AskBody b;
		b.what = jr::AskBody::Release;
		b.id = 0x1234;
		b.crc = jr::section_crc("phantom");
		jr::Entry e;
		REQUIRE(jr::body_entry(Head::Ask, b, e));
		out.push_back(e);
	}
	out.push_back(jr::id_ask_entry());
	out.push_back(carry_of(0, 1, 16));
	{
		jr::DoneBody b;
		b.origin = 0x10;
		b.op = 5;
		b.answer = "ok";
		jr::Entry e;
		REQUIRE(jr::body_entry(Head::Done, b, e));
		out.push_back(e);
	}
	{
		jr::FlushedBody b;
		b.round = 4;
		jr::Entry e;
		REQUIRE(jr::body_entry(Head::Flushed, b, e));
		out.push_back(e);
	}
	return out;
}

wire::LevelJournalMsg round_trip(const wire::LevelJournalMsg& m)
{
	Writer w;
	REQUIRE(m.write(w));
	Reader r(w.ptr(), w.size());
	wire::LevelJournalMsg back;
	REQUIRE(back.read(r));
	CHECK_EQ(r.remaining(), size_t(0));
	return back;
}
} // namespace

TEST(srv_journal_every_op_goes_through_a_batch_and_back)
{
	const std::vector<jr::Entry> all = every_op();
	std::vector<bool> seen(jr::kLastOp + 1, false);
	jr::Batcher b;
	for (const jr::Entry& e : all)
	{
		CHECK(b.add(e));
		seen[e.op] = true;
	}
	for (uint8_t op = 0; op <= jr::kLastOp; ++op)
		CHECK_EQ(bool(seen[op]), jr::known_op(op)); // every op a journal carries, and Report alone left out
	const std::vector<wire::LevelJournalMsg> out = b.take();
	REQUIRE(out.size() == 1);
	CHECK_EQ(out[0].seq, 1u);
	const wire::LevelJournalMsg back = round_trip(out[0]);
	CHECK_EQ(back.seq, 1u);
	CHECK(back.entries == all);
	CHECK(b.empty());
}

TEST(srv_journal_batcher_numbers_from_one_and_reset_starts_again)
{
	jr::Batcher b;
	CHECK(b.take().empty()); // nothing to send: no seq is used
	CHECK_EQ(b.last_seq(), 0u);
	b.add(destroy_of(0x9001));
	CHECK_EQ(b.take().at(0).seq, 1u);
	b.add(destroy_of(0x9002));
	CHECK_EQ(b.take().at(0).seq, 2u);
	CHECK_EQ(b.last_seq(), 2u);
	b.add(destroy_of(0x9003));
	b.reset(); // a new world: what was queued means nothing there
	CHECK(b.empty());
	b.add(destroy_of(0x9004));
	CHECK_EQ(b.take().at(0).seq, 1u);
}

TEST(srv_journal_batcher_refuses_an_entry_the_world_would_refuse_whole)
{
	jr::Batcher b;
	jr::Entry bad;
	bad.op = Head::Destroy;
	bad.body = {1, 2, 3}; // no head
	CHECK(!b.add(bad));
	jr::Entry report;
	report.op = Head::Report; // no journal op
	CHECK(!b.add(report));
	CHECK_EQ(b.dropped(), 2u);
	CHECK(b.empty());
}

// A11: a big frame (a surge, a carry of 2.4 MiB) goes as several batches under 1 MiB, in order, numbered one after another.
TEST(srv_journal_a_big_frame_is_cut_under_one_mib_in_order)
{
	jr::Batcher b;
	std::vector<jr::Entry> sent;
	for (uint16_t i = 0; i < 40; ++i)
	{
		sent.push_back(carry_of(i, 40, jr::CarryBody::kMaxPart));
		sent.push_back(destroy_of(uint16_t(0x9000 + i)));
	}
	for (const jr::Entry& e : sent)
		REQUIRE(b.add(e));
	const std::vector<wire::LevelJournalMsg> out = b.take();
	REQUIRE(out.size() >= 3);
	std::vector<jr::Entry> got;
	for (size_t i = 0; i < out.size(); ++i)
	{
		CHECK_EQ(out[i].seq, uint32_t(i + 1));
		CHECK(out[i].wire_size() <= jr::kMaxSendBytes);
		CHECK(out[i].wire_size() < 1024u * 1024u);
		const wire::LevelJournalMsg back = round_trip(out[i]);
		got.insert(got.end(), back.entries.begin(), back.entries.end());
	}
	CHECK(got == sent); // the order of the facts never changes across the cut
}

// Addendum P1: a placement is a Spawn of the object, the item's Destroy and the Tent report of one frame: they go in one batch, in
// that order, and the world reads that batch whole or not at all.
TEST(srv_journal_a_placement_goes_in_one_batch)
{
	jr::Batcher b;
	b.add(spawn_of(0x9010));
	b.add(destroy_of(0x9011));
	b.add(tent_of(0x9010, 0x20));
	const std::vector<wire::LevelJournalMsg> out = b.take();
	REQUIRE(out.size() == 1);
	REQUIRE(out[0].entries.size() == 3);
	CHECK_EQ(out[0].entries[0].op, uint8_t(Head::Spawn));
	CHECK_EQ(out[0].entries[1].op, uint8_t(Head::Destroy));
	CHECK_EQ(out[0].entries[2].op, uint8_t(Head::Tent));
	// one entry cut short: the world refuses the batch whole, nothing of the placement is applied
	Writer w;
	REQUIRE(out[0].write(w));
	std::vector<uint8_t> bytes = w.data();
	bytes.pop_back();
	Reader r(bytes.data(), bytes.size());
	wire::LevelJournalMsg back;
	back.seq = 5;
	back.entries.push_back(jr::Entry());
	CHECK(!back.read(r));
	CHECK_EQ(back.seq, 0u);
	CHECK(back.entries.empty());
}

TEST(srv_journal_a_malformed_entry_refuses_the_batch_whole)
{
	std::vector<jr::Entry> all = every_op();
	Writer w;
	w.u32(9);
	w.u16(uint16_t(all.size()));
	for (size_t i = 0; i < all.size(); ++i)
	{
		jr::Entry e = all[i];
		if (i == all.size() / 2)
			e.body.resize(1); // a body its op does not take
		w.u8(e.op);
		w.varu(e.body.size());
		w.bytes(e.body.data(), e.body.size());
	}
	Reader r(w.ptr(), w.size());
	wire::LevelJournalMsg m;
	CHECK(!m.read(r));
	CHECK_EQ(m.seq, 0u);
	CHECK(m.entries.empty());
}

TEST(srv_journal_receiver_applies_each_batch_once)
{
	jr::Receiver rx;
	CHECK(rx.look(258, 1) == jr::Receiver::Seen::Next);
	rx.applied(258, 1);
	CHECK(rx.look(258, 1) == jr::Receiver::Seen::Repeat);
	CHECK(rx.look(258, 2) == jr::Receiver::Seen::Next);
	CHECK(rx.look(258, 4) == jr::Receiver::Seen::Gap);
	rx.applied(258, 4);
	CHECK_EQ(rx.last(258), 4u);
	CHECK(rx.look(258, 3) == jr::Receiver::Seen::Repeat);
	rx.applied(258, 2); // never backwards
	CHECK_EQ(rx.last(258), 4u);
	CHECK(rx.look(257, 1) == jr::Receiver::Seen::Next); // bridges apart
	rx.forget(258); // gone: its next connection numbers from 1
	CHECK(rx.look(258, 1) == jr::Receiver::Seen::Next);
}

TEST(srv_journal_ack_carries_refusals_and_the_block)
{
	using Ack = wire::LevelJournalAckMsg;
	std::vector<Ack> plain = jr::acks_of(7, {}, false, 0, 0);
	REQUIRE(plain.size() == 1);
	CHECK_EQ(plain[0].upto, 7u);
	CHECK(plain[0].refusals.empty());
	CHECK(!plain[0].has_block);

	std::vector<Ack::Refusal> rows;
	for (uint32_t i = 0; i < 300; ++i)
		rows.push_back({7, Head::Destroy, uint16_t(0x9000 + i), jr::Identity});
	const std::vector<Ack> acks = jr::acks_of(7, rows, true, 0x8C00, kIdBlockSize);
	REQUIRE(acks.size() == 2);
	CHECK_EQ(acks[0].refusals.size(), Ack::kMaxRefusals);
	CHECK_EQ(acks[1].refusals.size(), size_t(300 - Ack::kMaxRefusals));
	CHECK(!acks[0].has_block);
	CHECK(acks[1].has_block);
	std::vector<Ack::Refusal> back_rows;
	for (const Ack& a : acks)
	{
		CHECK_EQ(a.upto, 7u);
		Writer w;
		REQUIRE(a.write(w));
		Reader r(w.ptr(), w.size());
		Ack back;
		REQUIRE(back.read(r));
		CHECK_EQ(r.remaining(), size_t(0));
		back_rows.insert(back_rows.end(), back.refusals.begin(), back.refusals.end());
		if (back.has_block)
		{
			CHECK_EQ(back.first, uint16_t(0x8C00));
			CHECK_EQ(back.count, kIdBlockSize);
		}
	}
	REQUIRE(back_rows.size() == rows.size());
	for (size_t i = 0; i < rows.size(); ++i)
		CHECK_EQ(back_rows[i].id, rows[i].id);
	// a block that is no block is left out, never sent broken
	CHECK(!jr::acks_of(7, {}, true, 0xFFF0, 0x100).back().has_block);
}

TEST(srv_journal_a_refusal_names_its_object)
{
	CHECK_EQ(jr::refused_id(destroy_of(0x9001)), uint16_t(0x9001));
	CHECK_EQ(jr::refused_id(member_of(Head::Joined, 0x9100, 0x9101)), uint16_t(0x9101)); // the member, as host_apply_fact names it
	CHECK_EQ(jr::refused_id(money_of(3, 10)), wire::kNoObject);
	CHECK_EQ(jr::refused_id(jr::id_ask_entry()), wire::kNoObject);
	for (const jr::Entry& e : every_op())
		if (e.op == Head::Info)
			CHECK_EQ(jr::refused_id(e), uint16_t(0x9101));
		else if (e.op == Head::Ask)
			CHECK_EQ(jr::refused_id(e), uint16_t(0x1234));
}

// W2b, W5: the map server repairs towards the world. A create the world refused is released here (its id kept); a change or a removal
// refused because the copy is wrong about the object is fetched; the world's own rule, a body report, a deal, an ask are no word about
// the copy.
TEST(srv_journal_each_refusal_has_its_repair)
{
	using jr::Repair;
	for (uint8_t why = 1; why <= jr::kLastWhy; ++why)
		CHECK(jr::repair_of(Head::Spawn, why) == Repair::ReleaseKeepId);
	for (const uint8_t op : {Head::Destroy, Head::Parent, Head::Died, Head::Item, Head::Tent, Head::Stash, Head::Logic, Head::Joined,
	         Head::Left, Head::Info})
	{
		CHECK(jr::repair_of(op, jr::NotWriter) == Repair::Fetch);
		CHECK(jr::repair_of(op, jr::Identity) == Repair::Fetch);
		CHECK(jr::repair_of(op, jr::PastFence) == Repair::Fetch);
		CHECK(jr::repair_of(op, jr::Unknown) == Repair::Fetch);
		CHECK(jr::repair_of(op, jr::Refused) == Repair::None);
		CHECK(jr::repair_of(op, jr::Malformed) == Repair::None);
		CHECK(jr::repair_of(op, jr::Ghost) == Repair::None);
	}
	for (const uint8_t op : {Head::State, Head::Money, Head::Ask, Head::IdAsk, Head::Carry, Head::Done, Head::Flushed})
		for (uint8_t why = 1; why <= jr::kLastWhy; ++why)
			CHECK(jr::repair_of(op, why) == Repair::None);
}

// ---------------------------------------------------------------- review WP4 #1, #2: the head names the root the world still sees

// HeldMemory: a Parent hook comes after the move; the old holder is read from the last frame's snapshot of the held creatures'
// children, or from a move a hook said since. A member's squad is read from the snapshot of the held squads.
TEST(srv_journal_held_memory_knows_where_things_stood)
{
	jr::HeldMemory m;
	m.begin();
	m.child(0x9301, 0x9101); // a gun in an NPC of a held squad
	m.member(0x9101, 0x9100);
	m.member(0x9201, 0x9200);
	CHECK_EQ(m.squad_before(0x9101), uint16_t(0x9100));
	CHECK_EQ(m.squad_before(0x9201), uint16_t(0x9200));
	CHECK_EQ(m.squad_before(0x9999), wire::kNoObject);

	const jr::ParentBefore reject = m.moved(0x9301, wire::kNoObject); // dropped: it was in the NPC
	CHECK(reject.known);
	CHECK_EQ(reject.parent, uint16_t(0x9101));
	const jr::ParentBefore take = m.moved(0x9301, 0x0010); // taken by a player: it lay on the ground (the move just said)
	CHECK(take.known);
	CHECK_EQ(take.parent, wire::kNoObject);
	const jr::ParentBefore loot = m.moved(0x9303, 0x9102); // ground loot no held creature had: not known
	CHECK(!loot.known);
	const jr::ParentBefore again = m.moved(0x9303, wire::kNoObject); // the move since counts
	CHECK(again.known);
	CHECK_EQ(again.parent, uint16_t(0x9102));

	// a squad that went offline rejected the gun and took it back without a hook (add_offline_impl): its next reject still comes
	// from that NPC, not from the ground
	m.child(0x9306, 0x9102);
	CHECK_EQ(m.moved(0x9306, wire::kNoObject).parent, uint16_t(0x9102));
	const jr::ParentBefore stale = m.moved(0x9306, wire::kNoObject);
	CHECK(stale.known);
	CHECK_EQ(stale.parent, uint16_t(0x9102));
	CHECK_EQ(m.moved(0x9306, 0x0010).parent, wire::kNoObject); // a take: from the ground
	m.begin(); // the next frame: the snapshot again, the moves of the last one are in it
	CHECK_EQ(m.children(), size_t(0));
	CHECK(!m.moved(0x9301, 0x9101).known);
}

// creature_place: a Died or a Destroy goes before the Left the member hook queued for that creature, and names that squad.
TEST(srv_journal_a_dead_member_goes_before_its_left)
{
	struct Up
	{
		uint8_t op;
		uint16_t a;
		uint16_t b;
	};
	std::vector<Up> ups = {{Head::Parent, 0x9301, 0xffff}, {Head::Left, 0x9100, 0x9101}, {Head::Parent, 0x9302, 0x9102}};
	jr::CreaturePlace p = jr::creature_place(ups, 0x9101, wire::kNoObject, wire::kNoObject);
	CHECK_EQ(p.at, size_t(1));
	CHECK(p.before_left);
	CHECK_EQ(p.squad, uint16_t(0x9100));
	// in a squad now: the end, that squad
	p = jr::creature_place(ups, 0x9102, 0x9100, wire::kNoObject);
	CHECK_EQ(p.at, ups.size());
	CHECK(!p.before_left);
	CHECK_EQ(p.squad, uint16_t(0x9100));
	// no membership up this frame (no member hook): the end, the squad of the snapshot
	p = jr::creature_place(ups, 0x9201, wire::kNoObject, 0x9200);
	CHECK_EQ(p.at, ups.size());
	CHECK_EQ(p.squad, uint16_t(0x9200));
	// left one squad, joined another, left that one: the last Left counts
	ups.push_back({Head::Joined, 0x9200, 0x9101});
	ups.push_back({Head::Left, 0x9200, 0x9101});
	p = jr::creature_place(ups, 0x9101, wire::kNoObject, 0x9100);
	CHECK_EQ(p.at, ups.size() - 1);
	CHECK_EQ(p.squad, uint16_t(0x9200));
	// a lone creature: nothing
	p = jr::creature_place(ups, 0x9500, wire::kNoObject, wire::kNoObject);
	CHECK_EQ(p.squad, wire::kNoObject);
	CHECK(!p.before_left);
}

// ParentNet: one Parent of an object per flush, from where it stood before its first move to where it stands now.
TEST(srv_journal_parent_net_sends_one_move_per_flush)
{
	const jr::ParentBefore in_npc{true, 0x9101}, ground{true, wire::kNoObject}, unknown{};
	jr::ParentNet net;
	CHECK(net.send(0x9301, in_npc, 0x0010)); // NPC -> player: sent
	CHECK(!net.send(0x9301, ground, 0x0010)); // its take: left out, the first one put it there
	CHECK(!net.send(0x9302, in_npc, 0x9101)); // back where it stood (offline: rejected and taken back silently): nothing changed
	CHECK(!net.send(0x9302, ground, 0x9101)); // ... and its later hooks too
	CHECK(net.send(0x9303, unknown, wire::kNoObject)); // from a box no held creature had: sent (its old root names gen 0)
	net.spawned(0x9304);
	CHECK(!net.send(0x9304, unknown, 0x9102)); // its Spawn is written where it stands now
	net.unborn(0x9305);
	CHECK(net.unborn_here(0x9305));
	CHECK(!net.send(0x9305, unknown, 0x9102)); // made and gone: the world never hears of it
	CHECK_EQ(net.unchanged(), uint32_t(1)); // the departure flood (2026-11-26): only 0x9302 was left out for standing where it stood
}

// The departure flood (2026-11-26): the snapshot lists the children of the characters of the level's players too; the reject of his
// departure (switch_offline) finds the character there, and the flush leaves out the item taken back into it without a hook.
TEST(srv_journal_held_memory_knows_a_players_items)
{
	constexpr uint16_t kHim = 0x0010, kPistol = 0x9310, kAmmo = 0x9311;
	jr::HeldMemory m;
	m.begin();
	m.child(kPistol, kHim);
	m.child(kAmmo, kHim);
	CHECK_EQ(m.children(), size_t(2));
	CHECK_EQ(m.members(), size_t(0)); // no squad of his: squad_before is not touched
	const jr::ParentBefore reject = m.moved(kPistol, wire::kNoObject);
	CHECK(reject.known);
	CHECK_EQ(reject.parent, kHim);
	jr::ParentNet net;
	CHECK(!net.send(kPistol, reject, kHim)); // back in him at the flush (add_offline_impl): nothing goes up
	CHECK(!net.send(kPistol, jr::ParentBefore{true, wire::kNoObject}, kHim)); // ... nor any later hook of it in the flush
	CHECK(net.send(kAmmo, m.moved(kAmmo, 0x9400), 0x9400)); // a real move out of him in the same flush: sent
	CHECK_EQ(net.unchanged(), uint32_t(1));
}

namespace
{
namespace w = coop::writer;
namespace acc = coop::levels::accept;

constexpr uint16_t kNo = wire::kNoObject;
constexpr uint16_t kMap = 5; // the map the map server leads
constexpr coop::PeerId kMk = 101; // its bridge on the world server
const w::Process kWorldServer{w::ProcessKind::World, w::kNoLevel, coop::kHostPeer};

// A registry, the world's or the map server's copy (one numbering: join::to_host is the identity here).
struct Obj
{
	std::string section;
	uint16_t parent = kNo;
	uint16_t squad = kNo; // a creature's squad (m_group_id)
	std::set<uint16_t> members; // a squad's
	std::vector<uint16_t> children;
	bool creature = false, is_squad = false, character = false, alive = true;
};

struct Registry
{
	std::map<uint16_t, Obj> objs;

	Obj* get(uint16_t id)
	{
		const auto it = objs.find(id);
		return it == objs.end() ? nullptr : &it->second;
	}
	uint16_t parent_of(uint16_t id)
	{
		const Obj* o = get(id);
		return o && o->parent != kNo ? o->parent : w::kNoId;
	}
	uint16_t squad_of(uint16_t id)
	{
		const Obj* o = get(id);
		return o && o->creature && o->squad != kNo ? o->squad : w::kNoId;
	}
	// As coop_writer.cpp root_facts_of: a squad, a living creature in no squad: a unit; a character; anything else on the map: a
	// resident.
	w::RootFacts root(uint16_t id)
	{
		w::RootFacts f{w::RootKind::None, id, w::kNoLevel};
		if (!get(id))
			return f;
		f.root = w::root_of(id, [this](uint16_t i) { return parent_of(i); }, [this](uint16_t i) { return squad_of(i); });
		const Obj* r = get(f.root);
		if (!r)
			return f;
		f.level = kMap;
		if (r->character)
			f.kind = w::RootKind::Character;
		else if (r->is_squad || (r->creature && r->alive))
			f.kind = w::RootKind::Unit;
		else
			f.kind = w::RootKind::Resident;
		return f;
	}
	void attach(uint16_t item, uint16_t parent)
	{
		Obj* o = get(item);
		REQUIRE(o != nullptr);
		if (o->parent != kNo)
		{
			std::vector<uint16_t>& c = get(o->parent)->children;
			c.erase(std::remove(c.begin(), c.end(), item), c.end());
		}
		o->parent = parent;
		if (parent != kNo)
			get(parent)->children.push_back(item);
	}
	void leave(uint16_t member)
	{
		Obj* m = get(member);
		if (m && m->squad != kNo)
		{
			get(m->squad)->members.erase(member);
			m->squad = kNo;
		}
	}
	void join(uint16_t squad, uint16_t member)
	{
		leave(member);
		get(squad)->members.insert(member);
		get(member)->squad = squad;
	}
};

uint16_t crc_of(const Obj& o) { return jr::section_crc(o.section.c_str()); }

// The world server: its registry, the units its keeper has away at the map server (unit -> gen), and its acceptance of each entry
// filled as srv/coop_levels_alife.cpp host_apply_fact fills it (root_seen, same_as, the writer of the old and the new root).
struct World
{
	Registry reg;
	std::map<uint16_t, uint32_t> held;
	std::vector<uint8_t> refused;
	uint32_t taken = 0;
	uint32_t repeats = 0; // taken, and nothing changed (accept::Verdict::repeat)
	// The departure flood (2026-11-26): characters whose player left (host_park_proxy, host_rejoin_peer): played_by gives nobody, so
	// world_seat gives no map and the world writes them and their items
	std::set<uint16_t> parked;
	bool unchanged_guard = true; // false: the acceptance as it was before the fix (no accept::unchanged_parent)

	w::Writer writer_of(const w::RootFacts& r)
	{
		w::Seat s;
		if (r.kind == w::RootKind::Unit)
		{
			if (held.count(r.root))
			{
				s.hold = w::Hold::Held;
				s.holder = kMk;
				s.holder_level = kMap;
			}
		}
		else if (r.kind != w::RootKind::Character || !parked.count(r.root))
			s.map = w::MapLead{w::Lead::Leads, kMk};
		return w::writer_of(r, kWorldServer, s);
	}
	// same_as: the hold of the root by the sender, whatever the root is now (levels::root_gen, Р68-3)
	uint32_t gen_here(const w::RootFacts& r) const
	{
		const auto it = held.find(r.root);
		return root_gen(r.kind, it != held.end() ? it->second : 0);
	}

	void apply(const jr::Entry& e)
	{
		acc::Facts f;
		f.op = e.op;
		f.sender = kMk;
		f.sender_level = kMap;
		if (e.op == Head::Joined || e.op == Head::Left)
		{
			coop::Reader r(e.body.data(), e.body.size());
			jr::MemberBody b;
			REQUIRE(jr::reads_whole(r, b));
			f.exists = reg.get(b.squad) && reg.get(b.member);
			if (f.exists)
			{
				if (e.op == Head::Joined)
				{
					f.writer = writer_of(reg.root(b.member));
					f.two_roots = true;
					f.writer_new = writer_of(reg.root(b.squad));
				}
				else
					f.writer = writer_of(reg.root(b.squad));
			}
			const acc::Verdict v = acc::accepts(f);
			if (!v.ok)
			{
				refused.push_back(v.why);
				return;
			}
			++taken;
			if (e.op == Head::Joined)
				reg.join(b.squad, b.member);
			else
				reg.leave(b.member);
			return;
		}
		jr::ObjectHead h;
		REQUIRE(jr::object_of(e, h));
		coop::Reader lr = jr::layout_of(e);
		lr.u16(); // the id again
		if (e.op == Head::Spawn)
		{
			const uint16_t parent = lr.u16();
			f.id_in_slice = true;
			f.exists = reg.get(h.id) != nullptr;
			if (parent != kNo)
				f.writer = writer_of(reg.root(parent));
			else
			{
				// fix A2: a root-less Spawn on the sender's map is the sender's while it leads that map (here it does)
				f.rootless = true;
				f.spawn_level = kMap;
				f.writer = writer_of(w::RootFacts{w::RootKind::Resident, h.id, kMap});
				f.sender_leads = f.writer == w::other(kMk);
			}
			const acc::Verdict v = acc::accepts(f);
			if (!v.ok)
			{
				refused.push_back(v.why);
				return;
			}
			++taken;
			Obj o;
			o.section = "spawned";
			reg.objs[h.id] = o;
			if (parent != kNo)
				reg.attach(h.id, parent);
			return;
		}
		Obj* o = reg.get(h.id);
		f.exists = o != nullptr;
		if (o)
		{
			const w::RootFacts r = reg.root(h.id);
			f.writer = writer_of(r);
			f.same = acc::identity(crc_of(*o), h.crc, gen_here(r), h.gen, 0);
		}
		uint16_t parent = kNo;
		if (e.op == Head::Parent)
		{
			parent = lr.u16();
			f.two_roots = true;
			f.writer_new = parent != kNo ? writer_of(reg.root(parent)) : w::other(kMk);
			f.unchanged = unchanged_guard && o && acc::unchanged_parent(o->parent, parent); // as coop_levels_alife.cpp fills it
		}
		const acc::Verdict v = acc::accepts(f);
		if (!v.ok)
		{
			refused.push_back(v.why);
			return;
		}
		++taken;
		if (v.repeat)
		{
			++repeats;
			return;
		}
		if (e.op == Head::Parent)
			reg.attach(h.id, parent);
		else if (e.op == Head::Died)
		{
			o->alive = false;
			reg.leave(h.id); // the world's own death chain: remove_npc -> unregister_member
		}
	}
	void apply_all(const std::vector<jr::Entry>& es)
	{
		for (const jr::Entry& e : es)
			apply(e);
	}
};

// The map server: its copy, the units it holds (unit -> gen), and the hooks and the flush of srv/coop_levels_xfer.cpp (up_parent,
// up_died, client_flush_up, client_remember_held) over the same pure parts.
struct MapServer
{
	struct Up
	{
		uint8_t op;
		uint16_t a;
		uint16_t b;
		jr::ObjectHead head;
		jr::ParentBefore before;
	};

	Registry reg;
	std::map<uint16_t, uint32_t> held;
	std::set<uint16_t> players; // the characters its players play here (mapserver::trunk_peers().on(): the departure flood fix)
	jr::HeldMemory memory;
	std::vector<Up> ups;
	bool member_hook = false; // WP5's hook in unregister_member: a Left up from the stock death chain
	bool registry_guard = true; // false: up_parent as it was before journal::journals_parent (no look at the registry)
	// Items that cannot be saved (a bolt of a player's belt, CSE_ALifeItemBolt): the stock switch offline releases them instead of
	// taking them back; their Parent "put down" and their Destroy follow
	std::set<uint16_t> unsaveable;
	bool departure_guard = true; // false: client_flush_up as it was before journal::journals_move_out_of_character
	std::set<uint16_t> departed; // g.departed: left out with a departed character, their Destroy too

	uint32_t gen(uint16_t unit) const
	{
		const auto it = held.find(unit);
		return it == held.end() ? 0 : it->second;
	}
	// held_gen_of: the root and its kind as the world reads them (root_facts_of: up the holders, then a creature's squad), and the
	// hold of that root (levels::root_gen, Р68-3)
	uint32_t held_gen_of(uint16_t id)
	{
		const w::RootFacts r = reg.root(id);
		return root_gen(r.kind, gen(r.root));
	}
	jr::ObjectHead head_of(uint16_t id) { return jr::ObjectHead{id, crc_of(*reg.get(id)), held_gen_of(id)}; }

	void remember()
	{
		memory.begin();
		for (const auto& unit : held)
		{
			Obj* u = reg.get(unit.first);
			if (!u)
				continue;
			const auto children_of = [&](uint16_t holder) {
				for (const uint16_t c : reg.get(holder)->children)
					memory.child(c, holder);
			};
			if (u->is_squad)
				for (const uint16_t m : u->members)
				{
					memory.member(m, unit.first);
					children_of(m);
				}
			else if (u->creature)
				children_of(unit.first);
		}
		for (const uint16_t c : players) // the departure flood (2026-11-26): and the children of its players' characters
			if (const Obj* o = reg.get(c))
				for (const uint16_t child : o->children)
					memory.child(child, c);
	}

	// A player leaves this level (quits, drops, takes an exit): his virtual peer leaves the trunk first (server_on_map), then
	// join::on_peer_left -> take_offline switches his character offline: Perform_destroy rejects each item with a hook,
	// add_offline_impl takes each back without one. The snapshot of the last frame end is still the one the hooks read.
	void take_offline(uint16_t character)
	{
		players.erase(character);
		const std::vector<uint16_t> items = reg.get(character)->children;
		for (const uint16_t item : items)
		{
			reg.attach(item, kNo);
			parent_hook(item, kNo);
			if (unsaveable.count(item))
			{
				ups.push_back(Up{Head::Destroy, item, kNo, head_of(item), {}}); // xfer_on_released: the head now, on the ground
				reg.objs.erase(item);
				continue;
			}
			reg.attach(item, character);
		}
	}

	// up_parent: `reg` is this map server's ALife registry; an entity outside it (its id only in a holder's children, as xrServer lists
	// it) is left out under the guard (journal::journals_parent); head_before_move gives it no section and gen 0
	void parent_hook(uint16_t item, uint16_t new_parent)
	{
		const Obj* o = reg.get(item);
		if (registry_guard && !jr::journals_parent(o != nullptr, false))
			return;
		const jr::ParentBefore before = memory.moved(item, new_parent);
		jr::ObjectHead h{item, o ? crc_of(*o) : uint16_t(0), 0};
		if (before.known && o)
			h.gen = before.parent == kNo ? gen(item) : held_gen_of(before.parent);
		ups.push_back(Up{Head::Parent, item, new_parent, h, before});
	}
	// An xrServer entity the registry never takes, in its holder's children (Process_spawn lists it there): no Spawn hook, no up. The
	// bolt CInventoryOwner::spawn_supplies gives an NPC that comes online here (CALifeSimulatorBase::create skips what cannot be saved),
	// a grenade's copy in the hand (spawn_fake_missile; game_sv_Single::OnCreate leaves an item held by an item outside).
	void server_child(uint16_t holder, uint16_t child) { reg.get(holder)->children.push_back(child); }
	// CALifeSwitchManager::remove_online of an NPC: Perform_destroy rejects each child with a hook; a child of the registry is taken
	// back without one (add_offline_impl), one outside it is destroyed with no release (no Released hook).
	void npc_offline(uint16_t npc)
	{
		const std::vector<uint16_t> children = reg.get(npc)->children;
		for (const uint16_t child : children)
		{
			std::vector<uint16_t>& c = reg.get(npc)->children;
			c.erase(std::remove(c.begin(), c.end(), child), c.end());
			if (Obj* o = reg.get(child))
				o->parent = kNo;
			parent_hook(child, kNo);
			if (reg.get(child))
				reg.attach(child, npc);
		}
	}
	// A grenade's copy in the hand (spawn_fake_missile: an xrServer child of the grenade, outside the registry) is thrown:
	// game_sv_Single::OnDetach registers it (its Spawn hook), then the reject puts it down (its Parent hook).
	void throw_copy(uint16_t grenade, uint16_t copy)
	{
		std::vector<uint16_t>& c = reg.get(grenade)->children;
		c.erase(std::remove(c.begin(), c.end(), copy), c.end());
		spawn(copy, kNo);
		parent_hook(copy, kNo);
	}
	// The stock move: a reject from the old holder, then a take by the new one, each with its hook after the change.
	void move(uint16_t item, uint16_t to)
	{
		if (reg.get(item)->parent != kNo)
		{
			reg.attach(item, kNo);
			parent_hook(item, kNo);
		}
		if (to != kNo)
		{
			reg.attach(item, to);
			parent_hook(item, to);
		}
	}
	void die(uint16_t victim)
	{
		Obj* v = reg.get(victim);
		v->alive = false;
		if (v->squad != kNo) // game->on_death runs the stock death chain before events::host_on_death
		{
			const uint16_t squad = v->squad;
			reg.leave(victim);
			if (member_hook)
				ups.push_back(Up{Head::Left, squad, victim, {}, {}});
		}
		Up u{Head::Died, victim, kNo, head_of(victim), {}};
		const jr::CreaturePlace p = jr::creature_place(ups, victim, v->squad, memory.squad_before(victim));
		if (p.squad != kNo)
			u.head.gen = gen(p.squad);
		ups.insert(ups.begin() + ptrdiff_t(p.at), u);
	}
	void spawn(uint16_t id, uint16_t parent)
	{
		Obj o;
		o.section = "spawned";
		reg.objs[id] = o;
		if (parent != kNo)
			reg.attach(id, parent);
		ups.push_back(Up{Head::Spawn, id, kNo, head_of(id), {}});
	}

	std::vector<jr::Entry> flush()
	{
		std::vector<jr::Entry> out;
		jr::ParentNet net;
		const auto object = [&](uint8_t op, const jr::ObjectHead& h, const coop::Writer& layout) {
			jr::Entry e;
			REQUIRE(jr::object_entry(op, h, layout, e));
			out.push_back(e);
		};
		for (const Up& u : ups)
		{
			const Obj* e = reg.get(u.a);
			coop::Writer w;
			switch (u.op)
			{
			case Head::Parent:
			{
				const uint16_t holder = e ? e->parent : u.b;
				if (!net.send(u.a, u.before, holder))
					break;
				const Obj* from = u.before.known && u.before.parent != kNo ? reg.get(u.before.parent) : nullptr;
				const bool from_character = from && from->character;
				if (departure_guard && !jr::journals_move_out_of_character(from_character, players.count(u.before.parent) != 0))
				{
					departed.insert(u.a);
					break;
				}
				w.u16(u.a);
				w.u16(holder);
				const float p[3] = {0.f, 0.f, 0.f};
				w.vec3(p);
				object(Head::Parent, u.head, w);
				break;
			}
			case Head::Died:
				w.u16(u.a);
				w.u16(kNo);
				object(Head::Died, u.head, w);
				break;
			case Head::Destroy:
				if (departure_guard && departed.erase(u.a))
					break;
				w.u16(u.a);
				object(Head::Destroy, u.head, w);
				break;
			case Head::Spawn:
				if (!e)
				{
					net.unborn(u.a);
					break;
				}
				net.spawned(u.a);
				w.u16(u.a);
				w.u16(e->parent);
				w.u8(1);
				object(Head::Spawn, head_of(u.a), w);
				break;
			case Head::Joined:
			case Head::Left:
			{
				jr::MemberBody b;
				b.squad = u.a;
				b.member = u.b;
				jr::Entry je;
				REQUIRE(jr::body_entry(u.op, b, je));
				out.push_back(je);
				break;
			}
			default: break;
			}
		}
		ups.clear();
		remember(); // the end of the frame
		return out;
	}
};

constexpr uint16_t kS = 0x9100, kN1 = 0x9101, kN2 = 0x9102; // squad S (held, gen 3) and its NPCs
constexpr uint16_t kT = 0x9200, kM1 = 0x9201; // squad T (held, gen 5) and its NPC
constexpr uint16_t kPlayer = 0x0010;
constexpr uint16_t kGun = 0x9301, kKnife = 0x9302, kLoot = 0x9303, kBody = 0x9400, kRing = 0x9304;

// The same world on both sides: S and T granted to the map server, a gun in N1, a knife in M1, loot on the ground, a body (a dead
// creature in no squad: a resident) with a ring, a player.
void same_world(World& world, MapServer& ms)
{
	Registry r;
	const auto add = [&](uint16_t id, const char* section) -> Obj& {
		Obj& o = r.objs[id];
		o.section = section;
		return o;
	};
	add(kS, "squad_s").is_squad = true;
	add(kT, "squad_t").is_squad = true;
	for (const uint16_t id : {kN1, kN2, kM1})
		add(id, "stalker").creature = true;
	r.join(kS, kN1);
	r.join(kS, kN2);
	r.join(kT, kM1);
	add(kPlayer, "actor").character = true;
	add(kGun, "wpn_ak74");
	add(kKnife, "wpn_knife");
	add(kLoot, "medkit");
	Obj& body = add(kBody, "stalker");
	body.creature = true;
	body.alive = false;
	add(kRing, "af_ring");
	r.attach(kGun, kN1);
	r.attach(kKnife, kM1);
	r.attach(kRing, kBody);
	world.reg = r;
	ms.reg = r;
	world.held = {{kS, 3}, {kT, 5}};
	ms.held = world.held;
	ms.remember();
}

void all_taken(const World& world, uint32_t n)
{
	CHECK_EQ(world.taken, n);
	CHECK(world.refused.empty());
	for (const uint8_t why : world.refused)
		std::printf("    refused: %s\n", jr::why_name(why));
}
} // namespace

// Review WP4 #1: a member of a held squad dies on the map server. The stock death chain took it out of its squad before the Died
// hook; the world still has it in that squad. Its Died names that squad's gen and the world applies it, with and without WP5's member
// hook (whose Left goes after the Died).
TEST(srv_journal_a_held_squads_member_dies_and_the_world_takes_it)
{
	for (const bool hook : {false, true})
	{
		World world;
		MapServer ms;
		same_world(world, ms);
		ms.member_hook = hook;
		ms.die(kN1);
		const std::vector<jr::Entry> es = ms.flush();
		REQUIRE(es.size() == (hook ? 2u : 1u));
		CHECK_EQ(es[0].op, uint8_t(Head::Died));
		world.apply_all(es);
		all_taken(world, uint32_t(es.size()));
		CHECK(!world.reg.get(kN1)->alive);
		CHECK_EQ(world.reg.get(kN1)->squad, kNo);
		CHECK(world.reg.get(kS)->members.count(kN1) == 0);
	}
	// the head as it was before the fix (the dead member's root after the chain: itself, gen 0) is refused: the model sees the defect
	World world;
	MapServer ms;
	same_world(world, ms);
	ms.reg.leave(kN1);
	ms.reg.get(kN1)->alive = false;
	coop::Writer w;
	w.u16(kN1);
	w.u16(kNo);
	jr::Entry old;
	REQUIRE(jr::object_entry(Head::Died, ms.head_of(kN1), w, old));
	world.apply(old);
	REQUIRE(world.refused.size() == 1);
	CHECK_EQ(world.refused[0], uint8_t(jr::Identity));
}

// Review WP4 #2: the moves across a held unit's border: NPC pickup from the ground and from a body, a player's buy from and sale to
// an NPC of a held squad, two NPCs of two held squads swapping. One Parent per item, its head the root before the move; the world
// takes every one and ends where the map server stands.
TEST(srv_journal_moves_across_held_units_are_taken)
{
	{
		World world;
		MapServer ms;
		same_world(world, ms);
		ms.move(kLoot, kN2); // an NPC picks up loot from the ground
		ms.move(kRing, kN2); // ... and a ring from a body (reject from the body, take)
		const std::vector<jr::Entry> es = ms.flush();
		CHECK_EQ(es.size(), size_t(2));
		world.apply_all(es);
		all_taken(world, 2);
		CHECK_EQ(world.reg.get(kLoot)->parent, kN2);
		CHECK_EQ(world.reg.get(kRing)->parent, kN2);
	}
	{
		World world;
		MapServer ms;
		same_world(world, ms);
		ms.move(kGun, kPlayer); // a player buys the gun of N1 (S held)
		const std::vector<jr::Entry> es = ms.flush();
		CHECK_EQ(es.size(), size_t(1)); // the reject and the take net out to one move
		world.apply_all(es);
		all_taken(world, 1);
		CHECK_EQ(world.reg.get(kGun)->parent, kPlayer);
		ms.move(kGun, kN2); // ... and sells it back, to N2, the next frame
		world.apply_all(ms.flush());
		all_taken(world, 2);
		CHECK_EQ(world.reg.get(kGun)->parent, kN2);
	}
	{
		World world;
		MapServer ms;
		same_world(world, ms);
		ms.move(kGun, kM1); // N1 (S) and M1 (T) swap
		ms.move(kKnife, kN1);
		const std::vector<jr::Entry> es = ms.flush();
		CHECK_EQ(es.size(), size_t(2));
		world.apply_all(es);
		all_taken(world, 2);
		CHECK_EQ(world.reg.get(kGun)->parent, kM1);
		CHECK_EQ(world.reg.get(kKnife)->parent, kN1);
	}
	{
		// the heads as they were before the fix (the root after the move) are refused: the model sees the defect
		World world;
		MapServer ms;
		same_world(world, ms);
		ms.reg.attach(kLoot, kN2);
		coop::Writer w;
		w.u16(kLoot);
		w.u16(kN2);
		const float p[3] = {0.f, 0.f, 0.f};
		w.vec3(p);
		jr::Entry old;
		REQUIRE(jr::object_entry(Head::Parent, ms.head_of(kLoot), w, old));
		world.apply(old);
		REQUIRE(world.refused.size() == 1);
		CHECK_EQ(world.refused[0], uint8_t(jr::Identity));
	}
}

// A dead member's weapon falls in the same frame as its death (with and without the member hook): the Died goes first, the drop names
// the body's root as the world has it after that Died (a resident, gen 0).
TEST(srv_journal_a_death_drop_in_the_same_frame_is_taken)
{
	for (const bool hook : {false, true})
	{
		World world;
		MapServer ms;
		same_world(world, ms);
		ms.member_hook = hook;
		ms.die(kN1);
		ms.move(kGun, kNo);
		const std::vector<jr::Entry> es = ms.flush();
		world.apply_all(es);
		all_taken(world, uint32_t(es.size()));
		CHECK_EQ(world.reg.get(kGun)->parent, kNo);
		CHECK(!world.reg.get(kN1)->alive);
	}
}

// An object made on the ground and picked up by an NPC of a held squad in one frame: its Spawn is written where it stands now, its
// Parent is left out. A squad that goes offline rejects its members' items and takes them back silently: nothing goes up.
TEST(srv_journal_netting_leaves_out_what_changes_nothing)
{
	{
		World world;
		MapServer ms;
		same_world(world, ms);
		ms.spawn(0x9500, kNo);
		ms.move(0x9500, kN2);
		const std::vector<jr::Entry> es = ms.flush();
		REQUIRE(es.size() == 1);
		CHECK_EQ(es[0].op, uint8_t(Head::Spawn));
		world.apply_all(es);
		all_taken(world, 1);
		CHECK_EQ(world.reg.get(0x9500)->parent, kN2);
	}
	{
		World world;
		MapServer ms;
		same_world(world, ms);
		for (const uint16_t member : {kN1, kN2})
		{
			const std::vector<uint16_t> items = ms.reg.get(member)->children;
			for (const uint16_t item : items)
			{
				ms.reg.attach(item, kNo); // Perform_destroy -> Perform_reject
				ms.parent_hook(item, kNo);
				ms.reg.attach(item, member); // add_offline_impl, no hook
			}
		}
		CHECK(ms.flush().empty());
	}
}

// An entity outside the map server's ALife registry (an NPC's bolt, a grenade's copy in the hand) is no object of the world's: no Spawn
// of it ever goes up. When its NPC goes offline here, Perform_destroy rejects the bolt with a hook and destroys it without a release.
// The hook without the registry guard sent its Parent "put down" with an empty head; the world refused it as no such object, its line
// "Parent of object N from map server M refused (...): no such object; not here, put down" (every such line of the Server stand and of
// a live world server named no section and put the object down), and the map server's repair (Fetch) asked the world for it again.
// journals_parent leaves it out; the NPC's gun, back in it, is left out as unchanged; a thrown copy, which OnDetach registers before
// its reject's hook, still goes up as its Spawn, written on the ground.
TEST(srv_journal_an_entity_outside_the_registry_sends_no_parent)
{
	constexpr uint16_t kBolt = 0x9051, kGrenade = 0x9320, kCopy = 0x9053;
	CHECK(jr::journals_parent(true, false));
	CHECK(!jr::journals_parent(false, false)); // outside the registry
	CHECK(!jr::journals_parent(true, true)); // a refused create being released (g.quiet)
	CHECK(!jr::journals_parent(false, true));
	for (const bool guard : {false, true})
	{
		World world;
		MapServer ms;
		same_world(world, ms);
		ms.registry_guard = guard;
		ms.server_child(kN1, kBolt); // N1 (a member of the held squad S) comes online here
		CHECK(ms.flush().empty()); // no Spawn: the registry's hook never ran; the snapshot lists the bolt among N1's children
		ms.npc_offline(kN1);
		const std::vector<jr::Entry> es = ms.flush();
		world.apply_all(es);
		CHECK(ms.reg.get(kBolt) == nullptr);
		CHECK(world.reg.get(kBolt) == nullptr);
		CHECK_EQ(ms.reg.get(kGun)->parent, kN1); // the gun is back in N1 and left out as unchanged
		CHECK_EQ(world.reg.get(kGun)->parent, kN1);
		if (guard)
		{
			CHECK(es.empty());
			CHECK(world.refused.empty());
			continue;
		}
		REQUIRE(es.size() == 1u);
		CHECK_EQ(es[0].op, uint8_t(Head::Parent));
		jr::ObjectHead h;
		REQUIRE(jr::object_of(es[0], h));
		CHECK_EQ(h.id, kBolt);
		CHECK_EQ(h.crc, uint16_t(0)); // head_before_move: no registry entry, no section
		coop::Reader lr = jr::layout_of(es[0]);
		CHECK_EQ(lr.u16(), kBolt);
		CHECK_EQ(lr.u16(), kNo); // put down
		CHECK_EQ(world.taken, uint32_t(0));
		REQUIRE(world.refused.size() == 1u);
		CHECK_EQ(world.refused[0], uint8_t(jr::Unknown));
		CHECK(jr::object_note(false, nullptr, h.crc, kNo, true, kNo) == "not here, put down"); // the world's refusal line
		CHECK(jr::repair_of(Head::Parent, jr::Unknown) == jr::Repair::Fetch); // and the map server's repair asks for it again
	}
	// a grenade's copy in N1's hand is thrown: its Spawn goes up written on the ground, its Parent is left out, the world takes it
	World world;
	MapServer ms;
	same_world(world, ms);
	for (Registry* r : {&world.reg, &ms.reg})
	{
		r->objs[kGrenade].section = "grenade_f1";
		r->attach(kGrenade, kN1);
	}
	ms.remember();
	ms.server_child(kGrenade, kCopy); // spawn_fake_missile at the throw's start
	CHECK(ms.flush().empty());
	ms.throw_copy(kGrenade, kCopy);
	const std::vector<jr::Entry> es = ms.flush();
	REQUIRE(es.size() == 1u);
	CHECK_EQ(es[0].op, uint8_t(Head::Spawn));
	world.apply_all(es);
	all_taken(world, 1);
	REQUIRE(world.reg.get(kCopy) != nullptr);
	CHECK_EQ(world.reg.get(kCopy)->parent, kNo);
}

// ---------------------------------------------------------------- the departure flood (Server, 2026-11-26)
//
// World log xray_banan4ik2.log (5 players, Server mode): every printed "Parent of object N from map server M refused: not the writer"
// reads "parent X, moved to X" for a player's character X, 1-3 lines after "player left" or after his level exit and the world's save;
// at least 1500 in the session, 100-300 per departure. The world parks the character first (it writes him from then on); the map server
// he left switches him offline, which rejects each item with a hook and takes each back without one; its snapshot listed only the
// held units' children, so each item went up as a Parent into the same character, refused, and its repair (Fetch: StateDumpRequest
// Replace) destroyed and made the item again on that map server. Fixed twice: the map server's snapshot lists its players' characters
// (client_remember_held), and the world takes a Parent into the holder an object has already as a repeat (accept::unchanged_parent).

namespace
{
constexpr uint16_t kPistol = 0x9310, kAmmo = 0x9311, kArtefact = 0x9312;

// same_world, and the player's character with three items on both sides; `listed`: the map server's snapshot lists his character
// (the fix; false: as before it)
void player_with_items(World& world, MapServer& ms, bool listed)
{
	same_world(world, ms);
	for (Registry* r : {&world.reg, &ms.reg})
	{
		const auto add = [&](uint16_t id, const char* section) {
			r->objs[id].section = section;
			r->attach(id, kPlayer);
		};
		add(kPistol, "wpn_pm");
		add(kAmmo, "ammo_9x19_fmj");
		add(kArtefact, "af_dragon_eye");
	}
	if (listed)
		ms.players.insert(kPlayer);
	ms.remember(); // the end of the frame before his departure
}
} // namespace

// Flows A and B (he quits or drops; he takes a level exit): the map server's flush sends nothing; the world keeps his items in him.
// Before the fix the same departure sent one Parent per item into the same character (head gen 0: a character's root), which the
// world, writing the parked character, refused as not the writer: the log's flood. The world's own guard takes those stragglers as
// repeats, so nothing is refused and nothing repaired even if the map server's snapshot misses him (a change of the frame order).
TEST(srv_journal_a_departing_players_inventory_sends_no_parent)
{
	{
		World world;
		MapServer ms;
		player_with_items(world, ms, true);
		world.parked.insert(kPlayer); // the world parked him first: it writes him and his items now
		ms.take_offline(kPlayer);
		CHECK(ms.flush().empty());
		CHECK(world.refused.empty());
		for (const uint16_t item : {kPistol, kAmmo, kArtefact})
		{
			CHECK_EQ(world.reg.get(item)->parent, kPlayer);
			CHECK_EQ(ms.reg.get(item)->parent, kPlayer);
		}
		CHECK_EQ(ms.memory.children(), size_t(2)); // the next snapshot: the gun and the knife of the held NPCs, he is gone from the trunk
	}
	// before the fix: his character not in the snapshot
	World world;
	MapServer ms;
	player_with_items(world, ms, false);
	world.parked.insert(kPlayer);
	ms.take_offline(kPlayer);
	const std::vector<jr::Entry> es = ms.flush();
	REQUIRE(es.size() == 3u);
	for (const jr::Entry& e : es)
	{
		CHECK_EQ(e.op, uint8_t(Head::Parent));
		jr::ObjectHead h;
		REQUIRE(jr::object_of(e, h));
		CHECK_EQ(h.gen, uint32_t(0));
		coop::Reader lr = jr::layout_of(e);
		CHECK_EQ(lr.u16(), h.id);
		CHECK_EQ(lr.u16(), kPlayer); // "parent X, moved to X"
	}
	world.unchanged_guard = false; // the world's acceptance as it was
	world.apply_all(es);
	CHECK_EQ(world.taken, uint32_t(0));
	REQUIRE(world.refused.size() == 3u);
	for (const uint8_t why : world.refused)
		CHECK_EQ(why, uint8_t(jr::NotWriter));
	// the world's guard: the same entries are repeats, nothing refused (so no Fetch), nothing changed
	World guarded;
	MapServer guarded_ms;
	player_with_items(guarded, guarded_ms, false);
	guarded.parked.insert(kPlayer);
	guarded.apply_all(es);
	all_taken(guarded, 3);
	CHECK_EQ(guarded.repeats, uint32_t(3));
	for (const uint16_t item : {kPistol, kAmmo, kArtefact})
		CHECK_EQ(guarded.reg.get(item)->parent, kPlayer);
	// a player still seated here (the map server writes him): his own unchanged Parent is a repeat too, as host_apply_parent's no-op was
	World seated;
	MapServer seated_ms;
	player_with_items(seated, seated_ms, false);
	seated.apply_all(es);
	all_taken(seated, 3);
	CHECK_EQ(seated.repeats, uint32_t(3));
}

// The bolt of his belt (allymark_server, Dev 65 and 66: "Parent of object 29957 from map server 1 refused: not the writer; here:
// section 'bolt', parent 29698, put down", then its Destroy, after 'allymover' left level 7). A bolt cannot be saved: the stock
// switch offline of his character releases it instead of taking it back, so ParentNet does not net it out. Both its entries named a
// character the map server no longer writes; the world, writing him, refused both and keeps the bolt in him. Left out
// (journal::journals_move_out_of_character), nothing is refused and both sides end as the world says.
namespace
{
// a bolt in the player's character on both sides, in the snapshot of the frame's end
void with_bolt(World& world, MapServer& ms, uint16_t bolt)
{
	for (Registry* r : {&world.reg, &ms.reg})
	{
		r->objs[bolt].section = "bolt";
		r->attach(bolt, kPlayer);
	}
	ms.remember();
}
} // namespace

TEST(srv_journal_a_departing_players_bolt_sends_neither_parent_nor_destroy)
{
	constexpr uint16_t kBolt = 0x9313;
	for (const bool guard : {true, false})
	{
		World world;
		MapServer ms;
		player_with_items(world, ms, true);
		with_bolt(world, ms, kBolt);
		ms.unsaveable.insert(kBolt);
		ms.departure_guard = guard;
		world.parked.insert(kPlayer);
		ms.take_offline(kPlayer);
		CHECK(ms.reg.get(kBolt) == nullptr); // released here
		const std::vector<jr::Entry> es = ms.flush();
		world.apply_all(es);
		CHECK_EQ(world.reg.get(kBolt)->parent, kPlayer); // the world keeps it in him either way
		if (guard)
		{
			CHECK(es.empty());
			CHECK(world.refused.empty());
			CHECK(ms.departed.empty()); // its Destroy took its mark
			continue;
		}
		// before the fix: the stand's two lines
		REQUIRE(es.size() == 2u);
		CHECK_EQ(es[0].op, uint8_t(Head::Parent));
		CHECK_EQ(es[1].op, uint8_t(Head::Destroy));
		REQUIRE(world.refused.size() == 2u);
		for (const uint8_t why : world.refused)
			CHECK_EQ(why, uint8_t(jr::NotWriter));
	}
	// a player who still plays here puts his bolt down: that move is his map server's and goes up
	World world;
	MapServer ms;
	player_with_items(world, ms, true);
	with_bolt(world, ms, kBolt);
	ms.move(kBolt, kNo);
	const std::vector<jr::Entry> es = ms.flush();
	REQUIRE(es.size() == 1u);
	world.apply_all(es);
	all_taken(world, 1);
	CHECK_EQ(world.reg.get(kBolt)->parent, kNo);
	CHECK(jr::journals_move_out_of_character(false, false)); // not out of a character: the rule does not look
	CHECK(jr::journals_move_out_of_character(true, true));
	CHECK(!jr::journals_move_out_of_character(true, false));
}

// Flow C (a pick-up from a body in the frame of his departure): one Parent goes up, the body's ring into him, its head the body's root
// (a resident, gen 0); his other items are left out. While the world still seats him there it takes it. Parked before the entry arrives,
// the world still refuses it as not the writer and the map server's repair puts the ring back into the body there: the departure race
// (TRACE 5C), which needs the W4.2 departure fence (world_seat's Seat::from) and is not covered by this fix.
TEST(srv_journal_a_pickup_in_the_departures_frame_sends_one_parent)
{
	for (const bool parked : {false, true})
	{
		World world;
		MapServer ms;
		player_with_items(world, ms, true);
		ms.move(kRing, kPlayer); // from the body: a reject (not known: no held unit had it), then his take
		ms.take_offline(kPlayer);
		const std::vector<jr::Entry> es = ms.flush();
		REQUIRE(es.size() == 1u);
		CHECK_EQ(es[0].op, uint8_t(Head::Parent));
		jr::ObjectHead h;
		REQUIRE(jr::object_of(es[0], h));
		CHECK_EQ(h.id, kRing);
		CHECK_EQ(h.gen, uint32_t(0));
		if (parked)
			world.parked.insert(kPlayer);
		world.apply_all(es);
		if (!parked)
		{
			all_taken(world, 1);
			CHECK_EQ(world.repeats, uint32_t(0));
			CHECK_EQ(world.reg.get(kRing)->parent, kPlayer);
		}
		else
		{
			REQUIRE(world.refused.size() == 1u);
			CHECK_EQ(world.refused[0], uint8_t(jr::NotWriter));
			CHECK_EQ(world.reg.get(kRing)->parent, kBody);
		}
	}
}

// ---------------------------------------------------------------- review WP4 #3, #6, #9, #10: the engine's glue (its source is read)

namespace
{
std::string engine_code(const char* relative)
{
	const auto path = std::filesystem::path(__FILE__).parent_path().parent_path() / "engine/src" / relative;
	std::ifstream in(path, std::ios::binary);
	REQUIRE(in.is_open());
	std::ostringstream source;
	source << in.rdbuf();
	const std::regex comments_and_literals(R"cpp(//[^\r\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\\r\n])*"|'(?:\\.|[^'\\\r\n])')cpp");
	return std::regex_replace(source.str(), comments_and_literals, " ");
}

std::string xfer_code() { return engine_code("xrGame/coop/srv/coop_levels_xfer.cpp"); }

std::string_view body_of(const std::string& code, const char* type, const char* name)
{
	std::smatch match;
	const std::regex definition(std::string(R"(\b)") + type + R"(\s+)" + name + R"(\s*\([^;{}]*\)\s*\{)");
	if (!std::regex_search(code, match, definition))
		return {};
	const size_t start = size_t(match.position() + match.length());
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

bool before(std::string_view body, std::string_view first, std::string_view second)
{
	const size_t at = body.find(second);
	return at != std::string_view::npos && body.find(first) < at;
}
} // namespace

TEST(srv_journal_engine_glue)
{
	const std::string code = xfer_code();
	// #3: every fact the hooks queued goes up before a transfer packet: send_up drains g.up first, and a frame flushes before its
	// recalls and requests (a squad's ReleasePrepare after the rejects of its items)
	const auto send_all = body_of(code, "void", "client_send_all");
	CHECK(before(send_all, "client_flush_up()", "client_send_journal()"));
	CHECK(before(body_of(code, "void", "send_up"), "client_send_all()", "for ("));
	const auto frame = body_of(code, "void", "xfer_client_frame");
	CHECK(before(frame, "client_flush_up()", "client_recalls(now)"));
	CHECK(before(frame, "client_recalls(now)", "client_send_all()"));
	const size_t sent = frame.find("client_send_all()");
	REQUIRE(sent != std::string_view::npos);
	CHECK(frame.substr(sent).find("client_remember_held()") != std::string_view::npos); // the snapshot after the frame's facts
	CHECK(body_of(code, "void", "logic_hand_over").find("client_send_all()") != std::string_view::npos);
	const auto flush = body_of(code, "void", "client_flush_up");
	CHECK(before(flush, "g.flushing = true", "for ("));
	// #1, #2: the hooks take the head before the change; the flush keeps it for a move and a death
	CHECK(before(body_of(code, "void", "up_parent"), "g.memory.moved(item, new_parent)", "head_before_move(item, before)"));
	CHECK(body_of(code, "void", "up_died").find("place_of_creature(victim, u.head)") != std::string_view::npos);
	const auto released = body_of(code, "void", "xfer_on_released");
	CHECK(before(released, "g.quiet.count(local_id)", "place_of_creature(local_id, u.head)"));
	CHECK(flush.find("journal_object(Head::Parent, u.head, w)") != std::string_view::npos);
	CHECK(flush.find("journal_object(Head::Died, u.head, w)") != std::string_view::npos);
	CHECK(before(flush, "net.send(u.a, u.before, holder)", "journal_object(Head::Parent"));
	// #6: a Logic entry the world took marks its level (serve_bridge's logic_came_since)
	CHECK(before(body_of(code, "void", "host_on_level_journal"), "host_apply_fact(from, e, why, m.seq)", "host_count_entry(from, e.op, taken)"));
	CHECK(body_of(code, "void", "host_count_entry").find("g.logic_at[mapserver::level_of_bridge(from)] = mgr().now_ms()") !=
	    std::string_view::npos);
	// #9: the audit's heal goes through the world's one acceptance
	CHECK(body_of(code, "void", "host_heal_members").find("host_heal_member(from, wire::LevelEntityHead::Joined") != std::string_view::npos);
	CHECK(body_of(code, "bool", "host_heal_member").find("host_apply_heal(from, e, why") != std::string_view::npos); // fix round 2 of A: host_apply_fact's acceptance and apply, a Left goes home
	CHECK(body_of(code, "void", "host_heal_members").find("coop_join_member(") == std::string_view::npos);
	// #10: a refused create's repair tells this level's players (no ClientApply) and journals no Destroy (g.quiet)
	const auto ack = body_of(code, "void", "client_on_journal_ack");
	const size_t quiet = ack.find("g.quiet.insert(");
	REQUIRE(quiet != std::string_view::npos);
	CHECK(before(ack.substr(quiet), "alife_rw().release(e, true)", "g.quiet.erase(local)"));
	CHECK(ack.find("ClientApply") == std::string_view::npos);
}

// The departure flood (Server, 2026-11-26): the engine's glue of both fixes (its source is read; the engine is not built into the test
// exe). The map server's snapshot lists the characters of its players and the flush counts what it left out
// (srv/coop_levels_xfer.cpp); the world fills `unchanged` for a Parent before its acceptance and takes a repeat without applying it
// (srv/coop_levels_alife.cpp).
TEST(srv_journal_departure_flood_glue)
{
	const std::string code = xfer_code();
	const auto remember = body_of(code, "void", "client_remember_held");
	REQUIRE(!remember.empty());
	CHECK(before(remember, "g.holder->ids()", "mapserver::trunk_peers().on()")); // after the held units, as the harness's remember()
	CHECK(remember.find("ai().alife().objects().object(it.second.proxy, true)") != std::string_view::npos); // take_offline's id
	CHECK(before(remember, "mapserver::trunk_peers().on()", "children_of(played)"));
	const auto flush = body_of(code, "void", "client_flush_up");
	CHECK(before(flush, "net.send(u.a, u.before, holder)", "g.parents_unchanged += net.unchanged()"));
	// the snapshot is still taken after the frame's flush: the departure's hooks (the session update, before the levels frame) read
	// the one of the frame before, which still lists his character
	const auto frame = body_of(code, "void", "xfer_client_frame");
	const size_t flushed = frame.find("client_flush_up()");
	REQUIRE(flushed != std::string_view::npos);
	CHECK(frame.find("client_remember_held()", flushed) != std::string_view::npos);
	// the frame order the fix relies on (review nit 2): a map server's frame runs the world's session first (the LevelMap that takes a
	// player off this level comes down in it: mapserver::server_on_map -> virtual_leave), then the session of its level (the departure's
	// hooks run in its update), then the sync frame, whose mode frame runs the levels frame (xfer_client_frame above: the flush, then
	// the snapshot); so the departure's hooks read the snapshot of the frame before
	const std::string manager = engine_code("xrGame/coop/coop_manager.cpp");
	const auto manager_frame = body_of(manager, "void", "Manager::frame");
	REQUIRE(!manager_frame.empty());
	CHECK(before(manager_frame, "m_world.update(now_ms())", "m_session.update(now_ms())"));
	CHECK(before(manager_frame, "m_session.update(now_ms())", "sync::frame()"));
	const std::string sync = engine_code("xrGame/coop/coop_sync.cpp");
	const size_t table = sync.find("kFrame[] = {"); // the frame pass of the module table
	REQUIRE(table != std::string::npos);
	CHECK(sync.substr(table, sync.find("};", table) - table).find("mode().frame()") != std::string::npos);

	const std::string alife = engine_code("xrGame/coop/srv/coop_levels_alife.cpp");
	const auto fact = body_of(alife, "ApplyVerdict", "apply_entry");
	const size_t at = fact.find("case H::Parent:");
	REQUIRE(at != std::string_view::npos);
	const auto parent_case = fact.substr(at);
	CHECK(before(parent_case, "f.unchanged = obj && item == h.id && accept::unchanged_parent(obj->ID_Parent, parent)",
	    "accept::accepts(f)"));
	CHECK(before(parent_case, "refused_by(author, e.op, item, v, why, to_seen)", "if (v.repeat)"));
	CHECK(before(parent_case, "parent_unchanged(author, item, parent, accept::sender_writes(f))", "host_apply_parent(item, parent, pos)"));
	const auto repeat = body_of(alife, "ApplyVerdict", "parent_unchanged");
	REQUIRE(!repeat.empty());
	CHECK(repeat.find("++g_accept.repeats") != std::string_view::npos);
	CHECK(repeat.find("host_apply_parent") == std::string_view::npos); // nothing applied, nothing relayed
	CHECK(repeat.find("host_on_parent_changed") == std::string_view::npos);
	CHECK(body_of(alife, "void", "host_accept_print_status").find("g_accept.parents_unchanged") != std::string_view::npos);
}

// The engine's glue of journal::journals_parent (its source is read): up_parent asks this map server's ALife registry at the hook, before
// the snapshot's move and the up, and counts what it left out for the status; and the stock chain the rule rests on: ALife's create
// registers nothing that cannot be saved (a bolt cannot), and a reject runs game_sv_Single::OnDetach, which registers a thrown copy,
// before the Parent hook.
TEST(srv_journal_registry_guard_glue)
{
	const std::string code = xfer_code();
	const auto hook = body_of(code, "void", "up_parent");
	REQUIRE(!hook.empty());
	CHECK(before(hook, "ai().alife().objects().object(item, true)", "journal::journals_parent("));
	CHECK(before(hook, "journal::journals_parent(", "g.memory.moved(item, new_parent)"));
	CHECK(before(hook, "journal::journals_parent(", "g.up.push_back("));
	CHECK(hook.find("g.quiet.count(item)") != std::string_view::npos);
	CHECK(hook.find("++g.parents_unregistered") != std::string_view::npos);
	CHECK(body_of(code, "void", "xfer_print_status").find("g.parents_unregistered") != std::string_view::npos);

	const std::string alife = engine_code("xrGame/alife_simulator_base.cpp");
	const size_t create = alife.find("void CALifeSimulatorBase::create(CSE_ALifeObject* object)"); // the create of a client's spawn
	REQUIRE(create != std::string::npos);
	CHECK(before(std::string_view(alife).substr(create), "can_save()", "register_object("));
	const std::string items = engine_code("xrServerEntities/xrServer_Objects_ALife_Items.cpp");
	CHECK(std::regex_search(items, std::regex(R"(CSE_ALifeItemBolt::can_save\s*\(\s*\)\s*const\s*\{\s*return\s*\(\s*false\s*\)\s*;)")));
	const std::string reject = engine_code("xrGame/xrServer_process_event_reject.cpp");
	const auto on_reject = body_of(reject, "bool", "xrServer::Process_event_reject");
	REQUIRE(!on_reject.empty());
	CHECK(before(on_reject, "game->OnDetach(id_parent, id_entity)", "host_on_parent_changed(id_entity, id_parent, 0xffff)"));
}
