#include <algorithm>
#include <atomic>
#include <climits>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <mutex>
#include <string>
#include <vector>
#include "../../../engine/src/xrCoop/coop_trade_permit.h" // G6-3: the permit rules the host deal reads
#include "../../../engine/src/xrCoop/coop_trade_window_rules.h" // TZ R90: how the host deal prices a Lua window's deal
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
// TZ R90: what coop_trade_window.host_price answers on the decider, 100 RU an item as price_list (lua_sell_raw / lua_buy_raw: another
// sum for a side); a refusal (nil and why: an item the window does not trade); or nothing (no such script on the decider).
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
void run(const std::string& mode) {
    player.id=501; trader.id=10;
    Deal d; add(100,10); d.buy={100};
    const bool engine_window = mode.find("engine-window")==0 || mode=="ordinary-items";
    if(mode=="ordinary-items"||mode=="lua-window-items"||mode=="lua-window-refused"||mode=="lua-window-purchase-shown-more"
       ||mode=="lua-window-purchase-dearer"||mode=="lua-window-no-formula"||mode=="engine-window-no-formula"
       ||mode=="engine-window-lua-dearer"||mode=="engine-window-lua-refused"||mode=="engine-window-lua-cheaper"
       ||mode=="lua-window-purchase-rounding"||mode=="engine-window-lua-floors") {
        d.lua_prices = !engine_window;
        if(mode=="lua-window-refused"||mode=="engine-window-lua-refused") lua_answer = trade_window::Answer::Refused;
        if(mode=="lua-window-no-formula"||mode=="engine-window-no-formula") lua_answer = trade_window::Answer::NoFormula;
        d.buy_shown = mode=="lua-window-purchase-shown-more" ? 1000 : mode=="lua-window-purchase-dearer" ? 850
                    : mode=="lua-window-purchase-rounding" ? 899 : 900; // the window showed
        if(mode=="engine-window-lua-dearer") lua_buy_raw = 1000; // the decider's Lua formula: more than CTrade (900), which that window showed
        if(mode=="engine-window-lua-cheaper") lua_buy_raw = 700;
        // review of 2026-11-25, nit 1: CTrade floors each of the 9 items twice, the Lua formula once a side: 910 against 900 is rounding
        if(mode=="engine-window-lua-floors") lua_buy_raw = 910.7;
        const char* sections[]={"wpn_sil_9mm","wpn_addon_scope","ammo_9x19_fmj","medkit","bread","wpn_ak74","novice_outfit","af_medusa","repairkit"};
        d.buy.clear(); for(u16 n=0;n<9;++n){ add(u16(100+n),10,sections[n]); d.buy.push_back(u16(100+n)); }
    } else if(mode=="lua-window-wpo-part") {
        // R90 review: a worn prt_w_barrel_10 sold to a mechanic. The decider's formula says 8250 RU (the mechanic's own sale price:
        // its owner there is the player's character, id 501, not the actor), the player's window showed 1237 RU.
        add(102,501,"prt_w_barrel_10"); d.buy.clear(); d.sell={102}; d.lua_prices=true; d.sell_shown=1237; lua_sell_raw=8250;
    } else if(mode=="lua-window-sale-cheaper"||mode=="lua-window-sale-rounding"||mode=="lua-window-wpo-claimed") {
        // review of 2026-11-25: the decider pays less than the window showed: 1 RU is rounding, more is refused for its price. A modified
        // window that claims a worn part's price from the mechanic's list (8250) meets the decider's worn price (1237): refused too.
        add(102,501,"prt_w_barrel_10"); d.buy.clear(); d.sell={102}; d.lua_prices=true;
        d.sell_shown = mode=="lua-window-wpo-claimed" ? 8250 : 1000;
        lua_sell_raw = mode=="lua-window-sale-rounding" ? 999 : mode=="lua-window-wpo-claimed" ? 1237 : 900;
    } else if(mode=="destroying-item") items[100].destroying=true;
    else if(mode=="removed-item") items[100].removed=true;
    else if(mode=="cannot-take") items[100].takeable=false;
    else if(mode=="stale-local-owner") items[100].parent=20;
    else if(mode=="refused-first-buy") reject_item=100;
    else if(mode=="refused-later-buy") { add(101,10);d.buy.push_back(101);reject_item=101; }
    else if(mode=="refused-sale") { add(102,501);d.buy.clear();d.sell={102};reject_item=102; }
    else if(mode=="barter-rollback") { add(102,501);d.sell={102};reject_item=100; }
    s64 delta=0; const auto result=host_apply(1,d,delta);
    if(mode=="ordinary-items"||mode=="lua-window-items"||mode=="engine-window-no-formula"||mode=="engine-window-lua-cheaper") {
        require(result==Ok && delta==-900 && player_balance==9100 && trader.balance==10900,"ordinary items must be delivered and paid exactly once");
        for(auto id:d.buy) require(server_parent(id)==501,"every purchased item must reach the player");
        // review of 2026-11-25: the formula is the decider's whatever the flag: the engine window's deal meets the Lua formula too, and
        // pays what that window showed (CTrade) when the Lua formula is cheaper or missing on the decider
        require(lua_priced==1u,"every deal is priced by the decider's own window's formula when it has one");
    } else if(mode=="lua-window-purchase-rounding"||mode=="engine-window-lua-floors") {
        // review of 2026-11-25: rounding is no refusal, and it costs the trader, not the player: the purchase costs what was shown
        const s64 paid = mode=="lua-window-purchase-rounding" ? 899 : 900;
        require(result==Ok && delta==-paid && player_balance==10000-paid && trader.balance==10000+paid,"rounding: the purchase costs what the window showed");
        require(d.buy_decider==(mode=="lua-window-purchase-rounding" ? 900u : 910u) && lua_priced==1u,"the decider's formula priced it");
        for(auto id:d.buy) require(server_parent(id)==501,"every purchased item must reach the player");
    } else if(mode=="lua-window-sale-rounding") {
        require(result==Ok && delta==999 && player_balance==10999 && d.sell_total==999,"1 RU of rounding: the sale pays the decider's price");
    } else if(mode=="lua-window-purchase-dearer"||mode=="engine-window-lua-dearer"||mode=="lua-window-sale-cheaper"||mode=="lua-window-wpo-claimed") {
        require(result==PriceChanged,"a purchase dearer or a sale cheaper than the window showed is refused for its price");
        require(delta==0 && player_balance==10000 && trader.balance==10000 && money_changes==0 && move_calls==0,"a refusal for the price moves nothing");
        for(auto id:d.buy) require(server_parent(id)==10,"the items stay with the trader");
        for(auto id:d.sell) require(server_parent(id)==501,"the player's items stay his");
        if(mode=="lua-window-purchase-dearer") require(d.buy_decider==900 && d.sell_decider==0,"the refusal carries the decider's price of the purchase");
        if(mode=="engine-window-lua-dearer") require(d.buy_decider==1000 && lua_priced==1u,"the engine window's deal meets the Lua formula");
        if(mode=="lua-window-sale-cheaper") require(d.sell_decider==900 && d.buy_decider==0,"the refusal carries the decider's price of the sale");
        if(mode=="lua-window-wpo-claimed") require(d.sell_decider==1237,"a modified window gets no more than the worn part's price");
    } else if(mode=="lua-window-purchase-shown-more") {
        require(result==Ok && delta==-1000 && player_balance==9000 && trader.balance==11000,"a purchase never costs less than the window showed");
        for(auto id:d.buy) require(server_parent(id)==501,"every purchased item must reach the player");
    } else if(mode=="lua-window-wpo-part") {
        require(result==Ok && delta==1237 && player_balance==11237 && trader.balance==8763,"a sale never pays more than the window showed (WPO part)");
        require(d.sell_total==1237 && server_parent(102)==10,"the part went to the mechanic for the shown price");
    } else {
        require(result!=Ok,"failed delivery must not report a successful purchase");
        require(delta==0 && player_balance==10000 && trader.balance==10000 && money_changes==0,"failed delivery must not move money");
        for(auto id:d.buy) require(server_parent(id)==10,"failed purchase must remain at/return to trader");
        for(auto id:d.sell) require(server_parent(id)==501,"failed barter must restore player's items");
        if(mode=="destroying-item"||mode=="removed-item"||mode=="cannot-take"||mode=="stale-local-owner"||mode=="lua-window-refused"
           ||mode=="lua-window-no-formula"||mode=="engine-window-lua-refused")
            require(move_calls==0,"invalid item must be rejected before any ownership event");
        if(mode=="lua-window-refused"||mode=="lua-window-no-formula")
            require(result==NotTraded && lua_priced==1,"no price from the Lua window's formula refuses the deal, without a fallback price");
        if(mode=="engine-window-lua-refused")
            require(result==NotTraded && lua_priced==1,"what the decider's own window would not trade is not traded through the engine window either");
    }
}
} // namespace host_test

namespace mirror_test {
enum class Step { Wait, Fail, Done };
struct Fvector {void set(float,float,float){}};
struct ParentTarget {u16 parent=0; u64 since=0; bool dump_asked=false,extended=false,failed=false,online=true,exact_pos=false; Fvector pos;};
std::map<u16,ParentTarget> g_parent_targets;
bool g_pGameLevel=true;
struct AI { bool get_alife(){return true;} }; AI ai(){return {};}
u64 clock_ms=100;
struct Manager { u64 now_ms(){return clock_ms;} }; Manager mgr(){return {};}
constexpr u64 kDumpAfterMs=1000,kPendingTimeoutMs=5000,kExtendMs=10000;
struct Counters {u64 parent_timeouts=0,parent_failed=0,parent_applied=0;} g_c;
struct Obj {const std::string& cNameSect(){static std::string s="wpn_sil_9mm";return s;}} object;
using CGameObject=Obj;
Obj* find_entity(u16){return &object;} Obj* find_go(u16){return &object;}
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
bool before_live(Msg){return false;}
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
u64 now_ms(){return now;}
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
Reason admitted_move(u16 item, u16 src, u16 dst, const Fvector* drop_pos, xr_string& refused);

bool is_map_authority();
struct Mode {
    bool decides_world() const { return is_map_authority(); }
    bool leads_level() const { return is_map_authority(); }
};
Mode mode() { return {}; }
}
#include "request_move_fixture.h"
namespace request_test {
// These gifts have no container rule. Keep the real ownership checks and rollback.
Reason admitted_move(u16 item, u16 src, u16 dst, const Fvector* drop_pos, xr_string&)
{
    return apply_move(item, src, dst, drop_pos);
}
}
int main(int argc,char** argv){
    require(argc==2,"scenario required");std::string mode=argv[1];
    if(mode.find("gift-")==0) request_test::run(mode);
    else if(mode.find("mirror")!=std::string::npos) mirror_test::run(mode);
    else if(mode.find("callback")!=std::string::npos) callback_test::run(mode);
    else host_test::run(mode);
}
