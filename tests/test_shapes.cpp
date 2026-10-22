// Anomaly Coop unit tests: distance from a point to the shapes of a level exit (coop_shapes.h). The host lets a player
// vote for a level exit only near it (T12 review, Ruling 18).
#include "test_util.h"

#include "coop_shapes.h"

#include <cmath>
#include <limits>

using namespace coop;

namespace
{
const float kNaN = std::numeric_limits<float>::quiet_NaN();
const float kInf = std::numeric_limits<float>::infinity();

bool near(float a, float b) { return std::fabs(a - b) < 1e-4f; }
} // namespace

TEST(shapes_sphere_distance)
{
	const float c[3] = {10.f, 2.f, -3.f};
	const float inside[3] = {10.5f, 2.f, -3.f};
	CHECK_EQ(shapes::to_sphere(inside, c, 2.f), 0.f);
	CHECK_EQ(shapes::to_sphere(c, c, 2.f), 0.f);
	const float on[3] = {12.f, 2.f, -3.f};
	CHECK_EQ(shapes::to_sphere(on, c, 2.f), 0.f);
	const float out[3] = {10.f, 2.f, 4.f}; // 7 from the center
	CHECK(near(shapes::to_sphere(out, c, 2.f), 5.f));
	const float diag[3] = {13.f, 6.f, -3.f}; // 3-4-5 from the center
	CHECK(near(shapes::to_sphere(diag, c, 1.f), 4.f));
	CHECK(near(shapes::to_sphere(diag, c, 0.f), 5.f)); // a point

	// Garbage never reads as "near".
	const float nan_p[3] = {kNaN, 0.f, 0.f};
	const float inf_c[3] = {0.f, kInf, 0.f};
	CHECK_EQ(shapes::to_sphere(nan_p, c, 2.f), shapes::kFar);
	CHECK_EQ(shapes::to_sphere(on, inf_c, 2.f), shapes::kFar);
	CHECK_EQ(shapes::to_sphere(on, c, kNaN), shapes::kFar);
	CHECK_EQ(shapes::to_sphere(on, c, -1.f), shapes::kFar);
	CHECK_EQ(shapes::to_sphere(on, c, kInf), shapes::kFar);
}

TEST(shapes_box_distance_axis_aligned)
{
	// A box 2 x 4 x 6 around (10, 0, 0): the unit cube's edges scaled, as a level editor box is stored.
	const float i[3] = {2.f, 0.f, 0.f}, j[3] = {0.f, 4.f, 0.f}, k[3] = {0.f, 0.f, 6.f}, c[3] = {10.f, 0.f, 0.f};
	CHECK_EQ(shapes::to_box(c, i, j, k, c), 0.f);
	const float inside[3] = {10.9f, -1.9f, 2.9f};
	CHECK_EQ(shapes::to_box(inside, i, j, k, c), 0.f);
	const float face[3] = {11.f, 2.f, 3.f}; // a corner: on the surface
	CHECK(near(shapes::to_box(face, i, j, k, c), 0.f));
	const float x_out[3] = {14.f, 0.f, 0.f}; // 3 past the +x face
	CHECK(near(shapes::to_box(x_out, i, j, k, c), 3.f));
	const float z_out[3] = {10.f, 1.f, -8.f}; // 5 past the -z face
	CHECK(near(shapes::to_box(z_out, i, j, k, c), 5.f));
	const float edge[3] = {14.f, 6.f, 0.f}; // 3 past x, 4 past y: 5 from the edge
	CHECK(near(shapes::to_box(edge, i, j, k, c), 5.f));
	const float corner[3] = {12.f, 4.f, 5.f}; // 1, 2, 2 past: 3 from the corner
	CHECK(near(shapes::to_box(corner, i, j, k, c), 3.f));
}

TEST(shapes_box_distance_rotated)
{
	// The same box turned 90 degrees about y: its 2 m edge runs along z, its 6 m edge along x.
	const float i[3] = {0.f, 0.f, -2.f}, j[3] = {0.f, 4.f, 0.f}, k[3] = {6.f, 0.f, 0.f}, c[3] = {0.f, 0.f, 0.f};
	const float along_x[3] = {5.f, 0.f, 0.f}; // the 6 m edge reaches 3 along x: 2 past
	CHECK(near(shapes::to_box(along_x, i, j, k, c), 2.f));
	const float along_z[3] = {0.f, 0.f, 4.f}; // half of 2 is 1 -> 3 past
	CHECK(near(shapes::to_box(along_z, i, j, k, c), 3.f));
	const float in[3] = {2.9f, 1.9f, -0.9f};
	CHECK_EQ(shapes::to_box(in, i, j, k, c), 0.f);

	// 45 degrees about y, a 2 x 2 x 2 cube: a point 3 along the cube's own x axis is 2 from its face.
	const float s = std::sqrt(0.5f);
	const float i45[3] = {2.f * s, 0.f, -2.f * s}, j45[3] = {0.f, 2.f, 0.f}, k45[3] = {2.f * s, 0.f, 2.f * s};
	const float p45[3] = {3.f * s, 0.f, -3.f * s};
	CHECK(near(shapes::to_box(p45, i45, j45, k45, c), 2.f));
	const float world_x[3] = {3.f, 0.f, 0.f}; // along the world x: |proj| = 3 * s on both slanted axes
	const float e = 3.f * s - 1.f;
	CHECK(near(shapes::to_box(world_x, i45, j45, k45, c), std::sqrt(2.f * e * e)));
}

TEST(shapes_box_garbage_is_far)
{
	const float i[3] = {2.f, 0.f, 0.f}, j[3] = {0.f, 4.f, 0.f}, k[3] = {0.f, 0.f, 6.f}, c[3] = {0.f, 0.f, 0.f};
	const float p[3] = {0.f, 0.f, 0.f};
	const float nan_p[3] = {0.f, kNaN, 0.f};
	CHECK_EQ(shapes::to_box(nan_p, i, j, k, c), shapes::kFar);
	const float inf_c[3] = {kInf, 0.f, 0.f};
	CHECK_EQ(shapes::to_box(p, i, j, k, inf_c), shapes::kFar);
	const float nan_e[3] = {kNaN, 0.f, 0.f};
	CHECK_EQ(shapes::to_box(p, nan_e, j, k, c), shapes::kFar);
	// A flat box (an edge of length 0) has no inside to stand in.
	const float flat[3] = {0.f, 0.f, 0.f};
	CHECK_EQ(shapes::to_box(p, i, flat, k, c), shapes::kFar);
}
