// Anomaly Coop unit tests: a C++ exception stopped at a call nobody could catch it behind, and named (coop_guarded_call.h).
// The renderer's texture loads run in a task group no one waits on: without this a throw leaves the texture "loading" for ever.
#include "test_util.h"

#include "coop_guarded_call.h"

#include <cstring>
#include <stdexcept>
#include <system_error>

using coop::guard::call;

namespace
{
struct NotAnException
{
};
struct Derived : std::runtime_error
{
	Derived() : std::runtime_error("from a derived type") {}
};

int g_unwound = 0;
struct Marker
{
	~Marker() { ++g_unwound; }
};

void counts(void* p) { ++*static_cast<int*>(p); }
void throws_runtime(void*) { throw std::runtime_error("disk on fire"); }
void throws_derived(void*) { throw Derived(); }
void throws_system(void*) { throw std::system_error(std::make_error_code(std::errc::resource_deadlock_would_occur)); }
void throws_alien(void*) { throw NotAnException(); }
void throws_after_a_local(void*)
{
	Marker m;
	throw 7;
}
void touches_null(void*) { *static_cast<volatile int*>(nullptr) = 1; }

// The access violation must pass the guard: the crash handler is further up.
bool violation_passes()
{
	__try
	{
		char why[32] = "";
		call(touches_null, nullptr, why, sizeof(why));
		return false;
	}
	__except (GetExceptionCode() == EXCEPTION_ACCESS_VIOLATION ? EXCEPTION_EXECUTE_HANDLER : EXCEPTION_CONTINUE_SEARCH)
	{
		return true;
	}
}
}

TEST(guarded_call_runs_the_function)
{
	int n = 0;
	char why[64] = "untouched";
	CHECK(call(counts, &n, why, sizeof(why)));
	CHECK(n == 1);
	CHECK(strcmp(why, "untouched") == 0);
}

TEST(guarded_call_names_a_std_exception)
{
	char why[128] = "";
	CHECK(!call(throws_runtime, nullptr, why, sizeof(why)));
	CHECK(strstr(why, "runtime_error") != nullptr);
	CHECK(strstr(why, "disk on fire") != nullptr);
}

TEST(guarded_call_reads_what_through_a_derived_type)
{
	char why[128] = "";
	CHECK(!call(throws_derived, nullptr, why, sizeof(why)));
	CHECK(strstr(why, "Derived") != nullptr);
	CHECK(strstr(why, "from a derived type") != nullptr);
}

TEST(guarded_call_reads_a_system_error)
{
	char why[160] = "";
	CHECK(!call(throws_system, nullptr, why, sizeof(why)));
	CHECK(strstr(why, "system_error") != nullptr);
	CHECK(strstr(why, "deadlock") != nullptr);
}

TEST(guarded_call_names_a_type_with_no_what)
{
	char why[128] = "";
	CHECK(!call(throws_alien, nullptr, why, sizeof(why)));
	CHECK(strstr(why, "NotAnException") != nullptr);
}

TEST(guarded_call_keeps_to_a_small_buffer)
{
	char why[8 + 1];
	memset(why, '#', sizeof(why));
	CHECK(!call(throws_runtime, nullptr, why, 8));
	CHECK(strlen(why) == 7);
	CHECK(why[8] == '#');
}

TEST(guarded_call_unwinds_the_frames_it_stops)
{
	g_unwound = 0;
	char why[32] = "";
	CHECK(!call(throws_after_a_local, nullptr, why, sizeof(why)));
	CHECK(g_unwound == 1);
}

TEST(guarded_call_leaves_a_violation_to_the_crash_handler) { CHECK(violation_passes()); }
