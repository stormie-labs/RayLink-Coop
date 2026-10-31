// Anomaly Coop unit tests: which creature on a client keeps its binder's update (coop_rules.h). Stock Anomaly offers the
// skinning from the update of a dead mutant's binder, so a suspended binder left a client with no tip and a dead use key.
#include "test_util.h"

#include "coop_rules.h"

using coop::rules::puppet_binder_runs;

TEST(puppet_binder_stays_off_for_the_living)
{
	CHECK(!puppet_binder_runs(true, true));
	CHECK(!puppet_binder_runs(false, true));
}

TEST(puppet_binder_runs_for_a_dead_mutant) { CHECK(puppet_binder_runs(true, false)); }

TEST(puppet_binder_stays_off_for_a_dead_stalker) { CHECK(!puppet_binder_runs(false, false)); }
