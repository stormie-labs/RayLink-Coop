// Anomaly Coop unit tests: Writer/Reader, crc32, manifest helpers, handshake structs, names.
#include "test_util.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

using namespace coop;

TEST(wire_roundtrip_all_types)
{
	Writer w;
	w.u8(0xAB);
	w.u16(0xBEEF);
	w.u32(0xDEADBEEFu);
	w.u64(0x0123456789ABCDEFull);
	w.i32(-123456789);
	w.i32(std::numeric_limits<int32_t>::min());
	w.f32(3.14159274f);
	w.f32(-0.f);
	w.boolean(true);
	w.boolean(false);
	w.varu(300);
	w.str("hello \xD0\xBF\xD1\x80\xD0\xB8\xD0\xB2\xD0\xB5\xD1\x82");
	w.str("");
	const uint8_t raw[5] = {1, 2, 3, 4, 5};
	w.bytes(raw, sizeof(raw));
	const float v3[3] = {1.5f, -2.25f, 1e6f};
	w.vec3(v3);
	w.angle16(1.0f);

	// Little-endian layout is part of the protocol.
	CHECK_EQ(w.data()[0], uint8_t(0xAB));
	CHECK_EQ(w.data()[1], uint8_t(0xEF));
	CHECK_EQ(w.data()[2], uint8_t(0xBE));
	CHECK_EQ(w.data()[3], uint8_t(0xEF));
	CHECK_EQ(w.data()[6], uint8_t(0xDE));

	Reader r(w.ptr(), w.size());
	CHECK_EQ(r.u8(), uint8_t(0xAB));
	CHECK_EQ(r.u16(), uint16_t(0xBEEF));
	CHECK_EQ(r.u32(), 0xDEADBEEFu);
	CHECK_EQ(r.u64(), 0x0123456789ABCDEFull);
	CHECK_EQ(r.i32(), -123456789);
	CHECK_EQ(r.i32(), std::numeric_limits<int32_t>::min());
	CHECK_EQ(r.f32(), 3.14159274f);
	const float nz = r.f32();
	CHECK(nz == 0.f && std::signbit(nz));
	CHECK(r.boolean());
	CHECK(!r.boolean());
	CHECK_EQ(r.varu(), uint64_t(300));
	CHECK_EQ(r.str(), std::string("hello \xD0\xBF\xD1\x80\xD0\xB8\xD0\xB2\xD0\xB5\xD1\x82"));
	CHECK_EQ(r.str(), std::string());
	uint8_t back[5] = {};
	CHECK(r.bytes(back, sizeof(back)));
	CHECK(std::memcmp(raw, back, sizeof(raw)) == 0);
	float o3[3] = {};
	r.vec3(o3);
	CHECK(o3[0] == 1.5f && o3[1] == -2.25f && o3[2] == 1e6f);
	CHECK(std::fabs(r.angle16() - 1.0f) < 1e-4f);
	CHECK(r.ok());
	CHECK_EQ(r.remaining(), size_t(0));
}

TEST(wire_float_special_values_roundtrip_bitwise)
{
	const float values[] = {0.f, 1.f, -1.f, 1e-38f, 3.4e38f, std::numeric_limits<float>::infinity(),
		-std::numeric_limits<float>::infinity()};
	Writer w;
	for (float f : values)
		w.f32(f);
	w.f32(std::numeric_limits<float>::quiet_NaN());
	Reader r(w.ptr(), w.size());
	for (float f : values)
		CHECK(r.f32() == f);
	CHECK(std::isnan(r.f32()));
	CHECK(r.ok());
}

TEST(wire_varu_edge_values)
{
	const uint64_t values[] = {0, 1, 127, 128, 255, 256, 16383, 16384, 0x1FFFFFull, 0x200000ull,
		std::numeric_limits<uint32_t>::max(), uint64_t(std::numeric_limits<uint32_t>::max()) + 1,
		std::numeric_limits<uint64_t>::max() - 1, std::numeric_limits<uint64_t>::max()};
	for (uint64_t v : values)
	{
		Writer w;
		w.varu(v);
		Reader r(w.ptr(), w.size());
		CHECK_EQ(r.varu(), v);
		CHECK(r.ok());
		CHECK_EQ(r.remaining(), size_t(0));
	}

	// Encoded sizes.
	{
		Writer w;
		w.varu(127);
		CHECK_EQ(w.size(), size_t(1));
		w.clear();
		w.varu(128);
		CHECK_EQ(w.size(), size_t(2));
		w.clear();
		w.varu(std::numeric_limits<uint64_t>::max());
		CHECK_EQ(w.size(), size_t(10));
	}

	// Malformed: 11 continuation bytes, and a 10th byte that overflows 64 bits.
	{
		const uint8_t too_long[11] = {0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01};
		Reader r(too_long, sizeof(too_long));
		CHECK_EQ(r.varu(), uint64_t(0));
		CHECK(!r.ok());
	}
	{
		const uint8_t overflow[10] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F};
		Reader r(overflow, sizeof(overflow));
		r.varu();
		CHECK(!r.ok());
	}
	{
		const uint8_t truncated[2] = {0x80, 0x80};
		Reader r(truncated, sizeof(truncated));
		r.varu();
		CHECK(!r.ok());
	}
}

TEST(wire_str_truncation_and_limits)
{
	Writer w;
	const std::string big(Writer::kMaxString + 100, 'x');
	w.str(big);
	Reader r(w.ptr(), w.size());
	const std::string got = r.str();
	CHECK(r.ok());
	CHECK_EQ(got.size(), Writer::kMaxString);
	CHECK(got == big.substr(0, Writer::kMaxString));

	// Exactly at the limit is kept whole.
	Writer w2;
	const std::string exact(Writer::kMaxString, 'y');
	w2.str(exact);
	Reader r2(w2.ptr(), w2.size());
	CHECK(r2.str() == exact);
	CHECK(r2.ok());

	// A reader refuses a declared length above the limit even when enough bytes follow.
	Writer w3;
	w3.varu(Writer::kMaxString + 1);
	const std::string filler(Writer::kMaxString + 1, 'z');
	w3.bytes(filler.data(), filler.size());
	Reader r3(w3.ptr(), w3.size());
	CHECK(r3.str().empty());
	CHECK(!r3.ok());

	// Declared length beyond the buffer.
	Writer w4;
	w4.varu(10);
	w4.u8('a');
	Reader r4(w4.ptr(), w4.size());
	CHECK(r4.str().empty());
	CHECK(!r4.ok());

	// Embedded NUL survives.
	Writer w5;
	w5.str(std::string("a\0b", 3));
	Reader r5(w5.ptr(), w5.size());
	CHECK(r5.str() == std::string("a\0b", 3));
}

TEST(wire_angle16_precision)
{
	const double two_pi = 6.283185307179586;
	const double step = two_pi / 65536.0;
	double worst = 0.0;
	for (int i = -20000; i <= 20000; ++i)
	{
		const float a = float(i) * 0.000731f; // about +-14.6 rad: several wraps
		Writer w;
		w.angle16(a);
		CHECK_EQ(w.size(), size_t(2));
		Reader r(w.ptr(), w.size());
		const float back = r.angle16();
		CHECK(back >= 0.f && back < float(two_pi) + 1e-6f);
		double d = std::fmod(double(back) - double(a), two_pi);
		if (d > two_pi / 2)
			d -= two_pi;
		if (d < -two_pi / 2)
			d += two_pi;
		worst = std::max(worst, std::fabs(d));
	}
	// Half a quantization step plus float rounding of the input and output.
	CHECK(worst <= step * 0.5 + 2e-6);
	CHECK(worst < 1e-4);

	// Wrap-around: 2*pi and -tiny map to code 0 / 65535 neighbours, not to garbage.
	Writer w;
	w.angle16(float(two_pi));
	w.angle16(0.f);
	w.angle16(-0.00001f);
	Reader r(w.ptr(), w.size());
	const float a0 = r.angle16();
	const float a1 = r.angle16();
	const float a2 = r.angle16();
	CHECK(a0 < 1e-4f || a0 > float(two_pi) - 1e-4f);
	CHECK(a1 == 0.f);
	CHECK(a2 < 1e-4f || a2 > float(two_pi) - 1e-4f);

	// NaN must not crash or read out of range.
	Writer wn;
	wn.angle16(std::numeric_limits<float>::quiet_NaN());
	Reader rn(wn.ptr(), wn.size());
	const float an = rn.angle16();
	CHECK(an >= 0.f && an < 7.f);
}

TEST(wire_reader_overrun_sets_failed_and_returns_zero)
{
	const uint8_t data[3] = {1, 2, 3};
	Reader r(data, sizeof(data));
	CHECK_EQ(r.u16(), uint16_t(0x0201));
	CHECK(r.ok());
	CHECK_EQ(r.remaining(), size_t(1));
	CHECK_EQ(r.u32(), 0u); // needs 4, has 1
	CHECK(!r.ok());
	CHECK_EQ(r.remaining(), size_t(0));
	// Everything afterwards is zero/empty, even things that would have fit before.
	CHECK_EQ(r.u8(), uint8_t(0));
	CHECK_EQ(r.u16(), uint16_t(0));
	CHECK_EQ(r.u64(), uint64_t(0));
	CHECK_EQ(r.i32(), 0);
	CHECK_EQ(r.f32(), 0.f);
	CHECK(!r.boolean());
	CHECK_EQ(r.varu(), uint64_t(0));
	CHECK(r.str().empty());
	CHECK_EQ(r.angle16(), 0.f);
	float v[3] = {9.f, 9.f, 9.f};
	r.vec3(v);
	CHECK(v[0] == 0.f && v[1] == 0.f && v[2] == 0.f);
	uint8_t out[4] = {0xFF, 0xFF, 0xFF, 0xFF};
	CHECK(!r.bytes(out, sizeof(out)));
	CHECK(!r.skip(1));

	// skip / bytes overrun on a fresh reader.
	Reader r2(data, sizeof(data));
	CHECK(r2.skip(2));
	CHECK(!r2.skip(2));
	CHECK(!r2.ok());
	Reader r3(data, sizeof(data));
	uint8_t big[8];
	CHECK(!r3.bytes(big, sizeof(big)));
	CHECK(!r3.ok());

	// Empty reader.
	Reader r4(nullptr, 0);
	CHECK_EQ(r4.u8(), uint8_t(0));
	CHECK(!r4.ok());
	Reader r5(nullptr, 0);
	CHECK(r5.skip(0));
	CHECK(r5.ok());
}

TEST(crc32_known_vectors)
{
	CHECK_EQ(crc32("123456789", 9), 0xCBF43926u);
	CHECK_EQ(crc32("", 0), 0u);
	CHECK_EQ(crc32("a", 1), 0xE8B7BE43u);
	CHECK_EQ(crc32("The quick brown fox jumps over the lazy dog", 43), 0x414FA339u);
	// Chaining through the seed equals one pass.
	const uint32_t part = crc32("12345", 5);
	CHECK_EQ(crc32("6789", 4, part), 0xCBF43926u);
	// Large buffer: incremental == one shot.
	const std::vector<uint8_t> data = t::random_bytes(100000, 7);
	const uint32_t one = crc32(data.data(), data.size());
	uint32_t inc = 0;
	for (size_t off = 0; off < data.size(); off += 4096)
		inc = crc32(data.data() + off, std::min<size_t>(4096, data.size() - off), inc);
	CHECK_EQ(one, inc);
}

TEST(player_key_generation_and_hash)
{
	const PlayerKey a = generate_player_key();
	const PlayerKey b = generate_player_key();
	CHECK(a != b);
	CHECK(a != PlayerKey{});
	CHECK_EQ(player_key_hash(a), player_key_hash(a));
	CHECK(player_key_hash(a) != player_key_hash(b));
}

TEST(msg_name_known_and_unknown)
{
	CHECK_EQ(std::string(msg_name(Msg::Hello)), std::string("Hello"));
	CHECK_EQ(std::string(msg_name(Msg::PlayerState)), std::string("PlayerState"));
	CHECK_EQ(std::string(msg_name(Msg::StateDump)), std::string("StateDump"));
	CHECK_EQ(std::string(msg_name(uint16_t(0x0123))), std::string("EntitySnapshot"));
	CHECK_EQ(std::string(msg_name(static_cast<Msg>(0x1234))), std::string("Msg_0x1234"));
	CHECK_EQ(std::string(msg_name(static_cast<Msg>(0x0050))), std::string("Msg_0x0050"));
	CHECK_EQ(std::string(msg_name(uint16_t(0xFFFF))), std::string("Msg_0xFFFF"));

	// Several unknown names alive at once (one log line) must not overwrite each other.
	const char* a = msg_name(static_cast<Msg>(0x7001));
	const char* b = msg_name(static_cast<Msg>(0x7002));
	CHECK_EQ(std::string(a), std::string("Msg_0x7001"));
	CHECK_EQ(std::string(b), std::string("Msg_0x7002"));

	// Every enumerator of the header has a real name.
	const Msg all[] = {Msg::Hello, Msg::Welcome, Msg::Reject, Msg::Bye, Msg::BlobBegin, Msg::BlobChunk, Msg::BlobEnd,
		Msg::PeerList, Msg::Chat, Msg::GameBase, Msg::JoinRequest, Msg::WorldBlob, Msg::WorldLoaded,
		Msg::JoinComplete, Msg::SessionReset, Msg::LevelChange, Msg::TransitionVote, Msg::PlayerState,
		Msg::PlayerVitals, Msg::PlayerEquip, Msg::PlayerAnim, Msg::PlayerShot, Msg::PlayerGrenade, Msg::PlayerHit,
		Msg::PlayerWounded, Msg::PlayerRevive, Msg::PlayerDied, Msg::EntitySpawn, Msg::EntityDestroy,
		Msg::EntitySwitch, Msg::EntitySnapshot, Msg::EntityAnim, Msg::EntityEvent, Msg::EntityHealth,
		Msg::EntityDied, Msg::EntityParent, Msg::EntityState, Msg::ReqSpawn, Msg::ReqDestroy, Msg::ReqTake,
		Msg::ReqDrop, Msg::ReqTransfer, Msg::ReqUse, Msg::ReqHit, Msg::ReqResult, Msg::ReqMoney,
		Msg::ReqContainer, Msg::TimeSync, Msg::WeatherSync, Msg::Emission, Msg::ZoneState, Msg::InfoPortion,
		Msg::TaskList, Msg::TaskUpdate, Msg::MapSpot, Msg::Relation, Msg::Progress, Msg::DialogLock,
		Msg::DialogLockResult, Msg::DialogUnlock, Msg::DialogPhrases, Msg::DialogSelect, Msg::TradeOp,
		Msg::ScriptEvent, Msg::StateDumpRequest, Msg::StateDump};
	for (Msg m : all)
		CHECK(std::strncmp(msg_name(m), "Msg_0x", 6) != 0);
}

TEST(reject_reason_names)
{
	CHECK_EQ(std::string(reject_reason_name(RejectReason::DuplicateKey)), std::string("DuplicateKey"));
	CHECK_EQ(std::string(reject_reason_name(RejectReason::ProtocolMismatch)), std::string("ProtocolMismatch"));
	CHECK_EQ(std::string(reject_reason_name(RejectReason::Malformed)), std::string("Malformed"));
	CHECK(std::strlen(reject_reason_name(static_cast<RejectReason>(200))) > 0);
}

TEST(manifest_fingerprint_order_independent)
{
	Manifest a = {{"a.ltx", 1}, {"b.script", 2}, {"c.ogf", 3}, {"d.dds", 4}};
	Manifest b = {{"d.dds", 4}, {"b.script", 2}, {"a.ltx", 1}, {"c.ogf", 3}};
	CHECK_EQ(manifest_fingerprint(a), manifest_fingerprint(b));

	Manifest changed_hash = a;
	changed_hash[1].hash = 22;
	CHECK(manifest_fingerprint(a) != manifest_fingerprint(changed_hash));

	Manifest changed_path = a;
	changed_path[0].path = "a2.ltx";
	CHECK(manifest_fingerprint(a) != manifest_fingerprint(changed_path));

	Manifest fewer = a;
	fewer.pop_back();
	CHECK(manifest_fingerprint(a) != manifest_fingerprint(fewer));

	// Path boundaries matter: {"ab","c"} must differ from {"a","bc"}.
	Manifest x = {{"ab", 5}, {"c", 5}};
	Manifest y = {{"a", 5}, {"bc", 5}};
	CHECK(manifest_fingerprint(x) != manifest_fingerprint(y));

	CHECK_EQ(manifest_fingerprint(Manifest{}), manifest_fingerprint(Manifest{}));
	CHECK(manifest_fingerprint(Manifest{}) != manifest_fingerprint(a));

	// Many entries, shuffled deterministically.
	Manifest big;
	for (int i = 0; i < 5000; ++i)
		big.push_back({"gamedata\\file_" + std::to_string(i) + ".ltx", uint64_t(i) * 2654435761ull});
	Manifest shuffled = big;
	for (size_t i = 0; i < shuffled.size(); ++i)
		std::swap(shuffled[i], shuffled[(i * 7919 + 13) % shuffled.size()]);
	CHECK_EQ(manifest_fingerprint(big), manifest_fingerprint(shuffled));
}

TEST(manifest_diff_missing_extra_differ)
{
	const Manifest host = {{"a.ltx", 1}, {"b.script", 2}, {"c.ogf", 3}, {"same.dds", 9}};
	const Manifest here = {{"same.dds", 9}, {"b.script", 99}, {"d.xml", 4}, {"a.ltx", 1}};
	const ManifestDiff d = diff_manifests(here, host);
	CHECK(!d.empty());
	REQUIRE(d.missing_here.size() == 1);
	CHECK_EQ(d.missing_here[0], std::string("c.ogf"));
	REQUIRE(d.extra_here.size() == 1);
	CHECK_EQ(d.extra_here[0], std::string("d.xml"));
	REQUIRE(d.differ.size() == 1);
	CHECK_EQ(d.differ[0], std::string("b.script"));

	CHECK(diff_manifests(host, host).empty());
	CHECK(diff_manifests(Manifest{}, Manifest{}).empty());

	const ManifestDiff all_missing = diff_manifests(Manifest{}, host);
	CHECK_EQ(all_missing.missing_here.size(), size_t(4));
	CHECK(all_missing.extra_here.empty() && all_missing.differ.empty());
	const ManifestDiff all_extra = diff_manifests(host, Manifest{});
	CHECK_EQ(all_extra.extra_here.size(), size_t(4));
}

TEST(manifest_write_read_roundtrip_and_bad_counts)
{
	Manifest m = t::sample_manifest();
	m.push_back({"", 0});
	Writer w;
	write_manifest(w, m);
	Reader r(w.ptr(), w.size());
	Manifest back;
	CHECK(read_manifest(r, back));
	CHECK_EQ(back.size(), m.size());
	for (size_t i = 0; i < m.size() && i < back.size(); ++i)
		CHECK(back[i].path == m[i].path && back[i].hash == m[i].hash);

	// Truncated buffer.
	Reader rt(w.ptr(), w.size() - 3);
	Manifest tmp;
	CHECK(!read_manifest(rt, tmp));
	CHECK(tmp.empty());

	// Absurd count must fail without allocating.
	Writer bad;
	bad.varu(0xFFFFFFFFFFull);
	bad.u8(1);
	Reader rb(bad.ptr(), bad.size());
	Manifest tmp2;
	CHECK(!read_manifest(rb, tmp2));
	CHECK(!rb.ok());
}

TEST(handshake_structs_roundtrip)
{
	HelloMsg h;
	h.protocol = 7;
	h.build_id = "build-xyz";
	h.content_fp = 0xCAFEBABE12345678ull;
	for (size_t i = 0; i < h.key.size(); ++i)
		h.key[i] = uint8_t(i * 3 + 1);
	h.nick = "Strelok";
	Writer w;
	h.write(w);
	HelloMsg h2;
	Reader r(w.ptr(), w.size());
	CHECK(h2.read(r));
	CHECK(h2.protocol == 7 && h2.build_id == h.build_id && h2.content_fp == h.content_fp && h2.key == h.key &&
		h2.nick == h.nick);
	Reader rt(w.ptr(), w.size() - 1);
	HelloMsg h3;
	CHECK(!h3.read(rt));

	WelcomeMsg we;
	we.slot = 3;
	we.session_token = 0x1122334455667788ull;
	we.host_nick = "Host";
	we.max_players = 5;
	Writer ww;
	we.write(ww);
	WelcomeMsg we2;
	Reader rw(ww.ptr(), ww.size());
	CHECK(we2.read(rw));
	CHECK(we2.slot == 3 && we2.session_token == we.session_token && we2.host_nick == "Host" && we2.max_players == 5);

	RejectMsg rj;
	rj.reason = RejectReason::ContentMismatch;
	rj.text = "files differ";
	rj.host_manifest = t::sample_manifest();
	Writer wr;
	rj.write(wr);
	RejectMsg rj2;
	Reader rr(wr.ptr(), wr.size());
	CHECK(rj2.read(rr));
	CHECK(rj2.reason == RejectReason::ContentMismatch && rj2.text == "files differ");
	CHECK_EQ(rj2.host_manifest.size(), size_t(3));

	// Manifest only travels with ContentMismatch.
	RejectMsg plain;
	plain.reason = RejectReason::SessionFull;
	plain.text = "full";
	plain.host_manifest = t::sample_manifest();
	Writer wp;
	plain.write(wp);
	RejectMsg plain2;
	Reader rp(wp.ptr(), wp.size());
	CHECK(plain2.read(rp));
	CHECK(plain2.reason == RejectReason::SessionFull && plain2.host_manifest.empty());
}
