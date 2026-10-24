// Anomaly Coop unit tests: a deterministic fuzzer of the ownership transfer core (xrCoop/coop_xfer.h; plan
// 2026-10-24-f3a §1.7, §4.1 requirement 5).
// One run = one world server (Ledger), 1-3 map servers (Holder) and a bad network between them (loss 0-30 %,
// duplicates 0-10 %, a packet picked at random among the first 8 in flight that are due, delay 0-2000 ms; a packet
// older than kMaxAgeMs is lost), driven by a xorshift64 stream of the run's seed. Each run draws a profile:
//   default - takes, releases, changes, spawns, destroys at a map server and at the world, a player's move (release
//             here, take there), the edge of the online radius (out and in at once), a squad as a unit, a story
//             teleport of an NPC (release, teleport at the world, take elsewhere), a player leaving mid-transfer, the
//             world aborting a grant, a map server crash (its late packets still arrive), the bridge cut, a map server
//             drained and stopped, a restart (a new peer id, or the old one when nothing of it is in flight), a save
//             (the world's objects plus the journal) and a load (a fresh Ledger, load_journal, resolve_after_load,
//             every map server restarted empty);
//   ce1     - the mix that found review C1: 30 % takes, 25 % edge of the radius, 30 % world aborts, no random quiet;
//   reuse   - the default mix plus ids used again (a map server spawns a destroyed id, the world makes one anew);
//   limits  - the default mix with ids used again under small limits (journal 1-4 entries / 200-600 bytes,
//             tombstones 6-12 s, grant timeout 1.5-5 s), so R6 and the tombstone's end are reached.
// Half the runs audit as they go (requirement 3); a third of those inject faults: a misrouted copy of a grant (a
// duplicate) and an object the engine lost behind the holder's back (a loss). Every finding must be one of the faults
// injected, and healing must clear them.
// The oracle is the model, never the ledger: registrations and destroys come from the replies the simulator delivered;
// the last confirmed state of each object from the replies to Snapshot, ReleasePrepare/ReleaseCommit and SpawnPrepare;
// what each map server runs from the engine events (Create, Remove, Refused) plus its own spawns and destroys.
// After every step (and for the touched id after every delivered packet): the ledger's ids are the model's, one owner
// each, the world's copy is the last confirmed state; no id with two authors (the world when it owns the object and it
// is not frozen, a map server when its engine runs it); a holder and its engine agree; a destroyed id is not written;
// a take carries the last confirmed state; a lost map server's prepared release is completed with its state. In a quiet
// period (no new wishes, the network drained): the journal is empty, no fault is left, every state is the last one the
// game gave it, the owner's copy is the world's, the auditor finds nothing and the level hashes agree.
//   COOP_FUZZ_RUNS=<n>         runs (default 300 000), seeds splitmix64(kSeedBase + run index), on all cores
//   COOP_FUZZ_PROFILE=<name>   default | ce1 | reuse | limits: every run of that profile
//   COOP_FUZZ_SEED=<seed>      replay one seed with a trace (decimal or 0x hex); COOP_FUZZ_OPS=<n> limits operations
//   COOP_FUZZ_THREADS=<n>      worker threads (default: the hardware's, at most 16)
//   COOP_FUZZ_BIG=<n>          one run in n is full-size (default kBigEvery; 0: none)
// On a violation: the seed, the step, the smallest operation count that still fails and its trace.
// One run in kBigEvery (not ce1) is the full-size world of the plan (20-200 objects, 150-399 operations); the others
// are small (3-10 objects, 10-49 operations).
#include "test_util.h"

#include "coop_xfer.h"

#include <algorithm>
#include <atomic>
#include <cinttypes>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
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
constexpr size_t kWindow = 8; // a packet is picked among the first kWindow in flight that are due
constexpr uint64_t kMaxAgeMs = 5000; // R4: a tombstone outlives every packet - older ones are lost
constexpr uint32_t kBigEvery = 20; // 300 000 runs stay under 60 s on one thread (measured: 53 s)
constexpr uint64_t kFullCheckEvery = 64;
constexpr uint32_t kQuietStepMs = 100;
constexpr uint32_t kQuietMaxMs = 600000; // a quiet period that does not settle in 10 simulated minutes is a livelock
constexpr uint64_t kTimeLimitMs = 60000;

enum class Profile : uint8_t
{
	Default,
	Ce1,
	Reuse,
	Limits,
};
constexpr int kProfiles = 4;

const char* profile_name(Profile p)
{
	switch (p)
	{
	case Profile::Default: return "default";
	case Profile::Ce1: return "ce1";
	case Profile::Reuse: return "reuse";
	case Profile::Limits: return "limits";
	}
	return "?";
}

enum class Do : uint8_t
{
	Take,
	Release,
	Change,
	WorldChange,
	Spawn,
	Destroy,
	WorldDestroy,
	Move,
	Edge,
	Squad,
	Teleport,
	Leave,
	Abort,
	Crash,
	Bridge,
	Drain,
	Restart,
	Save,
	Load,
	Reuse,
	Idle,
};

struct Weight
{
	Do what;
	uint32_t w;
};

const std::vector<Weight>& mix(Profile p)
{
	static const std::vector<Weight> base = {{Do::Take, 22}, {Do::Release, 12}, {Do::Change, 12}, {Do::WorldChange, 4},
		{Do::Spawn, 6}, {Do::Destroy, 4}, {Do::WorldDestroy, 2}, {Do::Move, 6}, {Do::Edge, 2}, {Do::Squad, 3},
		{Do::Teleport, 3}, {Do::Leave, 4}, {Do::Abort, 3}, {Do::Crash, 2}, {Do::Bridge, 1}, {Do::Drain, 2},
		{Do::Restart, 2}, {Do::Save, 3}, {Do::Load, 2}, {Do::Idle, 5}};
	static const std::vector<Weight> ce1 = {{Do::Take, 30}, {Do::Edge, 25}, {Do::Abort, 30}, {Do::Release, 4},
		{Do::Change, 3}, {Do::Spawn, 2}, {Do::Destroy, 1}, {Do::Crash, 1}, {Do::Save, 2}, {Do::Load, 1}, {Do::Idle, 1}};
	static const std::vector<Weight> reuse = [] {
		std::vector<Weight> v = base;
		v.push_back({Do::Reuse, 10});
		return v;
	}();
	static const std::vector<Weight> limits = [] {
		std::vector<Weight> v = base;
		v.push_back({Do::Reuse, 6});
		return v;
	}();
	switch (p)
	{
	case Profile::Ce1: return ce1;
	case Profile::Reuse: return reuse;
	case Profile::Limits: return limits;
	default: return base;
	}
}

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
	if (b->size() != 6 + v % 5)
		return false;
	for (size_t i = 6; i < b->size(); ++i)
		if ((*b)[i] != uint8_t(v * 31 + i))
			return false;
	return true;
}

struct Worst
{
	size_t net = 0; // packets in the network at once
	size_t journal = 0; // journal entries at once
	size_t held = 0; // ids one map server tracks at once
	uint64_t quiet_ms = 0; // simulated time a quiet period took to settle
	uint64_t ops = 0; // operations in one run
	uint64_t age = 0; // the oldest packet delivered (ms)

	void merge(const Worst& o)
	{
		net = std::max(net, o.net);
		journal = std::max(journal, o.journal);
		held = std::max(held, o.held);
		quiet_ms = std::max(quiet_ms, o.quiet_ms);
		ops = std::max(ops, o.ops);
		age = std::max(age, o.age);
	}
};

struct Stats
{
	uint64_t runs = 0, big = 0, saves = 0, loads = 0, crashes = 0, drains = 0, quiets = 0, audits = 0, dup_faults = 0,
	         lose_faults = 0, healed = 0, drifts = 0, journal_full = 0, reused = 0, refusals = 0;

	void merge(const Stats& o)
	{
		runs += o.runs;
		big += o.big;
		saves += o.saves;
		loads += o.loads;
		crashes += o.crashes;
		drains += o.drains;
		quiets += o.quiets;
		audits += o.audits;
		dup_faults += o.dup_faults;
		lose_faults += o.lose_faults;
		healed += o.healed;
		drifts += o.drifts;
		journal_full += o.journal_full;
		reused += o.reused;
		refusals += o.refusals;
	}
};

struct Result
{
	bool ok = true;
	std::string error;
	uint64_t step = 0;
	uint32_t ops = 0;
	Profile profile = Profile::Default;
	Stats stats;
	Worst worst;
};

class Sim
{
public:
	Sim(uint64_t seed, uint32_t op_limit, std::vector<std::string>* trace, int forced, uint32_t big_every)
		: m_r(seed), m_op_limit(op_limit), m_trace(trace), m_forced(forced), m_big_every(big_every)
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
			if (m_faults && m_r.percent(3))
				inject_lose();
			deliver(m_r.below(8));
			tick_all();
			housekeeping();
			if (m_audits && m_r.percent(m_audit_pct))
				audit_round(false);
			check_step(m_res.step % kFullCheckEvery == 0);
			if (m_res.ok && m_random_quiet && m_r.percent(2))
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
		Peer peer = 0;
		bool up = false;
		bool draining = false;
		std::set<uint16_t> has; // what its engine runs (Create/Remove events, its own spawns and destroys)
		std::set<uint16_t> wanted; // what its engine asked for and neither got nor took back
		std::set<uint16_t> lost; // injected fault: the engine lost the object, the holder does not know
	};
	struct Flight
	{
		Packet p;
		uint64_t sent;
		uint64_t at;
	};
	struct Release // a release the world acknowledged (Ack) and has not applied yet
	{
		Peer by;
		uint32_t gen;
		uint32_t v;
	};
	struct Save
	{
		std::vector<std::pair<uint16_t, Bytes>> world;
		std::string journal;
		std::set<uint16_t> reg, dead;
		std::map<uint16_t, uint32_t> conf;
	};

	Rng m_r;
	uint32_t m_op_limit;
	std::vector<std::string>* m_trace;
	int m_forced;
	uint32_t m_big_every;
	Result m_res;
	Profile m_profile = Profile::Default;
	bool m_random_quiet = true, m_audits = false, m_faults = false;
	uint32_t m_dup_pct = 0;
	uint32_t m_audit_pct = 20; // a full-size world audits less often: an audit costs what the network and the report do
	Ledger::Limits m_limits;
	std::unique_ptr<Ledger> m_w;
	std::vector<Map> m_maps;
	Peer m_next_peer = 1;
	std::deque<Flight> m_net;
	uint64_t m_now = 1000;
	uint32_t m_loss = 0, m_dup = 0, m_delay = 0;
	uint16_t m_next_id = 1000;
	// The model: what the game did and what the replies said, kept apart from the ledger.
	std::set<uint16_t> m_reg; // registered: made by the world, or a spawn the world answered
	std::set<uint16_t> m_dead; // destroyed (a destroy the world answered, or the world's own)
	std::map<uint16_t, Peer> m_spawning; // spawned at a map server, not answered yet
	std::map<uint16_t, uint32_t> m_conf; // the last confirmed state version (the world's copy)
	std::map<uint16_t, uint32_t> m_truth; // the last state version the game gave each object
	std::map<uint16_t, uint32_t> m_ver; // versions handed out (never reused)
	std::map<uint16_t, Release> m_rel;
	std::set<uint16_t> m_world; // written by the world at the last check
	std::map<uint16_t, size_t> m_faulty; // an injected duplicate: the map server that holds it
	std::map<uint16_t, size_t> m_teleport; // story teleports waiting for the NPC to be back at the world
	std::unique_ptr<Save> m_save;
	std::vector<uint16_t> m_dirty; // ids touched since the last check

	void touch(uint16_t id) { m_dirty.push_back(id); }

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

	void fail_id(const char* what, uint16_t id) { fail(std::string(what) + " (id " + std::to_string(id) + ")"); }

	Bytes new_state(uint16_t id)
	{
		const uint32_t v = ++m_ver[id];
		m_truth[id] = v;
		return make_state(id, v);
	}

	static uint32_t version_of(const Bytes& b)
	{
		uint16_t id = 0;
		uint32_t v = 0;
		return read_state(&b, id, v) ? v : 0;
	}

	int slot_of(Peer p) const
	{
		for (size_t k = 0; k < m_maps.size(); ++k)
			if (m_maps[k].up && m_maps[k].peer == p)
				return int(k);
		return -1;
	}

	void start_map(size_t k, Peer peer)
	{
		Map& m = m_maps[k];
		m.h = std::make_unique<Holder>(peer);
		m.peer = peer;
		m.up = true;
		m.draining = false;
		m.has.clear();
		m.wanted.clear();
		m.lost.clear();
	}

	void setup()
	{
		m_profile = m_forced >= 0 ? Profile(m_forced) : Profile(m_r.below(100) < 40 ? 0 : 1 + m_r.below(3));
		m_res.profile = m_profile;
		const bool big = m_profile != Profile::Ce1 && m_big_every && m_r.below(m_big_every) == 0;
		m_res.stats.big = big ? 1 : 0;
		if (big)
			m_audit_pct = 4;
		uint32_t maps = 1 + m_r.below(3), objects = big ? 20 + m_r.below(181) : 3 + m_r.below(8);
		uint32_t ops = big ? 150 + m_r.below(250) : 10 + m_r.below(40);
		m_loss = m_r.below(31);
		m_dup = m_r.below(11);
		m_delay = m_r.below(2001);
		if (m_profile == Profile::Ce1)
		{
			maps = 1 + m_r.below(2);
			objects = 1 + m_r.below(3);
			ops = 40 + m_r.below(41);
			m_loss = m_r.below(11);
			m_delay = 1000 + m_r.below(1001);
			m_random_quiet = false;
		}
		if (m_profile == Profile::Reuse)
			m_limits.tombstone_ms = 6000 + m_r.below(6001);
		if (m_profile == Profile::Limits)
		{
			m_limits.journal_entries = 1 + m_r.below(4);
			m_limits.journal_bytes = 200 + m_r.below(401);
			m_limits.tombstone_ms = 6000 + m_r.below(6001);
			m_limits.grant_timeout_ms = 1500 + m_r.below(3501);
		}
		m_audits = m_r.percent(50);
		m_faults = m_audits && m_r.percent(33);
		m_dup_pct = m_faults ? 5 + m_r.below(16) : 0;
		m_res.ops = std::min(ops, m_op_limit);
		m_w = std::make_unique<Ledger>(m_limits);
		m_maps.resize(maps);
		for (size_t k = 0; k < maps; ++k)
			start_map(k, m_next_peer++);
		for (uint16_t id = 1; id <= objects; ++id)
			world_add(id);
		log(std::string("setup: profile ") + profile_name(m_profile) + (big ? " (full size)" : "") + ", " +
			std::to_string(maps) + " map servers, " + std::to_string(objects) + " objects, " +
			std::to_string(m_res.ops) + " operations, loss " + std::to_string(m_loss) + "%, dup " +
			std::to_string(m_dup) + "%, delay 0-" + std::to_string(m_delay) + " ms, audits " +
			std::to_string(int(m_audits)) + ", faults " + std::to_string(int(m_faults)));
		m_res.worst.ops = m_res.ops;
	}

	void world_add(uint16_t id)
	{
		m_w->add_world_object(id, new_state(id));
		m_reg.insert(id);
		m_dead.erase(id);
		m_conf[id] = m_truth[id];
	}

	// ---- network --------------------------------------------------------------------------------------------------

	void send(std::vector<Packet> ps)
	{
		for (Packet& p : ps)
		{
			touch(p.key.id);
			if (m_r.percent(m_loss))
			{
				log("lost " + describe_packet(p));
				continue;
			}
			if (m_r.percent(m_dup))
				m_net.push_back({p, m_now, m_now + m_r.below(m_delay + 1)});
			m_net.push_back({std::move(p), m_now, m_now + m_r.below(m_delay + 1)});
		}
		m_res.worst.net = std::max(m_res.worst.net, m_net.size());
	}

	// Delivers up to `n` packets that are due, each picked at random among the first kWindow in flight; a packet older
	// than kMaxAgeMs is lost.
	size_t deliver(size_t n)
	{
		size_t done = 0;
		for (; done < n && m_res.ok; ++done)
		{
			while (!m_net.empty() && m_now > m_net.front().sent + kMaxAgeMs)
				m_net.pop_front();
			size_t due[kWindow];
			size_t k = 0;
			for (size_t i = 0; i < m_net.size() && i < kWindow; ++i)
				if (m_net[i].at <= m_now && m_now <= m_net[i].sent + kMaxAgeMs)
					due[k++] = i;
			if (!k)
				break;
			const size_t at = due[m_r.below(uint32_t(k))];
			Flight f = std::move(m_net[at]);
			m_net.erase(m_net.begin() + std::ptrdiff_t(at));
			m_res.worst.age = std::max(m_res.worst.age, m_now - f.sent);
			dispatch(f.p);
		}
		return done;
	}

	void dispatch(const Packet& p)
	{
		log(describe_packet(p));
		const uint16_t id = p.key.id;
		if (p.to == kWorld)
		{
			std::vector<Packet> out = m_w->on_packet(p, m_now);
			observe(p, out);
			send(std::move(out));
		}
		else
		{
			const int k = slot_of(p.to);
			if (k < 0)
				return; // nobody listens there any more
			if (p.op == Op::Grant && m_dup_pct && m_r.percent(m_dup_pct) && !m_faulty.count(id))
				misroute(p, size_t(k));
			send(m_maps[size_t(k)].h->on_packet(p, m_now));
			events(size_t(k));
		}
		check_id(id);
	}

	// Fault: a copy of a grant reaches another map server that asks for the same object.
	void misroute(const Packet& p, size_t k)
	{
		for (size_t b = 0; b < m_maps.size(); ++b)
		{
			Map& m = m_maps[b];
			if (b == k || !m.up || !m.h->requesting(p.key.id))
				continue;
			Packet q = p;
			q.to = m.peer;
			log("fault: misrouted copy " + describe_packet(q));
			m_faulty[p.key.id] = b;
			send(m.h->on_packet(q, m_now));
			events(b);
			if (m.h->authors(p.key.id))
				++m_res.stats.dup_faults;
			else
				m_faulty.erase(p.key.id);
			return;
		}
	}

	// The model learns from the world's replies what it registered, destroyed and confirmed.
	void observe(const Packet& p, const std::vector<Packet>& out)
	{
		const uint16_t id = p.key.id;
		auto reply = [&](Op op) -> const Packet* {
			for (const Packet& q : out)
				if (q.op == op && q.to == p.from && q.key.id == id)
					return &q;
			return nullptr;
		};
		switch (p.op)
		{
		case Op::SpawnPrepare:
			if (reply(Op::Ack) && !m_reg.count(id))
			{
				auto sp = m_spawning.find(id);
				if (sp == m_spawning.end() || sp->second != p.from)
					return fail_id("the world registered a spawn nobody made (a late copy beat the tombstone?)", id);
				m_spawning.erase(sp);
				m_reg.insert(id);
				m_conf[id] = version_of(p.payload);
			}
			break;
		case Op::Destroy:
			// A spawn the world never registered ends when its map server forgets it (housekeeping): a Done for a
			// Destroy {0} may answer an earlier life's copy (R4), so it says nothing about this one.
			if (reply(Op::Done) && m_reg.erase(id))
			{
				m_dead.insert(id);
				m_conf.erase(id);
				m_truth.erase(id);
				m_rel.erase(id);
			}
			break;
		case Op::ReleasePrepare:
			if (const Packet* a = reply(Op::Ack))
				m_rel[id] = Release{p.from, a->key.gen, version_of(p.payload)};
			break;
		case Op::ReleaseCommit:
			if (const Packet* d = reply(Op::Done))
			{
				auto it = m_rel.find(id);
				if (it != m_rel.end() && it->second.gen == d->key.gen && it->second.by == p.from)
				{
					m_conf[id] = it->second.v;
					m_rel.erase(it);
				}
			}
			break;
		case Op::Snapshot:
			if (const Packet* a = reply(Op::Snapshot))
			{
				uint32_t in = 0, back = 0;
				Bytes st, none;
				if (read_snapshot(p.payload, in, st) && read_snapshot(a->payload, back, none) && in == back)
					m_conf[id] = version_of(st);
			}
			break;
		default:
			break;
		}
	}

	// What the engine of map server k is told to do.
	void events(size_t k)
	{
		Map& m = m_maps[k];
		std::set<uint16_t> removed;
		for (const Holder::Event& e : m.h->take_events())
		{
			switch (e.kind)
			{
			case Holder::Event::Kind::Create:
			{
				if (m.has.count(e.id))
					return fail_id("an object created twice", e.id);
				if (!m.wanted.count(e.id) && !removed.count(e.id))
					return fail_id("an object created that nobody asked for", e.id);
				auto f = m_faulty.find(e.id);
				if ((f == m_faulty.end() || f->second != k) && m_reg.count(e.id) && version_of(e.state) != m_conf[e.id])
					return fail_id("a take that does not carry the last confirmed state", e.id);
				m.has.insert(e.id);
				m.wanted.erase(e.id);
				break;
			}
			case Holder::Event::Kind::Remove:
			{
				if (!m.has.count(e.id) && !m.lost.count(e.id))
					return fail_id("an object removed that is not there", e.id);
				auto f = m_faulty.find(e.id);
				if (f != m_faulty.end() && f->second == k)
					m_faulty.erase(f); // the injected copy is gone
				m.has.erase(e.id);
				m.lost.erase(e.id);
				removed.insert(e.id);
				break;
			}
			case Holder::Event::Kind::Refused:
				if (!m.wanted.count(e.id) && !removed.count(e.id))
					return fail_id("a request refused that nobody made", e.id);
				if (!m.h->requesting(e.id))
					m.wanted.erase(e.id);
				++m_res.stats.refusals;
				break;
			}
		}
	}

	void tick_all()
	{
		send(m_w->tick(m_now));
		for (size_t k = 0; k < m_maps.size(); ++k)
			if (m_maps[k].up)
			{
				send(m_maps[k].h->tick(m_now));
				events(k);
			}
	}

	// ---- checks -----------------------------------------------------------------------------------------------------

	void check_id(uint16_t id)
	{
		if (!m_res.ok)
			return;
		const bool reg = m_w->registered(id);
		if (reg != (m_reg.count(id) != 0))
			return fail_id(reg ? "registered in the ledger without a registration the model saw" :
			                     "lost: a registered id vanished from the ledger without a destroy",
				id);
		if (reg)
		{
			if (m_w->owner_count(id) != 1)
				return fail_id("a registered id without exactly one owner in the ledger", id);
			uint16_t sid = 0;
			uint32_t v = 0;
			if (!read_state(m_w->last_confirmed(id), sid, v) || sid != id)
				return fail_id("the world holds a state that is not this object's", id);
			if (v != m_conf[id])
				return fail_id("the world's copy is not the last confirmed state", id);
		}
		const bool wa = m_w->world_authors(id);
		uint32_t authors = wa ? 1 : 0;
		for (size_t k = 0; k < m_maps.size(); ++k)
		{
			Map& m = m_maps[k];
			if (!m.up)
				continue;
			const bool runs = m.has.count(id) != 0;
			if (m.h->authors(id) != (runs || m.lost.count(id)))
				return fail_id("a holder and its engine disagree", id);
			auto f = m_faulty.find(id);
			if (runs && (f == m_faulty.end() || f->second != k))
				++authors;
		}
		if (authors > 1)
			return fail_id("two authors", id);
		if (m_dead.count(id) && authors)
			return fail_id("a destroyed id is written", id);
		// The world writes it again (a release applied, a grant or a loss taken back): the game goes on from the last
		// confirmed state.
		if (wa && !m_world.count(id))
		{
			m_world.insert(id);
			m_truth[id] = m_conf[id];
		}
		else if (!wa)
			m_world.erase(id);
	}

	// After every step: the ids the step touched (every packet sent or delivered, every operation, every heal - nothing
	// else changes an id); all of them every kFullCheckEvery steps and in every quiet period.
	void check_step(bool full)
	{
		if (!m_res.ok)
			return;
		if (!full)
		{
			std::sort(m_dirty.begin(), m_dirty.end());
			m_dirty.erase(std::unique(m_dirty.begin(), m_dirty.end()), m_dirty.end());
			for (uint16_t id : m_dirty)
				check_id(id);
			m_dirty.clear();
			const size_t journal = m_w->journal_size();
			m_res.worst.journal = std::max(m_res.worst.journal, journal);
			if (journal >= m_limits.journal_entries)
				++m_res.stats.journal_full; // R6 reached: transfers wait for room
			if (m_w->counters().in_flight != journal)
				fail("the in-flight counter differs from the journal");
			return;
		}
		m_dirty.clear();
		std::set<uint16_t> ids(m_reg.begin(), m_reg.end());
		ids.insert(m_dead.begin(), m_dead.end());
		for (const auto& s : m_spawning)
			ids.insert(s.first);
		for (uint16_t id : m_w->ids())
			ids.insert(id);
		for (Map& m : m_maps)
			if (m.up)
			{
				const std::vector<uint16_t> held = m.h->ids();
				m_res.worst.held = std::max(m_res.worst.held, held.size());
				ids.insert(held.begin(), held.end());
				ids.insert(m.has.begin(), m.has.end());
			}
		for (uint16_t id : ids)
			check_id(id);
		const size_t journal = m_w->journal_size();
		m_res.worst.journal = std::max(m_res.worst.journal, journal);
		if (m_w->counters().in_flight != journal)
			fail("the in-flight counter differs from the journal");
	}

	// ---- the auditor ------------------------------------------------------------------------------------------------

	// Every map server reports what its engine runs; buckets with something of it in flight (its packets, or a
	// transfer it does not write any more) wait - R9. Every finding must be a fault that was injected.
	void audit_round(bool settled)
	{
		for (size_t k = 0; k < m_maps.size() && m_res.ok; ++k)
		{
			Map& m = m_maps[k];
			if (!m.up)
				continue;
			uint32_t mask = kAllBuckets;
			if (!settled)
			{
				for (const Flight& f : m_net)
					if (f.p.from == m.peer)
						mask &= ~(1u << bucket_of(f.p.key.id));
				for (uint16_t id : m.h->ids())
					if (m.h->busy(id) && !m.h->authors(id))
						mask &= ~(1u << bucket_of(id));
			}
			std::vector<Entry> report;
			for (const Entry& e : m.h->report())
				if (m.has.count(e.id))
					report.push_back(e);
			const std::vector<Finding> found = audit(*m_w, m.peer, report, mask);
			++m_res.stats.audits;
			for (const Finding& f : found)
			{
				auto fault = m_faulty.find(f.id);
				if (f.kind == Violation::Duplicate && (fault == m_faulty.end() || fault->second != k))
					return fail_id("the auditor found a duplicate nobody injected", f.id);
				if (f.kind == Violation::Lost && !m.lost.count(f.id))
					return fail_id("the auditor found a loss nobody injected", f.id);
				if (settled && f.kind == Violation::Drift)
					return fail_id("the auditor found a drift in a quiet period", f.id);
				log(describe(f));
				if (f.kind == Violation::Drift)
					++m_res.stats.drifts;
				else
					++m_res.stats.healed;
			}
			if (found.empty())
				continue;
			send(heal(*m_w, found));
			for (const Finding& f : found)
				check_id(f.id);
		}
	}

	// Fault: an engine loses an object it runs, the holder does not know.
	void inject_lose()
	{
		const int k = live_map();
		if (k < 0)
			return;
		Map& m = m_maps[size_t(k)];
		std::vector<uint16_t> settled;
		for (uint16_t id : m.has)
			if (m.h->authors(id) && !m.h->busy(id) && !m.h->frozen(id) && !m_faulty.count(id))
				settled.push_back(id);
		uint16_t id = 0;
		if (!pick(settled, id))
			return;
		touch(id);
		log("fault: M" + std::to_string(m.peer) + "'s engine loses id " + std::to_string(id));
		m.has.erase(id);
		m.lost.insert(id);
		++m_res.stats.lose_faults;
	}

	// ---- housekeeping -----------------------------------------------------------------------------------------------

	void housekeeping()
	{
		for (size_t k = 0; k < m_maps.size() && m_res.ok; ++k)
		{
			Map& m = m_maps[k];
			if (!m.up || !m.draining || !m.h->idle() || !m.h->ids().empty())
				continue;
			if (!m_w->owned_by(m.peer).empty())
				return fail("a drained map server stopped with objects the ledger still gives it");
			log("M" + std::to_string(m.peer) + " stops (drained)");
			stop(k);
			++m_res.stats.drains;
		}
		for (auto it = m_teleport.begin(); it != m_teleport.end() && m_res.ok;)
		{
			const uint16_t id = it->first;
			const size_t to = it->second;
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
			log("teleport id " + std::to_string(id) + " to slot " + std::to_string(to));
			world_update(id);
			if (to < m_maps.size() && m_maps[to].up && !m_maps[to].draining)
				take(int(to), id);
			it = m_teleport.erase(it);
		}
		for (auto it = m_faulty.begin(); it != m_faulty.end();)
		{
			const Map& m = m_maps[it->second];
			if (!m.up || !m.h->authors(it->first))
			{
				touch(it->first);
				it = m_faulty.erase(it);
			}
			else
				++it;
		}
		// A spawn the world never registered and its map server forgot (destroyed first, or refused): gone.
		for (auto it = m_spawning.begin(); it != m_spawning.end();)
		{
			const int k = slot_of(it->second);
			const uint16_t id = it->first;
			if (k >= 0 && !m_w->registered(id) && !m_maps[size_t(k)].h->busy(id) && !m_maps[size_t(k)].h->authors(id))
			{
				touch(id);
				m_truth.erase(id);
				m_dead.insert(id);
				it = m_spawning.erase(it);
			}
			else
				++it;
		}
	}

	// A map server goes away for good (R7): its process is gone; what it sent is still on its way and must be ignored.
	void stop(size_t k)
	{
		Map& m = m_maps[k];
		const Peer peer = m.peer;
		std::vector<uint16_t> involved;
		for (uint16_t id : m_w->ids())
			if (m_w->owner(id) == peer || m_w->peer(id) == peer)
				involved.push_back(id);
		m.up = false;
		m.draining = false;
		m.has.clear();
		m.wanted.clear();
		m.lost.clear();
		for (auto it = m_faulty.begin(); it != m_faulty.end();)
			it = it->second == k ? m_faulty.erase(it) : std::next(it);
		m_w->server_lost(peer, m_now); // its Drops go to a closed connection
		for (auto it = m_rel.begin(); it != m_rel.end();)
		{
			if (it->second.by == peer)
			{
				m_conf[it->first] = it->second.v; // a prepared release is completed with its state
				it = m_rel.erase(it);
			}
			else
				++it;
		}
		for (auto it = m_spawning.begin(); it != m_spawning.end();)
		{
			if (it->second == peer)
			{
				m_truth.erase(it->first);
				it = m_spawning.erase(it); // never registered: it died with the process
			}
			else
				++it;
		}
		for (uint16_t id : involved)
		{
			if (!m_w->registered(id))
				return fail_id("a lost map server's object vanished", id);
			if (!m_w->world_authors(id))
				return fail_id("a lost map server's object is not back at the world", id);
			check_id(id);
		}
	}

	// ---- operations -------------------------------------------------------------------------------------------------

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

	// An id the engine of map server k runs and may change (not frozen for a release).
	bool pick_free(int k, uint16_t& out)
	{
		const Map& m = m_maps[size_t(k)];
		std::vector<uint16_t> free;
		for (uint16_t id : m.has)
		{
			auto f = m_faulty.find(id);
			if (!m.h->frozen(id) && (f == m_faulty.end() || f->second != size_t(k))) // not an injected duplicate
				free.push_back(id);
		}
		return pick(free, out);
	}

	void take(int k, uint16_t id)
	{
		touch(id);
		Map& m = m_maps[size_t(k)];
		log("op take id " + std::to_string(id) + " at M" + std::to_string(m.peer));
		send(m.h->want_online(id, m_now));
		if (!m.has.count(id) || m.h->frozen(id))
			m.wanted.insert(id);
		events(size_t(k));
	}

	// Map server k lets go of `id`: a release with a new state when its engine runs it, else a wish taken back.
	void release(int k, uint16_t id)
	{
		touch(id);
		Map& m = m_maps[size_t(k)];
		auto f = m_faulty.find(id);
		if (m.lost.count(id) || (f != m_faulty.end() && f->second == size_t(k)))
			return; // the engine does not have it, or it is an injected duplicate that only the auditor removes
		const bool runs = m.has.count(id) && !m.h->frozen(id);
		log("op release id " + std::to_string(id) + " at M" + std::to_string(m.peer));
		send(m.h->want_offline(id, runs ? new_state(id) : Bytes(), m_now));
		m.wanted.erase(id);
		events(size_t(k));
	}

	void world_update(uint16_t id)
	{
		touch(id);
		if (!m_w->world_update(id, new_state(id)))
			return fail_id("world_update refused an object the world writes", id);
		m_conf[id] = m_truth[id];
	}

	void random_op()
	{
		const std::vector<Weight>& w = mix(m_profile);
		uint32_t total = 0;
		for (const Weight& x : w)
			total += x.w;
		uint32_t roll = m_r.below(total);
		Do what = Do::Idle;
		for (const Weight& x : w)
		{
			if (roll < x.w)
			{
				what = x.what;
				break;
			}
			roll -= x.w;
		}
		uint16_t id = 0;
		struct Touch // every id an operation names is checked after the step
		{
			Sim& sim;
			uint16_t& id;
			~Touch() { sim.touch(id); }
		} touched{*this, id};
		switch (what)
		{
		case Do::Take:
		{
			const int k = live_map();
			if (k >= 0 && (m_r.percent(5) ? pick(m_dead, id) : pick(m_reg, id)))
				take(k, id);
			break;
		}
		case Do::Release:
		{
			const int k = live_map();
			if (k >= 0 && pick_free(k, id))
				release(k, id);
			break;
		}
		case Do::Change:
		{
			const int k = live_map();
			if (k >= 0 && pick_free(k, id))
			{
				log("op change id " + std::to_string(id));
				send(m_maps[size_t(k)].h->changed(id, new_state(id), m_now));
			}
			break;
		}
		case Do::WorldChange:
			if (pick(m_reg, id) && m_w->world_authors(id))
			{
				log("op world change id " + std::to_string(id));
				world_update(id);
			}
			break;
		case Do::Spawn:
		{
			const int k = live_map();
			if (k < 0 || m_next_id >= 0xfff0)
				break;
			spawn(k, m_next_id++);
			break;
		}
		case Do::Destroy:
		{
			const int k = live_map();
			if (k >= 0 && pick_free(k, id))
			{
				Map& m = m_maps[size_t(k)];
				log("op destroy id " + std::to_string(id) + " at M" + std::to_string(m.peer));
				m.has.erase(id);
				m.wanted.erase(id);
				send(m.h->destroyed(id, m_now));
				events(size_t(k));
			}
			break;
		}
		case Do::WorldDestroy:
			if (pick(m_reg, id) && m_w->world_authors(id))
			{
				log("op world destroy id " + std::to_string(id));
				if (!m_w->world_destroy(id, m_now))
					return fail_id("world_destroy refused an object the world writes", id);
				m_reg.erase(id);
				m_conf.erase(id);
				m_truth.erase(id);
				m_dead.insert(id);
				check_id(id);
			}
			break;
		case Do::Move:
		{
			const int k = live_map();
			const int j = live_map();
			if (k >= 0 && j >= 0 && k != j && pick_free(k, id))
			{
				release(k, id);
				take(j, id);
			}
			break;
		}
		case Do::Edge:
		{
			const int k = live_map();
			if (k >= 0 && pick_free(k, id))
			{
				release(k, id);
				take(k, id);
			}
			break;
		}
		case Do::Squad:
		{
			const int k = live_map();
			if (k < 0)
				break;
			const uint32_t n = 2 + m_r.below(3);
			const bool in = m_r.percent(50);
			for (uint32_t i = 0; i < n; ++i)
			{
				if (in && pick(m_reg, id))
					take(k, id);
				else if (!in && pick_free(k, id))
					release(k, id);
			}
			break;
		}
		case Do::Teleport:
		{
			const int j = live_map();
			if (j < 0 || !pick(m_reg, id))
				break;
			m_teleport[id] = size_t(j);
			for (size_t k = 0; k < m_maps.size(); ++k)
				if (m_maps[k].up && m_maps[k].has.count(id) && !m_maps[k].h->frozen(id))
					release(int(k), id);
			break;
		}
		case Do::Leave:
		{
			const int k = live_map();
			if (k >= 0 && pick(m_maps[size_t(k)].h->ids(), id))
				release(k, id);
			break;
		}
		case Do::Abort:
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
			break;
		}
		case Do::Crash:
		{
			std::vector<int> ups;
			for (size_t k = 0; k < m_maps.size(); ++k)
				if (m_maps[k].up)
					ups.push_back(int(k));
			if (ups.empty())
				break;
			const int k = ups[m_r.below(uint32_t(ups.size()))];
			log("op crash M" + std::to_string(m_maps[size_t(k)].peer));
			stop(size_t(k));
			++m_res.stats.crashes;
			break;
		}
		case Do::Bridge:
			if (!m_r.percent(30))
				break;
			log("op bridge cut");
			for (size_t k = 0; k < m_maps.size() && m_res.ok; ++k)
				if (m_maps[k].up)
				{
					stop(k);
					++m_res.stats.crashes;
				}
			break;
		case Do::Drain:
		{
			const int k = live_map();
			if (k < 0)
				break;
			log("op drain M" + std::to_string(m_maps[size_t(k)].peer));
			m_maps[size_t(k)].draining = true;
			for (uint16_t i : m_maps[size_t(k)].h->ids())
				release(k, i);
			break;
		}
		case Do::Restart:
			for (size_t k = 0; k < m_maps.size(); ++k)
				if (!m_maps[k].up)
				{
					const Peer old = m_maps[k].peer;
					bool quiet_link = m_r.percent(50);
					for (const Flight& f : m_net)
						quiet_link = quiet_link && f.p.from != old && f.p.to != old;
					const Peer peer = quiet_link ? old : m_next_peer++;
					if (quiet_link)
						m_w->server_joined(peer);
					log("op restart slot " + std::to_string(k) + " as M" + std::to_string(peer));
					start_map(k, peer);
					break;
				}
			break;
		case Do::Save:
			save();
			break;
		case Do::Load:
			if (m_save)
				load();
			break;
		case Do::Reuse:
			if (!pick(m_dead, id))
				break;
			++m_res.stats.reused;
			if (m_r.percent(50))
			{
				log("op world makes id " + std::to_string(id) + " again");
				world_add(id);
				check_id(id);
			}
			else
			{
				const int k = live_map();
				const std::vector<uint16_t> tracked = k >= 0 ? m_maps[size_t(k)].h->ids() : std::vector<uint16_t>();
				if (k >= 0 && std::find(tracked.begin(), tracked.end(), id) == tracked.end())
				{
					m_dead.erase(id);
					spawn(k, id);
				}
			}
			break;
		case Do::Idle:
			break;
		}
	}

	void spawn(int k, uint16_t id)
	{
		touch(id);
		Map& m = m_maps[size_t(k)];
		log("op spawn id " + std::to_string(id) + " at M" + std::to_string(m.peer));
		m_spawning[id] = m.peer;
		m.has.insert(id);
		send(m.h->spawned(id, new_state(id), m_now));
		events(size_t(k));
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
			s->world.emplace_back(id, *m_w->last_confirmed(id));
		s->conf = m_conf;
		for (const auto& r : m_rel)
			s->conf[r.first] = r.second.v; // a release the world acknowledged is completed by the load
		s->journal = m_w->save_journal();
		if (s->journal.size() > m_limits.journal_bytes)
			return fail("the journal text is over its limit");
		s->reg = m_reg;
		s->dead = m_dead;
		m_save = std::move(s);
		++m_res.stats.saves;
	}

	void load()
	{
		log("op load");
		const Save& s = *m_save;
		m_w = std::make_unique<Ledger>(m_limits);
		for (const auto& o : s.world)
			m_w->add_world_object(o.first, o.second);
		if (!m_w->load_journal(s.journal))
			return fail("load_journal refused a journal it saved");
		m_w->resolve_after_load();
		m_net.clear(); // every connection is new
		for (size_t k = 0; k < m_maps.size(); ++k)
			start_map(k, m_next_peer++);
		m_reg = s.reg;
		m_dead = s.dead;
		m_conf = s.conf;
		m_truth = s.conf;
		m_rel.clear();
		m_spawning.clear();
		m_teleport.clear();
		m_faulty.clear();
		m_world.clear();
		m_dirty.clear();
		++m_res.stats.loads;
		if (m_w->journal_size() != 0)
			return fail("the journal is not empty after resolve_after_load");
		for (uint16_t id : m_reg)
		{
			if (!m_w->world_authors(id))
				return fail_id("after a load an object is not the world's", id);
			check_id(id);
		}
		check_step(true);
	}

	// ---- quiet ------------------------------------------------------------------------------------------------------

	bool settled()
	{
		for (Map& m : m_maps)
			if (m.up && (!m.h->idle() || !m.lost.empty()))
				return false;
		return m_net.empty() && m_w->journal_size() == 0 && m_faulty.empty();
	}

	void quiet()
	{
		if (!m_res.ok)
			return;
		log("quiet");
		++m_res.stats.quiets;
		m_teleport.clear();
		const uint64_t start = m_now;
		for (uint32_t i = 0; m_res.ok && !settled(); ++i)
		{
			if (m_now - start > kQuietMaxMs)
				return fail("no quiet: transfers still going after " + std::to_string(kQuietMaxMs / 1000) + " s");
			// No new wishes: requests (one for an object another map server keeps waits for it for good) and "take it
			// again after the release" are taken back.
			for (size_t k = 0; k < m_maps.size(); ++k)
			{
				Map& m = m_maps[k];
				if (!m.up)
					continue;
				for (uint16_t id : m.h->ids())
					if (m.h->requesting(id) || m.h->frozen(id) || (m.h->busy(id) && !m.h->authors(id)))
					{
						send(m.h->want_offline(id, Bytes(), m_now));
						events(k);
					}
				m.wanted.clear();
			}
			m_now += kQuietStepMs;
			const size_t before = m_net.size();
			const size_t delivered = deliver(SIZE_MAX);
			tick_all();
			housekeeping();
			if (m_audits && i % 4 == 0)
				audit_round(false);
			if (delivered || m_net.size() != before || !m_dirty.empty())
				check_step(false);
		}
		if (!m_res.ok)
			return;
		check_step(true);
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
		if (!m_rel.empty())
			return fail_id("a release acknowledged and never applied", m_rel.begin()->first);
		const std::vector<uint16_t> ids = m_w->ids();
		if (std::set<uint16_t>(ids.begin(), ids.end()) != m_reg)
			return fail("the ledger's ids differ from the model's in a quiet period");
		for (uint16_t id : m_reg)
		{
			if (m_conf[id] != m_truth[id])
				return fail_id("the last confirmed state is not the game's last state", id);
			const Peer owner = m_w->owner(id);
			uint32_t runs = 0;
			for (Map& m : m_maps)
				if (m.up && m.has.count(id))
					++runs;
			if (owner == kWorld)
			{
				if (!m_w->world_authors(id) || runs)
					return fail_id("an object of the world is run elsewhere or frozen", id);
				continue;
			}
			const int k = slot_of(owner);
			if (k < 0)
				return fail_id("an object owned by a map server that is not there", id);
			const Map& m = m_maps[size_t(k)];
			if (!m.has.count(id) || runs != 1)
				return fail_id("lost: the owner does not run it", id);
			const Bytes* hs = m.h->state(id);
			if (!hs || *hs != *m_w->last_confirmed(id))
				return fail_id("the owner's state is not the last confirmed snapshot", id);
			if (m.h->gen(id) != m_w->gen(id))
				return fail_id("the owner's gen differs from the ledger's", id);
		}
		for (size_t k = 0; k < m_maps.size(); ++k)
		{
			Map& m = m_maps[k];
			for (uint16_t id : m.has)
				if (!m.up || !m_reg.count(id) || m_w->owner(id) != m.peer)
					return fail_id("an engine runs an object the ledger does not give its map server", id);
			if (!m.up)
				continue;
			std::vector<Entry> report;
			for (const Entry& e : m.h->report())
				report.push_back(e);
			if (mismatched(hash_of(report), hash_of(m_w->owned_by(m.peer))) != 0)
				return fail("level hashes differ in a quiet period at M" + std::to_string(m.peer));
		}
		audit_round(true);
	}
};

uint64_t env_u64(const char* name, uint64_t fallback)
{
	const char* v = std::getenv(name);
	if (!v || !*v)
		return fallback;
	return std::strtoull(v, nullptr, 0);
}

int env_profile()
{
	const char* v = std::getenv("COOP_FUZZ_PROFILE");
	if (!v || !*v)
		return -1;
	for (int p = 0; p < kProfiles; ++p)
		if (std::strcmp(v, profile_name(Profile(p))) == 0)
			return p;
	return -1;
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
void minimal_repro(uint64_t seed, uint32_t ops, int forced, uint32_t big_every)
{
	uint32_t smallest = ops;
	for (uint32_t n = 0; n < ops; ++n)
		if (!Sim(seed, n, nullptr, forced, big_every).run().ok)
		{
			smallest = n;
			break;
		}
	std::vector<std::string> trace;
	const Result r = Sim(seed, smallest, &trace, forced, big_every).run();
	std::printf("    minimal repro: seed 0x%016" PRIx64 " (%s), %u operations, step %" PRIu64 ": %s\n", seed,
		profile_name(r.profile), smallest, r.step, r.error.c_str());
	std::printf("    replay: set COOP_FUZZ_SEED=0x%016" PRIx64 " and COOP_FUZZ_OPS=%u%s, run coop_tests.exe "
	            "xfer_fuzz\n",
		seed, smallest, forced >= 0 ? " (and COOP_FUZZ_PROFILE)" : "");
	print_trace(trace, 300);
}
} // namespace

// Requirement 5: hundreds of thousands of runs, none with a lost or a doubled object.
TEST(xfer_fuzz)
{
	const int forced = env_profile();
	const uint32_t big_every = uint32_t(env_u64("COOP_FUZZ_BIG", kBigEvery)); // 1 run in n full-size, 0 none
	if (const char* replay = std::getenv("COOP_FUZZ_SEED"))
	{
		const uint64_t seed = std::strtoull(replay, nullptr, 0);
		const uint32_t ops = uint32_t(env_u64("COOP_FUZZ_OPS", UINT32_MAX));
		std::vector<std::string> trace;
		const Result r = Sim(seed, ops, &trace, forced, big_every).run();
		print_trace(trace, SIZE_MAX);
		std::printf("    seed 0x%016" PRIx64 " (%s): %s\n", seed, profile_name(r.profile),
			r.ok ? "ok" : r.error.c_str());
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
	Stats per[kProfiles];
	bool failed = false;
	uint64_t fail_seed = 0, fail_run = 0;
	Result fail_result;

	const uint64_t t0 = t::now_ms();
	auto worker = [&]() {
		Worst w;
		Stats s[kProfiles];
		for (;;)
		{
			const uint64_t i = next.fetch_add(1);
			if (i >= runs || stop.load())
				break;
			const uint64_t seed = splitmix64(kSeedBase + i);
			Result r = Sim(seed, UINT32_MAX, nullptr, forced, big_every).run();
			r.stats.runs = 1;
			w.merge(r.worst);
			s[int(r.profile)].merge(r.stats);
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
		for (int p = 0; p < kProfiles; ++p)
			per[p].merge(s[p]);
	};
	std::vector<std::thread> pool;
	for (unsigned i = 0; i < threads; ++i)
		pool.emplace_back(worker);
	for (std::thread& th : pool)
		th.join();
	const uint64_t ms = t::now_ms() - t0;

	Stats all;
	for (int p = 0; p < kProfiles; ++p)
		all.merge(per[p]);
	std::printf("    %" PRIu64 " runs on %u threads in %" PRIu64 " ms\n", all.runs, threads, ms);
	for (int p = 0; p < kProfiles; ++p)
	{
		const Stats& s = per[p];
		if (!s.runs)
			continue;
		std::printf("    %-7s %7" PRIu64 " runs (%" PRIu64 " full-size): %" PRIu64 " saves, %" PRIu64 " loads, %" PRIu64
		            " crashes, %" PRIu64 " drains, %" PRIu64 " quiets, %" PRIu64 " audits, faults %" PRIu64
		            " dup / %" PRIu64 " lost, healed %" PRIu64 ", drifts %" PRIu64 ", ids reused %" PRIu64
		            ", refusals %" PRIu64 ", steps with a full journal %" PRIu64 "\n",
			profile_name(Profile(p)), s.runs, s.big, s.saves, s.loads, s.crashes, s.drains, s.quiets, s.audits,
			s.dup_faults, s.lose_faults, s.healed, s.drifts, s.reused, s.refusals, s.journal_full);
	}
	std::printf("    worst: %zu packets in flight, %zu journal entries, %zu ids at one map server, %" PRIu64
	            " ms to settle, %" PRIu64 " operations, the oldest packet delivered %" PRIu64 " ms\n",
		worst.net, worst.journal, worst.held, worst.quiet_ms, worst.ops, worst.age);
	if (failed)
	{
		std::printf("    VIOLATION in run %" PRIu64 " (seed 0x%016" PRIx64 ", %s), step %" PRIu64 ": %s\n", fail_run,
			fail_seed, profile_name(fail_result.profile), fail_result.step, fail_result.error.c_str());
		minimal_repro(fail_seed, fail_result.ops, forced, big_every);
	}
	CHECK(!failed);
	CHECK_EQ(all.runs, runs);
	if (runs == kDefaultRuns && forced < 0)
		CHECK(ms <= kTimeLimitMs);
}
