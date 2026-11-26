// Executes the engine's own admitted_move and player_move (engine/src/xrGame/coop/coop_requests.cpp, cut out by
// tests/tools/test_move_admission_wiring.py into admitted_move.inc) over the real pure header
// engine/src/xrCoop/coop_move_admission.h. R32 WP18 P4, temp/r30/design/R32-final.md section 8a A21 E-3: a move whose
// destination root is a player is put to the move rules without the admission book; a refusal is Reason::NotAllowed.
// The engine calls around them (the Lua move rules, apply_move, is_player, events::root_of, the clock, the item's
// weight) are stubs that record what they were asked. One scenario per run: move_admission_wiring.exe <scenario>.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>

#include "coop_move_admission.h"

using u8 = uint8_t;
using u16 = uint16_t;
using u32 = uint32_t;
using u64 = uint64_t;
using xr_string = std::string;
struct Fvector
{
	float x = 0.f, y = 0.f, z = 0.f;
};
constexpr u16 kNoId = 0xffff;

int g_log_lines = 0; // ::Msg lines (a failed asking is logged)
template <class... T> void Msg(const char*, T...) { ++g_log_lines; }

namespace
{
int g_failures = 0;
void check(bool ok, const char* what)
{
	if (!ok)
	{
		std::fprintf(stderr, "FAIL: %s\n", what);
		++g_failures;
	}
}
} // namespace

namespace coop
{
namespace requests
{
enum class Reason : u8
{
	Ok = 0,
	Malformed,
	NoProxy,
	Missing,
	Moved,
	NotOwner,
	NotAllowed,
	BadSection,
	RateLimited,
	TooFar,
	Offline
};

// The counters the engine prints in coop_status (coop_requests.cpp AdmissionCounters, same fields).
struct AdmissionCounters
{
	u64 asked = 0, let_in = 0, refused = 0, too_many = 0, no_rule = 0, failed = 0, undone = 0;
	u64 player_asked = 0, player_refused = 0, player_failed = 0;
} g_ac;
admission::Ledger g_admission;

// ---- the world of one scenario
constexpr u16 kHostActor = 0, kClientCharacter = 101, kInsideClient = 205, kStash = 300, kItem = 400, kOtherItem = 401,
              kBox = 500;

struct CGameObject
{
	virtual ~CGameObject() = default;
};
struct CInventoryItem : CGameObject
{
	float weight = 3.5f;
	float Weight() const { return weight; }
};
CInventoryItem g_item;
template <class T, class U> T smart_cast(U* value) { return dynamic_cast<T>(value); }
CGameObject* valid_go(u16 id) { return id == kItem ? &g_item : nullptr; }

bool is_player(u16 id) { return id == kHostActor || id == kClientCharacter; }
namespace events
{
u16 root_of(u16 id)
{
	if (id == kInsideClient)
		return kClientCharacter;
	return id;
}
} // namespace events

struct Manager
{
	u64 now = 100000;
	u64 now_ms() const { return now; }
} g_mgr;
Manager& mgr() { return g_mgr; }
struct { bool allow() { return true; } } g_log;

// Where a held move stands (coop_requests.cpp admission_track): every held move of this world has left its container.
admission::Track admission_track(u16, u16) { return admission::Track::Gone; }

// ---- the move rules (Lua coop_mods_move_limits.admit): the scripted answer, every call recorded
admission::Answer g_answer = admission::Answer::NoRule;
xr_string g_answer_text;
int g_asked = 0;
u16 g_asked_item = 0, g_asked_src = 0, g_asked_dst = 0;
admission::Pending g_asked_pending;
admission::Answer ask_move_rules(u16 item, u16 src, u16 dst, const admission::Pending& pending, xr_string& text)
{
	++g_asked;
	g_asked_item = item;
	g_asked_src = src;
	g_asked_dst = dst;
	g_asked_pending = pending;
	text = g_answer_text;
	return g_answer;
}

// ---- apply_move: the stock move, every call recorded
Reason g_apply_result = Reason::Ok;
int g_applied = 0;
u16 g_applied_item = 0, g_applied_src = 0, g_applied_dst = 0;
const Fvector* g_applied_pos = nullptr;
Reason apply_move(u16 item, u16 src, u16 dst, const Fvector* drop_pos)
{
	++g_applied;
	g_applied_item = item;
	g_applied_src = src;
	g_applied_dst = dst;
	g_applied_pos = drop_pos;
	return g_apply_result;
}

#include "admitted_move.inc"

// ---- scenarios
struct Outcome
{
	Reason result = Reason::Malformed;
	xr_string refused;
};

Outcome move(u16 src, u16 dst, const Fvector* pos = nullptr)
{
	Outcome o;
	o.result = admitted_move(kItem, src, dst, pos, o.refused);
	return o;
}

// A held move of another item in `container`, which settle() would drop (admission_track says Gone).
void hold_other(u16 container) { check(g_admission.hold(container, kOtherItem, 2.f, g_mgr.now), "setup: hold"); }

void expect_applied(u16 src, u16 dst, const Fvector* pos)
{
	check(g_applied == 1, "apply_move is called once");
	check(g_applied_item == kItem && g_applied_src == src && g_applied_dst == dst, "apply_move gets the move as asked");
	check(g_applied_pos == pos, "apply_move gets the drop position");
}

void expect_asked(u16 src, u16 dst)
{
	check(g_asked == 1, "the move rules are asked once");
	check(g_asked_item == kItem && g_asked_src == src && g_asked_dst == dst, "the rules are asked about this move");
}

// The ground: nothing asked, nothing held, the stock move (A21 E-3 keeps dst == kNoId unasked).
void ground(u16 src)
{
	g_answer = admission::Answer::Refuse; // a rule that would refuse: never asked
	const Fvector pos{1.f, 2.f, 3.f};
	hold_other(kStash);
	const Outcome o = move(src, kNoId, &pos);
	check(o.result == Reason::Ok, "a drop is moved");
	check(o.refused.empty(), "a drop is not refused");
	check(g_asked == 0, "the ground is never asked");
	expect_applied(src, kNoId, &pos);
	check(g_admission.size() == 1, "the admission book is untouched");
	check(g_ac.asked == 0 && g_ac.player_asked == 0, "no asking is counted");
}

// Into a player's character (dst, or an object whose root is a player): the rules are asked with nothing pending and
// the admission book is never settled, held or released.
void player(u16 dst, admission::Answer answer, const char* text, Reason apply_result)
{
	g_answer = answer;
	g_answer_text = text;
	g_apply_result = apply_result;
	hold_other(dst); // settle() of dst would drop it; the rules would see it in pending(dst)
	const Outcome o = move(kBox, dst);
	expect_asked(kBox, dst);
	check(g_asked_pending.count == 0 && g_asked_pending.weight == 0.f, "a player is asked with nothing pending");
	check(g_admission.size() == 1 && g_admission.holds(kOtherItem), "the book is not settled");
	check(!g_admission.holds(kItem), "a move into a player is never held");
	check(g_ac.player_asked == 1, "player_asked counts the asking");
	check(g_ac.asked == 0 && g_ac.let_in == 0 && g_ac.refused == 0 && g_ac.no_rule == 0 && g_ac.failed == 0 &&
	          g_ac.too_many == 0 && g_ac.undone == 0,
	    "the container counters are untouched");
	if (answer == admission::Answer::Refuse)
	{
		check(o.result == Reason::NotAllowed, "a refused take into a player is NotAllowed");
		check(o.refused == (*text ? xr_string(text) : xr_string("refused by a move rule")),
		    "the refusal carries the rule's text or the default");
		check(g_applied == 0, "a refused take is not applied");
		check(g_ac.player_refused == 1 && g_ac.player_failed == 0, "player_refused counts it");
		return;
	}
	check(o.result == apply_result, "apply_move's result is returned");
	check(o.refused.empty(), "a move let in is not refused");
	expect_applied(kBox, dst, nullptr);
	check(g_ac.player_refused == 0, "nothing refused");
	check(g_ac.player_failed == (answer == admission::Answer::Failed ? 1u : 0u), "player_failed counts a failed asking");
	check(g_log_lines == (answer == admission::Answer::Failed ? 1 : 0), "only a failed asking is logged");
}

// Into a container that is not a player's (a stash), from the player's character: unchanged, asked with its held moves.
void container(admission::Answer answer, const char* text, Reason apply_result)
{
	g_answer = answer;
	g_answer_text = text;
	g_apply_result = apply_result;
	hold_other(kStash); // settle() drops it (Gone), so the rules see nothing pending
	check(g_admission.hold(kStash + 1, kOtherItem + 1, 4.f, g_mgr.now), "setup: hold elsewhere");
	const Outcome o = move(kClientCharacter, kStash);
	expect_asked(kClientCharacter, kStash);
	check(g_asked_pending.count == 0, "the stash was settled before it was asked");
	check(!g_admission.holds(kOtherItem), "settle dropped the stash's landed move");
	check(g_admission.holds(kOtherItem + 1), "another container's move stays held");
	check(g_ac.asked == 1, "asked counts it");
	check(g_ac.player_asked == 0 && g_ac.player_refused == 0 && g_ac.player_failed == 0, "no player counter moves");
	switch (answer)
	{
	case admission::Answer::Refuse:
		check(o.result == Reason::NotAllowed, "a refused move into a stash is NotAllowed");
		check(o.refused == (*text ? xr_string(text) : xr_string("refused by a move rule")), "the stash refusal's text");
		check(g_applied == 0, "a refused move is not applied");
		check(g_ac.refused == 1, "refused counts it");
		return;
	case admission::Answer::Admit:
		check(g_ac.let_in == 1, "let_in counts it");
		break;
	case admission::Answer::NoRule: check(g_ac.no_rule == 1, "no_rule counts it"); break;
	case admission::Answer::Failed:
		check(g_ac.failed == 1, "failed counts it");
		check(g_log_lines == 1, "a failed asking is logged");
		break;
	}
	check(o.result == apply_result, "apply_move's result is returned");
	expect_applied(kClientCharacter, kStash, nullptr);
	const bool held = answer == admission::Answer::Admit && apply_result == Reason::Ok;
	check(g_admission.holds(kItem) == held, "a let-in move is held until it lands; anything else is not");
	check(g_ac.undone == (answer == admission::Answer::Admit && apply_result != Reason::Ok ? 1u : 0u),
	    "a let-in move that apply_move did not do is released (undone)");
}

int run(const std::string& s)
{
	using A = admission::Answer;
	const char* display = "refused: a weapon showcase display copy";
	if (s == "ground-from-box")
		ground(kBox);
	else if (s == "ground-from-player")
		ground(kClientCharacter);
	else if (s == "player-refuse-text")
		player(kClientCharacter, A::Refuse, display, Reason::Ok);
	else if (s == "player-refuse-default")
		player(kClientCharacter, A::Refuse, "", Reason::Ok);
	else if (s == "host-actor-refuse")
		player(kHostActor, A::Refuse, display, Reason::Ok);
	else if (s == "inside-player-refuse")
		player(kInsideClient, A::Refuse, display, Reason::Ok);
	else if (s == "player-admit")
		player(kClientCharacter, A::Admit, "", Reason::Ok);
	else if (s == "player-no-rule")
		player(kClientCharacter, A::NoRule, "", Reason::Ok);
	else if (s == "host-actor-no-rule")
		player(kHostActor, A::NoRule, "", Reason::Ok);
	else if (s == "player-failed")
		player(kClientCharacter, A::Failed, "attempt to index a nil value", Reason::Ok);
	else if (s == "player-apply-fails")
		player(kClientCharacter, A::Admit, "", Reason::Moved);
	else if (s == "container-admit")
		container(A::Admit, "", Reason::Ok);
	else if (s == "container-refuse-text")
		container(A::Refuse, "refused: the stash is full", Reason::Ok);
	else if (s == "container-refuse-default")
		container(A::Refuse, "", Reason::Ok);
	else if (s == "container-no-rule")
		container(A::NoRule, "", Reason::Ok);
	else if (s == "container-failed")
		container(A::Failed, "attempt to call a nil value", Reason::Ok);
	else if (s == "container-apply-fails")
		container(A::Admit, "", Reason::Moved);
	else
	{
		std::fprintf(stderr, "unknown scenario %s\n", s.c_str());
		return 2;
	}
	return g_failures ? 1 : 0;
}
} // namespace requests
} // namespace coop

int main(int argc, char** argv)
{
	if (argc != 2)
	{
		std::fprintf(stderr, "usage: move_admission_wiring <scenario>\n");
		return 2;
	}
	return coop::requests::run(argv[1]);
}
