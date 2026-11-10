dofile("tests/lua/support/harness_economy.lua")
dofile("tests/lua/support/clone_parts_evaluate.lua")

local function worlds()
	PLAYERS = { [0] = { nick = "host", proxy = 0 }, [1] = { nick = "owner", proxy = 501 }, [2] = { nick = "observer", proxy = 502 } }
	POS, QUEUE, WORLDS = {}, {}, {}
	for peer in pairs(PLAYERS) do
		POS[peer] = { x = 0, y = 0, z = 0 }
		local w = make_world(peer)
		load_script(w, "coop_economy_core")
		load_script(w, "coop_economy_mdata")
		w.coop_economy_mdata.on_game_start()
		for other, info in pairs(PLAYERS) do
			local id = peer == 0 and info.proxy or (other == peer and 0 or (other == 0 and PLAYERS[peer].proxy or info.proxy))
			add_entity(w, id, "coop_player_avatar", nil)
		end
		add_item(w, 800, "wpn_ak74m", peer == 1 and 0 or 501)
		w.MDATA.se_object[800] = { name = "wpn_ak74m800", parts = { wpn_ak74m = 83, barrel = 97, trigger = 41, bolt = 13 }, strapped_item = false }
		w.coop_economy_mdata.declare_item_key("clone_test_rider")
		w.MDATA.clone_test_rider = { [800] = { mark = "green" } }
	end
	return WORLDS[0], WORLDS[1], WORLDS[2]
end

section("attach then detach keeps initialized parts through the mirror's first evaluation")
do
	local h, a, b = worlds()
	local source = 800
	for _, target in ipairs({900, 901}) do
		local snapshot = assert(a.coop_economy_mdata.clone_export(source))
		local token = "tx" .. target
		check(a.coop_economy_mdata.clone_stage(source, target, "wpn_ak74m" .. target, snapshot, 0, token), "owner stages complete source")
		check(h.coop_economy_mdata.clone_stage(source, target, "wpn_ak74m" .. target, snapshot, 1, token), "host stages complete source")
		add_item(h, target, "wpn_ak74m", 501)
		clone_register_cleanup(h, target)
		clone_evaluate_parts(h, target)
		local canonical = assert(h.coop_economy_mdata.clone_export(target))
		check(b.coop_economy_mdata.clone_stage(65535, target, "wpn_ak74m" .. target, canonical, 2, token), "mirror receives initial metadata")
		add_item(b, target, "wpn_ak74m", 501)
		clone_register_cleanup(b, target)
		clone_evaluate_parts(b, target)
		check(a.coop_economy_mdata.clone_stage(source, target, "wpn_ak74m" .. target, canonical, 2, token), "owner installs host canonical snapshot")
		add_item(a, target, "wpn_ak74m", 0)
		clone_register_cleanup(a, target)
		clone_evaluate_parts(a, target)
		for _, w in ipairs({h,a,b}) do
			w.SE[source], w.OBJ[source], w.MDATA.se_object[source] = nil,nil,nil
			w.coop_economy_mdata.clone_finish(target, true)
			local parts = w.MDATA.se_object[target].parts
			check(parts.barrel==97 and parts.trigger==41 and parts.bolt==13, "disassembly input retains each asymmetric part")
		end
		check(h.RANDOM_CALLS==0 and a.RANDOM_CALLS==0 and b.RANDOM_CALLS==0, "attach/detach performs zero random generation")
		source = target
	end
	-- A stale observer cannot replace the owner's initialized parts after the commit.
	b.se_save_var(901,nil,"parts",{wpn_ak74m=83,barrel=2,trigger=3,bolt=4})
	tick(b,400) deliver_all()
	check(h.MDATA.se_object[901].parts.barrel==97 and a.MDATA.se_object[901].parts.barrel==97, "late observer garbage is refused before relay to owner")
	a.se_save_var(901, nil, "parts", {wpn_ak74m=83,barrel=66,trigger=41,bolt=13})
	tick(a,400) deliver_all()
	check(h.MDATA.se_object[901].parts.barrel==66 and b.MDATA.se_object[901].parts.barrel==66,
		"after replacement the host relays the owner's part wear with its instance stamp to observers")
end

section("registration cleanup still clears ordinary/reused ids and completed weapons")
do
	local _, a = worlds()
	clone_register_cleanup(a, 800)
	check(a.MDATA.se_object[800].parts == nil, "ordinary registration can remove stale parts")
	a.se_save_var(800,nil,"parts",{wpn_ak74m=83,barrel=97,trigger=41,bolt=13})
	local m = a.coop_economy_mdata
	check(m.clone_stage(800,900,"wpn_ak74m900",assert(m.clone_export(800)),0,"cleanup"), "replacement prepared")
	clone_register_cleanup(a, 900)
	check(a.MDATA.se_object[900].parts.barrel == 97, "pending target keeps its initialized parts")
	a.se_save_var(800,nil,"parts",nil)
	check(a.MDATA.se_object[800].parts == nil, "source cleanup remains available to the clone wrapper")
	m.clone_finish(900,true)
	a.se_save_var(900,nil,"parts",nil)
	check(a.MDATA.se_object[900].parts == nil, "completed weapon permits explicit parts removal")
end

section("successful clone: real evaluate_parts runs before the owner's 300 ms flush")
do
	local h, a, b = worlds()
	local owner, host, observer = a.coop_economy_mdata, h.coop_economy_mdata, b.coop_economy_mdata
	local snapshot = owner.clone_export and owner.clone_export(800)
	add_item(a, 900, "wpn_ak74m_scope", 0)
	a.MDATA.se_object[900] = { name = "wpn_ak74m_scope900", parts = { wpn_ak74m = 83, barrel = 97, trigger = 41, bolt = 13 } }
	if snapshot and host.clone_stage then host.clone_stage(800, 900, "wpn_ak74m_scope900", snapshot, 1, "tx1") end
	if snapshot and observer.clone_stage then observer.clone_stage(65535, 900, "wpn_ak74m_scope900", snapshot, 2, "tx1") end
	add_item(h, 900, "wpn_ak74m_scope", 501)
	add_item(b, 900, "wpn_ak74m_scope", 501)
	clone_evaluate_parts(h, 900)
	clone_evaluate_parts(b, 900)
	check(h.RANDOM_CALLS == 0 and b.RANDOM_CALLS == 0, "first real evaluate on host and mirror performs zero random rolls")
	if host.clone_finish then host.clone_finish(900, true) end
	if observer.clone_finish then observer.clone_finish(900, true) end
	tick(h, 400) deliver_all()
	local p = a.MDATA.se_object[900].parts
	check(p.barrel == 97 and p.trigger == 41 and p.bolt == 13, "host's first evaluation never overwrites the owner's asymmetric parts")
end

section("clone metadata is installed before the host and observer's spawn callbacks")
do
	local h, a, b = worlds()
	local owner, host, observer = a.coop_economy_mdata, h.coop_economy_mdata, b.coop_economy_mdata
	local snapshot = owner.clone_export and owner.clone_export(800)
	local staged = snapshot and host.clone_stage and host.clone_stage(800, 900, "wpn_ak74m_scope900", snapshot, 1, "tx1")
	local hp = h.MDATA.se_object[900]
	check(staged and hp and hp.parts.barrel == 97 and hp.parts.trigger == 41, "host callback sees the original parts before target registration")
	local mirrored = snapshot and observer.clone_stage and observer.clone_stage(65535, 900, "wpn_ak74m_scope900", snapshot, 2, "tx1")
	check(mirrored and b.MDATA.se_object[900].parts.barrel == 97, "observer callback sees the parts before target registration")
end

section("a refused speculative clone restores its cleared source")
do
	local _, a = worlds()
	local m = a.coop_economy_mdata
	local snapshot = m.clone_export and m.clone_export(800)
	if snapshot and m.clone_stage then m.clone_stage(800, 900, "wpn_ak74m_scope900", snapshot, 0, "tx1") end
	a.se_save_var(800, nil, "parts", nil) -- GAMMA's clear after its optimistic clone
	a.MDATA.clone_test_rider[800] = nil
	if m.clone_finish then m.clone_finish(900, false) end
	local p = a.MDATA.se_object[800] and a.MDATA.se_object[800].parts
	check(p and p.barrel == 97 and p.trigger == 41, "refusal restores full source parts")
	check(a.MDATA.clone_test_rider[800] and a.MDATA.clone_test_rider[800].mark == "green", "refusal restores riders")
	check(a.MDATA.se_object[900] == nil, "refusal removes speculative metadata")
end

section("unsupported or oversized metadata fails before any mutation")
do
	local _, a = worlds()
	local m = a.coop_economy_mdata
	a.MDATA.se_object[800].bad = function() end
	local snapshot = m.clone_export and m.clone_export(800)
	check(snapshot == nil, "function values are rejected instead of packed as nil")
	check(a.MDATA.se_object[800].parts.barrel == 97, "failed export preserves source parts")
	a.MDATA.se_object[800].bad = string.rep("x", 4096)
	check(not (m.clone_export and m.clone_export(800)), "oversize export is rejected")
	local cycle = {} cycle.self = cycle
	local deep = {} local cursor = deep
	for i=1,10 do cursor.child={} cursor=cursor.child end
	for _, value in ipairs({cycle, deep, setmetatable({},{}), coroutine.create(function() end), newproxy(), math.huge, 0/0}) do
		a.MDATA.se_object[800].bad=value
		check(m.clone_export(800)==nil and a.MDATA.se_object[800].parts.barrel==97, "unsupported snapshots leave source intact")
	end
	a.MDATA.se_object[800].bad=nil
	local function clock(ms)
		local value=newproxy(true)
		getmetatable(value).__index={diffSec=function() end,dateToString=function() end,ms=ms}
		return value
	end
	a.utils_data.CTime_to_table=function(v) return {Y=2026,M=11,D=10,h=0,m=0,s=0,ms=v.ms} end
	a.utils_data.CTime_from_table=function(t) return clock(t.ms) end
	a.MDATA.se_object[800].clock=clock(234)
	local packed=assert(m.clone_export(800))
	check(a.coop_economy_core.unpack(packed).se.clock.ms==234, "supported CTime round-trips without losing metadata")
	a.utils_data.CTime_from_table=function() return nil end
	check(m.clone_export(800)==nil, "failed CTime decoding refuses before mutation")
end

section("one source instance has one pending replacement and refusal purges queues")
do
	local h,a = worlds()
	local m=a.coop_economy_mdata
	local snapshot=assert(m.clone_export(800))
	check(m.clone_stage(800,900,"wpn_variant900",snapshot,0,"first"), "first replacement staged")
	check(not m.clone_stage(800,901,"wpn_variant901",snapshot,0,"second"), "second replacement of the same source refused")
	a.se_save_var(800,nil,"parts",nil)
	a.se_save_var(900,nil,"parts",{barrel=1})
	m.clone_finish(900,false)
	tick(a,400) deliver_all()
	check(h.MDATA.se_object[800].parts.barrel==97 and a.MDATA.se_object[800].parts.barrel==97, "source clear cannot escape after compensation")
	check(h.MDATA.se_object[900]==nil, "speculative target queues cannot resurrect it")
	add_item(a,900,"medkit",0) add_item(h,900,"medkit",501)
	a.se_save_var(900,nil,"looted",true)
	tick(a,800) deliver_all()
	check(h.MDATA.se_object[900] and h.MDATA.se_object[900].looted==true, "reused id accepts its new instance")
end

section("source without sevars keeps its absent table on rollback")
do
	local _,a=worlds()
	local m=a.coop_economy_mdata
	a.MDATA.se_object[800]=nil
	local snapshot=assert(m.clone_export(800))
	check(m.clone_stage(800,900,"wpn_variant900",snapshot,0,"nil-source"), "nil metadata can stage a normal first-generation weapon")
	m.clone_finish(900,false)
	check(a.MDATA.se_object[800]==nil and a.MDATA.se_object[900]==nil, "rollback preserves absent metadata without inventing parts")
end

section("review HIGH: host-only merge overflow refuses before transaction or queue mutation")
do
	local h,a,b=worlds()
	local host,owner=h.coop_economy_mdata,a.coop_economy_mdata
	h.MDATA.se_object[800].dont_release=string.rep("h",512)
	h.se_save_var(800,nil,"looted",true)
	h.MDATA.se_object[900]={name="previous900",info="previous target"}
	h.MDATA.clone_test_rider[900]={mark="previous rider"}
	local snapshot
	for size=4000,3000,-1 do
		a.MDATA.se_object[800].info=string.rep("x",size)
		snapshot=owner.clone_export(800)
		if snapshot and #snapshot<=3900 then break end
	end
	assert(snapshot and #snapshot<=3900)
	local before=assert(host.clone_export(800))
	local staged=host.clone_stage(800,900,"wpn_variant900",snapshot,1,"merge-overflow")
	check(not staged,"HIGH merged rollback snapshot exceeds bound and refuses staging")
	host.clone_finish(900,false)
	check(host.clone_export(800)==before,"HIGH refusal preserves complete source metadata and riders")
	check(h.MDATA.se_object[900] and h.MDATA.se_object[900].info=="previous target" and
		h.MDATA.clone_test_rider[900].mark=="previous rider","HIGH refusal preserves previous target")
	check(not host.clone_pending(800) and not host.clone_pending(900),"HIGH refusal leaves no transaction fence")
	tick(h,400) deliver_all()
	check(b.MDATA.se_object[800].looted==true,"HIGH refusal preserves pre-existing source outbox")
end

section("review MEDIUM: early host refusal restores pending updates, tombstones and instance stamps")
do
	local h,a,b=worlds()
	for _,w in ipairs({h,a,b}) do
		w.MDATA.se_object[800]._coop_instance="source-instance"
		w.MDATA.se_object[800].unpatched=true
		w.coop_economy_mdata.declare_item_key("clone_test_removed")
		w.MDATA.clone_test_removed={[800]=7}
	end
	h.MDATA.se_object[800].parts={wpn_ak74m=83,barrel=20,trigger=30,bolt=40}
	b.MDATA.se_object[800].parts={wpn_ak74m=83,barrel=20,trigger=30,bolt=40}
	a.INV={800}
	a.se_save_var(800,nil,"parts",{wpn_ak74m=83,barrel=97,trigger=41,bolt=13})
	a.se_save_var(800,nil,"unpatched",nil)
	a.MDATA.clone_test_rider[800]={mark="pending owner value"}
	a.MDATA.clone_test_removed[800]=nil
	local owner=a.coop_economy_mdata
	local snapshot=assert(owner.clone_export(800))
	assert(owner.clone_stage(800,900,"wpn_variant900",snapshot,0,"early-refusal"))
	a.se_save_var(800,nil,"parts",nil)
	a.MDATA.clone_test_rider[800]=nil
	owner.clone_finish(900,false) -- the host denied the native request before its Lua stage
	tick(a,400) deliver_all()
	local parts=h.MDATA.se_object[800].parts
	check(parts.barrel==97 and parts.trigger==41 and parts.bolt==13,"MEDIUM host receives restored owner parts before rejoin")
	check(h.MDATA.se_object[800].unpatched==nil,"MEDIUM pending sevar removal survives rollback")
	check(h.MDATA.clone_test_rider[800] and h.MDATA.clone_test_rider[800].mark=="pending owner value","MEDIUM restored rider is sent even on first silent poll")
	check(h.MDATA.clone_test_removed[800]==nil,"MEDIUM rider removal survives rollback")
	check(b.MDATA.se_object[800].parts.barrel==97 and b.MDATA.se_object[800].unpatched==nil,"MEDIUM mirror receives the restored source from host")
	local stamped,valid=0,true
	for _,message in ipairs(a.SENT) do
		if message.name=="economy.se" or message.name=="economy.imd" then
			local batch=CM_DECODE(message.payload)
			for i=1,batch.n do
				if batch["i"..i]==800 then stamped=stamped+1 valid=valid and batch["x"..i]=="source-instance" end
			end
		end
	end
	check(stamped>0 and valid,"MEDIUM retries retain the source instance stamp")
end

section("review MEDIUM: host compensation sends owner snapshot over older queued host parts")
do
	local h,a=worlds()
	h.se_save_var(800,nil,"parts",{wpn_ak74m=83,barrel=20,trigger=30,bolt=40})
	local snapshot=assert(a.coop_economy_mdata.clone_export(800))
	assert(h.coop_economy_mdata.clone_stage(800,900,"wpn_variant900",snapshot,1,"host-refusal"))
	h.coop_economy_mdata.clone_finish(900,false)
	tick(h,400) deliver_all()
	check(a.MDATA.se_object[800].parts.barrel==97,"MEDIUM host retries restored owner truth over its stale queued value")
end

print(string.format("%d passed, %d failed", CHECKS - FAILS, FAILS))
if FAILS > 0 then error("clone metadata failed") end
