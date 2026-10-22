// Anomaly Coop unit tests: player money on the host (coop_ledger.h; F2 T1, review R4 7). The host owns every player's
// balance; a client sends changes with a cause, the host checks them and answers with the balance it holds.
#include "test_util.h"

#include "coop_ledger.h"

#include <vector>

using coop::Reader;
using coop::Writer;
using coop::ledger::Allowance;
using coop::ledger::apply_client_delta;
using coop::ledger::Cause;
using coop::ledger::client_view;
using coop::ledger::forget_acked;
using coop::ledger::MoneyBalanceMsg;
using coop::ledger::MoneyReq;
using coop::ledger::Pending;
using coop::ledger::Policy;
using coop::ledger::Verdict;

namespace
{
// One player's state on the host, as coop_money keeps it.
struct HostSide
{
	uint32_t balance = 0;
	uint32_t dialog_gained = 0;
	Allowance script;
	Policy policy;

	Verdict change(int64_t delta, Cause cause, uint64_t now, bool dialog_lock = false)
	{
		return apply_client_delta(balance, delta, cause, dialog_lock, dialog_gained, script, policy, now);
	}
};

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
	CHECK_EQ(h.dialog_gained, 0u);
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
	// The talk lock is held: a dialog pays up to the cap per lock without touching the allowance.
	HostSide h;
	CHECK_EQ(h.policy.dialog_gain_cap, 100000u);
	CHECK(h.change(100000, Cause::Dialog, 0, true) == Verdict::Applied);
	CHECK_EQ(h.dialog_gained, 100000u);
	CHECK_EQ(h.balance, 100000u);
	CHECK(!h.script.started);
	// The next RU comes out of the script allowance.
	CHECK(h.change(1, Cause::Dialog, 0, true) == Verdict::Applied);
	CHECK_EQ(h.dialog_gained, 100000u);
	CHECK(h.script.started);
	CHECK(h.script.tokens > 49998.5 && h.script.tokens < 49999.5);
	CHECK_EQ(h.balance, 100001u);

	// Part of a gain fits under the cap: the rest comes out of the allowance, or nothing happens.
	HostSide part;
	CHECK(part.change(90000, Cause::Dialog, 0, true) == Verdict::Applied);
	CHECK(part.change(60001, Cause::Dialog, 0, true) == Verdict::NoAllowance); // 10000 + 50001 > 10000 + 50000
	CHECK_EQ(part.dialog_gained, 90000u);
	CHECK_EQ(part.balance, 90000u);
	CHECK(part.change(60000, Cause::Dialog, 0, true) == Verdict::Applied);
	CHECK_EQ(part.dialog_gained, 100000u);
	CHECK_EQ(part.balance, 150000u);
	CHECK(part.change(1, Cause::Script, 0) == Verdict::NoAllowance);

	// Dialog without a lock counts as Script.
	HostSide nolock;
	CHECK(nolock.change(50000, Cause::Dialog, 0, false) == Verdict::Applied);
	CHECK_EQ(nolock.dialog_gained, 0u);
	CHECK(nolock.change(1, Cause::Dialog, 0, false) == Verdict::NoAllowance);
	CHECK_EQ(nolock.balance, 50000u);
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
	CHECK_EQ(h.dialog_gained, 0u);
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
	// No change: nothing to do.
	CHECK(h.change(0, Cause::Script, 0) == Verdict::Applied);
	CHECK_EQ(h.balance, 700u);
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
