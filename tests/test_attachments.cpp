// Real wire/helper regressions; the fake world supplies only engine effects.
#include "test_util.h"
#include "coop_attachments.h"

#include <algorithm>
#include <limits>
#include <map>

using coop::Reader;
using coop::Writer;
namespace att = coop::attachments;

namespace
{
att::Item descriptor(uint16_t id, std::string bone = "bip01_r_hand")
{
    att::Item item;
    item.id = id;
    item.bone = std::move(bone);
    item.angles[0] = .25f;
    item.angles[1] = -1.5f;
    item.angles[2] = 2.f;
    item.position[0] = -.125f;
    item.position[1] = .5f;
    item.position[2] = 3.f;
    return item;
}

att::State state(std::initializer_list<att::Item> items)
{
    att::State out;
    out.items = items;
    return out;
}

// Deliberately bypass State::write so invalid input can reach the real decoder.
void raw_item(Writer& w, const att::Item& item)
{
    w.u16(item.id);
    w.str(item.bone);
    w.vec3(item.angles);
    w.vec3(item.position);
}

Writer raw_state(const std::vector<att::Item>& items)
{
    Writer w;
    w.u8(static_cast<uint8_t>(items.size()));
    for (const auto& item : items)
        raw_item(w, item);
    return w;
}

void rejected_unchanged(const Writer& w)
{
    const auto before = state({descriptor(500, "previous_bone")});
    auto out = before;
    Reader r(w.ptr(), w.size());
    CHECK(!out.read(r));
    CHECK(out == before);
}

struct Entity
{
    uint16_t owner = 700;
    bool enabled = false;
    att::Item applied;
};

struct World
{
    std::map<uint16_t, Entity> entities;
    std::vector<int> calls; // Negative IDs are detach, positive IDs are attach attempts.

    std::vector<uint16_t> enabled() const
    {
        std::vector<uint16_t> ids;
        for (const auto& entry : entities)
            if (entry.second.owner == 700 && entry.second.enabled)
                ids.push_back(entry.first);
        return ids;
    }

    bool apply(const att::State& want)
    {
        const auto actual = enabled();
        return att::reconcile(want, actual,
            [this](uint16_t id) {
                calls.push_back(-static_cast<int>(id));
                entities.at(id).enabled = false;
            },
            [this](const att::Item& item) {
                calls.push_back(item.id);
                auto found = entities.find(item.id);
                if (found == entities.end() || found->second.owner != 700 ||
                    (item.bone != "bip01_r_hand" && item.bone != "bip01_l_hand"))
                    return false;
                found->second.applied = item;
                found->second.enabled = true;
                return true;
            });
    }
};
} // namespace

TEST(attachments_present_disabled_bottle_becomes_attached_with_offsets)
{
    World world;
    world.entities.emplace(uint16_t(10), Entity{});
    const auto bottle = descriptor(10);
    CHECK(world.apply(state({bottle})));
    CHECK(world.entities.at(10).enabled);
    CHECK(world.entities.at(10).applied == bottle);
    CHECK(world.enabled() == std::vector<uint16_t>({10}));
}

TEST(attachments_missing_first_item_does_not_block_others_and_retries)
{
    World world;
    world.entities.emplace(uint16_t(11), Entity{});
    const auto want = state({descriptor(10), descriptor(11, "bip01_l_hand")});
    CHECK(!world.apply(want));
    CHECK_EQ(world.entities.size(), size_t(1)); // No fabricated entity for ID 10.
    CHECK(world.entities.at(11).enabled);
    CHECK(world.calls == std::vector<int>({10, 11}));
    world.entities.emplace(uint16_t(10), Entity{}); // The entity arrives on a later snapshot.
    world.calls.clear();
    CHECK(world.apply(want));
    CHECK(world.enabled() == std::vector<uint16_t>({10, 11}));
    CHECK(world.calls == std::vector<int>({10, 11}));
}

TEST(attachments_ownership_mismatch_does_not_attach_then_recovers)
{
    World world;
    Entity foreign;
    foreign.owner = 701;
    world.entities.emplace(uint16_t(10), foreign);
    const auto want = state({descriptor(10)});
    CHECK(!world.apply(want));
    CHECK(!world.entities.at(10).enabled);
    CHECK_EQ(world.entities.at(10).owner, uint16_t(701));
    world.entities.at(10).owner = 700;
    CHECK(world.apply(want));
    CHECK(world.entities.at(10).enabled);
}

TEST(attachments_missing_local_bone_does_not_enable_existing_item)
{
    World world;
    world.entities.emplace(uint16_t(10), Entity{});
    CHECK(!world.apply(state({descriptor(10, "missing_bone")})));
    CHECK(!world.entities.at(10).enabled);
    CHECK(world.apply(state({descriptor(10)})));
    CHECK(world.entities.at(10).enabled);
}

TEST(attachments_complete_empty_state_detaches_removed_or_disabled_items)
{
    World world;
    Entity attached;
    attached.enabled = true;
    world.entities.emplace(uint16_t(10), attached);
    world.entities.emplace(uint16_t(11), Entity{});
    Entity foreign = attached;
    foreign.owner = 701;
    world.entities.emplace(uint16_t(12), foreign);
    CHECK(world.apply(att::State{}));
    CHECK(world.enabled().empty());
    CHECK(!world.entities.at(10).enabled);
    CHECK(!world.entities.at(11).enabled);
    CHECK(world.entities.at(12).enabled);
    CHECK(world.calls == std::vector<int>({-10}));
    world.calls.clear();
    CHECK(world.apply(att::State{}));
    CHECK(world.calls.empty());
}

TEST(attachments_switch_beer_to_cigarette_detaches_before_attach_and_repeats)
{
    World world;
    Entity beer;
    beer.enabled = true;
    world.entities.emplace(uint16_t(10), beer);
    world.entities.emplace(uint16_t(11), Entity{});
    const auto cigarette = descriptor(11, "bip01_l_hand");
    const auto want = state({cigarette});
    CHECK(world.apply(want));
    CHECK(world.calls == std::vector<int>({-10, 11}));
    CHECK(world.enabled() == std::vector<uint16_t>({11}));
    CHECK(world.entities.at(11).applied == cigarette);
    world.calls.clear();
    CHECK(world.apply(want));
    CHECK(world.enabled() == std::vector<uint16_t>({11}));
    CHECK(world.calls == std::vector<int>({11})); // Desired descriptors are always reapplied.
    world.entities.at(11).enabled = false;
    CHECK(world.apply(want)); // Same snapshot heals a locally disabled attachment.
    CHECK(world.entities.at(11).enabled);
}

TEST(attachments_incomplete_preserves_actual_without_any_callbacks)
{
    World world;
    Entity attached;
    attached.enabled = true;
    attached.applied = descriptor(10);
    world.entities.emplace(uint16_t(10), attached);
    att::State incomplete;
    incomplete.complete = false;
    CHECK(!world.apply(incomplete));
    CHECK(world.calls.empty());
    CHECK(world.entities.at(10).enabled);
    CHECK(world.entities.at(10).applied == attached.applied);
    incomplete.items.push_back(descriptor(11));
    CHECK(!world.apply(incomplete));
    CHECK(world.calls.empty());
    CHECK_EQ(world.entities.size(), size_t(1));
}

TEST(attachments_guitar_and_harmonica_can_both_be_desired)
{
    World world;
    world.entities.emplace(uint16_t(20), Entity{});
    world.entities.emplace(uint16_t(21), Entity{});
    const auto want = state({descriptor(20), descriptor(21, "bip01_l_hand")});
    CHECK(want.valid());
    CHECK(world.apply(want));
    CHECK(world.enabled() == std::vector<uint16_t>({20, 21}));
    CHECK(world.entities.at(20).applied == want.items[0]);
    CHECK(world.entities.at(21).applied == want.items[1]);
}

TEST(attachments_item_validation_bounds_and_nonfinite_components)
{
    CHECK(!att::Item{}.valid());
    CHECK(descriptor(1).valid());
    CHECK(descriptor(0xfffe).valid());
    CHECK(!descriptor(0).valid());
    CHECK(!descriptor(0xffff).valid());
    CHECK(!descriptor(1, "").valid());
    CHECK(descriptor(1, std::string(63, 'x')).valid());
    CHECK(!descriptor(1, std::string(64, 'x')).valid());
    for (unsigned int c = 0; c <= 0x7f; ++c)
    {
        const bool printable = c >= 0x20 && c != 0x7f;
        CHECK_EQ(descriptor(1, std::string(1, static_cast<char>(c))).valid(), printable);
    }
    for (const float bad : {std::numeric_limits<float>::quiet_NaN(),
             std::numeric_limits<float>::infinity(), -std::numeric_limits<float>::infinity()})
        for (size_t axis = 0; axis < 3; ++axis)
        {
            auto item = descriptor(1);
            item.angles[axis] = bad;
            CHECK(!item.valid());
            item = descriptor(1);
            item.position[axis] = bad;
            CHECK(!item.valid());
        }
    auto large = descriptor(1);
    large.angles[2] = std::numeric_limits<float>::max();
    large.position[1] = std::numeric_limits<float>::lowest();
    CHECK(large.valid());
}

TEST(attachments_state_validation_limits_duplicates_and_incomplete)
{
    att::State want;
    CHECK(want.valid());
    want.complete = false;
    CHECK(want.valid());
    want.items.push_back(descriptor(1));
    CHECK(!want.valid());
    want.complete = true;
    CHECK(want.valid());
    want.items.push_back(descriptor(1, "another_bone"));
    CHECK(!want.valid());
    want.items.clear();
    for (uint16_t id = 1; id <= 8; ++id)
        want.items.push_back(descriptor(id));
    CHECK(want.valid());
    want.items.push_back(descriptor(9));
    CHECK(!want.valid());
    want.items.resize(1);
    want.items[0].bone.clear();
    CHECK(!want.valid());
}

TEST(attachments_equality_covers_completeness_order_and_every_descriptor_field)
{
    const auto original = state({descriptor(1), descriptor(2)});
    CHECK(original == original);
    auto changed = original;
    changed.complete = false;
    CHECK(!(changed == original));
    changed = original;
    std::swap(changed.items[0], changed.items[1]);
    CHECK(!(changed == original));
    changed = original;
    changed.items.pop_back();
    CHECK(!(changed == original));
    auto item = original.items[0];
    item.id = 3;
    CHECK(!(item == original.items[0]));
    item = original.items[0];
    item.bone = "other";
    CHECK(!(item == original.items[0]));
    for (size_t axis = 0; axis < 3; ++axis)
    {
        changed = original;
        changed.items[1].angles[axis] += 1.f;
        CHECK(!(changed == original));
        changed = original;
        changed.items[1].position[axis] += 1.f;
        CHECK(!(changed == original));
    }
}

TEST(attachments_wire_literal_layout_and_following_field)
{
    auto item = descriptor(0x1234, "b");
    item.angles[0] = 1.f; item.angles[1] = -2.f; item.angles[2] = 0.f;
    item.position[0] = .5f; item.position[1] = -.5f; item.position[2] = 4.f;
    const std::vector<uint8_t> bytes = {
        1, 0x34, 0x12, 1, 'b',
        0, 0, 0x80, 0x3f, 0, 0, 0, 0xc0, 0, 0, 0, 0,
        0, 0, 0, 0x3f, 0, 0, 0, 0xbf, 0, 0, 0x80, 0x40};
    const auto want = state({item});
    Writer w;
    want.write(w);
    CHECK(w.data() == bytes);
    w.u8(0x5a);
    Reader r(w.ptr(), w.size());
    att::State out;
    REQUIRE(out.read(r));
    CHECK(out == want);
    CHECK_EQ(r.remaining(), size_t(1));
    CHECK_EQ(r.u8(), uint8_t(0x5a));
    Reader literal(bytes.data(), bytes.size());
    REQUIRE(out.read(literal));
    CHECK(out == want);
}

TEST(attachments_wire_roundtrips_all_counts_with_maximum_721_byte_state)
{
    for (uint16_t count = 0; count <= 8; ++count)
    {
        att::State want;
        for (uint16_t id = 1; id <= count; ++id)
            want.items.push_back(descriptor(id, std::string(63, 'x')));
        Writer w;
        want.write(w);
        CHECK_EQ(w.size(), size_t(1 + 90 * count));
        CHECK(w.size() <= 721);
        Reader r(w.ptr(), w.size());
        auto out = state({descriptor(400)});
        REQUIRE(out.read(r));
        CHECK(out.valid());
        CHECK(out == want);
        CHECK_EQ(r.remaining(), size_t(0));
    }
}

TEST(attachments_wire_empty_and_incomplete_have_distinct_single_byte_markers)
{
    for (const bool complete : {true, false})
    {
        att::State want;
        want.complete = complete;
        Writer w;
        want.write(w);
        CHECK(w.data() == std::vector<uint8_t>({uint8_t(complete ? 0 : 255)}));
        w.u8(0x5a);
        Reader r(w.ptr(), w.size());
        auto out = state({descriptor(400)});
        REQUIRE(out.read(r));
        CHECK_EQ(out.complete, complete);
        CHECK(out.items.empty());
        CHECK(out.valid());
        CHECK_EQ(r.u8(), uint8_t(0x5a));
    }
}

TEST(attachments_wire_every_truncation_preserves_previous_complete_or_incomplete_state)
{
    att::State want;
    for (uint16_t id = 1; id <= 8; ++id)
        want.items.push_back(descriptor(id, std::string(63, 'x')));
    const Writer w = raw_state(want.items);
    for (const bool complete : {true, false})
        for (size_t cut = 0; cut < w.size(); ++cut)
        {
            auto before = state({descriptor(400)});
            before.complete = complete;
            if (!complete)
                before.items.clear();
            auto out = before;
            Reader r(w.ptr(), cut);
            CHECK(!out.read(r));
            CHECK(out == before);
        }
}

TEST(attachments_wire_rejects_every_reserved_count_without_mutating_state)
{
    for (unsigned int count = 9; count < 255; ++count)
    {
        Writer w;
        w.u8(static_cast<uint8_t>(count));
        rejected_unchanged(w);
    }
}

TEST(attachments_wire_rejects_invalid_ids_and_duplicate_ids_atomically)
{
    rejected_unchanged(raw_state({descriptor(0)}));
    rejected_unchanged(raw_state({descriptor(0xffff)}));
    rejected_unchanged(raw_state({descriptor(1), descriptor(1, "another_bone")}));
    rejected_unchanged(raw_state({descriptor(1), descriptor(2), descriptor(1)}));
}

TEST(attachments_wire_rejects_empty_oversized_nul_and_control_bones_atomically)
{
    rejected_unchanged(raw_state({descriptor(1, "")}));
    rejected_unchanged(raw_state({descriptor(1, std::string(64, 'x'))}));
    rejected_unchanged(raw_state({descriptor(1, std::string(65536, 'x'))}));
    for (unsigned int c = 0; c <= 0x7f; ++c)
        if (c < 0x20 || c == 0x7f)
        {
            std::string bone = "bip01";
            bone.push_back(static_cast<char>(c));
            bone += "hand";
            rejected_unchanged(raw_state({descriptor(1), descriptor(2, bone)}));
        }
}

TEST(attachments_wire_rejects_huge_truncated_and_noncanonical_varu_without_allocation)
{
    const std::vector<std::vector<uint8_t>> lengths = {
        {0x80}, {0xff}, {0xff, 0x7f}, {0x80, 0x80, 0x04},
        {0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01},
        {0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x02},
        {0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0},
        {0x81, 0}, {0xbf, 0}};
    for (const auto& length : lengths)
    {
        Writer w;
        w.u8(1); w.u16(1); w.bytes(length.data(), length.size());
        if (length == std::vector<uint8_t>({0x81, 0}) || length == std::vector<uint8_t>({0xbf, 0}))
        {
            const auto item = descriptor(1, std::string(length.front() & 0x7f, 'x'));
            w.bytes(item.bone.data(), item.bone.size());
            w.vec3(item.angles); w.vec3(item.position);
        }
        rejected_unchanged(w);
    }
}

TEST(attachments_wire_rejects_nan_and_infinities_in_every_vector_component)
{
    for (const float bad : {std::numeric_limits<float>::quiet_NaN(),
             std::numeric_limits<float>::infinity(), -std::numeric_limits<float>::infinity()})
        for (size_t axis = 0; axis < 3; ++axis)
        {
            auto item = descriptor(2);
            item.angles[axis] = bad;
            rejected_unchanged(raw_state({descriptor(1), item}));
            item = descriptor(2);
            item.position[axis] = bad;
            rejected_unchanged(raw_state({descriptor(1), item}));
        }
}

TEST(attachments_wire_failed_reader_cannot_clear_previous_state)
{
    Writer w;
    w.u8(0);
    Reader r(w.ptr(), w.size());
    (void)r.u16();
    REQUIRE(!r.ok());
    const auto before = state({descriptor(1)});
    auto out = before;
    CHECK(!out.read(r));
    CHECK(out == before);
}
