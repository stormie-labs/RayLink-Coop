// Anomaly Coop unit tests: player money on the host (coop_ledger.h; F2 T1, review R4 7). The host owns every player's
// balance; a client sends changes with a cause, the host checks them and answers with the balance it holds.
#include "test_util.h"

#include "coop_ledger.h"

#include <map>
#include <vector>

using coop::Reader;
using coop::Writer;
using coop::ledger::Allowance;
using coop::ledger::apply_client_delta;
using coop::ledger::Cause;
using coop::ledger::check_transfer;
using coop::ledger::client_view;
using coop::ledger::Decision;
using coop::ledger::forget_acked;
using coop::ledger::HostBook;
using coop::ledger::MoneyBalanceMsg;
using coop::ledger::MoneyReq;
using coop::ledger::Pending;
using coop::ledger::Policy;
using coop::ledger::Receiver;
using coop::ledger::Verdict;

namespace
{
// One character's balance and allowances on the host.
struct HostSide
{
	uint32_t balance = 0;
	Allowance dialog;
	Allowance script;
	Policy policy;

	Verdict change(int64_t delta, Cause cause, uint64_t now, bool dialog_lock = false)
	{
		return apply_client_delta(balance, delta, cause, dialog_lock, dialog, script, policy, now);
	}
};

bool near(double a, double b) { return a > b - 0.5 && a < b + 0.5; }

MoneyReq req(uint32_t seq, int32_t delta, Cause cause = Cause::Script, uint32_t ref = 0)
{
	return MoneyReq{seq, delta, cause, ref};
}

std::vector<uint8_t> bytes_of(const Writer& w) { return std::vector<uint8_t>(w.ptr(), w.ptr() + w.size()); }
} // namespace

TEST(ledger_spend)
{
	HostSide h;
	h.balance = 1000;
	CHECK(h.change(-400, Cause::Script, 0) == Verdict::Applied);
	CHECK_EQ(h.balance, 600u);
	CHECK(h.change(-601, Cause::Script, 0) == Verdict::Insufficient);
	CHECK_EQ(h.balance, 600u);
	// Spending everything is fine; a spend never touches the allowance.
	CHECK(h.change(-600, Cause::Dialog, 0, true) == Verdict::Applied);
	CHECK_EQ(h.balance, 0u);
	CHECK(!h.script.started);
	CHECK(!h.dialog.started);
	// No overflow on the most negative change a caller can pass.
	h.balance = 5;
	CHECK(h.change(INT64_MIN, Cause::Script, 0) == Verdict::Insufficient);
	CHECK_EQ(h.balance, 5u);
}

TEST(ledger_script_gain_allowance)
{
	// Default policy: 50000 in a row, then 10000 per minute.
	HostSide h;
	CHECK_EQ(h.policy.script_gain_burst, 50000u);
	CHECK_EQ(h.policy.script_gain_per_min, 10000u);
	CHECK(h.change(50000, Cause::Script, 0) == Verdict::Applied);
	CHECK_EQ(h.balance, 50000u);
	CHECK(h.change(1, Cause::Script, 0) == Verdict::NoAllowance);
	CHECK_EQ(h.balance, 50000u);
	CHECK(h.change(10000, Cause::Script, 60000) == Verdict::Applied);
	CHECK_EQ(h.balance, 60000u);
	CHECK(h.change(1, Cause::Script, 60000) == Verdict::NoAllowance);
	CHECK_EQ(h.balance, 60000u);
	// A refused gain takes nothing from the allowance: half a minute later half the refill is there.
	CHECK(h.change(5001, Cause::Script, 90000) == Verdict::NoAllowance);
	CHECK(h.change(5000, Cause::Script, 90000) == Verdict::Applied);
	// The allowance never holds more than the burst, however long the player waited.
	CHECK(h.change(50001, Cause::Script, 90000 + 3600000) == Verdict::NoAllowance);
	CHECK(h.change(50000, Cause::Script, 90000 + 3600000) == Verdict::Applied);
	// A clock that goes back refills nothing.
	CHECK(h.change(1, Cause::Script, 1000) == Verdict::NoAllowance);
}

TEST(ledger_dialog_gain)
{
	// The talk lock is held: a dialog pays out of the dialog allowance first, the script one is not touched.
	HostSide h;
	CHECK_EQ(h.policy.dialog_gain_cap, 100000u);
	CHECK_EQ(h.policy.dialog_gain_per_min, 20000u);
	CHECK(h.change(100000, Cause::Dialog, 0, true) == Verdict::Applied);
	CHECK_EQ(h.balance, 100000u);
	CHECK(near(h.dialog.tokens, 0));
	CHECK(!h.script.started);
	// The next RU comes out of the script allowance.
	CHECK(h.change(1, Cause::Dialog, 0, true) == Verdict::Applied);
	CHECK(near(h.script.tokens, 49999));
	CHECK_EQ(h.balance, 100001u);
	// A minute later the dialog allowance holds 20000 again, the script one is not touched by that payout.
	CHECK(h.change(20000, Cause::Dialog, 60000, true) == Verdict::Applied);
	CHECK(near(h.dialog.tokens, 0));
	CHECK(near(h.script.tokens, 49999));
	// The script one refills when it is drawn on: back at its burst.
	CHECK(h.change(50000, Cause::Dialog, 60000, true) == Verdict::Applied);
	CHECK(h.change(1, Cause::Dialog, 60000, true) == Verdict::NoAllowance);
	CHECK_EQ(h.balance, 170001u);

	// Part of a gain fits in the dialog allowance: the rest comes out of the script one, or nothing happens.
	HostSide part;
	CHECK(part.change(90000, Cause::Dialog, 0, true) == Verdict::Applied);
	CHECK(part.change(60001, Cause::Dialog, 0, true) == Verdict::NoAllowance); // 10000 + 50001 > 10000 + 50000
	CHECK(near(part.dialog.tokens, 10000));
	CHECK_EQ(part.balance, 90000u);
	uint32_t from_dialog = 7;
	CHECK(apply_client_delta(part.balance, 60000, Cause::Dialog, true, part.dialog, part.script, part.policy, 0,
	          &from_dialog) == Verdict::Applied);
	CHECK_EQ(from_dialog, 10000u);
	CHECK_EQ(part.balance, 150000u);
	CHECK(near(part.dialog.tokens, 0));
	CHECK(part.change(1, Cause::Script, 0) == Verdict::NoAllowance);

	// Dialog without a lock counts as Script.
	HostSide nolock;
	CHECK(nolock.change(50000, Cause::Dialog, 0, false) == Verdict::Applied);
	CHECK(!nolock.dialog.started);
	CHECK(nolock.change(1, Cause::Dialog, 0, false) == Verdict::NoAllowance);
	CHECK_EQ(nolock.balance, 50000u);
}

// Ruling F2-1 (review, Critical): the dialog allowance belongs to the player, not to a talk lock. Taking another lock
// (another NPC, the same one again) or a change without a lock between them refills nothing: lock cycling cannot
// print money.
TEST(ledger_dialog_cap_not_reset_by_lock_cycling)
{
	HostBook book;
	book.start_session({300}); // a character from the save: full allowances (Ruling F2-10)
	const Policy p;
	const Receiver nobody;
	uint32_t balance = 0;
	uint32_t seq = 0;
	auto send = [&](int32_t delta, Cause cause, bool lock, uint64_t now)
	{
		const Decision d = book.on_request(1, 300, req(++seq, delta, cause), balance, lock, nobody, p, now);
		if (d.verdict == Verdict::Applied)
			balance = d.balance;
		return d;
	};
	CHECK(send(100000, Cause::Dialog, true, 0).verdict == Verdict::Applied); // talk to NPC A
	CHECK(send(1, Cause::Script, false, 0).verdict == Verdict::Applied); // between the talks: no lock
	const Decision zero = send(0, Cause::Script, false, 0); // or a change of nothing
	CHECK(zero.verdict == Verdict::Malformed);
	CHECK_EQ(zero.balance, 100001u);
	CHECK(send(100000, Cause::Dialog, true, 0).verdict == Verdict::NoAllowance); // talk to NPC B
	CHECK(send(100000, Cause::Dialog, true, 0).verdict == Verdict::NoAllowance); // A again
	CHECK_EQ(balance, 100001u);
	// What is left is the script allowance.
	CHECK(send(49999, Cause::Dialog, true, 0).verdict == Verdict::Applied);
	CHECK(send(1, Cause::Dialog, true, 0).verdict == Verdict::NoAllowance);
	CHECK_EQ(balance, 150000u);
	// An hour of lock farming, a new lock and a 100000 payout every minute: both allowances refill 20000 + 10000 a
	// minute, so 18 payouts go through (1 800 000 RU an hour), not 60 (6 000 000 RU with a cap per lock).
	uint32_t applied = 0;
	for (int i = 0; i < 60; ++i)
		if (send(100000, Cause::Dialog, true, 60000ull * uint64_t(i + 1)).verdict == Verdict::Applied)
			++applied;
	CHECK_EQ(applied, 18u);
	CHECK_EQ(balance, 150000u + 60u * (20000u + 10000u));
}

// Review fix round 1: the allowances belong to the character for the whole session; leaving and joining again (a new
// connection, maybe another peer id, a client numbering from 1) refills nothing. The numbering of a connection goes
// with it.
TEST(ledger_allowance_survives_reconnect)
{
	HostBook book;
	book.start_session({300, 301}); // characters from the save
	const Policy p;
	const Receiver nobody;
	Decision d = book.on_request(1, 300, req(41, 50000), 0, false, nobody, p, 0);
	CHECK(d.verdict == Verdict::Applied);
	CHECK_EQ(d.acked, 41u);
	CHECK_EQ(d.gain_script, 50000u);
	CHECK_EQ(d.gain_dialog, 0u);
	book.peer_left(1);
	CHECK_EQ(book.acked(1), 0u);
	// The same character back as peer 2, a new game process numbering from 1.
	d = book.on_request(2, 300, req(1, 1), 50000, false, nobody, p, 0); // the same moment: no refill either
	CHECK(!d.stale);
	CHECK(d.verdict == Verdict::NoAllowance);
	CHECK_EQ(d.balance, 50000u);
	CHECK_EQ(book.acked(2), 1u);
	// As peer 1 again, the old numbering going on.
	d = book.on_request(1, 300, req(42, 1), 50000, false, nobody, p, 0);
	CHECK(d.verdict == Verdict::NoAllowance);
	// Another character has his own.
	d = book.on_request(3, 301, req(1, 50000), 0, false, nobody, p, 0);
	CHECK(d.verdict == Verdict::Applied);
	REQUIRE(book.allowances(300) != nullptr);
	CHECK(near(book.allowances(300)->script.tokens, 0));
	// A dialog split is reported by allowance.
	d = book.on_request(3, 301, req(2, 1000, Cause::Dialog), 50000, true, nobody, p, 0);
	CHECK(d.verdict == Verdict::Applied);
	CHECK_EQ(d.gain_dialog, 1000u);
	CHECK_EQ(d.gain_script, 0u);
	// A new session keeps nothing.
	book.reset();
	CHECK(book.allowances(300) == nullptr);
	CHECK_EQ(book.acked(2), 0u);
}

TEST(ledger_stale_seq)
{
	HostBook book;
	book.start_session({300});
	const Policy p;
	const Receiver nobody;
	Decision d = book.on_request(1, 300, req(5, -100), 1000, false, nobody, p, 0);
	CHECK(d.verdict == Verdict::Applied);
	CHECK_EQ(d.balance, 900u);
	// The same change again, an older one: nothing done, the answer says where we are.
	d = book.on_request(1, 300, req(5, -100), 900, false, nobody, p, 0);
	CHECK(d.stale);
	CHECK_EQ(d.balance, 900u);
	CHECK_EQ(d.acked, 5u);
	d = book.on_request(1, 300, req(4, 50000), 900, false, nobody, p, 0);
	CHECK(d.stale);
	CHECK_EQ(d.balance, 900u);
	CHECK_EQ(book.acked(1), 5u);
	REQUIRE(book.allowances(300) != nullptr); // made by the spend above
	CHECK(!book.allowances(300)->script.started); // the stale gain touched nothing
	d = book.on_request(1, 300, req(6, -100), 900, false, nobody, p, 0);
	CHECK(!d.stale);
	CHECK_EQ(d.balance, 800u);
	CHECK_EQ(d.acked, 6u);
	// Refused changes are answered too, and count as answered.
	d = book.on_request(1, 300, req(7, -5000), 800, false, nobody, p, 0);
	CHECK(d.verdict == Verdict::Insufficient);
	CHECK_EQ(d.acked, 7u);
	CHECK_EQ(d.balance, 800u);
}

TEST(ledger_transfer_checks)
{
	const Policy p;
	uint32_t balance = 1000, credit = 99;
	Receiver to;
	to.peer = 2;
	to.present = true;
	to.balance = 500;
	// Nobody there, himself, nothing given.
	Receiver gone = to;
	gone.present = false;
	CHECK(check_transfer(1, gone, -100, balance, credit, p) == Verdict::Malformed);
	CHECK_EQ(credit, 0u);
	CHECK(check_transfer(2, to, -100, balance, credit, p) == Verdict::Malformed);
	CHECK(check_transfer(1, to, 0, balance, credit, p) == Verdict::Malformed);
	CHECK(check_transfer(1, to, 100, balance, credit, p) == Verdict::Malformed);
	CHECK(check_transfer(1, to, -1001, balance, credit, p) == Verdict::Insufficient);
	CHECK(check_transfer(1, to, INT64_MIN, balance, credit, p) == Verdict::Insufficient);
	Receiver rich = to;
	rich.balance = p.max_money - 50;
	CHECK(check_transfer(1, rich, -51, balance, credit, p) == Verdict::OverMax);
	CHECK_EQ(balance, 1000u);
	CHECK(check_transfer(1, to, -300, balance, credit, p) == Verdict::Applied);
	CHECK_EQ(balance, 700u);
	CHECK_EQ(credit, 300u);
	// To the host (peer 0) is fine; a transfer never touches the allowances.
	HostBook book;
	Receiver host;
	host.peer = 0;
	host.present = true;
	const Decision d = book.on_request(1, 300, req(1, -200, Cause::Transfer, 0), 700, false, host, p, 0);
	CHECK(d.verdict == Verdict::Applied);
	CHECK_EQ(d.balance, 500u);
	CHECK_EQ(d.credit, 200u);
	CHECK(book.allowances(300) == nullptr);
	const Decision bad = book.on_request(1, 300, req(2, -200, Cause::Transfer, 9), 500, false, gone, p, 0);
	CHECK(bad.verdict == Verdict::Malformed);
	CHECK_EQ(bad.credit, 0u);
	CHECK_EQ(bad.balance, 500u);
	CHECK_EQ(bad.acked, 2u);
}

// Ruling F2-10 (review round 2, Important): the client chooses its player key, and the host makes a character for any
// new key. A character made in this session starts with empty allowances and only gets the refills: a new key cannot
// bring a fresh 50 000 + 100 000 to pass on to the main character.
TEST(ledger_new_character_starts_empty)
{
	HostBook book;
	book.start_session({300}); // 300 was in the save; 777 is new
	CHECK(book.from_save(300));
	CHECK(!book.from_save(777));
	const Policy p;
	const Receiver nobody;
	const uint64_t t0 = 5000000; // well into the session
	Decision d = book.on_request(4, 777, req(1, 1), 0, false, nobody, p, t0);
	CHECK(d.verdict == Verdict::NoAllowance);
	d = book.on_request(4, 777, req(2, 1, Cause::Dialog), 0, true, nobody, p, t0);
	CHECK(d.verdict == Verdict::NoAllowance);
	REQUIRE(book.allowances(777) != nullptr);
	CHECK(book.allowances(777)->script.started);
	CHECK(book.allowances(777)->dialog.started);
	// A spend is never limited.
	d = book.on_request(4, 777, req(3, -1), 10, false, nobody, p, t0);
	CHECK(d.verdict == Verdict::Applied);
	// A minute later: the refills only (10000 script, 20000 dialog), not the bursts.
	d = book.on_request(4, 777, req(4, 10001), 0, false, nobody, p, t0 + 60000);
	CHECK(d.verdict == Verdict::NoAllowance);
	d = book.on_request(4, 777, req(5, 10000), 0, false, nobody, p, t0 + 60000);
	CHECK(d.verdict == Verdict::Applied);
	d = book.on_request(4, 777, req(6, 20001, Cause::Dialog), 0, true, nobody, p, t0 + 60000);
	CHECK(d.verdict == Verdict::NoAllowance);
	d = book.on_request(4, 777, req(7, 20000, Cause::Dialog), 0, true, nobody, p, t0 + 60000);
	CHECK(d.verdict == Verdict::Applied);
	CHECK_EQ(d.gain_dialog, 20000u);
	// Leaving and joining again with the same key changes nothing.
	book.peer_left(4);
	d = book.on_request(5, 777, req(1, 1), 0, false, nobody, p, t0 + 60000);
	CHECK(d.verdict == Verdict::NoAllowance);
	// A new session: what the save holds then is "from the save".
	book.start_session({300, 777});
	d = book.on_request(5, 777, req(2, 50000), 0, false, nobody, p, t0 + 60000);
	CHECK(d.verdict == Verdict::Applied);
	// Without a list (reset) every character counts as new.
	book.reset();
	CHECK(!book.from_save(300));
}

// Ruling F2-10: a returning player's character, in the save when the session started, has its full allowances.
TEST(ledger_saved_character_keeps_burst)
{
	HostBook book;
	book.start_session({300, 301});
	const Policy p;
	const Receiver nobody;
	Decision d = book.on_request(1, 300, req(1, 50000), 0, false, nobody, p, 5000000);
	CHECK(d.verdict == Verdict::Applied);
	d = book.on_request(1, 300, req(2, 100000, Cause::Dialog), 50000, true, nobody, p, 5000000);
	CHECK(d.verdict == Verdict::Applied);
	CHECK_EQ(d.gain_dialog, 100000u);
	d = book.on_request(1, 300, req(3, 1), 150000, false, nobody, p, 5000000);
	CHECK(d.verdict == Verdict::NoAllowance);
	// The other saved character has his own burst.
	d = book.on_request(2, 301, req(1, 50000), 0, false, nobody, p, 5000000);
	CHECK(d.verdict == Verdict::Applied);
}

namespace
{
// Balances by character, written through peers the way coop_money writes them (peer -> its character).
struct Balances
{
	std::map<uint32_t, uint32_t> character_of; // peer -> character
	std::map<uint32_t, uint32_t> money; // character -> RU

	uint32_t get(uint32_t peer) { return money[character_of[peer]]; }
	void set(uint32_t peer, uint32_t value) { money[character_of[peer]] = value; }
	void add(uint32_t peer, uint32_t credit) { money[character_of[peer]] += credit; }
};
} // namespace

// Review round 2: a transfer is settled giver first, then the receiver gets the credit on top of what he holds at that
// moment. Two connections on one character (a fair game never has them) keep their money exactly: crediting first and
// then writing the giver's figure, taken before, would lose the credit; nothing may ever print money.
TEST(ledger_transfer_order_keeps_money)
{
	using coop::ledger::settle_transfer;
	const Policy p;
	HostBook book;
	book.start_session({300, 301});

	// Two players, two characters: the money moves.
	Balances two;
	two.character_of = {{1, 300}, {2, 301}};
	two.money = {{300, 1000}, {301, 500}};
	Receiver to{2, true, two.get(2)};
	Decision d = book.on_request(1, 300, req(1, -400, Cause::Transfer, 2), two.get(1), false, to, p, 0);
	REQUIRE(d.verdict == Verdict::Applied);
	settle_transfer(two, 1, d.balance, 2, d.credit);
	CHECK_EQ(two.money[300], 600u);
	CHECK_EQ(two.money[301], 900u);

	// Two connections on one character: neither printed (1400) nor lost (600).
	Balances one;
	one.character_of = {{1, 300}, {2, 300}};
	one.money = {{300, 1000}};
	Receiver self{2, true, one.get(2)};
	d = book.on_request(1, 300, req(2, -400, Cause::Transfer, 2), one.get(1), false, self, p, 0);
	REQUIRE(d.verdict == Verdict::Applied);
	settle_transfer(one, 1, d.balance, 2, d.credit);
	CHECK_EQ(one.money[300], 1000u);
}

TEST(ledger_over_max)
{
	HostSide h;
	CHECK_EQ(h.policy.max_money, 100000000u);
	h.balance = 99999999;
	CHECK(h.change(2, Cause::Script, 0) == Verdict::OverMax);
	CHECK_EQ(h.balance, 99999999u);
	CHECK(!h.script.started); // checked before the allowance: nothing taken from it
	CHECK(h.change(1, Cause::Script, 0) == Verdict::Applied);
	CHECK_EQ(h.balance, 100000000u);
	CHECK(h.change(1, Cause::Dialog, 0, true) == Verdict::OverMax);
	CHECK(!h.dialog.started);
}

TEST(ledger_bad_causes)
{
	HostSide h;
	h.balance = 1000;
	// The giver's side of a transfer is a spend; the caller credits the receiver.
	CHECK(h.change(-300, Cause::Transfer, 0) == Verdict::Applied);
	CHECK_EQ(h.balance, 700u);
	CHECK(h.change(-701, Cause::Transfer, 0) == Verdict::Insufficient);
	CHECK(h.change(300, Cause::Transfer, 0) == Verdict::Malformed);
	CHECK(h.change(0, Cause::Transfer, 0) == Verdict::Malformed);
	CHECK(h.change(5, static_cast<Cause>(3), 0) == Verdict::Malformed);
	CHECK(h.change(-5, static_cast<Cause>(200), 0) == Verdict::Malformed);
	CHECK_EQ(h.balance, 700u);
	// A change of nothing: a client never sends one (Ruling F2-1).
	CHECK(h.change(0, Cause::Script, 0) == Verdict::Malformed);
	CHECK(h.change(0, Cause::Dialog, 0, true) == Verdict::Malformed);
	CHECK_EQ(h.balance, 700u);
	CHECK(!h.script.started);
	CHECK(!h.dialog.started);
}

TEST(ledger_client_view)
{
	CHECK_EQ(client_view(500, 3, {{3, -100}, {4, -50}, {5, 20}}), 470u);
	CHECK_EQ(client_view(10, 0, {{7, -50}}), 0u);
	// Never above max_money, but never below what the host holds.
	CHECK_EQ(client_view(99999990, 0, {{1, 100}}), 100000000u);
	CHECK_EQ(client_view(10, 0, {{1, 100}}, 50), 50u);
	CHECK_EQ(client_view(70, 0, {{1, 100}}, 50), 70u);
	// Sequence numbers compare as serial numbers (as every coop seq).
	CHECK_EQ(client_view(100, 0xFFFFFFF0u, {{0xFFFFFFF0u, -10}, {0xFFFFFFF5u, -20}, {2, -30}}), 50u);
}

// Review Focus 1: a fair client gains money without the host beyond the allowance (a dialog payout, a mod's
// give_money). The host refuses it; the balance on the client matches the host's after one answer.
TEST(ledger_gain_refused_then_view_matches_host)
{
	HostSide host;
	host.balance = 1000;
	std::vector<Pending> pending;
	uint32_t acked = 6;

	// The client's game added 60000 RU: the player sees them at once, the change goes to the host.
	pending.push_back({7, 60000});
	CHECK_EQ(client_view(host.balance, acked, pending), 61000u);
	// And spent 100 right after, before the answer came.
	pending.push_back({8, -100});
	CHECK_EQ(client_view(host.balance, acked, pending), 60900u);

	// The host: over the allowance.
	CHECK(host.change(60000, Cause::Script, 0) == Verdict::NoAllowance);
	CHECK_EQ(host.balance, 1000u);
	Writer w;
	write(w, MoneyBalanceMsg{host.balance, 7});
	const std::vector<uint8_t> wire = bytes_of(w);
	Reader r(wire.data(), wire.size());
	MoneyBalanceMsg got;
	REQUIRE(read(r, got));
	forget_acked(pending, got.acked_seq);
	REQUIRE(pending.size() == 1u);
	acked = got.acked_seq;
	// The gain is gone, the spend still waits.
	CHECK_EQ(client_view(got.balance, acked, pending), 900u);

	// The spend arrives and is answered: the view is exactly the host's balance.
	CHECK(host.change(-100, Cause::Script, 0) == Verdict::Applied);
	Writer w2;
	write(w2, MoneyBalanceMsg{host.balance, 8});
	const std::vector<uint8_t> wire2 = bytes_of(w2);
	Reader r2(wire2.data(), wire2.size());
	REQUIRE(read(r2, got));
	forget_acked(pending, got.acked_seq);
	CHECK(pending.empty());
	CHECK_EQ(client_view(got.balance, got.acked_seq, pending), host.balance);
	CHECK_EQ(host.balance, 900u);
}

// Review Focus 2: a host load or a rejoin while changes are on the way. The client drops what it had pending (the
// host's save holds the outcome); its first answer from the new world is exactly the host's balance.
TEST(ledger_client_view_after_reset)
{
	std::vector<Pending> pending = {{11, -500}, {12, 250}};
	pending.clear(); // coop_money reset on SessionReset
	CHECK_EQ(client_view(4321, 12, pending), 4321u);
	CHECK_EQ(client_view(4321, 0, pending), 4321u);
	CHECK_EQ(client_view(0, 0, pending), 0u);
	// An answer that acknowledges more than the client knows keeps nothing.
	std::vector<Pending> old = {{3, -10}, {4, -20}};
	forget_acked(old, 9);
	CHECK(old.empty());
}

TEST(ledger_wire_roundtrip)
{
	const MoneyReq req{0xA1B2C3D4u, -123456789, Cause::Transfer, 5};
	Writer w;
	write(w, req);
	CHECK_EQ(w.size(), size_t(13));
	const std::vector<uint8_t> wire = bytes_of(w);
	Reader r(wire.data(), wire.size());
	MoneyReq got;
	REQUIRE(read(r, got));
	CHECK_EQ(got.seq, req.seq);
	CHECK_EQ(got.delta, req.delta);
	CHECK(got.cause == Cause::Transfer);
	CHECK_EQ(got.ref, 5u);
	CHECK_EQ(r.remaining(), size_t(0));

	for (Cause c : {Cause::Script, Cause::Dialog})
	{
		Writer wc;
		write(wc, MoneyReq{1, 2147483647, c, 0});
		const std::vector<uint8_t> bc = bytes_of(wc);
		Reader rc(bc.data(), bc.size());
		MoneyReq gc;
		REQUIRE(read(rc, gc));
		CHECK(gc.cause == c);
		CHECK_EQ(gc.delta, 2147483647);
	}

	const MoneyBalanceMsg bal{100000000u, 77};
	Writer wb;
	write(wb, bal);
	CHECK_EQ(wb.size(), size_t(8));
	const std::vector<uint8_t> wire_b = bytes_of(wb);
	Reader rb(wire_b.data(), wire_b.size());
	MoneyBalanceMsg got_b;
	REQUIRE(read(rb, got_b));
	CHECK_EQ(got_b.balance, 100000000u);
	CHECK_EQ(got_b.acked_seq, 77u);
}

TEST(ledger_wire_truncated)
{
	Writer w;
	write(w, MoneyReq{9, -1, Cause::Script, 0});
	const std::vector<uint8_t> wire = bytes_of(w);
	Reader cut(wire.data(), 12);
	MoneyReq got;
	CHECK(!read(cut, got));

	// cause = 3 is no cause.
	Writer bad;
	bad.u32(9);
	bad.i32(-1);
	bad.u8(3);
	bad.u32(0);
	const std::vector<uint8_t> wire_bad = bytes_of(bad);
	Reader rb(wire_bad.data(), wire_bad.size());
	CHECK(!read(rb, got));

	Writer wb;
	write(wb, MoneyBalanceMsg{1, 2});
	const std::vector<uint8_t> wire_b = bytes_of(wb);
	Reader cut_b(wire_b.data(), 7);
	MoneyBalanceMsg got_b;
	CHECK(!read(cut_b, got_b));
}
