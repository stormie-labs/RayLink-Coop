// Anomaly Coop unit tests: checks of numbers and names that come from the network (coop_validate.h, R3 K1, K2).
#include "test_util.h"

#include "coop_validate.h"

#include <limits>
#include <string>

using namespace coop;

namespace
{
const float kNaN = std::numeric_limits<float>::quiet_NaN();
const float kInf = std::numeric_limits<float>::infinity();
} // namespace

TEST(validate_finite)
{
	CHECK(!validate::finite(kNaN));
	CHECK(!validate::finite(kInf));
	CHECK(!validate::finite(-kInf));
	CHECK(validate::finite(0.f));
	CHECK(validate::finite(-1e6f));
	CHECK(validate::finite(1e6f));
	CHECK(validate::finite(std::numeric_limits<float>::max()));
	CHECK(validate::finite(std::numeric_limits<float>::denorm_min()));

	const float ok[3] = {1.f, -2.f, 1e6f};
	CHECK(validate::finite3(ok));
	for (int i = 0; i < 3; ++i)
	{
		float v[3] = {0.f, 0.f, 0.f};
		v[i] = kNaN;
		CHECK(!validate::finite3(v));
		v[i] = -kInf;
		CHECK(!validate::finite3(v));
	}
}

TEST(validate_speed)
{
	const float at_limit[3] = {0.f, 0.f, 100.f};
	CHECK(validate::speed_ok(at_limit, 100.f));
	const float over[3] = {0.f, 0.f, 100.01f};
	CHECK(!validate::speed_ok(over, 100.f));
	const float diagonal[3] = {60.f, -80.f, 0.f}; // length exactly 100
	CHECK(validate::speed_ok(diagonal, 100.f));
	const float diagonal_over[3] = {60.f, -80.f, 0.5f};
	CHECK(!validate::speed_ok(diagonal_over, 100.f));
	const float still[3] = {0.f, 0.f, 0.f};
	CHECK(validate::speed_ok(still, 100.f));

	const float nan_x[3] = {kNaN, 0.f, 0.f};
	CHECK(!validate::speed_ok(nan_x, 100.f));
	const float nan_z[3] = {0.f, 0.f, kNaN};
	CHECK(!validate::speed_ok(nan_z, 100.f));
	const float inf_y[3] = {0.f, kInf, 0.f};
	CHECK(!validate::speed_ok(inf_y, 100.f));
	// Squares of huge finite components must not overflow into a pass.
	const float huge[3] = {3e38f, 3e38f, 3e38f};
	CHECK(!validate::speed_ok(huge, 100.f));

	// A broken limit never lets anything through.
	CHECK(!validate::speed_ok(still, kNaN));
	CHECK(!validate::speed_ok(at_limit, -100.f));
}

TEST(validate_box)
{
	const float lo[3] = {-100.f, -10.f, -200.f};
	const float hi[3] = {100.f, 10.f, 200.f};
	const float margin = 50.f;

	const float inside[3] = {0.f, 0.f, 0.f};
	CHECK(validate::in_box(inside, lo, hi, margin));
	// On the border of the grown box: +50 past hi / -50 past lo.
	const float border_hi[3] = {150.f, 60.f, 250.f};
	CHECK(validate::in_box(border_hi, lo, hi, margin));
	const float border_lo[3] = {-150.f, -60.f, -250.f};
	CHECK(validate::in_box(border_lo, lo, hi, margin));
	// +50.01 past the border, on each axis.
	const float over_x[3] = {150.01f, 0.f, 0.f};
	CHECK(!validate::in_box(over_x, lo, hi, margin));
	const float over_y[3] = {0.f, 60.01f, 0.f};
	CHECK(!validate::in_box(over_y, lo, hi, margin));
	const float under_z[3] = {0.f, 0.f, -250.01f};
	CHECK(!validate::in_box(under_z, lo, hi, margin));
	// Far away and non-finite.
	const float far_away[3] = {1e30f, 0.f, 0.f};
	CHECK(!validate::in_box(far_away, lo, hi, margin));
	const float far_neg[3] = {0.f, 0.f, -1e30f};
	CHECK(!validate::in_box(far_neg, lo, hi, margin));
	const float nan_p[3] = {0.f, kNaN, 0.f};
	CHECK(!validate::in_box(nan_p, lo, hi, margin));
	const float inf_p[3] = {kInf, 0.f, 0.f};
	CHECK(!validate::in_box(inf_p, lo, hi, margin));
	// Zero margin = the box itself.
	const float edge[3] = {100.f, 10.f, 200.f};
	CHECK(validate::in_box(edge, lo, hi, 0.f));
	CHECK(!validate::in_box(border_hi, lo, hi, 0.f));
	// A broken box or margin rejects everything.
	const float bad_lo[3] = {kNaN, -10.f, -200.f};
	CHECK(!validate::in_box(inside, bad_lo, hi, margin));
	CHECK(!validate::in_box(inside, lo, hi, kNaN));
}

TEST(validate_name)
{
	const size_t kMax = 200;
	CHECK(validate::resource_name_ok("actors\\stalker_neutral\\stalker_neutral_1", kMax));
	CHECK(validate::resource_name_ok("actors\\stalker_neutral\\stalker_neutral_1.ogf", kMax));
	CHECK(validate::resource_name_ok("a b/c-d_e.f", kMax));

	CHECK(!validate::resource_name_ok("", kMax));
	CHECK(!validate::resource_name_ok(nullptr, kMax));
	CHECK(!validate::resource_name_ok("..\\x", kMax));
	CHECK(!validate::resource_name_ok("actors\\..\\..\\x", kMax));
	CHECK(!validate::resource_name_ok("actors\\x..", kMax));
	CHECK(!validate::resource_name_ok("c:\\x", kMax));
	CHECK(!validate::resource_name_ok("actors\\x:stream", kMax));

	const std::string exact(kMax, 'a');
	CHECK(validate::resource_name_ok(exact.c_str(), kMax));
	const std::string too_long(kMax + 1, 'a');
	CHECK(!validate::resource_name_ok(too_long.c_str(), kMax));
	CHECK(!validate::resource_name_ok("a", 0));

	// Printable ASCII only: 0x20..0x7E.
	CHECK(validate::resource_name_ok("x ~", kMax));
	CHECK(!validate::resource_name_ok("actors\x7F", kMax));
	CHECK(!validate::resource_name_ok("actors\x1F", kMax));
	CHECK(!validate::resource_name_ok("actors\tx", kMax));
	CHECK(!validate::resource_name_ok("actors\x80", kMax));
	CHECK(!validate::resource_name_ok("\xD0\xBF", kMax)); // UTF-8 Cyrillic
}

TEST(validate_vector_types)
{
	struct V
	{
		float x, y, z;
	};
	CHECK(validate::vec_finite(V{1.f, -2.f, 3.f}));
	CHECK(!validate::vec_finite(V{1.f, kNaN, 3.f}));
	CHECK(!validate::vec_finite(V{1.f, 2.f, -kInf}));
	CHECK(validate::vec_speed_ok(V{0.f, 60.f, 80.f}, 100.f));
	CHECK(!validate::vec_speed_ok(V{0.f, 60.f, 80.01f}, 100.f));
	CHECK(!validate::vec_speed_ok(V{3e38f, 3e38f, 3e38f}, 100.f));
	// A direction from a peer is a unit vector: a huge finite one would normalize to zero and a matrix to NaN.
	CHECK(validate::vec_speed_ok(V{0.f, 0.f, 1.f}, validate::kMaxDirLength));
	CHECK(!validate::vec_speed_ok(V{0.f, 1e20f, 0.f}, validate::kMaxDirLength));
}

TEST(validate_bone)
{
	// R3 В5: the bone of a hit indexes the target's skeleton; 0xffff (BI_NONE) is the engine's own "no bone".
	static_assert(validate::kNoBone == 0xffffu, "BI_NONE is u16(-1)");
	CHECK(validate::bone_ok(0, 1));
	CHECK(validate::bone_ok(46, 47));
	CHECK(!validate::bone_ok(47, 47));
	CHECK(!validate::bone_ok(48, 47));
	CHECK(!validate::bone_ok(1000, 47));
	CHECK(!validate::bone_ok(0, 0)); // no skeleton bones: only "no bone" passes
	CHECK(validate::bone_ok(validate::kNoBone, 47));
	CHECK(validate::bone_ok(validate::kNoBone, 0));
	CHECK(validate::bone_ok(0xfffe, 0xffff)); // the last bone of the largest skeleton a u16 can count
	CHECK(!validate::bone_ok(0xfffe, 0xfffe));
}
