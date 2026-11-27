// RayLink unit tests: the heap walk of xrMemory::mem_usage (engine/src/xrCore/heap_walk.h).
// An unlocked walk on the stat_memory_async thread never returned while the main thread loaded and kept mem_lock; the
// main thread then hung in IGame_Persistent::Prefetch on mem_lock. The walk now holds the heap's own lock.
// Every test works on a private heap, so the CRT heap of the test runner is never locked.
#include "test_util.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include "../engine/src/xrCore/heap_walk.h"

#include <atomic>

namespace
{
// Larger than the low-fragmentation front end serves: such a block always goes through the heap's lock.
constexpr size_t kBigBlock = 64 * 1024;

struct PrivateHeap
{
	HANDLE h = HeapCreate(0, 0, 0);
	~PrivateHeap()
	{
		if (h)
			HeapDestroy(h);
	}
};
} // namespace

TEST(heap_walk_counts_the_busy_blocks)
{
	PrivateHeap heap;
	REQUIRE(heap.h != nullptr);
	const xr_heap::WalkResult empty = xr_heap::used_bytes(heap.h);
	CHECK(empty.complete);
	void* a = HeapAlloc(heap.h, 0, 1000);
	void* b = HeapAlloc(heap.h, 0, kBigBlock);
	REQUIRE(a != nullptr);
	REQUIRE(b != nullptr);
	const xr_heap::WalkResult full = xr_heap::used_bytes(heap.h);
	CHECK(full.complete);
	CHECK_EQ(full.error, static_cast<unsigned long>(ERROR_NO_MORE_ITEMS));
	CHECK(full.used >= empty.used + 1000 + kBigBlock);
	HeapFree(heap.h, 0, b);
	const xr_heap::WalkResult freed = xr_heap::used_bytes(heap.h);
	CHECK(freed.complete);
	CHECK(freed.used + kBigBlock <= full.used);
	HeapFree(heap.h, 0, a);
}

// Fails on a walk without HeapLock: the other thread's allocation then finishes while the walk is still running.
TEST(heap_walk_holds_the_heap_lock_while_it_walks)
{
	PrivateHeap heap;
	REQUIRE(heap.h != nullptr);
	void* keep = HeapAlloc(heap.h, 0, 1000);
	REQUIRE(keep != nullptr);

	std::atomic<bool> allocated{false};
	std::atomic<void*> other{nullptr};
	bool allocated_during_walk = true;
	bool first = true;
	std::thread allocator;
	const xr_heap::WalkResult walk = xr_heap::walk_locked(heap.h, [&](const PROCESS_HEAP_ENTRY&) {
		if (!first)
			return;
		first = false;
		allocator = std::thread([&] {
			other.store(HeapAlloc(heap.h, 0, kBigBlock));
			allocated.store(true);
		});
		std::this_thread::sleep_for(std::chrono::milliseconds(300));
		allocated_during_walk = allocated.load();
	});
	REQUIRE(allocator.joinable());
	allocator.join();
	CHECK(walk.complete);
	CHECK(!allocated_during_walk);
	CHECK(allocated.load());
	CHECK(other.load() != nullptr);
	HeapFree(heap.h, 0, other.load());
	HeapFree(heap.h, 0, keep);
}
