// Anomaly Coop unit tests: player money on the host (coop_ledger.h; F2 T1, review R4 7). The host owns every player's
// balance; a client sends changes with a cause, the host checks them and answers with the balance it holds.
#include "test_util.h"

#include "coop_ledger.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <map>
#include <string>
#include <vector>

using coop::Reader;
using coop::Writer;
using coop::ledger::Allowance;
using coop::ledger::apply_client_delta;
using coop::ledger::Cause;
using coop::ledger::character_key;
using coop::ledger::check_mechanic;
using coop::ledger::check_transfer;
using coop::ledger::client_view;
using coop::ledger::Decision;
using coop::ledger::forget_acked;
using coop::ledger::host_keeps_own_upgrades;
using coop::ledger::HostBook;
using coop::ledger::judge_upgrade;
using coop::ledger::MechanicCheck;
using coop::ledger::MechanicFacts;
using coop::ledger::MoneyBalanceMsg;
using coop::ledger::MoneyReq;
using coop::ledger::Pending;
using coop::ledger::Policy;
using coop::ledger::Receiver;
using coop::ledger::upgrade_price_ok;
using coop::ledger::UpgradeFacts;
using coop::ledger::UpgradeHolds;
using coop::ledger::UpgradePayment;
using coop::ledger::UpgradeVerdict;
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
	book.start_session({"k300"}); // a character from the save: full allowances (Ruling F2-10)
	const Policy p;
	const Receiver nobody;
	uint32_t balance = 0;
	uint32_t seq = 0;
	auto send = [&](int32_t delta, Cause cause, bool lock, uint64_t now)
	{
		const Decision d = book.on_request(1, "k300", req(++seq, delta, cause), balance, lock, nobody, p, now);
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
	book.start_session({"k300", "k301"}); // characters from the save
	const Policy p;
	const Receiver nobody;
	Decision d = book.on_request(1, "k300", req(41, 50000), 0, false, nobody, p, 0);
	CHECK(d.verdict == Verdict::Applied);
	CHECK_EQ(d.acked, 41u);
	CHECK_EQ(d.gain_script, 50000u);
	CHECK_EQ(d.gain_dialog, 0u);
	book.peer_left(1);
	CHECK_EQ(book.acked(1), 0u);
	// The same character back as peer 2, a new game process numbering from 1.
	d = book.on_request(2, "k300", req(1, 1), 50000, false, nobody, p, 0); // the same moment: no refill either
	CHECK(!d.stale);
	CHECK(d.verdict == Verdict::NoAllowance);
	CHECK_EQ(d.balance, 50000u);
	CHECK_EQ(book.acked(2), 1u);
	// As peer 1 again, the old numbering going on.
	d = book.on_request(1, "k300", req(42, 1), 50000, false, nobody, p, 0);
	CHECK(d.verdict == Verdict::NoAllowance);
	// Another character has his own.
	d = book.on_request(3, "k301", req(1, 50000), 0, false, nobody, p, 0);
	CHECK(d.verdict == Verdict::Applied);
	REQUIRE(book.allowances("k300") != nullptr);
	CHECK(near(book.allowances("k300")->script.tokens, 0));
	// A dialog split is reported by allowance.
	d = book.on_request(3, "k301", req(2, 1000, Cause::Dialog), 50000, true, nobody, p, 0);
	CHECK(d.verdict == Verdict::Applied);
	CHECK_EQ(d.gain_dialog, 1000u);
	CHECK_EQ(d.gain_script, 0u);
	// A new session keeps nothing.
	book.reset();
	CHECK(book.allowances("k300") == nullptr);
	CHECK_EQ(book.acked(2), 0u);
}

TEST(ledger_stale_seq)
{
	HostBook book;
	book.start_session({"k300"});
	const Policy p;
	const Receiver nobody;
	Decision d = book.on_request(1, "k300", req(5, -100), 1000, false, nobody, p, 0);
	CHECK(d.verdict == Verdict::Applied);
	CHECK_EQ(d.balance, 900u);
	// The same change again, an older one: nothing done, the answer says where we are.
	d = book.on_request(1, "k300", req(5, -100), 900, false, nobody, p, 0);
	CHECK(d.stale);
	CHECK_EQ(d.balance, 900u);
	CHECK_EQ(d.acked, 5u);
	d = book.on_request(1, "k300", req(4, 50000), 900, false, nobody, p, 0);
	CHECK(d.stale);
	CHECK_EQ(d.balance, 900u);
	CHECK_EQ(book.acked(1), 5u);
	CHECK(book.allowances("k300") == nullptr); // a spend and a stale gain touch no allowance
	d = book.on_request(1, "k300", req(6, -100), 900, false, nobody, p, 0);
	CHECK(!d.stale);
	CHECK_EQ(d.balance, 800u);
	CHECK_EQ(d.acked, 6u);
	// Refused changes are answered too, and count as answered.
	d = book.on_request(1, "k300", req(7, -5000), 800, false, nobody, p, 0);
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
	const Decision d = book.on_request(1, "k300", req(1, -200, Cause::Transfer, 0), 700, false, host, p, 0);
	CHECK(d.verdict == Verdict::Applied);
	CHECK_EQ(d.balance, 500u);
	CHECK_EQ(d.credit, 200u);
	CHECK(book.allowances("k300") == nullptr);
	const Decision bad = book.on_request(1, "k300", req(2, -200, Cause::Transfer, 9), 500, false, gone, p, 0);
	CHECK(bad.verdict == Verdict::Malformed);
	CHECK_EQ(bad.credit, 0u);
	CHECK_EQ(bad.balance, 500u);
	CHECK_EQ(bad.acked, 2u);
}

// F2 T6b (Ruling F2-19): the host enforces the session's transfer rules, money_transfer and max_money_transfer. Its Lua
// pushes them into the Policy (coop.money_set_rules); a client's own Lua checks them too, but only the host's answer counts.
TEST(ledger_transfer_rules)
{
	Receiver to;
	to.peer = 2;
	to.present = true;
	to.balance = 100;
	uint32_t balance = 5000, credit = 99;

	// Without a rule from the host's Lua: transfers on, no limit but the balance.
	const Policy none;
	CHECK(none.transfer_on);
	CHECK(none.transfer_max == UINT64_MAX);
	CHECK(check_transfer(1, to, -5000, balance, credit, none) == Verdict::Applied);
	CHECK_EQ(balance, 0u);
	CHECK_EQ(credit, 5000u);

	// money_transfer off: nothing moves, whatever the amount.
	Policy off;
	off.transfer_on = false;
	balance = 5000;
	CHECK(check_transfer(1, to, -1, balance, credit, off) == Verdict::TransfersOff);
	CHECK_EQ(balance, 5000u);
	CHECK_EQ(credit, 0u);
	// The form comes first: nobody there is Malformed, a rule cannot say "the receiver is gone".
	Receiver gone = to;
	gone.present = false;
	CHECK(check_transfer(1, gone, -1, balance, credit, off) == Verdict::Malformed);
	CHECK(check_transfer(2, to, -1, balance, credit, off) == Verdict::Malformed);
	CHECK(check_transfer(1, to, 5, balance, credit, off) == Verdict::Malformed);
	// The rule comes before the state: a giver without money is told about the rule.
	balance = 3;
	CHECK(check_transfer(1, to, -50, balance, credit, off) == Verdict::TransfersOff);
	CHECK_EQ(balance, 3u);

	// max_money_transfer: up to the limit, not one RU over.
	Policy lim;
	lim.transfer_max = 1000;
	balance = 5000;
	CHECK(check_transfer(1, to, -1001, balance, credit, lim) == Verdict::OverTransferLimit);
	CHECK_EQ(balance, 5000u);
	CHECK_EQ(credit, 0u);
	CHECK(check_transfer(1, to, INT64_MIN, balance, credit, lim) == Verdict::OverTransferLimit);
	CHECK(check_transfer(1, to, -1000, balance, credit, lim) == Verdict::Applied);
	CHECK_EQ(balance, 4000u);
	CHECK_EQ(credit, 1000u);
	// The limit comes before the balance: 1001 from a giver with 500 is over the limit, not "not enough".
	balance = 500;
	CHECK(check_transfer(1, to, -1001, balance, credit, lim) == Verdict::OverTransferLimit);
	CHECK(check_transfer(1, to, -600, balance, credit, lim) == Verdict::Insufficient);
	// A limit of 0 allows no transfer (the options page lets the host set it).
	Policy zero;
	zero.transfer_max = 0;
	balance = 500;
	CHECK(check_transfer(1, to, -1, balance, credit, zero) == Verdict::OverTransferLimit);
	CHECK_EQ(balance, 500u);

	// Through the book: the change is answered (its number is spent), the allowances are not touched, nothing is credited.
	HostBook book;
	book.start_session({"k310"}); // a character from the save: its first income is paid from full buckets
	const Decision d = book.on_request(1, "k310", req(1, -2000, Cause::Transfer, 2), 5000, false, to, lim, 0);
	CHECK(d.verdict == Verdict::OverTransferLimit);
	CHECK(!d.stale);
	CHECK_EQ(d.acked, 1u);
	CHECK_EQ(d.balance, 5000u);
	CHECK_EQ(d.credit, 0u);
	CHECK(book.allowances("k310") == nullptr);
	const Decision again = book.on_request(1, "k310", req(1, -2000, Cause::Transfer, 2), 5000, false, to, lim, 0);
	CHECK(again.stale);
	const Decision off_d = book.on_request(1, "k310", req(2, -10, Cause::Transfer, 2), 5000, false, to, off, 0);
	CHECK(off_d.verdict == Verdict::TransfersOff);
	CHECK_EQ(off_d.acked, 2u);
	CHECK_EQ(off_d.credit, 0u);
	// The rules are about transfers between players only: the same player spends and gains by himself as before.
	const Decision spend = book.on_request(1, "k310", req(3, -4000, Cause::Script), 5000, false, to, off, 0);
	CHECK(spend.verdict == Verdict::Applied);
	CHECK_EQ(spend.balance, 1000u);
	const Decision gain = book.on_request(1, "k310", req(4, 100, Cause::Script), 1000, false, to, off, 0);
	CHECK(gain.verdict == Verdict::Applied);
}

// F2 T6b: the host's answer says what happened to a change it refused (the client tells its player), and a player who
// was given money gets the giver's name.
TEST(ledger_money_notes)
{
	const Policy p;
	Receiver to;
	to.peer = 2;
	to.present = true;
	to.balance = 100;
	Receiver gone = to;
	gone.present = false;
	HostBook book;
	book.start_session({"k320"});

	// An applied change carries no note.
	const Decision ok = book.on_request(1, "k320", req(1, -100, Cause::Script), 1000, false, to, p, 0);
	CHECK(ok.verdict == Verdict::Applied);
	CHECK(ok.note.kind == coop::ledger::NoteKind::None);
	const Decision gave = book.on_request(1, "k320", req(2, -100, Cause::Transfer, 2), 900, false, to, p, 0);
	CHECK(gave.verdict == Verdict::Applied);
	CHECK(gave.note.kind == coop::ledger::NoteKind::None);

	// A spend the host cannot cover.
	const Decision poor = book.on_request(1, "k320", req(3, -5000, Cause::Script), 800, false, to, p, 0);
	CHECK(poor.verdict == Verdict::Insufficient);
	CHECK(poor.note.kind == coop::ledger::NoteKind::Refused);
	CHECK(poor.note.cause == Cause::Script);
	CHECK(poor.note.verdict == Verdict::Insufficient);
	CHECK_EQ(poor.note.amount, -5000);
	CHECK_EQ(poor.note.peer, 0u);

	// An income over the allowance: the change asked for is told with its sign.
	const Decision rich = book.on_request(1, "k320", req(4, 60000, Cause::Dialog), 800, true, to, p, 0);
	CHECK(rich.verdict == Verdict::Applied); // the first 60000 of a saved character comes out of its dialog bucket
	const Decision over = book.on_request(1, "k320", req(5, 99999, Cause::Script), 800, false, to, p, 0);
	CHECK(over.verdict == Verdict::NoAllowance);
	CHECK(over.note.kind == coop::ledger::NoteKind::Refused);
	CHECK(over.note.verdict == Verdict::NoAllowance);
	CHECK(over.note.cause == Cause::Script);
	CHECK_EQ(over.note.amount, 99999);

	// A refused transfer names the receiver, whatever the reason.
	Policy lim;
	lim.transfer_max = 10;
	const Decision limit = book.on_request(1, "k320", req(6, -11, Cause::Transfer, 2), 800, false, to, lim, 0);
	CHECK(limit.verdict == Verdict::OverTransferLimit);
	CHECK(limit.note.kind == coop::ledger::NoteKind::Refused);
	CHECK(limit.note.cause == Cause::Transfer);
	CHECK(limit.note.verdict == Verdict::OverTransferLimit);
	CHECK_EQ(limit.note.peer, 2u);
	CHECK_EQ(limit.note.amount, -11);
	const Decision nobody = book.on_request(1, "k320", req(7, -5, Cause::Transfer, 9), 800, false, gone, p, 0);
	CHECK(nobody.verdict == Verdict::Malformed);
	CHECK(nobody.note.kind == coop::ledger::NoteKind::Refused); // the player gave to someone who left: he is told
	CHECK_EQ(nobody.note.peer, 9u);

	// A change no honest client sends (zero) is refused without a word; so is a repeat.
	const Decision zero = book.on_request(1, "k320", req(8, 0, Cause::Script), 800, false, to, p, 0);
	CHECK(zero.verdict == Verdict::Malformed);
	CHECK(zero.note.kind == coop::ledger::NoteKind::None);
	const Decision stale = book.on_request(1, "k320", req(3, -5000, Cause::Script), 800, false, to, p, 0);
	CHECK(stale.stale);
	CHECK(stale.note.kind == coop::ledger::NoteKind::None);

	// The receiver of a transfer.
	const coop::ledger::MoneyNote got = coop::ledger::note_received(5, 1234);
	CHECK(got.kind == coop::ledger::NoteKind::Received);
	CHECK_EQ(got.peer, 5u);
	CHECK_EQ(got.amount, 1234);
	// The amount fits the wire: a credit is at most max_money; an absurd one is cut, never wrapped to a negative.
	CHECK_EQ(coop::ledger::note_received(0, 0xFFFFFFFFu).amount, 2147483647);
}

// F2 T6b: a mod that changes the money in a loop must not fill the screen with refusals.
TEST(ledger_notice_gate)
{
	coop::ledger::NoticeGate g; // default: one in three seconds
	CHECK(g.allow(10000));
	CHECK(!g.allow(10001));
	CHECK(!g.allow(12999));
	CHECK(g.allow(13000));
	CHECK(!g.allow(13500));
	CHECK_EQ(g.dropped(), uint64_t(3));
	// A clock that goes back lets the next one through and starts over.
	CHECK(g.allow(5));
	CHECK(!g.allow(6));
	g.reset();
	CHECK_EQ(g.dropped(), uint64_t(0));
	CHECK(g.allow(7));
	coop::ledger::NoticeGate fast(100);
	CHECK(fast.allow(0));
	CHECK(!fast.allow(99));
	CHECK(fast.allow(100));
}

// Ruling F2-10 (review round 2, Important): the client chooses its player key, and the host makes a character for any
// new key. A character made in this session starts with empty allowances and only gets the refills: a new key cannot
// bring a fresh 50 000 + 100 000 to pass on to the main character.
TEST(ledger_new_character_starts_empty)
{
	HostBook book;
	book.start_session({"k300"}); // 300 was in the save; 777 is new
	CHECK(book.from_save("k300"));
	CHECK(!book.from_save("k777"));
	const Policy p;
	const Receiver nobody;
	const uint64_t t0 = 5000000; // well into the session
	Decision d = book.on_request(4, "k777", req(1, 1), 0, false, nobody, p, t0);
	CHECK(d.verdict == Verdict::NoAllowance);
	d = book.on_request(4, "k777", req(2, 1, Cause::Dialog), 0, true, nobody, p, t0);
	CHECK(d.verdict == Verdict::NoAllowance);
	REQUIRE(book.allowances("k777") != nullptr);
	CHECK(book.allowances("k777")->script.started);
	CHECK(book.allowances("k777")->dialog.started);
	// A spend is never limited.
	d = book.on_request(4, "k777", req(3, -1), 10, false, nobody, p, t0);
	CHECK(d.verdict == Verdict::Applied);
	// A minute later: the refills only (10000 script, 20000 dialog), not the bursts.
	d = book.on_request(4, "k777", req(4, 10001), 0, false, nobody, p, t0 + 60000);
	CHECK(d.verdict == Verdict::NoAllowance);
	d = book.on_request(4, "k777", req(5, 10000), 0, false, nobody, p, t0 + 60000);
	CHECK(d.verdict == Verdict::Applied);
	d = book.on_request(4, "k777", req(6, 20001, Cause::Dialog), 0, true, nobody, p, t0 + 60000);
	CHECK(d.verdict == Verdict::NoAllowance);
	d = book.on_request(4, "k777", req(7, 20000, Cause::Dialog), 0, true, nobody, p, t0 + 60000);
	CHECK(d.verdict == Verdict::Applied);
	CHECK_EQ(d.gain_dialog, 20000u);
	// Leaving and joining again with the same key changes nothing.
	book.peer_left(4);
	d = book.on_request(5, "k777", req(1, 1), 0, false, nobody, p, t0 + 60000);
	CHECK(d.verdict == Verdict::NoAllowance);
	// A new session: what the save holds then is "from the save".
	book.start_session({"k300", "k777"});
	d = book.on_request(5, "k777", req(2, 50000), 0, false, nobody, p, t0 + 60000);
	CHECK(d.verdict == Verdict::Applied);
	// Without a list (reset) every character counts as new.
	book.reset();
	CHECK(!book.from_save("k300"));
}

// Ruling F2-10: a returning player's character, in the save when the session started, has its full allowances.
TEST(ledger_saved_character_keeps_burst)
{
	HostBook book;
	book.start_session({"k300", "k301"});
	const Policy p;
	const Receiver nobody;
	Decision d = book.on_request(1, "k300", req(1, 50000), 0, false, nobody, p, 5000000);
	CHECK(d.verdict == Verdict::Applied);
	d = book.on_request(1, "k300", req(2, 100000, Cause::Dialog), 50000, true, nobody, p, 5000000);
	CHECK(d.verdict == Verdict::Applied);
	CHECK_EQ(d.gain_dialog, 100000u);
	d = book.on_request(1, "k300", req(3, 1), 150000, false, nobody, p, 5000000);
	CHECK(d.verdict == Verdict::NoAllowance);
	// The other saved character has his own burst.
	d = book.on_request(2, "k301", req(1, 50000), 0, false, nobody, p, 5000000);
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
	book.start_session({"k300", "k301"});

	// Two players, two characters: the money moves.
	Balances two;
	two.character_of = {{1, 300}, {2, 301}};
	two.money = {{300, 1000}, {301, 500}};
	Receiver to{2, true, two.get(2)};
	Decision d = book.on_request(1, "k300", req(1, -400, Cause::Transfer, 2), two.get(1), false, to, p, 0);
	REQUIRE(d.verdict == Verdict::Applied);
	settle_transfer(two, 1, d.balance, 2, d.credit);
	CHECK_EQ(two.money[300], 600u);
	CHECK_EQ(two.money[301], 900u);

	// Two connections on one character: neither printed (1400) nor lost (600).
	Balances one;
	one.character_of = {{1, 300}, {2, 300}};
	one.money = {{300, 1000}};
	Receiver self{2, true, one.get(2)};
	d = book.on_request(1, "k300", req(2, -400, Cause::Transfer, 2), one.get(1), false, self, p, 0);
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
	CHECK_EQ(wb.size(), size_t(19)); // F2 T6b: the 8 bytes of before and a note (kind, cause, verdict, peer, amount)
	CHECK_EQ(wb.size(), coop::ledger::kMoneyBalanceSize);
	const std::vector<uint8_t> wire_b = bytes_of(wb);
	Reader rb(wire_b.data(), wire_b.size());
	MoneyBalanceMsg got_b;
	REQUIRE(read(rb, got_b));
	CHECK_EQ(got_b.balance, 100000000u);
	CHECK_EQ(got_b.acked_seq, 77u);
	CHECK(got_b.note.kind == coop::ledger::NoteKind::None);
}

// F2 T6b: the note of a balance, both kinds, and what a reader refuses.
TEST(ledger_wire_note)
{
	using coop::ledger::MoneyNote;
	using coop::ledger::NoteKind;
	MoneyBalanceMsg given{1500u, 12};
	given.note.kind = NoteKind::Received;
	given.note.peer = 3;
	given.note.amount = 750;
	Writer w;
	write(w, given);
	CHECK_EQ(w.size(), coop::ledger::kMoneyBalanceSize);
	std::vector<uint8_t> wire = bytes_of(w);
	Reader r(wire.data(), wire.size());
	MoneyBalanceMsg got;
	REQUIRE(read(r, got));
	CHECK_EQ(r.remaining(), size_t(0));
	CHECK_EQ(got.balance, 1500u);
	CHECK_EQ(got.acked_seq, 12u);
	CHECK(got.note.kind == NoteKind::Received);
	CHECK_EQ(got.note.peer, 3u);
	CHECK_EQ(got.note.amount, 750);

	MoneyBalanceMsg refused{20u, 13};
	refused.note.kind = NoteKind::Refused;
	refused.note.cause = Cause::Transfer;
	refused.note.verdict = Verdict::OverTransferLimit;
	refused.note.peer = 4;
	refused.note.amount = -2147483647 - 1;
	Writer wr;
	write(wr, refused);
	wire = bytes_of(wr);
	Reader rr(wire.data(), wire.size());
	REQUIRE(read(rr, got));
	CHECK(got.note.kind == NoteKind::Refused);
	CHECK(got.note.cause == Cause::Transfer);
	CHECK(got.note.verdict == Verdict::OverTransferLimit);
	CHECK_EQ(got.note.peer, 4u);
	CHECK_EQ(got.note.amount, -2147483647 - 1);

	// Every verdict the host can name travels.
	for (uint8_t v = 0; v < coop::ledger::kVerdictCount; ++v)
	{
		MoneyBalanceMsg m{1u, 1};
		m.note.kind = NoteKind::Refused;
		m.note.verdict = Verdict(v);
		Writer wv;
		write(wv, m);
		const std::vector<uint8_t> bv = bytes_of(wv);
		Reader rv(bv.data(), bv.size());
		REQUIRE(read(rv, got));
		CHECK(got.note.verdict == Verdict(v));
	}

	// Truncated, or a byte that names nothing: refused. The first 8 bytes alone are not a balance any more.
	const std::vector<uint8_t> full = bytes_of(wr);
	for (size_t cut : {size_t(0), size_t(8), size_t(10), size_t(18)})
	{
		Reader rc(full.data(), cut);
		CHECK(!read(rc, got));
	}
	const uint8_t no_kind = 3, no_cause = 3, no_verdict = coop::ledger::kVerdictCount;
	for (const auto& bad : {std::make_pair(size_t(8), no_kind), std::make_pair(size_t(9), no_cause),
	         std::make_pair(size_t(10), no_verdict)})
	{
		std::vector<uint8_t> broken = full;
		broken[bad.first] = bad.second;
		Reader rb(broken.data(), broken.size());
		CHECK(!read(rb, got));
	}
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
	Reader cut_c(wire_b.data(), wire_b.size() - 1);
	CHECK(!read(cut_c, got_b));
}

// Ruling F2-13 (review round 3, Important): the allowances refill only while the character is in the game. Leaving
// freezes them; the first change after coming back starts the clock again without paying for the pause. Else a pool
// of alts, each back after 5 minutes with full buckets, would print millions an hour.
TEST(ledger_no_refill_while_offline)
{
	HostBook book;
	book.start_session({"k300"}); // from the save: this holds for them as well
	const Policy p;
	const Receiver nobody;
	Decision d = book.on_request(1, "k300", req(1, 50000), 0, false, nobody, p, 0);
	CHECK(d.verdict == Verdict::Applied); // the script burst used up
	d = book.on_request(1, "k300", req(2, 30000, Cause::Dialog), 50000, true, nobody, p, 0);
	CHECK(d.verdict == Verdict::Applied); // 70000 left in the dialog allowance
	book.peer_left(1);
	// Ten minutes away, back as another connection: no more than he had when he left.
	const uint64_t back = 600000;
	d = book.on_request(2, "k300", req(1, 1), 80000, false, nobody, p, back);
	CHECK(d.verdict == Verdict::NoAllowance);
	d = book.on_request(2, "k300", req(2, 70001, Cause::Dialog), 80000, true, nobody, p, back);
	CHECK(d.verdict == Verdict::NoAllowance);
	d = book.on_request(2, "k300", req(3, 70000, Cause::Dialog), 80000, true, nobody, p, back);
	CHECK(d.verdict == Verdict::Applied);
	// A minute in the game: one refill of each.
	d = book.on_request(2, "k300", req(4, 10001), 150000, false, nobody, p, back + 60000);
	CHECK(d.verdict == Verdict::NoAllowance);
	d = book.on_request(2, "k300", req(5, 10000), 150000, false, nobody, p, back + 60000);
	CHECK(d.verdict == Verdict::Applied);
	d = book.on_request(2, "k300", req(6, 20000, Cause::Dialog), 160000, true, nobody, p, back + 60000);
	CHECK(d.verdict == Verdict::Applied);
	CHECK_EQ(d.gain_dialog, 20000u);
	// Away again, with only spends in between: still frozen.
	book.peer_left(2);
	d = book.on_request(3, "k300", req(1, -5), 180000, false, nobody, p, back + 3600000);
	CHECK(d.verdict == Verdict::Applied);
	d = book.on_request(3, "k300", req(2, 1), 179995, false, nobody, p, back + 3600000 + 30000);
	CHECK(d.verdict == Verdict::NoAllowance);
}

// Ruling F2-20: the refill clock of a character runs from the moment it is in the game (its join is complete,
// HostBook::peer_online), not from its first income. Before: the buckets of a new character were made at its first
// income with 0 tokens, so that first income was always refused in full, however long the player had been playing.
TEST(ledger_new_character_refills_from_join)
{
	HostBook book;
	book.start_session({"k300"}); // "k777" is made in this session
	const Policy p;
	const Receiver nobody;
	const uint64_t joined = 5000000; // well into the session
	book.peer_online(4, "k777", joined);
	REQUIRE(book.allowances("k777") != nullptr); // the buckets exist from the join: empty, clock running
	CHECK(book.allowances("k777")->script.started);
	CHECK(book.allowances("k777")->dialog.started);
	CHECK(near(book.allowances("k777")->script.tokens, 0));
	CHECK_EQ(book.allowances("k777")->script.at, joined);
	// At the join itself there is nothing yet (not the burst of a character from the save).
	Decision d = book.on_request(4, "k777", req(1, 1), 0, false, nobody, p, joined);
	CHECK(d.verdict == Verdict::NoAllowance);
	// A minute in the game, first income (corpse money): the refill of that minute, 10 000 and not a RU more.
	d = book.on_request(4, "k777", req(2, 10001), 0, false, nobody, p, joined + 60000);
	CHECK(d.verdict == Verdict::NoAllowance);
	d = book.on_request(4, "k777", req(3, 10000), 0, false, nobody, p, joined + 60000);
	CHECK(d.verdict == Verdict::Applied);
	CHECK_EQ(d.gain_script, 10000u);
	d = book.on_request(4, "k777", req(4, 1), 10000, false, nobody, p, joined + 60000);
	CHECK(d.verdict == Verdict::NoAllowance);
	// The dialog bucket ran from the same moment: 20 000 after one minute, and the script bucket pays the rest of a
	// payout (10 000 more): 30 000 in all (a fresh character, another join).
	book.peer_online(5, "k778", joined);
	d = book.on_request(5, "k778", req(1, 30001, Cause::Dialog), 0, true, nobody, p, joined + 60000);
	CHECK(d.verdict == Verdict::NoAllowance);
	d = book.on_request(5, "k778", req(2, 30000, Cause::Dialog), 0, true, nobody, p, joined + 60000);
	CHECK(d.verdict == Verdict::Applied);
	CHECK_EQ(d.gain_dialog, 20000u);
	CHECK_EQ(d.gain_script, 10000u);
	// The refill is capped by the bucket: a long time in the game gives the burst, no more.
	book.peer_online(6, "k779", joined);
	d = book.on_request(6, "k779", req(1, 50001), 0, false, nobody, p, joined + 3600000);
	CHECK(d.verdict == Verdict::NoAllowance);
	d = book.on_request(6, "k779", req(2, 50000), 0, false, nobody, p, joined + 3600000);
	CHECK(d.verdict == Verdict::Applied);
	// A character from the save keeps its full burst when it first appears: the join does not empty it.
	book.peer_online(1, "k300", joined);
	d = book.on_request(1, "k300", req(1, 50001), 0, false, nobody, p, joined);
	CHECK(d.verdict == Verdict::NoAllowance);
	d = book.on_request(1, "k300", req(2, 50000), 0, false, nobody, p, joined);
	CHECK(d.verdict == Verdict::Applied);
	d = book.on_request(1, "k300", req(3, 100000, Cause::Dialog), 50000, true, nobody, p, joined);
	CHECK(d.verdict == Verdict::Applied);
	CHECK_EQ(d.gain_dialog, 100000u);
	// Online again (a repeat, the character was not away) neither refills nor empties anything: a second of the game
	// is a sixtieth of a minute's refill (166.67 RU), the clock was not restarted.
	book.peer_online(1, "k300", joined + 1000);
	d = book.on_request(1, "k300", req(4, 166), 150000, false, nobody, p, joined + 1000);
	CHECK(d.verdict == Verdict::Applied);
	d = book.on_request(1, "k300", req(5, 1), 150166, false, nobody, p, joined + 1000);
	CHECK(d.verdict == Verdict::NoAllowance);
}

// Ruling F2-20: the same for a return. Away, the buckets are frozen; the clock restarts at the join, so the time in the
// game before the first income is credited and the time away is not.
TEST(ledger_return_refills_from_join_not_first_income)
{
	HostBook book;
	book.start_session({"k300"}); // from the save
	const Policy p;
	const Receiver nobody;
	book.peer_online(1, "k300", 0);
	Decision d = book.on_request(1, "k300", req(1, 50000), 0, false, nobody, p, 0);
	CHECK(d.verdict == Verdict::Applied); // the script burst used up
	d = book.on_request(1, "k300", req(2, 30000, Cause::Dialog), 50000, true, nobody, p, 0);
	CHECK(d.verdict == Verdict::Applied); // 70000 left in the dialog bucket
	book.peer_left(1);
	// Ten minutes away; back as another connection; one minute in the game before the first income.
	const uint64_t back = 600000;
	book.peer_online(2, "k300", back);
	REQUIRE(book.allowances("k300") != nullptr);
	CHECK_EQ(book.allowances("k300")->script.at, back);
	CHECK(near(book.allowances("k300")->script.tokens, 0)); // the frozen tokens, nothing for the 10 minutes away
	CHECK(near(book.allowances("k300")->dialog.tokens, 70000));
	d = book.on_request(2, "k300", req(1, 10001), 80000, false, nobody, p, back + 60000);
	CHECK(d.verdict == Verdict::NoAllowance); // +1 minute of refill (10 000), not +10 minutes (capped at 50 000)
	d = book.on_request(2, "k300", req(2, 10000), 80000, false, nobody, p, back + 60000);
	CHECK(d.verdict == Verdict::Applied);
	d = book.on_request(2, "k300", req(3, 90001, Cause::Dialog), 90000, true, nobody, p, back + 60000);
	CHECK(d.verdict == Verdict::NoAllowance); // 70 000 frozen + 20 000 of the minute = 90 000
	d = book.on_request(2, "k300", req(4, 90000, Cause::Dialog), 90000, true, nobody, p, back + 60000);
	CHECK(d.verdict == Verdict::Applied);
	CHECK_EQ(d.gain_dialog, 90000u);

	// A new character that joined and left without a single request is frozen too (the mapping comes from the join):
	// its time away is not credited when it is back.
	book.peer_online(7, "k777", 1000000);
	book.peer_left(7);
	book.peer_online(8, "k777", 1000000 + 600000);
	d = book.on_request(8, "k777", req(1, 1), 0, false, nobody, p, 1000000 + 600000);
	CHECK(d.verdict == Verdict::NoAllowance);
	d = book.on_request(8, "k777", req(2, 10000), 0, false, nobody, p, 1000000 + 660000);
	CHECK(d.verdict == Verdict::Applied); // one minute in the game, not eleven
	d = book.on_request(8, "k777", req(3, 1), 10000, false, nobody, p, 1000000 + 660000);
	CHECK(d.verdict == Verdict::NoAllowance);

	// A saved character that never had an income comes back with its full burst (still unspent).
	book.start_session({"k301-saved"});
	book.peer_online(10, "k301-saved", 2600000);
	book.peer_left(10);
	book.peer_online(11, "k301-saved", 3200000);
	d = book.on_request(11, "k301-saved", req(1, 50000), 0, false, nobody, p, 3200000);
	CHECK(d.verdict == Verdict::Applied);
}

// Ruling F2-13: a request refused by its form (a change of nothing, an unknown cause) and a spend touch no allowance
// and start no clock: an alt cannot start its refill with a cheap request and come back later to a full bucket.
// (A connection that was never marked online, HostBook::peer_online: the fallback of F2-20. A marked one has its
// buckets from the join, see ledger_new_character_refills_from_join.)
TEST(ledger_malformed_does_not_start_clock)
{
	HostBook book;
	book.start_session({"k300"}); // "k777" is new
	const Policy p;
	const Receiver nobody;
	const uint64_t t0 = 1000000;
	Decision d = book.on_request(1, "k777", req(1, 0), 100, false, nobody, p, t0);
	CHECK(d.verdict == Verdict::Malformed);
	d = book.on_request(1, "k777", req(2, 5, static_cast<Cause>(7)), 100, false, nobody, p, t0);
	CHECK(d.verdict == Verdict::Malformed);
	d = book.on_request(1, "k777", req(3, -10), 100, false, nobody, p, t0);
	CHECK(d.verdict == Verdict::Applied);
	CHECK(book.allowances("k777") == nullptr);
	// Ten minutes in the game later: the clock starts at the first gain, empty.
	d = book.on_request(1, "k777", req(4, 1), 90, false, nobody, p, t0 + 600000);
	CHECK(d.verdict == Verdict::NoAllowance);
	REQUIRE(book.allowances("k777") != nullptr);
	d = book.on_request(1, "k777", req(5, 10000), 90, false, nobody, p, t0 + 660000);
	CHECK(d.verdict == Verdict::Applied);
	d = book.on_request(1, "k777", req(6, 1), 10090, false, nobody, p, t0 + 660000);
	CHECK(d.verdict == Verdict::NoAllowance);
	// A malformed request of a character from the save does not use his burst either.
	d = book.on_request(2, "k300", req(1, 0), 0, false, nobody, p, t0);
	CHECK(d.verdict == Verdict::Malformed);
	CHECK(book.allowances("k300") == nullptr);
}

// Ruling F2-13 (minor): "from the save" is the player key the character is bound to (the digest on the "key" line of
// its custom data, as coop_join finds it), not its entity id: an id freed and given to a new character later says
// nothing about who plays it.
TEST(ledger_from_save_by_key_not_id)
{
	const std::string a(64, 'a'), b(64, 'b');
	const std::string ini_a = "[coop]\nkey = " + a + "\nnick = Al\n";
	const std::string ini_b = "[coop]\nkey=" + b + "\nnick = " + a + "\n"; // another player's digest as a nick
	CHECK_EQ(character_key(ini_a), a);
	CHECK_EQ(character_key(ini_b), b);
	CHECK(character_key("[coop]\nnick = Al\n").empty());
	CHECK(character_key("").empty());
	// A save from before R1 I1 keeps the key itself: its digest, as coop_join migrates it.
	coop::PlayerKey key{};
	for (size_t i = 0; i < key.size(); ++i)
		key[i] = uint8_t(i * 7 + 1);
	static const char* hex = "0123456789abcdef";
	std::string raw;
	for (uint8_t byte : key)
	{
		raw += hex[byte >> 4];
		raw += hex[byte & 15];
	}
	std::string digest;
	REQUIRE(coop::key_digest_hex(key, digest));
	CHECK_EQ(character_key("[coop]\nkey = " + raw + "\n"), digest);

	// Character 300 was player A's when the session started; later id 300 belongs to a new character of player B.
	HostBook book;
	book.start_session({character_key(ini_a)});
	const Policy p;
	const Receiver nobody;
	Decision d = book.on_request(1, character_key(ini_b), req(1, 1), 0, false, nobody, p, 0);
	CHECK(d.verdict == Verdict::NoAllowance);
	d = book.on_request(2, character_key(ini_a), req(1, 50000), 0, false, nobody, p, 0);
	CHECK(d.verdict == Verdict::Applied);
}

// ---------------------------------------------------------------- F2 T5: upgrades at a mechanic

// The least a mechanic takes: paid >= floor(cost x upgrade_min_percent).
TEST(ledger_upgrade_price)
{
	// The brief's figures: 2.21 = 1.7 (the lowest stock mech_discount) x 1.3 (the lowest eco `upgrade`).
	CHECK(upgrade_price_ok(2210, 1000, 2.21f));
	CHECK(!upgrade_price_ok(2209, 1000, 2.21f));
	CHECK(upgrade_price_ok(0, 0, 2.21f));
	// What the stock Lua charges at the cheapest mechanic (floor(cost x 1.7 x 1.3) in doubles) passes and one RU less
	// does not, also where the float 2.21f (2.2100000381) would ask for one RU more: 263219 x 2.21 = 581713.99.
	for (uint32_t cost : {1u, 7u, 99u, 100u, 4840u, 12345u, 99999u, 263219u, 1000019u, 1000000000u})
	{
		const uint32_t lua_price = uint32_t(std::floor(double(cost) * (1.7 * 1.3)));
		CHECK(upgrade_price_ok(lua_price, cost, 2.21f));
		CHECK(!upgrade_price_ok(lua_price - 1, cost, 2.21f));
	}
	// A dearer mechanic (mech_discount 2.2 x eco 2.0) pays more: still fine.
	CHECK(upgrade_price_ok(4400, 1000, 2.21f));
	// Settings: 0 takes anything; a broken value (NaN, infinite, below 0) refuses (coop_money never passes one).
	CHECK(upgrade_price_ok(0, 1000, 0.f));
	CHECK(!upgrade_price_ok(1000000, 1000, std::nanf("")));
	CHECK(!upgrade_price_ok(1000000, 1000, -1.f));
	// No overflow at the largest cost.
	CHECK(!upgrade_price_ok(0xFFFFFFFFu, 0xFFFFFFFFu, 100.f));
	CHECK(upgrade_price_ok(0xFFFFFFFFu, 0xFFFFFFFFu, 1.f));
	CHECK(!upgrade_price_ok(0, 0, std::numeric_limits<float>::infinity()));
	CHECK(!upgrade_price_ok(0xFFFFFFFFu, 1, std::numeric_limits<float>::infinity()));
}

namespace
{
// An honest upgrade at the cheapest mechanic: cost 1000, paid 2210, balance 5000, 2 m away.
UpgradeFacts honest_upgrade()
{
	UpgradeFacts f;
	f.mechanic_named = true;
	f.mechanic_ok = true;
	f.distance = 2.f;
	f.reach = 6.f;
	f.paid = 2210;
	f.cost = 1000;
	f.cost_known = true;
	f.min_percent = 2.21f;
	f.balance = 5000;
	return f;
}
} // namespace

// The host's checks, in the brief's order: a mechanic, within reach, paid enough, has the money.
TEST(ledger_upgrade_judge)
{
	CHECK(judge_upgrade(honest_upgrade()) == UpgradeVerdict::Ok);

	UpgradeFacts f = honest_upgrade();
	f.mechanic_ok = false; // not a live stalker, not the NPC whose talk lock he holds, no mechanic settings
	f.distance = 100.f;
	f.paid = 0;
	CHECK(judge_upgrade(f) == UpgradeVerdict::NoMechanic);

	f = honest_upgrade();
	f.distance = 6.5f;
	f.paid = 0;
	CHECK(judge_upgrade(f) == UpgradeVerdict::TooFar);
	f.distance = 6.f; // at reach exactly
	CHECK(judge_upgrade(f) == UpgradeVerdict::Underpaid);
	f.distance = std::nanf(""); // a broken position is never near
	CHECK(judge_upgrade(f) == UpgradeVerdict::TooFar);

	f = honest_upgrade();
	f.paid = 2209;
	CHECK(judge_upgrade(f) == UpgradeVerdict::Underpaid);

	f = honest_upgrade();
	f.balance = 2209; // paid on the client, the host's balance does not cover it
	CHECK(judge_upgrade(f) == UpgradeVerdict::Insufficient);
	f.balance = 2210;
	CHECK(judge_upgrade(f) == UpgradeVerdict::Ok);

	// No mechanic named: an upgrade a script installed. Refused unless the host allows them (scripted_upgrades).
	f = honest_upgrade();
	f.mechanic_named = false;
	f.mechanic_ok = false;
	f.distance = 1000.f;
	f.paid = 0;
	CHECK(judge_upgrade(f) == UpgradeVerdict::Scripted);
	f.scripted_allowed = true;
	CHECK(judge_upgrade(f) == UpgradeVerdict::Ok); // no price for a script's upgrade
	f.paid = 6000; // whatever it paid must be there
	CHECK(judge_upgrade(f) == UpgradeVerdict::Insufficient);
}

// Msg::ReqItemEvent ends with the payment (F2 T5): u16 mechanic, u32 paid.
TEST(ledger_upgrade_payment_wire)
{
	Writer w;
	write(w, UpgradePayment{1234, 0xA1B2C3D4u});
	CHECK_EQ(w.size(), coop::ledger::kUpgradePaymentSize);
	CHECK_EQ(w.size(), size_t(6));
	const std::vector<uint8_t> wire = bytes_of(w);
	Reader r(wire.data(), wire.size());
	UpgradePayment got;
	REQUIRE(read(r, got));
	CHECK_EQ(got.mechanic, 1234u);
	CHECK_EQ(got.paid, 0xA1B2C3D4u);
	CHECK_EQ(r.remaining(), size_t(0));

	const UpgradePayment none;
	CHECK_EQ(none.mechanic, 0xFFFFu); // a script's upgrade
	CHECK_EQ(none.paid, 0u);

	Reader cut(wire.data(), 5);
	UpgradePayment partial;
	CHECK(!read(cut, partial));
}

// T1 concern 3: the upgrade's price is spent on the client inside a ClientSpendScope and sent with the upgrade, not as
// a ReqMoney. The client counts it (a hold) until the host answers that request; the host answers first, then sends
// the balance. So a MoneyBalance that left the host before it charged the upgrade never shows the money from before
// the payment, and the view after the answer is exactly the host's.
TEST(ledger_upgrade_hold_keeps_paid_view)
{
	const uint32_t max_money = Policy().max_money;
	std::vector<Pending> pending;
	UpgradeHolds holds;
	uint32_t host_balance = 5000, acked = 3;

	// Accepted: the player pays 2210 at the mechanic, the actor shows 2790.
	holds.hold(1, 2210);
	CHECK_EQ(holds.sum(), uint64_t(2210));
	// A MoneyBalance the host sent before it got the upgrade (the answer to an older change).
	CHECK_EQ(client_view(host_balance, acked, pending, max_money, holds.sum()), 2790u);
	CHECK_EQ(client_view(host_balance, acked, pending), 5000u); // without the hold: the old sum for a moment
	// A change of the client meanwhile counts on top.
	pending.push_back({4, -100});
	CHECK_EQ(client_view(host_balance, acked, pending, max_money, holds.sum()), 2690u);
	// The host answers the upgrade (ReqResult): the hold goes, nothing is shown yet ...
	CHECK(holds.release(1));
	CHECK(!holds.release(1)); // once
	// ... then the balance after the charge and the change.
	host_balance = 5000 - 2210 - 100;
	forget_acked(pending, 4);
	acked = 4;
	CHECK_EQ(client_view(host_balance, acked, pending, max_money, holds.sum()), 2690u);

	// Refused (underpaid, too far, ...): the answer releases the hold, the unchanged balance follows it.
	holds.hold(2, 500);
	CHECK_EQ(client_view(host_balance, acked, pending, max_money, holds.sum()), 2190u);
	CHECK(holds.release(2));
	CHECK_EQ(client_view(host_balance, acked, pending, max_money, holds.sum()), 2690u);

	// Never below zero.
	holds.hold(3, 9000);
	CHECK_EQ(client_view(host_balance, acked, pending, max_money, holds.sum()), 0u);
	holds.clear();
	CHECK_EQ(holds.sum(), uint64_t(0));
	CHECK_EQ(holds.size(), size_t(0));
}

// Bounded: a client that never gets answers keeps at most kMax holds (the oldest goes first).
TEST(ledger_upgrade_holds_bounded)
{
	UpgradeHolds holds;
	for (uint32_t key = 1; key <= uint32_t(UpgradeHolds::kMax) + 6; ++key)
		holds.hold(key, 10);
	CHECK_EQ(holds.size(), UpgradeHolds::kMax);
	CHECK_EQ(holds.sum(), uint64_t(UpgradeHolds::kMax) * 10u);
	CHECK(!holds.release(1)); // dropped
	CHECK(holds.release(uint32_t(UpgradeHolds::kMax) + 6));
	CHECK_EQ(holds.size(), UpgradeHolds::kMax - 1);
	// No key and no amount hold nothing.
	holds.hold(0, 100);
	holds.hold(1000, 0);
	CHECK_EQ(holds.size(), UpgradeHolds::kMax - 1);
	// The largest amounts add up without overflow.
	UpgradeHolds big;
	big.hold(1, 0xFFFFFFFFu);
	big.hold(2, 0xFFFFFFFFu);
	CHECK_EQ(big.sum(), uint64_t(0xFFFFFFFFu) * 2u);
	CHECK_EQ(client_view(100, 0, {}, Policy().max_money, big.sum()), 0u);
}

// ---------------------------------------------------------------- F2 T5 fix round 1 (review)

// Review 2: the economy slider `upgrade` (ui_options.script) starts at 1.0, so the cheapest honest stock price is the
// lowest mech_discount 1.7 x 1.0; the host's floor is 1.70 x cost.
TEST(ledger_upgrade_floor_stock)
{
	CHECK(upgrade_price_ok(1700, 1000, 1.7f));
	CHECK(!upgrade_price_ok(1699, 1000, 1.7f));
	for (uint32_t cost : {1u, 99u, 4840u, 263219u, 1000019u})
	{
		const uint32_t lua_price = uint32_t(std::floor(double(cost) * (1.7 * 1.0)));
		CHECK(upgrade_price_ok(lua_price, cost, 1.7f));
		CHECK(!upgrade_price_ok(lua_price - 1, cost, 1.7f));
	}
}

// Review 4: a named mechanic and an upgrade whose cost the host cannot read is refused, not priced at 0.
TEST(ledger_upgrade_unknown_cost)
{
	UpgradeFacts f = honest_upgrade();
	f.cost_known = false;
	f.cost = 0;
	f.paid = 0;
	CHECK(judge_upgrade(f) == UpgradeVerdict::UnknownCost);
	f.paid = 1000000; // paying more changes nothing
	CHECK(judge_upgrade(f) == UpgradeVerdict::UnknownCost);
	// After the mechanic and the reach, before the price.
	f.distance = 100.f;
	CHECK(judge_upgrade(f) == UpgradeVerdict::TooFar);
	f = honest_upgrade();
	f.cost_known = false;
	f.mechanic_ok = false;
	CHECK(judge_upgrade(f) == UpgradeVerdict::NoMechanic);
	// A script's upgrade has no price: its cost is not needed.
	f = honest_upgrade();
	f.mechanic_named = false;
	f.mechanic_ok = false;
	f.scripted_allowed = true;
	f.cost_known = false;
	CHECK(judge_upgrade(f) == UpgradeVerdict::Ok);
	// A cost of 0 that is known is a free upgrade.
	f = honest_upgrade();
	f.cost = 0;
	f.paid = 0;
	CHECK(judge_upgrade(f) == UpgradeVerdict::Ok);
}

namespace
{
// The Forester (m_lesnik): a real mechanic (dm_init_mechanic) of class m_trader (AI_TRD_S, CAI_Trader), not a stalker.
MechanicFacts forester()
{
	MechanicFacts m;
	m.talk_lock = true;
	m.inventory_owner = true; // CAI_Trader is a CInventoryOwner
	m.alive = true;
	m.player = false;
	m.listed = true; // [m_lesnik] and [m_lesnik_upgr] in misc\stalkers_upgrade_info.ltx
	return m;
}
} // namespace

// Review 3: a mechanic is any live NPC with an inventory the player talks to and the mechanics' settings name, a trader
// class as well as a stalker.
TEST(ledger_upgrade_trader_mechanic)
{
	CHECK(check_mechanic(forester()) == MechanicCheck::Ok);
	MechanicFacts m = forester();
	m.talk_lock = false;
	CHECK(check_mechanic(m) == MechanicCheck::NotHisTalk);
	m = forester();
	m.alive = false;
	CHECK(check_mechanic(m) == MechanicCheck::NotAlive);
	m = forester();
	m.inventory_owner = false; // a monster, a physics object
	CHECK(check_mechanic(m) == MechanicCheck::NotAlive);
	m = forester();
	m.listed = false; // an ordinary trader
	CHECK(check_mechanic(m) == MechanicCheck::NotMechanic);
	m = forester();
	m.player = true; // another player's character never sells upgrades
	CHECK(check_mechanic(m) == MechanicCheck::NotMechanic);
	// The talk comes first: nothing else about an NPC he does not talk to is looked at.
	m = MechanicFacts();
	CHECK(check_mechanic(m) == MechanicCheck::NotHisTalk);
}

namespace
{
// The item layer's state of an item (ItemData): the fields the rule reads.
struct OwnerState
{
	bool has_upgrades = false;
	std::vector<std::string> upgrades;
};

// The host's copy of a player's item as the engine keeps it: an apply installs what a state lists and it lacks (it
// never removes one), and its price is the section's cost plus each installed upgrade's (CInventoryItem::Cost after
// install_upgrade_impl), which a trade on the host pays.
struct HostCopy
{
	uint32_t base = 1000;
	std::map<std::string, uint32_t> costs = {{"up_a", 500}, {"up_b", 4840}};
	std::vector<std::string> installed = {"up_a"};

	void apply(const OwnerState& s)
	{
		if (!s.has_upgrades)
			return;
		for (const std::string& u : s.upgrades)
			if (std::find(installed.begin(), installed.end(), u) == installed.end())
				installed.push_back(u);
	}
	uint32_t price() const
	{
		uint32_t p = base;
		for (const std::string& u : installed)
			p += costs.at(u);
		return p;
	}
};
} // namespace

// Review 1: an ItemState with an upgrade the host did not sell (up_b) changes neither the host's copy nor its price.
TEST(ledger_owner_state_brings_no_upgrade)
{
	HostCopy host;
	const uint32_t before = host.price();
	OwnerState state;
	state.has_upgrades = true;
	state.upgrades = {"up_a", "up_b"};

	HostCopy taken = host; // what the host did before: the owner's list onto its copy
	taken.apply(state);
	CHECK_EQ(taken.price(), before + 4840u);

	host_keeps_own_upgrades(state);
	CHECK(!state.has_upgrades);
	CHECK(state.upgrades.empty());
	host.apply(state);
	CHECK_EQ(host.installed.size(), size_t(1));
	CHECK_EQ(host.price(), before);

	// A purchase the host accepted (judge_upgrade Ok) is installed by the host itself: then the price has it.
	CHECK(judge_upgrade(honest_upgrade()) == UpgradeVerdict::Ok);
	OwnerState sold;
	sold.has_upgrades = true;
	sold.upgrades = {"up_b"};
	host.apply(sold);
	CHECK_EQ(host.price(), before + 4840u);
}
