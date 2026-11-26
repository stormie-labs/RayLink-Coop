// Anomaly Coop unit tests: a copy of a creature that no usable motion of the decider reaches (TZ P101, 6.30, 2026-11-25).
// Live (Dev 64, Server mode, Cordon): Wolf stood in a T-pose on a player's machine. Every live NPC spawns playing "death_init",
// the bind pose of GAMMA's stalker models (CCharacterPhysicsSupport::in_NetSpawn); on a copy only drive_mirror replaces it, so
// a partition no usable host motion reached stayed in it, and the 26fe5b0b line never fired (death_init counted as a live
// motion; a copy with no snapshot returned before the line). xrCoop/coop_mirror_pose_rules.h decides when the copy plays its
// own idle and when a line names the trigger; coop_snapshots.cpp, coop_pose_diag.cpp, coop_remote.cpp and coop_dialog.cpp wire
// it (pins below).
// The rules are Ядро: the same in Coop (the host decides) and Server (the map server of the level decides).
#include "test_util.h"

#include "coop_mirror_pose_rules.h"

#include <algorithm>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

using namespace coop;
using mirror_pose::Cause;
using mirror_pose::PartPlay;

namespace
{
// anomaly-coop/<rel>, the project root above this source file (tests\ -> ..), without '\r'
std::string project_file(const std::string& rel)
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	here.resize(slash == std::string::npos ? 0 : slash);
	std::ifstream f(here + "/../" + rel, std::ios::binary);
	std::string text((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
	text.erase(std::remove(text.begin(), text.end(), '\r'), text.end());
	return text;
}

std::string game_source(const char* name) { return project_file(std::string("engine/src/xrGame/") + name); }

// The text from `from` to the first `to` after it; "" if `from` is missing.
std::string between(const std::string& src, const std::string& from, const std::string& to)
{
	const size_t at = src.find(from);
	if (at == std::string::npos)
		return std::string();
	const size_t end = src.find(to, at + from.size());
	return src.substr(at, end == std::string::npos ? std::string::npos : end - at);
}

constexpr size_t npos = std::string::npos;

// A model's motion tables as entities::motion_valid reads them: the number of motions per slot (MotionID: idx low 16 bits,
// slot high 16). The real GAMMA tables (temp/r101: stalker_animation.omf 1441, stalker_scripts_animation.omf 586,
// stalker_smart_cover_animation.omf 544, scenario 442).
struct Tables
{
	std::vector<uint32_t> sizes;
	bool valid(uint32_t value) const
	{
		if (value == mirror_pose::kNoMotion)
			return false;
		const uint32_t slot = value >> 16, idx = value & 0xffff;
		return slot < sizes.size() && idx < sizes[slot];
	}
};
// Wolf's model actors\stalker_neutral\stalker_neytral_balon_1: [stalker_animation, scripts, smart_cover] (one of a kind).
const Tables kBalon1{{1441, 586, 544}};
// The order of 138 of the 181 models of that folder: [stalker_animation, scenario, scripts, smart_cover].
const Tables kCommon{{1441, 442, 586, 544}};
constexpr uint32_t kDeathInit = 967; // (0, 967) in stalker_animation.omf: the bind pose
constexpr uint32_t kHeadIdle = 778; // (0, 778) head_idle_0
constexpr uint32_t kOhrana1 = (1u << 16) | 544; // Wolf's "ward" idle on balon_1 (slot 1 = scripts)

mirror_pose::PartFacts part(const Tables& here, uint32_t host, bool driven, bool bare)
{
	mirror_pose::PartFacts f;
	f.named = host != mirror_pose::kNoMotion;
	f.valid = here.valid(host);
	f.placeholder = f.valid && host == kDeathInit;
	f.driven = driven;
	f.bare = bare;
	return f;
}

mirror_pose::Book settled_book()
{
	mirror_pose::Book b;
	b.since_ms = 1000;
	b.frames = mirror_pose::kGraceFrames;
	return b;
}
} // namespace

TEST(mirror_pose_a_copy_settles_after_its_first_moments)
{
	mirror_pose::Book b;
	b.since_ms = 1000;
	b.frames = mirror_pose::kGraceFrames - 1;
	CHECK(!mirror_pose::settled(b, 1000 + 60000)); // one long frame (a level loading) is not enough
	b.frames = mirror_pose::kGraceFrames;
	CHECK(!mirror_pose::settled(b, 1000 + mirror_pose::kGraceMs - 1));
	CHECK(mirror_pose::settled(b, 1000 + mirror_pose::kGraceMs));
	// A snapshot comes every 66 ms and is shown 120 ms late: the grace is ten times that.
	CHECK(mirror_pose::kGraceMs >= 10u * (66u + 120u));
}

TEST(mirror_pose_wolf_with_another_motion_table_stands_in_his_own_idle)
{
	// The decider plays Wolf's "ward" (ohrana_1, slot 1 of balon_1) on legs and torso and head_idle_0 on the head; the copy's
	// model has the common order, where slot 1 is the scenario table (442 motions): 1:544 is past its end.
	CHECK(!kCommon.valid(kOhrana1));
	CHECK(kBalon1.valid(kOhrana1));
	const bool settled = true;
	CHECK(mirror_pose::part_play(part(kCommon, kOhrana1, false, true), settled) == PartPlay::Fallback); // legs
	CHECK(mirror_pose::part_play(part(kCommon, kOhrana1, false, true), !settled) == PartPlay::Keep); // not yet
	CHECK(mirror_pose::part_play(part(kCommon, kHeadIdle, false, true), settled) == PartPlay::Host); // the head plays
	// The line: legs and torso idle, the head driven; the decider names motions this model has not.
	mirror_pose::WatchFacts f;
	f.track = true;
	f.samples = 24;
	f.present = 0x7;
	f.driven = 0x4;
	f.named = 0x7;
	f.valid = 0x4;
	CHECK(mirror_pose::cause_of(f) == Cause::NotInThisModel);
	// (The 26fe5b0b line looked for a copy with no channel-0 blend on any partition: the head and death_init silenced it.)
}

TEST(mirror_pose_a_copy_with_no_snapshot_stands_in_its_own_idle)
{
	// No snapshot of the id here (the decider does not stream it): nothing is named, every partition still plays death_init.
	CHECK(mirror_pose::part_play(part(kBalon1, mirror_pose::kNoMotion, false, true), true) == PartPlay::Fallback);
	CHECK(mirror_pose::part_play(part(kBalon1, mirror_pose::kNoMotion, false, true), false) == PartPlay::Keep);
	mirror_pose::WatchFacts f;
	f.present = 0x7;
	f.stream = true; // the decider streams other creatures here (Wolf's signature)
	CHECK(mirror_pose::cause_of(f) == Cause::NoSnapshot); // no track
	f.track = true;
	CHECK(mirror_pose::cause_of(f) == Cause::NoSnapshot); // a track with no sample
	// P101 review: a track dropped after the copy was driven leaves it frozen in its last pose, not in its spawn pose: no line.
	f.driven = 0x7;
	CHECK(mirror_pose::cause_of(f) == Cause::None);
	f.track = false;
	CHECK(mirror_pose::cause_of(f) == Cause::None);
	f.stream = false;
	CHECK(mirror_pose::cause_of(f) == Cause::None);
	// A monster's or a trader's copy: no partition counts (watch_pose), so no line whatever the snapshots.
	f.driven = 0;
	f.present = 0;
	CHECK(mirror_pose::cause_of(f) == Cause::None);
	f.stream = true;
	CHECK(mirror_pose::cause_of(f) == Cause::None);
}

TEST(mirror_pose_no_stream_to_this_client_is_not_the_ids_matter)
{
	// P101 review: "no snapshot of this id" names the id only while the decider's stream reaches this process. A client the
	// stream has not reached yet (a join, a level of a map server that streams to nobody here) or no longer reaches (the
	// decider saves or loads) lacks a snapshot of every copy: Cause::NoStream, one line for the gap, none per copy.
	mirror_pose::WatchFacts f;
	f.present = 0x7;
	CHECK(mirror_pose::cause_of(f) == Cause::NoStream); // no track and no stream
	f.track = true;
	CHECK(mirror_pose::cause_of(f) == Cause::NoStream); // an empty track, no stream
	f.samples = 5;
	f.newest_age_ms = mirror_pose::kStaleMs + 1;
	CHECK(mirror_pose::cause_of(f) == Cause::NoStream); // every snapshot stopped, not this id's
	f.stream = true;
	CHECK(mirror_pose::cause_of(f) == Cause::Stale); // this id's stopped while others still come
	// The rule of the stream: a sample of any creature within kStaleMs, and after the copy appeared.
	const uint64_t since = 10000;
	CHECK(!mirror_pose::stream_reaches(0, since, since + 5000)); // none this session
	CHECK(mirror_pose::stream_reaches(since + 4000, since, since + 5000)); // a sample 1 s ago
	CHECK(mirror_pose::stream_reaches(since + 1000, since, since + 1000 + mirror_pose::kStaleMs)); // the edge
	CHECK(!mirror_pose::stream_reaches(since + 1000, since, since + 1001 + mirror_pose::kStaleMs)); // stopped
	CHECK(!mirror_pose::stream_reaches(since - 1, since, since + 2500)); // fresh, but nothing came since the copy appeared
	CHECK(mirror_pose::stream_reaches(since, since, since + 2500)); // one in the copy's first frame counts
	// A copy settles after kGraceMs: on a live stream (a sample every 66 ms) one came after it appeared by then.
	CHECK(mirror_pose::stream_reaches(since + mirror_pose::kGraceMs - 66, since, since + mirror_pose::kGraceMs));
	// The copy's own lines: NoStream neither starts nor ends an episode.
	mirror_pose::Book b = settled_book();
	CHECK(!mirror_pose::say_now(b, Cause::NoStream, true));
	CHECK(!b.said);
	CHECK(mirror_pose::say_now(b, Cause::NoSnapshot, true)); // the stream came and still leaves this id out: said
	CHECK(!mirror_pose::say_now(b, Cause::NoStream, true)); // the decider stalls
	CHECK(b.said);
	CHECK(!mirror_pose::say_now(b, Cause::NoSnapshot, true)); // and comes back: the same episode, not said again
}

TEST(mirror_pose_no_judgement_while_this_process_takes_no_snapshot)
{
	// Dev 65/66 stands: the joining client wrote "no snapshot stream to this client" in loading-world (its handler drops every
	// EntitySnapshot until it is live in an up world), and a Server client 0.2 s after "phase live -> receiving-world".
	const mirror_pose::Book b = settled_book(); // appeared at 1000, many frames
	const uint64_t now = 1000 + 4344; // 4344 ms with this model, as in dev66_base_client.log
	CHECK(mirror_pose::settled(b, now)); // the copy's own first moments are over
	CHECK(!mirror_pose::watch_due(b, 0, now)); // loading-world / receiving-world: no stream can reach, no line
	// The clock of the open stream: set on the first open frame, kept while open, cleared when it closes.
	CHECK(mirror_pose::stream_open_at(0, false, now) == 0);
	CHECK(mirror_pose::stream_open_at(0, true, now) == now);
	CHECK(mirror_pose::stream_open_at(now, true, now + 500) == now);
	CHECK(mirror_pose::stream_open_at(now, false, now + 500) == 0);
	// Live since `now`: a copy that appeared long before is judged kGraceMs after the stream opened, not at once.
	CHECK(!mirror_pose::watch_due(b, now, now));
	CHECK(!mirror_pose::watch_due(b, now, now + mirror_pose::kGraceMs - 1));
	CHECK(mirror_pose::watch_due(b, now, now + mirror_pose::kGraceMs));
	// A copy that appears after the stream opened keeps its own first moments.
	mirror_pose::Book late = b;
	late.since_ms = now + 5000;
	CHECK(!mirror_pose::watch_due(late, now, now + 5000 + mirror_pose::kGraceMs - 1));
	CHECK(mirror_pose::watch_due(late, now, now + 5000 + mirror_pose::kGraceMs));
	// A real gap is still said: live, the copies settled, and no sample of any creature for kStaleMs.
	CHECK(mirror_pose::watch_due(b, 1000, now));
	CHECK(!mirror_pose::stream_reaches(0, b.since_ms, now));
}

TEST(mirror_pose_the_deciders_own_placeholder_is_mirrored_not_hidden)
{
	// The decider names death_init (its own animation update never ran, or a ragdoll: a corpse there): the copy plays it as
	// it is, so a dead or broken decider is not shown as a living idle NPC. The line names it.
	CHECK(mirror_pose::part_play(part(kBalon1, kDeathInit, false, true), true) == PartPlay::Host);
	CHECK(part(kBalon1, kDeathInit, false, true).placeholder);
	mirror_pose::WatchFacts f;
	f.track = true;
	f.samples = 3;
	f.present = 0x7;
	f.named = f.valid = f.placeholder = 0x7;
	CHECK(mirror_pose::cause_of(f) == Cause::HostPlaceholder);
	f.decider_dead = true;
	CHECK(mirror_pose::cause_of(f) == Cause::HostDead);
}

TEST(mirror_pose_a_driven_or_playing_part_is_left_alone)
{
	// b29: a part with nothing but a hit flinch names no channel-0 motion for a moment; a part a host motion drove keeps it.
	CHECK(mirror_pose::part_play(part(kBalon1, mirror_pose::kNoMotion, true, false), true) == PartPlay::Keep);
	CHECK(mirror_pose::part_play(part(kCommon, kOhrana1, true, false), true) == PartPlay::Keep);
	// The idle plays already (not bare): nothing more.
	CHECK(mirror_pose::part_play(part(kBalon1, mirror_pose::kNoMotion, false, false), true) == PartPlay::Keep);
	// A motion this model has: the host's, as before P101.
	CHECK(mirror_pose::part_play(part(kBalon1, kOhrana1, true, false), true) == PartPlay::Host);
	CHECK(mirror_pose::part_play(part(kBalon1, kOhrana1, false, true), false) == PartPlay::Host); // also before it settled
}

TEST(mirror_pose_causes_in_their_order)
{
	mirror_pose::WatchFacts f;
	f.stream = true;
	f.track = true;
	f.samples = 10;
	f.present = 0x7;
	f.driven = 0x7;
	CHECK(mirror_pose::cause_of(f) == Cause::None);
	f.newest_age_ms = mirror_pose::kStaleMs + 1; // every part driven: a decider that stalls is no T-pose and no line
	CHECK(mirror_pose::cause_of(f) == Cause::None);
	f.driven = 0x4;
	CHECK(mirror_pose::cause_of(f) == Cause::Stale);
	f.stream = false;
	CHECK(mirror_pose::cause_of(f) == Cause::NoStream);
	f.stream = true;
	f.newest_age_ms = 66;
	f.named = 0x4;
	f.valid = 0x4;
	CHECK(mirror_pose::cause_of(f) == Cause::HostNamesNone);
	f.named = 0x7;
	f.valid = 0x7;
	CHECK(mirror_pose::cause_of(f) == Cause::NotStarted);
	f.present = 0x3; // the head is no partition of this model: legs and torso decide
	f.driven = 0x3;
	CHECK(mirror_pose::cause_of(f) == Cause::None);
	// With fresh snapshots of this id the stream does not matter.
	f.stream = false;
	CHECK(mirror_pose::cause_of(f) == Cause::None);
	f.driven = 0x1;
	CHECK(mirror_pose::cause_of(f) == Cause::NotStarted);
	for (Cause c : {Cause::None, Cause::NoStream, Cause::NoSnapshot, Cause::Stale, Cause::HostDead, Cause::HostPlaceholder,
	                Cause::NotInThisModel, Cause::HostNamesNone, Cause::NotStarted})
		CHECK(std::string(mirror_pose::cause_name(c)) != "?");
}

TEST(mirror_pose_a_line_once_per_episode_within_the_budget)
{
	mirror_pose::Book b = settled_book();
	CHECK(!mirror_pose::say_now(b, Cause::NoSnapshot, false)); // not settled: nothing, and nothing remembered
	CHECK(mirror_pose::say_now(b, Cause::NoSnapshot, true));
	CHECK(!mirror_pose::say_now(b, Cause::NoSnapshot, true));
	CHECK(!mirror_pose::say_now(b, Cause::NotInThisModel, true)); // the same episode
	CHECK(!mirror_pose::say_now(b, Cause::None, true)); // fine again: the episode ends
	CHECK(mirror_pose::say_now(b, Cause::Stale, true)); // a new one is said
	uint32_t n = 0;
	int said = 0;
	for (int i = 1; i <= 200; ++i)
		said += mirror_pose::line_allowed(n) ? 1 : 0;
	CHECK_EQ(n, 200u);
	CHECK_EQ(said, 40 + 4); // the first 40, then the 50th, 100th, 150th and 200th
}

TEST(mirror_pose_fallback_motions_by_partition_name)
{
	CHECK_EQ(std::string(mirror_pose::fallback_motion("legs")), std::string("norm_idle_0"));
	CHECK_EQ(std::string(mirror_pose::fallback_motion("torso")), std::string("norm_torso_0_idle_0"));
	CHECK_EQ(std::string(mirror_pose::fallback_motion("head")), std::string("head_idle_0"));
	CHECK_EQ(std::string(mirror_pose::fallback_motion("Legs")), std::string("norm_idle_0")); // LL_PartID: stricmp
	CHECK(mirror_pose::fallback_motion("default") == nullptr); // a monster's partition
	CHECK(mirror_pose::fallback_motion("leg") == nullptr);
	CHECK(mirror_pose::fallback_motion("legs2") == nullptr);
	CHECK(mirror_pose::fallback_motion("") == nullptr);
	CHECK(mirror_pose::fallback_motion(nullptr) == nullptr); // an empty shared_str gives nullptr
	CHECK_EQ(mirror_pose::bit(0), 1);
	CHECK_EQ(mirror_pose::bit(2), 4);
	CHECK_EQ(mirror_pose::bit(4), 0);
}

TEST(mirror_pose_decider_rules)
{
	uint8_t streak = 0;
	CHECK(!mirror_pose::second_round(streak)); // a spawn under way is met once
	CHECK(mirror_pose::second_round(streak)); // two rounds in a row: said
	CHECK(!mirror_pose::second_round(streak)); // and only once
	streak = 254;
	CHECK(!mirror_pose::second_round(streak));
	CHECK(!mirror_pose::second_round(streak));
	CHECK_EQ(streak, 255);
	// A round is far longer than the copy's grace: a stuck decider is said only once its copies have long settled.
	CHECK(mirror_pose::kRoundMs >= 2 * mirror_pose::kGraceMs);
}

// ---------------------------------------------------------------- the engine side (source pins)

TEST(mirror_pose_premise_every_live_npc_spawns_in_death_init)
{
	// If in_NetSpawn stops playing death_init, revisit the rules: a copy with no blend at all collapses onto its root instead
	// (AnimationKeyCalculate.h MixInterlerp case 0), it does not show the bind pose.
	const std::string src = game_source("CharacterPhysicsSupport.cpp");
	const std::string spawn = between(src, "void CCharacterPhysicsSupport::in_NetSpawn", "\nvoid CCharacterPhysicsSupport::");
	CHECK(!spawn.empty());
	CHECK(spawn.find("else if (!m_EntityAlife.animation_movement_controlled())\n\t\tka->PlayCycle(\"death_init\");") != npos);
	// P103's premise: a copy has no movement controller (make_remote destroys it).
	const std::string remote = game_source("coop/coop_remote.cpp");
	CHECK(between(remote, "void make_remote(CGameObject* obj)", "\n}\n").find("obj->destroy_anim_mov_ctrl();") != npos);
}

TEST(mirror_pose_drive_mirror_uses_the_rules)
{
	const std::string src = game_source("coop/coop_snapshots.cpp");
	const std::string drive = between(src, "bool drive_mirror(CGameObject* obj, mirror_pose::Book& book)", "\n}\n");
	CHECK(!drive.empty());
	// No snapshot: the parts and the line before the return (before P101 it returned at once, silently).
	const std::string none = between(drive, "if (it == g_tracks.end() || !interpolate(", "return false;");
	CHECK(none.find("drive_parts(obj, ka, book, nullptr, track, now);") != npos);
	CHECK(none.find("watch_pose(obj, ka, book, track, nullptr, now);") != npos);
	CHECK(drive.find("drive_parts(obj, ka, book, s.sample, &track, now);") != npos);
	CHECK(drive.find("watch_pose(obj, ka, book, &track, s.sample, now);") != npos);
	CHECK(drive.find("plays no base motion") == npos); // the 26fe5b0b line is replaced
	const std::string parts = between(src, "void drive_parts(", "\n}\n");
	CHECK(parts.find("switch (mirror_pose::part_play(f, settled))") != npos);
	CHECK(parts.find("play_own_idle(obj, ka, part, book);") != npos);
	CHECK(parts.find("if (!f.placeholder)\n\t\t\t\t\tbook.driven |= b;") != npos);
	// b29 stays: the copy looks for and starts channel-0 blends only, and the decider captures channel 0 only.
	CHECK(parts.find("instrument::mirrored_channel(blend->channel)") != npos);
	CHECK(between(src, "void capture_anims(", "\n}\n").find("instrument::pick_mirror_blend(") != npos);
	const std::string idle = between(src, "void play_own_idle(", "\n}\n");
	CHECK(idle.find("if (!obj->cast_stalker() || !(parts_of(ka) & b))") != npos); // no null partition, stalkers only
	CHECK(idle.find("mirror_pose::fallback_motion(") != npos);
	CHECK(idle.find("ka->ID_Cycle_Safe(name)") != npos); // by name in this model, never a host id
	const std::string watch = between(game_source("coop/coop_pose_diag.cpp"), "void watch_pose(", "\n}\n");
	CHECK(watch.find("mirror_pose::cause_of(f)") != npos);
	CHECK(watch.find("mirror_pose::say_now(book, cause, due)") != npos);
	CHECK(watch.find("mirror_pose::line_allowed(g_pose_lines)") != npos);
}

TEST(mirror_pose_the_copy_book_starts_with_each_skeleton)
{
	const std::string src = game_source("coop/coop_remote.cpp");
	const std::string apply = between(src, "bool apply(CGameObject* obj)", "\n}\n");
	const size_t reset = apply.find("puppet->second.visual != ka");
	const size_t drive = apply.find("entities::drive_mirror(obj, ");
	CHECK(reset != npos);
	CHECK(drive != npos);
	CHECK(reset < drive);
	CHECK(apply.find("puppet->second.pose.since_ms = mgr().now_ms();") != npos);
	CHECK(between(src, "struct Puppet", "};").find("mirror_pose::Book pose;") != npos);
}

TEST(mirror_pose_decider_lines_are_wired)
{
	const std::string src = game_source("coop/coop_pose_diag.cpp");
	// A round every kRoundMs, off the 66 ms snapshot path (host_send_snapshots is as before P101).
	CHECK(between(game_source("coop/coop_snapshots.cpp"), "void host_send_snapshots()", "\n}\n").find("watch_") == npos);
	CHECK(between(game_source("coop/coop_entities.cpp"), "void frame()", "\n}\n").find("watch_decider(mgr().now_ms());") != npos);
	// Only a process that has the level loaded (the Coop host, a map server) has game objects to compare with.
	const std::string round = between(src, "void watch_decider(u64 now)", "\n}\n");
	CHECK(round.find("if (!mode().leads_level() ||") != npos);
	CHECK(round.find("g_decider_round_at = now + mirror_pose::kRoundMs;") != npos);
	CHECK(round.find("obj->cast_stalker() && !world::is_player_proxy(obj->ID())") != npos);
	// P101 review: the level's server entities, not the whole ALife registry; a squad's members through their squad (the level
	// registry has none: CSE_ALifeOnlineOfflineGroup::register_member takes them out).
	CHECK(round.find("ai().alife().objects().objects()") == npos);
	CHECK(round.find("if (ai().alife().graph().level_exists())") != npos);
	CHECK(round.find("for (const auto& it : ai().alife().graph().level().objects())") != npos);
	CHECK(round.find("smart_cast<CSE_ALifeOnlineOfflineGroup*>(e)") != npos);
	CHECK(round.find("watch_entity(member.second, bodiless);") != npos);
	CHECK(round.find("watch_entity(e, bodiless);") != npos);
	CHECK(between(project_file("engine/src/xrGame/alife_online_offline_group.cpp"),
	              "void CSE_ALifeOnlineOfflineGroup::register_member", "\n}\n")
	          .find("alife().graph().level().remove(object);") != npos);
	const std::string entity = between(src, "void watch_entity(", "\n}\n");
	CHECK(entity.find("next_round(g_bodiless, bodiless, e->ID, e)") != npos);
	CHECK(entity.find("!online_here(e) || game_object_here(e->ID)") != npos);
	const std::string creature = between(src, "void watch_creature(", "\n}\n");
	CHECK(creature.find("obj->animation_movement_controlled()") != npos); // P103
	CHECK(creature.find("ka->ID_Cycle_Safe(\"death_init\")") != npos); // P101 (d)
	CHECK(creature.find("next_round(g_decider_unposed, unposed, id, obj)") != npos);
}

TEST(mirror_pose_stream_stamp_and_session_reset_are_wired)
{
	const std::string src = game_source("coop/coop_snapshots.cpp");
	const std::string diag = game_source("coop/coop_pose_diag.cpp");
	// The stream's time is a sample taken (client_on_snapshot), and watch_pose asks the rule with it.
	const std::string in = between(src, "void client_on_snapshot(PeerId, Reader& r)", "\n}\n");
	const size_t taken = in.find("t.samples.push_back(std::move(s));");
	const size_t stamp = in.find("g_snapshot_in_at = now;");
	CHECK(taken != npos);
	CHECK(stamp != npos);
	CHECK(taken < stamp);
	CHECK(in.find("g_pose_gap_said = false;") != npos);
	const std::string watch = between(diag, "void watch_pose(", "\n}\n");
	CHECK(watch.find("f.stream = mirror_pose::stream_reaches(g_snapshot_in_at, book.since_ms, now);") != npos);
	CHECK(watch.find("if (cause == mirror_pose::Cause::NoStream)") != npos);
	CHECK(watch.find("mirror_pose::line_allowed(g_pose_gap_lines)") != npos);
	// Judged only once this client can take a sample: live in an up world (the handler and the world gate drop them before).
	const size_t opened = watch.find("g_stream_open_at = mirror_pose::stream_open_at(g_stream_open_at, mgr().is_live_client() && world_up(), now);");
	const size_t due = watch.find("const bool due = mirror_pose::watch_due(book, g_stream_open_at, now);");
	CHECK(opened != npos);
	CHECK(due != npos);
	CHECK(opened < due);
	CHECK(due < watch.find("if (cause == mirror_pose::Cause::NoStream)"));
	CHECK(watch.find("if (due && !g_pose_gap_said)") != npos);
	CHECK(game_source("coop/coop_entities.cpp").find("if (mgr().is_live_client()) client_on_snapshot(from, r);") != npos);
	// The counters, books and line budgets are the session's (entities::reset: reset_snapshots, reset_pose_diag).
	const std::string reset = between(src, "\nvoid reset_snapshots()\n{", "\n}\n") +
	    between(diag, "\nvoid reset_pose_diag()\n{", "\n}\n");
	for (const char* line : {"g_pose_fallbacks = 0;", "g_pose_lines = g_copy_state_lines = g_pose_gap_lines = 0;",
	                         "g_snapshot_in_at = 0;", "g_pose_gap_said = false;", "g_stream_open_at = 0;", "g_decider_round_at = 0;",
	                         "g_decider_unposed.clear();", "g_decider_rootctl.clear();", "g_bodiless.clear();",
	                         "g_decider_lines = g_rootctl_lines = g_bodiless_lines = 0;"})
		CHECK(reset.find(line) != npos);
}

TEST(mirror_pose_a_gone_talk_names_its_npc)
{
	const std::string src = game_source("coop/coop_dialog.cpp");
	const std::string denied = between(src, "void notify_denied(", "\n}\n");
	CHECK(denied.find("talk refused by the host: %s (NPC %u here, %u on the host, [%s])") != npos);
	CHECK(denied.find("if (result == Gone && local != kNoId)") != npos);
	CHECK(denied.find("entities::describe_copy(local,") != npos);
	CHECK(between(src, "void client_on_result(", "\n}\n").find("notify_denied(result, msg.reason, npc);") != npos);
}
