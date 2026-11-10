#include <algorithm>
#include <climits>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <string>
#include <vector>
using u8 = uint8_t; using u16 = uint16_t; using u32 = uint32_t; using u64 = uint64_t;
using s64 = int64_t; using PeerId = uint16_t;
template<class T> using xr_vector = std::vector<T>;
template<class T, class U> T smart_cast(U* value) { return dynamic_cast<T>(value); }
template<class... T> void Msg(const char*, T...) {}
void require(bool ok, const char* reason) { if (!ok) { std::fprintf(stderr, "%s\n", reason); std::exit(1); } }
constexpr u16 kNoId = 65535;

namespace host_test {
enum Result : u8 { Ok, NotReady, NoPlayer, NoTrader, ItemGone, NoMoney, TraderNoMoney, Malformed, TooFar, NotTraded };
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
struct Deal { u32 seq = 1; u16 trader = 10; bool donate = false; xr_vector<u16> sell, buy; u32 sell_total = 0, buy_total = 0; };
CAI_Stalker player; CAI_Trader trader;
std::map<u16, CInventoryItem> items;
std::map<u16, u16> server_parents;
u16 reject_item = kNoId;
u32 move_calls = 0, money_changes = 0;
u64 g_host_items = 0;
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
// The local server updates ownership synchronously; game objects catch up on its event queue.
// Rejecting BUY after SELL leaves the entity unowned, exactly as Process_event_ownership does.
void move_item(u16 from, u16 to, u16 id) {
    ++move_calls;
    if (server_parent(id) == from) server_parents[id]=kNoId;
    if (id == reject_item) { reject_item=kNoId; return; }
    if (server_parent(id) == kNoId) server_parents[id]=to;
}
#include "trade_host.inc"
void add(u16 id, u16 owner, const char* section="wpn_sil_9mm") {
    auto& i=items[id]; i.id=id; i.parent=owner; i.section=section; server_parents[id]=owner;
}
void run(const std::string& mode) {
    player.id=501; trader.id=10;
    Deal d; add(100,10); d.buy={100};
    if(mode=="ordinary-items") {
        const char* sections[]={"wpn_sil_9mm","wpn_addon_scope","ammo_9x19_fmj","medkit","bread","wpn_ak74","novice_outfit","af_medusa","repairkit"};
        d.buy.clear(); for(u16 n=0;n<9;++n){ add(u16(100+n),10,sections[n]); d.buy.push_back(u16(100+n)); }
    } else if(mode=="destroying-item") items[100].destroying=true;
    else if(mode=="removed-item") items[100].removed=true;
    else if(mode=="cannot-take") items[100].takeable=false;
    else if(mode=="stale-local-owner") items[100].parent=20;
    else if(mode=="refused-first-buy") reject_item=100;
    else if(mode=="refused-later-buy") { add(101,10);d.buy.push_back(101);reject_item=101; }
    else if(mode=="refused-sale") { add(102,501);d.buy.clear();d.sell={102};reject_item=102; }
    else if(mode=="barter-rollback") { add(102,501);d.sell={102};reject_item=100; }
    s64 delta=0; const auto result=host_apply(1,d,delta);
    if(mode=="ordinary-items") {
        require(result==Ok && delta==-900 && player_balance==9100 && trader.balance==10900,"ordinary items must be delivered and paid exactly once");
        for(auto id:d.buy) require(server_parent(id)==501,"every purchased item must reach the player");
    } else {
        require(result!=Ok,"failed delivery must not report a successful purchase");
        require(delta==0 && player_balance==10000 && trader.balance==10000 && money_changes==0,"failed delivery must not move money");
        for(auto id:d.buy) require(server_parent(id)==10,"failed purchase must remain at/return to trader");
        for(auto id:d.sell) require(server_parent(id)==501,"failed barter must restore player's items");
        if(mode=="destroying-item"||mode=="removed-item"||mode=="cannot-take"||mode=="stale-local-owner")
            require(move_calls==0,"invalid item must be rejected before any ownership event");
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
namespace reconcile {constexpr u8 Spawn=1,Parent=4,State=16;}
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
#include "request_move_fixture.h"
int main(int argc,char** argv){
    require(argc==2,"scenario required");std::string mode=argv[1];
    if(mode.find("gift-")==0) request_test::run(mode);
    else if(mode.find("mirror")!=std::string::npos) mirror_test::run(mode);
    else if(mode.find("callback")!=std::string::npos) callback_test::run(mode);
    else host_test::run(mode);
}
