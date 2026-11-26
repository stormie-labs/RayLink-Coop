// Anomaly Coop unit tests: the scope of every game message and the route a process gives it (xrCoop/coop_scope.h;
// docs/plans/2026-10-24-f3a-split-levels.md §2.2). Core is the session's, World the world server's, Map the authority of
// the sender's level, Trunk the link between the host's process and a map server. route() is a pure function with a
// test on every cell.
#include "test_util.h"
#include "coop_protocol.h"
#include "srv/coop_scope.h"

#include <algorithm>
#include <cstring>
#include <string>

using namespace coop;

namespace
{
const char* route_name(Route r)
{
	switch (r)
	{
	case Route::HandleHere: return "HandleHere";
	case Route::TunnelToServer: return "TunnelToServer";
	case Route::RefuseNotTrunk: return "RefuseNotTrunk";
	}
	return "?";
}

struct Row
{
	Msg type;
	Scope scope;
};

constexpr Scope kWorld = Scope::World;
constexpr Scope kMap = Scope::Map;
constexpr Scope kTrunk = Scope::Trunk;

// Every game message and its scope, from the table of §2.2 (the lines name the families it lists). A new message needs
// its decision here: scope_every_named_game_message_has_a_scope fails without it.
constexpr Row kExpected[] = {
	// session / join / world lifecycle: the world server (Join*, Transition*)
	{Msg::JoinRequest, kWorld},
	{Msg::WorldBlob, kWorld},
	{Msg::WorldLoaded, kWorld},
	{Msg::JoinComplete, kWorld},
	{Msg::SessionReset, kWorld},
	{Msg::LevelChange, kWorld},
	{Msg::TransitionVote, kWorld},
	{Msg::TransitionState, kWorld},
	{Msg::AvatarList, kWorld},
	{Msg::CharOffer, kWorld},
	{Msg::CharChoice, kWorld},
	// players: the stream of the body belongs to the authority of its level; the life states to the world server
	{Msg::PlayerState, kMap},
	{Msg::PlayerVitals, kMap},
	{Msg::PlayerEquip, kMap},
	{Msg::PlayerAnim, kMap},
	{Msg::PlayerShot, kMap},
	{Msg::PlayerGrenade, kMap},
	{Msg::PlayerHit, kMap},
	{Msg::PlayerWounded, kWorld},
	{Msg::PlayerRevive, kWorld},
	{Msg::PlayerDied, kWorld},
	{Msg::PlayerRules, kWorld},
	// entities: the authority of the level
	{Msg::EntitySpawn, kMap},
	{Msg::EntityDestroy, kMap},
	{Msg::EntitySwitch, kMap},
	{Msg::EntitySnapshot, kMap},
	{Msg::EntityAnim, kMap},
	{Msg::EntityEvent, kMap},
	{Msg::EntityHealth, kMap},
	{Msg::EntityDied, kMap},
	{Msg::EntityParent, kMap},
	{Msg::EntityState, kMap},
	{Msg::EntityLocal, kMap},
	{Msg::ItemState, kMap},
	{Msg::EntitySound, kMap},
	{Msg::EntityVisual, kMap},
	{Msg::EntityHash, kMap}, // the roster (coop_reconcile.h): the authority of the level compares it
	{Msg::EntityRoster, kMap},
	{Msg::EntityResync, kMap},
	{Msg::EntityTraits, kMap},
	{Msg::EntitySquad, kMap},
	{Msg::LampState, kMap},
	{Msg::Thunderbolt, kMap},
	// requests (Req*, except the money) and their results
	{Msg::ReqSpawn, kMap},
	{Msg::ReqDestroy, kMap},
	{Msg::ReqTake, kMap},
	{Msg::ReqDrop, kMap},
	{Msg::ReqTransfer, kMap},
	{Msg::ReqUse, kMap},
	{Msg::ReqHit, kMap},
	{Msg::ReqResult, kMap},
	{Msg::ReqMoney, kWorld},
	{Msg::ReqContainer, kMap},
	{Msg::ReqItemEvent, kMap},
	{Msg::ReqLaunch, kMap},
	// world state: the time and the emission are the world server's, the weather sections and zones the level's
	{Msg::TimeSync, kWorld},
	{Msg::WeatherSync, kMap},
	{Msg::Emission, kWorld},
	{Msg::ZoneState, kMap},
	{Msg::TimeRequest, kWorld},
	// quests, story, PDA: the world server
	{Msg::InfoPortion, kWorld},
	{Msg::TaskList, kWorld},
	{Msg::TaskUpdate, kWorld},
	{Msg::MapSpot, kWorld},
	{Msg::Relation, kWorld},
	{Msg::Progress, kWorld},
	{Msg::StoryHash, kWorld},
	{Msg::StoryResync, kWorld},
	{Msg::IdLease, kMap},
	{Msg::IdLeaseAck, kMap},
	// dialogs and trade: the authority of the level the NPC stands on
	{Msg::DialogLock, kMap},
	{Msg::DialogLockResult, kMap},
	{Msg::DialogUnlock, kMap},
	{Msg::DialogPhrases, kMap},
	{Msg::DialogSelect, kMap},
	{Msg::TradeOp, kMap},
	// F2 mod layer: money and coop.sync live at the world server
	{Msg::MoneyBalance, kWorld},
	{Msg::SyncSet, kWorld},
	{Msg::SyncFull, kWorld},
	{Msg::SyncRequest, kWorld},
	{Msg::SyncResult, kWorld},
	{Msg::SyncCast, kWorld},
	// F3 checkpoints, shared sleep, death
	{Msg::CheckpointState, kWorld},
	{Msg::CheckpointClaim, kWorld},
	{Msg::RestRequest, kWorld},
	{Msg::RestState, kWorld},
	{Msg::RestSleep, kWorld},
	{Msg::DeathMarker, kMap},
	{Msg::MonsterEffect, kMap}, // audit A5
	{Msg::NewCharacter, kWorld},
	// scripting and diagnostics
	{Msg::ScriptEvent, kWorld},
	{Msg::DebugState, kWorld}, // protocol 29: the server's debug
	{Msg::StateDumpRequest, kMap},
	{Msg::StateDump, kMap},
	// F3a: the world server and the players
	{Msg::LevelMap, kWorld},
	{Msg::LevelMove, kWorld},
	{Msg::LevelMoveResult, kWorld},
	{Msg::LoadWait, kWorld},
	{Msg::LoadReady, kWorld},
	// F3a: the trunk, host process <-> map server
	{Msg::LevelFlush, kTrunk},
	{Msg::LevelSnapshot, kTrunk},
	{Msg::LevelEntity, kTrunk},
	{Msg::LevelXferUp, kTrunk},
	{Msg::LevelXferDown, kTrunk},
	{Msg::LevelBrain, kTrunk},
	{Msg::LevelHash, kTrunk},
	{Msg::LevelResync, kTrunk},
	{Msg::Tunnel, kTrunk},
	{Msg::MapServerState, kTrunk},
	{Msg::MapServerOrder, kTrunk},
	// R32 (protocol 34): the journal of a map server and its answer, over the trunk alone
	{Msg::LevelJournal, kTrunk},
	{Msg::LevelJournalAck, kTrunk},
	// F5 vehicles: a car of the sender's level (test_protocol_f5.cpp)
	{Msg::VehicleReq, kMap},
	{Msg::VehicleSeat, kMap},
	{Msg::VehicleInput, kMap},
	{Msg::VehicleState, kMap},
};

std::string verdict(const std::string& what, bool ok)
{
	return what + (ok ? " is classified" : " is not");
}
} // namespace

TEST(scope_every_named_game_message_has_a_scope)
{
	// A new message (coop_protocol.h) needs its row in scope_of (coop_scope.h) and its decision in kExpected above.
	for (uint32_t v = uint32_t(Msg::GameBase); v <= 0xFFFFu; ++v)
	{
		const Msg m = static_cast<Msg>(v);
		if (std::strncmp(msg_name(m), "Msg_0x", 6) == 0)
			continue; // not a message of the protocol
		const std::string what = std::string(msg_name(m)) + " (scope_of)";
		CHECK_EQ(verdict(what, scope_listed(m)), verdict(what, true));
		const auto listed = std::count_if(std::begin(kExpected), std::end(kExpected), [&](const Row& r) { return r.type == m; });
		const std::string what2 = std::string(msg_name(m)) + " (kExpected, " + std::to_string(listed) + " rows)";
		CHECK_EQ(verdict(what2, listed == 1), verdict(what2, true));
	}
	for (const Row& r : kExpected)
		CHECK_EQ(std::string(msg_name(r.type)) + " has scope " + scope_name(scope_of(r.type)),
		    std::string(msg_name(r.type)) + " has scope " + scope_name(r.scope));
}

TEST(scope_core_messages_stay_with_the_session)
{
	// below GameBase: the handshake, blobs, the roster, the chat; never anything else
	for (Msg m : {Msg::Hello, Msg::Welcome, Msg::Reject, Msg::Bye, Msg::BlobBegin, Msg::BlobChunk, Msg::BlobEnd,
	         Msg::PeerList, Msg::Chat, Msg::WorldEpoch})
	{
		CHECK(scope_listed(m));
		CHECK(scope_of(m) == Scope::Core);
	}
	for (const Row& r : kExpected)
		CHECK(scope_of(r.type) != Scope::Core);
	// a value that is no message of the protocol is no row, and falls to the world server (the safe, untunnelled side)
	CHECK(!scope_listed(static_cast<Msg>(0x7777)));
	CHECK(scope_of(static_cast<Msg>(0x7777)) == Scope::World);
}

TEST(scope_trunk_matches_the_senders)
{
	// What only the bridge sends is the trunk's; the trunk is never a client's request.
	for (const Row& r : kExpected)
	{
		if (msg_sender(r.type) == MsgSender::TrunkOnly)
			CHECK_EQ(std::string(msg_name(r.type)) + " is " + scope_name(scope_of(r.type)),
			    std::string(msg_name(r.type)) + " is Trunk");
		if (scope_of(r.type) == Scope::Trunk)
			CHECK(msg_sender(r.type) != MsgSender::ClientOnly);
	}
	// Level* are the trunk's, except the three a player sees and sends; Tunnel and MapServer* too (§2.2)
	for (Msg m : {Msg::LevelFlush, Msg::LevelSnapshot, Msg::LevelEntity, Msg::LevelXferUp, Msg::LevelXferDown, Msg::LevelBrain,
	         Msg::LevelHash, Msg::LevelResync, Msg::Tunnel, Msg::MapServerState, Msg::MapServerOrder, Msg::LevelJournal,
	         Msg::LevelJournalAck})
		CHECK(scope_of(m) == Scope::Trunk);
	for (Msg m : {Msg::LevelMap, Msg::LevelMove, Msg::LevelMoveResult, Msg::LoadWait, Msg::LoadReady})
		CHECK(scope_of(m) == Scope::World);
}

TEST(scope_examples)
{
	// §2.2, one line per family
	CHECK(scope_of(Msg::Hello) == Scope::Core);
	CHECK(scope_of(Msg::Chat) == Scope::Core);

	CHECK(scope_of(Msg::JoinRequest) == Scope::World);
	CHECK(scope_of(Msg::TimeSync) == Scope::World);
	CHECK(scope_of(Msg::Emission) == Scope::World);
	CHECK(scope_of(Msg::InfoPortion) == Scope::World);
	CHECK(scope_of(Msg::TaskUpdate) == Scope::World);
	CHECK(scope_of(Msg::Relation) == Scope::World);
	CHECK(scope_of(Msg::Progress) == Scope::World);
	CHECK(scope_of(Msg::StoryHash) == Scope::World);
	CHECK(scope_of(Msg::ReqMoney) == Scope::World); // Req*, but the money is the world server's book
	CHECK(scope_of(Msg::MoneyBalance) == Scope::World);
	CHECK(scope_of(Msg::SyncSet) == Scope::World);
	CHECK(scope_of(Msg::CheckpointClaim) == Scope::World);
	CHECK(scope_of(Msg::RestState) == Scope::World);
	CHECK(scope_of(Msg::NewCharacter) == Scope::World);
	CHECK(scope_of(Msg::TransitionVote) == Scope::World);
	CHECK(scope_of(Msg::LevelMove) == Scope::World);
	CHECK(scope_of(Msg::LoadReady) == Scope::World);
	CHECK(scope_of(Msg::PlayerRules) == Scope::World);
	CHECK(scope_of(Msg::PlayerWounded) == Scope::World);
	CHECK(scope_of(Msg::PlayerRevive) == Scope::World);
	CHECK(scope_of(Msg::PlayerDied) == Scope::World);

	CHECK(scope_of(Msg::PlayerState) == Scope::Map);
	CHECK(scope_of(Msg::PlayerVitals) == Scope::Map);
	CHECK(scope_of(Msg::PlayerEquip) == Scope::Map);
	CHECK(scope_of(Msg::PlayerShot) == Scope::Map);
	CHECK(scope_of(Msg::PlayerHit) == Scope::Map);
	CHECK(scope_of(Msg::EntitySpawn) == Scope::Map);
	CHECK(scope_of(Msg::EntitySnapshot) == Scope::Map);
	CHECK(scope_of(Msg::ReqTake) == Scope::Map);
	CHECK(scope_of(Msg::ReqHit) == Scope::Map);
	CHECK(scope_of(Msg::DialogLock) == Scope::Map);
	CHECK(scope_of(Msg::TradeOp) == Scope::Map);
	CHECK(scope_of(Msg::ZoneState) == Scope::Map);
	CHECK(scope_of(Msg::WeatherSync) == Scope::Map);
	CHECK(scope_of(Msg::IdLease) == Scope::Map);
	CHECK(scope_of(Msg::IdLeaseAck) == Scope::Map);
	CHECK(scope_of(Msg::DeathMarker) == Scope::Map);

	CHECK(scope_of(Msg::LevelXferUp) == Scope::Trunk);
	CHECK(scope_of(Msg::Tunnel) == Scope::Trunk);
	CHECK(scope_of(Msg::MapServerState) == Scope::Trunk);
}

// ---------------------------------------------------------------------------------------------- route()

TEST(route_core_is_the_sessions_whatever_the_flag)
{
	for (bool from_trunk : {false, true})
		CHECK_EQ(std::string(route_name(route(Scope::Core, from_trunk))), std::string("HandleHere"));
}

TEST(route_world_is_always_the_world_servers)
{
	// the world server is the process that receives it; a player on a level of a map server asks the same process
	for (bool from_trunk : {false, true})
		CHECK_EQ(std::string(route_name(route(Scope::World, from_trunk))), std::string("HandleHere"));
}

TEST(route_map_goes_to_the_authority_of_the_senders_level)
{
	// owner 2026-11-18, no hybrid: the world server leads no level, the map server of the sender's level is its authority. From a
	// player or from the trunk (a map server's virtual player, a tunnel opened): the same rule
	CHECK_EQ(std::string(route_name(route(Scope::Map, false))), std::string("TunnelToServer"));
	CHECK_EQ(std::string(route_name(route(Scope::Map, true))), std::string("TunnelToServer"));
}

TEST(route_trunk_only_from_the_bridge)
{
	CHECK_EQ(std::string(route_name(route(Scope::Trunk, true))), std::string("HandleHere"));
	CHECK_EQ(std::string(route_name(route(Scope::Trunk, false))), std::string("RefuseNotTrunk"));
}

TEST(route_every_cell_of_the_table)
{
	// 4 scopes x from_trunk: the whole table in one place
	struct Cell
	{
		Scope scope;
		bool from_trunk;
		Route want;
	};
	const Cell cells[] = {
		{Scope::Core, false, Route::HandleHere}, {Scope::Core, true, Route::HandleHere},
		{Scope::World, false, Route::HandleHere}, {Scope::World, true, Route::HandleHere},
		{Scope::Map, false, Route::TunnelToServer}, {Scope::Map, true, Route::TunnelToServer},
		{Scope::Trunk, false, Route::RefuseNotTrunk}, {Scope::Trunk, true, Route::HandleHere},
	};
	for (const Cell& c : cells)
	{
		const std::string what = std::string(scope_name(c.scope)) + (c.from_trunk ? " from the trunk" : " from a player");
		CHECK_EQ(what + ": " + route_name(route(c.scope, c.from_trunk)), what + ": " + route_name(c.want));
	}
}

// ---------------------------------------------------------------------------------------------- also_to_level_authority

TEST(scope_also_to_level_authority)
{
	// A world message that touches the body of a player (it lives on the map of its authority) also goes there.
	for (Msg m : {Msg::PlayerWounded, Msg::PlayerRevive, Msg::PlayerDied, Msg::CheckpointClaim, Msg::RestRequest})
	{
		CHECK_EQ(std::string(msg_name(m)) + (also_to_level_authority(m) ? " also goes to the authority" : " stays at the world server"),
		    std::string(msg_name(m)) + " also goes to the authority");
		CHECK(scope_of(m) == Scope::World);
	}
	// Only world messages are on the list: a map message goes to the authority anyway, a core or trunk one never.
	for (const Row& r : kExpected)
	{
		if (!also_to_level_authority(r.type))
			continue;
		CHECK_EQ(std::string(msg_name(r.type)) + " is " + scope_name(r.scope), std::string(msg_name(r.type)) + " is World");
	}
	// the rest of the world messages stay at the world server
	for (Msg m : {Msg::InfoPortion, Msg::ReqMoney, Msg::MoneyBalance, Msg::TimeSync, Msg::LevelMove, Msg::LoadReady,
	         Msg::TransitionVote, Msg::PlayerRules, Msg::NewCharacter, Msg::SyncSet})
		CHECK(!also_to_level_authority(m));
	CHECK(!also_to_level_authority(Msg::Hello));
	CHECK(!also_to_level_authority(Msg::Tunnel));
}

// ---------------------------------------------------------------------------------------------- R32: the co-op rows stay

namespace
{
// The messages of the whole range for which `pred` holds.
template <class P>
std::vector<std::string> names_where(P&& pred)
{
	std::vector<std::string> out;
	for (uint32_t v = 0; v <= 0xFFFFu; ++v)
	{
		const Msg m = static_cast<Msg>(uint16_t(v));
		if (scope_listed(m) && pred(m))
			out.push_back(msg_name(m));
	}
	std::sort(out.begin(), out.end());
	return out;
}

std::string joined(const std::vector<std::string>& v)
{
	std::string s;
	for (const std::string& n : v)
		s += (s.empty() ? "" : ", ") + n;
	return s;
}
} // namespace

TEST(scope_r32_the_coop_rows_are_unchanged)
{
	// TZ R32 (protocol 34) changes what a map server may ask its world (StateDumpRequest, EntityResync) and what the world tells the
	// map servers (EntityDied, EntityHash): coop_mapserver_rules.h, the Server's. The scopes and the players' rows of every message
	// are protocol 33's: a co-op session (split off) and a player on another level see no change.
	CHECK_EQ(joined(names_where([](Msg m) { return reaches_every_level(m); })),
	    std::string("EntityDestroy, EntityParent, EntitySpawn, EntitySquad"));
	CHECK_EQ(joined(names_where([](Msg m) { return kept_from_every_level(m); })),
	    std::string("IdLeaseAck, ItemState, PlayerEquip, PlayerVitals, StateDumpRequest"));
	CHECK_EQ(joined(names_where([](Msg m) { return also_to_level_authority(m); })),
	    std::string("CheckpointClaim, PlayerDied, PlayerRevive, PlayerWounded, RestRequest"));
	// co-op: every message goes and is taken as always, wherever the player stands
	CHECK(names_where([](Msg m) { return !level_passes(m, false, false) || !level_passes(m, false, true); }).empty());
	CHECK(names_where([](Msg m) { return !level_takes(m, false, false) || !level_takes(m, false, true); }).empty());
	// the four messages of R32 keep their scope, their route and their rows for the players
	for (const Msg m : {Msg::EntityDied, Msg::EntityHash, Msg::StateDumpRequest, Msg::EntityResync})
	{
		CHECK_EQ(std::string(msg_name(m)) + " is " + scope_name(scope_of(m)), std::string(msg_name(m)) + " is Map");
		CHECK(route(scope_of(m), false) == Route::TunnelToServer);
		CHECK(level_passes(m, true, true));
	}
	CHECK(!level_passes(Msg::EntityDied, true, false)); // a player on another level hears a death from the map server of his own
	CHECK(!level_passes(Msg::EntityHash, true, false));
	CHECK(level_takes(Msg::StateDumpRequest, true, false)); // his repair: kept (P99: answered here only while his map server is not
	                                                        // connected, mapserver::route_incoming; test_srv_repair_answer.cpp)
	CHECK(!level_takes(Msg::EntityResync, true, false));
	// the journal is the trunk's: never a player's, never on a co-op player's way
	for (const Msg m : {Msg::LevelJournal, Msg::LevelJournalAck})
	{
		CHECK(route(scope_of(m), false) == Route::RefuseNotTrunk);
		CHECK(route(scope_of(m), true) == Route::HandleHere);
		CHECK(!also_to_level_authority(m));
	}
}
