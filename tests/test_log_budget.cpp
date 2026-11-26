// Anomaly Coop unit tests: the budget of a log line that repeats by kind (xrCoop/coop_lua_errors.h, LogBudget / line_allowed).
// It replaces the hand copies `++n <= burst || n % 100 == 0` of xrGame/coop: the golden check below runs each old copy beside the
// helper over the first lines of a kind, so a module that moves to the helper writes the very same lines.
#include "test_util.h"

#include "coop_lua_errors.h"

#include <cstdint>

using coop::lua_errors::line_allowed;
using coop::lua_errors::LogBudget;

namespace
{
// The old copies, as they read (the count already incremented by the caller, or incremented inside).
bool old_count_10(uint64_t count) { return count <= 10 || count % 100 == 0; }

struct OldInc20
{
	uint32_t n = 0;
	bool allowed() { return ++n <= 20 || (n % 100) == 0; }
};

bool old_srv_8(uint64_t n) { return n <= 8 || n % 100 == 0; }
} // namespace

TEST(log_budget_writes_the_same_lines_as_the_old_copies)
{
	OldInc20 old20;
	LogBudget b10(10), b20(20), b8(8);
	for (uint64_t n = 1; n <= 5000; ++n)
	{
		CHECK_EQ(line_allowed(n, 10), old_count_10(n));
		CHECK_EQ(line_allowed(n, 8), old_srv_8(n));
		CHECK_EQ(b10.allow(), old_count_10(n));
		CHECK_EQ(b8.allow(), old_srv_8(n));
		CHECK_EQ(b20.allow(), old20.allowed());
	}
	CHECK_EQ(b10.count(), uint64_t(5000));
	CHECK_EQ(b20.count(), uint64_t(5000));
}

TEST(log_budget_first_burst_then_every_hundredth)
{
	LogBudget b(3);
	CHECK(b.allow());
	CHECK(b.allow());
	CHECK(b.allow());
	CHECK(!b.allow()); // 4
	for (int i = 5; i < 100; ++i)
		CHECK(!b.allow());
	CHECK(b.allow()); // 100
	CHECK_EQ(b.count(), uint64_t(100));
	static_assert(line_allowed(200, 0) && !line_allowed(1, 0), "a zero burst writes only every hundredth line");
}
