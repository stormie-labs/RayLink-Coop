#include <algorithm>
#include <atomic>
#include <climits>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <initializer_list>
#include <map>
#include <mutex>
#include <string>
#include <vector>
#include "../../../engine/src/xrCoop/coop_trade_permit.h" // G6-3: the permit rules the host deal reads
#include "../../../engine/src/xrCoop/coop_trade_window_rules.h" // TZ R90, R92: how the host deal checks a window's sums
using u8 = uint8_t; using u16 = uint16_t; using u32 = uint32_t; using u64 = uint64_t;
using s64 = int64_t; using PeerId = uint16_t;
template<class T> using xr_vector = std::vector<T>;
template<class T, class U> T smart_cast(U* value) { return dynamic_cast<T>(value); }
template<class... T> void Msg(const char*, T...) {}
void require(bool ok, const char* reason) { if (!ok) { std::fprintf(stderr, "%s\n", reason); std::exit(1); } }
constexpr u16 kNoId = 65535;

namespace host_test {
enum Result : u8 { Ok, NotReady, NoPlayer, NoTrader, ItemGone, NoMoney, TraderNoMoney, Malformed, TooFar, NotTraded, PriceChanged };
constexpr size_t kMaxDealItems = 1024;
constexpr float kTradeReach = 5;
constexpr s64 kMaxMoney = 0xffffffffll;
struct Object {
    virtual ~Object() = default;
    u16 id = 0, parent = kNoId;
    bool destroying = false, removed = false;
    u16 ID() const { return id; }
    bool getDestroy() const { return destroying; }
    bool object_removed() const { return removed; }
    const std::string& cNameSect() const { return section; }
    std::string section = "wpn_sil_9mm";
};
using CObject = Object; using CGameObject = Object;
struct CInventoryItem : Object {
    bool takeable = true;
    float weight = 0.2f;
    CObject& object() { return *this; }
    bool CanTake() const { return takeable; }
    float Weight() const { return weight; }
};
struct Inventory {
    bool CanTakeItem(CInventoryItem* i) const { return i && i->takeable && !i->destroying; }
};
struct CInventoryOwner : Object {
    Inventory bag;
    u32 balance = 10000;
    Inventory& inventory() { return bag; }
    bool IsTradeEnabled() const { return true; }
    bool NeedOsoznanieMode() const { return false; }
    bool InfinitiveMoney() const { return false; }
    u32 get_money() const { return balance; }
    void set_money(u32 n, bool) { balance = n; }
    virtual void on_before_sell(CInventoryItem*) {}
    virtual void on_before_buy(CInventoryItem*) {}
};
struct CAI_Stalker : CInventoryOwner { bool wounded() const { return false; } };
struct CAI_Trader : CInventoryOwner {
    struct Callback { void operator()(u32,u32) {} };
    Callback callback(int) { return {}; }
};
namespace GameObject { constexpr int eTradePerformTradeOperation = 1; }
struct CTrade { explicit CTrade(CInventoryOwner*) {} void SetActorPartner(CInventoryOwner*) {} };
struct { bool dwPrecacheFrame = false; } Device;
struct Deal { u32 seq = 1; u16 trader = 10; bool donate = false; bool lua_prices = false; xr_vector<u16> sell, buy; u32 sell_total = 0, buy_total = 0; u32 sell_shown = 0, buy_shown = 0; u32 sell_decider = 0, buy_decider = 0; };
CAI_Stalker player; CAI_Trader trader;
std::map<u16, CInventoryItem> items;
std::map<u16, u16> server_parents;
u16 reject_item = kNoId;
u32 move_calls = 0, money_changes = 0;
u64 g_host_items = 0, g_permit_deals = 0;
u32 player_balance = 10000;
CObject* find_object(u16 id) {
    if (id == player.id) return &player;
    if (id == trader.id) return &trader;
    auto it = items.find(id); return it == items.end() ? nullptr : &it->second;
}
CInventoryOwner* find_owner(u16 id) { return smart_cast<CInventoryOwner*>(find_object(id)); }
u16 server_parent(u16 id) { auto i=server_parents.find(id); return i==server_parents.end()?kNoId:i->second; }
u16 local_parent(u16 id) { auto* p=find_object(id); return p?p->parent:kNoId; }
u16 id_of(CInventoryOwner* o) { return o?o->id:kNoId; }
bool alive(CInventoryOwner*) { return true; }
bool within_reach(CInventoryOwner*,CInventoryOwner*,float) { return true; }
namespace sync { bool host_peer_joining(PeerId) { return false; } }
namespace join { u16 proxy_of_peer(PeerId) { return 501; } }
namespace world { bool is_player_proxy(u16 id) { return id==501; } }
namespace talks { constexpr u32 kTradeAfterTalkMs=100; bool may_trade_with(bool,bool,bool){return true;} }
namespace dialog { bool host_talked_recently(PeerId,u16,u32){return true;} }
namespace money {
u32 host_balance(PeerId) { return player_balance; }
u32 max_money() { return UINT_MAX; }
void host_adjust(PeerId,s64 delta,const char*) { player_balance=u32(s64(player_balance)+delta); ++money_changes; }
}
u32 clamp_money(s64 v) { return u32(v); }
u8 price_list(CTrade&, CInventoryOwner*, const xr_vector<u16>& ids, bool, u32& total) { total=u32(ids.size()*100); return Ok; }
namespace trade_window = coop::trade_window;
// TZ R90: what coop_trade_window.host_price answers on the decider (TZ R92: computed as for the decider itself), 100 RU an item as
// price_list (lua_sell_raw / lua_buy_raw: another sum for a side); a refusal (nil and why: an item the window does not trade); or
// nothing (no such script on the decider).
// lua_price_deal itself is the engine's.
u32 lua_priced = 0; trade_window::Answer lua_answer = trade_window::Answer::Priced; double lua_sell_raw = -1, lua_buy_raw = -1;
trade_window::Answer ask_host_price(u16, u16, const Deal& d, double raw[2], std::string&) {
    ++lua_priced;
    if (lua_answer != trade_window::Answer::Priced) return lua_answer;
    raw[0]=lua_sell_raw>=0?lua_sell_raw:double(d.sell.size()*100); raw[1]=lua_buy_raw>=0?lua_buy_raw:double(d.buy.size()*100);
    return trade_window::Answer::Priced;
}
// The local server updates ownership synchronously; game objects catch up on its event queue.
// Rejecting BUY after SELL leaves the entity unowned, exactly as Process_event_ownership does.
void move_item(u16 from, u16 to, u16 id) {
    ++move_calls;
    if (server_parent(id) == from) server_parents[id]=kNoId;
    if (id == reject_item) { reject_item=kNoId; return; }
    if (server_parent(id) == kNoId) server_parents[id]=to;
}
namespace trade_permit = coop::trade_permit;
// G6-3: no trading-computer permit in these deals; the stock talk and reach decide (coop_trade.cpp permit_verdict)
trade_permit::Verdict permit_verdict(PeerId, CInventoryOwner*, u16) { return trade_permit::Verdict::None; }
#include "trade_host.inc"
void add(u16 id, u16 owner, const char* section="wpn_sil_9mm") {
    auto& i=items[id]; i.id=id; i.parent=owner; i.section=section; server_parents[id]=owner;
}
bool one_of(const std::string& mode, std::initializer_list<const char*> names) {
    for (const char* n : names) if (mode == n) return true;
    return false;
}
// TZ R92: the player pays and gets exactly what his window showed, once the decider's formula (lua_buy_raw / lua_sell_raw, computed as
// for the decider itself) agrees within the tolerance: a Lua window's deal 1 RU + 1 RU an item, the engine window's (CTrade 100 RU an
// item, price_list) 1 RU + 3 RU an item. Beyond it, either way, PriceChanged with the decider's sums and nothing moves.
void run(const std::string& mode) {
    player.id=501; trader.id=10;
    Deal d; add(100,10); d.buy={100};
    const bool engine_window = mode.find("engine-window")==0 || mode=="ordinary-items";
    const bool nine_bought = one_of(mode, {"ordinary-items","lua-window-items","lua-window-refused","lua-window-purchase-shown-more",
        "lua-window-purchase-dearer","lua-window-no-formula","engine-window-no-formula","engine-window-lua-dearer",
        "engine-window-lua-refused","engine-window-lua-cheaper","lua-window-purchase-rounding","engine-window-lua-floors",
        "lua-window-purchase-within","engine-window-lua-edge-dearer","engine-window-lua-edge-cheaper","engine-window-lua-beyond-edge",
        "map-server-balance-unnamed"});
    const bool one_sold = one_of(mode, {"lua-window-wpo-part","lua-window-sale-cheaper","lua-window-sale-rounding",
        "lua-window-wpo-claimed","lua-window-sale-within-dearer","lua-window-sale-dearer","lua-window-shown-zero"});
    if(nine_bought) {
        d.lua_prices = !engine_window;
        if(mode=="lua-window-refused"||mode=="engine-window-lua-refused") lua_answer = trade_window::Answer::Refused;
        if(mode=="lua-window-no-formula"||mode=="engine-window-no-formula") lua_answer = trade_window::Answer::NoFormula;
        // what the Lua window showed (the engine window's is CTrade's 900, host_apply); the decider's formula says 900 unless set
        d.buy_shown = mode=="lua-window-purchase-shown-more" ? 1000 : mode=="lua-window-purchase-dearer" ? 850
                    : mode=="lua-window-purchase-rounding" ? 899 : 900;
        if(mode=="lua-window-purchase-within") lua_buy_raw = 910.5; // 10 RU dearer here: within 1 + 9 RU, the shown 900 is paid
        if(mode=="engine-window-lua-dearer") lua_buy_raw = 1000; // the decider's Lua formula: more than CTrade (900), which that window showed
        if(mode=="engine-window-lua-cheaper") lua_buy_raw = 700;
        // review of 2026-11-25, nit 1: CTrade floors each of the 9 items twice, the Lua formula once a side: 910 against 900 is rounding
        if(mode=="engine-window-lua-floors") lua_buy_raw = 910.7;
        // the engine window's tolerance of 9 items: 1 + 27 RU either way
        if(mode=="engine-window-lua-edge-dearer") lua_buy_raw = 928.9;
        if(mode=="engine-window-lua-edge-cheaper") lua_buy_raw = 872;
        if(mode=="engine-window-lua-beyond-edge") lua_buy_raw = 929;
        // CLAUDE.md, the Server mode: the map server judges by the last balance the world server named, 0 until it has named one
        if(mode=="map-server-balance-unnamed") player_balance = 0;
        const char* sections[]={"wpn_sil_9mm","wpn_addon_scope","ammo_9x19_fmj","medkit","bread","wpn_ak74","novice_outfit","af_medusa","repairkit"};
        d.buy.clear(); for(u16 n=0;n<9;++n){ add(u16(100+n),10,sections[n]); d.buy.push_back(u16(100+n)); }
    } else if(one_sold) {
        // a worn prt_w_barrel_10 sold to a mechanic by a Lua window, 1 item: a tolerance of 2 RU. TZ R92: the decider computes the formula as
        // for itself and the Weapon Parts Overhaul compatibility counts the player's character as the holder, so its price is the worn one
        // the window showed (1237 RU), not the mechanic's own sale price (8250 RU, part_prices.ltx).
        add(102,501,"prt_w_barrel_10"); d.buy.clear(); d.sell={102}; d.lua_prices=true;
        d.sell_shown = mode=="lua-window-wpo-part" ? 1237 : mode=="lua-window-wpo-claimed" ? 8250 : mode=="lua-window-shown-zero" ? 0 : 1000;
        lua_sell_raw = mode=="lua-window-wpo-part" ? 1237.6 : mode=="lua-window-wpo-claimed" ? 1237 : mode=="lua-window-sale-rounding" ? 999
                     : mode=="lua-window-sale-within-dearer" ? 1002 : mode=="lua-window-sale-dearer" ? 1100
                     : mode=="lua-window-shown-zero" ? 1.5 : 900;
    } else if(mode=="destroying-item") items[100].destroying=true;
    else if(mode=="removed-item") items[100].removed=true;
    else if(mode=="cannot-take") items[100].takeable=false;
    else if(mode=="stale-local-owner") items[100].parent=20;
    else if(mode=="refused-first-buy") reject_item=100;
    else if(mode=="refused-later-buy") { add(101,10);d.buy.push_back(101);reject_item=101; }
    else if(mode=="refused-sale") { add(102,501);d.buy.clear();d.sell={102};reject_item=102; }
    else if(mode=="barter-rollback") { add(102,501);d.sell={102};reject_item=100; }
    s64 delta=0; const auto result=host_apply(1,d,delta);
    const auto delivered = [&]() { for(auto id:d.buy) require(server_parent(id)==501,"every purchased item must reach the player"); };
    if(one_of(mode, {"ordinary-items","lua-window-items","engine-window-no-formula"})) {
        require(result==Ok && delta==-900 && player_balance==9100 && trader.balance==10900,"ordinary items must be delivered and paid exactly once");
        delivered();
        // review of 2026-11-25: the formula is the decider's whatever the flag: the engine window's deal meets the Lua formula too, and
        // pays what that window showed (CTrade) when the Lua formula agrees or is missing on the decider
        require(lua_priced==1u,"every deal is checked by the decider's own window's formula when it has one");
    } else if(one_of(mode, {"lua-window-purchase-rounding","engine-window-lua-floors","lua-window-purchase-within",
                            "engine-window-lua-edge-dearer","engine-window-lua-edge-cheaper"})) {
        // TZ R92: within the tolerance, either way, the purchase costs exactly what the window showed
        const s64 paid = mode=="lua-window-purchase-rounding" ? 899 : 900;
        require(result==Ok && delta==-paid && player_balance==10000-paid && trader.balance==10000+paid,"within the tolerance the purchase costs what the window showed");
        require(d.buy_total==u32(paid) && lua_priced==1u,"the deal goes at the shown sum, the decider's formula checked it");
        const u32 decider = mode=="lua-window-purchase-rounding" ? 900u : mode=="engine-window-lua-floors" || mode=="lua-window-purchase-within" ? 910u
                          : mode=="engine-window-lua-edge-dearer" ? 928u : 872u;
        require(d.buy_decider==decider,"the decider's own sum is kept for the log");
        delivered();
    } else if(one_of(mode, {"lua-window-sale-rounding","lua-window-sale-within-dearer","lua-window-wpo-part"})) {
        // TZ R92: within the tolerance, either way, the sale pays exactly what the window showed
        const s64 got = mode=="lua-window-wpo-part" ? 1237 : 1000;
        require(result==Ok && delta==got && player_balance==10000+got && trader.balance==10000-got && d.sell_total==u32(got),"within the tolerance the sale pays what the window showed");
        require(server_parent(102)==10,"the sold item went to the trader");
        if(mode=="lua-window-wpo-part") require(d.sell_decider==1237,"the worn part's price here is the window's, no player character put in");
    } else if(one_of(mode, {"lua-window-purchase-dearer","engine-window-lua-dearer","lua-window-sale-cheaper","lua-window-wpo-claimed",
                            "lua-window-purchase-shown-more","lua-window-sale-dearer","engine-window-lua-cheaper","engine-window-lua-beyond-edge"})) {
        require(result==PriceChanged,"a side beyond the tolerance, either way, is refused for its price");
        require(delta==0 && player_balance==10000 && trader.balance==10000 && money_changes==0 && move_calls==0,"a refusal for the price moves nothing");
        require(d.sell_total==0 && d.buy_total==0,"a refusal for the price pays nothing");
        for(auto id:d.buy) require(server_parent(id)==10,"the items stay with the trader");
        for(auto id:d.sell) require(server_parent(id)==501,"the player's items stay his");
        // the Result carries the decider's sums (for the player's log and text)
        if(mode=="lua-window-purchase-dearer"||mode=="lua-window-purchase-shown-more") require(d.buy_decider==900 && d.sell_decider==0,"the refusal carries the decider's price of the purchase");
        if(mode=="engine-window-lua-dearer") require(d.buy_decider==1000 && lua_priced==1u,"the engine window's deal meets the Lua formula");
        if(mode=="engine-window-lua-cheaper") require(d.buy_decider==700 && lua_priced==1u,"the engine window's deal far from the Lua formula is refused either way");
        if(mode=="engine-window-lua-beyond-edge") require(d.buy_decider==929,"one RU beyond the engine window's tolerance is refused");
        if(mode=="lua-window-sale-cheaper") require(d.sell_decider==900 && d.buy_decider==0,"the refusal carries the decider's price of the sale");
        if(mode=="lua-window-sale-dearer") require(d.sell_decider==1100,"a sale the window showed too cheap is refused, not paid at the decider's price");
        if(mode=="lua-window-wpo-claimed") require(d.sell_decider==1237,"a modified window gets nothing for a claimed price");
    } else if(mode=="map-server-balance-unnamed") {
        require(result==NoMoney && lua_priced==1u,"the Server mode: no balance named yet is no money for a purchase");
        require(delta==0 && player_balance==0 && trader.balance==10000 && money_changes==0 && move_calls==0,"no money moves nothing");
    } else {
        require(result!=Ok,"failed delivery must not report a successful purchase");
        require(delta==0 && player_balance==10000 && trader.balance==10000 && money_changes==0,"failed delivery must not move money");
        for(auto id:d.buy) require(server_parent(id)==10,"failed purchase must remain at/return to trader");
        for(auto id:d.sell) require(server_parent(id)==501,"failed barter must restore player's items");
        if(mode=="destroying-item"||mode=="removed-item"||mode=="cannot-take"||mode=="stale-local-owner"||mode=="lua-window-refused"
           ||mode=="lua-window-no-formula"||mode=="engine-window-lua-refused"||mode=="lua-window-shown-zero")
            require(move_calls==0,"invalid item must be rejected before any ownership event");
        if(mode=="lua-window-refused"||mode=="lua-window-no-formula")
            require(result==NotTraded && lua_priced==1,"no price from the Lua window's formula refuses the deal, without a fallback price");
        if(mode=="engine-window-lua-refused")
            require(result==NotTraded && lua_priced==1,"what the decider's own window would not trade is not traded through the engine window either");
        if(mode=="lua-window-shown-zero")
            require(result==NotTraded && d.sell_total==0,"a side the window showed for nothing is no deal, even within the tolerance");
    }
}
} // namespace host_test

namespace mirror_test {
enum class Step { Wait, Fail, Done };
struct Fvector {
    float x = 0, y = 0, z = 0;
    Fvector& set(float new_x, float new_y, float new_z) {
        x = new_x;
        y = new_y;
        z = new_z;
        return *this;
    }
};
struct ParentTarget {u16 parent=0; u64 since=0; bool dump_asked=false,extended=false,failed=false,online=true,exact_pos=false; Fvector pos;};
std::map<u16,ParentTarget> g_parent_targets;
bool g_pGameLevel=true;
struct AI { bool get_alife(){return true;} }; AI ai(){return {};}
u64 clock_ms=100;
struct Manager {
    u64 now_ms() const { return clock_ms; }
    bool is_live_client() const { return true; }
};
Manager& mgr() { static Manager manager; return manager; }
constexpr u64 kDumpAfterMs=1000,kPendingTimeoutMs=5000,kExtendMs=10000;
struct Counters {u64 parent_timeouts=0,parent_failed=0,parent_applied=0,dropped_before_live=0;} g_c;
struct Obj {const std::string& cNameSect(){static std::string s="wpn_sil_9mm";return s;}} object;
using CGameObject=Obj;
using CSE_Abstract=Obj;
namespace world {
CSE_Abstract* server_entity(u16) { return &object; }
CGameObject* object_here(u16) { return &object; }
}
const char* entity_name(u16){return "wpn_sil_9mm";}
Step next_step=Step::Fail;
Step step_parent(u16,const ParentTarget&){return next_step;}
namespace join {u16 to_host(u16 n){return n;} u16 to_local(u16 n){return n;}}
namespace reconcile {constexpr u8 Spawn=1,Parent=4,State=16;
// xrCoop/coop_reconcile.h stalled_ask (R32 WP5 fix round, verify-D finding 2): Spawn only for an id this copy lacks
inline u8 stalled_ask(bool here){return here ? u8(Parent|State) : u8(Spawn|Parent|State);}}
struct Writer {explicit Writer(int){} u16 id=0;u8 flags=0;void u16(uint16_t n){id=n;} void u8(uint8_t n){flags=n;}};
struct Reader {
    int i=0;
    uint16_t u16(){const uint16_t ids[]={100,10,0};return ids[i++];}
    bool boolean(){return true;} void vec3(float* p){p[0]=p[1]=p[2]=0;}
    uint8_t u8(){return 0;} bool ok(){return true;}
};
enum class Msg {StateDumpRequest,EntityParent};
namespace rules { bool live_only(Msg type) { return type == Msg::EntityParent; } }
namespace entities {void client_on_holder_changed(u16,u16,bool){}}
std::vector<Writer> requests;
namespace net {void client_send(Msg,const Writer& w){requests.push_back(w);}}
#include "trade_mirror.inc"
void run(const std::string& mode){
    g_parent_targets[100]={};
    if(mode=="mirror-success") next_step=Step::Done;
    if(mode=="mirror-timeout") {g_parent_targets[100].extended=true;clock_ms=kExtendMs+1;}
    if(mode=="mirror-repair-mask") clock_ms=kPendingTimeoutMs+1;
    if(mode=="mirror-repeated-reply") {
        auto& target=g_parent_targets[100]; target.since=42;target.extended=true;
        next_step=Step::Wait; Reader reply; client_on_entity_parent(0,reply);
        require(g_parent_targets.at(100).since==42 && g_parent_targets.at(100).extended,"repeated holder reply must not reset the retry budget");
        return;
    }
    client_step_parents();
    if(mode=="temporary-mirror-rejection") {
        require(g_parent_targets.count(100)==1,"temporary ownership rejection must remain queued");
        next_step=Step::Done; ++clock_ms; client_step_parents();
        require(g_parent_targets.empty() && g_c.parent_applied==1,"the same item must be delivered on retry");
    } else if(mode=="mirror-repair-mask") {
        require(!requests.empty(),"failed delivery must request authoritative repair");
        require((requests.front().flags & reconcile::Parent)!=0,"repair must include parent: default Spawn|Died does not repair existing items");
    } else if(mode=="mirror-timeout") require(g_parent_targets.empty()&&g_c.parent_timeouts==1,"repair must stop after bounded timeout");
    else require(g_parent_targets.empty()&&g_c.parent_applied==1,"successful delivery must not be repeated");
}
}
namespace callback_test {
using mirror_test::Writer; using mirror_test::Msg; using mirror_test::reconcile::Parent;
namespace reconcile=mirror_test::reconcile;
namespace join=mirror_test::join;
namespace net=mirror_test::net;
constexpr u64 kCallbackWaitMs=3000, kCallbackRepairWaitMs=45000, kPendingWarnMs=15000;
u64 now=4000;
u16 holder=10;
u32 callbacks=0;
struct Manager { u64 now_ms() const { return now; } };
Manager& mgr() { static Manager manager; return manager; }
void search_frame(){} void client_sync_world(){} void request_rebuild(u64){}
bool is_mirror(){return true;} bool is_live_mirror(){return true;}
u16 local_parent(u16){return holder;}
struct CGameObject {virtual ~CGameObject()=default; void* lua_game_object(){return this;}} item;
struct CActor {
    struct Callback {void operator()(void*,bool,u32){++callbacks;}};
    Callback callback(int){return {};}
} actor;
namespace GameObject {constexpr int eTradeSellBuyItem=1;}
CActor* Actor(){return &actor;} CGameObject* find_object(u16){return &item;}
struct Pending {bool warned=false;u64 sent_at=0;};
std::map<u32,Pending> g_pending;
std::atomic<bool> g_have_queued{false}; std::mutex g_deal_lock; void send_queued_locked(){} // TZ R90: the Lua window's queue
struct TradeCallback;
extern std::vector<TradeCallback> g_callbacks;
#include "trade_callback.inc"
std::vector<TradeCallback> g_callbacks;
void run(const std::string& mode){
    g_callbacks.push_back({100,0,false,100,3000});
    if(mode=="callback-arrived") holder=0;
    frame();
    if(mode=="callback-arrived") require(callbacks==1 && g_callbacks.empty(),"delivered item must emit one purchase callback");
    else {
        require(callbacks==0,"a purchase callback must never run on a still-unowned item");
        require(!mirror_test::requests.empty() && (mirror_test::requests.front().flags&Parent),"missing purchase must request its authoritative holder");
        if(mode=="callback-expired") {
            now+=kCallbackRepairWaitMs+1;frame();
            require(callbacks==0 && g_callbacks.empty(),"undelivered item expires without a false purchase callback");
        } else {
            holder=0;++now;frame();
            require(callbacks==1 && g_callbacks.empty(),"repaired delivery must emit its callback once");
        }
    }
}
}
namespace request_test {
using xr_string = std::string;
enum class Reason;
struct Fvector;
struct CSE_Abstract;
Reason admitted_move(u16 item, u16 src, u16 dst, const Fvector* drop_pos, xr_string& refused);
namespace world { CSE_Abstract* server_entity(u16 id); }

bool is_map_authority();
struct Mode {
    bool decides_world() const { return is_map_authority(); }
    bool leads_level() const { return is_map_authority(); }
    bool decides_here() const { return decides_world() || leads_level(); }
};
Mode& mode() { static Mode mode; return mode; }
}
#include "request_move_fixture.h"
namespace request_test {
namespace world { CSE_Abstract* server_entity(u16 id) { return events::find_entity(id); } }

// These gifts have no container rule. Keep the real ownership checks and rollback.
Reason admitted_move(u16 item, u16 src, u16 dst, const Fvector* drop_pos, xr_string&)
{
    return apply_move(item, src, dst, drop_pos);
}
}
namespace deal_test {
// Review of 2026-11-25 (TZ R92, lua_flow#1): host_on_deal as the engine has it (trade_deal.inc). A deal refused for its price sends the
// player the states of the trader's items and his money before the Result, on the same lane, when he may see that trader (a talk, or a
// trading computer's permit, which nothing revokes now: his window keeps its view open). Any other answer, a repeated deal, a joining
// player and a trader he may not see get the Result alone, as before.
namespace trade_window = coop::trade_window;
namespace trade_permit = coop::trade_permit;
using trade_window::kDealDonate; using trade_window::kDealLuaPrices;
using s32 = int32_t;
constexpr u16 kMaxDealItems = 1024;
constexpr PeerId kPlayer = 7;
constexpr u16 kTrader = 10, kComputer = 20, kItem = 100;
enum TradeResult : u8 { Ok, NotReady, NoPlayer, NoTrader, ItemGone, NoMoney, TraderNoMoney, Malformed, TooFar, NotTraded, PriceChanged };
enum ContainerKind : u8 { ContNone = 0, ContBox = 1, ContCorpse = 2, ContTrader = 3 };
enum class Op : u8 { Request = 1, Result = 2, TraderMoney = 3, Deal = 4 };
enum class Msg : u8 { TradeOp, ItemState };
struct Writer {
    std::vector<uint32_t> v;
    explicit Writer(size_t) {}
    void u8(uint8_t n) { v.push_back(n); }
    void u16(uint16_t n) { v.push_back(n); }
    void u32(uint32_t n) { v.push_back(n); }
    void i32(int32_t n) { v.push_back(uint32_t(n)); }
};
struct Reader {
    std::vector<uint32_t> v; size_t at = 0; bool good = true;
    uint32_t next() { if (at >= v.size()) { good = false; return 0; } return v[at++]; }
    uint32_t u32() { return next(); }
    uint16_t u16() { return uint16_t(next()); }
    uint8_t u8() { return uint8_t(next()); }
    bool ok() const { return good; }
};
struct Deal { u32 seq = 0; u16 trader = kNoId; bool donate = false; bool lua_prices = false; xr_vector<u16> sell, buy;
    u32 sell_total = 0, buy_total = 0, sell_shown = 0, buy_shown = 0, sell_decider = 0, buy_decider = 0; };
struct Object { virtual ~Object() = default; u16 id = 0; };
using CObject = Object;
struct CInventoryBox : Object {};
struct CInventoryOwner : Object { u32 money = 4321; u32 get_money() const { return money; } };
CInventoryOwner the_trader;
CObject* find_object(u16 id) { return id == the_trader.id ? &the_trader : nullptr; }
CInventoryOwner* find_owner(u16 id) { return smart_cast<CInventoryOwner*>(find_object(id)); }
bool alive(CInventoryOwner*) { return true; }
// what reached the player, in order: "contents:<holder>", "money:<trader>:<money>", "result:<code>"
std::vector<std::string> sent;
u32 broadcasts = 0, applied = 0;
bool joining = false;
u16 talk_lock = kNoId;
u8 apply_code = Ok;
namespace net {
void host_send(PeerId to, Msg type, const Writer& w) {
    require(to == kPlayer && type == Msg::TradeOp && !w.v.empty(), "only the player who dealt gets a TradeOp");
    if (w.v[0] == uint32_t(Op::Result)) sent.push_back("result:" + std::to_string(w.v[3]));
    else if (w.v[0] == uint32_t(Op::TraderMoney)) sent.push_back("money:" + std::to_string(w.v[1]) + ":" + std::to_string(w.v[2]));
    else sent.push_back("other");
}
}
namespace items { void host_send_contents(PeerId to, u16 holder) { require(to == kPlayer, "contents go to the player who dealt"); sent.push_back("contents:" + std::to_string(holder)); } }
namespace sync { bool host_peer_joining(PeerId) { return joining; } }
namespace dialog { u16 host_lock_of(PeerId) { return talk_lock; } bool host_talked_recently(PeerId, u16, u32) { return false; } }
namespace talks { constexpr u32 kTradeAfterTalkMs = 100; }
trade_permit::Book book;
trade_permit::Book& permits() { return book; }
void host_sync_world() {}
const char* result_name(u8) { return "?"; }
struct PeerInfo { std::string nick = "player"; };
struct Session { const PeerInfo* peer(PeerId) const { static PeerInfo p; return &p; } };
struct Manager {
    Session s;
    Session& session() { return s; }
    u64 now_ms() const { return 1000; }
};
Manager& mgr() { static Manager m; return m; }
u64 g_host_deals = 0, g_host_ok = 0, g_host_rejected = 0;
void host_broadcast_trader_money(CInventoryOwner*, PeerId except) { require(except == kPlayer, "the broadcast skips the dealer"); ++broadcasts; }
u8 host_apply(PeerId, Deal& d, s64& delta) {
    ++applied;
    delta = apply_code == Ok ? -300 : 0;
    if (apply_code == PriceChanged) d.buy_decider = 345;
    return apply_code;
}
#include "trade_deal_types.inc"
std::map<PeerId, PeerTrade> g_peers;
#include "trade_deal.inc"
Reader deal_of(u32 seq) {
    Reader r; r.v = { seq, kTrader, kDealLuaPrices, 0, 1, kItem, 0, 300 }; // sell nothing, buy one item, shown 0 and 300 RU
    return r;
}
std::string joined() { std::string s; for (const auto& m : sent) s += (s.empty() ? "" : ",") + m; return s; }
void run(const std::string& mode) {
    the_trader.id = kTrader;
    apply_code = mode.find("deal-ok")==0 ? u8(Ok) : u8(PriceChanged);
    if (mode=="deal-price-changed-talk" || mode=="deal-price-changed-joining" || mode=="deal-price-changed-repeat" || mode=="deal-ok-sends-the-result")
        talk_lock = kTrader;
    // The real host_apply answers NotReady for a joining peer before any price (coop_trade.cpp host_apply); here it is stubbed to
    // PriceChanged on purpose, to check host_send_trader_view's own guard against a joining peer.
    if (mode=="deal-price-changed-joining") joining = true;
    if (mode=="deal-price-changed-computer")
        require(book.issue(kPlayer, kComputer, kTrader, 1000, 60000, 3.f) && book.covers(kPlayer, kTrader, 1000), "the computer's permit is issued");
    Reader r = deal_of(5);
    host_on_deal(kPlayer, r);
    const std::string first = joined();
    const std::string view = "contents:10,money:10:4321,result:10";
    if (mode=="deal-price-changed-talk" || mode=="deal-price-changed-computer") {
        require(first == view, "a refusal for its price sends the trader's items, then his money, then the Result");
        // host_on_deal itself touches no permit; that the window keeps its view open (no close, so no revoke in host_on_container)
        // is guarded by the Lua test (test_trade_window.lua: #VIEWS) and the source check for REOPEN_MS. Here: the contents go by
        // the computer permit alone (no talk lock, no recent talk).
        if (mode=="deal-price-changed-computer") require(book.find(kPlayer) != nullptr, "host_on_deal touches no permit: the computer's one is still issued");
    } else if (mode=="deal-price-changed-unseen" || mode=="deal-price-changed-joining") {
        require(first == "result:10", "a trader the player may not see, or a joining player: the Result alone");
    } else if (mode=="deal-ok-sends-the-result") {
        require(first == "result:0" && broadcasts == 1, "an accepted deal sends the Result alone (and the money to the others)");
    } else if (mode=="deal-price-changed-repeat") {
        require(first == view, "the first answer sends the trader's data");
        sent.clear();
        Reader again = deal_of(5);
        host_on_deal(kPlayer, again);
        require(joined() == "result:10" && applied == 1, "a repeated deal gets the stored Result alone, nothing sent again");
    } else require(false, "unknown deal scenario");
}
} // namespace deal_test
int main(int argc,char** argv){
    require(argc==2,"scenario required");std::string mode=argv[1];
    if(mode.find("gift-")==0) request_test::run(mode);
    else if(mode.find("deal-")==0) deal_test::run(mode);
    else if(mode.find("mirror")!=std::string::npos) mirror_test::run(mode);
    else if(mode.find("callback")!=std::string::npos) callback_test::run(mode);
    else host_test::run(mode);
}
