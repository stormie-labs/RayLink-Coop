# Ф2 задача 8 — id для `alife_create` у клиента (разведка, 2026-10-22 21:30)

Разведка только чтением, по `docs/MOD_LAYER.md` §2.3 и §6, `docs/plans/2026-10-22-f2-mod-layer.md` Task 8. Источники:
- движок — `engine/src` (пути даны от `engine/src/xrGame`, если не сказано иначе);
- сток Anomaly — `anomaly-ref/unpacked/scripts` (по имени файла, номера строк стока);
- GAMMA — `E:\GAMMA\mods`, профиль `G.A.M.M.A` из MO2 (`profiles\G.A.M.M.A\modlist.txt`: 579 включённых модов, 360 из них
  со `gamedata\scripts`). Пути GAMMA даны как `<мод>/<скрипт>:строка`;
- наш Lua — `gamedata/scripts`.

Ничего не собиралось и не запускалось. Всё ниже — по коду; «в игре не проверялось».

---

## 0. Коротко

**Решение: (а) — резерв id (аренда) и создание у клиента сразу, хост подтверждает или откатывает. Задачу 12b вести.**

Рамка решения, чтобы 12b не разрослась:
1. **Аренда — только на id.** Хост берёт у `xrServer` свободные номера (`PerformIDgen(0xffff)`), клиент занимает те же номера у
   себя. Сейв и «ID already used» это не ломает (§1.5–1.7).
2. **Что клиент создаёт сразу:** предметы в свой инвентарь, путь `create(…, false)` → `register`, клоны оружия. Это 50–70 %
   вызовов в коде, который у клиента исполняется после задачи 10 (92 из 184 прямо — в актора, деталями и клонами; плюс часть
   из 42 вызовов «владелец — переменная», §3.2).
3. **Мировые вещи (палатка, рюкзак-тайник, мина, костёр, мебель, светящаяся палка) — вторая очередь той же 12b:**
   хост принимает их по белому списку классов, радиусу и лимиту (сейчас `required_lines` пускает только предметы,
   `coop_spawn.h:141-161`). Без этого у клиента остаётся откат на каждый вызов.
4. **Остаётся `nil`** (и домен `host`): существа, отряды, аномалии, вертолёты, `level_changer`, рестрикторы — всё, что делает
   мировая логика хоста. Лут на трупе мутанта (`ui_mutant_loot`) — тоже запросом к хосту: это общее состояние, а не вещь игрока.
5. **(б) отвергнут как основной путь** (§5.1): результат используется в 31 % клиентских вызовов GAMMA (57 из 184, 30 скриптов,
   ещё 6 оборачивают глобальные функции), и там `nil` даёт потерю предмета, дубль или ошибку Lua; `cond`/`uses` теряются и там,
   где результат не нужен. Патч на каждый мод — 30+ скриптов GAMMA. (б) остаётся для того, что не вошло в п. 2–3.

**Что мешает:**
- Сейчас у клиента `alife_clone_weapon` отдаёт объект с `id = 65535`, и стоковые данные (`m_data.se_object`, части оружия)
  пишутся в ключ 65535 — это живая ошибка независимо от решения (§3.3, строка 1).
- Нужны два предварительных куска: `CID_Generator::is_free` (его нет) и ответ на вопрос «чьи ключи `m_data` по новым id» для задачи 15
  (§5.4).

---

## 1. Как хост выдаёт id

### 1.1 Где живёт генератор
- Один на сервер: `xrServer::m_tID_Generator`, тип `CID_Generator<u32, u8, u16, u8, u16, 0, 0xFFFE, 256, 0xFFFF>`
  (`xrServer.h:144-158`). Доступ — `PerformIDgen(id)` / `FreeID(id, time)` / `clear_ids()` (`xrServer.h:172-185`).
- ALife собственного генератора **не имеет**: `CALifeSimulatorBase` зовёт `server().PerformIDgen(…)`
  (`alife_simulator_base.cpp:108,166,210`; `alife_dynamic_object.cpp:294`; `alife_trader_abstract.cpp:263`).
- Пространство — 65 534 номера (0…0xFFFE, `0xFFFF` = «любой» / «нет»). Всё в одной куче: объекты ALife (онлайн и офлайн),
  не-ALife сущности сервера (граната-снаряд, ракета, болт), фантомы (`xrServer_process_spawn.cpp:79`).

### 1.2 Как генератор выбирает номер (`id_generator.h`)
- 256 блоков по 256 номеров; в блоке — список свободных.
- `tfGetID(0xFFFF)` берёт блок с **самым давним** временем освобождения среди непустых (`std::min_element` +
  `operator<`, :35-38, :101) и достаёт из него последний элемент (:71). Свежеосвобождённые номера идут в хвост очереди.
- `tfGetID(x)` с конкретным номером ищет его в списке блока и при отсутствии падает:
  `R_ASSERT2(…, "Requesting ID has already been used!")` (:75). Это и есть «ID already used».
- `vfFreeID(id, time)` возвращает номер и ставит блоку время (:106-125). Нет ни «свободен ли», ни счётчика свободных
  номеров: наружу торчит только `R_ASSERT2(m_available_count, "Not enough IDs")` (:100) — это число **непустых блоков**.

### 1.3 Кто и когда берёт/возвращает номер
| Момент | Место | Что |
|---|---|---|
| Новый предмет скриптом | `alife_simulator_base.cpp:108` `spawn_item` | любой номер, потом `register_object` |
| Предмет в **онлайн**-держателя | `alife_simulator_script.cpp:216-231` (`spawn_item2`) | номер берётся в `spawn_item(…, false)`, пишется в пакет, **возвращается** `FreeID(item->ID, 0)` (:222), `Process_spawn` забирает его снова: `E->ID = PerformIDgen(E->ID)` (`xrServer_process_spawn.cpp:87,112`) |
| Тот же приём | `alife_simulator_script.cpp:299,445`; наш `coop_items.cpp:1393` (`spawn_box`) | |
| Смена онлайн/офлайн | `alife_switch_manager.cpp:57-61` (`add_online`: `entity_Destroy` освобождает, `Process_spawn(…, существующий)` забирает), `:92-96` (`remove_online`: `PerformIDgen(object_id)`) | **номер офлайн-объекта в генераторе занят** |
| Удаление | `xrServer.cpp:865-883` `entity_Destroy`: `FreeID(P->ID, Device.TimerAsync())` | |
| Загрузка сейва | `alife_storage_manager.cpp:152-158`: `PerformIDgen(id)` для **каждого** объекта | перед этим `clear_ids()` (`game_sv_single.cpp:354`); новая игра: `alife_update_manager.cpp:263` занимает 0 для актора |

Вывод: генератор хоста — это точный список «какие номера заняты миром». Всё, что не занято, свободно.

### 1.4 Что в сейве
Сейв хранит id внутри объектов, состояния генератора там нет (поиск `m_tID_Generator` — только `xrServer.h/.cpp`).
Номера, которые хост взял впрок, но которым не создал объект, после загрузки свободны — **как раз то, что нужно** для аренды.

### 1.5 Где уже ломается «ID already used» (R2 minor)
- `coop_events.cpp:719` (`client_on_entity_local`): перед `Level().Send(spawn)` с `e->ID = id` (:734) проверяется только
  `ID_to_entity(id)`. Карта `entities` не знает **офлайн**-объекты ALife, а генератор знает → при рассинхроне номера
  `Process_spawn` → `PerformIDgen(id)` → FATAL.
- `coop_entities.cpp:571-579` (`client_on_spawn`): две проверки (`objects().object(id)`, `ID_to_entity(id)`), затем
  `PerformIDgen(id)` (:612). Не покрыты: номер занят, но объекта нет ни там, ни там (переход `spawn_item` между
  `PerformIDgen` и `Process_spawn`, утечка при неполном release).
- Лекарство общее: **`bool CID_Generator::is_free(id)`** (сканирование списка блока, `O(256)`) и проверка им вместо
  `ID_to_entity` во всех клиентских местах. Закрывает R2 minor независимо от аренды.

### 1.6 Можно ли выделить клиенту блок — да
Механика (хост):
1. `PerformIDgen(0xffff)` N раз → номера выпали из оборота хоста: ни `spawn_item`, ни переключение их не выдадут;
2. список хранится по пиру: `leases[peer] = {id…}`; клиенту уходит `IdLease{epoch, ids[]}` (ordered reliable, как все `Req*`).
Механика (клиент): для каждого номера `is_free` → `PerformIDgen(id)` в **своём** генераторе (иначе локальный не-ALife объект
может занять номер раньше — тот же класс, что R2 minor); занятые отдаются обратно хосту (`IdLeaseAck{rejected[]}` →
`FreeID(id, now)`).

Расход:
- N = 48 на клиента, подпитка 1:1 после каждого израсходованного номера (в том же кадре, одним сообщением).
- `kMaxPlayers = 8` (`coop_protocol.h:27`) → не больше 7 × 48 = 336 номеров из 65 534. Для GAMMA это мало: стоковый скрипт
  предупреждает при 64 000 объектов (`_g.script:2057`), типичный сейв заметно меньше.
- Хост не выдаёт аренду, когда остаётся мало непустых блоков (нужен `available()` — публичный геттер `m_available_count`).

### 1.7 Что аренда не ломает
- **Сейв:** аренда в нём не хранится; создание по арендованному номеру кладёт объект с обычным id. После загрузки сейва хоста
  `clear_ids()` + эпоха мира (`join::host_world_epoch`, `coop_join.h:55-58`): аренды сбрасываются, клиенты получают новые.
- **Обмен ролями 0 ↔ прокси** (`coop_join.h:78-85`): арендованные номера берутся из свободных, 0 и номера прокси среди них
  быть не может; замены `to_local/to_host` для них — тождество.
- **Хост-создание:** при `ReqSpawn` с арендованным номером хост делает `FreeID(id, 0)` и пишет `e->ID = id` в пакет:
  `Process_spawn` забирает его через `PerformIDgen(E->ID)` — тот же приём, что уже есть в `spawn_item2`/`spawn_box`.
  Условие: номер **принадлежит** этому пиру и не потрачен (иначе `R_ASSERT` = падение хоста). Проверка обязательна до `FreeID`.
- Эхо: после регистрации хост рассылает `EntitySpawn` всем, включая автора (`coop_entities.cpp:89-105,834-838`). У автора номер
  уже есть → `client_on_spawn` вернётся на `objects().object(id,true)` (:571-572). Для арендованных это надо превратить в
  «подтверждение + применение авторитетного состояния» (§5.3).

---

## 2. Поля CSE: что заполняет клиент, что перезаписывает хост

Клиент строит заготовку `make_temp` (`coop_requests.cpp:574-598`), хост строит **свою** из секции (`host_on_spawn` →
`make_temp`, :791-864, затем `host_spawn` :736-789). Клиентский CSE хост не читает: по проводу идут секция, родитель,
позиция и блоб состояния предмета (`coop_spawn.h:26-29,86-97`).

| Поле | Клиент `make_temp` | Хост `host_spawn` | Замечание |
|---|---|---|---|
| `s_name`, `name_replace` | секция; `name_replace = секция` | как у клиента (из своего `make_temp`) | **У `spawn_item` имя = секция + id с нулями** (`alife_simulator_base.cpp:114-124`); у запросной цепочки без суффикса. Для предметов не критично; для `name()`-ключей — отличие |
| `ID` | `0xFFFF` | `0xFFFF`, номер выдаёт `Process_spawn` | **Здесь аренда меняет контракт:** клиент ставит арендованный, хост подтверждает тот же |
| `ID_Parent` | родитель клиента | родитель из запроса (проверен `host_spawn_holder` :720-731: корень — прокси, держатель онлайн) | |
| `ID_Phantom`, `RespawnTime`, `s_RP` | `0xFFFF`, —, `0xFF` | `0xFFFF`, 0, `0xFF` | |
| `m_wVersion` | `SPAWN_VERSION` | как у клиента | |
| `o_Position` | позиция клиента | **позиция держателя** (:758) | позиция клиента для детей инвентаря игнорируется |
| `m_tNodeID`, `m_tGraphID` | вершины клиента | вершины держателя (:764-770) | |
| `m_tSpawnID` | `-1` | `-1` | |
| `m_story_id`, `m_spawn_story_id` | не трогает | `INVALID_*` (:759-763) | |
| магазин оружия | полный (`get_ammo_magsize`, :595-596) | полный (из хостовского `make_temp`), потом блоб | |
| состояние предмета | в блоб: `ItemData` (`coop_items.cpp:79-99`): состояние, апгрейды, коробка патронов, аддоны, прицел, магазин и ГП, `uses` | `host_apply_spawn_state` (:1842-1869): типы, счётчики по вместимости, порядок апгрейдов, диапазоны | остальное **теряется** |
| `spawn_supplies()`, `on_spawn()` | нет | нет (в отличие от `spawn_item` :141-142) | для предметов пусто; для контейнеров с `[spawn]` — отличие |

Что теряется по дороге (важно для (б), и для аренды тоже, пока не расширен блоб):
- правки CSE, которых нет в `ItemData`: `custom_data`, `angle`, визуал, данные лампы/зоны (`utils_stpk.get_lamp_data`,
  `get_anom_zone_data`), `m_story_id`;
- `cond/uses` из опций `alife_create_item` (применяются позже по id, §3.3).

Что **не** годится как есть для миров вещей (п. 3 рамки): `required_lines` требует `inv_weight` и `cost`
(`coop_spawn.h:141-145`) — «заодно это держит не-предметы снаружи». У `ph_tent`/`ph_sleepbag` (класс `physic_destroyable_object`,
`configs\models\dynamic_objects.ltx:637,644`) и `inv_backpack`/`hidden_box` (`inventory_box`, `items_anim.ltx:688,690`) этих строк
нет → `BadSection` (`coop_requests.cpp:820-846`). Мировые вещи требуют отдельной ветки с белым списком классов.

---

## 3. Кто использует результат `alife_create*` в коде, который после задачи 10 исполняется у клиента

### 3.1 Что видит мод у клиента сегодня
- `alife():create/create_ammo/spawn_item*` у клиента (`alife_simulator_script.cpp:193-261`) → `lua_create` (`coop_requests.cpp:1628-1648`):
  - родитель — свой актор, `register=true`: `ReqSpawn` уходит (`lua_forward` :600-610 → `client_forward_spawn` :1424-1464),
    мод получает **`nil`**;
  - родитель мир или чужой: отказ с записью в лог (:1429-1430), **`nil`**;
  - `register=false`: возвращается временный CSE с `ID = 0xFFFF` (`g_lua_temps` :308), потом `alife():register` →
    `lua_register_spawn` (:1680-1688) пересылает его как `ReqSpawn`;
  - `clone_weapon` — то же (:1650-1678).
- Вне `Live` (`LoadingWorld`) вызовы молча гасятся (`not_live`, :1431-1435).
- Хост отвечает `ReqResult` с id созданного объекта в `subject` (:863), клиент его только считает (:530-556).

### 3.2 Масштаб
Стандартный стек стока: `alife_create` (`_g.script:2071`), `alife_create_item` (:2147 → `itms_manager.create_item` :1149 →
`ItemProcessor:Create_Item` :1254), `create_ammo` (:2333), `alife_clone_weapon` (:2257).

**Сток:** 65 файлов (без `*debug*`), около 224 вызовов `alife_create*`/`create_ammo`/`clone_weapon` (rg по строкам, без `function`).

**GAMMA (профиль G.A.M.M.A, включённые моды):**
- 583 вхождения в 188 файлах; после схлопывания копий одного скрипта (по имени файла + тексту строки) — **348 вызовов**,
  113 разных имён скриптов;
- по прикидке на уровне файлов (домен `host` — death/treasure/smr/tasks/sim/xr_effects/…; остальное owner/view): **156 в host-скриптах,
  192 исполняются у клиента**; без определений функций — **184 вызова в 59 скриптах**;
- из 184 клиентских:

  | Класс | Вызовов | Пояснение |
  |---|---|---|
  | `alife_create_item(…, актор)` | 74 | в свой инвентарь |
  | `alife_create_item(…, владелец-переменная)` | 42 | `npc`/`owner`/ящик; часть — тот же актор через параметр |
  | `alife_create(…, мир)` | 18 | реквизит в мире |
  | `alife_create_item(…, {pos,…})` | 8 | предмет в мире |
  | `alife_clone_weapon` | 11 | смена/снятие аддона |
  | `create(…, родитель, false)` + `register` | 7 | детали, правка CSE через `STATE_Write/Read` |
  | `alife():create`/`create_ammo` напрямую | 7 | |
- **результат используется** в 57 из 184 (31 %), в 30 скриптах — и ещё в цепочках обёрток: 6 скриптов (3DSS, canted irons) и
  Magazines Redux оборачивают `_G.alife_create_item` / `_G.alife_clone_weapon` и работают с возвращённым объектом.

### 3.3 Топ-20 мест

Домен — как его получит скрипт по правилам задачи 9–10: `actor_*`, `ActorMenu_*`, `on_key_*`, `GUI_*`, UI-классы → owner/view.

| № | Место | Домен | Что создаётся и кому | Что делает с объектом | Итог при `nil` сегодня |
|---|---|---|---|---|---|
| 1 | `_g.script:2257-2289` `alife_clone_weapon` (зовут `item_weapon.script:88,124`; GAMMA: `haru_quick_action_wheel_mcm:1128,1138,1170,1180`, `ish_toggle_scope:373`, `magnifier_switch:552`, `arti_jamming:795`, `aol_mp412_scopes:35`, обёртки `207- …Magazines…/mags_patches.script:321-359`, `410- 3DSS…/z_3dss_thermal_battery.script:516-518`) | owner (меню, клавиши) | клон оружия владельца | ключ `se_obj_new.id` для `m_data.se_object` и `item_parts.copy_parts_con` (:2267-2278), `set_data(new_wep.id, …)` у Magazines, `alife():register`, `alife_release(старое)` | у клиента `id = 65535`: данные частей/магазина пишутся в ключ 65535 и теряются, у старого ключа очищаются. **Живая ошибка по коду** |
| 2 | `itms_manager.script:1254-1401` `Create_Item` (все `alife_create_item`) | owner/view | предмет владельцу | `Uses[se_itm.id]`, `Cond[se_itm.id]` (:1363,1382), опрос объекта по id | `cond`, `uses` не применяются; `printe` на каждый вызов |
| 3 | `itms_manager.script:997-1018` `relocate_item_to_actor` (диалоги, обмен) | view/owner | предмет актору | `id = se_obj and se_obj.id` → `ui_pda_npc_tab.register_pda(npc, section, id)`, `process_item(section, id, {uses})` | `printe("bugged")` и `break`: цикл выдачи обрывается, PDA не регистрируется, порции не выставлены |
| 4 | `itms_manager.script:675-680` `use_place` | owner | предмет в мире | `alife_release_id(obj)` **до** создания; `se_obj.angle = …` без проверки | предмет потерян + ошибка Lua |
| 5 | `itms_manager.script:591` `use_deployable_mgun` | owner | пулемёт в мире | результат не используется | мировой объект не создаётся (отказ хоста), использованный предмет не возвращается |
| 6 | `item_parts.script:123-127,204-208,354-358` (+`item_parts_repair_notifications`, `zzzz_arti_jamming_repairs:207,824`) | owner/view | деталь в инвентарь, `create(…, false)` | `utils_stpk.get_item_data` → `STATE_Write/Read` → условие → `alife():register` | **работает** без id (`g_lua_temps` + блоб); теряет только поля вне `ItemData` |
| 7 | `item_tent.script:37-42,134-137` | owner | `ph_tent`, `ph_sleepbag` в мире | `se_obj.id` → `level.map_add_object_spot_ser`, `spawned_tents[id]`, `spawned_sleepbags[id]` (в `m_data`) | ошибка индекса, палатка потрачена |
| 8 | `item_tent.script:139-141,170-171` | owner | спальник в инвентарь | `ui_sleep_dialog.sleep_bag(se_obj,sec)`, `save_var(…,se_obj.id)` | ошибка |
| 9 | `item_backpack.script:20-31,210-220` | owner/view | `inv_backpack` (тайник) в мире | `map_add_object_spot_ser(se_obj.id)`, `m_data.player_created_stashes[se_obj.id]`, дальше вещи в ящик | `if se_obj` → тайник не создан, рюкзак израсходован |
| 10 | `item_mine.script:173-195`, `txr_mines.script:60-66` | owner | мина/СВУ в мире (`II_EXPLO`) | `m_mine_table.priming[se_obj.id]`, `planted_se:name()`, `.position`, `.id` | мина не ставится, предмет израсходован / ошибка |
| 11 | `bind_item.script:45-48` `func_separate` | owner | отделённая порция в инвентарь | `if se_obj then obj:set_remaining_uses(uses-1)` | **дубль предмета:** хост создал новую порцию, старая осталась полной |
| 12 | `xr_effects.script:148-149`, `:1425-1431` (диалоги, награды) | view (диалог у клиента) | награда в инвентарь | `se_item:clsid()`, `se_item.condition = rand` | `:148` — ошибка Lua; `:1425` — без условия и новости |
| 13 | `ui_mutant_loot.script:133,152` (+ `se_obj.id` в таблицу добычи ниже) | view (UI) | добыча **на трупе мутанта** (чужой держатель) | `loot_table[sec][c] = se_obj.id`, UI показывает и переносит по id | хост отказывает (`NotOwner`), список пуст |
| 14 | `ui_workshop.script:2063-2066`, `item_cooking.script:572`, `dialogs.script:1994`, `item_money.script:116-134`, `item_device.script:201,437`, `utils_item.script:830-931` | view/owner | предмет актору | результат не используется (основная масса) | **работает** через `ReqSpawn`, но `cond/uses/ammo`-опции `ItemProcessor` теряются (п. 2) |
| 15 | `alife_storage_manager.script:104-106` (миграция старых сейвов) | view (`load_state`) | PDA владельцу-NPC | `se_save_var(se_pda_new.id, …)` | одноразово при загрузке |
| 16 | GAMMA `119- HD Glowsticks…/zz_glowstick_mcm.script:126,141,308,416,425` (номера по двум копиям: HD Glowsticks и `396- Glowsticks Reanimated`) | owner | лампа в мире + `alife_create_item(…).id` | `utils_stpk.get_lamp_data(obj)`, `obj.angle`, `CreateTimeEvent(…, newid)` | палка не бросается, `.id` на `nil`. Сегодня закрыт патчем `coop_mods_items.script:80-115` (хост творит «как игрок», ~100 строк с `debug.getupvalue`) |
| 17 | GAMMA `452- Interaction Dot Marks/ui_hud_dotmarks.script:3663,4735,4964,5007,5217` | view | предмет, тайник `inv_backpack`, бомба в мире, магазин | `alife_create_item(…).id` сразу; `bomb_obj`; `se_mag` | ошибка индекса / потеря |
| 18 | GAMMA `52- Perk-Based Artefacts/perk_based_artefacts.script:1137,1403-1404,2605,3648` | owner/host | мясо, `ied_new_blow`, деньги у NPC | `CreateTimeEvent(explode_obj.id, explode_obj.id, …)` | у клиента закрыто захватом (`coop_mods_perks.script:120-153`), но только для смерти |
| 19 | GAMMA `207- Anomaly Magazines…/mags_patches.script:356-359,394-395,480` | owner | магазины в инвентарь | `set_mag_data(se_mag.id, old_data)` | `if se_mag` → магазин пропадает |
| 20 | GAMMA `225- Placeable Campfires/campfire_placeable.script:156-171`, `placeable_furniture.script:135`, `ui_furniture_workshop.script:14-15`, `ui_stove_furniture.script:31`, `410- 3DSS…/scripted_canted_irons.script:1198-1200`, `z_3dss_thermal_battery.script:508-511` | owner/view | костёр, мебель, склад мебели (мир); `created` дальше по цепочке | `se_obj.id` в таймер, `se_anoms[id]`, `get_anom_zone_data(se_obj)`; цепочки обёрток ждут `created` | палатка-класс: ошибки; мебель закрыта `coop_mods_hf` |

### 3.4 Вывод по классам мест
1. **Предмет в свой инвентарь** (строки 2, 3, 8, 11, 12, 14, 19): нужны id и объект сразу; `ReqSpawn` для них уже работает, держатель — прокси клиента.
2. **Клон оружия** (1): id нужен обязательно (ключи `m_data`, части).
3. **`create(…, false)` + `register`** (6): уже работает; id нужен, если мод кладёт в `m_data` до `register` (в GAMMA такие есть — см. 1, 19).
4. **Мировая вещь** (4, 5, 7, 9, 10, 16, 17, 20): нужны id, объект и хостовая политика мировых вещей.
5. **Чужой держатель** (13, 15): аренда не помогает, нужно решение хоста; для лута — запрос хосту целиком.
6. **Существа/мир хоста** (в 156 host-вызовах GAMMA и в `xr_effects` 3012-5269, `sim_*`, `smart_terrain`): остаётся `nil` и домен `host`.

---

## 4. Откат

### 4.1 Что есть
- Хост: любой отказ → `ReqResult(Err, reason, subject=parent)` (`coop_requests.cpp:863`; причины `coop_requests.h:58-74`). Клиент:
  `client_on_result` (:530-556) пишет в лог и считает. Откатывать нечего — объекта у клиента **не было**.
- При аренде у клиента будет **спекулятивный** объект; отказ должен его убрать.

### 4.2 Что уже делает клиент с объектом, удаляемым хостом
`client_on_destroy` (`coop_entities.cpp:628-660`): онлайн → штатная цепочка `GE_DESTROY` → игровой объект уничтожается;
офлайн → `alife_rw().release(e, true)` → `entity_Destroy` → `F_entity_Destroy`, т.к. `m_bALifeControl = false`
(`alife_simulator_base.cpp:305-308`; `xrServer.cpp:875-882`). CSE **освобождается сразу**.

Что видит мод:
- `level.object_by_id(id)` и `alife():object(id)` → `nil` (код стока на это рассчитан);
- `server_entity_on_unregister` вызывается (`unregister_object` → `on_unregister`, `alife_simulator_base2.cpp:64`):
  `alife_storage_manager.script:46-55` чистит `m_data.se_object[id]` и `game_object[id]` — **подписчики сами убирают своё
  состояние** (обработчик вешает `axr_main`, :69);
- `se_obj`, хранившийся как userdata в переменной скрипта, — **висячий указатель**: luabind не владеет CSE. Чтение после
  освобождения — AV. В стоке это правило скриптов («после release не трогать»); в коопе хост может удалить объект когда угодно.
  Моды обычно хранят id, но замыкания таймеров (`CreateTimeEvent`) и обёртки (3DSS, Magazines) держат сам объект в пределах одного кадра.

### 4.3 Что нужно для спекулятивных объектов (12b)
1. **Карантин вместо освобождения** для отката: объект снимается с реестров через тот же `release` (подписчики `on_unregister`
   отработают и почистят `m_data`), но `xrServer::entity_Destroy` не зовёт `F_entity_Destroy` для CSE из набора карантина;
   освобождение — через 120 с или при `reset()`. Образец: `g_lua_temps` (`coop_requests.cpp:308,1370-1372`).
2. **`RateLimited` — не откат, а повтор** через 100–250 мс (номер остался арендованным у клиента и не потрачен у хоста). Откат —
   на `NotAllowed/BadSection/NotOwner/TooFar/Missing/Offline/Malformed`.
3. **Воскрешение эхом:** если скрипт сразу сделал `alife_release` арендованного объекта (создал и выбросил), `EntitySpawn` от хоста
   придёт после — клиент воссоздал бы его. Нужен набор «выпущенные арендованные», эхо для них игнорируется до `EntityDestroy`.
4. **Видимость:** строка в `coop_status` (`lease: выдано / потрачено / откат по причинам`), HUD-сообщение при откате предмета игрока.
5. **Порядок на проводе:** запросы клиента идут в одной надёжной упорядоченной линии (`coop_trade.cpp:664-665`), так что
   `ReqItemEvent/ReqDrop/ReqDestroy` по арендованному номеру приходят после `ReqSpawn` и находят объект.

### 4.4 Что при этом остаётся у мода при откате
- `m_data`-записи по откатанному id чистятся подписчиками `on_unregister` (если мод его слушает — стоковые слушают);
  остальное — «пустой» ключ, как после обычного `alife_release`.
- Метки на карте (`map_add_object_spot_ser(id, …)`) остаются без объекта — движок их скрывает (объект не найден); чистить
  не нужно, но стоит проверить в игре.

---

## 5. Рекомендация

### 5.1 Почему (а), а не (б)
- Результат используется в 31 % клиентских мест, и там падает/теряет/дублирует (см. §3.3: 4, 7–11, 12, 16, 17, 19). Ошибка Lua в
  `owner/view` режется `pcall` (R-11.4), поэтому игрок видит «ничего не произошло» или дубль.
- (б) = точечные патчи на `coop.sync.request`: у нас уже есть образцы (`coop_mods_items.script:80-115` глоустики ~100 строк,
  `coop_mods_perks.script:120-153` захват при смерти, `coop_mods_hf`), каждый зависит от внутренностей мода
  (`debug.getupvalue`). 30+ скриптов GAMMA и каждая новая сборка — не масштабируется.
- (б) не лечит стоковую `itms_manager` (опции `cond/uses`) и `alife_clone_weapon` (id для `m_data`).
- Блокирующий вызов (клиент ждёт `ReqResult` внутри Lua) отвергнут: ожидание сети внутри скрипта, обработка входящих пакетов
  посреди колбэка, заморозка кадра на RTT × число вызовов (разбор оружия = 5–10 вызовов).

### 5.2 Что оставляем на (б)
- Существа, отряды, аномалии, вертолёты, `level_changer`, рестрикторы, `smart_terrain`: `nil` + домен `host`.
- Лут на трупе мутанта (`ui_mutant_loot`) и товар торговцев (`axr_trade_manager:314,326`): общее состояние — запросом хосту
  (`coop.sync.request`), хост создаёт один раз.
- Мировые вещи, не прошедшие политику (§5.3 «Политика»): `nil` + строка в логе, как сейчас.

### 5.3 Интерфейс для задачи 12b
Файлы:
- `engine/src/xrCoop/coop_idlease.h` — чистый (без движка), как `coop_spawn.h`/`coop_ledger.h`;
- `engine/src/xrGame/id_generator.h`, `xrServer.h` — `is_free(id)`, `available()`;
- `engine/src/xrGame/coop/coop_requests.cpp/.h`, `coop_entities.cpp/.h` — пути ниже;
- `tests/test_idlease.cpp` (+ строки в `test_requests.cpp`, `test_spawn.cpp`).

**Чистый заголовок `coop_idlease.h`:**
- `struct HostLeases { grant(peer, n, pick) ; owns(peer,id) ; spend(peer,id) ; give_back(peer,id) ; drop(peer) ; count(peer) ; }`,
  где `pick()` — вставляемая функция «взять свободный номер» (в движке — `PerformIDgen(0xffff)`), в тестах — счётчик;
- `struct ClientPool { add(ids) ; take() -> id|0xffff ; need() ; ids_in_flight }`;
- правила: `kLeaseSize = 48`, `kLeaseRefill = 16`, номер не 0 и не `0xffff`, повторные номера отвергаются, сброс по эпохе.

**Провод** (свободны `0x0178-0x017F` по `coop_protocol.h`; номер версии выдаёт ведущая, у T1 уже есть «N»):
- `IdLease = 0x0178` host → client: `u32 epoch, varu n, u16 ids[n]`;
- `IdLeaseAck = 0x0179` client → host: `u32 epoch, varu n, u16 rejected[n]` (номера, занятые у клиента);
- `ReqSpawn` маркер `0xC7` = `0xC6` + `u16 id` после `parent` (`coop_spawn.h` `Layout::StateId`); `0xC6` остаётся как «без
  аренды» (id не арендован → путь «`nil`»);
- ответ — прежний `ReqResult`, `subject = id`.

**Хост** (`coop_requests.cpp`):
- `host_on_spawn` (:791): если есть `id` — `leases.owns(from,id)` **до** любых изменений генератора; затем
  `FreeID(id,0)` и `e->ID = id` в пакете (`host_spawn` :752 сегодня пишет `kNoId`), после `Process_spawn` — `leases.spend`
  и подпитка;
- политика `SpawnPolicy`: `ItemOwn` (сегодня), `ItemHolderReach` (контейнер/тайник в радиусе, 2-я очередь),
  `Prop` (физ. объект, лампа, ящик, взрывной предмет; радиус от прокси ≤ 10 м, потолок 64 живых на игрока, белый список
  `class` в ltx), `Never` (существа, отряды, зоны, вертолёты, `level_changer`, рестрикторы); вершину ИИ-сетки хост считает
  сам по позиции, клиентскому значению не верит;
- ведро `CatSpawn` (`kRate 20/с, kBurst 40`, :623-624) — тот же лимит, `RateLimited` → повтор у клиента;
- освобождение при уходе пира и смене эпохи: `FreeID(id, now)`.

**Клиент:**
- `lua_create/lua_clone/lua_register_spawn` (:1628-1688): если `is_live_client()`, в пуле есть номер и политика
  `ItemOwn/Prop` — `speculative_create`; иначе прежний путь (`nil`/временный CSE);
- `speculative_create` (новая, `coop_entities.cpp`): тот же набор шагов, что `client_on_spawn` (:596-625) и `spawn_item`
  (`alife_simulator_base.cpp:99-146`) — `F_entity_Create`, поля §2, `name_replace` с суффиксом id, `PerformIDgen(арендованный)`,
  `register_object(e, true)`, `bring_child_online(e)` при онлайн-держателе (:538-555), всё под `ClientApply`
  (иначе `intercept_local_spawn` :887 и `filter_spawn` `coop_events.cpp:155` отправят его обратно запросом);
  в набор «спекулятивные» + `ReqSpawn` с `id` в `g_outbox`;
- `client_on_result` (:530): `Ok` → снять признак; не `Ok` → `rollback(id)` по §4.3 (кроме `RateLimited`);
- `client_on_spawn` (:571): для спекулятивного id — применить `apply_update(e, update)` из эха (авторитетное состояние хоста:
  позиция, апгрейды после очистки) и снять признак вместо `return`;
- `lua_release` (:1690): для спекулятивного — `client_destroy` как для своих + метка «выпущен» (§4.3 п. 3).

**Движок общий:**
- `CID_Generator::is_free(id)` и `available()`; проверка `is_free` вместо `ID_to_entity` в `coop_events.cpp:719` и
  `coop_entities.cpp:573` (закрывает R2 minor);
- `xrServer::entity_Destroy`: пропуск `F_entity_Destroy` для CSE из карантина (§4.3).

**Тесты:**
- `test_idlease.cpp` — выдача/трата/возврат/сброс по эпохе/чужой номер/повтор;
- `test_spawn.cpp` — раскладка `0xC7`, обратная совместимость `0xC6`;
- `test_requests.cpp` — хост: арендованный номер принят один раз, чужой и потраченный отвергнуты, `Never`-класс отказ;
- Lua-заглушки (`tests/lua/`): `alife_create_item(…, db.actor, {cond=0.5})` у клиента возвращает объект с `id`, `Cond[id]`
  выставлен; `alife_clone_weapon` — не 65535; откат вызывает `server_entity_on_unregister`.

**Правки плана:**
- Task 10, тест `route_shim_unknown_script_world_call_is_gated` (план :800-803) требует «ровно один запрос и локального объекта нет».
  При (а) для класса «предмет в свой инвентарь» объект будет → ожидание теста поправить (оставить «нет» только для класса `Never`).
- Task 12, строка таблицы `alife:create, release, register, clone_weapon → путь ReqSpawn / client_destroy (есть)`: заменить
  на «путь аренды, затем ReqSpawn».
- Task 15 (зеркало `m_data`): ключи `se_object[id]` (и подобные per-object) — собственность пира, если номер из его аренды, иначе
  `root_of(parent)`. Без этого клиентские записи по новому id не доедут до сейва хоста (сегодня то же верно для всех owner-модов).

### 5.4 Риски (по убыванию)
1. **Политика мировых вещей — новая поверхность атаки** (клиент создаёт физ. объекты/ящики/лампы). Лимиты, белый список по
   `class`, радиус, потолок на игрока, тесты по образцу R3 В6. Без неё 12b сводится к инвентарю и клонам (это уже 50–70 % вызовов).
2. **Видимый откат:** предмет мигнул и исчез. Смягчение: повтор при `RateLimited`, строка в HUD; отказы по правилам — редкость.
3. **Владение `m_data` по новым id** (зависимость от задачи 15). Не решена — данные Magazines/частей оружия будут жить в
   сейве клиента, а не хоста.
4. **Висячие `se_obj`** при удалении хостом (не только откат). Карантин покрывает откат; общий случай — отдельное решение
   (то же правило «в карантин на 2 мин» для `client_on_destroy`), в 12b не входит.
5. **Эхо/воскрешение** при «создал и сразу выбросил» (§4.3 п. 3).
6. **Исчерпание номеров на огромных сейвах:** аренда 336 из 65 534; хост не выдаёт при `available() < 4`.
7. **Фаза `LoadingWorld`:** аренды ещё нет, вызовы остаются `nil`/гасятся (`alife_storage_manager.script:104` одноразово).
8. **Время:** правки CSE-поля вне `ItemData` (лампа, зона, `angle`, `custom_data`) хост не знает; мировая ветка 12b должна
   либо расширить блоб (`angle`, визуал/тип лампы), либо оставить такие объекты на (б).

### 5.5 Объём (оценка по коду, не по замеру)
- чистый заголовок + тесты: полдня; провод, хост и клиент без мировых вещей: 1,5–2 дня; откат/карантин/эхо: 1 день;
  политика мировых вещей: 1 день; живая проверка на GAMMA (палатка, рюкзак, мина, смена прицела, разбор оружия, магазины): полдня.
- сначала `is_free` + R2 minor (отдельный маленький коммит: пользы нет только от него, но он нужен всем остальным).

---

## 6. Что проверено, что нет

Проверено чтением кода и rg по включённым модам GAMMA (счётчики — регулярными выражениями, разбивка «клиент/хост» — по именам
скриптов и их `RegisterScriptCallback`, не по реальному исполнению). Не проверено:
- ничего не собиралось и не запускалось; поведение откат/эхо/карантин — проект, не измерение;
- «глобальное» поведение метки карты на несуществующий объект — по памяти кода движка, проверить в игре;
- точное распределение клиент/хост для скриптов GAMMA, которых нет в `coop_domains*.ltx`: решит таблица маршрутов (задача 9);
- стоимость `is_free` и отсутствие скрытых мест, где генератор трогается мимо `PerformIDgen/FreeID` (поиск по `m_tID_Generator`
  нашёл только `xrServer.h/.cpp`).
