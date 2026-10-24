// Anomaly Coop unit tests: Writer/Reader, crc32, manifest helpers, handshake structs, names.
#include "test_util.h"

#include "coop_checkpoint_source_rules.h" // F3 T7 round 1: the claim and its answer in protocol 8

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
	CHECK_EQ(std::string(msg_name(uint16_t(0x012C))), std::string("EntitySound"));
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
		Msg::ScriptEvent, Msg::StateDumpRequest, Msg::StateDump, Msg::EntitySound, Msg::AvatarList,
		Msg::MoneyBalance, Msg::CharOffer, Msg::CharChoice, Msg::TransitionState,
		Msg::SyncSet, Msg::SyncFull, Msg::SyncRequest, Msg::SyncResult, Msg::SyncCast}; // F2 T14
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

// ---------------------------------------------------------------- W5 C2: creature sounds and snapshot flags

TEST(npc_sound_roundtrip_minimal_and_full)
{
	NpcSound a;
	a.object = 1234;
	a.path = "characters_voice\\human_01\\stalker\\fight\\enemy\\enemy_3";
	a.delay_ms = 0;
	Writer w;
	a.write(w);
	// u16 object + u8 flags + (varu len + bytes) + u16 delay: no optional fields
	CHECK_EQ(w.size(), size_t(2 + 1 + 1 + a.path.size() + 2));
	NpcSound a2;
	Reader r(w.ptr(), w.size());
	CHECK(a2.read(r));
	CHECK(r.remaining() == 0);
	CHECK(a2.object == 1234 && a2.flags == 0 && a2.path == a.path && a2.delay_ms == 0);
	CHECK(a2.bone == 0xFFFF && a2.mask == 0 && a2.volume == 100);
	CHECK(a2.offset[0] == 0.f && a2.offset[1] == 0.f && a2.offset[2] == 0.f);

	NpcSound b;
	b.object = 7;
	b.flags = NpcSound::Bone | NpcSound::Mask | NpcSound::Offset | NpcSound::Volume | NpcSound::Follow;
	b.path = "monsters\\bloodsucker\\attack_0";
	b.delay_ms = 650;
	b.bone = 15;
	b.mask = 0xF0000001u;
	b.offset[0] = 0.25f;
	b.offset[1] = 1.7f;
	b.offset[2] = -3.5f;
	b.volume = 180;
	Writer wb;
	b.write(wb);
	CHECK_EQ(wb.size(), size_t(2 + 1 + 1 + b.path.size() + 2 + 2 + 4 + 12 + 1));
	NpcSound b2;
	Reader rb(wb.ptr(), wb.size());
	CHECK(b2.read(rb));
	CHECK(b2.object == 7 && b2.flags == b.flags && b2.path == b.path && b2.delay_ms == 650);
	CHECK(b2.bone == 15 && b2.mask == 0xF0000001u && b2.volume == 180);
	CHECK(b2.offset[0] == 0.25f && b2.offset[1] == 1.7f && b2.offset[2] == -3.5f);

	// A batch as Msg::EntitySound carries it: u8 count, entries back to back.
	Writer batch;
	batch.u8(2);
	a.write(batch);
	b.write(batch);
	Reader rr(batch.ptr(), batch.size());
	const uint8_t n = rr.u8();
	CHECK_EQ(n, uint8_t(2));
	NpcSound x, y;
	CHECK(x.read(rr) && y.read(rr));
	CHECK(x.path == a.path && y.path == b.path && y.mask == b.mask);
	CHECK(rr.remaining() == 0);
}

TEST(npc_sound_read_rejects_bad_input)
{
	NpcSound b;
	b.object = 9;
	b.flags = NpcSound::Bone | NpcSound::Offset;
	b.path = "characters_voice\\human_02\\bandit\\states\\idle\\idle_1";
	b.bone = 3;
	Writer w;
	b.write(w);
	// truncated anywhere: never ok
	for (size_t cut = 0; cut < w.size(); ++cut)
	{
		NpcSound t;
		Reader r(w.ptr(), cut);
		CHECK(!t.read(r));
	}
	// unknown flag bit
	{
		Writer wu;
		wu.u16(1);
		wu.u8(0x80);
		wu.str("ambient\\wind");
		wu.u16(0);
		NpcSound t;
		Reader r(wu.ptr(), wu.size());
		CHECK(!t.read(r));
	}
	// non-finite and absurd offsets
	const float bad[] = {std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity(), 5000.f};
	for (float v : bad)
	{
		NpcSound o;
		o.flags = NpcSound::Offset;
		o.path = "weapons\\knife\\knife_1";
		o.offset[1] = v;
		Writer wo;
		o.write(wo);
		NpcSound t;
		Reader r(wo.ptr(), wo.size());
		CHECK(!t.read(r));
	}
	// path checked on read
	{
		NpcSound o;
		o.path = "..\\..\\fsgame";
		Writer wo;
		o.write(wo);
		NpcSound t;
		Reader r(wo.ptr(), wo.size());
		CHECK(!t.read(r));
	}
}

TEST(sound_path_validation)
{
	CHECK(sound_path_valid("characters_voice\\human_01\\stalker\\fight\\enemy\\enemy_3"));
	CHECK(sound_path_valid("monsters\\dog\\bark-1 v2.0"));
	CHECK(sound_path_valid("a"));
	CHECK(!sound_path_valid(""));
	CHECK(!sound_path_valid(std::string(NpcSound::kMaxPath + 1, 'a')));
	CHECK(sound_path_valid(std::string(NpcSound::kMaxPath, 'a')));
	CHECK(!sound_path_valid("..\\gamedata\\x"));
	CHECK(!sound_path_valid("a\\..\\b"));
	CHECK(!sound_path_valid("\\absolute"));
	CHECK(!sound_path_valid(".hidden"));
	CHECK(!sound_path_valid("$game_sounds$\\x"));
	CHECK(!sound_path_valid("c:\\windows\\x"));
	CHECK(!sound_path_valid("a/b"));
	CHECK(!sound_path_valid("Upper\\Case"));
	CHECK(!sound_path_valid(std::string("nul\0byte", 8)));
	CHECK(!sound_path_valid("tab\tchar"));
}

TEST(snapshot_anim_byte_packs_creature_flags)
{
	for (uint8_t count = 0; count <= 15; ++count)
		for (uint8_t flags = 0; flags <= 15; ++flags)
		{
			const uint8_t b = pack_anim_byte(count, flags);
			CHECK_EQ(anim_count_of(b), count);
			CHECK_EQ(creature_flags_of(b), flags);
		}
	// Old layout (no flags) reads as flags 0: counts up to 4 are unchanged bytes.
	CHECK_EQ(pack_anim_byte(4, 0), uint8_t(4));
	CHECK_EQ(creature_flags_of(uint8_t(4)), uint8_t(0));
	CHECK_EQ(pack_anim_byte(3, CreatureTorchLit), uint8_t(0x13));
	// Out-of-range inputs are masked, never spill into the other nibble.
	CHECK_EQ(anim_count_of(pack_anim_byte(0xFF, 0)), uint8_t(15));
	CHECK_EQ(creature_flags_of(pack_anim_byte(0, 0xFF)), uint8_t(15));
	static_assert(pack_anim_byte(2, CreatureTorchLit) == 0x12, "constexpr");
	// Protocol 12 (live 2026-10-24: a client never saw an NPC raise its weapon): a stalker's item in its hands (or on its
	// back) follows the anims as a u16 id; the flags still fit the nibble.
	CHECK_EQ(pack_anim_byte(2, CreatureHolds), uint8_t(0x22));
	CHECK_EQ(creature_flags_of(pack_anim_byte(4, CreatureTorchLit | CreatureHolds | CreatureStrapped)), uint8_t(7));
}

TEST(protocol_version_bumped_for_c2)
{
	CHECK(kProtocolVersion >= 3u);
	CHECK(static_cast<uint16_t>(Msg::EntitySound) == 0x012C);
	CHECK(static_cast<uint16_t>(Msg::EntitySound) > static_cast<uint16_t>(Msg::ItemState));
}

// Review R4 2: TradeOp Deal lost its client prices (item ids only, the host prices the deal).
TEST(protocol_version_bumped_for_host_priced_trade)
{
	CHECK(kProtocolVersion >= 4u);
}

// Review R1 I3-I4, R2 I1, I3: the world epoch in Welcome, BlobBegin and SessionReset, the core WorldEpoch, a level
// changer id in TransitionVote instead of a raw packet.
TEST(protocol_version_bumped_for_world_epoch)
{
	static_assert(kProtocolVersion >= 5u, "protocol 5");
	static_assert(static_cast<uint16_t>(Msg::WorldEpoch) == 0x000A, "core message, append only");
	static_assert(static_cast<uint16_t>(Msg::WorldEpoch) < static_cast<uint16_t>(Msg::GameBase), "handled by the session");
	CHECK_EQ(std::string(msg_name(Msg::WorldEpoch)), std::string("WorldEpoch"));

	WelcomeMsg we;
	we.slot = 2;
	we.session_token = 99;
	we.host_nick = "Host";
	we.max_players = 4;
	we.world_epoch = 0xA1B2C3D4u;
	Writer w;
	we.write(w);
	WelcomeMsg we2;
	Reader r(w.ptr(), w.size());
	CHECK(we2.read(r));
	CHECK_EQ(we2.world_epoch, uint32_t(0xA1B2C3D4u));
	CHECK_EQ(r.remaining(), size_t(0));
	Reader cut(w.ptr(), w.size() - 1); // a Welcome of protocol 4 has no epoch
	WelcomeMsg we3;
	CHECK(!we3.read(cut));
}

// ---------------------------------------------------------------- R3 В3: who plays each player character

// Review R3 В3: the host tells every client the owner of each player character (Msg::AvatarList).
TEST(protocol_version_bumped_for_avatar_owners)
{
	static_assert(kProtocolVersion >= 6u, "protocol 6");
	static_assert(static_cast<uint16_t>(Msg::AvatarList) == 0x0107, "append only");
	static_assert(static_cast<uint16_t>(Msg::AvatarList) >= static_cast<uint16_t>(Msg::GameBase), "a game message");
	CHECK_EQ(std::string(msg_name(Msg::AvatarList)), std::string("AvatarList"));
}

// F2 T1 (review R4 7): player money lives on the host. ReqMoney carries a change with a cause and goes to the host
// only; MoneyBalance answers it, from the host only; TradeOp Deal lost the client's money. The lead sets the version
// number at commit (the counter is shared with F3): raise the bound below to it then.
TEST(protocol_version_bumped_for_host_money)
{
	static_assert(kProtocolVersion >= 7u, "F2 T1: host-owned money");
	static_assert(static_cast<uint16_t>(Msg::MoneyBalance) == 0x0190, "F2 range 0x0190-0x019F, append only");
	static_assert(static_cast<uint16_t>(Msg::ReqMoney) == 0x0148, "the number stays");
	CHECK_EQ(std::string(msg_name(Msg::MoneyBalance)), std::string("MoneyBalance"));
	CHECK(msg_sender(Msg::MoneyBalance) == MsgSender::HostOnly);
	CHECK(msg_sender(Msg::ReqMoney) == MsgSender::ClientOnly);
	CHECK(msg_sender(Msg::TradeOp) == MsgSender::Either); // Deal one way, Result and TraderMoney the other
}

namespace
{
struct Row
{
	uint16_t avatar;
	uint32_t peer;
};

// An AvatarList as raw bytes: u8 count, then (u16 avatar, u32 peer) rows.
std::vector<uint8_t> avatar_table(uint8_t count, std::initializer_list<Row> rows)
{
	Writer w;
	w.u8(count);
	for (const auto& row : rows)
	{
		w.u16(row.avatar);
		w.u32(row.peer);
	}
	return std::vector<uint8_t>(w.ptr(), w.ptr() + w.size());
}

bool read_table(const std::vector<uint8_t>& bytes, AvatarListMsg& out)
{
	Reader r(bytes.data(), bytes.size());
	return out.read(r);
}
} // namespace

TEST(avatar_list_roundtrip)
{
	AvatarListMsg m;
	m.owners = {{0, kHostPeer}, {1205, 1}, {7, 3}};
	Writer w;
	m.write(w);
	CHECK_EQ(w.size(), size_t(1 + 3 * (2 + 4)));
	AvatarListMsg back;
	Reader r(w.ptr(), w.size());
	CHECK(back.read(r));
	CHECK_EQ(r.remaining(), size_t(0));
	REQUIRE(back.owners.size() == 3);
	CHECK(back.owners[0].avatar == 0 && back.owners[0].peer == kHostPeer);
	CHECK(back.owners[1].avatar == 1205 && back.owners[1].peer == PeerId(1));
	CHECK(back.owners[2].avatar == 7 && back.owners[2].peer == PeerId(3));

	// A full session: the host and kMaxPlayers - 1 clients.
	AvatarListMsg full;
	for (PeerId p = 0; p < kMaxPlayers; ++p)
		full.owners.push_back({uint16_t(p == kHostPeer ? 0 : 60000 + p), p});
	Writer wf;
	full.write(wf);
	AvatarListMsg full2;
	Reader rf(wf.ptr(), wf.size());
	CHECK(full2.read(rf));
	CHECK_EQ(full2.owners.size(), size_t(kMaxPlayers));
	CHECK(uint32_t(full2.owners.back().avatar) == 60000u + kMaxPlayers - 1 && full2.owners.back().peer == kMaxPlayers - 1);

	// The host alone: a table of one; an empty one says nobody plays any character.
	AvatarListMsg alone;
	CHECK(read_table(avatar_table(1, {{0, kHostPeer}}), alone));
	CHECK_EQ(alone.owners.size(), size_t(1));
	AvatarListMsg none;
	none.owners = {{5, 2}};
	CHECK(read_table(avatar_table(0, {}), none));
	CHECK(none.owners.empty());
}

TEST(avatar_list_rejects_bad_tables)
{
	// Truncated anywhere: never ok, nothing kept.
	const std::vector<uint8_t> good = avatar_table(3, {{0, 0}, {300, 1}, {301, 2}});
	for (size_t cut = 0; cut < good.size(); ++cut)
	{
		AvatarListMsg t;
		t.owners = {{9, 4}};
		Reader r(good.data(), cut);
		CHECK(!t.read(r));
		CHECK(t.owners.empty());
	}
	AvatarListMsg t;
	// More rows than a session has players, even when the bytes are there.
	std::initializer_list<Row> nine = {{0, 0}, {301, 1}, {302, 2}, {303, 3}, {304, 4},
		{305, 5}, {306, 6}, {307, 7}, {308, 7}};
	CHECK(!read_table(avatar_table(uint8_t(kMaxPlayers + 1), nine), t));
	CHECK(!read_table(avatar_table(255, {{0, 0}}), t));
	// No such object id.
	CHECK(!read_table(avatar_table(2, {{0, 0}, {0xFFFF, 1}}), t));
	// No such player slot.
	CHECK(!read_table(avatar_table(1, {{300, kInvalidPeer}}), t));
	CHECK(!read_table(avatar_table(1, {{300, kMaxPlayers}}), t));
	// One character, two players; one player, two characters.
	CHECK(!read_table(avatar_table(3, {{0, 0}, {300, 1}, {300, 2}}), t));
	CHECK(!read_table(avatar_table(3, {{0, 0}, {300, 1}, {301, 1}}), t));
	// Id 0 is the host's own actor: the host's and nobody else's, and the host plays no other character.
	CHECK(!read_table(avatar_table(1, {{0, 1}}), t));
	CHECK(!read_table(avatar_table(1, {{300, kHostPeer}}), t));
	CHECK(t.owners.empty());
	// The same rows in order are fine.
	CHECK(read_table(avatar_table(3, {{0, 0}, {300, 1}, {301, 2}}), t));
	CHECK_EQ(t.owners.size(), size_t(3));
}

// ---------------------------------------------------------------- protocol 8: a new character before the world

// Owner, live test 2026-10-23: a player whose key has no character in the host's world chooses faction and gear before
// the world is sent, not in the world after it. The host answers his JoinRequest with CharOffer, he answers with
// CharChoice, the host makes the character at its faction's start and sends the world.
TEST(protocol_version_bumped_for_character_before_world)
{
	// Game settings T3: protocol 9 adds the world's faction to CharOffer (test_protocol_game.cpp); the messages are 8's.
	static_assert(kProtocolVersion >= 8u, "protocol 8: CharOffer / CharChoice (protocol 7 has not shipped)");
	static_assert(static_cast<uint16_t>(Msg::CharOffer) == 0x0108, "join lifecycle range, append only");
	static_assert(static_cast<uint16_t>(Msg::CharChoice) == 0x0109, "join lifecycle range, append only");
	static_assert(static_cast<uint16_t>(Msg::CharOffer) >= static_cast<uint16_t>(Msg::GameBase), "a game message");
	CHECK_EQ(std::string(msg_name(Msg::CharOffer)), std::string("CharOffer"));
	CHECK_EQ(std::string(msg_name(Msg::CharChoice)), std::string("CharChoice"));
	CHECK(msg_sender(Msg::CharOffer) == MsgSender::HostOnly);
	CHECK(msg_sender(Msg::CharChoice) == MsgSender::ClientOnly);
}

// F2 T14: coop.sync on the network (SYNC_SPEC §6.1-6.3; layouts in xrCoop/coop_syncnet.h). Protocol 8 has not shipped:
// the messages join it (the lead's ruling), the history line says so.
TEST(protocol_version_bumped_for_sync_api)
{
	static_assert(kProtocolVersion >= 8u, "F2 T14: coop.sync messages are part of protocol 8");
	struct Row
	{
		Msg type;
		uint16_t wire;
		const char* name;
		MsgSender sender;
	};
	const Row rows[] = {
		{Msg::SyncSet, 0x0191, "SyncSet", MsgSender::Either}, // a client's change to the host, the host's to clients
		{Msg::SyncFull, 0x0192, "SyncFull", MsgSender::HostOnly}, // the full copy at join
		{Msg::SyncRequest, 0x0193, "SyncRequest", MsgSender::ClientOnly}, // coop.sync.request to the host's handler
		{Msg::SyncResult, 0x0194, "SyncResult", MsgSender::HostOnly}, // its answer
		{Msg::SyncCast, 0x0195, "SyncCast", MsgSender::HostOnly}, // coop.sync.broadcast
	};
	for (const Row& r : rows)
	{
		CHECK_EQ(static_cast<uint16_t>(r.type), r.wire);
		CHECK_EQ(std::string(msg_name(r.type)), std::string(r.name));
		CHECK(msg_sender(r.type) == r.sender);
	}
}

// F3 T7 round 1 (Rulings F3-5, F3-6, F3-8): protocol 8 has not shipped, so the claim's kinds and the host's refusal
// join it without a new version (the history line says so). CheckpointClaim: u8 what (1 tent, 2 sleeping bag, 3 pack
// up), vec3 pos — 13 bytes. CheckpointState flags 4 alone: u16 character, u8 4, u8 what, u8 reason — 5 bytes.
TEST(protocol_8_checkpoint_claim_and_refusal)
{
	static_assert(kProtocolVersion >= 8u, "the claim's kinds and its refusal are part of protocol 8 (and so of 9)");
	static_assert(static_cast<uint16_t>(Msg::CheckpointState) == 0x01C0, "F3 range");
	static_assert(static_cast<uint16_t>(Msg::CheckpointClaim) == 0x01C1, "F3 range");
	CHECK(msg_sender(Msg::CheckpointState) == MsgSender::HostOnly);
	CHECK(msg_sender(Msg::CheckpointClaim) == MsgSender::ClientOnly);

	const float pos[3] = {1.5f, -2.0f, 300.25f};
	for (const checkpoint::ClaimWhat w :
	    {checkpoint::ClaimWhat::Tent, checkpoint::ClaimWhat::Sleepbag, checkpoint::ClaimWhat::Pack})
	{
		Writer claim;
		checkpoint::write_claim(claim, w, pos);
		REQUIRE(claim.size() == 13);
		CHECK_EQ(claim.ptr()[0], static_cast<uint8_t>(w)); // what first
		Reader rd(claim.ptr(), claim.size());
		checkpoint::ClaimWhat what = checkpoint::ClaimWhat::Tent;
		float out[3] = {0, 0, 0};
		REQUIRE(checkpoint::read_claim(rd, what, out));
		CHECK(what == w);
		CHECK_EQ(out[2], 300.25f);
	}

	Writer refusal;
	checkpoint::write_refusal(refusal, 0x0102, checkpoint::ClaimWhat::Pack, checkpoint::Refusal::Far);
	REQUIRE(refusal.size() == 5);
	const uint8_t* b = refusal.ptr();
	CHECK_EQ(b[2], checkpoint::kStateRefused); // after the u16 character
	CHECK_EQ(b[3], uint8_t(3)); // pack
	CHECK_EQ(b[4], uint8_t(2)); // far
	Reader rd(refusal.ptr(), refusal.size());
	checkpoint::StateMsg m;
	REQUIRE(checkpoint::read_state(rd, m));
	CHECK(m.refused());
	CHECK_EQ(m.character, uint16_t(0x0102));
	CHECK(m.what == checkpoint::ClaimWhat::Pack);
	CHECK(m.reason == checkpoint::Refusal::Far);
}

TEST(char_name_validation)
{
	for (const char* ok : {"stalker", "wpn_ak74u", "ammo_5.45x39_fmj", "l01_escape", "af-ball", "Wpn_AK74", "a"})
		CHECK_EQ(std::string(ok) + (char_name_valid(ok) ? " valid" : " invalid"), std::string(ok) + " valid");
	for (const char* bad : {"", "a b", "a,b", "a;b", "..\\x", "x/y", "x\\y", "st\xC3\xA4r", "a\nb", "%s", "a=b", "[a]"})
		CHECK_EQ(std::string(bad) + (char_name_valid(bad) ? " valid" : " invalid"), std::string(bad) + " invalid");
	CHECK(char_name_valid(std::string(kMaxCharName, 'x')));
	CHECK(!char_name_valid(std::string(kMaxCharName + 1, 'x')));
	CHECK(char_name_valid(std::string(10, 'x'), 10));
	CHECK(!char_name_valid(std::string(11, 'x'), 10));
}

TEST(char_offer_roundtrip)
{
	CharOfferMsg m;
	m.eco = 3;
	m.points = 400;
	m.flags = CharOfferMsg::StoryMode;
	m.level = "l01_escape";
	m.refusal = "points";
	m.faction = "stalker"; // protocol 9: the world's faction ends the offer (test_protocol_game.cpp)
	Writer w;
	m.write(w);
	CHECK_EQ(w.size(), size_t(1 + 4 + 1 + 1 + 10 + 1 + 6 + 1 + 7));
	CharOfferMsg back;
	Reader r(w.ptr(), w.size());
	CHECK(back.read(r));
	CHECK_EQ(r.remaining(), size_t(0));
	CHECK(back.eco == 3 && back.points == 400u && back.flags == CharOfferMsg::StoryMode);
	CHECK_EQ(back.level, std::string("l01_escape"));
	CHECK_EQ(back.refusal, std::string("points"));
	CHECK_EQ(back.faction, std::string("stalker"));

	// The first offer has no refusal; a host on a level without a name (cannot happen in game) sends none.
	CharOfferMsg first;
	first.eco = 1;
	first.points = 1000;
	first.faction = "stalker";
	Writer wf;
	first.write(wf);
	CharOfferMsg first2;
	first2.refusal = "stale";
	Reader rf(wf.ptr(), wf.size());
	CHECK(first2.read(rf));
	CHECK(first2.eco == 1 && first2.points == 1000u && first2.flags == 0 && first2.level.empty() && first2.refusal.empty());
}

TEST(char_offer_rejects_bad_input)
{
	CharOfferMsg good;
	good.eco = 2;
	good.points = 700;
	good.level = "zaton";
	good.refusal = "items";
	good.faction = "bandit";
	Writer w;
	good.write(w);
	for (size_t cut = 0; cut < w.size(); ++cut)
	{
		CharOfferMsg m;
		Reader r(w.ptr(), cut);
		CHECK(!m.read(r));
	}
	auto offer = [](uint8_t eco, uint8_t flags, const std::string& level, const std::string& refusal) {
		Writer b;
		b.u8(eco);
		b.u32(1000);
		b.u8(flags);
		b.str(level);
		b.str(refusal);
		b.str("stalker"); // protocol 9: the world's faction (a bad one: test_protocol_game.cpp)
		CharOfferMsg m;
		Reader r(b.ptr(), b.size());
		return m.read(r);
	};
	CHECK(offer(1, 0, "jupiter", ""));
	CHECK(offer(3, CharOfferMsg::StoryMode, "", "busy"));
	CHECK(!offer(0, 0, "jupiter", "")); // economy tiers are 1..3
	CHECK(!offer(4, 0, "jupiter", ""));
	CHECK(!offer(1, 0x80, "jupiter", "")); // unknown flags
	CHECK(!offer(1, 0, "..\\..\\x", "")); // the level picks a texture: a name only
	CHECK(!offer(1, 0, std::string(CharOfferMsg::kMaxLevel + 1, 'l'), ""));
	CHECK(!offer(1, 0, "jupiter", "st_coop char")); // the refusal picks a string id: a name only
	CHECK(!offer(1, 0, "jupiter", std::string(CharOfferMsg::kMaxRefusal + 1, 'r')));
}

TEST(char_choice_roundtrip)
{
	CharChoiceMsg m;
	m.faction = "bandit";
	m.buy = {"wpn_ak74_old", "ammo_5.45x39_fmj", "wpn_ak74_old"};
	CHECK(m.valid());
	Writer w;
	m.write(w);
	CharChoiceMsg back;
	Reader r(w.ptr(), w.size());
	CHECK(back.read(r));
	CHECK_EQ(r.remaining(), size_t(0));
	CHECK_EQ(back.faction, std::string("bandit"));
	CHECK(back.buy == m.buy);

	// Nothing bought: the faction's free kit only.
	CharChoiceMsg plain;
	plain.faction = "stalker";
	Writer wp;
	plain.write(wp);
	CHECK_EQ(wp.size(), size_t(1 + 7 + 1));
	CharChoiceMsg plain2;
	plain2.buy = {"stale"};
	Reader rp(wp.ptr(), wp.size());
	CHECK(plain2.read(rp));
	CHECK(plain2.faction == "stalker" && plain2.buy.empty());

	// As many items as a choice may carry.
	CharChoiceMsg full;
	full.faction = "isg";
	full.buy.assign(CharChoiceMsg::kMaxBuy, "medkit");
	CHECK(full.valid());
	Writer wf;
	full.write(wf);
	CharChoiceMsg full2;
	Reader rf(wf.ptr(), wf.size());
	CHECK(full2.read(rf));
	CHECK_EQ(full2.buy.size(), size_t(CharChoiceMsg::kMaxBuy));
}

TEST(char_choice_rejects_bad_input)
{
	CharChoiceMsg good;
	good.faction = "dolg";
	good.buy = {"wpn_pm", "medkit"};
	Writer w;
	good.write(w);
	for (size_t cut = 0; cut < w.size(); ++cut)
	{
		CharChoiceMsg m;
		m.buy = {"x"};
		Reader r(w.ptr(), cut);
		CHECK(!m.read(r));
		CHECK(m.buy.empty());
	}
	auto choice = [](const std::string& faction, uint8_t count, std::initializer_list<const char*> items) {
		Writer b;
		b.str(faction);
		b.u8(count);
		for (const char* s : items)
			b.str(s);
		CharChoiceMsg m;
		Reader r(b.ptr(), b.size());
		return m.read(r);
	};
	CHECK(choice("army", 1, {"wpn_ak74"}));
	CHECK(!choice("", 0, {})); // no faction
	CHECK(!choice("army,bandit", 0, {}));
	CHECK(!choice(std::string(kMaxCharName + 1, 'f'), 0, {}));
	CHECK(!choice("army", 1, {""})); // an empty section
	CHECK(!choice("army", 2, {"wpn_ak74", "wpn ak74"}));
	CHECK(!choice("army", 1, {"wpn_ak74,wpn_pm"})); // one section per entry: the host's Lua splits nothing
	CHECK(!choice("army", uint8_t(CharChoiceMsg::kMaxBuy + 1), {})); // more than a choice carries, before the bytes
	// Validation on the sender's side: the client never sends what the host would refuse to read.
	CharChoiceMsg bad;
	bad.faction = "army";
	bad.buy.assign(CharChoiceMsg::kMaxBuy + 1, "medkit");
	CHECK(!bad.valid());
	bad.buy = {"med kit"};
	CHECK(!bad.valid());
	bad.buy.clear();
	bad.faction.clear();
	CHECK(!bad.valid());
}
