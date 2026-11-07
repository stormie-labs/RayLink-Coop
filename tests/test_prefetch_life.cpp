// Anomaly Coop unit tests: the life of a level's spawn prefetch thread (coop_prefetch_life.h; SPAWN_ANTIFREEZE in
// xrGame/Level.cpp). The stock thread outlived its CLevel: ~CLevel freed the containers and then signalled the thread
// without waiting, so a batch in flight wrote into freed memory (0xC0000374 at level change); one static event served
// every level, and a stop that came just before the thread's own ResetEvent was lost.
#include "test_util.h"

#include "coop_prefetch_life.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <functional>
#include <memory>
#include <mutex>
#include <random>
#include <set>
#include <shared_mutex>
#include <string>
#include <thread>
#include <vector>

namespace
{
using coop::prefetch::kForever;
using Clock = std::chrono::steady_clock;

// A manual-reset event on std primitives that remembers every thread that set, reset or waited on it.
class TestEvent
{
public:
	void set()
	{
		note();
		std::lock_guard<std::mutex> g(m_);
		on_ = true;
		cv_.notify_all();
	}
	void reset()
	{
		note();
		std::lock_guard<std::mutex> g(m_);
		on_ = false;
	}
	bool wait(uint32_t ms)
	{
		note();
		std::unique_lock<std::mutex> g(m_);
		if (ms == kForever)
		{
			cv_.wait(g, [this] { return on_; });
			return true;
		}
		return cv_.wait_for(g, std::chrono::milliseconds(ms), [this] { return on_; });
	}
	bool touched_by(std::thread::id id) const
	{
		std::lock_guard<std::mutex> g(tm_);
		return touched_.count(id) != 0;
	}

private:
	void note()
	{
		std::lock_guard<std::mutex> g(tm_);
		touched_.insert(std::this_thread::get_id());
	}

	std::mutex m_;
	std::condition_variable cv_;
	bool on_ = false;
	mutable std::mutex tm_;
	std::set<std::thread::id> touched_;
};

using Life = coop::prefetch::Life<std::shared_mutex, TestEvent>;
using Exclusive = std::unique_lock<std::shared_mutex>;

// A door the prefetch of one model waits at: a test holds a batch in flight with it (no lock held, like a slow OGF load).
class Gate
{
public:
	void open()
	{
		std::lock_guard<std::mutex> g(m_);
		open_ = true;
		cv_.notify_all();
	}
	void pass()
	{
		std::unique_lock<std::mutex> g(m_);
		++inside_;
		cv_.notify_all();
		cv_.wait(g, [this] { return open_; });
	}
	bool wait_inside(uint32_t ms)
	{
		std::unique_lock<std::mutex> g(m_);
		return cv_.wait_for(g, std::chrono::milliseconds(ms), [this] { return inside_ > 0; });
	}

private:
	std::mutex m_;
	std::condition_variable cv_;
	bool open_ = false;
	int inside_ = 0;
};

struct Spawn
{
	int id;
	std::vector<std::string> models;
};

// The level's containers as the thread sees them (prefetch_events, prefetched_models, spawn_events), guarded by
// life.lock, plus a record of every touch.
struct Work
{
	using Batch = std::vector<Spawn>;

	explicit Work(Life& l) : life(l) {}

	Life& life;
	std::vector<Spawn> queue;
	std::set<std::string> known;
	std::vector<int> delivered;

	std::mutex rec_m;
	std::vector<std::string> prefetched;
	std::atomic<int> writes_while_closing{0}; // a container written after the owner said stop
	std::atomic<int> touches_after_free{0};   // a container touched after the owner freed them
	std::atomic<bool> freed{false};
	std::atomic<bool> closed{false};
	std::atomic<size_t> dropped{size_t(-1)};
	Gate* gate = nullptr; // the prefetch of `gated` waits at it
	std::string gated;
	bool jitter = false; // the prefetch takes a few microseconds (the stress test)
	std::function<void()> on_empty; // in the thread, under the lock, the queue found empty
	std::function<void()> on_take;  // in the thread, under the lock, before the queue is taken

	void touch()
	{
		if (freed)
			++touches_after_free;
	}
	bool empty_locked()
	{
		touch();
		if (!queue.empty())
			return false;
		if (on_empty)
			on_empty();
		return true;
	}
	void take_locked(Batch& batch)
	{
		touch();
		if (on_take)
			on_take();
		batch.swap(queue);
	}
	bool known_locked(const std::string& model)
	{
		touch();
		return known.count(model) != 0;
	}
	void prefetch(const std::string& model)
	{
		touch();
		{
			std::lock_guard<std::mutex> g(rec_m);
			prefetched.push_back(model);
		}
		if (gate && model == gated)
			gate->pass();
		else if (jitter)
			std::this_thread::sleep_for(std::chrono::microseconds(50));
	}
	void remember_locked(const std::string& model)
	{
		touch();
		if (life.closing)
			++writes_while_closing;
		known.insert(model);
	}
	void deliver_locked(Batch& batch)
	{
		touch();
		if (life.closing)
			++writes_while_closing;
		for (const Spawn& s : batch)
			delivered.push_back(s.id);
	}
	void leaving(size_t n)
	{
		touch();
		dropped = n;
		closed = true;
	}
	std::vector<std::string> prefetched_copy()
	{
		std::lock_guard<std::mutex> g(rec_m);
		return prefetched;
	}
};

// One level: its life, its containers, its thread.
struct Level
{
	Life life;
	Work work{life};
	std::thread th;

	void start()
	{
		th = std::thread([this] { coop::prefetch::run(life, work); });
	}
	// ProcessGameEvents: the batch goes into the queue and the thread is woken, under the lock.
	void push(Spawn s)
	{
		Exclusive g(life.lock);
		work.queue.push_back(std::move(s));
		coop::prefetch::wake_locked(life);
	}
	size_t delivered()
	{
		Exclusive g(life.lock);
		return work.delivered.size();
	}
	// After a test: makes the thread leave whatever the code under test did, and joins it. False: it did not leave.
	bool finish()
	{
		if (work.gate)
			work.gate->open();
		{
			Exclusive g(life.lock);
			life.closing = true;
		}
		const auto end = Clock::now() + std::chrono::seconds(5);
		while (!life.exited.wait(10))
		{
			{
				Exclusive g(life.lock);
				coop::prefetch::wake_locked(life);
				life.signal.set();
			}
			if (Clock::now() > end)
				break;
		}
		if (!th.joinable())
			return true;
		if (!life.exited.wait(0))
			return false;
		th.join();
		return true;
	}
};

// Owns a Level; frees it only when its thread has left (a thread that did not leave keeps it: leaked, detached).
class LevelPtr
{
public:
	LevelPtr() : p_(new Level) {}
	~LevelPtr()
	{
		if (p_->finish())
			delete p_;
		else
		{
			::t::report_failure(__FILE__, __LINE__, "the prefetch thread did not leave: the level is leaked");
			p_->th.detach();
		}
	}
	LevelPtr(const LevelPtr&) = delete;
	LevelPtr& operator=(const LevelPtr&) = delete;
	Level* operator->() const { return p_; }

private:
	Level* p_;
};

template <class Pred>
bool eventually(Pred pred, uint32_t ms = 5000)
{
	const auto end = Clock::now() + std::chrono::milliseconds(ms);
	while (!pred())
	{
		if (Clock::now() > end)
			return false;
		std::this_thread::sleep_for(std::chrono::milliseconds(1));
	}
	return true;
}

uint64_t ms_since(Clock::time_point t0)
{
	return uint64_t(std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - t0).count());
}
} // namespace

// The normal life: every model is prefetched once, each batch goes to the spawn queue, an idle thread stops at once.
TEST(prefetch_life_delivers_and_prefetches_once)
{
	LevelPtr L;
	L->start();
	L->push({1, {"a", "b"}});
	L->push({2, {"b", "c"}});
	CHECK(eventually([&] { return L->delivered() == 2; }));
	L->push({3, {"a"}});
	CHECK(eventually([&] { return L->delivered() == 3; }));

	std::vector<std::string> p = L->work.prefetched_copy();
	std::sort(p.begin(), p.end());
	CHECK_EQ(p.size(), size_t(3));
	CHECK(p == (std::vector<std::string>{"a", "b", "c"}));

	const auto t0 = Clock::now();
	CHECK(coop::prefetch::stop(L->life, 5000));
	CHECK(ms_since(t0) < 2000);
	CHECK(L->work.closed.load());
	CHECK_EQ(L->work.dropped.load(), size_t(0));
	CHECK_EQ(L->work.writes_while_closing.load(), 0);
}

// ~CLevel during a batch in flight: the stop waits until the thread has left the batch, the thread leaves after the
// model it is loading, and nothing of the batch reaches the containers.
TEST(prefetch_life_stop_waits_for_batch_in_flight)
{
	LevelPtr L;
	Gate gate;
	L->work.gate = &gate;
	L->work.gated = "b";
	L->start();
	L->push({1, {"a", "b", "c"}});
	L->push({2, {"d"}});
	// both may be taken at once or one by one: wait for the thread to stand in the load of "b"
	REQUIRE(gate.wait_inside(5000));

	std::atomic<int> result{-1};
	std::thread stopper([&] { result = coop::prefetch::stop(L->life, 10000) ? 1 : 0; });
	std::this_thread::sleep_for(std::chrono::milliseconds(200));
	CHECK_EQ(result.load(), -1); // still waiting: the thread is in the batch
	CHECK(!L->work.closed.load());
	gate.open();
	stopper.join();

	CHECK_EQ(result.load(), 1);
	CHECK(L->work.closed.load());
	CHECK(L->life.exited.wait(0));
	const std::vector<std::string> p = L->work.prefetched_copy();
	CHECK(std::find(p.begin(), p.end(), "c") == p.end()); // stopped after the model in flight
	CHECK(std::find(p.begin(), p.end(), "d") == p.end());
	{
		Exclusive g(L->life.lock);
		CHECK(L->work.known.count("b") == 0);
		CHECK(L->work.delivered.empty());
	}
	CHECK_EQ(L->work.writes_while_closing.load(), 0);
}

// The owner frees the containers only after the thread has left; the thread never touches them afterwards.
TEST(prefetch_life_no_touch_after_free)
{
	LevelPtr L;
	Gate gate;
	L->work.gate = &gate;
	L->work.gated = "b";
	L->start();
	L->push({1, {"a", "b"}});
	REQUIRE(gate.wait_inside(5000));

	std::thread opener([&] {
		std::this_thread::sleep_for(std::chrono::milliseconds(100));
		gate.open();
	});
	std::atomic<int> frees{0};
	const bool left = coop::prefetch::shutdown(L->life, 10000, [&] {
		++frees;
		L->work.freed = true;
	});
	opener.join();
	std::this_thread::sleep_for(std::chrono::milliseconds(50)); // a thread still alive would touch them now

	CHECK(left);
	CHECK_EQ(frees.load(), 1);
	CHECK(L->work.closed.load());
	CHECK_EQ(L->work.touches_after_free.load(), 0);
	CHECK_EQ(L->work.writes_while_closing.load(), 0);
	CHECK(L->work.delivered.empty());
}

// The stop comes while the thread, holding the lock, found the queue empty and is about to reset the signal: the
// reset must not swallow the stop (the stock thread then waited for ever).
TEST(prefetch_life_stop_before_empty_pause_not_lost)
{
	LevelPtr L;
	std::thread stopper;
	std::atomic<bool> started{false};
	std::atomic<int> result{-1};
	L->work.on_empty = [&] {
		if (started.exchange(true))
			return;
		stopper = std::thread([&] { result = coop::prefetch::stop(L->life, 3000) ? 1 : 0; });
		std::this_thread::sleep_for(std::chrono::milliseconds(100)); // the stopper reaches the lock meanwhile
	};
	L->start();
	{
		Exclusive g(L->life.lock);
		coop::prefetch::wake_locked(L->life); // a signal with an empty queue
	}
	REQUIRE(eventually([&] { return started.load(); }));
	REQUIRE(eventually([&] { return result.load() != -1; }, 10000));
	stopper.join();
	CHECK_EQ(result.load(), 1);
	CHECK(L->life.exited.wait(3000));
	CHECK(L->work.closed.load());
}

// The same race at the other reset: the stop comes while the thread takes the queue (exclusive lock). The load of "a"
// waits until the stop is in (an SRW lock is not fair: the thread could otherwise win it back and deliver first).
TEST(prefetch_life_stop_during_take_not_lost)
{
	LevelPtr L;
	Gate gate;
	L->work.gate = &gate;
	L->work.gated = "a";
	std::thread stopper;
	std::atomic<bool> started{false};
	std::atomic<int> result{-1};
	L->work.on_take = [&] {
		if (started.exchange(true))
			return;
		stopper = std::thread([&] { result = coop::prefetch::stop(L->life, 3000) ? 1 : 0; });
		std::this_thread::sleep_for(std::chrono::milliseconds(100));
	};
	L->start();
	L->push({1, {"a"}});
	REQUIRE(eventually([&] { return started.load(); }));
	CHECK(eventually([&] {
		std::shared_lock<std::shared_mutex> g(L->life.lock);
		return L->life.closing;
	}));
	gate.open();
	REQUIRE(eventually([&] { return result.load() != -1; }, 10000));
	stopper.join();
	CHECK_EQ(result.load(), 1);
	CHECK(L->life.exited.wait(3000));
	CHECK(L->work.closed.load());
	CHECK_EQ(L->work.dropped.load(), size_t(1));
	CHECK_EQ(L->work.writes_while_closing.load(), 0);
	Exclusive g(L->life.lock);
	CHECK(L->work.known.empty());
	CHECK(L->work.delivered.empty());
}

// A level change: the next level is built while the old one's batch is in flight. Each thread waits on and resets only
// its own level's events; the new level keeps working after the old one is gone.
TEST(prefetch_life_levels_have_own_events)
{
	LevelPtr A;
	Gate gate;
	A->work.gate = &gate;
	A->work.gated = "x";
	A->start();
	A->push({1, {"x"}});
	REQUIRE(gate.wait_inside(5000));

	LevelPtr B;
	B->start();
	B->push({7, {"y"}});
	CHECK(eventually([&] { return B->delivered() == 1; }));

	std::atomic<int> okA{-1};
	std::thread stopper([&] { okA = coop::prefetch::stop(A->life, 10000) ? 1 : 0; });
	std::this_thread::sleep_for(std::chrono::milliseconds(50));
	gate.open();
	stopper.join();
	CHECK_EQ(okA.load(), 1);
	CHECK(A->life.exited.wait(3000));

	B->push({8, {"z"}});
	CHECK(eventually([&] { return B->delivered() == 2; }));

	const std::thread::id ta = A->th.get_id();
	const std::thread::id tb = B->th.get_id();
	CHECK(!B->life.signal.touched_by(ta));
	CHECK(!B->life.exited.touched_by(ta));
	CHECK(!A->life.signal.touched_by(tb));
	CHECK(!A->life.exited.touched_by(tb));
	{
		Exclusive g(A->life.lock);
		CHECK(A->work.delivered.empty());
	}
	CHECK(coop::prefetch::stop(B->life, 5000));
	CHECK(B->work.closed.load());
}

// The thread does not leave in time (a load that hangs): nothing is freed, the owner leaks it all; when the thread
// finally leaves it still writes nothing.
TEST(prefetch_life_timeout_leaks)
{
	LevelPtr L;
	Gate gate;
	L->work.gate = &gate;
	L->work.gated = "a";
	L->start();
	L->push({1, {"a"}});
	REQUIRE(gate.wait_inside(5000));

	std::atomic<int> frees{0};
	const auto t0 = Clock::now();
	const bool left = coop::prefetch::shutdown(L->life, 150, [&] {
		++frees;
		L->work.freed = true;
	});
	CHECK(!left);
	CHECK_EQ(frees.load(), 0);
	CHECK(ms_since(t0) >= 140);
	CHECK(!L->work.closed.load());

	gate.open();
	CHECK(L->life.exited.wait(5000));
	CHECK(L->work.closed.load());
	CHECK_EQ(L->work.writes_while_closing.load(), 0);
	Exclusive g(L->life.lock);
	CHECK(L->work.known.empty());
	CHECK(L->work.delivered.empty());
}

// Stops at random moments of a busy thread: it always leaves, never writes after the stop or touches after the free,
// and every event is either delivered, dropped with the batch in flight, or still in the queue.
TEST(prefetch_life_stress_stop_anywhere)
{
	std::mt19937 rng(20261108);
	const char* const pool[] = {"m0", "m1", "m2", "m3", "m4", "m5"};
	int failures = 0;
	for (int round = 0; round < 150 && failures == 0; ++round)
	{
		LevelPtr L;
		L->work.jitter = true;
		L->start();
		const int batches = int(rng() % 6);
		int pushed = 0;
		for (int b = 0; b < batches; ++b)
		{
			L->push({pushed++, {pool[rng() % 6], pool[rng() % 6]}});
			if (rng() % 2)
				std::this_thread::sleep_for(std::chrono::microseconds(rng() % 300));
		}
		const bool left = coop::prefetch::shutdown(L->life, 5000, [&] { L->work.freed = true; });
		std::this_thread::yield();
		size_t accounted = 0;
		{
			Exclusive g(L->life.lock);
			accounted = L->work.delivered.size() + L->work.queue.size();
		}
		const size_t dropped = L->work.dropped.load();
		if (!left || !L->work.closed.load() || L->work.touches_after_free.load() != 0 ||
			L->work.writes_while_closing.load() != 0 || accounted + dropped != size_t(pushed))
		{
			++failures;
			CHECK(left);
			CHECK(L->work.closed.load());
			CHECK_EQ(L->work.touches_after_free.load(), 0);
			CHECK_EQ(L->work.writes_while_closing.load(), 0);
			CHECK_EQ(accounted + dropped, size_t(pushed));
		}
	}
	CHECK_EQ(failures, 0);
}
