# Сюжетные карты «только вместе» — исследование (2026-10-24 01:00)

Запрос владельца (2026-10-24 00:40): «заходить одному в разные локации, но, возможно, кроме некоторых сюжетных, в
которые лучше зайти вместе, если таковые имеются — поищи». Уточнение (01:20): «если будет мультилока, то ожидание уже не
надо» — обычный выход с карты становится переходом одного игрока, точка ожидания остаётся только для карт из этого
списка.

Модель Ф3a (решения владельца 02:00–02:10). Все карты ведёт ПК хоста:
- карту хоста — процесс хоста, это слушающий сервер;
- остальные карты — фоновые безоконные серверы карт.

Ниже «процесс, который ведёт карту» — один из них, никогда не машина клиента.

Только чтение кода. Игра не запускалась, ничего не собиралось.

Источники:
- сток Anomaly 1.5.3 — `anomaly-ref/unpacked/scripts`, `configs` (дальше пути от `unpacked/`);
- GAMMA — `E:\AnomalyCoopGamma\gamedata` (дальше «GAMMA: …»);
- наш Lua — `gamedata/scripts/coop_*.script`.

Номера строк — по файлу с концами строк, как их видит редактор: CRLF и одиночный CR считаются одним переводом строки.

---

## 0. Итог

**Только вместе — 3 карты.** На них заход одного ломает игру остальным или необратимо меняет мир всех.

| Карта | Пока действует | Почему одному нельзя |
|---|---|---|
| `l13u_warlab` (Варлаб, конец основного сюжета) | сюжет включён и `-warlab_deactivate_generators_done` | одноразовый телепорт в сцену «Осознания»; в комнату волн попадают только телепортом из сцены; конец сюжета; титры — в процессе, который ведёт карту, игроки их не видят |
| `l12u_sarcofag` (Саркофаг, Исполнитель желаний) | сюжет включён и `-actor_made_wish` | одно желание на мир: «мир» удаляет все отряды на всех картах, «бессмертие» делает игрока зомби и уводит на Болота, «исчезновение Зоны» роняет процесс, который ведёт Саркофаг |
| `l10u_bunker` (X-10, Выжигатель мозгов) | сюжет включён и `-bar_deactivate_radar_done` | рубильник выключает пси-поля Радара и Севера для всех, выдаёт всем задание «Монолит»; в GAMMA засада из 30 «монолитовцев» стоит с первого захода |

**Лучше вместе — 8 карт.** Ничего не ломается, но одноразовые бои и сцены достаются только тому, кто пришёл первым.
Игроку показывается подсказка, перехода никто не ждёт.

| Карта | Когда | Что достаётся одному |
|---|---|---|
| `l08u_brainlab` (X-16) | до `yan_labx16_switcher_primary_off` | Чудо-машина выключается рубильником, сразу `+yantar_attack_start`: атака зомби на Янтаре, где может стоять напарник; сон-сцена |
| `l12u_control_monolith` | сюжет включён | 27 «монолитовцев» при первой загрузке карты, три пиро-полтергейста на входе — один раз |
| `labx8` (X-8) | сюжет включён | контролёр после пятого документа — один раз; выход лифтом через сцену |
| `l04u_labx18` (X-18) | сюжет включён | дверь закрывается за первым, сон-сцена, кольцо полтергейстов и отряд военных — один раз |
| `jupiter_underground` | сюжет включён | прорыв ISG и «Перекрёстный огонь» (HB), засада Монолита (LL), волны ISG «Скрытой угрозы» (GAMMA) |
| `pripyat` (Припять ЗП) | только финал «Операции Послесвечение»: `+operation_afterglow_jupiter_final -lttz_oa_loose_ends_done` | финальные выборы с Дегтярёвым и Стрелком, после них титры |
| `l13_generators` | только финал «Смертного греха»: `+lttz_ms_heart_zone_started -mortal_sin_endgame` | «Решающий удар» и бой с Саваофом |
| `l11_hospital` | только «Штурм госпиталя» (MS) | гарнизон «Греха» и Саваоф |

**Можно одному — всё остальное**, в том числе `l03u_agr_underground`, `l12_stancia`, `l12_stancia_2`, `l10_radar`,
`l10_limansk`, `l10_red_forest`, Затон и Юпитер на поверхности. На них одноразовое — обычные бои и местные сцены. Их
уже ведёт механизм «аудитории» `coop_npc_logic`: кто вошёл и кто рядом — тот и в сцене.

**Главная находка не про карты, а про задания.** Хост-логика сюжета и заданий во многих местах спрашивает
`level.name()` — «где актёр». При раздельных картах хост отвечает про себя, а не про игрока, который делает задание.
- Задание GAMMA «Оборона насосной» проваливается, если хост не на Болотах (`tasks_pump_station_defense.script:459`).
- «Скрытая угроза» не двигает этапы, пока хост не на нужной карте (`task_functor_hidden_threat.script:262, 307, 389`).
- ISG-отряды спавнятся «за спиной», когда хост не на `jupiter_underground` — а клиент там стоит
  (`dialogs_lostzone.script:843-882`).

Это не повод запирать карты: нужна прослойка «уровень игрока» в Ф3a (план, задача T15). GAMMA: `level.name()` —
206 вызовов в 71 файле. Большая часть — вид (HUD, шейдеры), их не трогаем.

Правило в плане (`docs/plans/2026-10-24-f3a-split-levels.md`):
- список — данными в `configs/coop_levels_together.ltx`, условие — стоковый condlist, хост считает его сам;
- две настройки игры: «раздельные карты» и «сюжетные — вместе», по умолчанию обе включены;
- точка ожидания (протокол 10) включается только на вход в карту «только вместе» или при выключенных раздельных
  картах.

---

## 1. Как устроен сюжет Anomaly и GAMMA

| Линия | Где | Карты, на которых она что-то делает сама |
|---|---|---|
| Основной сюжет (поиск документов → Варлаб) | `configs/misc/task/tm_marsh.ltx` `main_1..7` (поиск документов в агропромовском подземелье, X-18, X-16, X-10, X-8, подземке Юпитера, Управлении Монолитом), `tm_sarcofag.ltx` (`sar_monolith`, `sar_monolith_destroy`), `tm_warlab.ltx` (`sar_warlab`, `warlab_kill_crazy_entity`), `tm_radar.ltx` `turn_off_brain_scorcher`, `tm_yantar.ltx` `turn_off_brain_machine` | все лаборатории, Саркофаг, Управление, Генераторы, Варлаб |
| `drx_sl_*` | `tm_*.ltx`, по два–четыре задания у каждого торговца и механика | ни одной: обычные «принеси/убей» по шаблонам, без сцен на картах |
| «Живая легенда» (LL) | `tm_lostzone_ll.ltx` | подземка Юпитера (засада), Припять (Эйдолон), Саркофаг (осколок Монолита) |
| «Смертный грех» (MS) | `tm_lostzone_ms.ltx` | Рыжий лес, Лиманск, Госпиталь, ЧАЭС-2, Генераторы, Управление, Саркофаг (выбор желания) |
| «Операция Послесвечение» (OA) | `tm_lostzone_oa.ltx`, `configs/scripts/pripyat/pri_a16_sr_light.ltx` | Припять: финал и титры |
| ISG (HB) | `tm_lostzone_hb.ltx`, `scripts/dialogs_lostzone.script` | Тёмная Лощина, подземка Юпитера |
| GAMMA «Скрытая угроза» (HT, Longreed) | GAMMA: `configs/misc/task/mod_task_manager_storyline_hidden_threat.ltx`, `scripts/task_functor_hidden_threat.script`, `hidden_threat.script` | подземка Юпитера, ЧАЭС-2, Припять, Агропром |
| GAMMA: «Охотник за артефактами» `ah_*`, «Живой огонь», «Тайны Зоны» | GAMMA: `mod_task_manager_storylines_dltx.ltx`, `tasks_the_living_fire.script` | задания «принеси»; сцен на картах нет |

Сюжетный режим — инфопорция `story_mode_disabled`, её нет. Многие сцены проверяют это первой строкой, например
`configs/scripts/monolith_control/mon_enter_monolith_control.ltx:8`. Поэтому все условия «только вместе» ниже
выключаются вместе с сюжетом.

---

## 2. Пять классов поломок при заходе одного

**A. Одноразовые бои при первой загрузке карты.** Рестриктор с `on_info = sr_idle@nil %=spawn_object(...)%` без
условия срабатывает на первом обновлении своей логики, то есть когда карту впервые загружает тот, кто её ведёт.
- В Ф3 это хост.
- В Ф3a — процесс на ПК хоста, который поднимает карту при первом заходе любого игрока. Всю засаду встречает первый
  вошедший, один.

Примеры:
- `configs/scripts/sarcofag/sar_enter_zone.ltx:5` — 15 бойцов;
- `configs/scripts/monolith_control/mon_spawner.ltx:5` — 27;
- `configs/scripts/labx16/x16_spawner.ltx:5`;
- GAMMA: `configs/scripts/bunker/bun_spawn_monolith_ambush.ltx:5` — 30. В стоке они появлялись только после рубильника:
  `{+bar_deactivate_radar_done}`, сток `:5`.

**B. Сцены с телепортом и `disable_ui`.** Механизм аудитории (`coop_npc_logic.script:201-266`) отдаёт эффект на актёра
тем, кто вошёл, и тем, кто в `scene_radius` от них. Кто был на другой карте, тот сцену пропустил навсегда:
рестриктор уже в `sr_idle@nil`. Хуже, если пропущенная сцена — единственный вход в часть карты. Так устроен Варлаб
(§3.1).

**C. Мировые переключатели.** Рубильники и желание — инфопорции, которые меняют мир всех:
- пси-поля, атаки, задания;
- удаление отрядов на всех картах.

Сделанное одним необратимо и для остальных.

**D. Концовки.** Титры и `main_menu on` идут в процессе, который ведёт карту. На фоновом сервере карты их не видит
никто:
- `xr_effects.game_credits` — сток `scripts/xr_effects.script:2861`, `game_over` — `:2866-2875`;
- `mov_join_osoznanie` → `game_credits` — `configs/ui/game_tutorials.xml:494-502`.

В коопе это пока не обработано вообще: `game_credits` нет ни в одном `coop_*.script`. Мир от этого не встаёт —
`coop_manager.cpp:215-217` не даёт паузу в сессии. Но остальные игроки концовку не видят.

**E. Хост-логика по `level.name()`.** Задания и `actor_on_first_update` хоста решают по уровню хоста (§4). Это не карта
«вместе», а исправляемая прослойка.

Плюс одно свойство, которое не поломка, но его надо знать. **Сюжетные напарники** (Стрелок, Шрам, Шустрый, Дегтярёв,
`create_squad` + `axr_companions`) следуют за ведущим через переходы
(`bind_stalker.script:322` `SendScriptCallback("on_level_changing")` → `axr_companions`). Если ведущий ушёл один, они уходят с ним.

---

## 3. По картам

Для каждой карты: доказательства, что ломается у одного, вердикт и условие. Условие — condlist, который хост
вычисляет у себя (§5).

### 3.1 `l13u_warlab` — только вместе

**Доказательства:**
- `configs/scripts/warlab/mon_monolith_proektor_restr.ltx:6` — `{+warlab_door_opened}`: `=teleport_actor(oso_actor_walk)
  +warlab_actor_teleported =disable_ui`. Телепорт в комнату «Осознания» один раз. Это не прибытие, поэтому аудитория —
  все игроки на карте («сюжетный триггер», `coop_npc_logic.script:236-262`).
- `:22` — через 2 с без диалога `=destroy_object(story:osoznanie)`: собеседник исчезает.
- `scripts/dialogs_warlab.script:2-13` — отказ: `+warlab_actor_teleported_to_sar2` и `set_actor_position` в комнату
  Монолита. Переносит только того, кто говорил.
- `:18-23` — согласие: `start_tutorial("mov_join_osoznanie")` → титры → главное меню (§2 D).
- `configs/scripts/sarcofag/sar2_script_zone.ltx:5-12` и `sar2_spawner.ltx:5…` — 10 волн по 6 одноразовых NPC, итог
  `+sar2_monolith_end`. Эти файлы лежат в папке `sarcofag`, но патрули — Варлаба: `set_actor_position` не меняет
  уровень.
- `mon_monolith_proektor_restr.ltx:24-25` — `wait_2nd_actor` ждёт `sar2_monolith_end`.
- `warlab_monolith_gen_main.ltx:24` — генераторы: `+sar_monolith_off`.
- `warlab_deactivate_generators.ltx:11, 17` — `run_tutorial(final_peace)` и телепорт обратно.

**Что ломается у одного:**
- второй игрок, пришедший позже, не попадает ни в комнату «Осознания», ни в комнату волн: вход туда только телепортом
  из сцены, а сцена уже прошла;
- конец основного сюжета (`warlab_deactivate_generators_done`) случается без него;
- при «согласии» титры у того, кто ведёт карту.

Проход в комнату волн по геометрии не проверен — нужна проверка в игре.

**Вердикт: только вместе.**

Условие: `{+story_mode_disabled} free, {+warlab_deactivate_generators_done} free, together`.

**Дыра коопа, не Ф3a.** Даже вместе отказ «Осознанию» переносит только говорившего. Остальные остаются в комнате
«Осознания», и через 2 с собеседник исчезает (`:22`). Нужен отдельный патч: отказ переносит всю аудиторию сцены. Записать
в находки.

### 3.2 `l12u_sarcofag` — только вместе

**Доказательства:**
- `configs/scripts/sarcofag/sar_monolith.ltx:5-6` — Исполнитель: `on_use = %=make_a_wish%`. После `+actor_made_wish`
  он гаснет навсегда.
- `scripts/xr_effects.script:5437` (GAMMA: `:5508`) — `make_a_wish`, выбор из списка:
  - «исчезновение Зоны» — `error(str,2)` (`:5459`): Lua-ошибка, вылет процесса, где исполнилось желание. В Ф3a это
    процесс хоста или фоновый сервер карты Саркофага;
  - «мир» — перебор всех id и `squad:remove_squad()` (`:5479-5489`). Отряды удаляются на всех картах, в том числе
    онлайн у напарника на его карте;
  - «богатство» — спавн всех предметов к актёру;
  - «бессмертие» — `set_actor_true_community("zombied")` (`:5546`) и `ChangeLevel` на Болота (`:5565`): игрок
    становится зомби и уходит один.
- `sar_enter_zone.ltx:5` — 15 «монолитовцев» при первой загрузке.
- `sar_in_rest.ltx:15-18` — засада телепортом, 8 бойцов, один раз.
- Задания:
  - `tm_sarcofag.ltx` `sar_monolith` (`condlist {+actor_made_wish} complete`);
  - LL `lttz_ll_crucible` — осколок Монолита у стража;
  - MS `lttz_ms_choice` — `{+deny_the_wish} complete, {+actor_made_wish} complete`, развилка концовки.

**Что ломается у одного.** Одно желание на весь мир, его загадывает тот, кто дошёл первым:
- «мир» стирает отряды и у напарника;
- «Зона исчезла» роняет процесс, который ведёт карту. Если это процесс хоста — падает вся сессия; если фоновый сервер
  карты — журнал передач и перезапуск, но игроки на карте вылетают на загрузку;
- развилки LL и MS закрываются без группы.

**Вердикт: только вместе.**

Условие: `{+story_mode_disabled} free, {+actor_made_wish} free, together`.

Отдельно, вне Ф3a: «Зона исчезла» в коопе нужно перехватить — не ронять процесс, а показать концовку всем.

### 3.3 `l10u_bunker` (X-10) — только вместе

**Доказательства:**
- `configs/scripts/bunker/bunker_primary_switcher.ltx:8` — `on_press = … +bar_deactivate_radar_done`.
- `bun_deactivate_radar.ltx:9-24` — грохот, пси-провал, `+bun_actor_fall`, сон (`end_radar_dream` →
  `+bun_patrol_start`), зов Монолита, `=give_task(sar_monolith)`.
- Выключение полей у всех:
  - `stancia_1/aes1_psy_zone_1.ltx:8` — `{+bar_deactivate_radar_done} nil`;
  - `bun_psi_radiotion_75.ltx`, Припять (`pripyat/pri_psy_zone_1.ltx`), Юпитер (`jupiter/smart/jup_a6.ltx`).
- Задания по этому же рубильнику: `tm_lostzone_ll.ltx` `lttz_ll_turn_off_brain_scorcher` (`on_complete
  =stalker_ceasefire()` и `create_squad(stalker_rogue_squad…)`), `tm_radar.ltx` `turn_off_brain_scorcher`.
- GAMMA: `bun_spawn_monolith_ambush.ltx:5` — 30 бойцов без условия, при первой загрузке.
- GAMMA: `x10_timer_restrictor.ltx:11-12` — 650 с до смерти без пси-шлема, у каждого свой таймер.

**Что ломается у одного:**
- это главная развилка сюжета: «Север открыт» для всех, сон и задание «Монолит» — только у тех, кто был;
- в GAMMA первый вошедший встречает 30 «монолитовцев» один.

Строго говоря, это «портит», а не «ломает». Но владелец просил сюжетное «лучше вместе», а это центральная точка
сюжета. Если владелец решит иначе — одна строка в ltx, `suggest`.

**Вердикт: только вместе** (решение по вкусу, §6).

Условие: `{+story_mode_disabled} free, {+bar_deactivate_radar_done} free, together`.

### 3.4 `l08u_brainlab` (X-16) — лучше вместе

**Доказательства:**
- `configs/scripts/labx16/yan_labx16_switcher_primary.ltx:17` — `+yan_labx16_switcher_primary_off +yantar_attack_start`;
- `yantar/yantar_psi_radiotion_*.ltx` — поле Янтаря снимается;
- `x16_spawner.ltx:5` — волна при первой загрузке;
- `yan_zasada_restrictor*.ltx`, `yan_controller_respawn_01.ltx` — засады на входе, по одной;
- `x16_timer_restrictor.ltx:5` — смерть без шлема. У каждого своя: `coop_npc_logic.script` `KILL_GATES`.

**Что у одного.** Атака зомби на Янтаре начинается там, где стоит напарник. Сон-сцена Янтаря проходит без него.
Ничего не запирается.

**Вердикт: лучше вместе**, условие `{+story_mode_disabled} free, {+yan_labx16_switcher_primary_off} free, suggest`.

### 3.5 `l12u_control_monolith` — лучше вместе

**Доказательства:**
- `configs/scripts/monolith_control/mon_spawner.ltx:5` — 27 бойцов при первой загрузке;
- `mon_enter_monolith_control.ltx:8` — на входе `+sar_monolith_generator_find` и три пиро-полтергейста, один раз;
- задание `main_7_search_mon_con` (`tm_marsh.ltx`), финал MS (`greh_castigator_5/6`, `greh_sabaoth`, `tm_lostzone_ms.ltx`
  `lttz_ms_endgame`).

**Вердикт: лучше вместе**, условие `{+story_mode_disabled} free, suggest`.

### 3.6 `labx8` (X-8) — лучше вместе

**Доказательства:**
- `configs/scripts/labx8/lx8_sr_counter.ltx:26` — после пятого документа `create_squad(lx8_controller_squad)` один раз;
- `lx8_lift_button.ltx:12-17` — выход лифтом: `scenario_autosave`, `disable_ui`, `teleport_actor`, затем зона перехода;
- `lx8_smart_terrain.ltx` — респаун только после `+actor_left_labx8`.

Задания: `main_5`, LL `lttz_ll_find_documents`, HB `lttz_hb_task_3_5`. GAMMA добавляет только `mod_lx8_door_lock_fix.ltx`
(подпись кнопки).

**Вердикт: лучше вместе**, условие `{+story_mode_disabled} free, suggest`.

### 3.7 `l04u_labx18` (X-18) — лучше вместе

**Доказательства:**
- `configs/scripts/labx18/x18_poltergeist_door_closer.ltx:8` — дверь закрывается за первым: `+dar_door3_closed`;
- `:12` — сон `=x18_gluk`, сцена только для аудитории;
- `:28` — отряд военных, один раз;
- `dar_poltergeist_ring_process.ltx:5` — кольцо полтергейстов после кодового замка.

GAMMA меняет только аномалии. Дверь открывается снова `{+dar_door3_free}`, вошедший позже не заперт снаружи.

**Вердикт: лучше вместе**, условие `{+story_mode_disabled} free, suggest`.

### 3.8 `jupiter_underground` — лучше вместе

**Доказательства:**
- HB `lttz_hb_task_2_2_breakthrough`, `lttz_hb_task_4_1_crossfire` — сопровождение Стрелка по зонам
  `pas_b400_sr_hall_*` (`tm_lostzone_hb.ltx`);
- LL `lttz_ll_path_pripyat` — засада `jupiter_underpass_monolith_ambush_squad`;
- GAMMA HT, задача 7 — волны ISG по `pas_b400_*`, этапы по `level.name()` хоста (`task_functor_hidden_threat.script:262,
  307`);
- GAMMA ISG — `dialogs_lostzone.script:877-882` спавнит охрану, «когда актёр не на этой карте».

Механизмы карты (кнопки, двери, лифт `pas_b400_*`) — сцены из ЗП, работают через аудиторию.

**Что у одного:**
- бои и сопровождение достаются первому;
- без прослойки T15 этапы HT стоят, а охрана ISG появляется на глазах у клиента.

**Вердикт: лучше вместе**, условие `{+story_mode_disabled} free, suggest`. T15 обязательна в любом случае.

### 3.9 `pripyat` (Припять ЗП) — лучше вместе только в финале OA

**Доказательства:**
- `configs/scripts/pripyat/pri_a16_sr_light.ltx:12` — `{=actor_on_level(pripyat) +operation_afterglow_jupiter_final}`:
  чистка смартов, спавн отряда Стрелка;
- `:28-50` — выбор стороны в финале: `lttz_set_squad_enemy_to_actor`, враги всей группе;
- `:54` — `{+lttz_oa_loose_ends_done} %=game_credits()%`.

GAMMA этот файл не переопределяет: `configs/scripts/pri_a16_sr_light.ltx` в корне — пустой, 0 байт.

Припять — большая открытая карта с торговцами. Запирать её всю нельзя.

**Вердикт: лучше вместе в окне финала**, условие
`{+story_mode_disabled} free, {+operation_afterglow_jupiter_final -lttz_oa_loose_ends_done} suggest, free`.

### 3.10 `l13_generators` и `l11_hospital` — лучше вместе в фазе MS

- Генераторы:
  - MS `lttz_ms_decisive_blow` — `gen_greh_ultimate_squad`, затем `create_special_task_squad(gen_greh_sabaoth_squad)`;
  - `lttz_ms_confrontation`;
  - основной сюжет только проходит через карту: `gen_space_restrictor_to_warlab`.

  Условие `{+story_mode_disabled} free, {+lttz_ms_heart_zone_started -mortal_sin_endgame} suggest, free`. Имя
  инфопорции старта задания — по стоковому правилу `<task>_started`; проверить в игре.
- Госпиталь: MS `lttz_ms_hospital_assault` — `kat_greh_garrison_squad`, `greh_sabaoth`.

  Условие `{+story_mode_disabled} free, {+lttz_ms_hospital_assault_started -lttz_ms_heart_zone_started} suggest, free`.

### 3.11 Можно одному

- `l03u_agr_underground`:
  - одноразовые отряды на входе (`agr_blood_growl.ltx:6`, `agr_u_controller_rest.ltx:6`);
  - сцена с телепортом «в тюрьму» выключена: `level_prefix_space_restrictor_0000.ltx` `active = sr_idle@nil`;
  - кейс Стрелка `main_story_1_quest_case`.

  GAMMA случайно гасит часть входов: `agroprom_underground_transition_randomizer.script`. Это решение хоста.
  Ф3a-риск: включённость `CLevelChanger` должна доходить до того, кто ведёт Агропром. План, T6.
- `l12_stancia`, `l12_stancia_2`: в стоковой логике одноразового нет, только пси-поле до Выжигателя. GAMMA HT, этап 6,
  на ЧАЭС-2 читает `level.name()` хоста (`task_functor_hidden_threat.script:389`) — это T15.
- `l10_radar`, `l10_red_forest`, `l10_limansk`: старт MS, пленный, разведчик — задания с особыми отрядами.
- Затон и Юпитер на поверхности: местные сцены ЗП через аудиторию. `jup_b16_teleport.ltx:14` — петля Оазиса, своя у
  каждого.
- Болота: интро-камера `mar_intro_camera.ltx` выключена (`active = nil`).

---

## 4. Хост-логика по `level.name()` и «где актёр» — для плана (T15)

С раздельными картами хост отвечает «где актёр» про себя. Места, которые ломают задания:

| Место | Что делает | Что сломается |
|---|---|---|
| сток и GAMMA `xr_conditions.script:1508-1511` `actor_on_level` | условия в condlist заданий и логики | у сервера мира — уровень хоста; в рестрикторах карты у процесса, который её ведёт, верно |
| GAMMA `task_status_functor.script:573` `actor_on_level` | функторы этапов | то же |
| GAMMA `tasks_pump_station_defense.script:459` | `if not level.name()=='k00_marsh' then return 'fail'` | задание проваливается, если клиент держит оборону, а хост на другой карте |
| GAMMA `task_functor_hidden_threat.script:262, 307, 389` | этапы HT по карте | этап не двигается, пока хост не на карте |
| GAMMA `dialogs_lostzone.script:843-882` (`actor_on_first_update`) | спавн и уборка ISG, «когда актёр не на карте» | спавн на глазах у клиента |
| GAMMA `tasks_measure`, `tasks_fate`, `tasks_bounty`, `tasks_assault`, `tasks_agent_rescue`, `tasks_delivery` | «северные карты» по уровню актёра | выбор целей по уровню хоста |
| `coop_quests_party.script:148-190` | `actor_has_item` считает группу | у игрока на чужой карте прокси у хоста офлайн, проверять по CSE-детям прокси |

Прослойка:
- `coop.levels.on(level)` — есть ли игрок на карте;
- `coop.levels.players_on(level)`;
- в контексте задания и `actor_on_first_update` хоста `actor_on_level(x)` = «кто-то из игроков на x»;
- явные патчи четырёх мест GAMMA, «не на карте» = «никого из игроков нет на карте».

---

## 5. Правило и данные

**Файл `gamedata/configs/coop_levels_together.ltx`** (cp1251, CRLF, DLTX-совместим, GAMMA может переопределить):

```ini
; Anomaly Coop F3a: which levels the group enters together (docs/research/2026-10-24-story-levels-together.md).
; <level> = <condlist> -> together | suggest | free. The host evaluates it (xr_logic.parse_condlist /
; pick_section_from_condlist on db.actor) every second and on every info portion change.
;   together - entering waits for every player (the waiting point, protocol 10); leaving is never held
;   suggest  - a notice "better together: <reason>", nobody waits
;   free     - nothing (a level that is not listed is free)
[coop_levels_together]
l13u_warlab           = {+story_mode_disabled} free, {+warlab_deactivate_generators_done} free, together
l12u_sarcofag         = {+story_mode_disabled} free, {+actor_made_wish} free, together
l10u_bunker           = {+story_mode_disabled} free, {+bar_deactivate_radar_done} free, together
l08u_brainlab         = {+story_mode_disabled} free, {+yan_labx16_switcher_primary_off} free, suggest
l12u_control_monolith = {+story_mode_disabled} free, suggest
labx8                 = {+story_mode_disabled} free, suggest
l04u_labx18           = {+story_mode_disabled} free, suggest
jupiter_underground   = {+story_mode_disabled} free, suggest
pripyat               = {+story_mode_disabled} free, {+operation_afterglow_jupiter_final -lttz_oa_loose_ends_done} suggest, free
l13_generators        = {+story_mode_disabled} free, {+lttz_ms_heart_zone_started -mortal_sin_endgame} suggest, free
l11_hospital          = {+story_mode_disabled} free, {+lttz_ms_hospital_assault_started -lttz_ms_heart_zone_started} suggest, free

; the reason a placard and the notice show: a string id (text\*\st_coop_levels.xml)
[coop_levels_together_reason]
l13u_warlab = st_coop_together_warlab
; ...
```

**Настройки игры** (каталог `coop_game_schema`, вкладка «Группа», меняются между сессиями):
- «Раздельные карты» — `c|coop_split_levels`, по умолчанию 1. При 0 всё как в Ф3: группа на карте хоста, точка
  ожидания на каждом выходе.
- «Сюжетные карты — вместе» — `c|coop_story_together`, по умолчанию 1. При 0 `together` считается как `suggest`.

**Правило входа в карту `together`:**
1. Ждут игроков, которые в мире, живы и **не на этой карте**. Кто уже внутри, вход не держит. Если вся группа уже там,
   вошедший позже проходит сразу.
2. Игрок на той же карте, что и выход, подходит к выходу: как в протоколе 10.
3. Игрок на другой карте соглашается на плашке удержанием клавиши — как «поездка с проводником» (`kGuideGoal`). Его
   переносят прямо в точку назначения: в v1 он и так грузит свежий мир. Идти пешком через Зону не нужно. Вариант
   «только пешком» — решение владельца (§6). Все согласившиеся, хост тоже, грузятся **одновременно** и входят вместе
   (план §1.5, барьер загрузки).
4. Выход с карты `together` не держится никогда. Возрождение на привале внутри неё тоже не держится.
5. Поездки скриптом (проводник, быстрое перемещение, `ChangeLevel` сюжета) в карту `together` идут через ту же доску.

**`suggest`:** при касании выхода — строка в ленте и на плашке на 5 с: «<карта>: лучше вместе — <причина>». Переход
сразу.

---

## 6. Что решить владельцу

1. **X-10 «только вместе» или «лучше вместе».** По коду это «портит», а не «ломает». Я поставила «вместе», потому что
   это центральная точка сюжета, а в GAMMA там 30 бойцов с порога.
2. **Удалённое согласие с переносом.** Предлагаю: игрок с другой карты не идёт пешком, а соглашается на плашке. Иначе
   вход в Варлаб требует, чтобы вся группа дошла до Генераторов.
3. **Настройка «сюжетные — вместе»** — да/нет. Вместо неё можно сделать «нет / только важные / все сюжетные»: третье
   значение превращает `suggest` в `together`.

---

## 7. Что не проверено и находки вне Ф3a

Не проверено (нужен живой прогон):
- в комнату волн Варлаба можно попасть только телепортом (§3.1) — проверить геометрию;
- имена инфопорций старта заданий MS (`lttz_ms_*_started`) — проверить в сейве;
- что `on_info` без условия в рестрикторе срабатывает при первой загрузке логики карты именно у того, кто её ведёт, в
  нашей схеме ведения карт.

Дыры коопа, найденные по дороге. Это не Ф3a, отдельные задачи:
1. Варлаб: отказ «Осознанию» переносит только говорившего (`dialogs_warlab.script:2-13`), остальные остаются в комнате.
   Нужен перенос всей аудитории.
2. Концовки (`game_credits`, `mov_join_osoznanie`, OA) в сессии идут только на одной машине. Нужен «общий финал»:
   титры всем, `main_menu on` никому.
3. Желание «Зона исчезла» — `error()` роняет процесс (`xr_effects.script:5459`). На хосте это роняет сессию уже сейчас,
   в Ф3. Перехватить.
