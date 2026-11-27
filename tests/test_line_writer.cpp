// Anomaly Coop unit tests: the line writer between the game's threads and a reader that may stop reading (xrCoop/srv/coop_line_writer.h).
// The dedicated host's pipe to its parent and its console window are both such readers: a paused window or a parent that does not read
// must cost the game's threads nothing but lines. The sink of every test is held on a gate the test opens; a wait is bounded only so
// that a broken writer fails the test instead of hanging it.
#include "test_util.h"

#include "srv/coop_line_writer.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <future>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using namespace coop::world_server;

namespace
{
constexpr auto kBound = std::chrono::seconds(10); // a failure bound, never the expected result
constexpr unsigned kFlushBoundMs = 10000;

// A sink that records every line and holds each call until the test opens it.
struct Gate
{
	std::mutex lock;
	std::condition_variable wake;
	std::vector<std::string> got;
	bool open = false;
	bool answer = true;

	LineWriter::Sink sink()
	{
		return [this](const std::string& line) {
			std::unique_lock<std::mutex> hold(lock);
			got.push_back(line);
			wake.notify_all();
			wake.wait_for(hold, kBound, [this] { return open; });
			return answer;
		};
	}
	// The sink holds its n-th line (or has written it).
	bool entered(size_t n)
	{
		std::unique_lock<std::mutex> hold(lock);
		return wake.wait_for(hold, kBound, [&] { return got.size() >= n; });
	}
	void release()
	{
		std::lock_guard<std::mutex> hold(lock);
		open = true;
		wake.notify_all();
	}
	std::vector<std::string> lines()
	{
		std::lock_guard<std::mutex> hold(lock);
		return got;
	}
};

// The writer's own lock, counted, and held by the test the way a writer's thread killed by ExitProcess inside it would leave it.
struct CountedLock
{
	static CountedLock* last; // the lock of the writer made last
	std::mutex m;
	std::atomic<int> taken{0};

	CountedLock() { last = this; }
	void lock()
	{
		++taken;
		m.lock();
	}
	void unlock() { m.unlock(); }
};
CountedLock* CountedLock::last = nullptr;

bool refuse_thread(void (*)(void*), void*) { return false; }
// The tests' starter: a detached thread of the standard library (the engine passes the CRT's).
bool own_thread(void (*entry)(void*), void* arg)
{
	std::thread(entry, arg).detach();
	return true;
}
} // namespace

TEST(line_writer_push_returns_while_the_sink_is_held_and_keeps_the_order)
{
	Gate gate;
	LineWriter w(OutputQueue(8, 8));
	CHECK(!w.on());
	CHECK(w.start(gate.sink(), own_thread));
	CHECK(w.on());
	w.push("a", false);
	CHECK(gate.entered(1));
	w.push("b", false); // the sink holds "a": these return at once
	w.push("@rl phase world", true);
	w.push("c", false);
	CHECK(!w.flush(0)); // three lines wait, one is being written
	gate.release();
	CHECK(w.flush(kFlushBoundMs));
	CHECK(gate.lines() == std::vector<std::string>({"a", "b", "@rl phase world", "c"}));
}

TEST(line_writer_held_sink_keeps_the_queue_bounded_and_its_note_comes_first)
{
	Gate gate;
	LineWriter w(OutputQueue(2, 2, "console", "the window's output was paused"));
	CHECK(w.start(gate.sink(), own_thread));
	w.push("a", false);
	CHECK(gate.entered(1));
	for (const char* line : {"1", "2", "3", "4", "5"})
		w.push(line, false); // a bound of 2: "1", "2", "3" go
	gate.release();
	CHECK(w.flush(kFlushBoundMs));
	CHECK(gate.lines() ==
	      std::vector<std::string>({"a", "[coop] console: 3 line(s) of the log dropped, the window's output was paused", "4", "5"}));
}

TEST(line_writer_sink_that_answers_false_turns_it_off)
{
	Gate gate;
	gate.answer = false; // the reader is gone for good
	gate.open = true;
	LineWriter w(OutputQueue(8, 8));
	CHECK(w.start(gate.sink(), own_thread));
	w.push("a", false);
	CHECK(!w.flush(kFlushBoundMs)); // answers as soon as the writer is off, not at the bound
	CHECK(!w.on());
	w.push("b", false);
	w.push("@rl phase world", true);
	CHECK(!w.flush(kFlushBoundMs));
	CHECK(gate.lines() == std::vector<std::string>({"a"}));
}

TEST(line_writer_flush_is_true_only_when_nothing_waits_and_nothing_is_written)
{
	Gate gate;
	LineWriter w(OutputQueue(8, 8));
	CHECK(!w.flush(0)); // not started: off
	CHECK(w.start(gate.sink(), own_thread));
	CHECK(w.flush(kFlushBoundMs)); // started, nothing pushed
	w.push("a", false);
	CHECK(gate.entered(1));
	CHECK(!w.flush(0)); // the queue is empty, the sink still holds "a"
	w.push("b", false);
	CHECK(!w.flush(0));
	gate.release();
	CHECK(w.flush(kFlushBoundMs));
	CHECK(w.on());
	CHECK(gate.lines() == std::vector<std::string>({"a", "b"}));
}

TEST(line_writer_rl_lines_keep_their_own_bound)
{
	Gate gate;
	LineWriter w(OutputQueue(2, 1));
	CHECK(w.start(gate.sink(), own_thread));
	w.push("a", false);
	CHECK(gate.entered(1));
	w.push("@rl phase world", true);
	w.push("x1", false);
	w.push("x2", false);
	w.push("x3", false); // "x1" goes
	w.push("@rl phase session", true); // "@rl phase world" goes: its own bound of 1, the log lines take none of it
	gate.release();
	CHECK(w.flush(kFlushBoundMs));
	CHECK(gate.lines() == std::vector<std::string>({"a", "[coop] stdout: 2 line(s) of the log dropped, the parent did not read", "x2", "x3",
	                                                "@rl phase session"}));
}

// The quit closes the writers after their flushes: no more lines are taken and no later call takes the lock (a writer's thread killed
// inside it would hold it for ever), while the lines queued before, the parent's "down" among them, are still written.
TEST(line_writer_closed_takes_no_more_lines_and_writes_the_queued_ones)
{
	auto gate = std::make_shared<Gate>(); // shared with the sink: the writer's thread may leave the sink after this test returns
	BasicLineWriter<CountedLock> w(OutputQueue(8, 8));
	CountedLock& lock = *CountedLock::last;
	CHECK(w.start([gate, sink = gate->sink()](const std::string& line) { return sink(line); }, own_thread));
	w.push("a", false);
	CHECK(gate->entered(1)); // the writer's thread holds the sink with "a"
	w.push("@rl phase down", true); // queued behind it
	w.close();
	CHECK(!w.on());
	const int taken = lock.taken;
	lock.m.lock();
	std::promise<void> done;
	std::thread late([&] {
		w.push("c", false);
		w.close();
		done.set_value();
	});
	const bool at_once = done.get_future().wait_for(kBound) == std::future_status::ready;
	lock.m.unlock(); // a writer that does take the lock gets it now, so a failure ends instead of hanging
	late.join();
	CHECK(at_once);
	CHECK(lock.taken == taken);
	gate->release();
	CHECK(gate->entered(2)); // the line queued before the close is written after it
	CHECK(gate->lines() == std::vector<std::string>({"a", "@rl phase down"}));
}

// A stopped writer is off for good: a line handed over later must return at once and take no lock, even while the writer's thread
// is held in its sink and its lock is held by a thread that will never release it; the lines it had queued go with the stop.
TEST(line_writer_after_stop_returns_at_once_without_the_lock)
{
	auto gate = std::make_shared<Gate>(); // shared with the sink: the writer's thread leaves the sink after this test returns
	BasicLineWriter<CountedLock> w(OutputQueue(8, 8));
	CountedLock& lock = *CountedLock::last;
	CHECK(w.start([gate, sink = gate->sink()](const std::string& line) { return sink(line); }, own_thread));
	w.push("a", false);
	CHECK(gate->entered(1)); // the writer's thread holds the sink
	w.push("b", false);
	w.stop();
	CHECK(!w.on());
	const int taken = lock.taken;
	lock.m.lock();
	bool flushed = true;
	bool on = true;
	std::promise<void> done;
	std::thread late([&] {
		w.push("c", false);
		w.push("@rl phase down", true);
		flushed = w.flush(kFlushBoundMs);
		on = w.on();
		w.stop();
		done.set_value();
	});
	const bool at_once = done.get_future().wait_for(kBound) == std::future_status::ready;
	lock.m.unlock(); // a writer that does take the lock gets it now, so a failure ends instead of hanging
	late.join();
	CHECK(at_once);
	CHECK(!flushed);
	CHECK(!on);
	CHECK(lock.taken == taken);
	gate->release();
	CHECK(gate->lines() == std::vector<std::string>({"a"})); // "b" went with the stop
}

// A system that refuses the writer's thread leaves the writer off and the caller running without that output.
TEST(line_writer_refused_thread_leaves_it_off)
{
	Gate gate;
	gate.open = true;
	LineWriter w(OutputQueue(8, 8));
	CHECK(!w.start(gate.sink(), refuse_thread));
	CHECK(!w.on());
	w.push("a", false);
	CHECK(!w.flush(kFlushBoundMs));
	CHECK(!w.start(gate.sink(), own_thread)); // off for good: no second thread
	CHECK(!w.on());
	CHECK(gate.lines().empty());
}

// A writer stopped before its start (no window was opened) never starts later.
TEST(line_writer_stopped_before_its_start_never_starts)
{
	Gate gate;
	gate.open = true;
	LineWriter w(OutputQueue(8, 8));
	w.stop();
	CHECK(!w.start(gate.sink(), own_thread));
	w.push("a", false);
	CHECK(!w.on());
	CHECK(!w.flush(kFlushBoundMs));
	CHECK(gate.lines().empty());
}
