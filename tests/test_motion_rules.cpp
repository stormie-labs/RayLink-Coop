// Anomaly Coop unit tests: the script cycle of a world physic object across machines (xrCoop/coop_motion_rules.h; live
// 2026-11-09: the X-16 levers went down on the host alone).
#include "test_util.h"

#include "coop_motion_rules.h"

#include <cmath>
#include <vector>

using namespace coop::motion;
using coop::Reader;
using coop::Writer;

namespace
{
// The stock X-16 switcher: ph_button@active anim = lab_primary_switcher_idle, ph_button@deactivate anim =
// lab_primary_switcher_off; ph_button.script reset_scheme plays it with st.blending (anim_blend, true by default).
const char* const kUp = "lab_primary_switcher_idle";
const char* const kDown = "lab_primary_switcher_off";
} // namespace

TEST(motion_word_round_trip)
{
	Word in;
	in.id = 10067;
	in.cycle = kDown;
	in.mix_in = true;
	in.played_ms = 1234;
	Writer w(64);
	write_word(w, in);
	Reader r(w.ptr(), w.size());
	Word out;
	CHECK(read_word(r, out));
	CHECK_EQ(out.id, in.id);
	CHECK(out.cycle == in.cycle);
	CHECK(out.mix_in == true);
	CHECK_EQ(out.played_ms, in.played_ms);
	CHECK_EQ(r.remaining(), size_t(0));

	// the script's explicit false travels too: no default in place of the stock call's argument
	in.mix_in = false;
	Writer w2(64);
	write_word(w2, in);
	Reader r2(w2.ptr(), w2.size());
	CHECK(read_word(r2, out));
	CHECK(out.mix_in == false);
}

TEST(motion_word_refuses_what_could_not_be_a_cycle)
{
	Word out;
	{
		Writer w(8);
		w.u16(5); // nothing else
		Reader r(w.ptr(), w.size());
		CHECK(!read_word(r, out));
	}
	{
		Word in; // no cycle: the client would look up nothing
		in.id = 5;
		Writer w(32);
		write_word(w, in);
		Reader r(w.ptr(), w.size());
		CHECK(!read_word(r, out));
	}
	{
		Word in;
		in.id = 5;
		in.cycle.assign(kMaxCycleName + 1, 'a');
		Writer w(256);
		write_word(w, in);
		Reader r(w.ptr(), w.size());
		CHECK(!read_word(r, out));
	}
	{
		Writer w(32);
		w.u16(5);
		w.str(kDown);
		w.u8(2); // no bool
		w.u32(0);
		Reader r(w.ptr(), w.size());
		CHECK(!read_word(r, out));
	}
	{
		Writer w(32);
		w.u16(5);
		w.str(kDown);
		w.u8(1);
		w.u32(0x80000000u);
		Reader r(w.ptr(), w.size());
		CHECK(!read_word(r, out));
	}
}

TEST(motion_book_keeps_the_last_cycle_of_each_object)
{
	Book b;
	Word word;
	CHECK(!b.has(10067));
	CHECK(!b.word(10067, 0, word));
	// the host loads X-16: each switcher's ph_button@active plays the up cycle
	b.note(10067, kUp, true, 1000);
	b.note(10070, kUp, true, 1000);
	CHECK_EQ(b.size(), size_t(2));
	// somebody pulls switcher 1: ph_button@deactivate plays the down cycle
	b.note(10067, kDown, true, 5000);
	CHECK(b.word(10067, 5000, word));
	CHECK(word.cycle == kDown);
	CHECK(word.mix_in);
	CHECK_EQ(word.played_ms, 0u);
	CHECK_EQ(word.id, 10067);
	// a player who comes in a minute later gets it, played that long: his copy is put at its end
	CHECK(b.word(10067, 65000, word));
	CHECK(word.cycle == kDown);
	CHECK_EQ(word.played_ms, 60000u);
	CHECK(b.word(10070, 65000, word));
	CHECK(word.cycle == kUp);
	CHECK_EQ(b.size(), size_t(2));
	// a clock that went back says 0, a world of weeks is capped
	CHECK_EQ(Book::played(5000, 4000), 0u);
	CHECK_EQ(Book::played(0, uint64_t(1) << 40), kMaxPlayedMs);
	b.clear();
	CHECK(!b.has(10067));
}

TEST(motion_local_cycle_of_a_client_yields_to_the_host)
{
	// a client's own copy of the logic: its ph_button@active plays the up cycle after the host's down word came
	CHECK(local_cycle(true, true, true) == LocalCycle::Drop);
	// before any word: its logic runs as before (the same sections as the host's at a load)
	CHECK(local_cycle(true, true, false) == LocalCycle::Play);
	// the host, single player: stock
	CHECK(local_cycle(false, true, true) == LocalCycle::Play);
	CHECK(local_cycle(false, true, false) == LocalCycle::Play);
	// a weapon in hands, a stalker: not a world physic object, never held to a word
	CHECK(local_cycle(true, false, true) == LocalCycle::Play);
}

TEST(motion_client_replays_the_word)
{
	CHECK(must_play(true, true, true)); // the host played it again: replay the call as it was made
	CHECK(!must_play(false, true, true)); // shown on the copy it was played on: nothing
	CHECK(must_play(false, false, true)); // the lever went offline and came back: its startup cycle shows, play the word
	CHECK(must_play(false, true, false)); // something else took the visual: the host's word again
}

TEST(motion_phase_after_the_host_played_it)
{
	const float eps = 1.f / 30.f + 1e-4f;
	// a stop-at-end cycle (the switcher going down, 1 s): a late player sees it down, at the stock end of a stopped blend
	CHECK(std::fabs(phase_after(60.f, 1.f, 1.f, true, eps) - (1.f - eps)) < 1e-6f);
	CHECK(std::fabs(phase_after(0.25f, 1.f, 1.f, true, eps) - 0.25f) < 1e-6f);
	CHECK(std::fabs(phase_after(0.25f, 2.f, 1.f, true, eps) - 0.5f) < 1e-6f);
	// a looped cycle wraps
	CHECK(std::fabs(phase_after(2.5f, 1.f, 1.f, false, eps) - 0.5f) < 1e-5f);
	// just played, a broken number or an empty motion: from the start
	CHECK(phase_after(0.f, 1.f, 1.f, true, eps) == 0.f);
	CHECK(phase_after(std::nanf(""), 1.f, 1.f, true, eps) == 0.f);
	CHECK(phase_after(1.f, 1.f, 0.f, false, eps) == 0.f);
	CHECK(phase_after(1.f, 1.f, eps * 0.5f, true, eps) == 0.f);
}
