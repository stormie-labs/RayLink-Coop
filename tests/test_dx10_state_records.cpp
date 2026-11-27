// RayLink unit tests: the records of the renderer's D3D state caches (engine/src/Layers/xrRenderDX10/StateManager/
// dx10StateRecords.h). A failed CreateSamplerState left a record with a null state; the next shader with the same state
// hash called GetDesc through it (an access violation reading the address 0 in dx10SamplerStateCache::FindState). The
// cache code of the renderer runs these same two functions over its records.
#include "test_util.h"

#include "../engine/src/Layers/xrRenderDX10/StateManager/dx10StateRecords.h"

#include <vector>

namespace
{
struct FakeDesc
{
	int filter = 0;
};

struct FakeState
{
	FakeDesc desc;
	mutable int asked = 0;
	void GetDesc(FakeDesc* out) const
	{
		++asked;
		*out = desc;
	}
};

struct Record
{
	unsigned int m_crc;
	FakeState* m_pState;
};

bool same(const FakeDesc& a, const FakeDesc& b)
{
	return a.filter == b.filter;
}

const long kOutOfMemory = static_cast<long>(0x8007000EUL); // E_OUTOFMEMORY
} // namespace

TEST(dx10_state_records_find_passes_over_a_record_without_a_state)
{
	FakeState live;
	live.desc.filter = 7;
	std::vector<Record> records = {{42u, nullptr}, {42u, &live}};
	FakeDesc want;
	want.filter = 7;
	CHECK_EQ(dx10_state_records::find(records, want, 42u, same), size_t(1));
	CHECK_EQ(live.asked, 1);

	std::vector<Record> only_lost = {{42u, nullptr}};
	CHECK_EQ(dx10_state_records::find(only_lost, want, 42u, same), dx10_state_records::not_found);
}

TEST(dx10_state_records_find_matches_hash_and_description)
{
	FakeState a, b;
	a.desc.filter = 1;
	b.desc.filter = 2;
	std::vector<Record> records = {{5u, &a}, {5u, &b}, {6u, &a}};
	FakeDesc want;
	want.filter = 2;
	CHECK_EQ(dx10_state_records::find(records, want, 5u, same), size_t(1)); // same hash, the description decides
	CHECK_EQ(dx10_state_records::find(records, want, 7u, same), dx10_state_records::not_found);
	CHECK_EQ(b.asked, 1);
}

TEST(dx10_state_records_a_failed_create_keeps_no_record)
{
	std::vector<Record> records;
	const dx10_state_records::Added failed = dx10_state_records::add(records, 42u, [](FakeState** out) {
		*out = nullptr;
		return kOutOfMemory;
	});
	CHECK_EQ(failed.index, dx10_state_records::not_found);
	CHECK_EQ(failed.code, kOutOfMemory);
	CHECK_EQ(records.size(), size_t(0));

	// a success answer without an object is no state either
	const dx10_state_records::Added empty = dx10_state_records::add(records, 42u, [](FakeState** out) {
		*out = nullptr;
		return 0L;
	});
	CHECK_EQ(empty.index, dx10_state_records::not_found);
	CHECK_EQ(records.size(), size_t(0));
}

// The client of the stand: the first create of a state fails, a later shader with the same state asks again and gets it.
TEST(dx10_state_records_the_next_shader_with_that_state_asks_the_device_again)
{
	std::vector<Record> records;
	FakeState made;
	made.desc.filter = 3;
	FakeDesc want;
	want.filter = 3;
	int creates = 0;
	auto device = [&](FakeState** out) {
		++creates;
		*out = creates == 1 ? nullptr : &made;
		return creates == 1 ? kOutOfMemory : 0L;
	};

	CHECK_EQ(dx10_state_records::find(records, want, 9u, same), dx10_state_records::not_found);
	CHECK_EQ(dx10_state_records::add(records, 9u, device).index, dx10_state_records::not_found);

	CHECK_EQ(dx10_state_records::find(records, want, 9u, same), dx10_state_records::not_found); // no null record met
	const dx10_state_records::Added added = dx10_state_records::add(records, 9u, device);
	CHECK_EQ(added.index, size_t(0));
	CHECK_EQ(added.code, 0L);
	CHECK(records[0].m_pState == &made);
	CHECK_EQ(records[0].m_crc, 9u);
	CHECK_EQ(dx10_state_records::find(records, want, 9u, same), size_t(0));
	CHECK_EQ(creates, 2);
}

TEST(dx10_state_records_failure_lines_are_bounded)
{
	CHECK(!dx10_state_records::log_failure(0));
	for (unsigned int count = 1; count <= 8; ++count)
		CHECK(dx10_state_records::log_failure(count));
	CHECK(!dx10_state_records::log_failure(9));
	CHECK(!dx10_state_records::log_failure(999));
	CHECK(dx10_state_records::log_failure(1000));
	CHECK(!dx10_state_records::log_failure(1001));
	CHECK(dx10_state_records::log_failure(5000));
}
