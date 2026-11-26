// Anomaly Coop unit tests: the kind of a root and the writer answers of the server's processes (TZ Р32, temp/r30/design/R32-final.md
// §1 W1.2, §8a A3-A6; review R32 W1 B1-B4). The pure parts of xrCoop/coop_writer_rules.h and xrCoop/srv/coop_writer_seats.h that the engine's answers call:
//   kind_of            what writing::root_facts_of names a root (coop_writer.cpp), from what it reads of the ALife object;
//   world_seat         what WorldServerMode::writer_of asks the rule with (coop_srv_mode.cpp world_writer_of), from its tables;
//   world_character_seat  the player and the map of a player's character as the world server's tables say (also decider_of);
//   map_seat           what MapServerMode::writer_of asks the rule with (map_writer_of), from a map server's tables.
// The tables are rows here (WorldRows, MapRows): the same questions the modes ask join::peer_of_proxy, levels::level_of_player,
// levels::my_level, mapserver::host_life_of / bridge_of / level_of_bridge, levels::holder_of, levels::xfer_authors, levels::xfer_born.
//
// One invariant over every row: exactly one process writes a root (the ghost: nobody), the world server names that map server's
// bridge, every other map server asks its world. The rows: a crow, a phantom, a dead monster, a parked character, a retired one, a
// played character on a led map, a just-born squad, a stopping map server, the ghost, an item in a held member's inventory; and the
// co-op host and client answers, which do not change.
#include "test_util.h"
#include "coop_writer_rules.h"
#include "srv/coop_writer_seats.h"

#include <map>
#include <set>
#include <string>
#include <vector>

namespace w = coop::writer;
using coop::PeerId;

namespace
{
// maps: A and B led, S's server starting, U unled; kOwn: the world server's own map (its ghost's)
constexpr uint16_t kA = 5, kB = 7, kS = 9, kU = 11, kOwn = 2;
constexpr PeerId kBridgeA = 101, kBridgeB = 102, kBridgeS = 103;
constexpr PeerId kAnna = 11, kBoris = 12; // players of the world
constexpr uint16_t kHim = 0x2a, kHisNew = 0x2b, kSquad = 0x300, kMember = 0x301, kBox = 0x700, kCrow = 0x710;

// The world server's tables (WorldServerMode asks the same of join, levels and mapserver).
struct WorldRows
{
	std::map<uint16_t, PeerId> players; // character -> the connected player who plays it (join::peer_of_proxy)
	std::map<PeerId, uint16_t> seats; // player -> the map of his seat (levels::level_of_player)
	uint16_t own = kOwn; // levels::my_level: its ghost's map
	std::map<uint16_t, w::MapLead> leads; // map -> its server's life and bridge (lead_of(host_life_of), bridge_of)
	std::map<uint16_t, PeerId> holders; // unit -> the bridge that holds it (levels::holder_of)
	std::map<PeerId, uint16_t> bridges; // bridge -> the map its server leads (mapserver::level_of_bridge)
	std::map<uint16_t, PeerId> made; // object -> the bridge whose ids it has (levels::host_id_is_senders)

	PeerId player_of(uint16_t character) const
	{
		const auto it = players.find(character);
		return it == players.end() ? coop::kInvalidPeer : it->second;
	}
	uint16_t seat_of(PeerId player) const
	{
		const auto it = seats.find(player);
		return it == seats.end() ? w::kNoLevel : it->second;
	}
	uint16_t own_map() const { return own; }
	w::MapLead lead_of_map(uint16_t level) const
	{
		const auto it = leads.find(level);
		return it == leads.end() ? w::MapLead{} : it->second;
	}
	PeerId holder_of(uint16_t root) const
	{
		const auto it = holders.find(root);
		return it == holders.end() ? coop::kInvalidPeer : it->second;
	}
	uint16_t map_of_bridge(PeerId bridge) const
	{
		const auto it = bridges.find(bridge);
		return it == bridges.end() ? w::kNoLevel : it->second;
	}
	PeerId maker_of(uint16_t root) const
	{
		const auto it = made.find(root);
		return it == made.end() ? coop::kInvalidPeer : it->second;
	}
};

// A map server's tables (MapServerMode asks the same of join, levels and mapserver).
struct MapRows
{
	uint16_t map; // levels::my_level
	PeerId bridge; // how its world names it
	w::Lead lead; // Leads once it said its map is up (mapserver::server_leads), until it ends; Starting before
	std::set<uint16_t> playing; // characters a player of its session plays (join::peer_of_proxy + its session)
	std::set<uint16_t> authored; // units its holder authors (levels::xfer_authors)
	std::set<uint16_t> newborn; // units it made under its slice since its last flush (levels::xfer_born)
	std::set<uint16_t> pool; // ids of its own pool that name objects (levels::xfer_made_here)

	bool plays_here(uint16_t character) const { return playing.count(character) != 0; }
	bool authors(uint16_t root) const { return authored.count(root) != 0; }
	bool born(uint16_t root) const { return newborn.count(root) != 0; }
	bool made_here(uint16_t root) const { return pool.count(root) != 0; }
};

// The world server and the map servers that run: A and B serve, S is loading its world.
struct Cluster
{
	WorldRows ws;
	std::vector<MapRows> mks;

	Cluster()
	{
		ws.leads = {{kA, {w::Lead::Leads, kBridgeA}}, {kB, {w::Lead::Leads, kBridgeB}}, {kS, {w::Lead::Starting, kBridgeS}}};
		ws.bridges = {{kBridgeA, kA}, {kBridgeB, kB}, {kBridgeS, kS}};
		mks.push_back(MapRows{kA, kBridgeA, w::Lead::Leads, {}, {}, {}, {}});
		mks.push_back(MapRows{kB, kBridgeB, w::Lead::Leads, {}, {}, {}, {}});
		mks.push_back(MapRows{kS, kBridgeS, w::Lead::Starting, {}, {}, {}, {}});
	}
	MapRows* find(uint16_t map)
	{
		for (MapRows& m : mks)
			if (m.map == map)
				return &m;
		return nullptr;
	}
	MapRows& mk(uint16_t map)
	{
		MapRows* m = find(map);
		REQUIRE(m != nullptr);
		return *m;
	}
	// `player` plays `character`, seated on `map` (kNoLevel: not seated); the server of that map has him (when one runs there)
	void plays(PeerId player, uint16_t character, uint16_t map, bool its_server_has_him)
	{
		ws.players[character] = player;
		if (map != w::kNoLevel)
			ws.seats[player] = map;
		else
			ws.seats.erase(player);
		if (its_server_has_him)
			mk(map).playing.insert(character);
	}
};

std::string map_name(uint16_t map)
{
	return map == kA ? "MkA" : map == kB ? "MkB" : map == kS ? "MkS" : "Mk" + std::to_string(map);
}

// Who writes the root, as every process answers it: the writers joined with '+' ("WS", "MkA"), "nobody" when every process says
// nobody (the ghost). What contradicts the one-writer contract is named: the world naming a bridge whose server does not write
// ("WS->MkA?"), a map server naming anyone but its world ("MkA->?"), one process saying nobody while another does not.
std::string writers(const Cluster& c, const w::RootFacts& r)
{
	std::string who;
	const auto add = [&](const std::string& n) { who += (who.empty() ? "" : "+") + n; };
	int nobodies = 0;
	const w::Asked asked = w::world_seat(r, c.ws);
	const w::Writer ws = w::writer_of(asked.root, w::Process{w::ProcessKind::World, w::kNoLevel, coop::kHostPeer}, asked.seat);
	if (ws.is == w::WriterIs::This)
		add("WS");
	nobodies += ws.is == w::WriterIs::Nobody ? 1 : 0;
	bool named = ws.is != w::WriterIs::Other;
	for (const MapRows& m : c.mks)
	{
		const w::Asked a = w::map_seat(r, m.map, m.lead, m);
		const w::Writer mk = w::writer_of(a.root, w::Process{w::ProcessKind::Level, m.map, coop::kHostPeer}, a.seat);
		if (mk.is == w::WriterIs::This)
			add(map_name(m.map));
		else if (mk.is == w::WriterIs::Other && mk.peer != coop::kHostPeer)
			add(map_name(m.map) + "->?");
		nobodies += mk.is == w::WriterIs::Nobody ? 1 : 0;
		if (ws.is == w::WriterIs::Other && ws.peer == m.bridge)
		{
			named = true;
			if (mk.is != w::WriterIs::This)
				add("WS->" + map_name(m.map) + "?");
		}
	}
	if (!named)
		add("WS->?");
	const int processes = 1 + int(c.mks.size());
	if (nobodies == processes)
		return "nobody";
	if (nobodies != 0)
		add("some say nobody");
	return who.empty() ? "none writes" : who;
}

#define WRITERS_ARE(what, c, r, want) CHECK_EQ(std::string(what) + ": " + writers(c, r), std::string(what) + ": " + (want))

// The kinds of what the Core reads of a root.
w::KindFacts creature(bool monster, bool alive, bool has_level)
{
	return w::KindFacts{false, false, false, monster, alive, has_level};
}

const char* kind_text(w::RootKind k)
{
	switch (k)
	{
	case w::RootKind::Character: return "character";
	case w::RootKind::Unit: return "unit";
	case w::RootKind::Resident: return "resident";
	case w::RootKind::None: return "none";
	}
	return "?";
}

#define KIND_IS(what, facts, want) CHECK_EQ(std::string(what) + ": " + kind_text(w::kind_of(facts)), std::string(what) + ": " + kind_text(want))

w::RootFacts root(const w::KindFacts& k, uint16_t id, uint16_t level)
{
	return w::RootFacts{w::kind_of(k), id, level};
}

std::string said(const w::Writer& wr)
{
	std::string s = w::writer_name(wr.is);
	if (wr.is == w::WriterIs::Other)
		s += "(" + std::to_string(wr.peer) + ")";
	return s;
}
} // namespace

// ------------------------------------------------------------------------------------------------- the kind of a root (B1)

TEST(writer_kind_of_every_root)
{
	// a crow (CSE_ALifeCreatureCrow) and a phantom (CSE_ALifeCreaturePhantom) are creatures, no monsters: the transfers never move
	// them (levels::transfers: a squad or a living monster), so they are their map's residents, written by its map server
	KIND_IS("living crow", creature(false, true, true), w::RootKind::Resident);
	KIND_IS("living phantom", creature(false, true, true), w::RootKind::Resident);
	KIND_IS("dead crow", creature(false, false, true), w::RootKind::Resident);
	KIND_IS("crow of no map", creature(false, true, false), w::RootKind::None);
	// a dead monster is a body: a resident
	KIND_IS("dead monster", creature(true, false, true), w::RootKind::Resident);
	// a living monster in no squad, a squad: units (granted to a map server and taken back)
	KIND_IS("living monster in no squad", creature(true, true, true), w::RootKind::Unit);
	KIND_IS("living monster of no map", creature(true, true, false), w::RootKind::Unit);
	KIND_IS("squad", (w::KindFacts{false, false, true, false, false, true}), w::RootKind::Unit);
	KIND_IS("squad of no map", (w::KindFacts{false, false, true, false, false, false}), w::RootKind::Unit);
	// a player's character, alive or dead, and the ghost (actor 0)
	KIND_IS("player character", (w::KindFacts{false, true, false, true, true, true}), w::RootKind::Character);
	KIND_IS("dead player character", (w::KindFacts{false, true, false, true, false, true}), w::RootKind::Character);
	KIND_IS("ghost", (w::KindFacts{true, false, false, false, true, true}), w::RootKind::Character);
	KIND_IS("ghost of no map", (w::KindFacts{true, false, false, false, true, false}), w::RootKind::Character);
	// a box, a ground item, a car on a map; money, a story record of none
	KIND_IS("box", (w::KindFacts{false, false, false, false, false, true}), w::RootKind::Resident);
	KIND_IS("record of no map", (w::KindFacts{false, false, false, false, false, false}), w::RootKind::None);

	// the unit predicate is the transfers' one, every combination
	for (bool group : {false, true})
		for (bool monster : {false, true})
			for (bool alive : {false, true})
				CHECK_EQ(std::to_string(group) + std::to_string(monster) + std::to_string(alive) + (w::is_unit(group, monster, alive) ? " unit" : " not"),
				    std::to_string(group) + std::to_string(monster) + std::to_string(alive) + (group || (monster && alive) ? " unit" : " not"));
}

// ------------------------------------------------------------------------------------------------- the answers, row by row

TEST(writer_answer_crow_and_phantom_are_their_maps)
{
	Cluster c;
	// a crow on A, which A's server has online: A's server writes it, its Died and Destroy are accepted by the world
	WRITERS_ARE("crow on led A", c, root(creature(false, true, true), kCrow, kA), "MkA");
	WRITERS_ARE("phantom on led B", c, root(creature(false, true, true), kCrow, kB), "MkB");
	// nobody leads U, S is still starting: the world writes them there
	WRITERS_ARE("crow on unled U", c, root(creature(false, true, true), kCrow, kU), "WS");
	WRITERS_ARE("crow on starting S", c, root(creature(false, true, true), kCrow, kS), "WS");
	// the control: a living monster in no squad stays a unit, the world's until it is granted
	WRITERS_ARE("lone monster at home on A", c, root(creature(true, true, true), kCrow, kA), "WS");
	c.ws.holders[kCrow] = kBridgeA;
	c.mk(kA).authored.insert(kCrow);
	WRITERS_ARE("lone monster held by A", c, root(creature(true, true, true), kCrow, kA), "MkA");
}

// A psy phantom stands at no game vertex (level.spawn_item with none, CPhantom exports none): of no map in every process. The world
// takes its Spawn as its maker's (accept::rootless_spawn_writer), so its maker writes its Died and Destroy as well.
TEST(writer_answer_phantom_of_no_map_is_its_makers)
{
	Cluster c;
	constexpr uint16_t kPhantom = 0x9005; // an id of B's slice
	const w::RootFacts phantom = root(creature(false, true, false), kPhantom, w::kNoLevel);
	CHECK(phantom.kind == w::RootKind::None);
	c.ws.made[kPhantom] = kBridgeB;
	c.mk(kB).pool.insert(kPhantom);
	WRITERS_ARE("phantom B made", c, phantom, "MkB");
	// the world's answer names B's bridge, B's own answer is This
	const w::Asked asked = w::world_seat(phantom, c.ws);
	const w::Writer ws = w::writer_of(asked.root, w::Process{w::ProcessKind::World, w::kNoLevel, coop::kHostPeer}, asked.seat);
	CHECK_EQ(said(ws), said(w::other(kBridgeB)));
	// one S made while its map is still starting: the world writes it, as it writes S's residents
	c.ws.made[kPhantom] = kBridgeS;
	c.mk(kB).pool.clear();
	c.mk(kS).pool.insert(kPhantom);
	WRITERS_ARE("phantom of starting S", c, phantom, "WS");
	// of no map and of nobody's ids (a record): the world's
	c.ws.made.clear();
	c.mk(kS).pool.clear();
	WRITERS_ARE("record of no map", c, root(w::KindFacts{false, false, false, false, false, false}, kBox, w::kNoLevel), "WS");
	// a new root a map server makes at no vertex (the gate of its level.spawn_item): its own, as the world takes its Spawn
	const w::RootFacts new_free{w::RootKind::Resident, w::kNoId, w::kNoLevel};
	const w::Asked mine = w::map_seat(new_free, kB, w::Lead::Leads, c.mk(kB));
	CHECK_EQ(said(w::writer_of(mine.root, w::Process{w::ProcessKind::Level, kB, coop::kHostPeer}, mine.seat)), said(w::this_process()));
	const w::Asked starting = w::map_seat(new_free, kS, w::Lead::Starting, c.mk(kS));
	CHECK_EQ(said(w::writer_of(starting.root, w::Process{w::ProcessKind::Level, kS, coop::kHostPeer}, starting.seat)),
	    said(w::other(coop::kHostPeer)));
}

TEST(writer_answer_dead_monster_is_its_maps)
{
	Cluster c;
	WRITERS_ARE("dead monster on led A", c, root(creature(true, false, true), 0x720, kA), "MkA");
	WRITERS_ARE("dead monster on unled U", c, root(creature(true, false, true), 0x720, kU), "WS");
	WRITERS_ARE("box on led A", c, (w::RootFacts{w::RootKind::Resident, kBox, kA}), "MkA");
	WRITERS_ARE("record of no map", c, (w::RootFacts{w::RootKind::None, 0xfff0, w::kNoLevel}), "WS");
}

TEST(writer_answer_parked_and_retired_characters)
{
	Cluster c;
	const w::RootFacts him{w::RootKind::Character, kHim, kA};
	// parked: his player left (join::on_peer_left -> host_park_proxy), nobody plays him; his body still stands on A
	WRITERS_ARE("parked character on led A", c, him, "WS");
	CHECK_EQ(said(w::world_answer(him, c.ws)), said(w::this_process()));
	// a level move's rejoin under way (host_rejoin_peer: nobody's until his JoinRequest): the same
	c.ws.seats[kAnna] = kB;
	WRITERS_ARE("character of a rejoin under way", c, him, "WS");
	// retired: a dead player's body until host_release_character; its player joins again with a new character, seated on A
	c.plays(kAnna, kHisNew, kA, true);
	WRITERS_ARE("retired character on led A", c, him, "WS");
	WRITERS_ARE("his new character on led A", c, (w::RootFacts{w::RootKind::Character, kHisNew, kA}), "MkA");
	// the old body's player is away (no peer): the world as well
	c.ws.players.clear();
	c.mk(kA).playing.clear();
	WRITERS_ARE("retired character, player away", c, him, "WS");
}

TEST(writer_answer_played_character)
{
	Cluster c;
	const w::RootFacts him{w::RootKind::Character, kHim, kA};
	// played by Anna, seated on A, whose server has her: A's server
	c.plays(kAnna, kHim, kA, true);
	WRITERS_ARE("played on led A", c, him, "MkA");
	CHECK_EQ(said(w::world_answer(him, c.ws)), said(w::other(kBridgeA)));
	// the seat names his map, not where the world's copy of his object stood last (the seat moves first at a level move)
	WRITERS_ARE("played on A, object still on B", c, (w::RootFacts{w::RootKind::Character, kHim, kB}), "MkA");
	// seated on B whose server has her
	c.mk(kA).playing.clear();
	c.plays(kAnna, kHim, kB, true);
	WRITERS_ARE("played on led B", c, him, "MkB");
	// seated on S, whose server is still loading its world: the world keeps him (his loading screen waits)
	c.mk(kB).playing.clear();
	c.plays(kAnna, kHim, kS, true);
	WRITERS_ARE("played, S starting", c, him, "WS");
	// seated on U (its server lost): the world
	c.mk(kS).playing.clear();
	c.plays(kAnna, kHim, kU, false);
	WRITERS_ARE("played, U unled", c, him, "WS");
	// joining, not seated yet; or seated on the world server's own map: the world
	c.plays(kAnna, kHim, w::kNoLevel, false);
	WRITERS_ARE("played, not seated", c, him, "WS");
	c.plays(kAnna, kHim, kOwn, false);
	WRITERS_ARE("played, on the world's own map", c, him, "WS");
	// two players on two maps
	c.plays(kAnna, kHim, kA, true);
	c.plays(kBoris, kHisNew, kB, true);
	WRITERS_ARE("Anna's on A", c, him, "MkA");
	WRITERS_ARE("Boris's on B", c, (w::RootFacts{w::RootKind::Character, kHisNew, kB}), "MkB");
}

TEST(writer_answer_deciders_agree)
{
	// WorldServerMode::decider_of reads world_character_seat: Nobody without a player, Other for a map, else This; the writer of
	// the character: the world for Nobody and This; for Other the server of that map once it writes (a starting or lost one: the
	// world, and no map server claims him). MapServerMode::decider_of: This exactly for a character it plays, and then it writes.
	struct Row
	{
		const char* what;
		bool played;
		uint16_t seat;
		bool server_has_her;
	};
	const Row rows[] = {{"parked", false, kA, false}, {"retired, away", false, w::kNoLevel, false}, {"played on A", true, kA, true},
	    {"played on B", true, kB, true}, {"played, S starting", true, kS, false}, {"played, U unled", true, kU, false},
	    {"played, not seated", true, w::kNoLevel, false}, {"played, own map", true, kOwn, false}};
	for (const Row& row : rows)
	{
		Cluster c;
		if (row.played)
			c.plays(kAnna, kHim, row.seat, row.server_has_her);
		else if (row.seat != w::kNoLevel)
			c.ws.seats[kAnna] = row.seat; // her seat, but she plays no character of this id
		const w::RootFacts him{w::RootKind::Character, kHim, kA};
		const w::CharacterSeat s = w::world_character_seat(kHim, c.ws);
		const std::string decider = s.player == coop::kInvalidPeer ? "nobody" : s.map != w::kNoLevel ? "other" : "this";
		const w::Writer ws = w::world_answer(him, c.ws);
		std::string want = "this";
		if (decider == "other" && w::writes(c.ws.lead_of_map(s.map).lead))
			want = said(w::other(c.ws.lead_of_map(s.map).peer));
		CHECK_EQ(std::string(row.what) + " (decider " + decider + "): " + said(ws), std::string(row.what) + " (decider " + decider + "): " + want);
		for (const MapRows& m : c.mks)
		{
			const bool decides = m.plays_here(kHim);
			const w::Writer mk = w::map_answer(him, m.map, m.lead, m);
			const bool writes = mk.is == w::WriterIs::This;
			CHECK_EQ(std::string(row.what) + " " + map_name(m.map) + (writes ? " writes" : " asks"),
			    std::string(row.what) + " " + map_name(m.map) + (decides && w::writes(m.lead) ? " writes" : " asks"));
		}
	}
	// the ghost: nobody decides, nobody writes
	Cluster c;
	c.ws.players[w::kGhostId] = kAnna; // never: actor 0 plays nobody on the world server, whatever a table says
	CHECK(w::world_character_seat(w::kGhostId, c.ws).player == coop::kInvalidPeer);
}

TEST(writer_answer_born_squad)
{
	Cluster c;
	const w::RootFacts squad{w::RootKind::Unit, kSquad, kA};
	// A's server made the squad under its slice this frame: its holder has not seen it (the next flush), it writes it from birth
	c.mk(kA).newborn.insert(kSquad);
	const w::Asked a = w::map_seat(squad, kA, w::Lead::Leads, c.mk(kA));
	CHECK(a.seat.hold == w::Hold::Born);
	CHECK_EQ(int(a.seat.holder_level), int(kA));
	CHECK_EQ(said(w::map_answer(squad, kA, w::Lead::Leads, c.mk(kA))), said(w::this_process()));
	CHECK_EQ(said(w::map_answer(squad, kB, w::Lead::Leads, c.mk(kB))), said(w::other(coop::kHostPeer)));
	// a squad born on A that walked onto B is still A's (its holder's, wherever it stands)
	CHECK_EQ(said(w::map_answer(w::RootFacts{w::RootKind::Unit, kSquad, kB}, kA, w::Lead::Leads, c.mk(kA))), said(w::this_process()));
	// flushed: its holder authors it (Held, not Born) and the world's keeper has its SpawnPrepare: one writer
	c.mk(kA).newborn.clear();
	c.mk(kA).authored.insert(kSquad);
	c.ws.holders[kSquad] = kBridgeA;
	CHECK(w::map_seat(squad, kA, w::Lead::Leads, c.mk(kA)).seat.hold == w::Hold::Held);
	WRITERS_ARE("born squad, flushed", c, squad, "MkA");
	// authored and still marked born: Held wins (the holder's word)
	c.mk(kA).newborn.insert(kSquad);
	CHECK(w::map_seat(squad, kA, w::Lead::Leads, c.mk(kA)).seat.hold == w::Hold::Held);
	// a squad at home, made by nobody here: the world
	Cluster home;
	WRITERS_ARE("squad at home on A", home, squad, "WS");
}

namespace
{
// A map server's tables whose flush (client_flush_up: the Spawn leaves the journal queue and Holder::spawned authors the unit, one
// step under the transfers' lock) lands right after question number `flush_after` of map_seat (0: before the first one). The two
// questions are separately locked (levels::xfer_born, levels::xfer_authors) and the ALife thread may ask while the main thread
// flushes: the hold only moves from born to authored, so whatever the moment, the map server writes its own squad.
struct FlushingRows
{
	int flush_after;
	mutable int asked;

	bool flushed() const { return asked >= flush_after; }
	void question() const { ++asked; }
	bool plays_here(uint16_t) const { return false; }
	bool authors(uint16_t) const
	{
		const bool a = flushed();
		question();
		return a;
	}
	bool born(uint16_t) const
	{
		const bool b = !flushed();
		question();
		return b;
	}
	bool made_here(uint16_t) const { return false; }
};
} // namespace

TEST(writer_answer_born_squad_flushed_between_questions)
{
	const w::RootFacts squad{w::RootKind::Unit, kSquad, kA};
	for (int flush_after = 0; flush_after <= 3; ++flush_after)
	{
		const FlushingRows t{flush_after, 0};
		const w::Writer mk = w::map_answer(squad, kA, w::Lead::Leads, t);
		CHECK_EQ("flush after question " + std::to_string(flush_after) + ": " + said(mk),
		    "flush after question " + std::to_string(flush_after) + ": " + said(w::this_process()));
		// each table question is asked once (two locked reads, not three)
		CHECK_EQ("flush after question " + std::to_string(flush_after) + ": asked " + std::to_string(t.asked),
		    "flush after question " + std::to_string(flush_after) + ": asked 2");
	}
}

TEST(writer_answer_stopping_map_server)
{
	Cluster c;
	// A's server got its Stop: the world sees it Stopping, A's server itself still leads (ready said) until its Stopped (§8a A4)
	c.ws.leads[kA] = {w::Lead::Stopping, kBridgeA};
	c.plays(kAnna, kHim, kA, true);
	c.ws.holders[kSquad] = kBridgeA;
	c.mk(kA).authored.insert(kSquad);
	WRITERS_ARE("resident of stopping A", c, (w::RootFacts{w::RootKind::Resident, kBox, kA}), "MkA");
	WRITERS_ARE("crow of stopping A", c, root(creature(false, true, true), kCrow, kA), "MkA");
	WRITERS_ARE("player on stopping A", c, (w::RootFacts{w::RootKind::Character, kHim, kA}), "MkA");
	WRITERS_ARE("unit held by stopping A", c, (w::RootFacts{w::RootKind::Unit, kSquad, kA}), "MkA");
	// Stopped: its process is gone, the world has everything back
	c.ws.leads.erase(kA);
	c.ws.holders.clear();
	c.ws.players.clear();
	c.mks.erase(c.mks.begin());
	WRITERS_ARE("resident of stopped A", c, (w::RootFacts{w::RootKind::Resident, kBox, kA}), "WS");
	WRITERS_ARE("unit of stopped A", c, (w::RootFacts{w::RootKind::Unit, kSquad, kA}), "WS");
}

TEST(writer_answer_the_ghost)
{
	Cluster c;
	c.ws.players[w::kGhostId] = kAnna; // even a table that says so does not make actor 0 a player's
	c.mk(kA).playing.insert(w::kGhostId);
	WRITERS_ARE("the ghost on A", c, (w::RootFacts{w::RootKind::Character, w::kGhostId, kA}), "nobody");
	WRITERS_ARE("the ghost of no map", c, (w::RootFacts{w::RootKind::Character, w::kGhostId, w::kNoLevel}), "nobody");
}

TEST(writer_answer_item_in_held_members_inventory)
{
	// 0x401 in the backpack 0x400 of member 0x301 of squad 0x300 (squad_of reads m_group_id, §8a A5)
	const auto parent_of = [](uint16_t id) -> uint16_t { return id == 0x401 ? uint16_t(0x400) : id == 0x400 ? kMember : w::kNoId; };
	const auto squad_of = [](uint16_t id) -> uint16_t { return id == kMember ? kSquad : w::kNoId; };
	const uint16_t top = w::root_of(0x401, parent_of, squad_of);
	CHECK_EQ(int(top), int(kSquad));
	const w::RootFacts item_root{w::RootKind::Unit, top, kA};
	Cluster c;
	WRITERS_ARE("item of a member, squad at home", c, item_root, "WS");
	c.ws.holders[kSquad] = kBridgeA;
	c.mk(kA).authored.insert(kSquad);
	WRITERS_ARE("item of a member, squad held by A", c, item_root, "MkA");
	// the squad walked onto B: still A's
	WRITERS_ARE("item of a member, held squad on B", c, (w::RootFacts{w::RootKind::Unit, top, kB}), "MkA");
}

TEST(writer_answer_coop_unchanged)
{
	// the co-op host writes everything, a co-op client asks its host, whatever the root's kind (hostplay writer_of: This /
	// Other(host)); the new kinds of B1 change nothing there
	const w::Process host{w::ProcessKind::Whole, w::kNoLevel, coop::kHostPeer};
	const w::Process client{w::ProcessKind::Mirror, w::kNoLevel, coop::kHostPeer};
	const w::RootFacts rows[] = {root(creature(false, true, true), kCrow, kA), root(creature(true, false, true), 0x720, kA),
	    root(creature(true, true, true), 0x721, kA), w::RootFacts{w::RootKind::Character, kHim, kA},
	    w::RootFacts{w::RootKind::Character, w::kGhostId, kA}, w::RootFacts{w::RootKind::Unit, kSquad, kA},
	    w::RootFacts{w::RootKind::Resident, kBox, kA}, w::RootFacts{w::RootKind::None, 0xfff0, w::kNoLevel}};
	for (const w::RootFacts& r : rows)
	{
		const std::string k = kind_text(r.kind);
		CHECK_EQ("host " + k + ": " + said(w::writer_of(r, host, w::Seat{})), "host " + k + ": " + said(w::this_process()));
		CHECK_EQ("client " + k + ": " + said(w::writer_of(r, client, w::Seat{})), "client " + k + ": " + said(w::other(coop::kHostPeer)));
	}
}
