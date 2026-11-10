// Model the engine boundary: SELL detaches immediately, BUY can be refused.
// Both native request code paths are compiled from the production source.
namespace request_test {
enum class Reason { Ok, Engine, Offline, NotAllowed, Moved, Missing };
struct Fvector {};
struct CSE_Abstract { virtual ~CSE_Abstract()=default; u16 ID_Parent=1; };
struct CSE_ALifeDynamicObject : CSE_Abstract {
    bool m_bOnline=true; int m_tGraphID=0; Fvector o_Position; std::vector<u16> children;
};
struct CSE_ALifeInventoryItem : CSE_ALifeDynamicObject {};
struct NET_Packet;
struct CGameObject {
    virtual ~CGameObject()=default;
    u16 id=0; CGameObject* parent=nullptr; bool destroying=false;
    CGameObject* H_Parent(){return parent;} u16 ID()const{return id;}
    static void u_EventGen(NET_Packet&,int,u16){} static void u_EventSend(NET_Packet&){}
};
struct CInventoryItem : CGameObject { bool takeable=true; };
struct Inventory { bool full=false; bool CanTakeItem(CInventoryItem* i){return i->takeable&&!full;} };
struct CInventoryOwner : CGameObject { Inventory bag; Inventory& inventory(){return bag;} };
CInventoryOwner sender, receiver;
CInventoryItem item;
CSE_ALifeInventoryItem entity;
bool reject_take=false;
int sent_events=0;
CGameObject* valid_go(u16 id) {
    CGameObject* o=id==1?static_cast<CGameObject*>(&sender):id==2?static_cast<CGameObject*>(&receiver):id==3?&item:nullptr;
    return o&&!o->destroying?o:nullptr;
}
namespace events {
CSE_Abstract* find_entity(u16 id){return id==3?&entity:nullptr;}
void host_set_drop_position(u16,const Fvector&){}
void host_on_parent_changed(u16,u16,u16){}
}
constexpr int GE_TRADE_SELL=1, GE_OWNERSHIP_REJECT=2, GE_TRADE_BUY=3, GE_OWNERSHIP_TAKE=4, GE_CHANGE_POS=5;
void inject_item_event(int kind,u16 holder,u16 id) {
    require(id==3,"must preserve the same entity");++sent_events;
    if(kind==GE_TRADE_SELL||kind==GE_OWNERSHIP_REJECT) {
        if(entity.ID_Parent==holder)entity.ID_Parent=kNoId;
    } else if(entity.ID_Parent==kNoId && !(reject_take&&holder==2)) entity.ID_Parent=holder;
}
struct NET_Packet { void w_vec3(const Fvector&){} };
struct Objects { CSE_ALifeDynamicObject* object(u16 id,bool){return id==3?&entity:nullptr;} };
struct Graph { void detach(CSE_ALifeDynamicObject&,CSE_ALifeInventoryItem*,int,bool,bool){} void attach(CSE_ALifeDynamicObject&,CSE_ALifeInventoryItem*,int,bool,bool){} };
struct Alife { Objects objects(){return {};} Graph graph(){return {};} };
struct AI { Alife alife(){return {};} };
AI ai(){return {};} Alife alife_rw(){return {};}
bool authority=true;
bool is_map_authority(){return authority;}
const char* reason_name(Reason){return "test";}
#include "request_move.inc"
void run(const std::string& mode) {
    sender.id=1;receiver.id=2;item.id=3;item.parent=&sender;
    if(mode.find("gift-host-script")==0) {
        authority=mode!="gift-host-script-offline";
        reject_take=mode=="gift-host-script-refused";
        bool stale=mode=="gift-host-script-stale";
        bool handled=host_transfer_item(3,stale?7:1,2);
        require(handled==authority,"host must consume a refused gift, single player must fall through");
        require(entity.ID_Parent==(mode=="gift-host-script"?2:1),"host script transfer must preserve ownership on failure");
        return;
    }
    u16 from=1,to=2;
    if(mode=="gift-rejected-take")reject_take=true;
    if(mode=="gift-cannot-take")item.takeable=false;
    if(mode=="gift-recipient-full")receiver.bag.full=true;
    if(mode=="gift-stale-owner")item.parent=&receiver;
    if(mode=="gift-destroying-recipient")receiver.destroying=true;
    if(mode=="gift-drop")to=kNoId;
    if(mode=="gift-ground-take"){from=kNoId;item.parent=nullptr;entity.ID_Parent=kNoId;}
    Reason result=apply_move(3,from,to,nullptr);
    if(mode=="gift-success"||mode=="gift-drop"||mode=="gift-ground-take") {
        require(result==Reason::Ok && entity.ID_Parent==to,"accepted transfer must reach its recipient");
    } else {
        require(result!=Reason::Ok,"invalid transfer must fail");
        require(entity.ID_Parent==1,"failed gift must remain with / return to its sender");
        if(mode!="gift-rejected-take")require(sent_events==0,"reject invalid transfer before detaching");
    }
}
}
