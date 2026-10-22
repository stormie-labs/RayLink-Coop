# Ф3, Task 1 — разведка: меню сейвов и сон/палатка в кооп-сессии (2026-10-22 21:35)

Разведка только чтением, по `docs/plans/2026-10-22-f3-checkpoints-death.md` Task 1 и `docs/CHECKPOINTS_DEATH.md` §2, §4, §7.
Ничего не собиралось, игра не запускалась. Читают задачи 7, 13, 14, 17.

Источники:
- движок — `engine/src` (ветка `coop`, HEAD `04eeffd`);
- сток Anomaly 1.5.3 — `anomaly-ref/unpacked`: скрипты по имени файла, строки стока;
- GAMMA — профиль `E:\GAMMA\profiles\G.A.M.M.A` (607 строк `+`, 579 модов без разделителей), победитель по приоритету смотрел в
  стенде `E:\AnomalyCoopGamma\gamedata\scripts` (жёсткие ссылки; в `modlist.txt` первая строка — наивысший приоритет,
  `docs/MO2_GAMMA.md` §1);
- наш Lua — `gamedata/scripts`, `gamedata/configs/coop_domains*.ltx`.

Где GAMMA меняет файл, номера строк даны отдельно (пометка «GAMMA»). Пути движка — от `engine/src/xrGame`.

---

## 0. Коротко (решения)

**§A Сейвы**
1. **Кнопки прячем в C++, в `CUIMMShniaga::CreateList` (`ui/UIMMShniaga.cpp:114`)**, по **имени** кнопки (`btn_save`,
   `btn_load`, `btn_lastsave`), если `coop::mgr().active()`. Имена одинаковы в стоке и в GAMMA. Другой файл движка для
   скрытия не нужен.
2. **Сбрасывать меню при старте и конце сессии не нужно**: список строится заново при каждом открытии меню
   (`MainMenu.cpp:213` → `ReloadUI` `:301-323` → новый Lua-экземпляр `main_menu` → `InitMMShniaga`). Исключение одно: сессия
   стартует при открытом игровом меню (`UICoopMenu:OnHostNow`, `coop_menu.script:500-507`). Тогда после закрытия окна
   «Кооператив» (`Close`, `:567-577`) показывается старый список. Закрыть: в `Close` (или сразу после успешного `api.host`),
   если `level.present()`, вызывать `main_menu off` вместо возврата в старое меню, плюс Lua-перехватчики (следующий пункт)
   как страховка.
3. **`on_before_save_input` / `on_before_load_input` закрывают только горячие клавиши и кнопку «Сохранить»**. Не закрыты вызовом
   обработчиков: кнопки «Загрузить» и «Последний сейв» (`ui_main_menu.script:198`, `:112`), `xr_effects.on_tutor_gameover_quickload`,
   сейв после сна (`ui_sleep_dialog.script:254`), сейв нового мира (`itms_manager.script:710`), таймер `game_autosave_new`,
   сейвы модов GAMMA. Сегодня их закрывает только C++ для **клиента** (`console_commands.cpp:1094`, `:1183`, `:1275`,
   `coop_events.cpp:435-441`). Хост открыт полностью.
4. **Править консольные `save` / `load` / `load_last_save` в C++ не предлагаю**: им пользуются автосейв, «Восстановить»
   и отладка хоста (решение плана 9). Вместо этого Lua-перехватчики в `coop_saves.script` (§A.5).
5. **Риск вне UI:** если Ф3 когда-либо пустит `CActor::Die` в сессии (hardcore, Task 10), стоковый `game_over` вызовет
   `load_last_save` у **хоста** без защиты (§A.3, путь L5).

**§B Сон и палатка**
6. Все входы сна сходятся в `UISleep:TestAndShow` / `OnButtonSleep`, `sleep_forced`, `sleep_bag` (`ui_sleep_dialog.script`).
   Обёртки Task 14 надо ставить в таблицы `ui_sleep_dialog` и `UISleep` присваиванием, не на местах вызова.
7. **Палатка и спальник у клиента сейчас не работают, а палатка ещё и роняет клиента.** `alife_create("ph_tent", …)` без
   родителя у клиента **не пересылается, а отбрасывается** (`coop_requests.cpp:1394-1396`): в плане и в vault стоит «пересылает
   запрос», это неверно для спавна без родителя. `itm_tent_func` индексирует `nil` (`item_tent.script:38`) внутри
   `level.add_call`-функтора, а Lua-ошибка в функторе движка в релизе — FATAL (`script_engine.cpp:276-296`,
   `xrCore.h:38-44`). Не проверено в игре.
8. **Lua-обёртка `item_tent` для клиента нужна. Маршрутизатора вызовов Ф2 не хватит**: Ф2 Task 12 оставляет для
   `alife:create` существующий путь ReqSpawn, а выдача id клиенту — только разведка Ф2 Task 8, без решения.
9. **Следствие для Task 7:** заявка «хост найдёт ничью палатку не старше 15 с» для клиента ничего не найдёт: палатки нет.
   Нужна просьба клиента к хосту «поставь палатку здесь» (форма — §B.3).
10. **Хуки Task 13 на `actor_on_item_use` недостаточны**: в GAMMA использование палатки и спальника идёт
    `use1_action_functor` → `item_tent.func_use_tent` / `func_use_bag` → **локальная** `actor_on_item_use` напрямую, мимо
    диспетчера колбэков.

---

# §A. Сейвы

## A.1 Как строится список кнопок (факты)

**Выбор списка** — `ui/UIMMShniaga.cpp:75-96`, в `InitShniaga` `:60-106`:

| Состояние | Строка | Список XML | Кнопки |
|---|---|---|---|
| нет уровня (`!g_pGameLevel \|\| !bReady`), нет последнего сейва | `:78` | `menu_main` | `btn_newgame`, `btn_load`, `btn_lastsave`, `btn_options`, `btn_originals`, `btn_quit` |
| нет уровня, есть валидный `g_last_saved_game` | `:80` | `menu_main_last_save` | то же без `btn_originals` |
| уровень есть, `GameID() == eGameIDSingle`, актор мёртв | `:90` | `menu_main_single_dead` | `btn_lastsave`, `btn_load`, `btn_options`, `btn_quit_to_mm`, `btn_quit` |
| уровень есть, `eGameIDSingle`, актор жив | `:92` | `menu_main_single` | `btn_ret`, `btn_lastsave`, `btn_load`, `btn_save`, `btn_options`, `btn_quit_to_mm`, `btn_quit` |
| уровень есть, другая игра | `:95` | `menu_main_mm` | `btn_ret`, `btn_options`, `btn_quit_to_mm`, `btn_quit` |

- В сессии `GameID()` остаётся `eGameIDSingle` (`MainMenu.cpp:194`: `b_is_single = IsGameTypeSingle() && !g_coop_menu_world_running`),
  поэтому и хост, и клиент видят `menu_main_single`. Нужные имена — в `ui_mm_main_16.xml:69-77` (список) и `:79-85` (мёртвый).
  `ui_mm_main.xml` стока — одна строка `#include "ui\ui_mm_main_16.xml"`.
- GAMMA: `G.A.M.M.A. UI/gamedata/configs/ui/ui_mm_main_16.xml:78-87`, `:89-96` и копия в моде 109 (MCM). Те же имена плюс
  `btn_mcm`. Фильтр по имени работает в обоих случаях.
- `CreateList` (`:114-154`): число кнопок из `GetNodesNum(path, 0, "btn")` `:124`, имя окна — из атрибута `name` `:147`.
  Отбросить узел по имени можно прямо в цикле `:131-152` (`continue`).
- `IsButton` (`:242-257`), `OnBtnClick` (`:357-368`), `OnKeyboardAction` (`:372-398`) работают по указателям и `m_selected_btn`,
  индексов конкретных кнопок не знают. `ShowMain` (`:208-216`) выбирает `m_buttons[0]`. Укороченный список безопасен.
  (Несвязанная особенность: `SelectBtn(CUIWindow*)` `:289-319` бежит по `m_buttons.size()` для всех страниц. В игровом меню
  страница всегда `epi_main`, других списков там нет.)
- Список пересоздаётся при **каждом** открытии меню:
  - `CMainMenu::Activate(true)` `MainMenu.cpp:182`, `:205-213` → `ReloadUI()` `:301-323`;
  - `ReloadUI` делает `NEW_INSTANCE(TEXT2CLSID("MAIN_MNU"))` `:309` — это Lua-класс `main_menu` (`ui_main_menu.script:19`);
  - его `__init` → `InitControls` → `xml:ParseFile("ui_mm_main.xml")` `:41` → `xml:InitMMShniaga("shniaga_wnd", self)` `:44`
    → `CUIMMShniaga::InitShniaga` → `CreateList`;
  - `ReloadUI` ещё раз зовётся при смене соотношения сторон открытого меню (`MainMenu.cpp:538-543`).
- XML читается заново при каждой сборке меню: `CXml::Load` зовёт Lua-колбэк `on_xml_read` каждый раз
  (`xrXMLParser/xrXMLParser.cpp:143`). Так наша кнопка «Кооператив» попадает в списки (`modxml_coop_menu.script:22-53`, DXML).

## A.2 Решение: где фильтровать и нужен ли сброс

**Где.** `CUIMMShniaga::CreateList` (`UIMMShniaga.cpp:131-152`): если `coop::mgr().active()` и имя узла — `btn_save`,
`btn_load` или `btn_lastsave`, узел пропускается.
- Инклюд: `#include "../coop/coop_manager.h"` (файл лежит в `ui/`; `MainMenu.cpp:3` пишет `"coop/coop_manager.h"`).
- Условие — `active()`, как в `MainMenu.cpp:193`. Ожидающий хост (`coop.host_when_ready`) **не** активен: холодное меню хоста,
  из которого `coop_menu.script:510-529` вызывает «Загрузить» / «Последний сейв», остаётся целым.
- Условие по списку не нужно: холодные списки видны только клиенту в фазах `Connecting…ReceivingWorld`. Прятать там
  «Загрузить» полезно: оно запускало бы `disconnect` + `start server` посреди входа (`ui_load_dialog.script:300-301`).

**Альтернатива (не выбрана).** Убрать узлы в DXML-обработчике `on_xml_read`: у `xml_object` есть `removeElement`
(`dxml_core.script:756`, GAMMA). Минусы:
- решение зависит от загрузки Lua-слоя коопа;
- привязано к имени файла `ui_mm_main*.xml` (скины других модов);
- рассчитывает на актуальность `coop.is_active()` в момент разбора XML.

**Нужен ли сброс меню.**
- Старт сессии при закрытом меню и конец сессии — нет, список строится при следующем открытии.
- Старт сессии из открытого игрового меню (`UICoopMenu:OnHostNow` `coop_menu.script:500-507`): окно «Кооператив» закрывается
  через `Close()` `:567-577`, меню показывается старое (`owner:ShowDialog(true)`), в нём «Сохранить / Загрузить / Последний
  сейв». Нужно: в `Close` (или в `OnHostNow` после успеха), если `level.present()`, вызвать `exec_console_cmd("main_menu off")`.
  Следующее открытие даст чистый список. Страховка — перехватчики методов (A.5).
- Конец сессии из открытого меню (`OnDisconnect` `:561-565`): список остаётся укороченным до следующего открытия.
  Безвредно, сброс не нужен.
- Если актор в сессии когда-либо мёртв (`g_Alive() == false`), список `menu_main_single_dead` без `btn_ret`; ESC не закрывает
  меню (`ui_main_menu.script:294-298`). После фильтра остаются «Опции», «Выход в меню», «Выход». Для Task 10 учесть.

**Правка движка вне `UIMMShniaga.cpp` для скрытия не требуется.** Ведущей: шаг в Task 17 дописывать не нужно, кроме
пункта «окно после старта хоста» (Lua, `coop_menu.script`, он уже в файлах Task 17).

## A.3 Все пути сейва и загрузки

Обозначения: «гейт» — закрыт ли путь вызовом `on_before_save_input` / `on_before_load_input`. «Хост» и «клиент» —
что есть **сейчас**, до Ф3. Строки стока; GAMMA в конце строки.

### Сохранение

| № | Путь | Файл:строка | Гейт | Сейчас: клиент | Сейчас: хост | Ф3 |
|---|---|---|---|---|---|---|
| S1 | F5 в игре: движок зовёт `level_input.on_key_press` напрямую (`Level_input.cpp:188`) → `action_quick_save` | `level_input.script:12-13`, `:48-104`; проверки жив и HUD свободен `:49`; сейв `:91` | **да**, тип 2, `:53-60` (`:56`) | `coop_main.on_before_save_input` (`:921-932`): отказ, но F5 просит быстрый сейв у хоста (`coop_core_player.script:247-258`) | открыт | `coop_saves`: отказ для всех, запрос клиента убрать (Task 17) |
| S2 | F5 при открытом меню | `ui_main_menu.script:299-301` → `level_input.action_quick_save()`; GAMMA `:321` | да (тот же гейт, тип 2) | как S1 | открыт | как S1 |
| S3 | Кнопка «Сохранить» → диалог → `ui_save_dialog.SaveFile` | `ui_main_menu.script:164-184` (гейт `:166-173`, тип 1 `:169`); `ui_save_dialog.script:254-258` (`exec_console_cmd("save …")` `:258`); GAMMA `:165`, `:170` | **да**, тип 1, один раз до диалога | отказ + патч `OnButton_save_clicked` (`coop_main.script:941-962`) | открыт | кнопка скрыта; гейт для устаревшего меню |
| S4 | F6 в меню («хардсейв») | `ui_main_menu.script:307-331` (гейт `:309-316`, тип 3 `:312`, сейв `:329`); GAMMA `:330-350` | **да**, тип 3 | отказ | открыт | отказ для всех |
| S5 | Сейв после сна | `ui_sleep_dialog.script:254` (`dream_callback2`); GAMMA `:354` | **нет** | C++ отказывает (`console_commands.cpp:1094`), в лог идёт строка | **пишет `<ник> - sleep`** | убирается заменой на `coop_rest.dream_end` (Task 14) |
| S6 | Сейв при старте нового мира | `itms_manager.script:249` → `new_game_equippment` `:697` → `:710`; GAMMA `itms_manager.script:704`/`:711` (3 мода) | нет | C++ отказывает | один раз при новой игре, `<ник> - autosave` | оставить, безвреден (единожды, до игры) |
| S7 | Таймер `game_autosave_new` | `game_autosave_new.script:17-29`, сейв `:22` (опция `other/autosave_timer_new`, по умолчанию 0) | нет | C++ отказывает | пишет `<ник> - tempsave`, если опция > 0 | Task 17: обёртка, сейв не зовётся |
| S8 | Сюжетные автосейвы | `xr_effects.script:4335-4351` — тело закомментировано (`:4341-4350`) | — | — | пустая функция | Task 13 вешает на неё привал |
| S9 | Автосейв при смене карты (C++) | `alife_update_manager.cpp:224-231` | — | клиент не сохраняет | хост: нужный сейв | оставить (Task 12) |
| S10 | Таймер C++ | `autosave_manager.cpp:55` `if (true) return;` | — | — | выключен | — |
| S11 | Сейв входа игрока | `coop/coop_join.cpp:347-364`, пакет `M_SAVE_GAME` напрямую; файл удаляется `:403-404` | — | — | служебный | не трогать |
| S12 | Консоль `save [имя]` | `console_commands.cpp:1090-1174`; защита `:1094` только `is_client()` | — | отказ | работает | оставить (отладка, автосейв) |
| S13 | Пакет `M_SAVE_GAME` от клиента | `coop/coop_events.cpp:435-441` | — | проглочен (`saves_blocked`) | — | оставить |
| S14 | `F7` в `Level_input.cpp:323` (M_RELOAD_GAME) | `#ifndef MASTER_GOLD`; релиз определяет `MASTER_GOLD` (`xrCore.h:5-7`) | — | — | выкомпилирован | — |
| S15 | Сейвы модов GAMMA | таблица A.4 | нет | C++ отказывает | **работают** | `YACS` и `Soulslike` выключает установщик; остальное — A.5 |

### Загрузка

| № | Путь | Файл:строка | Гейт | Сейчас: клиент | Сейчас: хост | Ф3 |
|---|---|---|---|---|---|---|
| L1 | F7 в игре → `action_quick_load` | `level_input.script:14`, `:106-137`; гейт `:108-113`; `load` `:130` | **да** (`on_before_load_input`) | отказ (`coop_main.script:934-939`) + C++ | открыт | отказ для всех |
| L2 | F7 в меню; в холодном меню F7 → `OnButton_last_save` | `ui_main_menu.script:302-304`, `:345-347`; GAMMA `:324` | в игре да; в холодном меню нет | в игре отказ | открыт | отказ в игре; холодное меню не трогать |
| L3 | Кнопка «Загрузить» → `ui_load_dialog` → `load_game_internal` | `ui_main_menu.script:198-209`; `ui_load_dialog.script:288-304` (`:300-301` холодное меню, `:303` игра), `:307-338`; GAMMA `ui_main_menu:212` | **нет** | патч `OnButton_load_clicked` (`coop_main.script:945-960`, ставится `client_mode`) + C++ | **открыт** | кнопка скрыта; перехватчик метода для всех |
| L4 | Кнопка «Последний сейв» | `ui_main_menu.script:112-136` (холодное `:114-126`), `LoadLastSave` `:269-272`, `OnMsgYes` `:228-235`; GAMMA `:114`, `:289-291` | **нет** | патч `OnButton_last_save` + C++ (`console_commands.cpp:1275`) | **открыт** | то же |
| L5 | Экран «Игра окончена»: `game_over` → действие `quick_load` → `load_last_save` | `Actor.cpp:1000` (`:994` в закомментированном блоке); `game_tutorials.xml:8-28` (действие `:16`); `xr_effects.script:2887-2889`; GAMMA `xr_effects.script:2959` | **нет** | C++ отказ | **загружает последний сейв хоста** | Task 8/10: см. риск R5 |
| L6 | Консоль `load <имя>` | `console_commands.cpp:1176-1252`; защита `:1183` только `is_client()` | — | отказ | работает | оставить (нужен «Восстановить») |
| L7 | Консоль `load_last_save` | `console_commands.cpp:1254-1321`; защита `:1275` | — | отказ | работает | оставить |
| L8 | Пакет `M_LOAD_GAME` / `M_RELOAD_GAME` от клиента | `coop/coop_events.cpp:435-441` | — | проглочен | — | оставить |
| L9 | `exec_console_cmd("load ~#…:"..)` — отладочный вывод | `_g.script:635` и отладочные скрипты | — | в лог идёт отказ | «Cannot find saved game» | безвреден; не путать с загрузкой |

**Что закрывают гейты на самом деле.** Вызывают `on_before_save_input`: S1, S2, S3, S4. Вызывает `on_before_load_input`:
только `level_input.action_quick_load` (L1, L2). Остальные пути (L3, L4, L5, S5-S7, S15) обработчики не вызывают совсем:
их закрывает только перехват самих методов или C++.

**Порядок обработчиков.** `SendScriptCallback` вызывает **все** обработчики, возврат первого не прерывает. Наш `coop_main`
грузится раньше остальных `on_game_start` (`coop_main.script:1105-1107`), но сообщения других обработчиков всё равно
выйдут: стоковый `bind_campfire.on_before_save_input` (`bind_campfire.script:159-168`, только в campfire mode, дополнительно
выполняет `main_menu off`), `LevelChangeCars.script:36-42`, `campfires_on_map_mcm.script:83-90` (побочный эффект «посещённые
костры»). Сообщение коопа должно быть читаемым при любом порядке.

## A.4 Моды GAMMA (профиль `G.A.M.M.A`, 579 включённых модов)

Поиск `exec_console_cmd` с `save` / `load` / `load_last_save` / `autosave` в `gamedata` всех включённых модов, плюс
`on_before_save_input` / `on_before_load_input`, плюс `ui_save_dialog` / `ui_load_dialog` / `OnButton_*`.
Прямых `get_console():execute("save …")` нет (только настройки рендера). Ни один скрипт не кэширует `exec_console_cmd`
в локальную переменную (поиск по стоку и по всем 579 модам пуст).

| Мод (строка в `modlist.txt`) | Файл:строка | Что делает | В кооп-сессии | Действие |
|---|---|---|---|---|
| 203 YACS Better Campfire Saves (566) | `ish_campfire_saving.script:231` | `create_emergency_save` из `on_key_release(F5)` с Shift после 3 мин («Mommy token») → `save … - <mommy>save`; гейт `on_before_save_input` `:40-77` | **обходит** `on_before_save_input`: сейв хоста по Shift+F5 | выключает установщик (`docs/MOD_REPLACEMENTS.md:24`) |
| G.A.M.M.A. YACS no quit | — | то же, выключен в профиле | — | выключить |
| 338 Soulslike (451) | `soulslike.script:441`, `:522` | сейв по смерти / на кроватях, гейт `:522` | режим новой игры | выключает установщик |
| G.A.M.M.A. Sleep Balance (290) — **победитель** | `ui_sleep_dialog.script:354` | сейв после сна | как S5 | Task 14 |
| 111 Immersive Sleep (649) | `ui_sleep_dialog.script:354` | то же | проигрывает Sleep Balance | — |
| 234 Dynamic Anomalies Overhaul (534) | `drx_da_main.script:943`, `:3537` | `<ник> - DAO tempsave` после чистки аномалий, если `save_after_cleanup` (MCM, по умолчанию выключено: `drx_da_main_mcm.script:91`) | хост пишет лишний сейв, если включить | не трогать; A.5 |
| G.A.M.M.A. Quests Rebalance (258) | `xr_effects.script:2959`, `:4419` | копия стока: `load_last_save`, `scenario_autosave` (закомментирован) | как L5 | — |
| G.A.M.M.A. Starter items…, 184 Body Health, Wildkins | `itms_manager.script:704`/`:711` | копии `new_game_equippment` | как S6 | — |
| 109 MCM (651) | `ui_main_menu.script` | копия меню с `btn_mcm`; номера выше | победитель по меню | номера GAMMA в таблицах A.3 |
| G.A.M.M.A. Cooking Overhaul (346) | `bind_campfire.script:160-169` | гейт campfire mode | — | — |
| Darkasleif's Cars Fixes (221) | `LevelChangeCars.script:12`, `:36-42` | гейт «не сохраняться в машине» | сообщение в сессии | — |
| 226 Display Campfires on Map (538) | `campfires_on_map_mcm.script:83-98` | при сохранении метит костёр | безвреден | — |
| 410 3DSS (на `on_before_load_input`) | `ubgl_no_3db.script:97` | сохраняет настройки перед загрузкой | безвреден | — |

Стоковые режимы новой игры (`gamemode_*.script`, `bind_campfire`):
- Ironman стирает сейвы при смерти (`gamemode_ironman.script:101-141`) через `actor_on_before_death`. Он зовётся из
  `CEntity::KillEntity` **после** `coop::survival::intercept_actor_kill` (`Entity.cpp:266`), то есть в сессии не срабатывает.
- «Агония», «Таймер», «Азазель» работают через смерть и сейв-гейты: в сессии актор не умирает, сейвы игроку закрыты.
  Это и есть механизм нейтрализации для реестра (`docs/MOD_REPLACEMENTS.md`, строки «Агония…» и «Сохранение у костра»).

## A.5 Что делает Task 17 (по итогам §A)

1. **Движок.** `UIMMShniaga.cpp`: фильтр по имени в `CreateList` (A.2). Больше ничего в C++.
2. **`coop_saves.script`** (домен `view`, работает у всех):
   - `on_before_save_input` и `on_before_load_input`: для **хоста и клиентов** в сессии `flags.ret = true` + подсказка. Условие —
     `coop.is_active()`, **не** «ожидающий хост» (иначе сломаются «Хостить после загрузки / последнего сейва / новой игры»,
     `coop_menu.script:510-529`).
   - Обёртки методов `ui_main_menu.main_menu.OnButton_load_clicked` и `OnButton_last_save` в сессии (S3 уже закрыт гейтом).
     Те же имена, что в `coop_main.patch_main_menu` (`:941-962`); Task 18 его убирает, поэтому `coop_saves` обязан
     покрыть и хоста.
   - Кнопка «Восстановить» (Task 17) должна идти мимо этих обёрток: свой диалог и `exec_console_cmd("load coop_auto_N")`.
     `ui_load_dialog` для этого не нужен (он перечисляет все сейвы).
   - Окно `coop_menu.script`: после успешного `api.host(port)` из игрового меню закрывать меню (`main_menu off`), не возвращаться
     в старое.
3. **Рекомендую (необязательно):** единая точка для всех Lua-вызовов `save` / `load` — обёртка глобальной
   `_G.exec_console_cmd` (`_g.script:743`): в сессии отбрасывать команды, начинающиеся с `save `, `load ` и `load_last_save`,
   кроме вызовов из `coop_saves` (флаг на время вызова). Закрывает S5-S7, S15 и неизвестные моды разом. Цена: строки
   `exec_console_cmd("load ~#…")` (отладочный вывод `_g.script:635`) нужно пропустить по префиксу `load ~`.
   Альтернатива по скриптам: `game_autosave_new.autosave` (обязательно, тест уже в плане) и `drx_da_main` (по желанию).
4. **Убрать** `request_quicksave` / `core.save_req` (`coop_core_player.script:30-31`, `:247-306`) и флаг `client_quicksave`
   в `coop_menu_options.script:68`, как в плане.
5. Существующий хост-гейт `host_can_save` (`coop_core_player.script:260-275`) зовёт `SendScriptCallback("on_before_save_input")`
   и после Task 17 всегда отказывал бы. Раз запрос убирается, функция уходит вместе с ним.

---

# §B. Сон и палатка

## B.1 Где что исполняется (из `coop_domains*.ltx`)

| Скрипт | Домен | Файл |
|---|---|---|
| `ui_sleep_dialog`, `ui_main_menu`, `ui_load_dialog`, `ui_save_dialog` | `view` (`ui_*`) | `coop_domains.ltx:63` |
| `item_tent`, `actor_status_sleep`, `actor_status_thirst`, `itms_manager` | `owner` | `coop_domains.ltx:84-108` |
| `bind_campfire` | `owner` | `coop_domains_npc.ltx` |
| `game_autosave`, `game_autosave_new`, `surge_manager`, `psi_storm_manager` | `host` | `coop_domains.ltx:111-124` |
| `level_input`, `xr_effects` | не перечислены → `host` | но движок зовёт `level_input.on_key_press` **напрямую** (`Level_input.cpp:188`), мимо фильтра; функции `xr_effects` вызывает логика, а не `RegisterScriptCallback` |
| `save_state` | `[callbacks_host]` (у клиента не работает) | `coop_domains.ltx:48` |
| `load_state` | `[callbacks_always]` | `coop_domains.ltx:27` |

«Owner»: колбэк выполняется на машине владельца актора, то есть у каждого игрока для **его** действий.
Фильтр касается колбэков из `RegisterScriptCallback` / `AddUniqueCall` / `CreateTimeEvent`. Функторы, которые движок зовёт
сам (`level.add_call`, эффекторы камеры по имени `"ui_sleep_dialog.dream_callback"`), фильтр не видит.

## B.2 Таблица: вход → функция стока → где исполняется сейчас → что делает Ф3

Строки стока (`anomaly-ref/unpacked/scripts`). GAMMA — победитель `ui_sleep_dialog.script` у **G.A.M.M.A. Sleep Balance**
(размер файла совпал со стендом).

| № | Вход | Функция стока (файл:строка) | Где исполняется сейчас | Что делает Ф3 |
|---|---|---|---|---|
| Z1 | Зона сна (25 рестрикторов): игрок внутри, жмёт USE | `configs/scripts/sr_sleep.ltx` (`run_tutorial(tutorial_sleep)`), `pri_a16_sr_sleep.ltx`; `game_tutorials.xml:337-345` (`<action id="use">`) → `ui_sleep_dialog.sleep_in_zone` `:319-327` (`give_info("sleep_active")` `:322`, `sleep()`); GAMMA `:419-428` | Логика рестриктора: по `coop_npc_logic.script:97-102`, `:151-157` рестриктор с `%-tutorial_sleep …%` — «общий» (меняет инфо, не только туториал), то есть **считает хост по каждому игроку**, а `run_tutorial` уходит в машину игрока (`npc.fx`, `ACTOR_FX` `:75-80`). `sleep_in_zone` и проверка зоны (`utils_obj.npc_in_zone` через `db.zone_by_name`) идут **у игрока** с его `db.actor`. Условия логики `actor_has_target_obj` (`xr_conditions.script:135`) и `has_active_tutorial` (`:2391`) хост считает по своему состоянию | Ничего особого: вход сходится в `sleep()` → `TestAndShow` (B.4). Место отдыха для привала хост определяет сам по списку Task 7 (`[coop_rest_zones]` = `sleep_zones`, `:292-318`; сверено со списком плана: 25 имён, идентичны, в GAMMA `:392-418` те же). Проверить вживую: подсказка клиенту (host-локальные условия) |
| Z2 | Спальник из инвентаря (placeable) | `item_tent.actor_on_item_use` `:121`, ветка `:131-143`, `alife_create("ph_sleepbag", …)` `:134`, `spawned_sleepbags` `:136`, `compression_bag` `:137` | У использующего. **Клиент:** `alife_create` → `nil` (B.3), строка `:135` падает в `actor_on_item_use`, обёрнутом `pcall` роутером (ошибка в лог и счётчик). Спальник израсходован, `ph_sleepbag` и `compression_bag` не созданы | Обёртка для клиента (B.3); хост без изменений |
| Z3 | Спальник без размещения (`use_placeable = false`, по умолчанию `true`: `itms_manager.ltx:8`) | `:138-142` → `ui_sleep_dialog.sleep_bag(se_obj, sec)` | У использующего | Через `sleep_bag` → `TestAndShow` (Task 14) |
| Z4 | Использование размещённого `ph_sleepbag` / кровати | `item_tent.physic_object_on_use_callback` `:149-154` (вызов `bind_physic_object.script:122`), `hide_hud_inventory()`, `ui_sleep_dialog.sleep_bag(obj:id(), sec)` `:152`; `ph_sleepbag.ltx` | У использующего (владелец; биндер `generic_physics_binder` работает и у клиента, `coop_client_binders.script:80`) | Через `sleep_bag` → `TestAndShow`. Кровати Hideout Furniture идут тем же `sleep_bag(id)` (`bind_hf_base.script:85-93`, `mod_system_props.ltx` мода 349) |
| Z5 | GAMMA New Safe Zones | `TB_Coordinate_Based_Safe_Zones.script:395-404`: `physic_object_on_use_callback` для `ph_sleepbag` → `ui_sleep_dialog.main()` | У использующего | Через `sleep()` → `TestAndShow` |
| Z6 | Палатка из инвентаря | `item_tent.actor_on_item_use` `:125-128` → `start_timer` `:16-28` → `level.add_call(check_timer, itm_tent_func)` `:23` → `itm_tent_func` `:30-45`: `alife_create("ph_tent", pos, 1, gv)` `:37`, `map_add_object_spot_ser(se_obj.id …)` `:38`, `spawned_tents[…]` `:39`, `alife_create_item("itm_tent_bag", db.actor)` `:40`. В GAMMA вход — `use1_action_functor = item_tent.func_use_tent` (`139-Craft and Repair Overhaul`, `items_tools.ltx:407-408`, `:461-462`) → `item_tent.script:210-218` | У использующего. **Клиент: FATAL по чтению кода** (B.3) | Обёртка для клиента (B.3) |
| Z7 | Свернуть палатку | `actor_on_item_use` `:125` (`itm_tent_bag` и `get_nearby_tent(3.5, true)`) → `start_timer` → `itm_tent_bag_func` `:68-82` | У использующего. **Клиент:** `get_nearby_tent` смотрит в `spawned_tents`, который у клиента — снимок хоста на входе (`load_state` `:161-164`, `save_state` `:156-159` только хост). Для известной палатки `alife_create_item("itm_tent")` проходит (родитель — актор), а `alife_release(se_obj)` чужой палатки отказывается (`coop_requests.cpp:1690-1702`) — **палатка остаётся и предмет выдан: дубль** | Обёртка (B.3) |
| Z8 | Свернуть спальник | `compression_bag` `:146` → `use_compression_bag` `:84-108` | То же | Обёртка (B.3) |
| Z9 | Кнопка «Спать» | `UISleep:OnButtonSleep` `:153-200` (`disable_ui` `:160`, камера `:161`, `level.add_pp_effector` `:162`, звук `:165-166`, `actor_is_sleeping` `:199`); GAMMA `:161-214` + вето «не устал» `:162-167` | У спящего. Сейчас обёртка `coop_economy_group.script:435-460` (голосование, `request_skip`); после одобрения стоковый ход идёт **только у спящего** | Task 14: `lie_down` + окно дрёмы; `patch_sleep` уходит |
| Z10 | Конец камеры 1 | `dream_callback` `:233-248`: `level.change_game_time(0, hours, 0)` `:243`, `db.actor.power = 1` `:245`, `actor_on_sleep` `:247`; GAMMA `:331-348` (+ `get_immersive_sleep_hours`) | У спящего. Время: клиентский вызов идёт хосту как `economy.skip` (`coop_economy_group.script:151-165`), чужие `change_game_time` движок отклоняет (`coop_worldstate`) | Task 14: `coop_rest.dream_end` без `change_game_time` |
| Z11 | Конец камеры 2 | `dream_callback2` `:250-261` (`enable_ui` `:251`, звук `:252-253`, сейв `:254`, снятие инфо `:258-260`); GAMMA `:350-361` | У спящего. Хост пишет `- sleep` | Task 14: без сейва; автосейв после общего сна (Task 12) |
| Z12 | Принудительный сон | `ui_sleep_dialog.sleep_forced` `:272-278` (`GUI.forced`); вызывают `actor_status_sleep.force_sleep` `:83-87`, `actor_status_thirst.force_sleep` `:86-93` (после — смерть с шансом `die_chance`). **В GAMMA оба `force_sleep` пустые** (только `printf`: победитель Sleep Balance `actor_status_sleep.script:95-98`, `actor_status_thirst.script:85-88`) | У владельца. `OnButtonSleep` с `self.forced` идёт в оригинал мимо голосования (`coop_economy_group.script:444`) | Task 14: `lie_down(h, true)` (обморок — отдых без привала). Только стоковый Anomaly, в GAMMA ветка мертва |
| Z13 | Проверка укрытия | `UISleep:TestAndShow` `:95-133`: кровотечение/радиация `:97-112`, укрытие `current_safe_cover` `:115` или палатка `get_nearby_tent(1.5)` `:119`; GAMMA `:96-140` + вето `last_sleep < 5000` («не хочу спать», `:97-103`) | У игрока; `current_safe_cover` у клиента зеркалит хост (`coop_main.script:788-793`) | Task 14: пропуск проверки укрытия, оставить кровотечение и радиацию. Спальник **сам по себе укрытием не считается**. Костёр — тоже (в стоке сна у костра нет) |
| Z14 | Окно и `sleep_active` | `sleep_in_zone` `:322` даёт `sleep_active`; `ProcessEventQueue` при нём не работает (`_g.script:364-367`) → встают все `CreateTimeEvent` этой машины; снимают `:110`, `:125`, `:224`, `:260` | У игрока; у хоста замирают и таймеры мира | Task 14: окно дрёмы снимает `sleep_active` (тест уже в плане) |

## B.3 Шаг 4: что делает `item_tent` у клиента

**Факты (чтение).**
1. Lua `alife_create(sec, pos, lid, gid)` без родителя (`_g.script:2071-2145`) → `alife():create(sec, pos, lid, gid)` без id.
   Хук `alife_simulator_script.cpp:195` → `lua_create(…, parent = 0xFFFF, register_now = true)` (`coop_requests.cpp:1628-1648`) →
   `lua_forward` (`:600-610`) → `client_forward_spawn` (`:1424-1464`).
2. `client_forward_spawn` возвращает `false` при `parent == kNoId` (`:1394-1396`): «world-caused: loot, population, effects
   are the host's job». Тогда `lua_forward` пишет «refused on a client: world spawns are the host's job», считает `lua_refused`
   и возвращает `nullptr`. **Запрос хосту не уходит.** (Уходит только спавн, цепочка родителей которого кончается на актор
   клиента: `alife_create_item("itm_tent_bag", db.actor)` пройдёт.)
3. `_g.alife_create` при `nil` печатает ошибку и возвращает ничего (`_g.script:2138-2140`). `itm_tent_func` следом берёт `se_obj.id`
   (`item_tent.script:38`) → ошибка «index a nil value».
4. `itm_tent_func` вызывает движок через `level.add_call(check_timer, itm_tent_func)`: `CPHScriptAction::run` `(*m_lua_function)()`
   (`PHScriptCall.cpp:61-65`, `level_script.cpp:643-650`). Это luabind-функтор **без** `pcall` на нашей стороне. Ошибка внутри
   → `CScriptEngine::lua_pcall_failed` → `Debug.fatal` (`script_engine.cpp:276-296`), а в релизе `XRAY_EXCEPTIONS = 0`
   (`xrCore.h:38-44`). Тот же класс, что «ошибка Lua в `iterate_inventory` — FATAL» из заметки W3c.
   **Вывод: палатка у клиента роняет игру через ~4 с после использования** (4 с — при включённых анимациях,
   `item_tent.script:17-18`). Не проверено в игре, но все звенья прочитаны.
5. В отличие от палатки спальник (Z2) стоит в самой `actor_on_item_use`, обёрнутой `pcall` роутером: клиент теряет предмет,
   вылета нет.
6. `spawned_tents` / `spawned_sleepbags` — таблицы модуля `item_tent` (`:13-14`), хозяин — хост (`save_state` не работает
   у клиента, `load_state` в `callbacks_always`). Клиент знает только палатки, существовавшие при его входе.

**Нужна ли Ф3 обёртка `item_tent`: да.**
- Маршрутизатор вызовов Ф2 (`docs/MOD_LAYER.md` §2.3, Ф2 Task 12) не помогает: для `alife:create` у клиента он оставляет
  существующий путь ReqSpawn (то есть то же отбрасывание), а «id по резерву» — предложение без решения (Ф2 Task 8,
  только разведка). Ф2 прямо отдаёт `item_tent` и `ui_sleep_dialog` Ф3 (`docs/plans/2026-10-22-f2-mod-layer.md`, «Общие файлы с Ф3»).
- Следствие для Task 7: «заявка на палатку, хост ищет ничью палатку не старше 15 с» для **клиента** не найдёт ничего, палатки нет.
  Решение плана 6 («`coop_requests.cpp` не трогается») остаётся, но создавать палатку должен хост по просьбе клиента.

**Рекомендуемая форма (обёртка Task 13; детали — решает исполнитель):**
- Вся стоковая палаточная логика `item_tent` у **клиента** выключена, её заменяет Ф3-обработчик. Хост исполняет сток как есть.
  Как выключить стоковые колбэки `item_tent` на клиенте: через роутер Ф2 (домен `none` для пары «колбэк + скрипт») или, пока его
  нет, домен `blocked` для `item_tent`; `load_state` останется, он в `[callbacks_always]` (`coop_domains.ltx:26-31`).
- Что подменять. Различать **глобальные** функции модуля (подменяются присваиванием в таблицу `item_tent`, имя ищется при вызове) и
  **локальные** (снаружи не обернуть):
  - глобальные: `start_timer` `:16`, `itm_tent_func` `:30` (`start_timer` берёт её в момент вызова), `itm_tent_bag_func` `:68`,
    `use_compression_bag` `:84`, `func_use_bag` `:200`, `func_use_tent` `:210`;
  - локальные: `actor_on_item_use` `:121` и `physic_object_on_use_callback` `:149`. Ветка спальника (Z2, `:131-143`) сидит именно в
    локальной `actor_on_item_use`, обернуть её нельзя. Путь: выключить стоковые колбэки на клиенте (см. выше) и зарегистрировать
    свой `actor_on_item_use` с теми же секциями (`itm_tent`, `itm_tent_bag`, `itm_sleepbag`, `sleep_bag`, `compression_bag`;
    списки `SleepBagSections` / `TentBagSections` из `itms_manager.ltx:11-13`, `:22-24`).
  - **GAMMA:** в `items_tools.ltx` мода 139 (`:407-408`, `:461-462`) предметы использует `UIInventory:Action_Custom`
    (`ui_inventory.script:1214-1229`), который зовёт `item_tent.func_use_bag` / `func_use_tent`, а те — локальную `actor_on_item_use`
    **напрямую**. По чтению, диспетчер колбэков `actor_on_item_use` при этом не вызывается (его шлёт «съедение» предмета движком).
    Тогда хук Task 13 «`actor_on_item_use` для `itm_tent`, `itm_sleepbag`» в GAMMA ничего не увидит, на хосте тоже. Проверить вживую.
    Для хоста признак палатки — появление `ph_tent` / `ph_sleepbag` в мире (Task 7, `tent_sections`), он от Lua не зависит.
- Протокол клиента: «поставь `ph_tent` / `ph_sleepbag` в точке P» → хост проверяет (прокси пира жив, расстояние ≤ ~5 м от прокси,
  секция из списка) → создаёт тем же вызовом, что сток → записывает в `item_tent.get_spawned_tents()` / `get_spawned_sleepbags()`
  (таблицы живые, их сохраняет `save_state`) → ставит привал **этому** пиру сразу (без поиска «ничьей» палатки) → возвращает клиенту id
  для метки КПК. Предметы `itm_tent_bag`, `compression_bag`, `itm_tent` выдаются клиенту существующим путём ReqSpawn
  (родитель — актор), эти вызовы можно оставить.
- Свернуть (Z7, Z8): клиент просит хост снять свою палатку (владелец известен хосту); без этого — дубль предмета.
- Отдельно, независимо от остального: **немедленная защита от вылета** — обёртка над `item_tent.itm_tent_func`, которая у клиента
  возвращает сразу (с подсказкой). Пока Ф3 не готова, это единственное, что не даёт клиенту падать.

## B.4 Что брать задачам

**Task 7 (источники на хосте).**
- Список зон сна верен (25 = сток = GAMMA).
- Хост видит `ph_tent` / `ph_sleepbag` сам, но **только созданные им самим или по его запросу**. Для клиентской палатки нужна просьба (B.3).
- Спальник сам по себе стоком не считается укрытием для сна (Z13); привал у спальника — решение Ф3, не стока.

**Task 13 (Lua привалов).**
- Хуки не на `actor_on_item_use`, а на подмененные функции `item_tent` (B.3). Тест `tent_claim_sent` из плана
  (`actor_on_item_use` с `itm_tent`) переписать под выбранный вход.
- `scenario_autosave` — пустая функция стока (`xr_effects.script:4335-4351`), обёртка безопасна; ~30 вызовов в скриптах и ltx.
  Проверка в GAMMA: копия в Quests Rebalance тоже пустая.
- Задержка 6 с в плане (4 с анимация + запас) верна для стока; в GAMMA `func_use_tent` вызывает ту же `start_timer`, задержка та же.

**Task 14 (общий сон).**
- Обёртки ставить в `ui_sleep_dialog.UISleep.TestAndShow` / `.OnButtonSleep` и в `ui_sleep_dialog.sleep_forced` / `sleep_bag` присваиванием.
  Колбэки камеры вызываются **по имени** (`"ui_sleep_dialog.dream_callback"` `:161`, `:169`, `:171`, `:235`, `:237`), а тело берёт `GUI` (`:13`)
  модуля: сохранить имена и `GUI`.
- Уже есть три слоя обёрток: `coop_mods_misc.install_sleep` (`coop_mods_misc.script:234-261`, `TestAndShow` и `OnButtonSleep` с групповой
  усталостью в GAMMA), `coop_economy_group.patch_sleep` (`:435-460`, уходит), и Task 14. Порядок установки определяет, кто видит вето
  «не устал» (GAMMA `:97-103`, `:162-167`): оно внутри стокового (GAMMA) `TestAndShow` и `OnButtonSleep`, перед проверкой укрытия, и считается по
  `actor_status_sleep.get_last_sleep()`. Групповое значение подставляет `with_party_sleepiness`.
- `_G.mus_vol` / `_G.amb_vol` стока (`:163-164`, `:252-253`) делит `coop_npc_effects.script:370-371`. Эффекты сна Task 14 должны читать и писать их так же.
- `sleep_in_zone` даёт `sleep_active` **до** `TestAndShow`; ранний выход обёртки обязан снять его (`:110`, `:125`).
- Вето GAMMA и нет-вето стока: в стоке сон возможен при любой усталости.

## B.5 Что проверить вживую (чтением не решить)

1. Палатка клиента сейчас падает (B.3, п.4). Подтвердить журналом `FATAL … itm_tent_func`.
2. Подсказка зоны сна у клиента: по чтению классификатора рестриктор считает хост, и тогда условие `actor_has_target_obj`
   берётся по прицелу хоста.
3. Что делает `use_callback` физического объекта на клиенте для `ph_sleepbag` (Z4): биндер работает, события в Lua идут от пира.
4. Нужно ли закрывать меню после старта хоста из игрового меню (A.2) или хватает перехватчиков.

---

## Риски и открытое

| № | Что | Где | Серьёзность |
|---|---|---|---|
| R1 | Клиент использует `itm_tent` → FATAL (по чтению). Сегодня, независимо от Ф3 | B.3 | высокая |
| R2 | План Task 7 и заметка в vault считают, что запрос клиента на палатку доходит до хоста. Не доходит | B.3 | высокая для Task 7/13 |
| R3 | Устаревшее меню после старта сессии из игрового меню; `OnButton_load_clicked` / `OnButton_last_save` не гейтятся стоком; патч `coop_main` — только клиент | A.2, A.5 | средняя |
| R4 | Лишние сейвы хоста от `dream_callback2`, `game_autosave_new`, GAMMA-модов | A.3, A.4 | низкая (мусор в списке, паузы на запись) |
| R5 | `CActor::Die` в сессии → `start_tutorial("game_over")` (`Actor.cpp:1000`) → `load_last_save` хоста без защиты. Сегодня не наступает: `intercept_actor_kill` (`Entity.cpp:266`, `coop_survival.cpp:1692-1714`) не пускает смерть при `live()` (хост или живой клиент). Task 8/10 (hardcore, «персонаж выбывает») не должны пускать `Die` без гарда на `on_tutor_gameover_quickload` / `Actor.cpp:1000` | A.3 L5 | высокая для Task 10 |
| R6 | Тройная обёртка `TestAndShow` / `OnButtonSleep` (GAMMA: `coop_mods_misc`, `coop_economy_group`, Task 14) | B.4 | средняя |
| R7 | `exec_console_cmd` как единая точка перехвата (A.5 п.3): решение за Task 17, нужно согласие на побочные эффекты | A.5 | — |

## Правки документов (для ведущей, агент их не вносил)

- `docs/plans/2026-10-22-f3-checkpoints-death.md`, Task 7 шаг 4 и Task 13 шаг 3: палатка клиента создаётся хостом по просьбе
  (B.3); хук на `item_tent`, а не на `actor_on_item_use`.
- `docs/CHECKPOINTS_DEATH.md` §2.2, строка «Палатка из спальника»: уточнить «ставит хост по просьбе игрока».
- vault `10 Projects/Anomaly Coop/Ф3 план — привалы и смерть.md`, факт «Палатка у клиента»: заменить «пересылает запрос» на
  «отбрасывает (родителя нет), `itm_tent_func` падает FATAL».
- `docs/MOD_REPLACEMENTS.md`: после Task 17 — механизм нейтрализации «Сохранение у костра», «Агония…», «Таймер», «Азазель»,
  «Автосейв по таймеру»: «в сессии актор не умирает (`coop_survival::intercept_actor_kill`), сейвы игроку закрыты `coop_saves`».
  После Task 13/14 — строки про `item_tent` и стоковый сон (B.3).
