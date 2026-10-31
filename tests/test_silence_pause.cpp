// Anomaly Coop unit tests: a client's pause while the host is silent ends by what was taken (coop_silence_pause.h).
// In a session the clock refuses to stop, so the device reads as not paused while the sound is. Ending by the device's word
// left every sound then playing paused for good: ambient gone, new sounds such as footsteps fine (live 2026-10-31).
#include "test_util.h"

#include "coop_silence_pause.h"

using coop::SilencePause;

TEST(silence_pause_takes_it_once)
{
	SilencePause p;
	CHECK(!p.waiting);
	CHECK(p.begin(false));
	CHECK(p.waiting);
	CHECK(!p.begin(false)); // the next frames of the same silence
}

TEST(silence_pause_gives_back_what_it_took_whatever_the_device_says)
{
	SilencePause p;
	CHECK(p.begin(false));
	CHECK(p.end()); // the session's device still reads as not paused here: the sound comes back all the same
	CHECK(!p.waiting);
}

TEST(silence_pause_leaves_a_pause_that_was_not_its_own)
{
	SilencePause p;
	CHECK(!p.begin(true)); // somebody else paused the device: nothing is taken
	CHECK(p.waiting);
	CHECK(!p.end()); // and nothing is given back
	CHECK(!p.waiting);
}

TEST(silence_pause_ends_once)
{
	SilencePause p;
	CHECK(p.begin(false));
	CHECK(p.end());
	CHECK(!p.end());
}

TEST(silence_pause_works_again_after_an_end)
{
	SilencePause p;
	CHECK(p.begin(false));
	CHECK(p.end());
	CHECK(p.begin(false));
	CHECK(p.end());
}
