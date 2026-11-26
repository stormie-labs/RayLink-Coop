"""Exercise the registered identity API and its existing digest access rules in Lua."""
import re
import subprocess

import check_gates
from native_slice import ROOT, build, definition


def test_registered_player_digest_uses_existing_identity_and_access_rules(work):
    text = (ROOT / "engine/src/xrGame/coop/coop_sync_api.cpp").read_text(encoding="utf-8-sig")
    registration = definition(text, "void register_lua(")
    assert '{"player_digest", &l_player_digest}' in registration
    methods = "\n".join(definition(text, name) for name in (
        "bool client(", "PeerId self_peer(", "const std::string& own_digest(", "bool peer_digest(",
        "int l_player_digest("))
    functions = set(re.findall(r'\{"[^"\n]+", &(l_\w+)\}', registration))
    stubs = "\n".join(f"int {name}(lua_State*) {{ return 0; }}" for name in sorted(functions - {"l_player_digest"}))
    source = HARNESS.replace("// METHODS", methods).replace("// OTHER_API", stubs).replace("// REGISTER", registration)
    fixture = work / "identity.cpp"
    fixture.write_text(source, encoding="utf-8")
    lib = check_gates.lua51_lib(ROOT)
    assert lib.is_file(), f"the engine's lua51.lib is required (LUA51_LIB): {lib}"
    runner = build(work, "cl /nologo /MD /EHsc /std:c++17 /utf-8", [fixture], work / "identity.exe",
                   includes=[ROOT / "engine/src/3rd party/luajit-2/src", ROOT / "engine/src/xrGame/coop"], libs=[lib])
    result = subprocess.run([str(runner), str(ROOT)], capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stdout + result.stderr


HARNESS = r'''
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <map>
#include <string>
extern "C" {
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
}
#include "coop_lua.h"
namespace lua_api = coop::lua_api;
using PeerId = uint16_t;
constexpr PeerId kHostPeer=0, kInvalidPeer=65535;
struct PeerInfo { std::string key; bool joined=true; };
struct Session {
    std::map<PeerId, PeerInfo> peers;
    const PeerInfo* peer(PeerId id) { auto it=peers.find(id); return it==peers.end()?nullptr:&it->second; }
};
struct Manager {
    bool enabled=true, host=true;
    PeerId id=0;
    Session s;
    bool active() { return enabled; }
    bool is_host() { return host; }
    bool is_client() { return !host; }
    PeerId self() { return id; }
    Session& session() { return s; }
    const char* player_key() { return "own"; }
} manager;
Manager& mgr() { return manager; }
std::string g_own_digest;
std::map<PeerId,std::string> g_peer_digest;
bool key_digest_hex(const std::string& key, std::string& out) { out=std::string(64,key=="own"?'a':'b'); return true; }
void follow_role() { g_peer_digest.clear(); }
void forget_lua() {}
bool in_world(PeerId id) { auto p=manager.s.peer(id); return manager.host && p && p->joined; }
bool decides_sync_store() { return manager.active() && manager.is_host(); }
namespace net { bool client() { return mgr().is_client(); } }
// METHODS
// OTHER_API
// REGISTER
void check(lua_State* L, const char* code) {
    if(luaL_dostring(L,code)) { std::cerr<<lua_tostring(L,-1)<<'\n'; std::exit(1); }
}
int main(int argc, char** argv) {
    assert(argc==2);
    lua_State* L=luaL_newstate(); luaL_openlibs(L);
    lua_newtable(L); lua_setglobal(L,"coop"); register_lua(L);
    manager.s.peers[1]={"remote",true}; manager.s.peers[2]={"pending",false};
    check(L,"assert(coop.sync.player_digest(0)==string.rep('a',64)); assert(coop.sync.player_digest(1)==string.rep('b',64)); assert(coop.sync.player_digest(2)==nil); assert(coop.sync.player_digest(9)==nil)");
    check(L,"for _,x in ipairs({-1,0.5,65535,0/0,math.huge,'0',true,{}}) do assert(coop.sync.player_digest(x)==nil) end; assert(coop.sync.player_digest()==nil)");
    manager.host=false; manager.id=1;
    check(L,"assert(coop.sync.player_digest(1)==string.rep('a',64)); assert(coop.sync.player_digest(0)==nil); assert(coop.sync.player_digest(2)==nil)");
    manager.enabled=false;
    check(L,"assert(coop.sync.player_digest(1)==nil)");
    manager.enabled=true; manager.host=true; manager.id=0;
    lua_pushstring(L,argv[1]); lua_setglobal(L,"test_root");
    check(L,R"lua(
        function coop.is_active() return true end
        function coop.is_host() return true end
        coop_mode = { decides_world = function() return true end }
        function coop.players() return {{id=0,is_self=true},{id=1,avatar_id=501},{id=2,avatar_id=502}} end
        local data={}
        -- the host's rule trader_rep (f77f52a, 2026-11-12): the default "best" would give the best player's 1200; the
        -- identity check needs every player's value, so it runs under "mean_online" and checks "best" at the end
        TRADER_MODE="mean_online"
        coop_economy_core={rule=function(key) if key=="trader_rep" then return TRADER_MODE end end}
        alife_storage_manager={get_state=function() return data end}
        game_relations={factions_table={"stalker"}}
        game={get_game_time=function() return {get=function() return 2026,11,10,12,0,0,0 end} end}
        relation_registry={community_goodwill=function(_,id) return ({[0]=1200,[501]=600,[502]=300})[id] end}
        function alife_object(id)
            return {spawn_ini=function() return {
                section_exist=function() return true end, line_exist=function() return true end,
                r_string=function() return string.rep(id==501 and 'b' or 'c',64) end
            } end}
        end
        local function module(name)
            local env=setmetatable({}, {__index=_G})
            _G[name]=env
            setfenv(assert(loadfile(test_root.."/gamedata/scripts/"..name..".script")),env)()
            return env
        end
        module("coop_util")
        module("coop_trader_state")
        local reputation=module("coop_trader_reputation")
        reputation.refresh()
        local mean,count=reputation.average("stalker")
        assert(mean==700 and count==3,"registered native identity must include the host in the real trader consumer")
        local binding=coop.sync.player_digest
        coop.sync.player_digest=nil
        reputation.refresh()
        assert(reputation.average("stalker")==nil,"missing native binding must reproduce the closed consumer")
        coop.sync.player_digest=binding
        reputation.refresh()
        assert(reputation.average("stalker")==700)
        TRADER_MODE="best"
        reputation.refresh()
        assert(reputation.average("stalker")==1200,"the best player's standing (the host's 1200) under the rule best")
    )lua");
    lua_close(L);
}
'''
