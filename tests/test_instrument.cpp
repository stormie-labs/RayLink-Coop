#include "test_util.h"
#include "coop_instrument.h"
#include <limits>
using namespace coop;

namespace
{
using ResourcePath = char[128];
struct ResourceFile {};
struct ResourceFileSystem
{
    int three_arg_calls = 0;
    int four_arg_calls = 0;
    ResourceFile file;

    const ResourceFile* lookup(const ResourcePath& path)
    {
        const std::string resolved(path);
        return resolved == "$game_meshes$/instruments/guitar.ogf" ||
            resolved == "$game_sounds$/music/guitar_1.ogg" ? &file : nullptr;
    }

    const ResourceFile* exist(ResourcePath& path, const char* alias, const char* name)
    {
        ++three_arg_calls;
        std::snprintf(path, sizeof(path), "%s/%s", alias, name);
        return lookup(path);
    }

    const ResourceFile* exist(ResourcePath& path, const char* alias, const char* name, const char* extension)
    {
        ++four_arg_calls;
        CHECK(extension != nullptr); // Real CLocatorAPI::exist passes this directly to strconcat.
        if (!extension)
            return nullptr;
        std::snprintf(path, sizeof(path), "%s/%s%s", alias, name, extension);
        return lookup(path);
    }
};
} // namespace

TEST(instrument_resource_full_mesh_name_uses_three_arg_exist)
{
    ResourceFileSystem fs;
    ResourcePath path = {};
    CHECK(instrument::resource_exists(fs, path, "$game_meshes$", "instruments/guitar.ogf", nullptr));
    CHECK_EQ(fs.three_arg_calls, 1);
    CHECK_EQ(fs.four_arg_calls, 0);
    CHECK_EQ(std::string(path), "$game_meshes$/instruments/guitar.ogf");
}

TEST(instrument_resource_sound_extension_uses_four_arg_exist)
{
    ResourceFileSystem fs;
    ResourcePath path = {};
    CHECK(instrument::resource_exists(fs, path, "$game_sounds$", "music/guitar_1", ".ogg"));
    CHECK_EQ(fs.three_arg_calls, 0);
    CHECK_EQ(fs.four_arg_calls, 1);
    CHECK_EQ(std::string(path), "$game_sounds$/music/guitar_1.ogg");
}

TEST(instrument_resource_missing_mesh_remains_false)
{
    ResourceFileSystem fs;
    ResourcePath path = {};
    CHECK(!instrument::resource_exists(fs, path, "$game_meshes$", "missing.ogf", nullptr));
    CHECK_EQ(fs.three_arg_calls, 1);
    CHECK_EQ(fs.four_arg_calls, 0);
    CHECK_EQ(std::string(path), "$game_meshes$/missing.ogf");
}

TEST(instrument_resource_missing_sound_remains_false)
{
    ResourceFileSystem fs;
    ResourcePath path = {};
    CHECK(!instrument::resource_exists(fs, path, "$game_sounds$", "music/missing", ".ogg"));
    CHECK_EQ(fs.three_arg_calls, 0);
    CHECK_EQ(fs.four_arg_calls, 1);
    CHECK_EQ(std::string(path), "$game_sounds$/music/missing.ogg");
}

TEST(instrument_wire_is_bounded_and_atomic)
{
    instrument::State s;
    s.kind = 1; s.phase = 2; s.track = 28; s.serial = 7;
    s.age_ms = 8000; s.phase_ms = 2000; s.duration_ms = 60000;
    Writer w; s.write(w);
    for (size_t n = 0; n < w.size(); ++n)
    {
        Reader r(w.ptr(), n); instrument::State out;
        CHECK(!out.read(r));
    }
    Reader r(w.ptr(), w.size()); instrument::State out;
    CHECK(out.read(r)); CHECK_EQ(out.track, 28); CHECK_EQ(out.phase_ms, 2000u);
    CHECK(out.valid());
    out.kind = 3; CHECK(!out.valid()); out.kind = 2; CHECK(!out.valid());
    out.track = 5; CHECK(out.valid());
    out.duration_ms = 600001; CHECK(!out.valid());
    out.duration_ms = 60000; out.phase = 4; CHECK(!out.valid());
    out.phase = 2; out.serial = 0; CHECK(!out.valid());
}

TEST(instrument_completion_and_interruption_are_finite)
{
    instrument::State s;
    s.kind = 1; s.phase = 2; s.track = 1; s.serial = 1;
    s.duration_ms = 4000; s.age_ms = 4000; s.phase_ms = 4000;
    instrument::advance(s, 1); CHECK_EQ(s.phase, 3); CHECK_EQ(s.phase_ms, 1u);
    instrument::advance(s, 15000); CHECK_EQ(s.kind, 0);
    s.kind = 1; s.phase = 1; s.serial = 2;
    instrument::advance(s, 20000); CHECK_EQ(s.kind, 0);
    CHECK(instrument::stationary(0, 0.f, 0.f, 0.f, true));
    CHECK(!instrument::stationary(1, 0.f, 0.f, 0.f, true));
    CHECK(!instrument::stationary(0, 1.f, 0.f, 0.f, true));
    CHECK(!instrument::stationary(0, 0.f, 0.f, 0.f, false));
    CHECK(!instrument::stationary(0, std::numeric_limits<float>::quiet_NaN(), 0.f, 0.f, true));
}

TEST(instrument_mirror_accepts_zero_motion_and_rejects_real_invalid)
{
    CHECK(instrument::motion_present(0)); // MotionID(0,0) is valid
    CHECK(!instrument::motion_present(0xffff)); // MotionID::invalidate
    CHECK(instrument::prefer_blend(true, false, .1f, true, true, 1.f));
    CHECK(!instrument::prefer_blend(false, false, 1.f, true, false, .2f));
    CHECK(instrument::phase_needs_sync(0.1f, 4.f)); // same motion repeated after a one-shot
    CHECK(!instrument::phase_needs_sync(1.1f, 1.f));
}

TEST(instrument_presentation_interpolates_only_within_a_phase)
{
    instrument::State a;
    a.kind=1; a.phase=2; a.track=4; a.serial=8;
    a.duration_ms=12000; a.age_ms=2000; a.phase_ms=1000;
    instrument::State b=a; b.age_ms=2100; b.phase_ms=1100;
    auto halfway=instrument::interpolate(a,b,.5f);
    CHECK_EQ(halfway.age_ms,2050u); CHECK_EQ(halfway.phase_ms,1050u);
    CHECK(halfway.valid());
    b.serial=9;
    CHECK_EQ(instrument::interpolate(a,b,.25f).serial,8u);
    CHECK_EQ(instrument::interpolate(a,b,.75f).serial,9u);
    b=a; b.phase=3; b.track=0; b.duration_ms=0; b.phase_ms=0;
    CHECK_EQ(instrument::interpolate(a,b,.75f).phase,3);
    CHECK_EQ(instrument::interpolate(a,b,.75f).phase_ms,0u);
    auto extrapolated=a; instrument::advance(extrapolated,37);
    CHECK_EQ(extrapolated.phase_ms,1037u);
    CHECK(instrument::finite3(0.f,1.f,-2.f));
    CHECK(!instrument::finite3(std::numeric_limits<float>::infinity(),0.f,0.f));
    CHECK(!instrument::finite3(0.f,std::numeric_limits<float>::quiet_NaN(),0.f));
}
