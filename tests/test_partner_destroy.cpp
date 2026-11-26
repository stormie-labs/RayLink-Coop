// Anomaly Coop unit tests: O2-partner, the windows that keep a raw pointer to their partner (crash reports of build 56:
// RL-8CGN-EU7U, 0xE06D7363 bad cast in CActor::OnDialogSoundHandlerStop from CUITalkWnd::StopSnd; RL-AYXZ-JTV4, access violation
// in CUIActorMenu::Update, mmTrade). Triage: vault "Разбор отчётов RayLink-Reports — 2026-11-23", C1a item 3.
//   1. The rules (xrCoop/coop_partner_rules.h): which window lets go of an inventory owner that is destroyed, and which a revoked
//      talk lock closes.
//   2. Why: what the stock reads of a partner on a window's close and every frame (the facts the crash reports showed).
//   3. The wiring, read from the sources (the engine's files cannot run here, as tests/test_issue_p45_kill_record.cpp): the hook in
//      CGameObject::net_Destroy, coop_trade.cpp applying the rules (each close under its own field of the answer), coop_dialog's
//      lock revoke, coop_join's SessionReset that closes
//      the dialogs before the session state goes, and coop_join's log lines (ASCII, no '!' for expected states, the changer-less
//      level change of a co-op client on the HUD).
// Both modes run the same Core code: Coop (the host releases or switches off an NPC, the host loads a save), Server (the map server
// releases or switches off an NPC, the world server sends a player's SessionReset). A process without windows (a world server, a
// map server) has no CurrentGameUI: the hook does nothing there.
#include "test_util.h"

#include "coop_partner_rules.h"

#include <fstream>
#include <regex>
#include <sstream>
#include <string>

namespace
{
using coop::partner_rules::Closes;
using coop::partner_rules::Menu;
using coop::partner_rules::Windows;

// engine/src, found next to this source file (tests\ -> ..\engine\src)
std::string pd_engine_src()
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	if (slash == std::string::npos)
		return "engine/src";
	here.resize(slash);
	return here + "/../engine/src";
}

std::string pd_read(const std::string& path)
{
	std::ifstream in(path, std::ios::binary);
	std::ostringstream s;
	s << in.rdbuf();
	return s.str();
}

// The source with // and /* */ comments blanked (string literals kept).
std::string pd_code(const std::string& src)
{
	std::string out = src;
	enum class St
	{
		Code,
		Line,
		Block,
		Str,
		Chr
	} st = St::Code;
	for (size_t i = 0; i < out.size(); ++i)
	{
		const char c = out[i];
		const char n = i + 1 < out.size() ? out[i + 1] : '\0';
		switch (st)
		{
		case St::Code:
			if (c == '/' && n == '/')
			{
				st = St::Line;
				out[i] = out[i + 1] = ' ';
				++i;
			}
			else if (c == '/' && n == '*')
			{
				st = St::Block;
				out[i] = out[i + 1] = ' ';
				++i;
			}
			else if (c == '"')
				st = St::Str;
			else if (c == '\'')
				st = St::Chr;
			break;
		case St::Line:
			if (c == '\n')
				st = St::Code;
			else
				out[i] = ' ';
			break;
		case St::Block:
			if (c == '*' && n == '/')
			{
				out[i] = out[i + 1] = ' ';
				++i;
				st = St::Code;
			}
			else if (c != '\n')
				out[i] = ' ';
			break;
		case St::Str:
			if (c == '\\')
				++i;
			else if (c == '"')
				st = St::Code;
			break;
		case St::Chr:
			if (c == '\\')
				++i;
			else if (c == '\'')
				st = St::Code;
			break;
		}
	}
	return out;
}

std::string pd_file(const std::string& rel) { return pd_code(pd_read(pd_engine_src() + "/" + rel)); }

std::string pd_collapse(const std::string& s)
{
	const std::string r = std::regex_replace(s, std::regex(R"(\s+)"), " ");
	return std::regex_replace(r, std::regex(R"(^ | $)"), "");
}

bool pd_has(const std::string& text, const std::string& what) { return text.find(what) != std::string::npos; }

size_t pd_at(const std::string& text, const std::string& what)
{
	const size_t at = text.find(what);
	return at == std::string::npos ? size_t(-1) : at;
}

// The body between the braces that open at `open` (the index of '{'); "" when they do not close.
std::string pd_braced(const std::string& code, size_t open)
{
	int depth = 1;
	size_t i = open + 1;
	for (; i < code.size() && depth; ++i)
		depth += code[i] == '{' ? 1 : (code[i] == '}' ? -1 : 0);
	return depth ? "" : code.substr(open + 1, i - 2 - open);
}

// The collapsed body of the first function whose head matches `head` (a regex ending at the name); "<none>" and a failure when none.
std::string pd_body(const std::string& code, const std::string& head)
{
	std::smatch m;
	if (!std::regex_search(code, m, std::regex(head + R"(\s*\([^;{]*\)\s*(?:const\s*)?\{)")))
	{
		t::report_failure(__FILE__, __LINE__, "no function " + head);
		return "<none>";
	}
	return pd_collapse(pd_braced(code, size_t(m.position(0) + m.length(0) - 1)));
}

// How many times `what` is in `text` (not overlapping).
size_t pd_count(const std::string& text, const std::string& what)
{
	size_t n = 0;
	for (size_t at = text.find(what); at != std::string::npos; at = text.find(what, at + what.size()))
		++n;
	return n;
}

// True when `a` comes before `b` in `text` and both are there.
bool pd_before(const std::string& text, const std::string& a, const std::string& b)
{
	const size_t x = pd_at(text, a);
	const size_t y = pd_at(text, b);
	return x != size_t(-1) && y != size_t(-1) && x < y;
}

bool pd_ascii(const std::string& code)
{
	for (const char c : code)
		if (static_cast<unsigned char>(c) >= 0x80)
			return false;
	return true;
}

Windows pd_trade_with_it()
{
	Windows w;
	w.menu_shown = true;
	w.menu = Menu::Trade;
	w.menu_partner = true;
	w.talk_shown = true; // the trade was opened from the talk: the talk window lies under it
	w.talk_partner = true;
	w.actor_talks = true;
	return w;
}
} // namespace

// ---------------------------------------------------------------- 1. the rules

// A trade opened from a talk, the trader goes: the menu closes and forgets it, the actor stops talking, the talk window hides.
TEST(partner_destroy_closes_every_window_that_shows_it)
{
	const Closes c = coop::partner_rules::on_destroy(pd_trade_with_it());
	CHECK(c.hide_menu);
	CHECK(c.forget_menu_partner);
	CHECK(c.stop_talk);
	CHECK(c.hide_talk);
}

// RL-AYXZ-JTV4 was a trade, but an upgrade (a mechanic) and a corpse's search keep the same pointer: any mode of the menu closes.
TEST(partner_destroy_closes_the_menu_in_every_mode)
{
	for (const Menu mode : {Menu::Trade, Menu::Upgrade, Menu::Search, Menu::Other})
	{
		Windows w;
		w.menu_shown = true;
		w.menu = mode;
		w.menu_partner = true;
		const Closes c = coop::partner_rules::on_destroy(w);
		CHECK(c.hide_menu);
		CHECK(c.forget_menu_partner);
		CHECK(!c.stop_talk);
		CHECK(!c.hide_talk);
	}
}

// A hidden menu keeps its last partner until the next trade: it forgets a partner that goes, and nothing is closed twice.
TEST(partner_destroy_hidden_menu_only_forgets_it)
{
	Windows w;
	w.menu_partner = true;
	const Closes c = coop::partner_rules::on_destroy(w);
	CHECK(!c.hide_menu);
	CHECK(c.forget_menu_partner);
	CHECK(!c.stop_talk);
	CHECK(!c.hide_talk);
}

// RL-8CGN-EU7U: a talk without a trade. The window hides (its StopSnd reads the partner) and the actor's own pointer goes.
TEST(partner_destroy_talk_alone)
{
	Windows w;
	w.talk_shown = true;
	w.talk_partner = true;
	w.actor_talks = true;
	const Closes c = coop::partner_rules::on_destroy(w);
	CHECK(!c.hide_menu);
	CHECK(!c.forget_menu_partner);
	CHECK(c.stop_talk);
	CHECK(c.hide_talk);

	// the talk was stopped already (a revoked lock: the window hides on its next update), the partner goes before that update
	w.actor_talks = false;
	const Closes late = coop::partner_rules::on_destroy(w);
	CHECK(!late.stop_talk);
	CHECK(late.hide_talk);

	// a talk whose window is not shown (the menu over it, a scripted talk): the actor's pointer still goes
	Windows hidden;
	hidden.actor_talks = true;
	CHECK(coop::partner_rules::on_destroy(hidden).stop_talk);
	CHECK(!coop::partner_rules::on_destroy(hidden).hide_talk);
}

// Every other NPC that goes leaves the windows of this partner alone (the hook runs for every inventory owner destroyed).
TEST(partner_destroy_leaves_the_windows_of_another_partner)
{
	Windows w = pd_trade_with_it();
	w.menu_partner = false;
	w.talk_partner = false;
	w.actor_talks = false;
	const Closes c = coop::partner_rules::on_destroy(w);
	CHECK(!c.hide_menu);
	CHECK(!c.forget_menu_partner);
	CHECK(!c.stop_talk);
	CHECK(!c.hide_talk);
	const Closes none = coop::partner_rules::on_destroy(Windows{});
	CHECK(!none.hide_menu && !none.forget_menu_partner && !none.stop_talk && !none.hide_talk);
}

// The host took back the talk lock: the talk stops, a trade or an upgrade with that NPC closes with it; the NPC is whole and stays
// in the menu's memory; the talk window hides itself on its next update, as before.
TEST(partner_lock_revoke_closes_trade_and_upgrade_with_it)
{
	for (const Menu mode : {Menu::Trade, Menu::Upgrade})
	{
		Windows w = pd_trade_with_it();
		w.menu = mode;
		const Closes c = coop::partner_rules::on_lock_revoked(w);
		CHECK(c.hide_menu);
		CHECK(!c.forget_menu_partner);
		CHECK(c.stop_talk);
		CHECK(!c.hide_talk);
	}
	// the player's inventory or a search is no window of that talk
	for (const Menu mode : {Menu::Search, Menu::Other})
	{
		Windows w = pd_trade_with_it();
		w.menu = mode;
		const Closes c = coop::partner_rules::on_lock_revoked(w);
		CHECK(!c.hide_menu);
		CHECK(c.stop_talk);
	}
	// a trade with another trader, a hidden menu: stays
	Windows other = pd_trade_with_it();
	other.menu_partner = false;
	CHECK(!coop::partner_rules::on_lock_revoked(other).hide_menu);
	Windows hidden = pd_trade_with_it();
	hidden.menu_shown = false;
	CHECK(!coop::partner_rules::on_lock_revoked(hidden).hide_menu);
	// no talk with it: nothing stops (the revoke came late)
	Windows quiet;
	CHECK(!coop::partner_rules::on_lock_revoked(quiet).stop_talk);
}

// ---------------------------------------------------------------- 2. why (the stock)

// The talk window hands its partner to CActor::OnDialogSoundHandlerStop on its close (StopSnd from Show(false)), and that one
// smart_casts it: a dynamic_cast that throws a bad cast (0xE06D7363) on a freed partner. The actor menu reads the trader's inventory
// every frame of a trade; the actor's own talk reads its partner every frame. Stock closes them only in CLevel::net_Stop.
TEST(partner_destroy_stock_reads_the_partner_on_close_and_every_frame)
{
	const std::string talk = pd_file("xrGame/ui/UITalkWnd.cpp");
	REQUIRE(!talk.empty());
	CHECK(pd_has(pd_body(talk, R"(void\s+CUITalkWnd::StopSnd)"), "m_pActor->OnDialogSoundHandlerStop(m_pOthersInvOwner)"));
	const std::string show = pd_body(talk, R"(void\s+CUITalkWnd::Show)");
	CHECK(pd_before(show, "coop::dialog::on_talk_window_closed();", "StopSnd();"));
	const std::string update = pd_body(talk, R"(void\s+CUITalkWnd::Update)");
	CHECK(pd_has(update, "m_pOthersInvOwner->IsTradeEnabled()"));
	CHECK(pd_has(pd_collapse(pd_code(pd_read(pd_engine_src() + "/xrGame/ui/UITalkWnd.h"))),
	    "IC CInventoryOwner* OthersInvOwner() const { return m_pOthersInvOwner; };"));

	const std::string actor = pd_file("xrGame/actor_communication.cpp");
	REQUIRE(!actor.empty());
	CHECK(pd_has(pd_body(actor, R"(bool\s+CActor::OnDialogSoundHandlerStop)"), "CAI_Trader* trader = smart_cast<CAI_Trader*>(inv_owner);"));

	const std::string menu = pd_file("xrGame/ui/UIActorMenu.cpp");
	REQUIRE(!menu.empty());
	CHECK(pd_has(pd_body(menu, R"(void\s+CUIActorMenu::Update)"),
	    "case mmTrade: { if (m_pPartnerInvOwner->inventory().ModifyFrame() != m_trade_partner_inventory_state)"));
	CHECK(pd_has(pd_body(menu, R"(void\s+CUIActorMenu::SetPartner)"), "R_ASSERT(!IsShown()); m_pPartnerInvOwner = io;"));

	const std::string owner = pd_file("xrGame/InventoryOwner.cpp");
	REQUIRE(!owner.empty());
	CHECK(pd_has(pd_body(owner, R"(void\s+CInventoryOwner::UpdateInventoryOwner)"), "if (!m_pTalkPartner->IsTalking())"));
	CHECK(pd_has(pd_body(owner, R"(void\s+CInventoryOwner::StopTalk)"), "m_pTalkPartner = NULL; m_bTalking = false;"));

	const std::string level = pd_file("xrGame/Level_network.cpp");
	REQUIRE(!level.empty());
	CHECK(pd_has(pd_body(level, R"(void\s+CLevel::net_Stop)"), "CurrentGameUI()->HideShownDialogs();"));
	// CUIGameSP closes the menu and a talk on top (the base class nothing more): the windows this package is about
	const std::string sp = pd_file("xrGame/UIGameSP.cpp");
	CHECK(pd_has(pd_body(sp, R"(void\s+CUIGameSP::HideShownDialogs)"), "HideActorMenu(); CUIDialogWnd* mir = TopInputReceiver();"));
}

// ---------------------------------------------------------------- 3. the wiring

// CGameObject::net_Destroy: the first thing, before the Lua net-destroy hook and the stock teardown, while the owner is whole.
TEST(partner_destroy_game_object_hook_runs_first)
{
	const std::string go = pd_file("xrGame/GameObject.cpp");
	REQUIRE(!go.empty());
	CHECK(pd_has(go, "#include \"coop/coop_trade.h\""));
	const std::string body = pd_body(go, R"(void\s+CGameObject::net_Destroy)");
	const std::string hook = "if (CInventoryOwner* owner = cast_inventory_owner()) coop::trade::on_inv_owner_destroy(*owner);";
	CHECK(pd_has(body, hook));
	CHECK(pd_before(body, "VERIFY(m_spawned);", hook));
	CHECK(pd_before(body, hook, "ai().script_engine().functor(\"_G.CGameObject_NetDestroy\", funct)"));
	CHECK(pd_before(body, hook, "inherited::net_Destroy();"));
	CHECK(pd_before(body, hook, "xr_delete(m_lua_game_object);"));
	// one hook, no mode question (the stock file is Core: docs/MODES.md rule 8)
	CHECK(body.find("on_inv_owner_destroy") == body.rfind("on_inv_owner_destroy"));
	CHECK(!pd_has(body, "mode()"));
}

// coop_trade_views.cpp gathers the windows, asks the rules and closes in their order: the menu, its memory, the talk, the talk window.
TEST(partner_destroy_trade_applies_the_rules)
{
	const std::string trade = pd_file("xrGame/coop/coop_trade_views.cpp");
	REQUIRE(!trade.empty());
	CHECK(pd_has(trade, "#include \"xrCoop/coop_partner_rules.h\""));
	CHECK(pd_has(trade, "#include \"ui/UITalkWnd.h\""));

	const std::string destroy = pd_body(trade, R"(void\s+on_inv_owner_destroy)");
	CHECK(pd_has(destroy, "CUIGameCustom* ui = CurrentGameUI();"));
	CHECK(pd_has(destroy, "close_partner_windows(ui, owner, partner_rules::on_destroy(partner_windows(ui, owner)),"));

	const std::string revoke = pd_body(trade, R"(bool\s+on_talk_lock_revoked)");
	CHECK(pd_has(revoke, "const partner_rules::Closes c = partner_rules::on_lock_revoked(partner_windows(ui, partner));"));
	CHECK(pd_has(revoke, "return c.hide_menu || c.stop_talk;"));

	const std::string facts = pd_body(trade, R"(partner_rules::Windows\s+partner_windows)");
	CHECK(pd_has(facts, "w.menu_shown = menu.IsShown();"));
	CHECK(pd_has(facts, "case mmTrade: w.menu = partner_rules::Menu::Trade; break;"));
	CHECK(pd_has(facts, "case mmUpgrade: w.menu = partner_rules::Menu::Upgrade; break;"));
	CHECK(pd_has(facts, "case mmDeadBodySearch: w.menu = partner_rules::Menu::Search; break;"));
	CHECK(pd_has(facts, "w.menu_partner = menu.GetPartner() == &owner;"));
	CHECK(pd_has(facts, "w.talk_shown = talk->IsShown(); w.talk_partner = talk->OthersInvOwner() == &owner;"));
	CHECK(pd_has(facts, "w.actor_talks = a && a->IsTalking() && a->GetTalkPartner() == &owner;"));

	const std::string close = pd_body(trade, R"(void\s+close_partner_windows)");
	const char* const order[] = {"ui->HideActorMenu();", "menu.SetPartner(nullptr);", "a->StopTalk();", "talk->HideDialog();"};
	for (size_t i = 0; i + 1 < sizeof(order) / sizeof(order[0]); ++i)
		CHECK(pd_before(close, order[i], order[i + 1]));
	// SetPartner asserts on a shown menu: a menu that would not close is a fault, and keeps its pointer rather than assert
	CHECK(pd_has(close, "if (menu.IsShown()) ::Msg(\"! [coop] %u (%s) %s and its window would not close"));
	// the stock close of a box stays its own (InventoryBox.cpp): the box hook is unchanged
	CHECK(pd_has(pd_body(trade, R"(void\s+on_inv_box_destroy)"), "menu.SetInvBox(nullptr);"));
}

// The dispatch runs each close under its own field of the rules' answer and under nothing else. A close gated by another field
// brings a crash back although every rule stays right: a trading computer's trade (coop_trade.cpp, G6-3) has no talk, so a menu
// gated by stop_talk keeps a freed trader (RL-AYXZ-JTV4); a revoked lock stopped the talk before the partner goes, so a talk window
// gated by stop_talk keeps a freed partner for its StopSnd (RL-8CGN-EU7U). Mutations checked: temp/O2-partner/mutate.py.
TEST(partner_destroy_dispatch_gates_each_close_by_its_rule)
{
	const std::string trade = pd_file("xrGame/coop/coop_trade_views.cpp");
	REQUIRE(!trade.empty());
	const std::string close = pd_body(trade, R"(void\s+close_partner_windows)");
	// nothing to do only when no field asks for anything: the first statement and the only return
	CHECK(close.rfind("if (!c.hide_menu && !c.forget_menu_partner && !c.stop_talk && !c.hide_talk) return;", 0) == 0);
	CHECK(pd_count(close, "return") == 1);
	// each close under its own field
	CHECK(pd_has(close, "if (ui && c.hide_menu) { ui->HideActorMenu(); ::Msg("));
	CHECK(pd_has(close, "if (ui && c.forget_menu_partner) { CUIActorMenu& menu = ui->GetActorMenu(); "
	                    "if (menu.IsShown()) ::Msg(\"! [coop]"));
	CHECK(pd_has(close, "else menu.SetPartner(nullptr); }"));
	CHECK(pd_has(close, "if (c.stop_talk) { if (CActor* a = g_actor ? Actor() : nullptr) a->StopTalk(); }"));
	CHECK(pd_has(close, "CUITalkWnd* talk = (ui && c.hide_talk) ? talk_window(ui) : nullptr; if (talk) talk->HideDialog();"));
	CHECK(pd_has(close, "if (talk && talk->IsShown()) ::Msg(\"! [coop]"));
	// each close once: no second call under another field
	for (const char* call : {"HideActorMenu(", "SetPartner(", "StopTalk(", "HideDialog("})
		CHECK(pd_count(close, call) == 1);
	// the talk window the dispatch closes is the one the facts read: CUIGameSP's talk menu
	CHECK(pd_has(pd_body(trade, R"(CUITalkWnd\*\s+talk_window)"),
	    "CUIGameSP* sp = ui ? smart_cast<CUIGameSP*>(ui) : nullptr; return sp ? sp->TalkMenu : nullptr;"));
	CHECK(pd_has(pd_body(trade, R"(partner_rules::Windows\s+partner_windows)"),
	    "if (CUITalkWnd* talk = talk_window(ui)) { w.talk_shown = talk->IsShown();"));
}

// coop_dialog client_on_revoke: the lock taken back closes a trade or upgrade with that NPC as well as the talk.
TEST(partner_lock_revoke_wiring)
{
	const std::string dialog = pd_file("xrGame/coop/coop_dialog.cpp");
	REQUIRE(!dialog.empty());
	CHECK(pd_has(dialog, "#include \"coop_trade.h\""));
	const std::string revoke = pd_body(dialog, R"(void\s+client_on_revoke)");
	CHECK(pd_before(revoke, "g_cl.granted = kNoId; g_cl.start = kNoId;",
	    "CInventoryOwner* io = find_owner(join::to_local(npc)); if (io && trade::on_talk_lock_revoked(*io)) "
	    "hud_text::say(\"st_coop_talk_revoked\", \"The conversation was interrupted by the host\");"));
	CHECK(!pd_has(revoke, "Actor()->StopTalk();")); // the rules stop it (coop_trade_views.cpp close_partner_windows)
}

// The join module: coop_join.cpp and the files it is split into.
std::string pd_join()
{
	return pd_file("xrGame/coop/coop_join.cpp")
	    + pd_file("xrGame/coop/coop_join_characters.cpp")
	    + pd_file("xrGame/coop/coop_join_transition.cpp")
	    + pd_file("xrGame/coop/coop_join_transition_load.cpp")
	    + pd_file("xrGame/coop/coop_join_swap.cpp");
}

// coop_join client_on_session_reset: the dialogs of the world that goes close first, while its objects are whole and the session's
// state of them (talk lock, open container) is there to be closed; sync::reset and the load come after.
TEST(partner_session_reset_hides_the_dialogs_before_the_state_goes)
{
	const std::string join = pd_join();
	REQUIRE(!join.empty());
	CHECK(pd_has(join, "#include \"UIGameCustom.h\""));
	const std::string reset = pd_body(join, R"(void\s+client_on_session_reset)");
	const std::string hide = "if (CUIGameCustom* ui = CurrentGameUI()) ui->HideShownDialogs();";
	CHECK(pd_before(reset, "if (from != kHostPeer || mode().decides_world()) return;", hide));
	CHECK(pd_before(reset, hide, "sync::reset();"));
	CHECK(pd_before(reset, hide, "world_leaving(epoch);"));
}

// coop_join's log: ASCII only (the log is cp1251: an em dash came out as three letters), no '!' for the precache wait (an expected
// state), and the changer-less level change of a co-op client refused in the open: once in the log, the route's fade lifted, the
// HUD line each time. Where the group does not travel together (Server) the same request is still a Trip.
TEST(partner_join_log_lines)
{
	const std::string join = pd_join();
	REQUIRE(!join.empty());
	CHECK(pd_ascii(join));
	CHECK(!pd_has(join, "is not a stalker \xE2\x80\x94"));
	CHECK(pd_has(join, "::Msg(\"! [coop] section [%s] is not a stalker: check gamedata (mod_system_coop.ltx)\", world::avatar_section().c_str());"));
	CHECK(pd_ascii(pd_file("xrGame/coop/coop_trade.cpp")));
	CHECK(pd_ascii(pd_file("xrGame/coop/coop_trade_views.cpp")));
	CHECK(pd_ascii(pd_file("xrGame/coop/coop_trade_window_lua.cpp")));
	CHECK(pd_ascii(pd_file("xrGame/coop/coop_dialog.cpp")));

	const std::string precache = pd_body(join, R"(bool\s+host_precaching)");
	CHECK(pd_has(precache, "::Msg(\"[coop] the host's level is still precaching after %u s (window without focus?): joins go on\","));
	CHECK(!pd_has(precache, "\"! [coop]"));

	const std::string change = pd_body(join, R"(void\s+client_request_level_change)");
	CHECK(pd_before(change, "if (changer == kNoId && !mode().group_travels()) { client_level_trip(P); return; }",
	    "if (changer == kNoId) {"));
	const size_t at = pd_at(change, "if (changer == kNoId) {");
	REQUIRE(at != size_t(-1));
	const std::string coop_branch = change.substr(at, pd_at(change, "if (!mode().group_travels()) {") - at);
	CHECK(!pd_has(coop_branch, "\"! [coop]"));
	CHECK(pd_has(coop_branch, "if (g_board.trips_refused++ == 0) ::Msg(\"[coop] level exit: no level changer of this level leads there"));
	CHECK(pd_before(coop_branch, "client_stays_on_level();",
	    "hud_text::say(\"st_coop_core_go_host_only\", \"Only the host can move the group.\"); return; }"));
	CHECK(pd_has(pd_file("xrGame/coop/coop_join_impl.h"), "u32 trips_refused = 0;"));
	// the line on the HUD is translated: the id is in both string tables
	for (const char* lang : {"rus", "eng"})
		CHECK(pd_has(pd_read(pd_engine_src() + "/../../gamedata/configs/text/" + lang + "/st_coop_core.xml"),
		    "<string id=\"st_coop_core_go_host_only\">"));
}
