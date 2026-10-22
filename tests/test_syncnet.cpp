// Anomaly Coop unit tests: coop.sync on the network (coop_syncnet.h; F2 T14, SYNC_SPEC §6.1-6.3, §6.5): scope names
// of the Lua API, the five sync messages, the host's stamping and routing of a change, the client's view of its own
// changes until the host answers, full copies at join, request limits, and the client's pacing of what the host
// rate-limits (coop_limits.h Pacer, Ruling F2-14).
#include "test_util.h"

#include "coop_limits.h"
#include "coop_syncnet.h"

#include <algorithm>
#include <cstdint>
#include <limits>
#include <string>
#include <utility>
#include <vector>

using coop::kHostPeer;
using coop::kInvalidPeer;
using coop::Msg;
using coop::PeerId;
using coop::Reader;
using coop::Writer;
namespace ss = coop::syncstore;
namespace sn = coop::syncnet;
using ss::ScopeId;
using ss::SetResult;
using ss::Store;
using ss::Value;
using ss::ValueType;

namespace
{
std::vector<uint8_t> bytes_of(const Writer& w) { return std::vector<uint8_t>(w.ptr(), w.ptr() + w.size()); }

std::string digest(uint32_t n)
{
	static const char* hex = "0123456789abcdef";
	std::string d(ss::kPlayerKeyDigits, 'b');
	for (size_t i = 0; i < 8; ++i)
		d[d.size() - 1 - i] = hex[(n >> (4 * i)) & 15];
	return d;
}


// The value a store shows for a key, Nil if none.
Value value_of(const Store& s, const ScopeId& scope, const std::string& key)
{
	const Value* v = s.get(scope, key);
	return v ? *v : Value();
}

// Everything a store holds, as bytes (its scopes in order, each as its full copy).
std::vector<uint8_t> dump(const Store& s, bool (*keep)(const ScopeId&) = nullptr)
{
	Writer w;
	for (const ScopeId& id : s.scopes())
		if (!keep || keep(id))
			s.encode_scope(w, id);
	return bytes_of(w);
}

// One message through its writer and reader.
template <class M, class W, class R>
bool through(const M& in, M& out, W write, R read)
{
	Writer w;
	write(w, in);
	const std::vector<uint8_t> b = bytes_of(w);
	Reader r(b.data(), b.size());
	return read(r, out) && r.remaining() == 0;
}

template <class R, class M>
bool reads(const std::vector<uint8_t>& b, R read, M& out)
{
	Reader r(b.data(), b.size());
	return read(r, out);
}
} // namespace

// ---------------------------------------------------------------- scope names

TEST(sync_net_scope_names)
{
	struct Ok
	{
		const char* text;
		sn::ScopeName::Kind kind;
		uint32_t peer;
		uint16_t id;
	};
	const Ok ok[] = {
		{"world", sn::ScopeName::World, 0, 0},
		{"session", sn::ScopeName::Session, 0, 0},
		{"player", sn::ScopeName::Player, 0, 0},
		{"player:0", sn::ScopeName::PlayerOf, 0, 0},
		{"player:7", sn::ScopeName::PlayerOf, 7, 0},
		{"player:4294967294", sn::ScopeName::PlayerOf, 4294967294u, 0},
		{"object:0", sn::ScopeName::Object, 0, 0},
		{"object:65534", sn::ScopeName::Object, 0, 65534},
		{"object", sn::ScopeName::AnyObject, 0, 0},
	};
	for (const Ok& c : ok)
	{
		sn::ScopeName s;
		CHECK_EQ(std::string(c.text) + (sn::parse_scope(c.text, s) ? " parsed" : " refused"), std::string(c.text) + " parsed");
		CHECK(s.kind == c.kind);
		CHECK_EQ(s.peer, c.peer);
		CHECK_EQ(s.id, c.id);
	}
	// One spelling per scope: no case, blanks, signs, leading zeros, ids out of range, a missing or extra part.
	for (const char* bad : {"", "World", "world ", " world", "worlds", "player:", "player:-1", "player:+1", "player:01",
	         "player:4294967295", "player:99999999999", "player:1x", "object:", "object:65535", "object:65536", "object:-0",
	         "object:00", "object:1:2", "object:0x10", "session:1", "world:0", "objects", "player:1 ", "obj:1"})
	{
		sn::ScopeName s;
		s.kind = sn::ScopeName::Session;
		s.peer = 3;
		CHECK_EQ(std::string(bad) + (sn::parse_scope(bad, s) ? " parsed" : " refused"), std::string(bad) + " refused");
		CHECK(s.kind == sn::ScopeName::Session && s.peer == 3); // untouched
	}
}

TEST(sync_net_names)
{
	CHECK(sn::name_ok("tasks.op"));
	CHECK(sn::name_ok(std::string(sn::kMaxName, 'n')));
	CHECK(!sn::name_ok(std::string(sn::kMaxName + 1, 'n')));
	for (const char* bad : {"", "a b", "a\tb", "\x7f", "na\xC3\xA4me"})
		CHECK_EQ(std::string(bad) + (sn::name_ok(bad) ? " ok" : " refused"), std::string(bad) + " refused");
}

TEST(sync_net_int_keys)
{
	// A Lua array index travels as a tagged decimal so that it comes back as a number, not as the text "1".
	for (const int64_t k : {int64_t(0), int64_t(1), int64_t(-1), int64_t(42), sn::kMaxIntKey, -sn::kMaxIntKey})
	{
		const std::string key = sn::int_key(k);
		CHECK_EQ(key[0], sn::kIntKeyTag);
		CHECK(key.size() <= ss::kMaxKey);
		int64_t back = 7;
		CHECK(sn::int_key_of(key, back));
		CHECK_EQ(back, k);
		CHECK(!sn::text_key_ok(key)); // a string key from Lua cannot pass for an index
	}
	CHECK(sn::text_key_ok("1"));
	CHECK(sn::text_key_ok(""));
	int64_t out = 5;
	for (const std::string bad : {std::string("1"), std::string("\x01"), std::string("\x01" "01"), std::string("\x01" "-0"),
	         std::string("\x01" "+1"), std::string("\x01" "1a"), std::string("\x01" "9007199254740993"),
	         std::string("\x01" " 1")})
	{
		CHECK(!sn::int_key_of(bad, out));
		CHECK_EQ(out, int64_t(5));
	}
}

// ---------------------------------------------------------------- wire

TEST(sync_net_client_set_wire)
{
	sn::ClientSet in;
	in.seq = 77;
	in.scope = ScopeId::player(digest(1));
	in.key = "perk/strength";
	in.value = ss::make_table({{"a", ss::make_number(1)}, {sn::int_key(1), ss::make_vec3(1.f, 2.f, 3.f)}});
	ss::canonicalize(in.value);
	sn::ClientSet out;
	REQUIRE(through(in, out, &sn::write_client_set, &sn::read_client_set));
	CHECK_EQ(out.seq, 77u);
	CHECK(out.scope == in.scope);
	CHECK_EQ(out.key, in.key);
	CHECK(ss::same(out.value, in.value));

	// A nil removes the key; an object scope by its host id.
	in.scope = ScopeId::object(4000);
	in.value = Value();
	REQUIRE(through(in, out, &sn::write_client_set, &sn::read_client_set));
	CHECK(out.scope == in.scope && out.value.type == ValueType::Nil);

	// Truncated anywhere, a bad key or a bad value: refused, the output stays.
	Writer w;
	sn::write_client_set(w, in);
	const std::vector<uint8_t> b = bytes_of(w);
	for (size_t n = 0; n < b.size(); ++n)
	{
		sn::ClientSet o;
		o.seq = 5;
		CHECK(!reads(std::vector<uint8_t>(b.begin(), b.begin() + ptrdiff_t(n)), &sn::read_client_set, o));
		CHECK_EQ(o.seq, 5u);
	}
	sn::ClientSet empty_key = in;
	empty_key.key.clear();
	sn::ClientSet o;
	CHECK(!through(empty_key, o, &sn::write_client_set, &sn::read_client_set));
	sn::ClientSet nan = in;
	nan.value = ss::make_number(std::numeric_limits<double>::quiet_NaN());
	CHECK(!through(nan, o, &sn::write_client_set, &sn::read_client_set));
}

TEST(sync_net_host_set_wire)
{
	// A change with the answer to its writer.
	sn::HostSet in;
	in.flags = sn::kAck;
	in.by = 3;
	in.ack = 12;
	in.scope = ScopeId::world();
	in.key = "k";
	in.value = ss::make_string("v");
	in.version = 99;
	sn::HostSet out;
	REQUIRE(through(in, out, &sn::write_host_set, &sn::read_host_set));
	CHECK_EQ(out.flags, uint8_t(sn::kAck));
	CHECK_EQ(out.by, PeerId(3));
	CHECK_EQ(out.ack, 12u);
	CHECK(out.has_change());
	CHECK(out.scope == in.scope && out.key == "k" && ss::same(out.value, in.value) && out.version == 99u);

	// A refusal: only the answer and its reason.
	sn::HostSet ref;
	ref.flags = sn::kAck | sn::kRefused;
	ref.by = 2;
	ref.ack = 4;
	ref.refused = SetResult::NotAllowed;
	REQUIRE(through(ref, out, &sn::write_host_set, &sn::read_host_set));
	CHECK(!out.has_change());
	CHECK(out.refused == SetResult::NotAllowed);
	CHECK_EQ(out.ack, 4u);

	// A dropped object scope (destroyed object).
	sn::HostSet drop;
	drop.flags = sn::kDrop;
	drop.scope = ScopeId::object(321);
	REQUIRE(through(drop, out, &sn::write_host_set, &sn::read_host_set));
	CHECK(!out.has_change());
	CHECK(out.scope == ScopeId::object(321));

	// What the host never sends is refused: unknown flags, a refusal without its answer or with a result that is no
	// refusal, a drop that also answers or drops another kind of scope, a change without a version.
	const auto refused = [](sn::HostSet m) {
		sn::HostSet o;
		return !through(m, o, &sn::write_host_set, &sn::read_host_set);
	};
	sn::HostSet m = in;
	m.flags = 8;
	CHECK(refused(m));
	m = ref;
	m.flags = sn::kRefused;
	CHECK(refused(m));
	m = ref;
	m.refused = SetResult::Ok;
	CHECK(refused(m));
	m.refused = SetResult::Same;
	CHECK(refused(m));
	m.refused = SetResult(200);
	CHECK(refused(m));
	m = drop;
	m.flags = sn::kDrop | sn::kAck;
	CHECK(refused(m));
	m = drop;
	m.scope = ScopeId::world();
	CHECK(refused(m));
	m = in;
	m.version = 0;
	CHECK(refused(m));
	m.version = ss::kMaxVersion + 1;
	CHECK(refused(m));

	Writer w;
	sn::write_host_set(w, in);
	const std::vector<uint8_t> b = bytes_of(w);
	for (size_t n = 0; n < b.size(); ++n)
	{
		sn::HostSet o;
		CHECK(!reads(std::vector<uint8_t>(b.begin(), b.begin() + ptrdiff_t(n)), &sn::read_host_set, o));
	}
}

TEST(sync_net_request_result_cast_wire)
{
	sn::Request q;
	q.id = 9;
	q.name = "tasks.op";
	q.args = ss::make_table({{sn::int_key(1), ss::make_string("complete")}, {sn::int_key(2), ss::make_number(5)}});
	ss::canonicalize(q.args);
	sn::Request q2;
	REQUIRE(through(q, q2, &sn::write_request, &sn::read_request));
	CHECK(q2.id == 9 && q2.name == "tasks.op" && ss::same(q2.args, q.args));

	sn::Result res;
	res.id = 9;
	res.ok = true;
	res.value = ss::make_number(3);
	sn::Result res2;
	REQUIRE(through(res, res2, &sn::write_result, &sn::read_result));
	CHECK(res2.id == 9 && res2.ok && ss::same(res2.value, res.value));

	sn::Cast c;
	c.name = "fx.boom";
	c.args = ss::make_vec3(1.f, 2.f, 3.f);
	sn::Cast c2;
	REQUIRE(through(c, c2, &sn::write_cast, &sn::read_cast));
	CHECK(c2.name == "fx.boom" && ss::same(c2.args, c.args));

	// Names are checked as coop.send_event checks them; an ok byte is 0 or 1.
	sn::Request bad = q;
	bad.name = "two words";
	CHECK(!through(bad, q2, &sn::write_request, &sn::read_request));
	bad.name = std::string(sn::kMaxName + 1, 'n');
	CHECK(!through(bad, q2, &sn::write_request, &sn::read_request));
	sn::Cast badc = c;
	badc.name.clear();
	CHECK(!through(badc, c2, &sn::write_cast, &sn::read_cast));
	Writer w;
	w.u32(1);
	w.u8(2);
	ss::write_value(w, Value());
	const std::vector<uint8_t> b = bytes_of(w);
	CHECK(!reads(b, &sn::read_result, res2));
}

// ---------------------------------------------------------------- host: one change and who hears of it

namespace
{
const sn::Delivery* to_one(const std::vector<sn::Delivery>& out, PeerId peer)
{
	for (const sn::Delivery& d : out)
		if (d.to == sn::Delivery::One && d.peer == peer)
			return &d;
	return nullptr;
}
const sn::Delivery* to_all(const std::vector<sn::Delivery>& out)
{
	for (const sn::Delivery& d : out)
		if (d.to == sn::Delivery::Everyone)
			return &d;
	return nullptr;
}
} // namespace

TEST(sync_net_host_stamps_from_one_counter)
{
	// Every change gets the next version of one counter, whatever its scope and writer (Ruling F2-24 contract).
	Store s;
	std::vector<sn::Delivery> out;
	sn::Change ev;
	CHECK(sn::host_set(s, ScopeId::world(), "a", ss::make_number(1), kHostPeer, false, nullptr, kInvalidPeer, out, &ev) ==
	    SetResult::Ok);
	CHECK_EQ(s.version_of(ScopeId::world(), "a"), uint64_t(1));
	CHECK(sn::host_set(s, ScopeId::object(5), "b", ss::make_number(2), 2, true, nullptr, kInvalidPeer, out) == SetResult::Ok);
	CHECK_EQ(s.version_of(ScopeId::object(5), "b"), uint64_t(2));
	CHECK(sn::host_set(s, ScopeId::world(), "a", ss::make_number(3), kHostPeer, false, nullptr, kInvalidPeer, out) ==
	    SetResult::Ok);
	CHECK_EQ(s.version_of(ScopeId::world(), "a"), uint64_t(3));
	CHECK_EQ(s.top_version(), uint64_t(3));

	// The host's own change: everybody hears of it; its event carries the old value.
	out.clear();
	CHECK(sn::host_set(s, ScopeId::world(), "a", ss::make_number(4), kHostPeer, false, nullptr, kInvalidPeer, out, &ev) ==
	    SetResult::Ok);
	REQUIRE(out.size() == 1);
	CHECK(out[0].to == sn::Delivery::Everyone && out[0].except == kInvalidPeer);
	CHECK(out[0].msg.has_change() && out[0].msg.version == 4u && out[0].msg.by == kHostPeer && out[0].msg.flags == 0);
	CHECK(ss::same(ev.old, ss::make_number(3)) && ss::same(ev.value, ss::make_number(4)) && ev.by == kHostPeer && ev.key == "a");

	// The counter stops below the ceiling: a store whose newest version is kMaxVersion takes no more.
	Store full;
	REQUIRE(full.set(ScopeId::world(), "x", ss::make_number(1), ss::kMaxVersion) == SetResult::Ok);
	out.clear();
	CHECK(sn::host_set(full, ScopeId::world(), "y", ss::make_number(1), kHostPeer, false, nullptr, kInvalidPeer, out) ==
	    SetResult::BadValue);
	CHECK(out.empty());
}

TEST(sync_net_host_routes_a_client_change)
{
	Store s;
	std::vector<sn::Delivery> out;
	const uint32_t seq = 41;

	// A client's change of a shared scope: the others get it, he gets it with the answer to his seq.
	CHECK(sn::host_set(s, ScopeId::object(9), "ammo", ss::make_number(30), 2, true, &seq, kInvalidPeer, out) ==
	    SetResult::Ok);
	REQUIRE(out.size() == 2);
	const sn::Delivery* all = to_all(out);
	const sn::Delivery* him = to_one(out, 2);
	REQUIRE(all && him);
	CHECK_EQ(all->except, PeerId(2));
	CHECK(all->msg.flags == 0 && all->msg.by == 2 && all->msg.has_change());
	CHECK(him->msg.flags == sn::kAck && him->msg.ack == seq && him->msg.has_change() && him->msg.version == all->msg.version);

	// The same value again: only his answer, nobody else hears of it.
	out.clear();
	CHECK(sn::host_set(s, ScopeId::object(9), "ammo", ss::make_number(30), 2, true, &seq, kInvalidPeer, out) ==
	    SetResult::Same);
	REQUIRE(out.size() == 1);
	CHECK(out[0].to == sn::Delivery::One && out[0].peer == 2 && out[0].msg.flags == sn::kAck && out[0].msg.has_change());

	// Not his object: refused, he alone is told, the store is as it was.
	out.clear();
	CHECK(sn::host_set(s, ScopeId::object(9), "ammo", ss::make_number(1), 3, false, &seq, kInvalidPeer, out) ==
	    SetResult::NotAllowed);
	REQUIRE(out.size() == 1);
	CHECK(out[0].peer == 3 && out[0].msg.flags == (sn::kAck | sn::kRefused) && out[0].msg.refused == SetResult::NotAllowed);
	CHECK(ss::same(value_of(s, ScopeId::object(9), "ammo"), ss::make_number(30)));
	// A client never writes World or Session, owner or not.
	out.clear();
	CHECK(sn::host_set(s, ScopeId::world(), "w", ss::make_number(1), 3, true, &seq, kInvalidPeer, out) ==
	    SetResult::NotAllowed);
	CHECK(s.get(ScopeId::world(), "w") == nullptr);
}

TEST(sync_net_player_scope_goes_to_its_player_only)
{
	// A player's own data goes to him alone, never to the other players.
	Store s;
	std::vector<sn::Delivery> out;
	const uint32_t seq = 1;
	const ScopeId p2 = ScopeId::player(digest(2));
	CHECK(sn::host_set(s, p2, "pda", ss::make_string("x"), 2, true, &seq, 2, out) == SetResult::Ok);
	REQUIRE(out.size() == 1);
	CHECK(out[0].to == sn::Delivery::One && out[0].peer == 2 && out[0].msg.flags == sn::kAck);

	// The host changes it: to him, without an answer.
	out.clear();
	CHECK(sn::host_set(s, p2, "pda", ss::make_string("y"), kHostPeer, false, nullptr, 2, out) == SetResult::Ok);
	REQUIRE(out.size() == 1);
	CHECK(out[0].to == sn::Delivery::One && out[0].peer == 2 && out[0].msg.flags == 0 && out[0].msg.by == kHostPeer);

	// He is away: kept for him, nobody hears of it.
	out.clear();
	CHECK(sn::host_set(s, p2, "pda", ss::make_string("z"), kHostPeer, false, nullptr, kInvalidPeer, out) == SetResult::Ok);
	CHECK(out.empty());

	// A full copy for another player has no trace of it; his own has.
	CHECK(!sn::goes_to(p2, digest(3)));
	CHECK(sn::goes_to(p2, digest(2)));
	CHECK(sn::goes_to(ScopeId::world(), digest(3)));
	CHECK(sn::goes_to(ScopeId::session(), digest(3)));
	CHECK(sn::goes_to(ScopeId::object(1), digest(3)));
}

TEST(sync_net_player_scope_of_a_character)
{
	// F3 keeps a player's checkpoint in his player scope (syncapi::player_get / player_set by character id): the scope
	// his own machine calls "player", by the key on the character's custom data, never by its id.
	const std::string d = digest(5);
	ScopeId s;
	REQUIRE(sn::player_scope_of("[coop]\nkey = " + d + "\nnick = Al\n", s));
	CHECK(s == ScopeId::player(d));
	// Another player's digest as a nick does not count; no key line: no player (an NPC); out untouched.
	REQUIRE(sn::player_scope_of("[coop]\nkey=" + d + "\nnick = " + digest(6) + "\n", s));
	CHECK(s == ScopeId::player(d));
	ScopeId kept = ScopeId::object(3);
	CHECK(!sn::player_scope_of("[coop]\nnick = Al\n", kept));
	CHECK(!sn::player_scope_of("", kept));
	CHECK(kept == ScopeId::object(3));
	// A save from before R1 I1 keeps the key itself: the scope is its digest, the one his machine knows.
	coop::PlayerKey key{};
	for (size_t i = 0; i < key.size(); ++i)
		key[i] = uint8_t(i * 5 + 3);
	std::string raw, mine;
	static const char* hex = "0123456789abcdef";
	for (uint8_t byte : key)
	{
		raw += hex[byte >> 4];
		raw += hex[byte & 15];
	}
	REQUIRE(coop::key_digest_hex(key, mine));
	REQUIRE(sn::player_scope_of("[coop]\nkey = " + raw + "\n", s));
	CHECK(s == ScopeId::player(mine));
}

TEST(sync_net_host_drop)
{
	// An object destroyed: its scope goes, and the clients drop theirs; a scope the host does not have sends nothing.
	Store s;
	std::vector<sn::Delivery> out;
	REQUIRE(sn::host_set(s, ScopeId::object(5), "a", ss::make_number(1), kHostPeer, false, nullptr, kInvalidPeer, out) ==
	    SetResult::Ok);
	out.clear();
	CHECK(sn::host_drop(s, ScopeId::object(5), out));
	CHECK(s.get(ScopeId::object(5), "a") == nullptr);
	REQUIRE(out.size() == 1);
	CHECK(out[0].to == sn::Delivery::Everyone && out[0].msg.flags == sn::kDrop && out[0].msg.scope == ScopeId::object(5));
	out.clear();
	CHECK(!sn::host_drop(s, ScopeId::object(5), out));
	CHECK(out.empty());
}

// ---------------------------------------------------------------- client: its own changes until the host answers

TEST(sync_net_client_shows_its_change_until_answered)
{
	sn::ClientCore c;
	const ScopeId obj = ScopeId::object(9);
	std::vector<sn::Change> ev;

	// The host's value, then our change: we show ours at once (get right after set), the store keeps the host's.
	sn::HostSet h;
	h.by = kHostPeer;
	h.scope = obj;
	h.key = "k";
	h.value = ss::make_number(1);
	h.version = 10;
	c.apply(h, ev);
	REQUIRE(ev.size() == 1);
	CHECK(ss::same(ev[0].value, ss::make_number(1)) && ev[0].old.type == ValueType::Nil && ev[0].by == kHostPeer);
	ev.clear();
	const uint32_t s1 = c.local_set(obj, "k", ss::make_number(2), 5, 1000, ev);
	CHECK(s1 != 0);
	CHECK(ss::same(c.shown(obj, "k"), ss::make_number(2)));
	CHECK(ss::same(value_of(c.store(), obj, "k"), ss::make_number(1)));
	REQUIRE(ev.size() == 1);
	CHECK(ss::same(ev[0].old, ss::make_number(1)) && ss::same(ev[0].value, ss::make_number(2)) && ev[0].by == 5);
	ev.clear();

	// A second change before the answer to the first: the first answer does not take the second away.
	const uint32_t s2 = c.local_set(obj, "k", ss::make_number(3), 5, 1001, ev);
	CHECK(s2 > s1);
	ev.clear();
	sn::HostSet a1 = h;
	a1.flags = sn::kAck;
	a1.by = 5;
	a1.ack = s1;
	a1.value = ss::make_number(2);
	a1.version = 11;
	c.apply(a1, ev);
	CHECK(ss::same(c.shown(obj, "k"), ss::make_number(3)));
	CHECK(ev.empty()); // nothing shown changed
	sn::HostSet a2 = a1;
	a2.ack = s2;
	a2.value = ss::make_number(3);
	a2.version = 12;
	c.apply(a2, ev);
	CHECK(ss::same(c.shown(obj, "k"), ss::make_number(3)));
	CHECK(ss::same(value_of(c.store(), obj, "k"), ss::make_number(3)));
	CHECK(ev.empty());
	CHECK_EQ(c.waiting(), size_t(0));

	// Refused: the shown value goes back to the host's, and that is a change.
	const uint32_t s3 = c.local_set(obj, "k", ss::make_number(4), 5, 1002, ev);
	ev.clear();
	sn::HostSet no;
	no.flags = sn::kAck | sn::kRefused;
	no.ack = s3;
	no.refused = SetResult::NotAllowed;
	c.apply(no, ev);
	CHECK(ss::same(c.shown(obj, "k"), ss::make_number(3)));
	REQUIRE(ev.size() == 1);
	CHECK(ss::same(ev[0].old, ss::make_number(4)) && ss::same(ev[0].value, ss::make_number(3)));
	CHECK_EQ(c.stats().refused, uint64_t(1));
}

TEST(sync_net_client_lost_and_late_answers)
{
	sn::ClientCore c;
	const ScopeId me = ScopeId::player(digest(1));
	std::vector<sn::Change> ev;
	const uint32_t a = c.local_set(me, "a", ss::make_number(1), 1, 0, ev);
	const uint32_t b = c.local_set(me, "b", ss::make_number(2), 1, 0, ev);
	(void)a;
	ev.clear();
	// The answer to b also answers a: the host takes them in order, an a it never answered was lost on the way.
	sn::HostSet ab;
	ab.flags = sn::kAck;
	ab.by = 1;
	ab.ack = b;
	ab.scope = me;
	ab.key = "b";
	ab.value = ss::make_number(2);
	ab.version = 3;
	c.apply(ab, ev);
	CHECK(c.shown(me, "a").type == ValueType::Nil); // a never reached the host
	CHECK(ss::same(c.shown(me, "b"), ss::make_number(2)));
	REQUIRE(ev.size() == 1);
	CHECK(ev[0].key == "a" && ss::same(ev[0].old, ss::make_number(1)) && ev[0].value.type == ValueType::Nil);
	CHECK_EQ(c.waiting(), size_t(0));

	// No answer within kAnswerTimeoutMs: the change is given up and the host's value shows again.
	ev.clear();
	c.local_set(me, "c", ss::make_string("x"), 1, 1000, ev);
	ev.clear();
	c.expire(1000 + sn::ClientView::kAnswerTimeoutMs - 1, ev);
	CHECK(ss::same(c.shown(me, "c"), ss::make_string("x")));
	c.expire(1000 + sn::ClientView::kAnswerTimeoutMs, ev);
	CHECK(c.shown(me, "c").type == ValueType::Nil);
	CHECK_EQ(ev.size(), size_t(1));
	CHECK_EQ(c.stats().expired, uint64_t(1));

	// Made while loading the world (minutes may pass): it waits from the moment the client is in.
	ev.clear();
	c.local_set(me, "d", ss::make_number(4), 1, 2000, ev);
	c.touch_all(500000);
	c.expire(500000 + sn::ClientView::kAnswerTimeoutMs - 1, ev);
	CHECK(ss::same(c.shown(me, "d"), ss::make_number(4)));
	c.expire(500000 + sn::ClientView::kAnswerTimeoutMs, ev);
	CHECK(c.shown(me, "d").type == ValueType::Nil);
}

TEST(sync_net_client_drop_and_full_copy)
{
	sn::ClientCore c;
	const ScopeId obj = ScopeId::object(3);
	std::vector<sn::Change> ev;
	sn::HostSet h;
	h.scope = obj;
	h.key = "a";
	h.value = ss::make_number(1);
	h.version = 1;
	c.apply(h, ev);
	h.key = "b";
	h.version = 2;
	c.apply(h, ev);
	c.local_set(obj, "c", ss::make_number(3), 1, 0, ev);
	ev.clear();

	// The host dropped the object: every key goes, ours waiting for an answer too, each one an event.
	sn::HostSet d;
	d.flags = sn::kDrop;
	d.scope = obj;
	c.apply(d, ev);
	CHECK(c.keys(obj, "").empty());
	CHECK_EQ(ev.size(), size_t(3));

	// A full copy replaces the store; a change still waiting keeps showing over it.
	Store host;
	REQUIRE(host.set(ScopeId::world(), "w", ss::make_number(7), 5) == SetResult::Ok);
	REQUIRE(host.set(ScopeId::player(digest(1)), "mine", ss::make_number(1), 6) == SetResult::Ok);
	REQUIRE(host.set(ScopeId::player(digest(2)), "his", ss::make_number(1), 7) == SetResult::Ok);
	REQUIRE(c.store().set(ScopeId::world(), "stale", ss::make_number(1), 1) == SetResult::Ok);
	c.local_set(ScopeId::world(), "x", ss::make_number(1), 1, 0, ev); // (a client never may: shown until refused)
	const std::vector<Writer> parts = sn::encode_full(host, digest(1), 16);
	REQUIRE(!parts.empty());
	for (const Writer& p : parts)
	{
		Reader r(p.ptr(), p.size());
		CHECK(c.apply_full(r));
	}
	CHECK(c.store().get(ScopeId::world(), "stale") == nullptr);
	CHECK(ss::same(value_of(c.store(), ScopeId::world(), "w"), ss::make_number(7)));
	CHECK(c.store().get(ScopeId::player(digest(1)), "mine") != nullptr);
	CHECK(c.store().get(ScopeId::player(digest(2)), "his") == nullptr);
	CHECK(ss::same(c.shown(ScopeId::world(), "x"), ss::make_number(1)));
	CHECK_EQ(c.store().top_version(), uint64_t(6)); // nothing of the other player's
}

TEST(sync_net_full_copy_parts)
{
	Store host;
	std::vector<sn::Delivery> out;
	REQUIRE(sn::host_set(host, ScopeId::world(), "w", ss::make_string(std::string(3000, 'w')), kHostPeer, false, nullptr,
	            kInvalidPeer, out) == SetResult::Ok);
	REQUIRE(sn::host_set(host, ScopeId::session(), "s", ss::make_number(1), kHostPeer, false, nullptr, kInvalidPeer, out) ==
	    SetResult::Ok);
	for (uint32_t id = 1; id <= 40; ++id)
		REQUIRE(sn::host_set(host, ScopeId::object(id), "k", ss::make_string(std::string(200, 'o')), kHostPeer, false, nullptr,
		            kInvalidPeer, out) == SetResult::Ok);
	REQUIRE(sn::host_set(host, ScopeId::player(digest(1)), "p", ss::make_number(1), kHostPeer, false, nullptr, kInvalidPeer,
	            out) == SetResult::Ok);
	REQUIRE(sn::host_set(host, ScopeId::player(digest(2)), "p", ss::make_number(2), kHostPeer, false, nullptr, kInvalidPeer,
	            out) == SetResult::Ok);
	// A freed scope (its last key removed) keeps a removal record on the host: it does not travel in the copy.
	REQUIRE(sn::host_set(host, ScopeId::object(99), "gone", ss::make_number(1), kHostPeer, false, nullptr, kInvalidPeer,
	            out) == SetResult::Ok);
	REQUIRE(sn::host_set(host, ScopeId::object(99), "gone", Value(), kHostPeer, false, nullptr, kInvalidPeer, out) ==
	    SetResult::Ok);

	const std::vector<Writer> parts = sn::encode_full(host, digest(1), 2048);
	REQUIRE(parts.size() > 2);
	size_t scopes = 0;
	for (size_t i = 0; i < parts.size(); ++i)
	{
		Reader r(parts[i].ptr(), parts[i].size());
		const uint8_t flags = r.u8();
		CHECK_EQ((flags & sn::kFirst) != 0, i == 0);
		CHECK_EQ((flags & sn::kLast) != 0, i + 1 == parts.size());
		scopes += size_t(r.varu());
		CHECK(parts[i].size() <= 2048 + 4000); // a part ends after the scope that crossed the size
	}
	CHECK_EQ(scopes, size_t(1 + 1 + 40 + 1)); // world, session, 40 objects, his own player; no freed scope

	// Applied on a client with anything in it: exactly what goes to that player.
	Store client;
	REQUIRE(client.set(ScopeId::object(500), "old", ss::make_number(1), 1) == SetResult::Ok);
	for (const Writer& p : parts)
	{
		Reader r(p.ptr(), p.size());
		bool last = false;
		CHECK(sn::apply_full(client, r, last));
	}
	CHECK(dump(client) == dump(host, [](const ScopeId& s) { return s.kind != ScopeId::Player || s.player_key == digest(1); }));

	// An empty store is one part, first and last.
	Store none;
	const std::vector<Writer> one = sn::encode_full(none, digest(1), 2048);
	REQUIRE(one.size() == 1);
	Reader r1(one[0].ptr(), one[0].size());
	CHECK_EQ(r1.u8(), uint8_t(sn::kFirst | sn::kLast));
	CHECK_EQ(r1.varu(), uint64_t(0));

	// A malformed part is refused (cut short, unknown flags).
	std::vector<uint8_t> b(parts[1].ptr(), parts[1].ptr() + parts[1].size());
	b.resize(b.size() - 1);
	Reader rb(b.data(), b.size());
	bool last = false;
	CHECK(!sn::apply_full(client, rb, last));
	Writer bad;
	bad.u8(8);
	bad.varu(0);
	Reader rf(bad.ptr(), bad.size());
	CHECK(!sn::apply_full(client, rf, last));
}

TEST(sync_net_client_view_bounds)
{
	sn::ClientCore c;
	std::vector<sn::Change> ev;
	for (size_t i = 0; i < sn::ClientView::kMaxPending; ++i)
		CHECK(c.local_set(ScopeId::object(1), "k" + std::to_string(i % 10), ss::make_number(double(i)), 1, 0, ev) != 0);
	CHECK(c.full());
	CHECK_EQ(c.local_set(ScopeId::object(1), "k", ss::make_number(1), 1, 0, ev), 0u); // refused, nothing changes
	CHECK_EQ(c.waiting(), sn::ClientView::kMaxPending);
	c.clear();
	CHECK_EQ(c.waiting(), size_t(0));
	CHECK(!c.full());
}

// ---------------------------------------------------------------- host: request limits, client: requests in flight

TEST(sync_net_request_limits)
{
	sn::RequestLimits l;
	// Default: 20 in a row per (player, name), then 10 per second.
	for (int i = 0; i < 20; ++i)
		CHECK(l.allow(2, "a", 1000));
	CHECK(!l.allow(2, "a", 1000));
	CHECK(l.allow(3, "a", 1000)); // another player
	CHECK(l.allow(2, "b", 1000)); // another name
	CHECK(!l.allow(2, "a", 1099));
	CHECK(l.allow(2, "a", 1100));
	CHECK(!l.allow(2, "a", 1100));

	// coop.sync.limit(name, burst, per_sec): checked, bounded.
	CHECK(l.set_rule("slow", 2, 0.5));
	CHECK(l.allow(2, "slow", 0));
	CHECK(l.allow(2, "slow", 0));
	CHECK(!l.allow(2, "slow", 1999));
	CHECK(l.allow(2, "slow", 2000));
	CHECK(!l.set_rule("x", 0, 1));
	CHECK(!l.set_rule("x", 1, 0));
	CHECK(!l.set_rule("x", sn::RequestLimits::kMaxBurst + 1, 1));
	CHECK(!l.set_rule("x", 1, sn::RequestLimits::kMaxPerSec + 1));
	CHECK(!l.set_rule("x", 1, std::numeric_limits<double>::quiet_NaN()));
	CHECK(!l.set_rule("bad name", 1, 1));
	for (size_t i = 1; i < sn::RequestLimits::kMaxRules; ++i)
		CHECK(l.set_rule("r" + std::to_string(i), 1, 1));
	CHECK(!l.set_rule("one.more", 1, 1));
	CHECK(l.set_rule("slow", 5, 5)); // a known name changes

	// A player who left starts again full.
	for (int i = 0; i < 20; ++i)
		l.allow(4, "a", 0);
	CHECK(!l.allow(4, "a", 0));
	l.forget_peer(4);
	CHECK(l.allow(4, "a", 0));
}

TEST(sync_net_requests_in_flight)
{
	sn::Requests<int> q;
	const uint32_t a = q.add(1000, 11);
	const uint32_t b = q.add(1500, 22);
	CHECK(a != 0 && b != 0 && a != b);
	int payload = 0;
	CHECK(q.take(b, payload));
	CHECK_EQ(payload, 22);
	CHECK(!q.take(b, payload)); // answered once
	CHECK(!q.take(12345, payload));
	CHECK(q.expire(1000 + sn::kRequestTimeoutMs - 1).empty());
	// Made while the client loaded the world: they wait from the moment it is in.
	sn::Requests<int> loading;
	const uint32_t l1 = loading.add(0, 1);
	loading.touch_all(50000);
	CHECK(loading.expire(50000 + sn::kRequestTimeoutMs - 1).empty());
	CHECK_EQ(loading.expire(50000 + sn::kRequestTimeoutMs).size(), size_t(1));
	CHECK(l1 != 0);

	const auto gone = q.expire(1000 + sn::kRequestTimeoutMs);
	REQUIRE(gone.size() == 1);
	CHECK(gone[0].first == a && gone[0].second == 11);
	for (size_t i = 0; i < sn::Requests<int>::kMax; ++i)
		CHECK(q.add(0, int(i)) != 0);
	CHECK(q.full());
	CHECK_EQ(q.add(0, 1), 0u);
	q.clear();
	CHECK_EQ(q.size(), size_t(0));
}

// ---------------------------------------------------------------- the client's pacing (Ruling F2-14)

namespace
{
// The host's token bucket as Session::within_rate keeps it, fed with arrival times.
struct HostBucket
{
	double burst, refill;
	bool started = false;
	double tokens = 0;
	uint64_t at = 0;
	bool take(uint64_t now)
	{
		if (!started)
		{
			started = true;
			tokens = burst;
			at = now;
		}
		else if (now > at)
		{
			tokens = std::min(burst, tokens + double(now - at) / refill);
			at = now;
		}
		if (tokens < 1.)
			return false;
		tokens -= 1.;
		return true;
	}
};
} // namespace

TEST(limits_pacer_holds_back_what_the_host_would_drop)
{
	for (const coop::limits::RateRule& rule : coop::limits::kClientRateRules)
	{
		coop::limits::Pacer p;
		// A burst far over the host's: the pacer lets half the host's burst go at once, holds the rest.
		uint32_t went = 0;
		for (uint32_t i = 0; i < rule.burst * 4; ++i)
			went += p.take(rule.type, 1000) ? 1 : 0;
		const coop::limits::Pace pace = coop::limits::client_pace(rule);
		CHECK_EQ(went, pace.burst);
		CHECK(pace.burst >= 1 && pace.burst <= rule.burst);
		CHECK(pace.interval_ms > rule.refill_ms);

		// An honest stream that wants out every millisecond for 20 s, paced, reaches the host after a lag spike of 300 ms
		// on top of 0..60 ms of jitter (in order: ENet's reliable lane): the host drops nothing.
		coop::limits::Pacer q;
		HostBucket host{double(rule.burst), double(rule.refill_ms)};
		uint64_t last_arrival = 0;
		uint32_t sent = 0, dropped = 0;
		uint64_t seed = 12345;
		for (uint64_t now = 0; now < 20000; ++now)
		{
			if (!q.take(rule.type, now))
				continue;
			seed = seed * 6364136223846793005ull + 1442695040888963407ull;
			uint64_t arrival = now + 10 + (seed >> 33) % 60;
			if (now >= 5000 && now < 5300)
				arrival = 5300 + 10; // a stall: everything sent in it arrives at once
			last_arrival = std::max(last_arrival, arrival);
			++sent;
			if (!host.take(last_arrival))
				++dropped;
		}
		CHECK(sent > 0);
		CHECK_EQ(std::string(coop::msg_name(rule.type)) + " dropped " + std::to_string(dropped),
		    std::string(coop::msg_name(rule.type)) + " dropped 0");
	}
	// A message the host does not limit always goes.
	coop::limits::Pacer p;
	for (int i = 0; i < 1000; ++i)
		CHECK(p.take(Msg::PlayerState, 0));
	CHECK(coop::limits::client_rule(Msg::PlayerState) == nullptr);
	CHECK(coop::limits::client_rule(Msg::ScriptEvent) != nullptr);
}
