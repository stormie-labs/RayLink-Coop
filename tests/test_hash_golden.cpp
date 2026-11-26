// Anomaly Coop unit tests: the FNV-1a results of every place that hashes a name or a state, pinned byte for byte.
// The values are what each place computed before it moved onto xrCoop/coop_hash.h; a digest or a wire tag that changes
// by one bit makes the two ends of a session disagree forever, so these stay fixed numbers, not recomputed ones.
#include "test_util.h"

#include "coop_gear.h"
#include "coop_hash.h"
#include "coop_item_tags.h"
#include "coop_protocol.h"
#include "coop_reconcile.h"
#include "coop_session.h"
#include "coop_zone_path_rules.h"
#include "srv/coop_levels_audit.h"
#include "srv/coop_levels_logic.h"
#include "srv/coop_levels_wire.h"
#include "srv/coop_xfer_base.h"

#include <cstdint>
#include <vector>

using namespace coop;

namespace
{
const std::vector<uint8_t> kState = {1, 2, 3, 250, 0, 7, 9};

struct ItemState
{
	bool has_cond = true;
	uint16_t cond = 500;
	bool has_box = true;
	uint16_t box = 3;
	bool has_addons = true;
	uint8_t addons = 5;
	bool has_main = true;
	uint8_t main_count = 2;
	uint8_t main_type = 1;
	bool has_uses = true;
	uint8_t uses = 4;
};
} // namespace

TEST(hash_golden_fnv1a32_of_names)
{
	CHECK_EQ(fnv1a32(""), 0x811c9dc5u);
	CHECK_EQ(fnv1a32(static_cast<const char*>(nullptr)), 0x811c9dc5u);
	CHECK_EQ(fnv1a32("wpn_ak74"), 0x7a01e3a2u);
	CHECK_EQ(fnv1a32(std::string_view("af_medusa")), 0x12802c9eu);
	CHECK_EQ(fold16(0x7a01e3a2u), uint16_t(0x99a3));
	CHECK_EQ(fnv1a64(kState.data(), kState.size()), 0x20a6ffd77471d2c9ull);
}

TEST(hash_golden_section_tags_and_kinds)
{
	CHECK_EQ(gear::tag_of("wpn_ak74"), uint16_t(0x99a3));
	CHECK_EQ(gear::tag_of(""), uint16_t(0x1cd9));
	CHECK_EQ(gear::tag_of(nullptr), uint16_t(0x1cd9));
	CHECK_EQ(levels::journal::section_crc("stalker_hero_1"), uint16_t(0x50b7));
	CHECK_EQ(levels::journal::section_crc(""), uint16_t(0x1cd9));
	CHECK_EQ(reconcile::kind_of("bread"), uint16_t(0xb781));
	CHECK_EQ(reconcile::kind_of(nullptr), uint16_t(0x1cd9));
	CHECK_EQ(zonepath::name_hash("af_medusa"), 0x12802c9eu);
	CHECK_EQ(zonepath::name_hash(nullptr), 0x811c9dc5u);
}

TEST(hash_golden_state_digests)
{
	CHECK_EQ(levels::logic::digest(kState.data(), kState.size()), 0x20a6ffd77471d2c9ull);
	CHECK_EQ(levels::logic::digest(kState.data(), kState.size(), 2), 0xb262baa57dbe8abcull);
	CHECK_EQ(levels::logic::digest(nullptr, 0), 0xcbf29ce484222325ull);
	CHECK_EQ(xfer::digest(kState), 0x20a6ffd77471d2c9ull);
	CHECK_EQ(xfer::digest({}), 0xcbf29ce484222325ull);
	CHECK_EQ(srv::members_digest({300, 5, 300, 65535, 0x0102}), 0x4a00bfabd66f5ee4ull);
	CHECK_EQ(srv::members_digest({}), uint64_t(0));
	CHECK_EQ(manifest_fingerprint(t::sample_manifest()), 0x9da6e738f99883e5ull);

	ItemState d;
	CHECK_EQ(itemtags::state_digest(d, true), 0x6b1ae45fu);
	ItemState none;
	none.has_cond = none.has_box = none.has_addons = none.has_main = none.has_uses = false;
	CHECK_EQ(itemtags::state_digest(none, false), 0xddbcf9b1u);

	PlayerKey key{};
	for (size_t i = 0; i < key.size(); ++i)
		key[i] = uint8_t(i);
	CHECK_EQ(player_key_hash(key), 0xc8fff215u);
}
