"""P101 (TZ 6.30): a copy of a creature that no usable motion of the decider reaches stands in its own idle, and bounded
lines name why (engine sources read as text; no build).

Every live NPC spawns playing "death_init", the bind pose of GAMMA's stalker models (CCharacterPhysicsSupport::in_NetSpawn);
on a copy only entities::drive_mirror replaces it. The rules are xrCoop/coop_mirror_pose_rules.h (native tests:
tests/test_mirror_pose_rules.cpp, built by tools/build_tests.cmd); this file pins the wiring they rely on, so that it can be
checked without building the engine or the native tests. Ядро: the same in Coop (the host decides) and Server (the map server
of the level decides).
"""
import re

from conftest import ROOT

GAME = ROOT / "engine" / "src" / "xrGame"
RULES = ROOT / "engine" / "src" / "xrCoop" / "coop_mirror_pose_rules.h"


def source(path):
    # Comments in GSC files are cp1251; latin-1 reads any byte. No '\r' (a checkout may have CRLF).
    return path.read_bytes().decode("latin-1").replace("\r", "")


def entities_source():
    # The entities module is split: the session reset, the snapshots, the pose lines.
    return "\n".join(source(GAME / "coop" / name) for name in ("coop_entities.cpp", "coop_snapshots.cpp", "coop_pose_diag.cpp"))


def between(text, start, end):
    at = text.find(start)
    assert at >= 0, start
    stop = text.find(end, at + len(start))
    return text[at:] if stop < 0 else text[at:stop]


def test_premise_every_live_npc_spawns_in_death_init():
    spawn = between(source(GAME / "CharacterPhysicsSupport.cpp"), "void CCharacterPhysicsSupport::in_NetSpawn",
                    "\nvoid CCharacterPhysicsSupport::")
    assert 'else if (!m_EntityAlife.animation_movement_controlled())\n\t\tka->PlayCycle("death_init");' in spawn
    # A copy selects no motion of its own: the stalker manager and script animations return at once for a puppet.
    update = source(GAME / "stalker_animation_manager_update.cpp")
    assert "if (coop::remote::is_remote_creature(m_object)) return;" in update
    # P103's premise: a copy has no movement controller.
    remote = source(GAME / "coop" / "coop_remote.cpp")
    assert "obj->destroy_anim_mov_ctrl();" in between(remote, "void make_remote(CGameObject* obj)", "\n}\n")


def test_drive_mirror_goes_through_the_rules_with_and_without_a_snapshot():
    src = entities_source()
    drive = between(src, "bool drive_mirror(CGameObject* obj, mirror_pose::Book& book)", "\nvoid frame()")
    none = between(drive, "if (it == g_tracks.end() || !interpolate(", "return false;")
    assert "drive_parts(obj, ka, book, nullptr, track, now);" in none
    assert "watch_pose(obj, ka, book, track, nullptr, now);" in none
    assert "drive_parts(obj, ka, book, s.sample, &track, now);" in drive
    assert "watch_pose(obj, ka, book, &track, s.sample, now);" in drive
    assert "plays no base motion" not in src  # the 26fe5b0b line is replaced
    assert "anim_diag_after" not in src
    parts = between(src, "void drive_parts(", "\n}\n")
    assert "switch (mirror_pose::part_play(f, settled))" in parts
    assert "play_own_idle(obj, ka, part, book);" in parts
    assert "if (!f.placeholder)\n\t\t\t\t\tbook.driven |= b;" in parts
    # b29 stays: channel 0 only, on the copy and in the decider's capture.
    assert "instrument::mirrored_channel(blend->channel)" in parts
    assert "instrument::pick_mirror_blend(" in between(src, "void capture_anims(", "\n}\n")
    idle = between(src, "void play_own_idle(", "\n}\n")
    assert "if (!obj->cast_stalker() || !(parts_of(ka) & b))" in idle
    assert "ka->ID_Cycle_Safe(name)" in idle
    assert "book.fallback_tried |= b;" in idle
    watch = between(src, "void watch_pose(", "\n}\n")
    assert "mirror_pose::cause_of(f)" in watch
    assert "mirror_pose::say_now(book, cause, due)" in watch
    assert "mirror_pose::line_allowed(g_pose_lines)" in watch
    assert "if (!alive || !alive->g_Alive())" in watch


def test_the_copy_book_starts_with_each_skeleton():
    src = source(GAME / "coop" / "coop_remote.cpp")
    assert "mirror_pose::Book pose;" in between(src, "struct Puppet", "};")
    apply = between(src, "bool apply(CGameObject* obj)", "\n}\n")
    reset = apply.find("puppet->second.visual != ka")
    drive = apply.find("entities::drive_mirror(obj, ")
    assert 0 <= reset < drive
    assert "puppet->second.pose.since_ms = mgr().now_ms();" in apply
    # Dead copies are never driven (the ragdoll owns them): the pose rules never touch a corpse.
    assert apply.find("if (!alive || !alive->g_Alive())") < reset


def test_decider_lines_are_wired_and_bounded():
    src = entities_source()
    # A round every kRoundMs, off the 66 ms snapshot path (host_send_snapshots is as before P101).
    assert "watch_" not in between(src, "void host_send_snapshots()", "\n}\n")
    assert "watch_decider(mgr().now_ms());" in between(src, "void frame()", "\n}\n")
    round_ = between(src, "void watch_decider(u64 now)", "\n}\n")
    assert "if (!mode().leads_level() ||" in round_
    assert "g_decider_round_at = now + mirror_pose::kRoundMs;" in round_
    assert "obj->cast_stalker() && !world::is_player_proxy(obj->ID())" in round_
    entity = between(src, "void watch_entity(", "\n}\n")
    assert "next_round(g_bodiless, bodiless, e->ID, e)" in entity
    assert "!online_here(e) || game_object_here(e->ID)" in entity
    creature = between(src, "void watch_creature(", "\n}\n")
    assert "obj->animation_movement_controlled()" in creature
    assert 'ka->ID_Cycle_Safe("death_init")' in creature
    assert "next_round(g_decider_unposed, unposed, id, obj)" in creature
    # Every new line of the module has a budget.
    for name in ("g_decider_lines", "g_rootctl_lines", "g_bodiless_lines", "g_pose_lines", "g_copy_state_lines"):
        assert f"mirror_pose::line_allowed({name})" in src, name


def test_decider_round_walks_only_its_level():
    """P101 review: the round ran on the decider's main thread (the Coop host's) over the whole ALife registry, every item
    of the world, every 10 s. It walks the current level's registry now; a squad's members are not in it (register_member
    takes them out), so they are met through their squad."""
    src = entities_source()
    round_ = between(src, "void watch_decider(u64 now)", "\n}\n")
    assert "ai().alife().objects().objects()" not in round_
    assert "if (ai().alife().graph().level_exists())" in round_
    assert "for (const auto& it : ai().alife().graph().level().objects())" in round_
    assert "smart_cast<CSE_ALifeOnlineOfflineGroup*>(e)" in round_
    assert "watch_entity(member.second, bodiless);" in round_
    assert "watch_entity(e, bodiless);" in round_
    # The engine API the walk relies on (stock X-Ray, as in this tree).
    graph = source(GAME / "alife_graph_registry.h")
    assert "IC CALifeLevelRegistry& level() const;" in graph
    assert "IC bool level_exists() const;" in graph
    assert "class CALifeLevelRegistry : public CSafeMapIterator<ALife::_OBJECT_ID, CSE_ALifeDynamicObject>" in source(
        GAME / "alife_level_registry.h")
    assert "IC const _REGISTRY& objects() const;" in source(GAME / "safe_map_iterator.h")
    group = between(source(GAME / "alife_online_offline_group.cpp"), "void CSE_ALifeOnlineOfflineGroup::register_member",
                    "\n}\n")
    assert group.count("alife().graph().level().remove(object);") == 2
    # A squad seen twice, or a member met twice, says its line once a round.
    assert "bodiless.count(e->ID)" in between(src, "void watch_entity(", "\n}\n")


def test_no_snapshot_is_said_only_while_the_stream_reaches_this_client():
    """P101 review: "no snapshot of this id" (Wolf's signature: the decider streams the others, not him) only while a sample
    of some creature was taken here within kStaleMs and after the copy appeared; else Cause::NoStream, one line per gap."""
    src = entities_source()
    snapshot = between(src, "void client_on_snapshot(PeerId, Reader& r)", "\n}\n")
    taken = snapshot.find("t.samples.push_back(")
    stamp = snapshot.find("g_snapshot_in_at = now;")
    assert 0 <= taken < stamp
    assert "g_pose_gap_said = false;" in snapshot[taken:]
    watch = between(src, "void watch_pose(", "\n}\n")
    assert "f.stream = mirror_pose::stream_reaches(g_snapshot_in_at, book.since_ms, now);" in watch
    gap = between(watch, "if (cause == mirror_pose::Cause::NoStream)", "\n\t}\n")
    assert "if (due && !g_pose_gap_said)" in gap
    # Judged only once this client can take snapshots (live in an up world), not while it joins or leaves a level.
    opened = watch.find("g_stream_open_at = mirror_pose::stream_open_at(g_stream_open_at, mgr().is_live_client() && world_up(), now);")
    due = watch.find("const bool due = mirror_pose::watch_due(book, g_stream_open_at, now);")
    assert 0 <= opened < due < watch.find("if (cause == mirror_pose::Cause::NoStream)")
    assert "mirror_pose::say_now(book, cause, due)" in watch
    assert "mirror_pose::line_allowed(g_pose_gap_lines)" in gap
    assert "return;" in gap
    assert watch.find("if (cause == mirror_pose::Cause::NoStream)") < watch.find("mirror_pose::say_now(")
    rules = RULES.read_text(encoding="utf-8")
    cause = between(rules, "inline Cause cause_of(const WatchFacts& f)", "\n}\n")
    # (a) no idle partition is no line, before any snapshot is looked at
    assert cause.find("if (!idle)") < cause.find("if (!f.track || !f.samples)")
    assert "return f.stream ? Cause::NoSnapshot : Cause::NoStream;" in cause
    assert "return f.stream ? Cause::Stale : Cause::NoStream;" in cause
    assert "last_ms != 0 && last_ms >= since_ms && now_ms <= last_ms + kStaleMs" in rules
    say = between(rules, "inline bool say_now(", "\n}\n")
    assert "if (c == Cause::NoStream || !settled_now || b.said)" in say


def test_session_reset_clears_the_pose_books_and_budgets():
    src = entities_source()
    # The session reset of the module and the two it calls (the snapshots, the pose lines).
    reset = "".join(between(src, head, "\n}\n")
                    for head in ("\nvoid reset()\n{", "void reset_snapshots()", "void reset_pose_diag()"))
    for line in ("g_pose_fallbacks = 0;", "g_pose_lines = g_copy_state_lines = g_pose_gap_lines = 0;",
                 "g_snapshot_in_at = 0;", "g_pose_gap_said = false;", "g_stream_open_at = 0;", "g_decider_round_at = 0;",
                 "g_decider_unposed.clear();", "g_decider_rootctl.clear();", "g_bodiless.clear();",
                 "g_decider_lines = g_rootctl_lines = g_bodiless_lines = 0;"):
        assert line in reset, line
    # Every module-level P101/P103 counter or budget is in it (a new one must be added there too).
    for name in re.findall(r"^(?:u64|u32|bool) (g_(?:pose|decider|bodiless|rootctl|snapshot_in|copy_state)\w*)", src, re.M):
        assert name in reset, name
    books = re.findall(r"^xr_(?:map|set)<[^>\n]*> (g_(?:decider|bodiless)\w*)", src, re.M)
    assert sorted(books) == ["g_bodiless", "g_decider_rootctl", "g_decider_unposed"], books
    for name in books:
        assert f"{name}.clear();" in reset, name


def test_a_gone_talk_names_its_npc_and_the_copy_state():
    src = source(GAME / "coop" / "coop_dialog.cpp")
    denied = between(src, "void notify_denied(", "\n}\n")
    assert "talk refused by the host: %s (NPC %u here, %u on the host, [%s])" in denied
    assert "if (result == Gone && local != kNoId)" in denied
    assert "entities::describe_copy(local," in denied
    assert "notify_denied(result, msg.reason, npc);" in between(src, "void client_on_result(", "\n}\n")


def test_rules_header_is_core_and_pure():
    text = RULES.read_text(encoding="utf-8")
    assert text.startswith("// Ядро: без проверок режима (docs/MODES.md)")
    includes = re.findall(r'^#include\s+[<"]([^>"]+)[>"]', text, re.M)
    assert includes == ["cstdint", "coop_text.h"]  # coop_text.h: text helpers of the standard library only
    for word in ("is_map_server", "is_host(", "is_client(", "dedicated", "split("):
        assert word not in text, word
    # The fallback names exist in GAMMA's stalker_animation.omf on these partitions (temp/r101/server/omfdefs.py, 2026-11-25):
    # 13 norm_idle_0 part 0, 650 norm_torso_0_idle_0 part 1, 778 head_idle_0 part 2.
    assert '{"legs", "norm_idle_0"}, {"torso", "norm_torso_0_idle_0"}, {"head", "head_idle_0"}' in text


def test_native_tests_exist_for_the_rules():
    native = (ROOT / "tests" / "test_mirror_pose_rules.cpp").read_text(encoding="utf-8")
    for name in ("mirror_pose_wolf_with_another_motion_table_stands_in_his_own_idle",
                 "mirror_pose_a_copy_with_no_snapshot_stands_in_its_own_idle",
                 "mirror_pose_the_deciders_own_placeholder_is_mirrored_not_hidden",
                 "mirror_pose_a_driven_or_playing_part_is_left_alone",
                 "mirror_pose_no_stream_to_this_client_is_not_the_ids_matter",
                 "mirror_pose_stream_stamp_and_session_reset_are_wired"):
        assert f"TEST({name})" in native, name
