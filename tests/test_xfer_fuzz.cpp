// Anomaly Coop unit tests: a deterministic fuzzer of the ownership transfer core (xrCoop/coop_xfer.h; plan
// 2026-10-24-f3a §1.7, §4.1 requirement 5). One run = one world server (Ledger), 1-3 map servers (Holder) and a bad
// network between them (loss 0-30 %, duplicates 0-10 %, reordering in a window of 8, delay 0-2000 ms), driven by a
// xorshift64 stream of the run's seed: takes, releases, changes, spawns, destroys, a player's move (release here, take
// there), a player on the edge of the online radius (out and in again at once), a squad as a unit, a story teleport of
// an NPC (release, teleport at the world, take elsewhere), a map server drained and stopped, a map server crash, the
// bridge cut, a player leaving mid-transfer, the world aborting a grant, a save (the world's objects plus the journal)
// and a load (a fresh Ledger, load_journal, resolve_after_load, every map server restarted empty).
// After every step (and for the touched id after every delivered packet): no id with two authors (the world counts as
// one when it owns the object and it is not frozen), every registered id has exactly one owner in the ledger, no
// registered id vanishes without a destroy, no destroyed id comes back; a lost map server's prepared release is
// completed with its state. In a quiet period (no new wishes, the network drained): the journal is empty; every id's
// state is the last confirmed snapshot of its owner and the last state the game gave it; the ledger's set of ids is the
// model's; the auditor finds nothing and the level hashes agree.
//   COOP_FUZZ_RUNS=<n>       runs (default 300 000), seeds splitmix64(kSeedBase + run index), on all cores
//   COOP_FUZZ_SEED=<seed>    replay one seed with a trace (decimal or 0x hex); COOP_FUZZ_OPS=<n> limits its operations
//   COOP_FUZZ_THREADS=<n>    worker threads (default: the hardware's, at most 16)
// On a violation: the seed, the step, the smallest operation count that still fails and its trace.
// Most runs are a small world (3-10 objects, 10-49 operations) so that 300 000 of them fit in the time; one run in
// kBigRunEvery is the full-size world of the plan (20-200 objects, 150-399 operations).
#include "test_util.h"

#include "coop_xfer.h"

#include <algorithm>
#include <atomic>
#include <cinttypes>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <iterator>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <utility>
#include <vector>

using namespace coop::xfer;

namespace
{
using Bytes = std::vector<uint8_t>;

constexpr uint64_t kDefaultRuns = 300000;
constexpr uint64_t kSeedBase = 0xC00F5EED20261024ull;
constexpr size_t kWindow = 8; // reordering: a packet overtakes at most kWindow - 1 sent before it
constexpr uint32_t kBigRunEvery = 512;
constexpr uint32_t kQuietStepMs = 100;
constexpr uint32_t kQuietMaxMs = 600000; // a quiet period that does not settle in 10 simulated minutes is a livelock
constexpr uint64_t kTimeLimitMs = 60000;

uint64_t splitmix64(uint64_t x)
{
	x += 0x9E3779B97F4A7C15ull;
	x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ull;
	x = (x ^ (x >> 27)) * 0x94D049BB133111EBull;
	return x ^ (x >> 31);
}

struct Rng
{
	uint64_t s;
	explicit Rng(uint64_t seed) : s(seed ? seed : 0x9E3779B97F4A7C15ull) {}
	uint64_t next()
	{
		s ^= s << 13;
		s ^= s >> 7;
		s ^= s << 17;
		return s;
	}
	uint32_t below(uint32_t n) { return n ? uint32_t(next() % n) : 0; }
	bool percent(uint32_t p) { return below(100) < p; }
};

// An object's state: its id and a version unique per id within the run (a state never passes for another object's or
// for another version), of a varying size.
Bytes make_state(uint16_t id, uint32_t v)
{
	Bytes b(6 + v % 5);
	b[0] = uint8_t(id);
	b[1] = uint8_t(id >> 8);
	for (int i = 0; i < 4; ++i)
		b[2 + i] = uint8_t(v >> (8 * i));
	for (size_t i = 6; i < b.size(); ++i)
		b[i] = uint8_t(v * 31 + i);
	return b;
}

bool read_state(const Bytes* b, uint16_t& id, uint32_t& v)
{
	if (!b || b->size() < 6)
		return false;
	id = uint16_t((*b)[0] | ((*b)[1] << 8));
	v = 0;
	for (int i = 0; i < 4; ++i)
		v |= uint32_t((*b)[2 + i]) << (8 * i);
	return *b == make_state(id, v);
}

struct Worst
{
	size_t net = 0; // packets in the network at once
	size_t journal = 0; // journal entries at once
	size_t held = 0; // ids one map server tracks at once
	uint64_t quiet_ms = 0; // simulated time a quiet period took to settle
	uint64_t ops = 0; // operations in one run

	void merge(const Worst& o)
	{
		net = std::max(net, o.net);
		journal = std::max(journal, o.journal);
		held = std::max(held, o.held);
		quiet_ms = std::max(quiet_ms, o.quiet_ms);
		ops = std::max(ops, o.ops);
	}
};

struct Result
{
	bool ok = true;
	std::string error;
	uint64_t step = 0;
	uint32_t ops = 0;
	bool big = false;
	uint64_t saves = 0, loads = 0, crashes = 0, drains = 0, quiets = 0;
	Worst worst;
};

class Sim
{
public:
	Sim(uint64_t seed, uint32_t op_limit, std::vector<std::string>* trace)
		: m_r(seed), m_op_limit(op_limit), m_trace(trace)
	{
	}

	Result run()
	{
		setup();
		for (uint32_t op = 0; op < m_res.ops && m_res.ok; ++op)
		{
			++m_res.step;
			m_now += 1 + m_r.below(200);
			random_op();
			if (!m_res.ok)
				break;
			deliver(m_r.below(8));
			tick_all();
			housekeeping();
			check_step();
			if (m_res.ok && m_r.percent(2))
				quiet();
		}
		if (m_res.ok)
			quiet();
		return m_res;
	}

private:
	struct Map
	{
		std::unique_ptr<Holder> h;
		bool up = true;
		bool draining = false;
	};
	struct Flight
	{
		Packet p;
		uint64_t at;
	};
	struct Save
	{
		std::vector<std::pair<uint16_t, Bytes>> world;
		std::string journal;
		std::set<uint16_t> reg, dead;
		std::map<uint16_t, uint32_t> truth;
	};

	Rng m_r;
	uint32_t m_op_limit;
	std::vector<std::string>* m_trace;
	Result m_res;
	std::unique_ptr<Ledger> m_w;
	std::vector<Map> m_maps; // peer = index + 1
	std::deque<Flight> m_net;
	uint64_t m_now = 1000;
	uint32_t m_loss = 0, m_dup = 0, m_delay = 0;
	uint16_t m_next_id = 1000;
	// The model: what the game did, kept apart from the ledger.
	std::set<uint16_t> m_reg; // registered in the ledger (seen), not destroyed
	std::set<uint16_t> m_dead; // destroyed: never registered again (ids are not reused in a run)
	std::set<uint16_t> m_intent; // a destroy was asked for
	std::map<uint16_t, Peer> m_spawning; // spawned at a map server, not registered yet
	std::map<uint16_t, uint32_t> m_truth; // the last state version the game gave each object
	std::map<uint16_t, uint32_t> m_ver; // versions handed out (never reused)
	std::map<uint16_t, Peer> m_teleport; // story teleports waiting for the NPC to be back at the world
	std::unique_ptr<Save> m_save;

	void log(const std::string& s)
	{
		if (m_trace)
			m_trace->push_back("t=" + std::to_string(m_now) + " " + s);
	}

	static std::string who(Peer p) { return p == kWorld ? std::string("W") : "M" + std::to_string(p); }

	static std::string describe_packet(const Packet& p)
	{
		char buf[96];
		std::snprintf(buf, sizeof(buf), "%s->%s %s id %u gen 0x%08x", who(p.from).c_str(), who(p.to).c_str(),
			op_name(p.op), unsigned(p.key.id), unsigned(p.key.gen));
		return buf;
	}

	void fail(const std::string& what)
	{
		if (!m_res.ok)
			return;
		m_res.ok = false;
		m_res.error = what;
		log("!! VIOLATION: " + what);
	}

	void fail_id(const char* what, uint16_t id)
	{
		fail(std::string(what) + " (id " + std::to_string(id) + ")");
	}

	Bytes new_state(uint16_t id)
	{
		const uint32_t v = ++m_ver[id];
		m_truth[id] = v;
		return make_state(id, v);
	}

	Map* map_of(Peer p) { return p >= 1 && p <= m_maps.size() ? &m_maps[p - 1] : nullptr; }

	bool up(Peer p)
	{
		const Map* m = map_of(p);
		return m && m->up;
	}

	void setup()
	{
		m_res.big = m_r.below(kBigRunEvery) == 0;
		const uint32_t maps = 1 + m_r.below(3);
		const uint32_t objects = m_res.big ? 20 + m_r.below(181) : 3 + m_r.below(8);
		const uint32_t ops = m_res.big ? 150 + m_r.below(250) : 10 + m_r.below(40);
		m_res.ops = std::min(ops, m_op_limit);
		m_loss = m_r.below(31);
		m_dup = m_r.below(11);
		m_delay = m_r.below(2001);
		m_w = std::make_unique<Ledger>();
		for (uint32_t i = 0; i < maps; ++i)
			m_maps.push_back(Map{std::make_unique<Holder>(Peer(i + 1)), true, false});
		for (uint16_t id = 1; id <= objects; ++id)
		{
			m_w->add_world_object(id, new_state(id));
			m_reg.insert(id);
		}
		log("setup: " + std::to_string(maps) + " map servers, " + std::to_string(objects) + " objects, " +
			std::to_string(m_res.ops) + " operations, loss " + std::to_string(m_loss) + "%, dup " +
			std::to_string(m_dup) + "%, delay 0-" + std::to_string(m_delay) + " ms");
		m_res.worst.ops = m_res.ops;
	}

	// ---- network --------------------------------------------------------------------------------------------------

	void send(std::vector<Packet> ps)
	{
		for (Packet& p : ps)
		{
			if ((p.to != kWorld && !up(p.to)) || (p.from != kWorld && !up(p.from)))
				continue; // no connection
			if (m_r.percent(m_loss))
			{
				log("lost " + describe_packet(p));
				continue;
			}
			if (m_r.percent(m_dup))
				m_net.push_back({p, m_now + m_r.below(m_delay + 1)});
			m_net.push_back({std::move(p), m_now + m_r.below(m_delay + 1)});
		}
		m_res.worst.net = std::max(m_res.worst.net, m_net.size());
	}

	// Delivers up to `n` packets that are due, each picked at random among the first kWindow in flight.
	size_t deliver(size_t n)
	{
		size_t done = 0;
		for (; done < n && m_res.ok; ++done)
		{
			size_t due[kWindow];
			size_t k = 0;
			for (size_t i = 0; i < m_net.size() && i < kWindow; ++i)
				if (m_net[i].at <= m_now)
					due[k++] = i;
			if (!k)
				break;
			const size_t at = due[m_r.below(uint32_t(k))];
			Packet p = std::move(m_net[at].p);
			m_net.erase(m_net.begin() + std::ptrdiff_t(at));
			dispatch(p);
		}
		return done;
	}

	void dispatch(const Packet& p)
	{
		log(describe_packet(p));
		const uint16_t id = p.key.id;
		if (p.to == kWorld)
		{
			const Phase before = m_w->phase(id);
			send(m_w->on_packet(p, m_now));
			// A grant undone (aborted or declined): the world's object is back at its last confirmed state.
			if ((before == Phase::Granting || before == Phase::Aborting) && m_w->registered(id) &&
			    m_w->phase(id) == Phase::Stable && m_w->owner(id) == kWorld)
				rebase(id);
		}
		else if (Map* m = map_of(p.to))
			send(m->h->on_packet(p, m_now));
		check_id(id);
	}

	void purge(Peer peer)
	{
		std::deque<Flight> keep;
		for (Flight& f : m_net)
			if (f.p.from != peer && f.p.to != peer)
				keep.push_back(std::move(f));
		m_net.swap(keep);
	}

	void tick_all()
	{
		send(m_w->tick(m_now));
		for (Map& m : m_maps)
			if (m.up)
				send(m.h->tick(m_now));
	}

	// ---- the model ------------------------------------------------------------------------------------------------

	// The object went back to the world's last confirmed state (a crash, an abort): the game's truth follows, never
	// forward.
	void rebase(uint16_t id)
	{
		uint16_t sid = 0;
		uint32_t v = 0;
		if (!read_state(m_w->last_confirmed(id), sid, v) || sid != id)
			return fail_id("the world holds a state that is not this object's", id);
		if (v > m_truth[id])
			return fail_id("the world holds a state newer than the game ever made", id);
		m_truth[id] = v;
	}

	void check_id(uint16_t id)
	{
		if (!m_res.ok)
			return;
		const bool reg = m_w->registered(id);
		auto sp = m_spawning.find(id);
		if (sp != m_spawning.end() && reg)
		{
			if (m_w->owner(id) != sp->second && m_w->phase(id) == Phase::Stable && m_w->owner(id) != kWorld)
				return fail_id("a spawn registered for another map server", id);
			m_spawning.erase(sp);
			m_reg.insert(id);
		}
		if (m_reg.count(id) && !reg)
		{
			if (!m_intent.count(id))
				return fail_id("lost: a registered id vanished from the ledger without a destroy", id);
			m_reg.erase(id);
			m_intent.erase(id);
			m_truth.erase(id);
			m_dead.insert(id);
		}
		const bool dead = m_dead.count(id) != 0;
		if (dead && reg)
			return fail_id("a destroyed id is registered again", id);
		if (m_reg.count(id) && m_w->owner_count(id) != 1)
			return fail_id("a registered id without exactly one owner in the ledger", id);
		uint32_t authors = m_w->world_authors(id) ? 1 : 0;
		for (Map& m : m_maps)
			if (m.up && m.h->authors(id))
				++authors;
		if (authors > 1)
			return fail_id("two authors", id);
		if (dead && authors)
			return fail_id("a destroyed id is written", id);
	}

	void check_step()
	{
		if (!m_res.ok)
			return;
		std::vector<uint16_t> ids(m_reg.begin(), m_reg.end());
		for (const auto& s : m_spawning)
			ids.push_back(s.first);
		for (uint16_t id : m_dead)
			ids.push_back(id);
		for (uint16_t id : ids)
			check_id(id);
		for (Map& m : m_maps)
		{
			if (!m.up)
				continue;
			const std::vector<uint16_t> held = m.h->ids();
			m_res.worst.held = std::max(m_res.worst.held, held.size());
			for (uint16_t id : held)
				if (m.h->authors(id) && !m_reg.count(id) && !m_spawning.count(id))
					return fail_id("a map server writes an id the game never made", id);
		}
		const size_t journal = m_w->journal_size();
		m_res.worst.journal = std::max(m_res.worst.journal, journal);
		if (m_w->counters().in_flight != journal)
			fail("the in-flight counter differs from the journal");
	}

	// Map servers with nothing left to do after a drain stop; story teleports go on; destroys that did not happen are
	// forgotten; a spawn destroyed before the world saw it is dead.
	void housekeeping()
	{
		for (size_t k = 0; k < m_maps.size() && m_res.ok; ++k)
		{
			Map& m = m_maps[k];
			if (!m.up || !m.draining || !m.h->idle() || !m.h->ids().empty())
				continue;
			const Peer peer = Peer(k + 1);
			if (!m_w->owned_by(peer).empty())
				return fail("a drained map server stopped with objects the ledger still gives it");
			log("M" + std::to_string(peer) + " stops (drained)");
			stop(peer);
			++m_res.drains;
		}
		for (auto it = m_teleport.begin(); it != m_teleport.end() && m_res.ok;)
		{
			const uint16_t id = it->first;
			const Peer to = it->second;
			if (!m_w->registered(id))
			{
				it = m_teleport.erase(it);
				continue;
			}
			if (!m_w->world_authors(id))
			{
				++it;
				continue;
			}
			log("teleport id " + std::to_string(id) + " to M" + std::to_string(to));
			if (!m_w->world_update(id, new_state(id)))
				fail_id("world_update refused an object the world writes", id);
			Map* m = map_of(to);
			if (m && m->up && !m->draining)
				send(m->h->want_online(id, m_now));
			it = m_teleport.erase(it);
		}
		for (auto it = m_intent.begin(); it != m_intent.end();)
		{
			const uint16_t id = *it;
			bool busy = false;
			for (Map& m : m_maps)
				busy = busy || (m.up && m.h->busy(id));
			if (busy)
			{
				++it;
				continue;
			}
			if (m_spawning.count(id) && !m_w->registered(id))
			{
				m_spawning.erase(id); // destroyed before the world saw the spawn
				m_truth.erase(id);
				m_dead.insert(id);
				it = m_intent.erase(it);
			}
			else if (m_w->registered(id))
				it = m_intent.erase(it); // the destroy did not happen (aborted, the map server lost)
			else
				++it;
		}
		for (Map& m : m_maps)
			if (m.up)
				m.h->take_events();
	}

	// A map server goes away: the connection is closed (what is in flight to or from it is gone), the world is told.
	void stop(Peer peer)
	{
		Map& m = *map_of(peer);
		std::vector<uint16_t> involved;
		std::set<uint16_t> releasing; // prepared releases: completed by the loss, at the game's last state (frozen)
		for (uint16_t id : m_reg)
			if (m_w->owner(id) == peer || m_w->peer(id) == peer)
			{
				involved.push_back(id);
				if (m_w->phase(id) == Phase::Releasing)
					releasing.insert(id);
			}
		purge(peer);
		m.h = std::make_unique<Holder>(peer);
		m.up = false;
		m.draining = false;
		m_w->server_lost(peer, m_now); // its Drops go to a closed connection
		for (auto it = m_spawning.begin(); it != m_spawning.end();)
		{
			if (it->second == peer && !m_w->registered(it->first))
			{
				m_truth.erase(it->first);
				it = m_spawning.erase(it);
			}
			else
				++it;
		}
		for (uint16_t id : involved)
		{
			if (!m_w->registered(id))
				return fail_id("a lost map server's object vanished", id);
			if (m_w->owner(id) != kWorld || !m_w->world_authors(id))
				return fail_id("a lost map server's object is not back at the world", id);
			if (releasing.count(id))
			{
				uint16_t sid = 0;
				uint32_t v = 0;
				if (!read_state(m_w->last_confirmed(id), sid, v) || sid != id || v != m_truth[id])
					return fail_id("a release the lost map server prepared was not completed with its state", id);
			}
			rebase(id);
			m_intent.erase(id);
		}
		for (uint16_t id : involved)
			check_id(id);
	}

	// ---- operations -----------------------------------------------------------------------------------------------

	int live_map()
	{
		std::vector<int> live;
		for (size_t k = 0; k < m_maps.size(); ++k)
			if (m_maps[k].up && !m_maps[k].draining)
				live.push_back(int(k));
		return live.empty() ? -1 : live[m_r.below(uint32_t(live.size()))];
	}

	template <class Set>
	bool pick(const Set& s, uint16_t& out)
	{
		if (s.empty())
			return false;
		auto it = s.begin();
		std::advance(it, m_r.below(uint32_t(s.size())));
		out = *it;
		return true;
	}

	// An id map server k writes and may change (not frozen for a release).
	bool pick_free(int k, uint16_t& out)
	{
		std::vector<uint16_t> free;
		for (uint16_t id : m_maps[size_t(k)].h->ids())
			if (m_maps[size_t(k)].h->authors(id) && !m_maps[size_t(k)].h->frozen(id))
				free.push_back(id);
		return pick(free, out);
	}

	void take(int k, uint16_t id)
	{
		log("op take id " + std::to_string(id) + " at M" + std::to_string(k + 1));
		send(m_maps[size_t(k)].h->want_online(id, m_now));
	}

	// Map server k lets go of `id`: a release with a new state when it writes it, else a request taken back.
	void release(int k, uint16_t id)
	{
		Holder& h = *m_maps[size_t(k)].h;
		const bool writes = h.authors(id) && !h.frozen(id);
		log("op release id " + std::to_string(id) + " at M" + std::to_string(k + 1));
		send(h.want_offline(id, writes ? new_state(id) : Bytes(), m_now));
	}

	void random_op()
	{
		const uint32_t roll = m_r.below(100);
		uint16_t id = 0;
		if (roll < 22) // take
		{
			const int k = live_map();
			if (k < 0)
				return;
			if (m_r.percent(5) ? pick(m_dead, id) : pick(m_reg, id))
				take(k, id);
		}
		else if (roll < 34) // release
		{
			const int k = live_map();
			if (k >= 0 && pick_free(k, id))
				release(k, id);
		}
		else if (roll < 46) // a change within ownership
		{
			const int k = live_map();
			if (k >= 0 && pick_free(k, id))
			{
				log("op change id " + std::to_string(id) + " at M" + std::to_string(k + 1));
				send(m_maps[size_t(k)].h->changed(id, new_state(id), m_now));
			}
		}
		else if (roll < 50) // the world's own simulation
		{
			if (pick(m_reg, id) && m_w->world_authors(id))
			{
				log("op world change id " + std::to_string(id));
				if (!m_w->world_update(id, new_state(id)))
					fail_id("world_update refused an object the world writes", id);
			}
		}
		else if (roll < 56) // spawn
		{
			const int k = live_map();
			if (k < 0 || m_next_id >= 0xfff0)
				return;
			id = m_next_id++;
			log("op spawn id " + std::to_string(id) + " at M" + std::to_string(k + 1));
			m_spawning[id] = Peer(k + 1);
			send(m_maps[size_t(k)].h->spawned(id, new_state(id), m_now));
		}
		else if (roll < 60) // destroy at a map server
		{
			const int k = live_map();
			if (k >= 0 && pick_free(k, id))
			{
				log("op destroy id " + std::to_string(id) + " at M" + std::to_string(k + 1));
				m_intent.insert(id);
				send(m_maps[size_t(k)].h->destroyed(id, m_now));
			}
		}
		else if (roll < 62) // destroy at the world
		{
			if (pick(m_reg, id) && m_w->world_authors(id))
			{
				log("op world destroy id " + std::to_string(id));
				if (!m_w->world_destroy(id, m_now))
					return fail_id("world_destroy refused an object the world writes", id);
				m_reg.erase(id);
				m_truth.erase(id);
				m_dead.insert(id);
				check_id(id);
			}
		}
		else if (roll < 68) // a player moves: release here, take there
		{
			const int k = live_map();
			const int j = live_map();
			if (k >= 0 && j >= 0 && k != j && pick_free(k, id))
			{
				release(k, id);
				take(j, id);
			}
		}
		else if (roll < 70) // a player on the edge of the online radius: out and in again at once
		{
			const int k = live_map();
			if (k >= 0 && pick_free(k, id))
			{
				release(k, id);
				take(k, id);
			}
		}
		else if (roll < 73) // a squad as a unit
		{
			const int k = live_map();
			if (k < 0)
				return;
			const uint32_t n = 2 + m_r.below(3);
			if (m_r.percent(50))
			{
				for (uint32_t i = 0; i < n; ++i)
					if (pick(m_reg, id))
						take(k, id);
			}
			else
			{
				for (uint32_t i = 0; i < n; ++i)
					if (pick_free(k, id))
						release(k, id);
			}
		}
		else if (roll < 76) // a story teleport of an NPC
		{
			const int j = live_map();
			if (j < 0 || !pick(m_reg, id))
				return;
			m_teleport[id] = Peer(j + 1);
			for (size_t k = 0; k < m_maps.size(); ++k)
				if (m_maps[k].up && m_maps[k].h->authors(id) && !m_maps[k].h->frozen(id))
					release(int(k), id);
		}
		else if (roll < 80) // a player leaves mid-transfer: whatever the map server has going for an id
		{
			const int k = live_map();
			if (k < 0)
				return;
			if (pick(m_maps[size_t(k)].h->ids(), id))
				release(k, id);
		}
		else if (roll < 83) // the world aborts a grant
		{
			std::vector<uint16_t> granting;
			for (uint16_t i : m_reg)
				if (m_w->phase(i) == Phase::Granting)
					granting.push_back(i);
			if (pick(granting, id))
			{
				log("op world abort id " + std::to_string(id));
				send(m_w->abort(id, m_now));
			}
		}
		else if (roll < 85) // a map server crashes
		{
			std::vector<int> ups;
			for (size_t k = 0; k < m_maps.size(); ++k)
				if (m_maps[k].up)
					ups.push_back(int(k));
			if (ups.empty())
				return;
			const int k = ups[m_r.below(uint32_t(ups.size()))];
			log("op crash M" + std::to_string(k + 1));
			stop(Peer(k + 1));
			++m_res.crashes;
		}
		else if (roll < 86) // the bridge is cut: every map server at once
		{
			if (!m_r.percent(30))
				return;
			log("op bridge cut");
			for (size_t k = 0; k < m_maps.size() && m_res.ok; ++k)
				if (m_maps[k].up)
				{
					stop(Peer(k + 1));
					++m_res.crashes;
				}
		}
		else if (roll < 88) // a map server is drained: everything handed back, then it stops
		{
			const int k = live_map();
			if (k < 0)
				return;
			log("op drain M" + std::to_string(k + 1));
			m_maps[size_t(k)].draining = true;
			for (uint16_t i : m_maps[size_t(k)].h->ids())
				release(k, i);
		}
		else if (roll < 90) // a stopped map server starts again (empty)
		{
			for (size_t k = 0; k < m_maps.size(); ++k)
				if (!m_maps[k].up)
				{
					log("op restart M" + std::to_string(k + 1));
					m_maps[k] = Map{std::make_unique<Holder>(Peer(k + 1)), true, false};
					break;
				}
		}
		else if (roll < 93)
			save();
		else if (roll < 95)
		{
			if (m_save)
				load();
		}
		// else: time passes
	}

	// ---- save and load ----------------------------------------------------------------------------------------------

	void save()
	{
		log("op save");
		auto s = std::make_unique<Save>();
		const std::vector<uint16_t> ids = m_w->ids();
		if (std::set<uint16_t>(ids.begin(), ids.end()) != m_reg)
			return fail("the ledger's ids differ from the model's at a save");
		for (uint16_t id : ids)
		{
			const Bytes* st = m_w->last_confirmed(id);
			uint16_t sid = 0;
			uint32_t v = 0;
			if (!read_state(st, sid, v) || sid != id)
				return fail_id("a saved state is not this object's", id);
			s->world.emplace_back(id, *st);
			// A release prepared is completed by the load (its object is frozen: the game's last state); everything
			// else loads at its last confirmed state.
			s->truth[id] = m_w->phase(id) == Phase::Releasing ? m_truth[id] : v;
		}
		s->journal = m_w->save_journal();
		if (s->journal.size() > kJournalMaxBytes)
			return fail("the journal text is over its limit");
		s->reg = m_reg;
		s->dead = m_dead;
		m_save = std::move(s);
		++m_res.saves;
	}

	void load()
	{
		log("op load");
		const Save& s = *m_save;
		m_w = std::make_unique<Ledger>();
		for (const auto& o : s.world)
			m_w->add_world_object(o.first, o.second);
		if (!m_w->load_journal(s.journal))
			return fail("load_journal refused a journal it saved");
		m_w->resolve_after_load();
		m_net.clear();
		for (size_t k = 0; k < m_maps.size(); ++k)
			m_maps[k] = Map{std::make_unique<Holder>(Peer(k + 1)), true, false};
		m_reg = s.reg;
		m_dead = s.dead;
		m_truth = s.truth;
		m_intent.clear();
		m_spawning.clear();
		m_teleport.clear();
		++m_res.loads;
		if (m_w->journal_size() != 0)
			return fail("the journal is not empty after resolve_after_load");
		if (m_w->ids().size() != m_reg.size())
			return fail("a load changed the number of objects");
		for (uint16_t id : m_reg)
		{
			uint16_t sid = 0;
			uint32_t v = 0;
			if (!m_w->world_authors(id))
				return fail_id("after a load an object is not the world's", id);
			if (!read_state(m_w->last_confirmed(id), sid, v) || sid != id || v != m_truth[id])
				return fail_id("after a load an object is not at the state it was saved with", id);
		}
	}

	// ---- quiet ------------------------------------------------------------------------------------------------------

	bool all_idle()
	{
		for (Map& m : m_maps)
			if (m.up && !m.h->idle())
				return false;
		return m_net.empty() && m_w->journal_size() == 0;
	}

	void quiet()
	{
		if (!m_res.ok)
			return;
		log("quiet");
		++m_res.quiets;
		m_teleport.clear();
		const uint64_t start = m_now;
		while (m_res.ok && !all_idle())
		{
			if (m_now - start > kQuietMaxMs)
				return fail("no quiet: transfers still going after " + std::to_string(kQuietMaxMs / 1000) + " s");
			// No new wishes: requests (a request for an object another map server keeps waits for it for good) and
			// "take it again after the release" are taken back.
			for (Map& m : m_maps)
				if (m.up)
					for (uint16_t id : m.h->ids())
						if (m.h->requesting(id) || m.h->frozen(id) || (m.h->busy(id) && !m.h->authors(id)))
							send(m.h->want_offline(id, Bytes(), m_now));
			m_now += kQuietStepMs;
			const size_t before = m_net.size();
			const size_t delivered = deliver(SIZE_MAX);
			tick_all();
			housekeeping();
			if (delivered || m_net.size() != before)
				check_step();
		}
		if (!m_res.ok)
			return;
		check_step();
		m_res.worst.quiet_ms = std::max(m_res.worst.quiet_ms, m_now - start);
		check_quiet();
	}

	void check_quiet()
	{
		if (!m_res.ok)
			return;
		if (m_w->journal_size() != 0 || m_w->counters().in_flight != 0)
			return fail("the journal is not empty in a quiet period");
		if (!m_spawning.empty())
			return fail_id("a spawn never registered", m_spawning.begin()->first);
		const std::vector<uint16_t> ids = m_w->ids();
		if (std::set<uint16_t>(ids.begin(), ids.end()) != m_reg)
			return fail("the ledger's ids differ from the model's in a quiet period");
		for (uint16_t id : m_reg)
		{
			uint16_t sid = 0;
			uint32_t v = 0;
			const Bytes* st = m_w->last_confirmed(id);
			if (!read_state(st, sid, v) || sid != id)
				return fail_id("the world holds a state that is not this object's", id);
			if (v != m_truth[id])
				return fail_id("the world's last confirmed state is not the game's last state", id);
			const Peer owner = m_w->owner(id);
			uint32_t authors = 0;
			for (Map& m : m_maps)
				if (m.up && m.h->authors(id))
					++authors;
			if (owner == kWorld)
			{
				if (!m_w->world_authors(id) || authors)
					return fail_id("an object of the world is written elsewhere or frozen", id);
				continue;
			}
			Map* m = map_of(owner);
			if (!m || !m->up)
				return fail_id("an object owned by a map server that is not there", id);
			if (!m->h->authors(id) || authors != 1)
				return fail_id("lost: the owner does not have it", id);
			const Bytes* hs = m->h->state(id);
			if (!hs || *hs != *st)
				return fail_id("the owner's state is not the last confirmed snapshot", id);
			if (m->h->gen(id) != m_w->gen(id))
				return fail_id("the owner's gen differs from the ledger's", id);
		}
		for (size_t k = 0; k < m_maps.size(); ++k)
		{
			const Peer peer = Peer(k + 1);
			Map& m = m_maps[k];
			if (!m.up)
			{
				if (!m_w->owned_by(peer).empty())
					return fail("the ledger gives objects to a map server that is down");
				continue;
			}
			for (uint16_t id : m.h->ids())
				if (m.h->authors(id) && (!m_reg.count(id) || m_w->owner(id) != peer))
					return fail_id("a map server writes an object the ledger does not give it", id);
			const std::vector<Entry> report = m.h->report();
			if (!audit(*m_w, peer, report).empty())
				return fail("the auditor found something in a quiet period at M" + std::to_string(peer));
			if (mismatched(hash_of(report), hash_of(m_w->owned_by(peer))) != 0)
				return fail("level hashes differ in a quiet period at M" + std::to_string(peer));
		}
		m_intent.clear();
	}
};

uint64_t env_u64(const char* name, uint64_t fallback)
{
	const char* v = std::getenv(name);
	if (!v || !*v)
		return fallback;
	return std::strtoull(v, nullptr, 0);
}

void print_trace(const std::vector<std::string>& trace, size_t last)
{
	const size_t from = trace.size() > last ? trace.size() - last : 0;
	if (from)
		std::printf("    ... %zu earlier lines\n", from);
	for (size_t i = from; i < trace.size(); ++i)
		std::printf("    %s\n", trace[i].c_str());
}

// Replays `seed` and finds the smallest operation count that still fails; prints it with its trace.
void minimal_repro(uint64_t seed, uint32_t ops)
{
	uint32_t smallest = ops;
	for (uint32_t n = 0; n < ops; ++n)
		if (!Sim(seed, n, nullptr).run().ok)
		{
			smallest = n;
			break;
		}
	std::vector<std::string> trace;
	const Result r = Sim(seed, smallest, &trace).run();
	std::printf("    minimal repro: seed 0x%016" PRIx64 ", %u operations, step %" PRIu64 ": %s\n", seed, smallest,
		r.step, r.error.c_str());
	std::printf("    replay: set COOP_FUZZ_SEED=0x%016" PRIx64 " and COOP_FUZZ_OPS=%u, run coop_tests.exe xfer_fuzz\n",
		seed, smallest);
	print_trace(trace, 300);
}
} // namespace

// Requirement 5: hundreds of thousands of runs, none with a lost or a doubled object.
TEST(xfer_fuzz)
{
	if (const char* replay = std::getenv("COOP_FUZZ_SEED"))
	{
		const uint64_t seed = std::strtoull(replay, nullptr, 0);
		const uint32_t ops = uint32_t(env_u64("COOP_FUZZ_OPS", UINT32_MAX));
		std::vector<std::string> trace;
		const Result r = Sim(seed, ops, &trace).run();
		print_trace(trace, SIZE_MAX);
		std::printf("    seed 0x%016" PRIx64 ": %s\n", seed, r.ok ? "ok" : r.error.c_str());
		CHECK(r.ok);
		return;
	}

	const uint64_t runs = env_u64("COOP_FUZZ_RUNS", kDefaultRuns);
	const unsigned hw = std::max(1u, std::thread::hardware_concurrency());
	const unsigned threads = unsigned(std::max<uint64_t>(1, std::min<uint64_t>(env_u64("COOP_FUZZ_THREADS", hw), 16)));
	std::atomic<uint64_t> next{0};
	std::atomic<bool> stop{false};
	std::mutex mx;
	Worst worst;
	uint64_t big = 0, saves = 0, loads = 0, crashes = 0, drains = 0, quiets = 0, done = 0;
	bool failed = false;
	uint64_t fail_seed = 0, fail_run = 0;
	Result fail_result;

	const uint64_t t0 = t::now_ms();
	auto worker = [&]() {
		Worst w;
		uint64_t b = 0, sv = 0, ld = 0, cr = 0, dr = 0, qu = 0, n = 0;
		for (;;)
		{
			const uint64_t i = next.fetch_add(1);
			if (i >= runs || stop.load())
				break;
			const uint64_t seed = splitmix64(kSeedBase + i);
			const Result r = Sim(seed, UINT32_MAX, nullptr).run();
			++n;
			w.merge(r.worst);
			b += r.big ? 1 : 0;
			sv += r.saves;
			ld += r.loads;
			cr += r.crashes;
			dr += r.drains;
			qu += r.quiets;
			if (!r.ok)
			{
				std::lock_guard<std::mutex> lock(mx);
				if (!failed || i < fail_run)
				{
					failed = true;
					fail_run = i;
					fail_seed = seed;
					fail_result = r;
				}
				stop.store(true);
			}
		}
		std::lock_guard<std::mutex> lock(mx);
		worst.merge(w);
		big += b;
		saves += sv;
		loads += ld;
		crashes += cr;
		drains += dr;
		quiets += qu;
		done += n;
	};
	std::vector<std::thread> pool;
	for (unsigned i = 0; i < threads; ++i)
		pool.emplace_back(worker);
	for (std::thread& th : pool)
		th.join();
	const uint64_t ms = t::now_ms() - t0;

	std::printf("    %" PRIu64 " runs (%" PRIu64 " full-size) on %u threads in %" PRIu64 " ms: %" PRIu64
	            " saves, %" PRIu64 " loads, %" PRIu64 " crashes, %" PRIu64 " drains, %" PRIu64 " quiet periods\n",
		done, big, threads, ms, saves, loads, crashes, drains, quiets);
	std::printf("    worst: %zu packets in flight, %zu journal entries, %zu ids at one map server, %" PRIu64
	            " ms to settle, %" PRIu64 " operations\n",
		worst.net, worst.journal, worst.held, worst.quiet_ms, worst.ops);
	if (failed)
	{
		std::printf("    VIOLATION in run %" PRIu64 " (seed 0x%016" PRIx64 "), step %" PRIu64 ": %s\n", fail_run,
			fail_seed, fail_result.step, fail_result.error.c_str());
		minimal_repro(fail_seed, fail_result.ops);
	}
	CHECK(!failed);
	CHECK_EQ(done, runs);
	if (runs == kDefaultRuns)
		CHECK(ms <= kTimeLimitMs);
}
