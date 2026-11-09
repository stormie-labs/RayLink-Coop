// Appended to the shared registry fixture by pelican_repair_native.py.
#include <fstream>
#include <memory>

struct RepairRow {
    u16 id;
    std::string section;
    bool multi;
    float before_condition, after_condition;
    unsigned before_uses, after_uses;
};

std::unique_ptr<CInventoryItem> repair_item(const RepairRow& row, u16 root, bool after) {
    std::unique_ptr<CInventoryItem> item;
    if (row.multi) {
        auto food = std::make_unique<CEatableItem>();
        food->uses = u8(after ? row.after_uses : row.before_uses);
        item = std::move(food);
    } else {
        item = std::make_unique<CInventoryItem>();
    }
    item->id = row.id;
    item->root = root;
    item->section = row.section.c_str();
    item->condition = after ? row.after_condition : row.before_condition;
    return item;
}

int main(int argc, char** argv) {
    expect(argc == 2, "repair input required");
    std::ifstream input(argv[1]);
    expect(bool(input), "repair input readable");
    unsigned count, cases = 0;
    while (input >> count) {
        std::vector<RepairRow> rows(count);
        for (auto& row : rows) {
            input >> row.id >> row.section >> row.multi >> row.before_condition >> row.before_uses
                  >> row.after_condition >> row.after_uses;
            expect(bool(input), "complete Lua repair outcome");
        }
        client_objects.clear(); host_objects.clear(); client_entities.clear(); host_entities.clear();
        g_sent.clear(); g_owned.clear(); g_take_base.clear(); g_pending.clear(); outgoing.clear();
        actor.inv.m_all.clear();
        std::vector<std::unique_ptr<CInventoryItem>> storage;
        std::vector<std::unique_ptr<CSE_ALifeInventoryItem>> server_storage;
        for (const auto& row : rows) {
            for (bool is_host : {false, true}) {
                auto item = repair_item(row, is_host ? 10 : 0, false);
                auto entity = std::make_unique<CSE_ALifeInventoryItem>();
                entity->ID = row.id;
                entity->root = item->root;
                entity->s_name = item->section;
                entity->m_fCondition = row.before_condition;
                (is_host ? host_objects : client_objects)[row.id] = item.get();
                (is_host ? host_entities : client_entities)[row.id] = entity.get();
                if (!is_host) actor.inv.m_all.push_back(item.get());
                storage.push_back(std::move(item));
                server_storage.push_back(std::move(entity));
            }
        }
        select_host(false);
        scan_local(false);
        for (const auto& row : rows) {
            auto* item = client_objects.at(row.id);
            item->SetCondition(row.after_condition);
            if (row.multi) smart_cast<CEatableItem*>(item)->SetRemainingUses(u8(row.after_uses));
        }
        scan_local(false);
        expect(!outgoing.empty(), "Lua repair creates an owner ItemState report");
        flush_owner(); // actual host_on_state and host_enforce
        for (const auto& row : rows) {
            auto* host_item = host_objects.at(row.id);
            expect(quant(host_item->GetCondition()) == quant(row.after_condition), "repair condition reaches host object");
            auto* entity = smart_cast<CSE_ALifeInventoryItem*>(host_entities.at(row.id));
            expect(quant(entity->m_fCondition) == quant(row.after_condition), "repair condition reaches host ALife save source");
            if (row.multi)
                expect(smart_cast<CEatableItem*>(host_item)->GetRemainingUses() == row.after_uses,
                    "actual item uses reaches host");

            auto observer = repair_item(row, 10, false);
            CSE_ALifeInventoryItem observer_entity;
            observer_entity.ID = row.id; observer_entity.root = 10; observer_entity.s_name = row.section.c_str();
            objects[row.id] = observer.get(); entities[row.id] = &observer_entity;
            const Blob blob = state(host_item);
            push(observer.get(), blob, false, 0); // write_state -> client_on_state -> client_apply
            expect(quant(observer->GetCondition()) == quant(row.after_condition), "repair condition reaches observer");
            if (row.multi)
                expect(smart_cast<CEatableItem*>(observer.get())->GetRemainingUses() == row.after_uses,
                    "actual item uses reaches observer");
        }
        ++cases;
    }
    expect(cases > 0, "at least one Lua repair scenario");
    std::cout << "native repair ItemState " << cases << " scenarios passed\n";
}
