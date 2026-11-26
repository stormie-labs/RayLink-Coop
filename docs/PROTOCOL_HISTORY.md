# Protocol versions

`kProtocolVersion` (engine/src/xrCoop/coop_protocol.h) is bumped on any incompatible change of a message layout. Hello takes
only the same number, so two versions never meet in one session and the engine keeps no branch for an older peer. What each
version changed, as it was recorded when it was made:

```
2: TradeOp Deal, ReqMoney with deal ledger
3: EntitySound (NPC voices on clients); the EntitySnapshot animation-count byte carries creature flags (W5 C2)
4: TradeOp Deal carries item ids only, the host prices the deal (review R4 2);
   ReqSpawn carries the section and an ItemState blob instead of raw spawn bytes, marker 0xC6 (review R3 V6)
5: world epoch: Welcome and BlobBegin carry it, core WorldEpoch (client -> host), SessionReset carries the new one;
   TransitionVote carries a level changer id instead of a raw M_CHANGE_LEVEL packet (review R1 I3-I4, R2 I1, I3, I4)
6: AvatarList (host -> clients): the owner of every player character (review R3 В3)
7 (F2 T1): player money lives on the host (review R4 7). ReqMoney carries a
   change with a cause (coop_ledger.h MoneyReq) instead of an absolute amount and goes client -> host only;
   MoneyBalance 0x0190 (host -> the player it belongs to); TradeOp Deal lost `applied` and `client_money`
8 (owner, live test 2026-10-23): a player whose key has no character chooses faction and gear before the world:
   CharOffer (host -> client, answers JoinRequest), CharChoice (client -> host); the world follows the choice.
   Also in 8 (F2 T5): ReqItemEvent ends with `u16 mechanic` and `u32 paid` (an upgrade is bought from a mechanic and
   charged by the host); F3 Msg 0x01C0-0x01C6
   Also in 8 (F2 T14): coop.sync SyncSet / SyncFull / SyncRequest / SyncResult / SyncCast 0x0191-0x0195
   (xrCoop/coop_syncnet.h)
   Also in 8 (F2 T6b): MoneyBalance ends with a note (u8 kind, u8 cause, u8 verdict, u32 peer, i32 amount): 19 bytes
   instead of 8 (coop_ledger.h MoneyNote: a refusal of the host's, a gift to the receiver)
   Also in 8 (F3 T7 round 1, Rulings F3-5, F3-6, F3-8): CheckpointClaim `what` 1 tent, 2 sleeping bag, 3 pack up;
   CheckpointState flags 4 alone = the refusal of the receiver's own claim, {u8 what, u8 reason} and nothing else
   (xrCoop/coop_checkpoint_store.h)
   Also in 8 (F3 T11): RestState ends with u8 refused (the owner's copy only) and its first byte is the rest::Block
   reason; RestSleep goes to the sleepers only
   Also in 8 (F2 T12b): leased object ids - IdLease 0x0178 (host -> client), IdLeaseAck 0x0179 (client -> host)
   (xrCoop/coop_id_lease.h IdsMsg); ReqSpawn marker 0xC7 (an item the client created under a leased id, and the
   weapon a clone replaces; xrCoop/coop_spawn.h)
   Also in 8 (HUD v2 part 2): PlayerRevive ops 6..10 - Begin 6 / Cancel 7 (reviver -> host), Reviving 8 / Stopped 9
   (host -> the wounded's owner), Done 10 (host -> reviver): the hold of USE on a wounded teammate made visible
   (xrCoop/coop_revive_hold.h; the ops 0..5 and the PlayerRevive rate row are unchanged)
9 (game settings T3, owner 2026-10-23): the faction is part of the world, the player does not choose it:
   CharOffer ends with `str faction` (the world's), the host ignores CharChoice::faction (coop_newchar.h
   character_faction). The CharChoice layout is unchanged.
10 (transition wait, owner 2026-10-23): the waiting point of a level change. TransitionVote is `u8 op, u16 level changer`
   (Ready / Cancel, coop_transition.h VoteMsg; protocol 9 sent just the u16), new Msg TransitionState 0x010A (host -> all,
   coop_transition.h StateMsg: who waits at which exit)
11 (F3a split levels, owner 2026-10-24): every player may be on a different map; the host's process holds the world and
   a background map server holds each other map. Msg 0x01D0-0x01DF (LevelMap .. LoadReady: the map table, a player's
   leave and his loading barrier, the trunk between the host's process and a map server), MsgSender::TrunkOnly, scopes and
   routes (coop_scope.h), the wire layouts in coop_levels_wire.h. Hello ends with `u8 role` (0 player, 1 map server)
   and `u8 token[16]`. Also in 11, in the modules that own the layouts: PlayerState + `u16 game_vertex, u32 level_vertex`
   (T10), TransitionState + `u8 flags` (T8), WeatherSync + `u8 weather_set` (T15).
12 (live 2026-10-24: a client never saw an NPC raise its weapon): EntitySnapshot carries a stalker's item in hands,
   CreatureHolds (+ CreatureStrapped) and a u16 id after the anims.
13 (live 2026-10-24: "the NPC does not point its gun and walks oddly sideways in front of the client"): EntitySnapshot
   carries a stalker's aim, CreatureAims and 3 quaternions (spine, shoulder, head bone rotations) after the item id.
14 (owner 2026-10-25: one sleeping bag, one sleeper): RestRequest ends with `u16 bag` (coop_rest_rules.h), refusal 6
   "occupied".
15: bounded instrument state at the end of PlayerState; EntitySnapshot ends each creature with u8 instrument kind.
    Animation absence uses MotionID::invalidate (0xffff); (slot 0,index 0) is a valid motion.
17 (2026-10-30): EntityVisual 0x012D (host -> all): a host creature took a new visual (GE_CHANGE_VISUAL); the motion ids
    of the snapshots belong to the host's model, a puppet that kept the old one played other motions.
20 (F3a, owner 2026-11-01: every map is computed on the host's PC, a client never leads one): a LevelMap player row is {peer, level,
    in_world, proxy, money} (a map server takes its virtual peers from it), LevelMoveResult has no reason Led, Tunnel flags carry the
    lane, LevelEntity State names the character and has an op Money, a map server's bridge has a peer id of its own
    (coop_mapserver_rules.h kBridgeBase) in its Welcome.
21 (F3a, a player's body on a map server's level): LevelEntity State ends with LevelBodyFacts, PlayerRevive has an op OpLosses from the
   world server to a map server.
22 (F3a, one brain of the world): the state of an object handed over ends with the Lua logic of the object and its members.
23: LevelBodyFacts has `talking`: the dialog allowance of the money book holds on a map server's level too.
24 (F3a): the logic of a squad itself goes with the logic of its members: its smart and its target change hands with it.
   LevelEntity has an op Tent.
25 (F3a): the state of an object handed over names its money: a trader's stayed with the map server that led him. PlayerRevive has an op
   OpStash from the world server to a map server, LevelEntity an op Stash the other way: a hardcore retirement of a player on its level.
26 (F3a, the host's move that nobody notices, coop_soft_move.h): LoadWait has a reason (why this player loads) and two states, Away and
   Back, for who stays in his world.
27 (F3a, what the static objects of a level keep, coop_levels_logic.h): LevelEntity has an op Logic, the bytes a binder would save.
28 (F3a, a map server has no game record): PlayerRules ends with a party byte, friendly fire and whether stalkers finish a downed player.
29 (docs/DEBUG_DESIGN.md §B.3, owner 2026-11-07: debug is the server's, as sv_cheats): DebugState 0x01A1 (world server -> every player,
   the host player over the LocalLink, and every map server): on, its source, a serial, each player's personal flags
   (xrCoop/coop_debug_rules.h StateMsg).
30: atomic weapon replacement and initial spawn metadata.
31 (docs/plans/2026-11-12-split-levels-native.md §1.3, §2): a world server's own seat plays no character and the creator's
   game holds the host's rights. Welcome ends with `u8 flags` (HostSeatPlays), a PeerList row ends with `u8 flags` (Operator),
   core Msg::OperatorCommand 0x000B (the operator -> the server: one console line, xrCoop/coop_operator.h).
32: nothing a reader of 31 would misread, the number keeps builds apart: NpcSound Stop (a voice the authority stopped; a 31
   reader rejects the entry and plays the line to its end), LevelEntity Item (the wear a map server gives loot; a 31 world
   server drops the op), and the Lua of build 50 expects both ends to speak them.
33 (docs/plans/2026-11-18-two-modes.md S3, owner 2026-11-18: two modes, co-op and server; Dev build 57): Welcome ends with
   `u8 mode` (SessionMode: 1 co-op, 2 server; it must agree with HostSeatPlays), so that a client knows the mode of its session
   from the Welcome on instead of from the first LevelMap. The only bump of the build: every other wire change of it joins
   33 without another one - the partner of a talk in LevelBodyFacts and what the trunk says of a spawn for the psi phantoms of a
   map server's level (step S3, coop_levels_wire.h), the messages of F5 and kMaxPlayers 16 (docs/plans/2026-11-18-build-57.md
   section 3), and the optional u32 audit round in LevelResync and LevelEntity Report (A-S7N), which older readers ignore.
   Dev (33) and Stable (32) never meet in one session: Hello refuses the other number.
34 (TZ R32, one writer per object; temp/r30/design/R32-final.md section 5): a map server's registry facts go up in one ordered
   batch that the world server answers. Msg::LevelJournal 0x01E0 (map server -> world server, TrunkOnly) and Msg::LevelJournalAck
   0x01E1 (world server -> that map server), layouts in srv/coop_levels_wire.h: the journal ops after LevelEntity Logic (Joined ..
   Flushed), a per-object head (u16 id, u16 section crc, u32 keeper generation) before today's LevelEntity layout, ItemFacts =
   the ItemState layout plus a source byte. LevelFlush is now sent, its answer is the journal's Flushed entry. Scope rules with no
   layout change (srv/coop_mapserver_rules.h): a map server may ask its world StateDumpRequest and EntityResync, EntityDied and
   EntityHash reach the map servers. The ItemState blob carries a u16 version per tagged field (coop_item_tags.h, blob tag 12),
   the EntitySpawn tail the initial state of an item (coop_initial_rules.h). Dev 57 (33) and 34 never meet: Hello refuses it.
35 (TZ R90, a player's trade window is the host's; review 2026-11-24): TradeOp Deal flag 2 is the deal of a player's Lua trade
   window (G.A.M.M.A.'s ui_inventory), priced on the decider with that window's Lua formula, and such a deal carries
   `u32 sell_shown, u32 buy_shown` after its two lists: the sums the window showed. The decider settles each side against them
   (xrCoop/coop_trade_window_rules.h settle_side): a sale pays the smaller sum, a purchase costs what was shown. Review of
   2026-11-25 (the same Dev build, still 35): a side the decider prices worse for the player than shown beyond rounding is refused
   with TradeResult 10 (PriceChanged), whose Result carries `u32 decider_sell, u32 decider_buy` after `u32 trader_money` (only with
   code 10); flag 0 (the engine window) keeps its layout, but the decider settles its CTrade sums against the Lua formula the same
   way (with 2 RU an item for CTrade's floors). TZ R92 (the same Dev build, still 35, no layout change): the shown sums are the
   deal's price, as in single player. The decider computes the same G.A.M.M.A. formula as for itself (no player character put in)
   and compares each side either way within 1 RU + 1 RU an item (the engine window's CTrade sums: 1 RU + 3 RU an item,
   trade_window::tolerance_of); within it the side goes at the shown sum, beyond it the deal is refused with code 10, whose tail is
   for the player's log and text only (nothing agrees to it any more). A 34 reader would price flag 2 with the engine's formula and
   read no sums; Hello refuses it.
```
