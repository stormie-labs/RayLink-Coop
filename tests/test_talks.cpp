// Anomaly Coop unit tests: the host's memory of a player's recent talk locks (xrCoop/coop_talks.h, Ruling F2-34,
// F2 T12 round 2). coop_dialog.cpp records every lock that ends; coop.talk_recent answers coop_npc_companions' recruit
// check from it.
#include "test_util.h"

#include "coop_talks.h"

#include <cstdint>

using namespace coop::talks;
using coop::Reader;
using coop::Writer;

namespace
{
constexpr uint16_t kNone = 0xffff;
}

// Holding the lock now, or a lock that ended no more than the window ago.
TEST(talks_recent_window)
{
	Recent r;
	const uint64_t t0 = 100000;
	CHECK(!talked_recently(kNone, r, 201, t0, 5000)); // never talked
	CHECK(talked_recently(201, r, 201, t0, 5000));    // holds it now
	CHECK(!talked_recently(202, r, 201, t0, 5000));   // holds another NPC's
	r.ended(201, t0);
	CHECK(talked_recently(kNone, r, 201, t0 + 2000, 5000)); // ended 2 s ago
	CHECK(talked_recently(kNone, r, 201, t0 + 5000, 5000)); // exactly the window
	CHECK(!talked_recently(kNone, r, 201, t0 + 10000, 5000)); // 10 s ago
	CHECK(!talked_recently(kNone, r, 202, t0 + 1000, 5000)); // not that NPC
	CHECK(talked_recently(kNone, r, 201, t0 - 10, 5000));    // a clock read before the end: still recent
	CHECK(!talked_recently(kNone, r, kNone, t0, 5000));      // "no NPC" never matches
	CHECK(!talked_recently(kNone, r, 201, t0 + 1, 0));       // a zero window: only holding now counts
}

// Bounded: the last kKept ends are kept, the same NPC keeps one entry with its latest end.
TEST(talks_recent_bounded)
{
	Recent r;
	static_assert(Recent::kKept == 2, "two last talks per player");
	r.ended(201, 1000);
	r.ended(202, 2000);
	r.ended(203, 3000); // drops the oldest (201)
	CHECK_EQ(r.size(), size_t(2));
	CHECK(!r.within(201, 3000, 5000));
	CHECK(r.within(202, 3000, 5000));
	CHECK(r.within(203, 3000, 5000));
	r.ended(202, 9000); // the same NPC again: its time moves, nothing else is dropped
	CHECK_EQ(r.size(), size_t(2));
	CHECK(r.within(202, 13000, 5000));
	CHECK(r.within(203, 7000, 5000));
	r.ended(kNone, 9500); // "no NPC" is not recorded
	CHECK_EQ(r.size(), size_t(2));
	CHECK(r.within(203, 7000, 5000));
	r.clear();
	CHECK_EQ(r.size(), size_t(0));
	CHECK(!r.within(202, 9000, 5000));
}

// ---------------------------------------------------------------------------------------------------------------------
// B8 (build 10): the host judges whether an NPC talks to a client's character; a refusal carries the reason, and a talk
// that was granted but did not start says why in the client's log.
// ---------------------------------------------------------------------------------------------------------------------

// Reasons: the name the host's Lua returns, the byte on the wire, the string-table id and the fallback text.
TEST(talks_reason_names)
{
	CHECK(reason_from_name("hostile") == Reason::Hostile);
	CHECK(reason_from_name("combat") == Reason::Combat);
	CHECK(reason_from_name("wounded") == Reason::Wounded);
	CHECK(reason_from_name("unwilling") == Reason::Unwilling);
	// a refusal never turns into "allowed": nothing, an empty or an unknown name is plain "does not want to"
	CHECK(reason_from_name(nullptr) == Reason::Unwilling);
	CHECK(reason_from_name("") == Reason::Unwilling);
	CHECK(reason_from_name("rain") == Reason::Unwilling);

	const Reason all[] = {Reason::Unwilling, Reason::Hostile, Reason::Combat, Reason::Wounded};
	for (Reason a : all)
	{
		CHECK(reason_from_name(reason_name(a)) == a); // the name round-trips
		CHECK(reason_from_wire(uint8_t(a)) == a);     // so does the wire byte
		CHECK(std::string(reason_string_id(a)).rfind("st_coop_talk_", 0) == 0);
		CHECK(std::string(reason_fallback(a)).size() > 10);
		for (Reason b : all)
			if (a != b)
			{
				CHECK(std::string(reason_name(a)) != reason_name(b));
				CHECK(std::string(reason_string_id(a)) != reason_string_id(b));
				CHECK(uint8_t(a) != uint8_t(b));
			}
	}
	// a byte this build does not know (a newer host) or 0 (a refusal without a reason): "does not want to"
	CHECK(reason_from_wire(0) == Reason::Unwilling);
	CHECK(reason_from_wire(200) == Reason::Unwilling);
	CHECK(Reason::None != Reason::Unwilling);
}

// DialogLockResult: npc, result, and for NotWilling the reason byte. The five old results keep their three bytes.
TEST(talks_lock_result_wire)
{
	static_assert(lock::Granted == 0 && lock::Busy == 1 && lock::Gone == 2 && lock::Refused == 3 && lock::TooFar == 4,
		"results 0..4 are on the wire since protocol 8");
	CHECK_EQ(int(lock::NotWilling), 5);

	for (uint8_t res : {lock::Granted, lock::Busy, lock::Gone, lock::Refused, lock::TooFar})
	{
		Writer w;
		write_lock_result(w, {201, res, Reason::Hostile}); // a reason on another result is not written
		CHECK_EQ(w.size(), size_t(3));
		Reader r(w.ptr(), w.size());
		LockResultMsg m;
		CHECK(read_lock_result(r, m));
		CHECK_EQ(m.npc, uint16_t(201));
		CHECK_EQ(m.result, res);
		CHECK(m.reason == Reason::None);
	}

	Writer w;
	write_lock_result(w, {0x1234, lock::NotWilling, Reason::Combat});
	CHECK_EQ(w.size(), size_t(4));
	CHECK_EQ(int(w.data()[0]), 0x34);
	CHECK_EQ(int(w.data()[1]), 0x12);
	CHECK_EQ(int(w.data()[2]), 5);
	CHECK_EQ(int(w.data()[3]), int(uint8_t(Reason::Combat)));
	Reader r(w.ptr(), w.size());
	LockResultMsg m;
	CHECK(read_lock_result(r, m));
	CHECK_EQ(m.npc, uint16_t(0x1234));
	CHECK_EQ(m.result, uint8_t(lock::NotWilling));
	CHECK(m.reason == Reason::Combat);

	// NotWilling from a host that sent no reason byte: "does not want to"
	Writer old;
	old.u16(7);
	old.u8(lock::NotWilling);
	Reader ro(old.ptr(), old.size());
	LockResultMsg mo;
	CHECK(read_lock_result(ro, mo));
	CHECK(mo.reason == Reason::Unwilling);

	// a cut message is refused
	Writer cut;
	cut.u16(7);
	Reader rc(cut.ptr(), cut.size());
	LockResultMsg mc;
	CHECK(!read_lock_result(rc, mc));
}

TEST(talks_lock_result_names)
{
	CHECK_EQ(std::string(lock::name(lock::Granted)), std::string("granted"));
	CHECK_EQ(std::string(lock::name(lock::TooFar)), std::string("too far"));
	CHECK_EQ(std::string(lock::name(lock::NotWilling)), std::string("not willing"));
	CHECK_EQ(std::string(lock::name(99)), std::string("?"));
}

// Why a granted talk did not start on the client: the first cause in this order is reported.
TEST(talks_start_block_order)
{
	StartState ok; // everything in order: nothing blocks
	CHECK(start_block(ok) == StartBlock::None);

	StartState s = ok;
	s.npc_found = false;
	CHECK(start_block(s) == StartBlock::NpcGone);
	s.npc_alive = false; // gone beats dead: there is nothing to look at
	CHECK(start_block(s) == StartBlock::NpcGone);

	s = ok;
	s.npc_alive = false;
	s.talk_enabled = false; // a corpse also has talk off: the death is the cause
	CHECK(start_block(s) == StartBlock::NpcDead);

	s = ok;
	s.actor_alive = false;
	s.actor_talking = true;
	CHECK(start_block(s) == StartBlock::ActorDead);

	s = ok;
	s.paused = true;
	s.window_shown = true;
	CHECK(start_block(s) == StartBlock::Paused);
	s = ok;
	s.window_shown = true;
	s.actor_talking = true;
	CHECK(start_block(s) == StartBlock::ActorBusy);
	s = ok;
	s.actor_talking = true;
	CHECK(start_block(s) == StartBlock::ActorBusy);
	s = ok;
	s.partner_talking = true;
	s.talk_enabled = false;
	CHECK(start_block(s) == StartBlock::PartnerBusy); // someone is already talking to it
	s = ok;
	s.talk_enabled = false;
	CHECK(start_block(s) == StartBlock::TalkOff);

	// every cause has its own non-empty name for the log
	const StartBlock all[] = {StartBlock::NpcGone, StartBlock::NpcDead, StartBlock::ActorDead, StartBlock::Paused,
		StartBlock::ActorBusy, StartBlock::PartnerBusy, StartBlock::TalkOff};
	for (StartBlock a : all)
	{
		CHECK(std::string(start_block_name(a)).size() > 4);
		for (StartBlock b : all)
			if (a != b)
				CHECK(std::string(start_block_name(a)) != start_block_name(b));
	}
	// nothing blocks, yet the engine did not start the talk: reported as such, never as a known cause
	CHECK(start_block(ok) == StartBlock::None);
	CHECK(std::string(start_block_name(StartBlock::None)).size() > 4);
}
