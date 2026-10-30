// Anomaly Coop unit tests: story rules shared by the engine layer and the tests (coop_rules.h).
#include "test_util.h"

#include "coop_rules.h"

using coop::Msg;
using coop::rules::client_echo;
using coop::rules::Echo;
using coop::rules::is_machine_info;
using coop::rules::live_only;

// R4 1: info portions that describe what ONE machine's UI / body is doing stay on that machine.
TEST(rules_machine_info)
{
	// Exact names.
	CHECK(is_machine_info("ui_pda"));
	CHECK(is_machine_info("actor_is_sleeping"));
	CHECK(is_machine_info("sleep_active"));

	// Prefix `ui_talk*`: the bare prefix and anything after it.
	CHECK(is_machine_info("ui_talk"));
	CHECK(is_machine_info("ui_talk_trade"));
	CHECK(is_machine_info("ui_talk_free_dialog"));
	CHECK(is_machine_info("ui_talk_"));

	// Suffix `*_wnd_open`.
	CHECK(is_machine_info("inventory_wnd_open"));
	CHECK(is_machine_info("trade_wnd_open"));
	CHECK(is_machine_info("ui_car_body_wnd_open"));
	CHECK(is_machine_info("pda_wnd_open"));

	// Story infos are shared.
	CHECK(!is_machine_info("esc_trader_task_1_done"));
	CHECK(!is_machine_info("pda_found"));
	CHECK(!is_machine_info("ui")); // no suffix
	CHECK(!is_machine_info("ui_"));
	CHECK(!is_machine_info("ui_tal")); // shorter than the prefix
}

// The patterns are a prefix, a suffix and exact names — nothing looser.
TEST(rules_machine_info_boundaries)
{
	// Exact names do not match as prefixes or suffixes.
	CHECK(!is_machine_info("ui_pda_found"));
	CHECK(!is_machine_info("my_ui_pda"));
	CHECK(!is_machine_info("actor_is_sleeping_not"));
	CHECK(!is_machine_info("actor_is_sleep"));
	CHECK(!is_machine_info("sleep_active2"));
	CHECK(!is_machine_info("not_sleep_active"));
	CHECK(!is_machine_info("sleep"));

	// `ui_talk*` is a prefix only.
	CHECK(!is_machine_info("my_ui_talk"));
	CHECK(!is_machine_info("xui_talk_trade"));

	// `*_wnd_open` is a suffix only, with its underscore.
	CHECK(!is_machine_info("trade_wnd_open_x"));
	CHECK(!is_machine_info("wnd_open"));
	CHECK(!is_machine_info("trade_wnd_opened"));
	CHECK(!is_machine_info("trade_wnd_ope"));

	// Ids are case-sensitive, like the engine's shared strings.
	CHECK(!is_machine_info("UI_PDA"));
	CHECK(!is_machine_info("UI_TALK_trade"));
	CHECK(!is_machine_info("trade_WND_OPEN"));

	// No id at all is not a machine info.
	CHECK(!is_machine_info(nullptr));
	CHECK(!is_machine_info(""));
}

// R2 I2: a world message reaches a client before it is live only from the window between Welcome and JoinRequest
// (or from a world it has left). It is dropped: what the host did before host_begin_join is in the save the client
// loads, what it does after is queued for it until WorldLoaded (P6).
TEST(rules_live_only)
{
	// World objects: applied only in Live.
	CHECK(live_only(Msg::EntityParent));
	CHECK(live_only(Msg::EntityDied));
	CHECK(live_only(Msg::EntityLocal));
	CHECK(live_only(Msg::EntityVisual));
	CHECK(live_only(Msg::EntityState));
	CHECK(live_only(Msg::ZoneState));
	CHECK(live_only(Msg::ItemState));
	CHECK(live_only(Msg::EntityEvent));
	// Live-only by their registration already (coop_entities.cpp): the rule says so too.
	CHECK(live_only(Msg::EntitySpawn));
	CHECK(live_only(Msg::EntityDestroy));
	CHECK(live_only(Msg::EntitySwitch));
	CHECK(live_only(Msg::EntitySnapshot));

	// The join lifecycle runs before Live by design.
	CHECK(!live_only(Msg::Welcome));
	CHECK(!live_only(Msg::WorldBlob));
	CHECK(!live_only(Msg::SessionReset));
	CHECK(!live_only(Msg::JoinComplete));
	CHECK(!live_only(Msg::LevelChange));
	// Not a world object: it may come before the proxies exist (F0 Task 8); its own handler decides.
	CHECK(!live_only(Msg::AvatarList));
	CHECK(!live_only(Msg::TimeSync));
	// Not a known message: not a world message either.
	CHECK(!live_only(static_cast<Msg>(0x7FFF)));
}

// R4 4: while a client applies a host broadcast (the host's story or a host command), what it does is a reaction,
// not a request: nothing of it about the host's world goes to the host. Ruling F2-12: the host runs the story's
// reactions on its own actor, so our own items (held by our actor, or given away from its inventory) are ours to
// request as before; a new object (spawn) is never one of them.
TEST(rules_client_echo)
{
	// Not applying anything: our own requests.
	CHECK_EQ(client_echo(false, false, false), Echo::Forward);
	CHECK_EQ(client_echo(false, false, true), Echo::Forward);

	// An addon reacts to the host's info portion.
	CHECK_EQ(client_echo(true, false, false), Echo::Drop); // a world object or a spawn: the host's
	CHECK_EQ(client_echo(true, false, true), Echo::Forward); // our own item: only we touch it

	// A host command applied here (entities::ClientApply): its events are the host's change itself, ours included.
	CHECK_EQ(client_echo(false, true, false), Echo::Drop);
	CHECK_EQ(client_echo(false, true, true), Echo::Drop);
	CHECK_EQ(client_echo(true, true, false), Echo::Drop);
	CHECK_EQ(client_echo(true, true, true), Echo::Drop);
}
