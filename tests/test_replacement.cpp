#include "test_util.h"
#include "coop_replacement.h"
#include "coop_id_lease.h"

using namespace coop;

TEST(replacement_uncertain_timeout_keeps_the_source_fenced)
{
	lease::SpecBook book;
	book.add(900, 800);
	uint64_t now = 0;
	for (uint32_t seq = 1; seq < 20; ++seq)
	{
		book.sent(900, seq, now);
		now += lease::kAnswerTimeoutMs;
		const auto due = book.due(now);
		CHECK(due.rollback.empty());
		CHECK_EQ(due.resend.size(), 1u);
		CHECK(book.pending(900));
	}
}

TEST(replacement_envelope_round_trip_and_whole_size_limit)
{
	replacement::Snapshot value;
	value.source = 800;
	value.target = 900;
	value.nonce = 123;
	value.source_name = "wpn_ak74m800";
	value.metadata = "{s5:parts{s6:barreln97;s7:triggern41;}}";
	value.native = {1, 1, 2, 3};
	std::vector<uint8_t> bytes;
	REQUIRE(replacement::encode(value, bytes));
	replacement::Snapshot decoded;
	REQUIRE(replacement::decode(bytes.data(), bytes.size(), decoded));
	CHECK_EQ(decoded.source, 800);
	CHECK_EQ(decoded.target, 900);
	CHECK_EQ(decoded.nonce, 123u);
	CHECK_EQ(decoded.metadata, value.metadata);
	CHECK(decoded.native == value.native);
	const size_t overhead = bytes.size() - value.metadata.size();
	value.metadata.assign(kMaxItemState - overhead - 1, 'x'); // extra varint byte for the longer string
	REQUIRE(replacement::encode(value, bytes));
	CHECK_EQ(bytes.size(), kMaxItemState);
	value.metadata.push_back('x');
	CHECK(!replacement::encode(value, bytes));
	CHECK(bytes.empty());
}

TEST(replacement_envelope_refuses_truncation_trailing_bytes_and_invalid_identity)
{
	replacement::Snapshot value;
	value.source = 800;
	value.target = 900;
	value.nonce = 123;
	value.metadata = "{}";
	value.native = {1};
	std::vector<uint8_t> bytes;
	REQUIRE(replacement::encode(value, bytes));
	replacement::Snapshot decoded;
	for (size_t n = 0; n < bytes.size(); ++n)
		CHECK(!replacement::decode(bytes.data(), n, decoded));
	bytes.push_back(0);
	CHECK(!replacement::decode(bytes.data(), bytes.size(), decoded));
	value.nonce = 0;
	CHECK(!replacement::encode(value, bytes));
}
