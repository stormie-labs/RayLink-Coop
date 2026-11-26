// Ядро: без проверок режима (docs/MODES.md)
// Anomaly Coop unit tests: a player's own progress (rank, reputation, community) checked where his record is kept (F5-PRG-2,
// temp/b58/f5_plan.md section 6; xrCoop/coop_progress_rules.h). The engine half (xrGame/coop/coop_progress.cpp) gathers the facts
// and calls these rules from coop_story.cpp's handler of Msg::Progress and from its put-back of the reported values.
//
// One set of rules for both modes. Who calls them, by test name:
//   progress_rules_coop_host_*     Co-op: the host keeps the record, has the player's body and the events (its record of the
//                                  character carries the reputation its own fights added: host_add_reported_reputation);
//   progress_rules_world_server_*  Server: the world server keeps the record, has no body (the saved character only) and its
//                                  budget comes from the map servers' tallies (F5-PRG-4 merges them into coop_progress_check);
//   progress_rules_*               the pure rules both use.
// Map servers only apply the rebroadcast (coop_story.cpp handle_client): no rule of this file runs there.
#include "test_util.h"

#include <algorithm>
#include <climits>
#include <cmath>
#include <fstream>
#include <iterator>
#include <limits>
#include <string>

#include "coop_progress_rules.h"

namespace pr = coop::progress;

namespace
{
constexpr uint32_t kPeer = 3;
constexpr uint16_t kChar = 1234;

pr::Values values(int32_t rank, int32_t reputation, int32_t community)
{
	pr::Values v;
	v.rank = rank;
	v.reputation = reputation;
	v.community = community;
	return v;
}

pr::Report report(const pr::Values& told, const pr::Values& record)
{
	pr::Report r;
	r.told = told;
	r.record_known = true;
	r.record = record;
	return r;
}

// A ledger window (coop_progress_check.rank_budget) that counts how often the engine asked it.
struct Window
{
	bool known = true;
	int64_t rank = 0, reputation = 0;
	int asked = 0;
	bool operator()(pr::Budget& out)
	{
		++asked;
		out.rank = rank;
		out.reputation = reputation;
		return known;
	}
};

struct FactionAnswer
{
	pr::Faction answer = pr::Faction::Unknown;
	int asked = 0;
	pr::Faction operator()(int32_t, int32_t)
	{
		++asked;
		return answer;
	}
};

pr::Modes modes(pr::Trust t)
{
	pr::Modes m;
	m.rank = m.reputation = m.community = t;
	return m;
}
} // namespace

// ---------------------------------------------------------------- pure helpers

TEST(progress_rules_trust_words)
{
	pr::Trust t = pr::Trust::Refuse;
	CHECK(pr::trust_of("log", t) && t == pr::Trust::Log);
	CHECK(pr::trust_of("refuse", t) && t == pr::Trust::Refuse);
	CHECK(pr::trust_of("off", t) && t == pr::Trust::Off);
	// coop_trust.script takes exactly these three words; anything else leaves the mode as it was
	t = pr::Trust::Refuse;
	CHECK(!pr::trust_of("LOG", t) && t == pr::Trust::Refuse);
	CHECK(!pr::trust_of("", t) && !pr::trust_of(nullptr, t) && !pr::trust_of("logx", t) && t == pr::Trust::Refuse);
	CHECK(std::string(pr::trust_word(pr::Trust::Log)) == "log");
	CHECK(std::string(pr::trust_word(pr::Trust::Refuse)) == "refuse");
	CHECK(std::string(pr::trust_word(pr::Trust::Off)) == "off");
	CHECK(std::string(pr::kTrustRank) == "progress_rank");
	CHECK(std::string(pr::kTrustReputation) == "progress_reputation");
	CHECK(std::string(pr::kTrustCommunity) == "progress_community");
}

TEST(progress_rules_lua_numbers_bounded)
{
	CHECK_EQ(pr::points_of(std::numeric_limits<double>::quiet_NaN()), int64_t(0));
	CHECK_EQ(pr::points_of(std::numeric_limits<double>::infinity()), int64_t(0));
	CHECK_EQ(pr::points_of(-std::numeric_limits<double>::infinity()), int64_t(0));
	CHECK_EQ(pr::points_of(-5.0), int64_t(0));
	CHECK_EQ(pr::points_of(12.9), int64_t(12));
	CHECK_EQ(pr::points_of(2e12), pr::kMaxPoints);
	CHECK_EQ(pr::points_of(0.0), int64_t(0));
}

TEST(progress_rules_log_lines_thinned)
{
	for (uint64_t n = 1; n <= 8; ++n)
		CHECK(pr::log_due(n));
	CHECK(!pr::log_due(9));
	CHECK(!pr::log_due(63));
	CHECK(pr::log_due(64));
	CHECK(!pr::log_due(65));
	CHECK(pr::log_due(128));
}

TEST(progress_rules_same_faction)
{
	// the NPC record is X, the player's character actor_X (coop_join.cpp role swap)
	CHECK(pr::same_faction("actor_dolg", "dolg"));
	CHECK(pr::same_faction("dolg", "actor_dolg"));
	CHECK(pr::same_faction("actor_stalker", "actor_stalker"));
	CHECK(!pr::same_faction("dolg", "freedom"));
	CHECK(!pr::same_faction("actor_dolg", "actor_freedom"));
	CHECK(!pr::same_faction("actor", "stalker"));
	CHECK(!pr::same_faction(nullptr, "dolg"));
	CHECK(!pr::same_faction("dolg", nullptr));
	CHECK(!pr::same_faction("actor_", ""));
	CHECK(!pr::same_faction("", ""));
}

// ---------------------------------------------------------------- decide

TEST(progress_rules_honest_deltas_accepted)
{
	pr::Budget b;
	b.rank = 100;
	b.reputation = 20;
	const pr::Verdict v = pr::decide(values(1000, 50, 3), values(1040, 45, 3), b, true, pr::Faction::Same);
	CHECK_EQ(int(v.failed), 0);
	CHECK_EQ(int(v.checked), int(pr::kRank | pr::kReputation));
	CHECK(v.clamped == values(1040, 45, 3));
	// exactly the budget is still honest
	const pr::Verdict w = pr::decide(values(1000, 50, 3), values(1100, 70, 3), b, true, pr::Faction::Same);
	CHECK_EQ(int(w.failed), 0);
}

TEST(progress_rules_inflated_rank_clamped_to_previous_plus_budget)
{
	pr::Budget b;
	b.rank = 125;
	b.reputation = 10;
	const pr::Verdict v = pr::decide(values(1000, 50, 3), values(6000, 50, 3), b, true, pr::Faction::Same);
	CHECK_EQ(int(v.failed), int(pr::kRank));
	CHECK_EQ(v.clamped.rank, 1125);
	CHECK_EQ(v.clamped.reputation, 50);
	const pr::Verdict r = pr::decide(values(1000, 50, 3), values(1000, 5000, 3), b, true, pr::Faction::Same);
	CHECK_EQ(int(r.failed), int(pr::kReputation));
	CHECK_EQ(r.clamped.reputation, 60);
	CHECK_EQ(r.clamped.rank, 1000);
}

TEST(progress_rules_losses_always_pass)
{
	const pr::Verdict v = pr::decide(values(1000, 50, 3), values(10, -4000, 3), pr::Budget(), true, pr::Faction::Same);
	CHECK_EQ(int(v.failed), 0);
	CHECK(v.clamped == values(10, -4000, 3));
}

TEST(progress_rules_unknown_budget_checks_no_points)
{
	const pr::Verdict v = pr::decide(values(1000, 50, 3), values(9000, 900, 3), pr::Budget(), false, pr::Faction::Same);
	CHECK_EQ(int(v.checked), 0);
	CHECK_EQ(int(v.failed), 0);
	CHECK(v.clamped == values(9000, 900, 3));
}

TEST(progress_rules_community_change_needs_an_allowance)
{
	const pr::Verdict no = pr::decide(values(1000, 50, 3), values(1000, 50, 9), pr::Budget(), true, pr::Faction::NotAllowed);
	CHECK_EQ(int(no.failed), int(pr::kCommunity));
	CHECK((no.checked & pr::kCommunity) != 0);
	CHECK_EQ(no.clamped.community, 3);
	const pr::Verdict yes = pr::decide(values(1000, 50, 3), values(1000, 50, 9), pr::Budget(), true, pr::Faction::Allowed);
	CHECK_EQ(int(yes.failed), 0);
	CHECK((yes.checked & pr::kCommunity) != 0);
	CHECK_EQ(yes.clamped.community, 9);
	// nobody to ask (no coop.progress.community_ok): not checked, never refused
	const pr::Verdict unknown = pr::decide(values(1000, 50, 3), values(1000, 50, 9), pr::Budget(), true, pr::Faction::Unknown);
	CHECK_EQ(int(unknown.failed), 0);
	CHECK((unknown.checked & pr::kCommunity) == 0);
	CHECK_EQ(unknown.clamped.community, 9);
}

TEST(progress_rules_extreme_numbers_do_not_overflow)
{
	pr::Budget b;
	b.rank = pr::kMaxPoints;
	b.reputation = pr::kMaxPoints;
	const pr::Verdict v =
	    pr::decide(values(INT32_MIN, INT32_MIN, 3), values(INT32_MAX, INT32_MAX, 3), b, true, pr::Faction::Same);
	CHECK_EQ(int(v.failed), int(pr::kRank | pr::kReputation));
	CHECK_EQ(int64_t(v.clamped.rank), int64_t(INT32_MIN) + pr::kMaxPoints);
	const pr::Verdict w =
	    pr::decide(values(INT32_MAX - 5, INT32_MAX - 5, 3), values(INT32_MAX, INT32_MAX, 3), b, true, pr::Faction::Same);
	CHECK_EQ(int(w.failed), 0);
	const pr::Verdict z = pr::decide(values(INT32_MAX, 0, 3), values(INT32_MIN, 0, 3), pr::Budget(), true, pr::Faction::Same);
	CHECK_EQ(int(z.failed), 0);
}

// ---------------------------------------------------------------- the book: Co-op host

TEST(progress_rules_coop_host_join_baseline_is_the_saved_record)
{
	pr::Book book;
	Window win;
	win.rank = 25; // coop_progress_check: a fresh window has only its allowance
	win.reputation = 10;
	FactionAnswer f;
	// the client's actor took the character's rank / reputation at the role swap: the first report equals the record
	const pr::Outcome same =
	    book.check(kPeer, kChar, report(values(1000, 50, 3), values(1000, 50, 3)), modes(pr::Trust::Refuse), 0, win, f);
	CHECK(same.baseline);
	CHECK_EQ(int(same.failed), 0);
	CHECK(same.out == values(1000, 50, 3));
	CHECK_EQ(win.asked, 0); // nothing rose: the ledger is not asked, its window stays open
	CHECK(!same.commit);
	REQUIRE(book.find(kPeer) != nullptr);
	CHECK(book.find(kPeer)->have);
}

TEST(progress_rules_coop_host_first_report_above_the_record_is_flagged)
{
	pr::Book book;
	Window win;
	win.rank = 25;
	win.reputation = 10;
	FactionAnswer f;
	const pr::Outcome o =
	    book.check(kPeer, kChar, report(values(6000, 50, 3), values(1000, 50, 3)), modes(pr::Trust::Refuse), 0, win, f);
	CHECK(o.baseline);
	CHECK_EQ(int(o.failed), int(pr::kRank));
	CHECK_EQ(int(o.refused), int(pr::kRank));
	CHECK_EQ(o.out.rank, 1025);
	CHECK(o.commit); // the clamped rise was stored: the ledger's window closes
	CHECK_EQ(win.asked, 1);
	// within the budget it passes
	pr::Book other;
	const pr::Outcome ok =
	    other.check(kPeer, kChar, report(values(1020, 55, 3), values(1000, 50, 3)), modes(pr::Trust::Refuse), 0, win, f);
	CHECK_EQ(int(ok.failed), 0);
	CHECK(ok.out == values(1020, 55, 3));
}

TEST(progress_rules_coop_host_log_passes_the_values_as_told)
{
	pr::Book book;
	Window win;
	win.rank = 25;
	FactionAnswer f;
	book.check(kPeer, kChar, report(values(1000, 50, 3), values(1000, 50, 3)), modes(pr::Trust::Log), 0, win, f);
	const pr::Outcome o =
	    book.check(kPeer, kChar, report(values(6000, 50, 3), values(1000, 50, 3)), modes(pr::Trust::Log), 1000, win, f);
	CHECK_EQ(int(o.failed), int(pr::kRank));
	CHECK_EQ(int(o.refused), 0);
	CHECK(o.out == values(6000, 50, 3));
	CHECK(o.commit);
	CHECK_EQ(book.find(kPeer)->accepted.rank, 6000);
}

TEST(progress_rules_coop_host_refuse_keeps_checking_the_told_value)
{
	pr::Book book;
	Window win;
	win.rank = 25;
	FactionAnswer f;
	book.check(kPeer, kChar, report(values(1000, 50, 3), values(1000, 50, 3)), modes(pr::Trust::Refuse), 0, win, f);
	const pr::Outcome a =
	    book.check(kPeer, kChar, report(values(6000, 50, 3), values(1000, 50, 3)), modes(pr::Trust::Refuse), 1000, win, f);
	CHECK_EQ(a.out.rank, 1025);
	// the client's own actor keeps 6000 (apply_progress never touches id 0) and reports it again on the 30 s refresh: not a
	// repeat of the stored record, checked again from the clamped value
	const pr::Outcome b =
	    book.check(kPeer, kChar, report(values(6000, 50, 3), values(1025, 50, 3)), modes(pr::Trust::Refuse), 31000, win, f);
	CHECK(!b.repeat);
	CHECK_EQ(int(b.failed), int(pr::kRank));
	CHECK_EQ(b.out.rank, 1050);
}

TEST(progress_rules_coop_host_repeat_checks_nothing)
{
	pr::Book book;
	Window win;
	win.rank = 100;
	FactionAnswer f;
	book.check(kPeer, kChar, report(values(1000, 50, 3), values(1000, 50, 3)), modes(pr::Trust::Log), 0, win, f);
	book.check(kPeer, kChar, report(values(1050, 50, 3), values(1000, 50, 3)), modes(pr::Trust::Log), 1000, win, f);
	const int asked = win.asked;
	// the 30 s refresh of unchanged values and the put-back of the stored record
	const pr::Outcome o =
	    book.check(kPeer, kChar, report(values(1050, 50, 3), values(1050, 50, 3)), modes(pr::Trust::Log), 31000, win, f);
	CHECK(o.repeat);
	CHECK_EQ(int(o.checked), 0);
	CHECK(!o.commit);
	CHECK_EQ(win.asked, asked);
}

TEST(progress_rules_coop_host_losses_do_not_close_the_window)
{
	pr::Book book;
	Window win;
	FactionAnswer f;
	book.check(kPeer, kChar, report(values(1000, 50, 3), values(1000, 50, 3)), modes(pr::Trust::Log), 0, win, f);
	const pr::Outcome o =
	    book.check(kPeer, kChar, report(values(990, 20, 3), values(1000, 50, 3)), modes(pr::Trust::Log), 1000, win, f);
	CHECK_EQ(int(o.failed), 0);
	CHECK(!o.commit);
	CHECK_EQ(win.asked, 0);
	CHECK(o.out == values(990, 20, 3));
}

TEST(progress_rules_coop_host_added_reputation_not_counted)
{
	pr::Book book;
	Window win;
	win.rank = 25;
	win.reputation = 10; // only the allowance: the +100 of a fight help is the host's own, not an event of the ledger
	FactionAnswer f;
	book.check(kPeer, kChar, report(values(1000, 100, 3), values(1000, 100, 3)), modes(pr::Trust::Refuse), 0, win, f);
	// host_flush_rep_deltas: the proxy (the record) got +100, the client got RelReputationDelta and reports it with +5 of his own
	const pr::Outcome o =
	    book.check(kPeer, kChar, report(values(1000, 205, 3), values(1000, 200, 3)), modes(pr::Trust::Refuse), 500, win, f);
	CHECK_EQ(int(o.failed), 0);
	CHECK_EQ(o.out.reputation, 205);
	CHECK_EQ(o.base.reputation, 200);
}

TEST(progress_rules_coop_host_put_back_of_the_record_is_silent)
{
	pr::Book book;
	Window win;
	FactionAnswer f;
	book.check(kPeer, kChar, report(values(1000, 100, 3), values(1000, 100, 3)), modes(pr::Trust::Refuse), 0, win, f);
	// progress_frame's put-back: g_reported carries the host's +100 (host_add_reported_reputation), so does the proxy
	const pr::Outcome o =
	    book.check(kPeer, kChar, report(values(1000, 200, 3), values(1000, 200, 3)), modes(pr::Trust::Refuse), 900, win, f);
	CHECK_EQ(int(o.failed), 0);
	CHECK(o.out == values(1000, 200, 3));
	CHECK(!o.commit);
	CHECK_EQ(win.asked, 0);
	// the client's report with it is then a repeat
	const pr::Outcome r =
	    book.check(kPeer, kChar, report(values(1000, 200, 3), values(1000, 200, 3)), modes(pr::Trust::Refuse), 1500, win, f);
	CHECK(r.repeat);
}

TEST(progress_rules_coop_host_added_reputation_reported_late)
{
	pr::Book book;
	Window win;
	win.rank = 25;
	win.reputation = 10;
	FactionAnswer f;
	book.check(kPeer, kChar, report(values(1000, 100, 3), values(1000, 100, 3)), modes(pr::Trust::Refuse), 0, win, f);
	// a report the client sent before the +100 reached him: the host's +100 is in the record, not in the report
	const pr::Outcome a =
	    book.check(kPeer, kChar, report(values(1000, 105, 3), values(1000, 200, 3)), modes(pr::Trust::Refuse), 300, win, f);
	CHECK_EQ(int(a.failed), 0);
	CHECK_EQ(a.out.reputation, 105);
	// coop_story stored and applied 105 (the record lost the +100); the next report carries it: not counted against him
	const pr::Outcome b =
	    book.check(kPeer, kChar, report(values(1000, 205, 3), values(1000, 105, 3)), modes(pr::Trust::Refuse), 1300, win, f);
	CHECK_EQ(int(b.failed), 0);
	CHECK_EQ(b.out.reputation, 205);
}

TEST(progress_rules_coop_host_unused_budget_carried_to_a_late_report)
{
	pr::Book book;
	Window win;
	win.rank = 25 + 2 * 106; // two kills seen by the host, their rank reported one by one
	win.reputation = 10;
	FactionAnswer f;
	book.check(kPeer, kChar, report(values(1000, 50, 3), values(1000, 50, 3)), modes(pr::Trust::Refuse), 0, win, f);
	const pr::Outcome a =
	    book.check(kPeer, kChar, report(values(1085, 50, 3), values(1000, 50, 3)), modes(pr::Trust::Refuse), 1000, win, f);
	CHECK_EQ(int(a.failed), 0);
	CHECK(a.commit);
	// the ledger's window closed at the commit: a fresh one has its allowance only
	win.rank = 25;
	const pr::Outcome b =
	    book.check(kPeer, kChar, report(values(1170, 50, 3), values(1085, 50, 3)), modes(pr::Trust::Refuse), 2000, win, f);
	CHECK_EQ(int(b.failed), 0);
	CHECK_EQ(b.out.rank, 1170);
	// what is carried runs out after kCreditMs
	pr::Book late;
	win.rank = 25 + 2 * 106;
	late.check(kPeer, kChar, report(values(1000, 50, 3), values(1000, 50, 3)), modes(pr::Trust::Refuse), 0, win, f);
	late.check(kPeer, kChar, report(values(1085, 50, 3), values(1000, 50, 3)), modes(pr::Trust::Refuse), 1000, win, f);
	win.rank = 25;
	const pr::Outcome c = late.check(kPeer, kChar, report(values(1170, 50, 3), values(1085, 50, 3)), modes(pr::Trust::Refuse),
	    1000 + pr::kCreditMs + 1, win, f);
	CHECK_EQ(int(c.failed), int(pr::kRank));
	CHECK_EQ(c.out.rank, 1110);
}

TEST(progress_rules_coop_host_pushed_budget)
{
	pr::Book book;
	Window win;
	win.rank = 25;
	FactionAnswer f;
	book.check(kPeer, kChar, report(values(1000, 50, 3), values(1000, 50, 3)), modes(pr::Trust::Refuse), 0, win, f);
	// coop.progress.budget(peer, 1000, 0): an achievement the ledger did not see
	CHECK(book.add_credit(kPeer, 1000, 0, 5000));
	const pr::Outcome o =
	    book.check(kPeer, kChar, report(values(2020, 50, 3), values(1000, 50, 3)), modes(pr::Trust::Refuse), 6000, win, f);
	CHECK_EQ(int(o.failed), 0);
	CHECK_EQ(o.out.rank, 2020);
	// capped, and it runs out
	CHECK(book.add_credit(kPeer, pr::kMaxPoints, pr::kMaxPoints, 7000));
	REQUIRE(book.find(kPeer) != nullptr);
	CHECK(book.find(kPeer)->credit.rank <= pr::kMaxCreditRank);
	CHECK(book.find(kPeer)->credit.reputation <= pr::kMaxCreditReputation);
	const pr::Outcome late = book.check(kPeer, kChar, report(values(9000, 50, 3), values(2020, 50, 3)),
	    modes(pr::Trust::Refuse), 7000 + pr::kCreditMs + 1, win, f);
	CHECK_EQ(int(late.failed), int(pr::kRank));
	CHECK_EQ(late.out.rank, 2045);
	// before the first report of the peer: kept for him
	pr::Book early;
	CHECK(early.add_credit(kPeer, 500, 0, 0));
	const pr::Outcome first =
	    early.check(kPeer, kChar, report(values(1500, 50, 3), values(1000, 50, 3)), modes(pr::Trust::Refuse), 100, win, f);
	CHECK_EQ(int(first.failed), 0);
}

TEST(progress_rules_coop_host_community)
{
	pr::Book book;
	Window win;
	FactionAnswer f;
	book.check(kPeer, kChar, report(values(1000, 50, 3), values(1000, 50, 3)), modes(pr::Trust::Refuse), 0, win, f);
	f.answer = pr::Faction::NotAllowed;
	const pr::Outcome no =
	    book.check(kPeer, kChar, report(values(1000, 50, 9), values(1000, 50, 3)), modes(pr::Trust::Refuse), 1000, win, f);
	CHECK_EQ(int(no.failed), int(pr::kCommunity));
	CHECK_EQ(int(no.refused), int(pr::kCommunity));
	CHECK_EQ(no.out.community, 3);
	CHECK_EQ(f.asked, 1);
	f.answer = pr::Faction::NotAllowed;
	const pr::Outcome logged =
	    book.check(kPeer, kChar, report(values(1000, 50, 9), values(1000, 50, 3)), modes(pr::Trust::Log), 2000, win, f);
	CHECK_EQ(int(logged.failed), int(pr::kCommunity));
	CHECK_EQ(logged.out.community, 9);
	// a disguise the coop_faction record allows
	pr::Book allowed;
	allowed.check(kPeer, kChar, report(values(1000, 50, 3), values(1000, 50, 3)), modes(pr::Trust::Refuse), 0, win, f);
	f.answer = pr::Faction::Allowed;
	const pr::Outcome yes =
	    allowed.check(kPeer, kChar, report(values(1000, 50, 9), values(1000, 50, 3)), modes(pr::Trust::Refuse), 1000, win, f);
	CHECK_EQ(int(yes.failed), 0);
	CHECK_EQ(yes.out.community, 9);
	// the record already has the told community: nobody is asked
	const int asked = f.asked;
	pr::Book rec;
	rec.check(kPeer, kChar, report(values(1000, 50, 3), values(1000, 50, 3)), modes(pr::Trust::Refuse), 0, win, f);
	const pr::Outcome same =
	    rec.check(kPeer, kChar, report(values(1000, 50, 9), values(1000, 50, 9)), modes(pr::Trust::Refuse), 1000, win, f);
	CHECK_EQ(int(same.failed), 0);
	CHECK_EQ(f.asked, asked);
}

TEST(progress_rules_coop_host_bad_community_index_kept_from_the_record)
{
	pr::Book book;
	Window win;
	FactionAnswer f;
	f.answer = pr::Faction::NotAllowed;
	book.check(kPeer, kChar, report(values(1000, 50, 3), values(1000, 50, 3)), modes(pr::Trust::Log), 0, win, f);
	pr::Report r = report(values(1000, 50, -7), values(1000, 50, 3));
	r.told_community_valid = false;
	const pr::Outcome o = book.check(kPeer, kChar, r, modes(pr::Trust::Log), 1000, win, f);
	CHECK(o.repeat); // nobody applies an index out of the table: the record's community stays, nothing else changed
	CHECK_EQ(o.out.community, 3);
	CHECK_EQ(f.asked, 0);
}

TEST(progress_rules_coop_host_off_checks_nothing)
{
	pr::Book book;
	Window win;
	FactionAnswer f;
	f.answer = pr::Faction::NotAllowed;
	book.check(kPeer, kChar, report(values(1000, 50, 3), values(1000, 50, 3)), modes(pr::Trust::Off), 0, win, f);
	const pr::Outcome o =
	    book.check(kPeer, kChar, report(values(9000, 900, 9), values(1000, 50, 3)), modes(pr::Trust::Off), 1000, win, f);
	CHECK_EQ(int(o.checked), 0);
	CHECK_EQ(int(o.failed), 0);
	CHECK(o.out == values(9000, 900, 9));
	CHECK(!o.commit);
}

TEST(progress_rules_coop_host_no_ledger_no_point_check)
{
	pr::Book book;
	Window win;
	win.known = false; // coop_progress_check absent or failing: no budget source
	FactionAnswer f;
	book.check(kPeer, kChar, report(values(1000, 50, 3), values(1000, 50, 3)), modes(pr::Trust::Refuse), 0, win, f);
	const pr::Outcome o =
	    book.check(kPeer, kChar, report(values(9000, 900, 3), values(1000, 50, 3)), modes(pr::Trust::Refuse), 1000, win, f);
	CHECK(!o.budget_known);
	CHECK_EQ(int(o.failed), 0);
	CHECK(o.out == values(9000, 900, 3));
	CHECK(!o.commit);
}

TEST(progress_rules_coop_host_no_record_takes_the_report)
{
	pr::Book book;
	Window win;
	FactionAnswer f;
	pr::Report r;
	r.told = values(5000, 50, 3);
	const pr::Outcome o = book.check(kPeer, kChar, r, modes(pr::Trust::Refuse), 0, win, f);
	CHECK(o.no_record);
	CHECK_EQ(int(o.failed), 0);
	CHECK(o.out == values(5000, 50, 3));
	// from then on the stored report is the base
	win.rank = 25;
	const pr::Outcome next = book.check(kPeer, kChar, report(values(9000, 50, 3), values(5000, 50, 3)), modes(pr::Trust::Refuse),
	    1000, win, f);
	CHECK_EQ(int(next.failed), int(pr::kRank));
	CHECK_EQ(next.out.rank, 5025);
}

TEST(progress_rules_coop_host_another_character_on_the_slot_is_a_new_join)
{
	pr::Book book;
	Window win;
	win.rank = 25;
	FactionAnswer f;
	book.check(kPeer, kChar, report(values(9000, 50, 3), values(9000, 50, 3)), modes(pr::Trust::Refuse), 0, win, f);
	// the slot is reused by a player with another character (rank 100 in the save): measured from that record, not 9000
	const pr::Outcome o = book.check(kPeer, uint16_t(kChar + 1), report(values(9000, 50, 3), values(100, 50, 3)),
	    modes(pr::Trust::Refuse), 1000, win, f);
	CHECK(o.baseline);
	CHECK_EQ(int(o.failed), int(pr::kRank));
	CHECK_EQ(o.out.rank, 125);
}

TEST(progress_rules_coop_host_sweep_drops_left_players)
{
	pr::Book book;
	Window win;
	FactionAnswer f;
	book.check(1, 100, report(values(1, 1, 3), values(1, 1, 3)), modes(pr::Trust::Log), 0, win, f);
	book.check(2, 200, report(values(1, 1, 3), values(1, 1, 3)), modes(pr::Trust::Log), 0, win, f);
	CHECK(book.add_credit(5, 10, 0, 0)); // pushed for a peer that never reports
	CHECK_EQ(book.size(), size_t(3));
	auto proxy_of = [](uint32_t peer) -> uint16_t { return peer == 1 ? uint16_t(100) : pr::kNoCharacter; };
	CHECK_EQ(book.sweep(proxy_of, 1000), size_t(1)); // peer 2 left; peer 5's credit is still young
	CHECK(book.find(1) != nullptr && book.find(2) == nullptr && book.find(5) != nullptr);
	CHECK_EQ(book.sweep(proxy_of, pr::kCreditMs + 1), size_t(1));
	CHECK(book.find(5) == nullptr && book.find(1) != nullptr);
	// a slot that now names another character is a join of its own: dropped
	auto moved = [](uint32_t) -> uint16_t { return uint16_t(101); };
	CHECK_EQ(book.sweep(moved, pr::kCreditMs + 2), size_t(1));
	CHECK(book.empty());
}

TEST(progress_rules_book_is_bounded)
{
	pr::Book book;
	for (uint32_t p = 0; p < uint32_t(pr::kMaxPeers); ++p)
		CHECK(book.add_credit(p + 100, 1, 1, 0));
	CHECK(!book.add_credit(9999, 1, 1, 0));
	CHECK_EQ(book.size(), pr::kMaxPeers);
	// a player's report still finds room: an entry that only holds pushed points gives way
	Window win;
	FactionAnswer f;
	const pr::Outcome o = book.check(kPeer, kChar, report(values(1, 1, 3), values(1, 1, 3)), modes(pr::Trust::Log), 0, win, f);
	CHECK(o.baseline);
	CHECK(book.find(kPeer) != nullptr);
	CHECK_EQ(book.size(), pr::kMaxPeers);
	CHECK(!book.add_credit(kPeer, -1, 0, 0)); // negative points are a caller bug: refused
}

// ---------------------------------------------------------------- the book: the world server (Server mode)

TEST(progress_rules_world_server_budget_from_the_map_tallies)
{
	// The world server keeps the record and has no body: its record of the character is the saved one (the alife object),
	// nothing of a fight changes it there. The budget is what the map servers tallied (merged into coop_progress_check).
	pr::Book book;
	Window win;
	win.rank = 25;
	win.reputation = 10;
	FactionAnswer f;
	const pr::Outcome first =
	    book.check(kPeer, kChar, report(values(1000, 50, 3), values(1000, 50, 3)), modes(pr::Trust::Log), 0, win, f);
	CHECK(first.baseline);
	CHECK_EQ(int(first.failed), 0);
	win.rank = 25 + 106; // a kill on the map server, tallied up (prg_tally)
	win.reputation = 10 + 12;
	const pr::Outcome kill =
	    book.check(kPeer, kChar, report(values(1085, 60, 3), values(1000, 50, 3)), modes(pr::Trust::Log), 15000, win, f);
	CHECK_EQ(int(kill.failed), 0);
	CHECK(kill.commit);
	win.rank = 25;
	win.reputation = 10;
	const pr::Outcome cheat =
	    book.check(kPeer, kChar, report(values(6085, 60, 3), values(1085, 60, 3)), modes(pr::Trust::Log), 30000, win, f);
	CHECK_EQ(int(cheat.failed), int(pr::kRank));
	CHECK_EQ(cheat.out.rank, 6085); // "log": as told
	CHECK_EQ(int(cheat.refused), 0);
}

TEST(progress_rules_world_server_refuse_clamps_the_record)
{
	pr::Book book;
	Window win;
	win.rank = 25;
	win.reputation = 10;
	FactionAnswer f;
	book.check(kPeer, kChar, report(values(1000, 50, 3), values(1000, 50, 3)), modes(pr::Trust::Refuse), 0, win, f);
	const pr::Outcome o =
	    book.check(kPeer, kChar, report(values(1000, 5050, 3), values(1000, 50, 3)), modes(pr::Trust::Refuse), 15000, win, f);
	CHECK_EQ(int(o.failed), int(pr::kReputation));
	CHECK_EQ(o.out.reputation, 60);
	CHECK_EQ(o.out.rank, 1000);
}

// ---------------------------------------------------------------- messages out of order (rv_F5-PRG-2 should-fix A)

// A1: the 30 s refresh the client sent before the host's +100 reached him repeats the stored values; coop_story stores and applies it
// (the record loses the +100). His next report, with the +100, is not counted against him.
TEST(progress_rules_coop_host_added_reputation_behind_a_stale_refresh)
{
	pr::Book book;
	Window win;
	win.rank = 25;
	win.reputation = 10;
	FactionAnswer f;
	book.check(kPeer, kChar, report(values(1000, 100, 3), values(1000, 100, 3)), modes(pr::Trust::Refuse), 0, win, f);
	// host_flush_rep_deltas: the proxy got +100; the client's refresh of 100 was already on its way
	const pr::Outcome stale =
	    book.check(kPeer, kChar, report(values(1000, 100, 3), values(1000, 200, 3)), modes(pr::Trust::Refuse), 300, win, f);
	CHECK(stale.repeat);
	CHECK_EQ(stale.out.reputation, 100);
	// coop_story stored and applied 100: the record is 100 again; then his report with the +100
	const pr::Outcome o =
	    book.check(kPeer, kChar, report(values(1000, 200, 3), values(1000, 100, 3)), modes(pr::Trust::Refuse), 1300, win, f);
	CHECK_EQ(int(o.failed), 0);
	CHECK_EQ(o.out.reputation, 200);
	CHECK(o.commit);
}

// A2: progress_frame's put-back comes first (g_reported and the proxy carry the +100), then a report the client sent before the +100
// reached him (a loss: it passes, coop_story applies it), then his report with the +100.
TEST(progress_rules_coop_host_added_reputation_put_back_before_a_stale_report)
{
	pr::Book book;
	Window win;
	win.rank = 25;
	win.reputation = 10;
	FactionAnswer f;
	book.check(kPeer, kChar, report(values(1000, 100, 3), values(1000, 100, 3)), modes(pr::Trust::Refuse), 0, win, f);
	const pr::Outcome put =
	    book.check(kPeer, kChar, report(values(1000, 200, 3), values(1000, 200, 3)), modes(pr::Trust::Refuse), 300, win, f);
	CHECK_EQ(int(put.failed), 0);
	CHECK(put.out == values(1000, 200, 3));
	const pr::Outcome stale =
	    book.check(kPeer, kChar, report(values(1000, 100, 3), values(1000, 200, 3)), modes(pr::Trust::Refuse), 600, win, f);
	CHECK_EQ(int(stale.failed), 0);
	CHECK_EQ(stale.out.reputation, 100);
	const pr::Outcome o =
	    book.check(kPeer, kChar, report(values(1000, 200, 3), values(1000, 100, 3)), modes(pr::Trust::Refuse), 1600, win, f);
	CHECK_EQ(int(o.failed), 0);
	CHECK_EQ(o.out.reputation, 200);
}

// The host's own reputation counts for the player once (his rises spend it first, what is left of the rest is carried) and for
// kCreditMs only.
TEST(progress_rules_coop_host_added_reputation_counts_once)
{
	pr::Book book;
	Window win;
	win.rank = 25;
	win.reputation = 10;
	FactionAnswer f;
	book.check(kPeer, kChar, report(values(1000, 100, 3), values(1000, 100, 3)), modes(pr::Trust::Refuse), 0, win, f);
	// the fight's +100 in the record and in his report, +5 of his own: 5 of the host's 100 spent, the allowance's 10 carried
	const pr::Outcome a =
	    book.check(kPeer, kChar, report(values(1000, 205, 3), values(1000, 200, 3)), modes(pr::Trust::Refuse), 500, win, f);
	CHECK_EQ(int(a.failed), 0);
	CHECK(a.commit);
	// 120 more: the allowance 10 + the carried 10 + the host's 95 left = 115
	const pr::Outcome b =
	    book.check(kPeer, kChar, report(values(1000, 325, 3), values(1000, 205, 3)), modes(pr::Trust::Refuse), 1500, win, f);
	CHECK_EQ(int(b.failed), int(pr::kReputation));
	CHECK_EQ(b.out.reputation, 320);

	// not kept for ever: the report with the +100 after kCreditMs has the allowance only
	pr::Book late;
	late.check(kPeer, kChar, report(values(1000, 100, 3), values(1000, 100, 3)), modes(pr::Trust::Refuse), 0, win, f);
	late.check(kPeer, kChar, report(values(1000, 100, 3), values(1000, 200, 3)), modes(pr::Trust::Refuse), 300, win, f);
	const pr::Outcome c = late.check(kPeer, kChar, report(values(1000, 200, 3), values(1000, 100, 3)), modes(pr::Trust::Refuse),
	    300 + pr::kCreditMs + 1, win, f);
	CHECK_EQ(int(c.failed), int(pr::kReputation));
	CHECK_EQ(c.out.reputation, 110);
}

// ---------------------------------------------------------------- a new world (rv_F5-PRG-2 should-fix B)

namespace
{
// anomaly-coop/<rel> (tests\ -> ..), without '\r'
std::string progress_project_file(const std::string& rel)
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	here.resize(slash == std::string::npos ? 0 : slash);
	std::ifstream in(here + "/../" + rel, std::ios::binary);
	std::string text((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
	text.erase(std::remove(text.begin(), text.end(), '\r'), text.end());
	return text;
}

std::string progress_body(const std::string& src, const std::string& head)
{
	const size_t at = src.find("\n" + head);
	if (at == std::string::npos)
		return std::string();
	const size_t end = src.find("\n}", at + 1);
	return src.substr(at + 1, end == std::string::npos ? std::string::npos : end - at);
}
} // namespace

// The engine half keys its book by the world (join::host_world_epoch: a load or a level change replaces it) before it checks a report
// and before it sweeps: the values stored in an old world are no base in a new one.
TEST(progress_rules_engine_keys_the_book_by_the_world)
{
	const std::string src = progress_project_file("engine/src/xrGame/coop/coop_progress.cpp");
	const std::string check = progress_body(src, "bool host_check(");
	const std::string frame = progress_body(src, "void frame()");
	REQUIRE(!check.empty() && !frame.empty());
	const std::string ask = "g.book.on_world(join::host_world_epoch())";
	const size_t check_world = check.find(ask);
	const size_t check_book = check.find("g.book.check(");
	CHECK(check_world != std::string::npos && check_book != std::string::npos && check_world < check_book);
	const size_t frame_world = frame.find(ask);
	const size_t frame_sweep = frame.find("g.book.sweep(");
	CHECK(frame_world != std::string::npos && frame_sweep != std::string::npos && frame_world < frame_sweep);
}

// The probe of the review: rank 5000 stored, then a new world whose record says 1000 (a save loaded), then a report of 4999. Measured
// from the old 5000 it passed; the book forgets the old world, so it is the first report of the new one, from its record.
TEST(progress_rules_book_forgets_an_old_world)
{
	pr::Book book;
	Window win;
	win.rank = 25;
	win.reputation = 10;
	FactionAnswer f;
	CHECK(!book.on_world(1)); // the first world: nothing to forget
	book.check(kPeer, kChar, report(values(5000, 50, 3), values(5000, 50, 3)), modes(pr::Trust::Refuse), 0, win, f);
	CHECK(!book.on_world(1)); // the same world
	CHECK(book.find(kPeer) != nullptr);
	CHECK(book.on_world(2));
	CHECK(book.empty());
	const pr::Outcome o =
	    book.check(kPeer, kChar, report(values(4999, 50, 3), values(1000, 50, 3)), modes(pr::Trust::Refuse), 1000, win, f);
	CHECK(o.baseline);
	CHECK_EQ(int(o.failed), int(pr::kRank));
	CHECK_EQ(o.out.rank, 1025);
	// a world's epoch may come back (a new session counts from its start again): only a change forgets
	CHECK(book.on_world(1));
	CHECK(!book.on_world(1));
}

// ---------------------------------------------------------------- Server: a map server's verified fight (F5-REV-1 should-fix S3)

// The world server keeps the record as the alife object, which a map server's fight never touches: host_apply_fight puts the fight's
// reputation into the stored report (g_reported) only, so the put-back, or his next report, rose by the fight against the window alone
// ("log": a false "would refuse" line for every honest fight; "refuse": the fight cut from his record). coop.progress.
// apply_verified_fight now credits the keeper with it (Book::credit_keeper), as the co-op host's record credits its own fights. The
// probe of the review: the fight +40, the window 10.
TEST(progress_rules_world_server_verified_fight_is_the_keepers)
{
	const pr::Values start = values(1000, 50, 3);
	Window win;
	win.rank = 0;
	win.reputation = 10;
	FactionAnswer f;
	// co-op: the host's fight changed his record itself (the probe's co-op line)
	{
		pr::Book book;
		book.check(kPeer, kChar, report(start, start), modes(pr::Trust::Log), 1000, win, f);
		const pr::Outcome o =
		    book.check(kPeer, kChar, report(values(1000, 90, 3), values(1000, 90, 3)), modes(pr::Trust::Log), 2000, win, f);
		CHECK_EQ(int(o.failed), 0);
		CHECK_EQ(o.base.reputation, 90);
	}
	// Server: the record stays 50, the fight is the keeper's credit
	pr::Book book;
	book.check(kPeer, kChar, report(start, start), modes(pr::Trust::Refuse), 1000, win, f);
	book.credit_keeper(kPeer, kChar, 40, 1500);
	const pr::Outcome put = book.check(kPeer, kChar, report(values(1000, 90, 3), start), modes(pr::Trust::Refuse), 2000, win, f);
	CHECK_EQ(int(put.failed), 0);
	CHECK_EQ(put.out.reputation, 90);
	CHECK_EQ(put.budget.reputation, 50);
	CHECK(put.commit);
	// spent once: 40 more is the window and the carried 10 (20), not the fight again
	const pr::Outcome more = book.check(kPeer, kChar, report(values(1000, 130, 3), start), modes(pr::Trust::Refuse), 3000, win, f);
	CHECK_EQ(int(more.failed), int(pr::kReputation));
	CHECK_EQ(more.out.reputation, 110);

	// only for the peer's own character, a rise, a peer the book knows; kept kCreditMs, as the co-op host's credit
	pr::Book other;
	other.check(kPeer, kChar, report(start, start), modes(pr::Trust::Refuse), 1000, win, f);
	other.credit_keeper(kPeer, kChar + 1, 40, 1500); // another character on his slot
	other.credit_keeper(kPeer, kChar, -40, 1500); // a fight that cost him: no credit (a loss always passes)
	other.credit_keeper(kPeer + 1, kChar, 40, 1500); // nobody the book knows: no entry made
	CHECK(other.find(kPeer + 1) == nullptr);
	REQUIRE(other.find(kPeer) != nullptr);
	CHECK_EQ(other.find(kPeer)->keeper_rep, int64_t(0));
	other.credit_keeper(kPeer, kChar, 40, 1500);
	CHECK_EQ(other.find(kPeer)->keeper_rep, int64_t(40));
	other.credit_keeper(kPeer, kChar, 5000, 1600); // capped as the record's credit
	CHECK_EQ(other.find(kPeer)->keeper_rep, pr::kMaxCreditReputation);
	pr::Book late;
	late.check(kPeer, kChar, report(start, start), modes(pr::Trust::Refuse), 1000, win, f);
	late.credit_keeper(kPeer, kChar, 40, 1500);
	const pr::Outcome stale =
	    late.check(kPeer, kChar, report(values(1000, 90, 3), start), modes(pr::Trust::Refuse), 1500 + pr::kCreditMs + 1, win, f);
	CHECK_EQ(int(stale.failed), int(pr::kReputation));
	CHECK_EQ(stale.out.reputation, 60);
}

// The engine half: apply_verified_fight credits the keeper after host_apply_fight took the fight, with the same peer, character and
// delta (the Server path; the co-op host's fights reach the book through its record).
TEST(progress_rules_engine_credits_a_verified_fight)
{
	const std::string src = progress_project_file("engine/src/xrGame/coop/coop_progress.cpp");
	const std::string apply = progress_body(src, "int l_apply_verified_fight(lua_State* L)");
	REQUIRE(!apply.empty());
	const size_t applied = apply.find("ok = host_apply_fight(PeerId(p), u16(c), int(d));");
	const size_t taken = apply.find("if (ok)", applied);
	const size_t credit = apply.find("g.book.credit_keeper(u32(p), u16(c), int64_t(d), mgr().now_ms());");
	CHECK(applied != std::string::npos && taken != std::string::npos && credit != std::string::npos);
	CHECK(applied < taken && taken < credit);
}

// Note 2 of F5-REV-1: the book and the counters are one session's (only Book::on_world forgot them before): sync::reset() calls
// progress::reset(), which starts the state afresh.
TEST(progress_rules_engine_forgets_a_session)
{
	const std::string api = progress_project_file("engine/src/xrGame/coop/coop_progress.h");
	CHECK(api.find("\nvoid reset();") != std::string::npos);
	const std::string src = progress_project_file("engine/src/xrGame/coop/coop_progress.cpp");
	const std::string reset = progress_body(src, "void reset()");
	REQUIRE(!reset.empty());
	CHECK(reset.find("g = State();") != std::string::npos);
	const std::string sync = progress_body(progress_project_file("engine/src/xrGame/coop/coop_sync.cpp"), "const Step kReset[]");
	REQUIRE(!sync.empty());
	CHECK(sync.find("&progress::reset,") != std::string::npos);
}

// Note 4 of F5-REV-1: the keeper adds a fight's reputation to the stored report of a player who may have told any number ("log"): the
// sum is made in 64 bits and kept in the int range, no signed overflow.
TEST(progress_rules_engine_added_reputation_stays_in_range)
{
	const std::string story = progress_project_file("engine/src/xrGame/coop/coop_story_progress.cpp");
	// the definition, not a declaration
	const std::string add = progress_body(story, std::string("void host_add_reported_reputation(PeerId peer, int delta)") + "\n{");
	REQUIRE(!add.empty());
	CHECK(add.find("it->second.reputation += delta") == std::string::npos);
	const size_t sum = add.find("const s64 sum = s64(it->second.reputation) + s64(delta);");
	const size_t kept = add.find("it->second.reputation = int(sum > s64(INT_MAX) ? INT_MAX : (sum < s64(INT_MIN) ? INT_MIN : sum));");
	CHECK(sum != std::string::npos && kept != std::string::npos && sum < kept);
}
