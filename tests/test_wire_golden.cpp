// Anomaly Coop unit tests: the exact bytes Writer puts on the wire. Every message of the protocol is built from these
// primitives, so a change of their layout changes every message: the bytes are pinned here one by one.
#include "test_util.h"

#include <vector>

using namespace coop;

namespace
{
bool same_bytes(const Writer& w, const std::vector<uint8_t>& want)
{
	return w.data() == want;
}
} // namespace

TEST(wire_golden_primitives_are_little_endian_bytes)
{
	Writer w;
	w.u8(0xAB);
	w.u16(0xBEEF);
	w.u32(0xDEADBEEFu);
	w.u64(0x0123456789ABCDEFull);
	w.i32(-2);
	w.f32(1.0f);
	w.boolean(true);
	w.boolean(false);
	w.varu(300);
	w.str("ab");
	const uint8_t raw[3] = {1, 2, 3};
	w.bytes(raw, sizeof(raw));
	const float v[3] = {1.0f, -2.0f, 0.5f};
	w.vec3(v);
	w.angle16(3.14159265f);
	const std::vector<uint8_t> want = {
		0xAB, //
		0xEF, 0xBE, //
		0xEF, 0xBE, 0xAD, 0xDE, //
		0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23, 0x01, //
		0xFE, 0xFF, 0xFF, 0xFF, //
		0x00, 0x00, 0x80, 0x3F, //
		0x01, 0x00, //
		0xAC, 0x02, //
		0x02, 'a', 'b', //
		0x01, 0x02, 0x03, //
		0x00, 0x00, 0x80, 0x3F, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x3F, //
		0x00, 0x80, //
	};
	CHECK_EQ(w.size(), want.size());
	CHECK(same_bytes(w, want));
}

TEST(wire_golden_extremes_and_empty_values)
{
	Writer w;
	w.u16(0);
	w.u16(0xFFFF);
	w.u32(0);
	w.u32(0xFFFFFFFFu);
	w.u64(0xFFFFFFFFFFFFFFFFull);
	w.varu(0);
	w.varu(127);
	w.varu(128);
	w.str("");
	w.bytes(nullptr, 4); // no data: nothing written
	w.angle16(-0.0f);
	const std::vector<uint8_t> want = {
		0x00, 0x00, //
		0xFF, 0xFF, //
		0x00, 0x00, 0x00, 0x00, //
		0xFF, 0xFF, 0xFF, 0xFF, //
		0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, //
		0x00, //
		0x7F, //
		0x80, 0x01, //
		0x00, //
		0x00, 0x00, //
	};
	CHECK_EQ(w.size(), want.size());
	CHECK(same_bytes(w, want));
}

TEST(wire_golden_patch_rewrites_a_header_in_place)
{
	Writer w(64); // the reserve changes no byte
	w.u8(7);
	const size_t count_at = w.size();
	w.u16(0);
	const size_t size_at = w.size();
	w.u32(0);
	w.u8(9);
	w.patch_u16(count_at, 0x1234);
	w.patch_u32(size_at, 0xA1B2C3D4u);
	const std::vector<uint8_t> want = {0x07, 0x34, 0x12, 0xD4, 0xC3, 0xB2, 0xA1, 0x09};
	CHECK(same_bytes(w, want));
	w.clear();
	CHECK_EQ(w.size(), size_t(0));
	w.u16(0x0102);
	CHECK(same_bytes(w, {0x02, 0x01}));
}
