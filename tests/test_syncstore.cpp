// Anomaly Coop unit tests: the coop.sync store (coop_syncstore.h; F2 T13, SYNC_SPEC §6.1, §6.5): scopes, the value
// format on the wire, limits, versions, full copies.
#include "test_util.h"

#include "coop_session.h" // kKeyDigestHexDigits
#include "coop_syncstore.h"

#include <cstdint>
#include <limits>
#include <string>
#include <utility>
#include <vector>

using coop::Reader;
using coop::Writer;
namespace ss = coop::syncstore;
using ss::ScopeId;
using ss::SetResult;
using ss::Store;
using ss::Value;
using ss::ValueType;

static_assert(ss::kPlayerKeyDigits == coop::kKeyDigestHexDigits, "a Player scope is keyed by the player key digest");

namespace
{
std::vector<uint8_t> bytes_of(const Writer& w) { return std::vector<uint8_t>(w.ptr(), w.ptr() + w.size()); }

// A player key digest as ledger::character_key gives it: 64 lowercase hex digits; `n` makes it unique.
std::string digest(uint32_t n)
{
	static const char* hex = "0123456789abcdef";
	std::string d(ss::kPlayerKeyDigits, 'a');
	for (size_t i = 0; i < 8; ++i)
		d[d.size() - 1 - i] = hex[(n >> (4 * i)) & 15];
	return d;
}

// A string value whose encoded size is exactly `encoded` (type byte, 2-byte length, the bytes).
Value sized_string(size_t encoded)
{
	const size_t len = encoded - 3;
	REQUIRE(ss::varu_size(len) == 2);
	Value v = ss::make_string(std::string(len, 's'));
	REQUIRE(ss::encoded_size(v) == encoded);
	return v;
}

// Everything a store holds, as bytes: its scopes in order, each as its full copy.
std::vector<uint8_t> dump(const Store& s)
{
	Writer w;
	for (const ScopeId& id : s.scopes())
		s.encode_scope(w, id);
	return bytes_of(w);
}

// read_set of what write_set wrote; false if refused.
bool wire_set(const ScopeId& scope, const std::string& key, const Value& value, uint64_t version)
{
	Writer w;
	ss::write_set(w, scope, key, value, version);
	const std::vector<uint8_t> b = bytes_of(w);
	Reader r(b.data(), b.size());
	ScopeId s;
	std::string k;
	Value v;
	uint64_t ver = 0;
	return ss::read_set(r, s, k, v, ver);
}

uint64_t results(const Store& s, SetResult r) { return s.stats().results[size_t(r)]; }

void write_key(Writer& w, const std::string& key)
{
	w.varu(key.size());
	w.bytes(key.data(), key.size());
}
} // namespace

TEST(sync_store_roundtrip_types)
{
	struct Case
	{
		ScopeId scope;
		std::string key;
		Value value;
		uint64_t version;
	};
	const std::vector<Case> cases = {
		{ScopeId::world(), "nil", ss::make_nil(), 1},
		{ScopeId::session(), "num", ss::make_number(-12.5), 2},
		{ScopeId::player(digest(7)), "str", ss::make_string(std::string("a\0b", 3)), 3},
		{ScopeId::object(65534), "bool", ss::make_bool(true), 4},
		{ScopeId::object(1), "vec", ss::make_vec3(1.f, -2.f, 3.5f), 0xFFFFFFFFFFull},
		{ScopeId::world(), "tbl",
		    ss::make_table({{"", ss::make_bool(false)}, {"n", ss::make_number(1e300)}, {"s", ss::make_string("x")},
		        {"v", ss::make_vec3(0.f, 0.f, -1.f)}}),
		    6},
	};
	bool seen[ss::kValueTypeCount] = {};
	for (const Case& c : cases)
	{
		seen[size_t(c.value.type)] = true;
		Writer vw;
		ss::write_value(vw, c.value);
		CHECK_EQ(vw.size(), ss::encoded_size(c.value));

		Writer w;
		ss::write_set(w, c.scope, c.key, c.value, c.version);
		const std::vector<uint8_t> b = bytes_of(w);
		Reader r(b.data(), b.size());
		ScopeId scope;
		std::string key;
		Value value;
		uint64_t version = 0;
		REQUIRE(ss::read_set(r, scope, key, value, version));
		CHECK(scope == c.scope);
		CHECK_EQ(key, c.key);
		CHECK(value.type == c.value.type);
		CHECK(ss::same(value, c.value));
		CHECK_EQ(version, c.version);
		CHECK_EQ(r.remaining(), size_t(0));
	}
	for (bool s : seen)
		CHECK(s);
}

TEST(sync_store_rejects_nan)
{
	const double nan = std::numeric_limits<double>::quiet_NaN();
	const double inf = std::numeric_limits<double>::infinity();
	const float fnan = std::numeric_limits<float>::quiet_NaN();
	const float finf = std::numeric_limits<float>::infinity();
	const std::vector<Value> bad = {
		ss::make_number(nan),
		ss::make_number(inf),
		ss::make_number(-inf),
		ss::make_vec3(fnan, 0.f, 0.f),
		ss::make_vec3(0.f, finf, 0.f),
		ss::make_table({{"x", ss::make_number(nan)}}),
		ss::make_table({{"v", ss::make_vec3(0.f, 0.f, -finf)}}),
	};
	Store s;
	const ScopeId w = ScopeId::world();
	uint64_t version = 1;
	for (const Value& v : bad)
	{
		CHECK(s.set(w, "k", v, version++) == SetResult::BadValue);
		CHECK(!wire_set(w, "k", v, 1));
		Writer vw;
		ss::write_value(vw, v);
		const std::vector<uint8_t> b = bytes_of(vw);
		Reader r(b.data(), b.size());
		Value out = ss::make_number(3);
		CHECK(!ss::read_value(r, out));
		CHECK(out.type == ValueType::Number && out.num == 3); // a refusal leaves the output alone
	}
	CHECK(s.get(w, "k") == nullptr);
	CHECK_EQ(s.bytes(w), size_t(0));
	CHECK(s.scopes().empty());
	CHECK_EQ(results(s, SetResult::BadValue), uint64_t(bad.size()));
}

TEST(sync_store_key_limit)
{
	Store s;
	const ScopeId w = ScopeId::world();
	const std::string at(ss::kMaxKey, 'k');
	const std::string over(ss::kMaxKey + 1, 'k');
	CHECK_EQ(at.size(), size_t(128));
	CHECK(s.set(w, at, ss::make_number(1), 1) == SetResult::Ok);
	CHECK(s.set(w, over, ss::make_number(1), 2) == SetResult::BadKey);
	CHECK(s.set(w, "", ss::make_number(1), 3) == SetResult::BadKey);
	CHECK(s.get(w, at) != nullptr);
	CHECK(s.get(w, over) == nullptr);
	CHECK_EQ(results(s, SetResult::BadKey), uint64_t(2));
	CHECK(wire_set(w, at, ss::make_number(1), 1));
	CHECK(!wire_set(w, over, ss::make_number(1), 1));
	CHECK(!wire_set(w, "", ss::make_number(1), 1));
	// the keys of a table have the same limit (an empty one is a valid Lua key)
	CHECK(s.set(w, "t", ss::make_table({{at, ss::make_bool(true)}, {"", ss::make_bool(true)}}), 4) == SetResult::Ok);
	CHECK(s.set(w, "t2", ss::make_table({{over, ss::make_bool(true)}}), 5) == SetResult::BadValue);
	CHECK(!wire_set(w, "t2", ss::make_table({{over, ss::make_bool(true)}}), 5));
}

TEST(sync_store_value_limit)
{
	Store s;
	const ScopeId w = ScopeId::world();
	const Value at = sized_string(ss::kMaxValueBytes);
	const Value over = sized_string(ss::kMaxValueBytes + 1);
	CHECK_EQ(ss::encoded_size(at), size_t(16384));
	CHECK(s.set(w, "at", at, 1) == SetResult::Ok);
	CHECK(s.set(w, "over", over, 2) == SetResult::TooBig);
	CHECK(s.get(w, "over") == nullptr);
	CHECK(wire_set(w, "at", at, 1));
	CHECK(!wire_set(w, "over", over, 2));

	// a table over the limit: 7 bytes of framing around one string field
	Value table_over = ss::make_table({{"s", ss::make_string(std::string(ss::kMaxValueBytes + 1 - 7, 't'))}});
	CHECK_EQ(ss::encoded_size(table_over), ss::kMaxValueBytes + 1);
	CHECK(s.set(w, "tbl", table_over, 3) == SetResult::TooBig);
	CHECK(!wire_set(w, "tbl", table_over, 3));
	table_over.table[0].second.str.pop_back();
	CHECK(s.set(w, "tbl", table_over, 4) == SetResult::Ok);
	CHECK_EQ(results(s, SetResult::TooBig), uint64_t(2));

	// lengths on the wire that promise more than the limit are refused before anything is allocated
	for (const uint8_t type : {uint8_t(ValueType::String), uint8_t(ValueType::Table)})
	{
		Writer bw;
		ss::write_scope(bw, w);
		write_key(bw, "k");
		bw.u64(1);
		bw.u8(type);
		bw.varu(uint64_t(1) << 40);
		const std::vector<uint8_t> b = bytes_of(bw);
		Reader r(b.data(), b.size());
		ScopeId scope;
		std::string key;
		Value value;
		uint64_t version = 0;
		CHECK(!ss::read_set(r, scope, key, value, version));
	}
}

TEST(sync_store_scope_full)
{
	Store s;
	const ScopeId obj = ScopeId::object(42);
	const Value kib = ss::make_string(std::string(1024, 'x'));
	size_t accepted = 0;
	SetResult last = SetResult::Ok;
	std::string rejected;
	for (uint32_t i = 0; i < 1000; ++i)
	{
		const std::string key = "k" + std::to_string(i);
		last = s.set(obj, key, kib, i + 1);
		if (last != SetResult::Ok)
		{
			rejected = key;
			break;
		}
		++accepted;
	}
	CHECK(last == SetResult::ScopeFull);
	CHECK(accepted > 0);
	CHECK(s.bytes(obj) <= ss::kMaxObjectBytes);
	CHECK(s.bytes(obj) + ss::entry_bytes(rejected, kib) > ss::kMaxObjectBytes);
	CHECK(s.get(obj, rejected) == nullptr);
	CHECK_EQ(s.keys(obj, "").size(), accepted);
	CHECK_EQ(s.stats().full_scope, uint64_t(1));
	CHECK_EQ(results(s, SetResult::ScopeFull), uint64_t(1));
	// the scope's size is the sum of its entries
	size_t sum = 0;
	for (const auto& kv : s.keys(obj, ""))
		sum += ss::entry_bytes(kv.first, *kv.second);
	CHECK_EQ(sum, s.bytes(obj));
	// a smaller value in place of a bigger one fits; another object has its own room
	CHECK(s.set(obj, "k0", ss::make_bool(true), 5000) == SetResult::Ok);
	CHECK(s.set(obj, rejected, kib, 5001) == SetResult::Ok);
	CHECK(s.set(ScopeId::object(43), "k0", kib, 1) == SetResult::Ok);

	// a scope filled to exactly its limit takes the last entry; one byte more does not fit
	Store exact;
	const ScopeId e = ScopeId::object(44);
	const Value max_value = sized_string(ss::kMaxValueBytes);
	for (const char* key : {"a", "b", "c"})
		REQUIRE(exact.set(e, key, max_value, 1) == SetResult::Ok);
	const size_t room = ss::kMaxObjectBytes - exact.bytes(e);
	const size_t fixed = ss::entry_bytes("d", ss::make_string("")) - ss::encoded_size(ss::make_string(""));
	const Value last_fit = sized_string(room - fixed);
	CHECK_EQ(ss::entry_bytes("d", last_fit), room);
	const Value one_more = sized_string(room - fixed + 1);
	CHECK(exact.set(e, "d", one_more, 1) == SetResult::ScopeFull);
	CHECK(exact.set(e, "d", last_fit, 1) == SetResult::Ok);
	CHECK_EQ(exact.bytes(e), ss::kMaxObjectBytes);
	CHECK(exact.set(e, "e", ss::make_bool(true), 1) == SetResult::ScopeFull);
}

TEST(sync_store_permissions)
{
	// World and Session: only the host
	CHECK(!ss::may_set(ScopeId::World, false, false));
	CHECK(!ss::may_set(ScopeId::World, false, true));
	CHECK(ss::may_set(ScopeId::World, true, false));
	CHECK(!ss::may_set(ScopeId::Session, false, false));
	CHECK(!ss::may_set(ScopeId::Session, false, true));
	CHECK(ss::may_set(ScopeId::Session, true, false));
	// Player: his own player or the host, not another player
	CHECK(!ss::may_set(ScopeId::Player, false, false));
	CHECK(ss::may_set(ScopeId::Player, false, true));
	CHECK(ss::may_set(ScopeId::Player, true, false));
	// Object: the host or the owner
	CHECK(!ss::may_set(ScopeId::Object, false, false));
	CHECK(ss::may_set(ScopeId::Object, false, true));
	CHECK(ss::may_set(ScopeId::Object, true, false));
	CHECK(!ss::may_set(ScopeId::Kind(9), true, true));

	Store s;
	const ScopeId p = ScopeId::player(digest(1));
	CHECK(s.set_by(ScopeId::world(), "w", ss::make_number(1), 1, false, false) == SetResult::NotAllowed);
	CHECK(s.set_by(p, "p", ss::make_number(1), 1, false, false) == SetResult::NotAllowed);
	CHECK(s.get(ScopeId::world(), "w") == nullptr);
	CHECK(s.get(p, "p") == nullptr);
	CHECK(s.set_by(p, "p", ss::make_number(1), 1, false, true) == SetResult::Ok);
	CHECK(s.set_by(ScopeId::world(), "w", ss::make_number(1), 1, true, false) == SetResult::Ok);
	CHECK_EQ(results(s, SetResult::NotAllowed), uint64_t(2));
}

TEST(sync_store_versions)
{
	Store s;
	const ScopeId w = ScopeId::world();
	CHECK(s.set(w, "k", ss::make_number(5), 5) == SetResult::Ok);
	CHECK(s.set(w, "k", ss::make_number(4), 4) == SetResult::Stale);
	REQUIRE(s.get(w, "k") != nullptr);
	CHECK_EQ(s.get(w, "k")->num, 5.0);
	CHECK_EQ(s.version_of(w, "k"), uint64_t(5));
	CHECK(s.set(w, "k", ss::make_number(6), 5) == SetResult::Stale); // the same version is not newer
	CHECK(s.set(w, "k", ss::make_number(5), 6) == SetResult::Same); // newer, same value: only the version moves
	CHECK_EQ(s.version_of(w, "k"), uint64_t(6));
	CHECK(s.set(w, "k", ss::make_number(7), 6) == SetResult::Stale);
	CHECK(s.set(w, "k", ss::make_number(7), 7) == SetResult::Ok);
	CHECK_EQ(s.get(w, "k")->num, 7.0);
	CHECK(s.set(w, "fresh", ss::make_number(1), 0) == SetResult::Stale); // versions start at 1
	CHECK_EQ(s.top_version(), uint64_t(7));

	// nil removes the key; a change older than the removal does not bring it back
	CHECK(s.set(w, "k", ss::make_nil(), 9) == SetResult::Ok);
	CHECK(s.get(w, "k") == nullptr);
	CHECK_EQ(s.bytes(w), size_t(0));
	CHECK(s.set(w, "k", ss::make_number(8), 8) == SetResult::Stale);
	CHECK(s.set(w, "k", ss::make_nil(), 10) == SetResult::Same); // removing a missing key changes nothing
	CHECK(s.set(w, "k", ss::make_number(11), 11) == SetResult::Ok);
	CHECK_EQ(s.top_version(), uint64_t(11));
	CHECK_EQ(results(s, SetResult::Stale), uint64_t(5));
	CHECK_EQ(results(s, SetResult::Same), uint64_t(2));
}

TEST(sync_store_nested_table_refused)
{
	Store s;
	const ScopeId w = ScopeId::world();
	Value nested = ss::make_table({{"t", ss::make_table({{"a", ss::make_number(1)}})}});
	CHECK(s.set(w, "k", nested, 1) == SetResult::BadValue);
	CHECK(!wire_set(w, "k", nested, 1));
	// no nil in a table, no repeated key, no unknown type
	const Value nil_field = ss::make_table({{"n", ss::make_nil()}});
	CHECK(s.set(w, "k", nil_field, 2) == SetResult::BadValue);
	CHECK(!wire_set(w, "k", nil_field, 2));
	const Value repeated = ss::make_table({{"a", ss::make_number(1)}, {"a", ss::make_number(2)}});
	CHECK(s.set(w, "k", repeated, 3) == SetResult::BadValue);
	CHECK(!wire_set(w, "k", repeated, 3));
	Value unknown;
	unknown.type = ValueType(ss::kValueTypeCount);
	CHECK(s.set(w, "k", unknown, 4) == SetResult::BadValue);
	CHECK(!wire_set(w, "k", unknown, 4));
	CHECK(s.get(w, "k") == nullptr);
	CHECK(s.scopes().empty());

	// a bool is 0 or 1 on the wire
	Writer bw;
	ss::write_set(bw, w, "b", ss::make_bool(true), 1);
	std::vector<uint8_t> b = bytes_of(bw);
	b.back() = 2;
	Reader r(b.data(), b.size());
	ScopeId scope;
	std::string key;
	Value value;
	uint64_t version = 0;
	CHECK(!ss::read_set(r, scope, key, value, version));
}

// Review Focus 2: after a save/load of the host or a reconnect the client drops what it had and takes the host's full
// copy: exactly the copy, nothing left of before, and no older change undoes it.
TEST(sync_store_full_replaces_after_reset)
{
	const ScopeId w = ScopeId::world();
	const ScopeId pa = ScopeId::player(digest(1));
	const ScopeId obj = ScopeId::object(7);
	Store host;
	CHECK(host.set(w, "a", ss::make_number(1), 1) == SetResult::Ok);
	CHECK(host.set(w, "b", ss::make_string("x"), 2) == SetResult::Ok);
	CHECK(host.set(w, "gone", ss::make_bool(true), 3) == SetResult::Ok);
	CHECK(host.set(w, "gone", ss::make_nil(), 4) == SetResult::Ok);
	CHECK(host.set(pa, "money", ss::make_number(500), 5) == SetResult::Ok);
	CHECK(host.set(obj, "charge", ss::make_vec3(1.f, 2.f, 3.f), 6) == SetResult::Ok);
	CHECK(host.set(ScopeId::session(), "set/x", ss::make_table({{"on", ss::make_bool(true)}}), 7) == SetResult::Ok);

	// what the client held before: other values, keys and a scope the copy does not have
	Store client;
	CHECK(client.set(w, "a", ss::make_number(99), 50) == SetResult::Ok);
	CHECK(client.set(w, "stale", ss::make_bool(true), 51) == SetResult::Ok);
	CHECK(client.set(ScopeId::object(9), "x", ss::make_number(1), 52) == SetResult::Ok);
	CHECK(client.set(pa, "money", ss::make_number(1), 53) == SetResult::Ok);

	client.clear();
	CHECK(client.scopes().empty());
	CHECK_EQ(client.pool_bytes(), size_t(0));
	for (const ScopeId& id : host.scopes())
	{
		Writer cw;
		host.encode_scope(cw, id);
		const std::vector<uint8_t> b = bytes_of(cw);
		Reader r(b.data(), b.size());
		ScopeId got;
		REQUIRE(client.decode_scope(r, got));
		CHECK(got == id);
		CHECK_EQ(r.remaining(), size_t(0));
	}
	CHECK(client.scopes() == host.scopes());
	CHECK(dump(client) == dump(host));
	CHECK(client.get(w, "stale") == nullptr);
	CHECK(client.get(ScopeId::object(9), "x") == nullptr);
	REQUIRE(client.get(pa, "money") != nullptr);
	CHECK_EQ(client.get(pa, "money")->num, 500.0);
	CHECK_EQ(client.bytes(w), host.bytes(w));
	CHECK_EQ(client.pool_bytes(), host.pool_bytes());
	CHECK_EQ(client.version_of(pa, "money"), uint64_t(5));
	CHECK_EQ(client.stats().decoded, uint64_t(host.scopes().size()));

	// changes from before the copy do not undo it (a key it removed stays out)
	CHECK(client.set(w, "a", ss::make_number(2), 1) == SetResult::Stale);
	CHECK(client.set(w, "gone", ss::make_bool(true), 3) == SetResult::Stale);
	CHECK(dump(client) == dump(host));

	// one scope dropped and taken again alone: exactly the copy
	Writer ww;
	host.encode_scope(ww, w);
	const std::vector<uint8_t> world_copy = bytes_of(ww);
	CHECK(client.set(w, "extra", ss::make_number(3), 100) == SetResult::Ok);
	client.drop(w);
	CHECK(client.get(w, "a") == nullptr);
	CHECK_EQ(client.bytes(w), size_t(0));
	{
		Reader r(world_copy.data(), world_copy.size());
		ScopeId got;
		REQUIRE(client.decode_scope(r, got));
	}
	CHECK(dump(client) == dump(host));
	// a copy taken over a scope that is still there replaces it whole: no merge
	CHECK(client.set(w, "extra", ss::make_number(3), 101) == SetResult::Ok);
	{
		Reader r(world_copy.data(), world_copy.size());
		ScopeId got;
		REQUIRE(client.decode_scope(r, got));
	}
	CHECK(client.get(w, "extra") == nullptr);
	CHECK(dump(client) == dump(host));

	// the copy of a scope the host does not have removes it
	Writer ew;
	host.encode_scope(ew, ScopeId::object(9));
	CHECK(client.set(ScopeId::object(9), "x", ss::make_number(1), 1) == SetResult::Ok);
	{
		const std::vector<uint8_t> b = bytes_of(ew);
		Reader r(b.data(), b.size());
		ScopeId got;
		REQUIRE(client.decode_scope(r, got));
		CHECK(got == ScopeId::object(9));
	}
	CHECK(dump(client) == dump(host));
}

TEST(sync_store_truncated)
{
	Writer w;
	const Value table = ss::make_table({{"a", ss::make_number(1)}, {"b", ss::make_string("bee")}});
	ss::write_set(w, ScopeId::player(digest(3)), "key", table, 9);
	const std::vector<uint8_t> full = bytes_of(w);
	{
		Reader r(full.data(), full.size());
		ScopeId s;
		std::string k;
		Value v;
		uint64_t ver = 0;
		REQUIRE(ss::read_set(r, s, k, v, ver));
	}
	for (size_t n = 0; n < full.size(); ++n)
	{
		Reader r(full.data(), n);
		ScopeId s = ScopeId::object(77);
		std::string k = "keep";
		Value v = ss::make_number(1);
		uint64_t ver = 123;
		CHECK(!ss::read_set(r, s, k, v, ver));
		CHECK(s == ScopeId::object(77)); // a refusal leaves the outputs alone
		CHECK_EQ(k, std::string("keep"));
		CHECK(v.type == ValueType::Number && v.num == 1);
		CHECK_EQ(ver, uint64_t(123));
	}

	// a full copy cut short: refused, the store as it was
	Store host;
	CHECK(host.set(ScopeId::world(), "a", ss::make_number(1), 1) == SetResult::Ok);
	CHECK(host.set(ScopeId::world(), "b", table, 2) == SetResult::Ok);
	CHECK(host.set(ScopeId::world(), "c", ss::make_nil(), 3) == SetResult::Same);
	Writer cw;
	host.encode_scope(cw, ScopeId::world());
	const std::vector<uint8_t> copy = bytes_of(cw);
	Store client;
	CHECK(client.set(ScopeId::world(), "mine", ss::make_number(1), 1) == SetResult::Ok);
	const std::vector<uint8_t> before = dump(client);
	for (size_t n = 0; n < copy.size(); ++n)
	{
		Reader r(copy.data(), n);
		ScopeId got = ScopeId::session();
		CHECK(!client.decode_scope(r, got));
		CHECK(got == ScopeId::session());
		CHECK(dump(client) == before);
	}
	CHECK_EQ(client.stats().decode_bad, uint64_t(copy.size()));
	CHECK_EQ(client.stats().decoded, uint64_t(0));
}

// The lesson of F2-13 / F2-18: a player's data is keyed by his player key digest (ledger::character_key), not by a peer
// id or an entity id, which change on a reconnect or across saves.
TEST(sync_store_player_scope_by_key_digest)
{
	Store s;
	const ScopeId a = ScopeId::player(digest(1));
	const ScopeId b = ScopeId::player(digest(2));
	CHECK(s.set(a, "k", ss::make_number(1), 1) == SetResult::Ok);
	CHECK(s.set(b, "k", ss::make_number(2), 1) == SetResult::Ok);
	CHECK_EQ(s.get(a, "k")->num, 1.0);
	CHECK_EQ(s.get(b, "k")->num, 2.0);
	CHECK(s.get(ScopeId::player(digest(1)), "k") != nullptr);
	// a real digest, as the host keeps it in the character's custom data
	std::string real;
	REQUIRE(coop::key_digest_hex(coop::generate_player_key(), real));
	CHECK(ss::scope_ok(ScopeId::player(real)));

	// not a key digest: refused here and on the wire
	std::vector<ScopeId> bad_key;
	ScopeId x = a;
	x.player_key.pop_back(); // 63 digits
	bad_key.push_back(x);
	x = a;
	x.player_key += "0"; // 65 digits
	bad_key.push_back(x);
	x = a;
	x.player_key[0] = 'A'; // the digest is lowercase
	bad_key.push_back(x);
	x = a;
	x.player_key[5] = 'g';
	bad_key.push_back(x);
	x = ScopeId();
	x.kind = ScopeId::Player; // no key
	bad_key.push_back(x);
	x = ScopeId();
	x.kind = ScopeId::Kind(4);
	bad_key.push_back(x);
	for (const ScopeId& id : bad_key)
	{
		CHECK(!ss::scope_ok(id));
		CHECK(s.set(id, "k", ss::make_number(3), 2) == SetResult::BadKey);
		CHECK(!wire_set(id, "k", ss::make_number(3), 2));
	}
	// one scope, one form: a player scope is not keyed by an id, the others have no key digest. The wire has no room
	// for these fields (it carries the one form only).
	std::vector<ScopeId> bad_form;
	x = a;
	x.arg = 5;
	bad_form.push_back(x);
	x = ScopeId::world();
	x.arg = 3;
	bad_form.push_back(x);
	x = ScopeId::session();
	x.player_key = digest(1);
	bad_form.push_back(x);
	x = ScopeId::object(4);
	x.player_key = digest(1);
	bad_form.push_back(x);
	for (const ScopeId& id : bad_form)
	{
		CHECK(!ss::scope_ok(id));
		CHECK(s.set(id, "k", ss::make_number(3), 2) == SetResult::BadKey);
	}
	CHECK_EQ(s.scopes().size(), size_t(2));
	CHECK_EQ(results(s, SetResult::BadKey), uint64_t(bad_key.size() + bad_form.size()));
}

// Every container is bounded: the number of player and object scopes, and all of them together (the pool); the host's
// own scopes (world, session) have room of their own, so a client filling the pool cannot starve them.
TEST(sync_store_pool_and_count_limits)
{
	{
		Store s;
		for (uint32_t i = 0; i < ss::kMaxPlayerScopes; ++i)
			REQUIRE(s.set(ScopeId::player(digest(i)), "k", ss::make_bool(true), 1) == SetResult::Ok);
		const ScopeId next = ScopeId::player(digest(uint32_t(ss::kMaxPlayerScopes)));
		CHECK(s.set(next, "k", ss::make_bool(true), 1) == SetResult::ScopeFull);
		CHECK_EQ(s.stats().full_count, uint64_t(1));
		CHECK(s.get(next, "k") == nullptr);
		CHECK(s.set(ScopeId::player(digest(0)), "k2", ss::make_bool(true), 2) == SetResult::Ok);
		s.drop(ScopeId::player(digest(0)));
		CHECK(s.set(next, "k", ss::make_bool(true), 1) == SetResult::Ok);
	}
	{
		Store s;
		const Value big = sized_string(ss::kMaxValueBytes);
		const size_t cost = ss::entry_bytes("k1000", big);
		const size_t per_player = ss::kMaxPlayerBytes / cost;
		SetResult last = SetResult::Ok;
		uint64_t version = 0;
		for (uint32_t p = 0; p < 64 && last == SetResult::Ok; ++p)
			for (size_t i = 0; i < per_player && last == SetResult::Ok; ++i)
				last = s.set(ScopeId::player(digest(p)), "k" + std::to_string(1000 + i), big, ++version);
		CHECK(last == SetResult::ScopeFull);
		CHECK_EQ(s.stats().full_pool, uint64_t(1));
		CHECK_EQ(s.stats().full_scope, uint64_t(0));
		CHECK(s.pool_bytes() <= ss::kMaxPoolBytes);
		CHECK(s.pool_bytes() + cost > ss::kMaxPoolBytes);
		size_t sum = 0;
		for (const ScopeId& id : s.scopes())
			sum += s.bytes(id);
		CHECK_EQ(sum, s.pool_bytes());
		// an object shares the pool
		CHECK(s.set(ScopeId::object(1), "k1000", big, ++version) == SetResult::ScopeFull);
		CHECK_EQ(s.stats().full_pool, uint64_t(2));
		// the host's scopes still have their room
		CHECK(s.set(ScopeId::world(), "k", big, ++version) == SetResult::Ok);
		CHECK(s.set(ScopeId::session(), "k", big, ++version) == SetResult::Ok);
		static_assert(ss::kMaxTotalBytes == ss::kMaxWorldBytes + ss::kMaxSessionBytes + ss::kMaxPoolBytes,
		    "the total is the host's own scopes plus the pool");
	}
}

TEST(sync_store_table_order_and_keys)
{
	Store s;
	const ScopeId w = ScopeId::world();
	CHECK(s.set(w, "t", ss::make_table({{"b", ss::make_number(2)}, {"a", ss::make_number(1)}}), 1) == SetResult::Ok);
	const Value* got = s.get(w, "t");
	REQUIRE(got != nullptr && got->table.size() == 2);
	CHECK_EQ(got->table[0].first, std::string("a"));
	CHECK_EQ(got->table[1].first, std::string("b"));
	// the same table in another order is the same value
	CHECK(s.set(w, "t", ss::make_table({{"a", ss::make_number(1)}, {"b", ss::make_number(2)}}), 2) == SetResult::Same);

	CHECK(s.set(w, "task/1", ss::make_number(1), 3) == SetResult::Ok);
	CHECK(s.set(w, "task/2", ss::make_number(2), 4) == SetResult::Ok);
	CHECK(s.set(w, "tas", ss::make_number(3), 5) == SetResult::Ok);
	CHECK(s.set(w, "u", ss::make_number(4), 6) == SetResult::Ok);
	const auto ks = s.keys(w, "task/");
	REQUIRE(ks.size() == 2);
	CHECK_EQ(ks[0].first, std::string("task/1"));
	CHECK_EQ(ks[1].first, std::string("task/2"));
	CHECK(ks[0].second == s.get(w, "task/1"));
	CHECK_EQ(s.keys(w, "").size(), size_t(5));
	CHECK(s.keys(w, "task/1/").empty());
	CHECK(s.keys(ScopeId::object(5), "").empty());
}

TEST(sync_store_decode_refuses_bad_copies)
{
	Store s;
	const ScopeId obj = ScopeId::object(5);
	CHECK(s.set(obj, "mine", ss::make_number(1), 1) == SetResult::Ok);
	const std::vector<uint8_t> before = dump(s);
	auto refused = [&](const Writer& w) {
		const std::vector<uint8_t> b = bytes_of(w);
		Reader r(b.data(), b.size());
		ScopeId got = ScopeId::world();
		const bool ok = s.decode_scope(r, got);
		CHECK(got == ScopeId::world());
		CHECK(dump(s) == before);
		return !ok;
	};

	// over the scope's limit: a copy that says object 5 holds 70 KiB
	{
		Writer w;
		ss::write_scope(w, obj);
		w.u64(0);
		w.varu(70);
		const Value kib = ss::make_string(std::string(1024, 'x'));
		for (uint32_t i = 0; i < 70; ++i)
		{
			write_key(w, "k" + std::to_string(100 + i));
			w.u64(i + 1);
			ss::write_value(w, kib);
		}
		CHECK(refused(w));
		CHECK_EQ(s.stats().decode_full, uint64_t(1));
	}
	// keys out of order, a repeated key, a nil entry, version 0, a bad value, an empty key, trailing count
	auto entry = [](Writer& w, const std::string& key, uint64_t version, const Value& v) {
		write_key(w, key);
		w.u64(version);
		ss::write_value(w, v);
	};
	const Value one = ss::make_number(1);
	std::vector<Writer> bad(7);
	for (Writer& w : bad)
	{
		ss::write_scope(w, obj);
		w.u64(0);
		w.varu(2);
	}
	entry(bad[0], "b", 1, one);
	entry(bad[0], "a", 2, one);
	entry(bad[1], "a", 1, one);
	entry(bad[1], "a", 2, one);
	entry(bad[2], "a", 1, one);
	entry(bad[2], "b", 2, ss::make_nil());
	entry(bad[3], "a", 1, one);
	entry(bad[3], "b", 0, one);
	entry(bad[4], "a", 1, one);
	entry(bad[4], "b", 2, ss::make_number(std::numeric_limits<double>::infinity()));
	entry(bad[5], "", 1, one);
	entry(bad[5], "b", 2, one);
	entry(bad[6], "a", 1, one); // says 2, holds 1
	for (const Writer& w : bad)
		CHECK(refused(w));
	CHECK_EQ(s.stats().decode_bad, uint64_t(bad.size()));
	CHECK_EQ(s.stats().decoded, uint64_t(0));
}
