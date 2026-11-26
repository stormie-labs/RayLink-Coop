# Два режима и три слоя кода

Решения владельца 2026-11-18. План работ — `docs/plans/2026-11-18-two-modes.md`. Правила проекта — `CLAUDE.md`.

Слова владельца:

- «Оставляем только кооп и сервер. Режим гибрид нахуй, и сюжетные карты вместе — тоже нахуй.»
- «Развилки в топку, делаем два разных режима. С игры запускается чисто кооп, а сервер из лаунчера.»
- «Главное, чтобы не было таких ситуаций, что мы чинили сервер, а затронуло кооп… я бы дал общему коду название, чтобы
  правильно определять, что можно писать в него, а что нельзя.»
- «Стим только в режиме коопа. Сервер не через стим.»

Основание документа — разборы `temp/modes/map-engine.md`, `map-scripts.md`, `map-products.md`, два проекта и критика
`temp/modes/critique.md` (2026-11-18). Ссылки вида `файл:строка` — по состоянию кода на 2026-11-18. Пометка
«не проверено» значит, что код по этому месту не открывали или в игре это не запускали.

Статус: **правила действуют с шага S1** (проверка `tools/check_layers.py`). До шага S4 часть кода ещё лежит не в своём
слое; такие места перечислены в `tools/layers_allow.txt`, и их число только уменьшается.

---

## 1. Два режима и как каждый запускается

| | Кооп | Сервер |
|---|---|---|
| Что это | хост играет сам, все игроки на его карте | сервер мира отдельным процессом без игрока (консоль) и серверы карт, по одному на карту с игроками. Игроки на разных картах |
| Кто решает за игрока | процесс хоста: карта игрока загружена у него | сервер мира; карты игрока у него нет, факты о карте сообщает сервер карты |
| Кто запускает | **только игра**: меню «Хост» (`coop_menu.script:2132-2151`), `-coop_host` (хост Steam), «Играть» в лаунчере для кооп-мира (`-coop_world_auto <мир>`) | **только лаунчер**: «Запустить сервер» / «Создать мир» (`backend.rs:822-850`, `server_spawn` в `launch/mod.rs:118-131`) |
| Процесс | `AnomalyCoopDX11AVX.exe` | сервер мира `RayLinkServer.exe -coop_dedicated …`; серверы карт `-coop_mapserver <карта>` запускает сам сервер мира тем же exe (`xrGame/coop/srv/coop_mapserver.cpp:292`) |
| Как входит игрок | `-coop_connect`, приглашение Steam | «Войти в мир» в лаунчере (`world_enter`, `backend.rs:736`) |
| Steam | да | нет (раздел 8) |
| Сохранения | у хоста, актор сейва — персонаж хоста | у сервера мира, актор сейва — «призрак» сервера на `fake_start` (`coop_dedicated.script:156-160`) |

Чего больше нет (раздел 7): гибрида («хост играет и ведёт свою карту, остальные карты у скрытых серверов карт»),
правила «сюжетные карты вместе», запуска сервера из игры (`coop_world_server.cpp`, `coop_world_wait.script`).

Один exe и один пакет на оба режима остаются (`tools/package.ps1`): `RayLinkServer.exe` — жёсткая ссылка лаунчера на тот
же exe (`launch/mod.rs:118-127`). Разделение — в коде и в проверках, а не в двух программах.

---

## 2. Три слоя

| По-русски | Имя в коде | Что в нём | Как узнать файл на глаз |
|---|---|---|---|
| **Ядро** | `core` | то, что нужно обоим режимам **и** ведёт себя в них одинаково: синхронизация, инвентарь, смерть и подъём, деньги, задания как правила, чекпоинты как правила, HUD, меню, адаптеры модов, протокол | **нет метки слоя**: движок в `xrGame/coop/` и `xrCoop/`, скрипты `coop_<область>.script`. Первая строка файла — `// Ядро: без проверок режима (docs/MODES.md)` или `-- Ядро: …` |
| **Кооп** | `hostplay` | только там, где хост играет сам: хост-игрок (LocalLink), переход группой и точка ожидания, Steam, кооп-ответы интерфейса | `xrGame/coop/hostplay/`, `xrCoop/hostplay/`, `coop_hostplay_<область>.script`, пространство имён `coop::hostplay` |
| **Сервер** | `srv` | только сервер мира и серверы карт: места, LevelMap/LevelMove, мосты, trunk, передача карт (xfer), запуск серверов карт, консоль оператора, дальние виды, сюжеты по фракциям, серверные ответы интерфейса | `xrGame/coop/srv/`, `xrCoop/srv/`, `coop_srv_<область>.script`, `coop::srv`. Старые честные пространства `coop::levels`, `coop::mapserver`, `coop::dedicated` живут там же |

Почему так:

- `coop` занято: это префикс всего продукта, иначе вышло бы `coop_coop_*`.
- `host` занято: `is_host()` — 212 мест в движке и 253 строки в скриптах, и `host_*` значит «сторона, которая решает» в
  обоих режимах (critique §8.1, BF §1.1).
- `hostplay` и `srv` сегодня не встречаются нигде (0 совпадений) — путаницы не будет.
- Файл без метки — Ядро. Новый файл, который никто не разметил, получает **самые строгие** правила, а не самые мягкие.

Отдельный класс — **сток**: 55 файлов движка GSC с нашими хуками. Правка такого файла считается правкой Ядра (раздел 3,
правило 8).

---

## 3. Правила Ядра (проверяются на глаз)

Коротко: **Ядро не знает, в каком режиме работает.** Что зависит от режима, оно получает ответом от слоя режима.

### Что в Ядро писать можно

1. Правила игры, одинаковые в обоих режимах: кто может подобрать, как считаются урон, смерть, деньги, задания,
   чекпоинты.
2. Вопросы слою режима через `mode()` (C++) или `coop_mode.*` (Lua) — **только про игрока, про карту или про своего
   актора**: «где этот игрок», «кто решает за этого персонажа», «мой актор — игрок?». Никогда «какой сейчас режим».
3. Роли, у которых один смысл в обоих режимах: `is_mirror()` («мои объекты — копии»), `is_player()` («в этом процессе
   играет человек»), фаза сессии.
4. Отправку через доставку режима (`mode().deliver`, `coop_mode.publish`).
5. Вызов чистых правил `xrCoop/*_rules.h` с фактами, полученными от интерфейса.

### Что в Ядро писать нельзя

| № | Нельзя | Пример, откуда правило |
|---|---|---|
| 1 | Проверки режима и функции, которые их возвращают. C++: `is_map_server`, `is_world_server`, `dedicated::`, `g_coop_dedicated`, `g_coop_headless`, `split()`, `story_together`, `ghost_actor`, `on_host_level`, `host_character_elsewhere`, `body_facts`, `led_by_host_process`, `is_bridge`, `mapserver::`, `leads_my_level`. Lua: `is_dedicated`, `levels.split`, `api.levels`, `actor_is_nobody`, `level_of_player`, `map_servers`. Обёртка, которая возвращает одно из этого, запрещена так же | обёртки прячут проверку: `coop_ai.cpp:576 ghost()`, `coop_health_ledger.cpp:31 on()`, `coop_levels.cpp:234 leads_my_level()`, `coop_scorcher.script:96 authority()`, 11 локальных `is_host()` (critique H3) |
| 2 | Спрашивать `mode()` / `coop_mode.*` о чём-то кроме игрока, карты или своего актора | — |
| 3 | Выбирать адресатов самому: пиры, мосты, LocalLink. Только доставка режима | `net::host_broadcast` сегодня сам знает про LocalLink и мосты (`coop_net.cpp:59-80`) |
| 4 | Новые строки с `is_host()`, `is_client()`, `is_map_authority()`. Старые только убывают | у кооп-хоста `is_world_server()` и `is_map_authority()` истинны (`coop_roles.h:32-35`), поэтому серверная правка под ними попадает в кооп: `41701d82` (`coop_items.cpp`) |
| 5 | Аргумент или поле по умолчанию, которое несёт факт режима или карты (в имени `level`, `split`, `host`, `here`, `plays`, `server`, `elsewhere`) | `coop_mirror.h:41` `flag_of_this_level = true` (R1, сборка 52, 10 вылетов кооп-клиентов); `coop_routes.h:789` `leads_level = false`. Оба убираются на шаге S1 |
| 6 | Состояние, которое заполняет только один режим. Steam | — |
| 7 | Ссылаться на файл, модуль или функцию слоя режима (`#include "srv/…"`, `coop_srv_x.fn`). Режимы не называют друг друга. Сток и Ядро доходят до кода `srv` только через `mode()` | хуки в стоке зовут серверные функции напрямую, и кооп спасает только ранний `return` внутри них (`xrGame/coop/srv/coop_levels_xfer.cpp:1116-1119,1156-1159,1256-1258,1293-1296,1363`; critique H5) |

### Что считается правкой Ядра (правило 8)

- правка любого файла без метки слоя;
- правка стокового файла движка (`88a20a9b` поменял `GetLuminocity` для серверов карт и тем самым кооп);
- правка таблиц маршрутов `coop_route*.ltx`, кроме замены `host` ↔ `level` (обе выполняются на кооп-хосте). R4 и R5
  сборки 53 были именно правками маршрутов;
- изменение протокола (одна версия на оба режима, `coop_protocol.h`, `package.ps1:117`);
- любая правка файла, у которого есть строки в `tools/layers_allow.txt` (иначе правка «под старой разрешённой строкой»
  проходит незаметно, critique H9);
- до конца шага S4: правка файла с функцией из `tools/srv_entry.txt` и правка 9 «серверных» скриптов, которые сегодня
  работают и в кооп-процессе (`coop_scorcher.script:417` ставит функции условий «в любом режиме», `coop_storyline.script:1472-1486`
  регистрирует `actor_on_update` в каждом процессе; critique H4).

### Правило 9: как принимается правка

- **Правка Ядра** — нативные и Lua-тесты под тремя наборами ответов (`hostplay`, `srv`, `none` — «вне сессии»), стенд
  Коопа (с отрядами и одиночной игрой) и стенд Сервера, оба на том же exe. Подробно — раздел 10.
- **Правка только `srv`** — стенд Сервера, а число кооп-тестов не меняется.
- **Правка только `hostplay`** — стенд Коопа.

### Правило 10: сохранённые имена не трогаем

Ключи записи мира (`c|…`), ключи pstor/marshal, имена событий на проводе не переименовываются и не удаляются. Список —
`tools/persisted_keys.txt`. Пример: `c|coop_world_server` — единственный признак серверного мира: из него карточка
получает `"world_server"` (`coop_json_card.script:27,81`), по нему лаунчер разрешает «Запустить сервер» (`list.rs:117`),
по нему сервер мира принимает свой сейв (`coop_srv_dedicated.script`, `load_allowed`).

### Где начинается новая фича

1. Для каждого режима записать: кто решает, какие данные у него есть, кто сообщает недостающее (`CLAUDE.md`, правило 1).
2. Код начинается **в слое того режима, которому он нужен**.
3. В Ядро он переезжает, только когда нужен обоим режимам и ведёт себя в них одинаково. Шаг, который переносит, проходит
   обе проверки (раздел 10).
4. Нужен новый ответ режима — он добавляется в интерфейс (раздел 4) с ответом для `hostplay`, `srv` и `none`.

Что останется общим и после разделения (critique §2): правило размещения зеркала `placement` (`coop_mirror.h:40-52`),
смерть и подъём (`coop_survival.cpp`), правила заданий (`coop_story.cpp`, `coop_tasks.script`), вход игрока
(`coop_join.cpp`). Их защищают не регулярные выражения, а стенды обоих режимов. **Проверка ловит простой способ
сломать кооп, стенды — остальное.**

---

## 4. Интерфейс: откуда Ядро берёт ответы

Один заголовок и один Lua-фасад, чтобы весь договор читался за минуту. Появляется на шаге S4 плана.

### C++: `engine/src/xrCoop/coop_mode.h` (чистый, тестируется без игры)

| Вопрос | Кооп отвечает | Сервер мира | Сервер карты | `none` (вне сессии) |
|---|---|---|---|---|
| `where(peer)`: Here / Away / Joining | Here для каждого сидящего | Away (Joining до посадки) | Here для игроков своей карты | Away |
| `decider_of(character)`: This / Other / Nobody | This | Other | This для своей карты | Nobody |
| `facts_of(character, out)` (в коде так: `body_facts` — имя L1) | читает объект здесь | факты, которые прислал сервер карты | читает объект здесь | false |
| `actor_is_player()` | true | false (призрак) | false | true (одиночная игра) |
| `decides_world()` | true | true | false | false |
| `leads_level()` | true | **false** (`fake_start`) | true | false |
| `deliver` / `stream` / `up` / `to_level_of` | рассылка сессии + LocalLink | по пирам с `passes_to` + мосты | фильтр `map_server_sends` | ничего |
| `install(tables)` | ставит **свои** таблицы обработчиков | свои | свои | ничего |
| `frame(dt)` | кадр кооп-режима | места, xfer | погода и выброс своей карты (свой шаг, не кооп-`host_weather_frame`) | ничего |
| `observer_distance`, `switch_vote` | сегодняшний код с «игрок на моей карте» | фильтр по картам и случаи призрака | то же | сток |

Правила интерфейса:

- `Mode& mode()` ставится один раз за сессию: `start_host` (Кооп), `start_client` по байту режима в Welcome (шаг S3),
  `-coop_dedicated` (сервер мира), `start_map_server` (сервер карты); сбрасывается в `set_phase(Off)`. До сессии — `none`.
- **Коммутатор (S4, `xrGame/coop/coop_mode.cpp`).** `mode_for(Entry, SessionMode)` спрашивает слои по очереди, первым
  серверный. Слой сам читает свои ключи (`-coop_dedicated`, `-coop_mapserver`) и режим из Welcome, кооп-слой берёт
  остальное. Строка со списком двух слоёв — единственное место, где Ядро называет `srv::` и `hostplay::`. Для неё в
  allow-списке одна запись L3. Тест `mode_switchboard_names_each_layer_once` не даёт добавить туда что-то ещё.
  `boot_layers()` в каждом кадре вызывает `boot_frame` слоёв: кадр сервера мира (`dedicated::frame()`) живёт в слое srv.
  Оба файла слоёв — gate-core в `tools/layers.txt`: их `mode_of` и `boot_frame` работают и в кооп-процессе.
- Хуки для A-S4H уже в интерфейсе: `online_elsewhere`, `binder_may_update`, `held_update`, `switched_offline`,
  `takes_own_ids`, `own_free_id`. У Коопа ответы пустые, серверные режимы передают их в `levels::*`.
- Ответы C++ `Mode` и Lua-таблицы `docs/contracts/coop_mode_api.md` §2 расходятся в трёх клетках (см. там). Перед S6
  сводятся к Lua-таблице.
- Каждый режим ставит **свои** таблицы обработчиков. Старт Коопа никогда не ставит серверные таблицы
  (сегодня `install_handlers` ставит одни и те же таблицы хосту, серверу мира и серверу карты, `coop_manager.cpp:468-498`).
- Хуки в стоке (`alife_switch_manager.cpp:115,128,131`, `alife_update_manager.cpp:113,475`, `GameObject.cpp:1115`,
  `xrServer.h:93,188`) зовут `mode()`. У Коопа ответы — пустые. Серверные функции после этого перестают проверять режим
  сами.
- Класс `Session` (`coop_session.h`) остаётся Ядром. Мосты, виртуальный хост и токен оператора уходят в серверное
  расширение (`SessionSrv`), LocalLink — в кооп-расширение (critique H10). S4 (A-S4S) сделал сам вид
  `srv::SessionSrv` (`xrCoop/srv/coop_session_srv.h`), через него ходит `xrGame/coop/srv/coop_mapserver.cpp`. Тела членов пока в
  `Session`: их ещё зовут напрямую `coop_trunk`, `coop_levels_xfer`, `coop_levels`, `coop_join`, `coop_manager`,
  `srv/coop_srv_mode` и тесты. Перенос тел — задание A-S4Sb.
- Карта сервера получила свой шаг неба `level_sky_frame` (`coop_worldstate.cpp`). Он в Ядре, но нужен только серверу
  карты, поэтому переезжает в srv на шаге S5 (A-S5W).
- `xrCoop/srv/coop_scope.h:216-268` (`scope_of`, `reaches_every_level`, `level_passes`) — серверная семантика, уходит в `srv`.
  `xrCoop/srv/coop_world_server_rules.h` — договор лаунчер ↔ сервер, тоже `srv`.

### Lua: `gamedata/scripts/coop_mode.script` (фасад, Ядро)

| Функция | Заменяет |
|---|---|
| `coop_mode.where(peer)` → `"here"` / `"away"` / `"joining"` | `on_host_level`, `level_of_player`, `split_levels()` в `coop_npc_companions.script:222-225` |
| `coop_mode.decider(peer)` → `"this"` / `"other"` / `"nobody"` | ветки «персонаж у меня / в другом месте» |
| `coop_mode.actor_is_player()` | три копии `actor_is_nobody` (`coop_quests_core:47-52`, `coop_npc_players:109`, `coop_mods_core:116-117`) |
| `coop_mode.decides_world()`, `coop_mode.leads_here()`, `coop_mode.is_player_mirror()` | `is_world_server()`, `is_host()` с двумя смыслами, два разных `is_client()` |
| `coop_mode.on_level_request(name, fn)`, `coop_mode.publish(verb, t)` | `coop_main.add_level_handler` (`:196-212`), `coop_mods_core.on/publish` (`:442-508`) |
| `coop_mode.seat_plays(peer)`, `coop_mode.group_travels()` | «у места 0 есть персонаж», «группа ходит вместе» |
| `coop_mode.when_srv(function() … end)` | единственное место, где серверный скрипт регистрирует колбэки, функции условий, события и сохранения |

- Звать как глобальный модуль `coop_mode.x(...)`, **без** новой `local`: в `coop_tasks.script` 188 из 200 локалей (после S5, A-S5T; было 197)
  файла, в `coop_npc_companions.script` 181.
- Предикаты режима переезжают из таблицы `coop.*` движка в отдельную таблицу `srv.*`. Одну dev-сборку они ещё читаются
  через `coop.*`, потом убираются. Ядро их не зовёт: любое обращение к таблице `srv` вне слоя Сервер — L1 в Ядре, L3 в
  Коопе, L5 в стоке (`tools/check_layers.py`, A-REV-E-1 п.1; critique §4.7).
- Кооп-ответы функций условий (`coop_scorcher.script:285-289`: `if not split() then return true`) переезжают в Ядро:
  это ответы стока. Серверный скрипт ставит свои версии только внутри `when_srv`.

### Ответы для S6 (A-S6-IF, сборка 57)

Новые ответы, которые просят группы S6, и их замороженные имена — `docs/contracts/coop_mode_api.md` §7: в C++ `Mode::level()` →
`LevelSide` (деньги, сообщение о предмете, палатки, метка смерти, пиры ствола, события сущностей; есть только у сервера карты,
остальные отвечают `nullptr`, и Ядро делает это в своих книгах) и члены `Mode` стороны мира (`reaches`, `deliver_links`,
`led_elsewhere`, `to_level_of`, `join_from_bridge`, `join_save`, `level_ready`, `on_world_live`, `load_text`, `ghost_said`); в Lua
`coop_mode.hook`, `facts_of`, `far`, `share_up`, `share_down`.

- `place_ghost(objects)` (H-JOIN) и `console_line(line)` (H-SAY) — хуки **слоя** (`Layer`), а не члены `Mode`: сервер мира грузит
  свой мир и держит консоль **до** своей сессии, когда C++ `mode()` ещё `none`. Ядро спрашивает их через коммутатор
  `coop::place_ghost(objects)` / `coop::console_line(line)` (`xrGame/coop/coop_mode.cpp`), серверный слой первым; у Коопа и
  `none` ответ «не моё».
- Тесты по видам процессов: `tests/test_mode_s6_answers.cpp`, `tests/lua/test_mode_s6_facade.lua`.

---

## 5. Автоматическая проверка

### `tools/check_layers.py`

Запуск: `python -I tools\check_layers.py` (или `tools\check_all.cmd`). Устроен как уже работающий
`tools/check_actor_compare.py`: список разрешённых строк `правило|путь|строка|счётчик` без номеров строк (строка — код без
комментариев, строки в кавычках сохранены), потолок только вниз, тесты в `tests/tools/test_layers.py` на деревьях-примерах
`tests/tools/fixtures/layers/` (запуск `python -m pytest tests\tools\test_layers.py -q`: pytest стоит в пользовательском
site-packages, ключ `-I` его прячет).

Входные файлы:

| Файл | Что в нём |
|---|---|
| `tools/layers.txt` | слой каждого файла, маски по порядку, последняя совпавшая побеждает. Файл, которого не назвала ни одна строка, — `core`. Строки `hostplay`, `srv`, `dying` (гибрид до S2; действует только для пяти файлов `DYING_FROZEN` в `check_layers.py`: строка `dying` на другой файл не работает), `stock engine/src/**` и `gate-core` (только для `check_gates.py`: 9 серверных скриптов до S4, H4). Строка `stock-list tools/stock_files.txt` обязательна, если есть `stock` |
| `tools/stock_files.txt` | файлы GSC как они пришли: коммит движка `ad9d8416` (2026-09-12, последний перед нашей работой), 4217 файлов C++ без «3rd party». Строка `stock` действует **только** на них: **новый наш файл где угодно в `engine/src` (например `xrGame/ui/…`) — `core`, а не сток**. Скрипт `gamedata/scripts/coop_*.script` без строки — тоже `core`; `coop_srv_*` / `coop_hostplay_*` — по приставке |
| `tools/layers_allow.txt` | сегодняшние нарушения. Первая строка `# ceiling: N`, N — сумма счётчиков. Шаг миграции удаляет строки и **в том же коммите** снижает N (`--write-allow` делает и то и другое) |
| `tools/srv_entry.txt` | серверные функции, которые зовут сток и Ядро (`online_at_server`, `logic_may_update`, `xfer_scheduled`, `xfer_on_switched_offline`, `leader_free_id`, `levels::frame`, `mapserver::host_incoming` — `coop_levels.cpp:505` на каждое входящее сообщение кооп-хоста, `mapserver_stats_frame` — `coop_manager.cpp:910` каждый кадр). Список — явная часть: проверка сама находит любую функцию, определённую только в файле `srv`/`hostplay`, которую зовёт Ядро или сток (L3, L5, `check_gates.py`) |
| `tools/persisted_keys.txt` | сохранённые ключи, которые не могут исчезнуть из скриптов |

Что читается: `engine/src` (без «3rd party»), `gamedata/scripts/*.script`, а как сток-Lua — `engine/gamedata/scripts/*.script`
и `gamedata_gamma/scripts/*.script` (правленые стоковые скрипты и слой GAMMA: `axr_main` выполняет уровень файла и
`on_game_start` каждого скрипта в каждом процессе). Для ворот (`core_reach`) ещё конфиги `gamedata/configs`,
`engine/gamedata/configs`, `gamedata_gamma/configs` (`*.ltx` без `;`-комментариев, `*.xml` без `<!-- -->`).

Правила:

| Правило | Где | Падает, когда |
|---|---|---|
| L1 имя режима | Ядро, C++ и Lua | строка кода (без комментариев и строк) называет запрещённое имя из раздела 3, правило 1 и консольные переменные режима (`g_coop_split_levels`, `g_coop_world_server`, `g_coop_story_together`, `g_coop_soft_host_move`, `g_coop_max_map_servers`, `g_coop_map_servers_rev`, `g_coop_mapserver_*`), `world_server_now(`, `game_split(`, `has_role(ProcessRole::WorldServer / MapAuthority / MapServer`, `using namespace …dedicated / …mapserver` и псевдоним `namespace d = coop::dedicated;`; строку `"-coop_mapserver"`, `"-coop_dedicated"`, `"-coop_host"`, `"-coop_operator"`, `"-coop_hidden"`, `"-coop_stage"` (проба командной строки); макрос, тело которого называет режим (в любом нашем файле, и в серверном заголовке); в Lua — и имена C++ из того же списка, **или функцию, которая его возвращает**: обёртка заражается по `return` и по короткому (до двух `;` / трёх строк) телу, по цепочке; `void`-функция не заражает (команда — не вопрос режима); C++ — по последнему квалификатору (`levels::leads_here(`, псевдонимы пространств `namespace lv = coop::levels` разворачиваются) и голым именем в своём файле, своих пространствах и подключённых `using namespace`; Lua — в пределах файла (локали, псевдонимы `local split = coop.levels.split`), как `скрипт.fn(` из других файлов, через псевдоним таблицы (`local L = coop.levels; L.split()`, `local l = api.levels`) и через поле в скобках (`coop.levels["split"]()`). Lua: любое обращение к таблице `srv` (`srv.x`, `srv["x"]`, `srv:x`, таблица как значение `local s = srv` / `f(srv)`, `_G.srv`, `_G["srv"]`, `rawget(_G, "srv")`) и `dedicated_new_world`: таблица есть в каждом Lua-состоянии, Ядро её не зовёт (не считается: поле `t.srv`, ключ `{ srv = … }`, присваивание `srv = x`, длинное имя `when_srv`; A-REV-E-1 п.1) |
| L2 обёртки ролей | Ядро | обёртка `is_host(` / `is_client(` / `is_map_authority(` (Lua `is_world_server(` / `is_host(`) заражается так же, её вызов — L2. Функция с именем самого предиката или роли не заражается (её вызовы находятся по имени) |
| L2 перегруженная роль | Ядро | новая строка с `is_host(`, `is_client(`, `is_map_authority(`, `has_role(ProcessRole::WorldClient` (Lua: `is_world_server(`, `is_host(`). `has_role(ProcessRole::Player)` — это `is_player()`, один смысл в обоих режимах, не нарушение |
| L3 ссылка через слой | Ядро и сток → `hostplay`/`srv`; `hostplay` ↔ `srv` | `#include` файла другого слоя (в Ядре и `#include` макроса: слой файла не проверить), Lua-имя `скрипт.fn` / `mod("…")` / `rawget(_G, "…")` / `_G["…"]` / `module_of` / `call_module` / псевдоним `local lv = coop_levels` скрипта другого слоя (по `layers.txt`, не только по префиксу; и из сток-Lua), вызов (или адрес, `&coop::levels::f`) функции из `srv_entry.txt` и **любой функции, определённой только в файлах другого слоя** (индекс определений: `q::f`, голое `f(` в своих и подключённых пространствах; функция, которую определяет и Ядро, не считается); **строка C++ с именем скрипта другого слоя** (`lua_getglobal(L, "coop_dedicated")`); **строка Lua, которая целиком — имя скрипта другого слоя** (таблица рассылки `{ "coop_economy_group", "coop_srv_far_prices" }`, по которой Ядро зовёт `rawget(_G, name)`; третье ревью, C6); **`extern` глобала, который определён только в `srv`/`hostplay`**; в файле `srv`/`hostplay` — **определение члена класса, который определяют только Ядро или сток**: функции (`bool coop::FarPolicy::keep_online(…)`: Ядро зовёт его через объект) и статического поля (`u32 FarLimits::squads_per_player = 4;`, C8). **Имя скрипта, собранное в Ядре во время работы** (`rawget(_G, "coop_" .. kind .. "_prices")`, `_G["coop_" .. x]`: ни одна строка не называет скрипт, который так достаётся; четвёртое ревью, X7). Функция, имя которой склеивает однострочный макрос `##` (`#define COOP_FAR_HOOK(name) bool coop_far_hook_##name(u16 id)` и `COOP_FAR_HOOK(skip) { … }` в файле `srv`), попадает в индекс определений раскрытой (X10b): вызов `coop_far_hook_skip(id)` из Ядра — L3. В файле `hostplay` — любое обращение к таблице `srv` слоя Сервер (те же формы, что в L1; A-REV-E-1 п.1). Фасад `coop_mode` разрешён |
| L4 умолчание режима | Ядро, все файлы C++ | параметр или поле (не `static` / `constexpr`) **типа `bool`** имеет `= значение`, и в его имени есть слово `level(s)`, `split`, `host(s)`, `here`, `plays`, `server(s)`, `elsewhere` или в комментарии строки — `split`, `map server`, `world server`, `dedicated`, `hybrid`. Умолчания других типов — данные (`uint16_t level = kNoLevel`). Поле в `.cpp` считается только с `= true`: `bool here = false;` строки данных своего файла — безопасное значение; в заголовках и у параметров — всегда |
| L5 хук в стоке | `stock` | новая строка, которая называет предикат режима (список L1, в том числе `g_coop_headless`, `g_coop_dedicated`), `coop_console::`, функцию из `srv_entry.txt`, функцию, определённую только в `srv`/`hostplay` (и в файле стока без байтов `coop`), или заражённую обёртку L1 и которой нет в разрешённых; в сток-Lua — предикат режима и любое обращение к таблице `srv` (A-REV-E-1 п.1). Хук в функцию Ядра (`coop::players::own_condition_held(this)`) — **не** L5: правка стока для `check_gates.py` и так правка Ядра |
| L6 надгробия гибрида | везде | упоминание удалённого: `coop_soft_move`, `softmove::`, `story_together` (и внутри `g_coop_story_together`), `coop_world_wait`, `coop_world_server.h`, `HostProcess`, `led_by_host_process` |
| L7 локали Lua | все скрипты | в файле больше 190 локалей (предел Lua — 200); каждая локаль сверх 190 — одна строка списка (`coop_tasks.script` сегодня 197) |
| L8 Steam | всё, кроме `hostplay` и `x_ray.cpp` | `Steam`, `RAYLINK_STEAM_`, `steam_invite`, `steam_join` |
| L9 регистрация в `srv`-скрипте | `srv`-скрипты | вне **анонимных функций**, переданных в `coop_mode.when_srv(...)` (остальное в скобках выполняется сразу: `when_srv(hide_far_spots())` зовёт функцию при загрузке — это само по себе L9, C2): `RegisterScriptCallback` (и через псевдоним `local reg = RegisterScriptCallback`), поле `xr_conditions` / `xr_effects` / `xr_logic` через `.X =`, `["X"] =`, `rawset(…)` или псевдоним таблицы, `add_event_handler`; **запись в любую не свою таблицу** — скрипта Ядра, `hostplay`, стока, в том числе не из репозитория (`sim_board`, `smart_terrain`), `db.флаг = true`, глобал через `_G`, `setmetatable(db.storage, …)` (C3); своими считаются локали, параметры, переменные `for`, `self`, свои классы (`class "x"`), глобалы уровня файла и сам скрипт, **кроме копии чужой таблицы**: локали (`local db = db`, `local t = sim_board.x or {}`: C1; `local cfg = rawget(_G, "coop_far_cfg")`, `local xc = rawget(_G, "xr_conditions") or xr_conditions`: четвёртое ревью, X3) и глобала уровня файла (`far_cfg = coop_far_cfg`, `far_db = db`, `x = rawget(…)`; `x = x or {}` и копия своей таблицы остаются своими: X4); **параметр функции, которая работает при загрузке, когда вызов при загрузке передаёт в него не свою таблицу** (`wrap(sim_board.simulation_board, "assign_squad_to_smart", f)`, а в `wrap` — `tbl[key] = …`: X2); **любой вызов при загрузке** — на уровне файла, в `on_game_start`, в функции, присвоенной ему (`on_game_start = start`), во всех функциях файла, которые они зовут по имени, по цепочке (C4), и **в теле литерала функции, который выполняется сразу**: вызванного на месте `(function() … end)()` (X5) или переданного в вызов, который сам его зовёт, — `string.gsub`, `s:gsub`, `table.sort`, `pcall`, `xpcall`, `table.foreach` (X6; литерал в `CreateTimeEvent` / `RegisterScriptCallback` / таблице выполнится позже, считается сам этот вызов): `CreateTimeEvent`, `AddUniqueCall`, `level.add_call`, `exec_console_cmd`, `get_console():execute`, сеттер Ядра; чистые чтения не считаются (`rawget`, `type`, `pairs`, `tostring`, `tonumber`, `string.*`, `math.*`, `printf`, `class`, `pcall` чистой функции, в том числе локали `local pf = rawget(_G, "printf")`, и `pcall(function() … end)`, тело которого проверяется само; `table.insert` и `setmetatable` в свою или новую таблицу) |
| L9C статическая инициализация | C++ `srv`/`hostplay` и `tests/test_srv_*.cpp` | переменная уровня пространства имён, чей инициализатор зовёт функцию (`static const bool registered = (coop::hooks::set_skip(&far_skip), true);`), или объект нашего класса с объявленным конструктором (`static Registrar s_registrar;`, `static Registrar s_r(1);`: C7; объект шаблона класса `static coop::hooks::AutoReg<FarSkip> s_reg;` — класс `AutoReg`, а не аргумент шаблона: четвёртое ревью, X8b): она выполняется в каждом процессе, и у кооп-хоста. Регистрироваться — из init режима через `mode()`. `constexpr` — не вызов. В `tests/test_srv_*.cpp` (их можно править вместе с правкой только `srv`) такой инициализатор выполняется до каждого кооп-теста того же нативного exe (`_putenv("COOP_FUZZ_RUNS=1")`: X11) |
| L10 сохранённый ключ | скрипты | ключ из `persisted_keys.txt` пропал из скриптов |
| L12 движок называет мод | C++ во всех слоях `engine/src` без «3rd party» | литерал содержит `coop_mods_`, токен кода или литерала называет мод из `tools/mod_names.txt` либо совпадает с долгом P106 в заданной области. Имена, данные и формулы мода живут в его Lua-адаптере. Линт проверяет имена, а формулы проверяются на ревью |
| L11 серверная часть `Session` (круг 8) | Ядро C++ | файл Ядра зовёт серверные члены `Session` напрямую (`issue_bridge`, `revoke_bridge`, `virtual_*`, `bridge_*`, `on_bridge_*`, `host_virtual`, сторона оператора) вместо `srv::SessionSrv`; сегодняшние вызовы — в замороженном списке `check_layers.py`, он только сокращается |
| L1, слова интерфейса режима (круг 8) | Ядро C++ и Lua | C++: `session_mode(`, `SessionMode::Coop/Server`, `ProcessRole::` (кроме `has_role(...)`), `.roles()`, `m_roles`, `roles_of(`, `mode_for(` / `install_mode(` / `boot_layers(` вне стартов `coop_manager.cpp`, сравнения `mode().name()`; исключения по функциям — `IFACE_ALLOWED`, список только сокращается. Lua: наличие серверной части `coop_quests_core.part(...)` как условие |

Пометки-исключения вида `layer-ok: причина` **нет**: это был бы простой обход проверки.

Что печатает (строка на нарушение, предупреждения о лишних строках списка, итог):

```
check_layers: OK (4607 files, ceiling 2335, used 2335)
```

```
engine/src/xrGame/coop/coop_net.cpp:109: [L1] if (is_map_server()) return; ('is_map_server') — Ядро never asks the mode; move the branch into hostplay/ or srv/ behind coop_mode (docs/MODES.md §3 rule 1)
check_layers: FAIL (1)
```

Коды выхода: 0 — чисто, 1 — нарушения, 2 — нет входного файла (и `stock` без `stock-list`). `--write-allow` переписывает
список (отсортированно: одно дерево — один файл) и ставит потолок = сумма; без `--reset-ceiling` он только снижает:
отказывается от **новой** строки и от выросшего счётчика, даже если сумма под потолком (иначе убранную разрешённую строку
можно было бы обменять на новую проверку режима), и от потолка выше прежнего. `--reset-ceiling` ставит только ведущая после
просмотра добавленных строк. `--top N` печатает N файлов Ядра с наибольшим числом строк L1+L2 и числа по правилам.

Потолок 2308 (2026-11-18, `--write-allow --reset-ceiling` на рабочем дереве): правила этого дня поменяли ключи списка —
L5 больше не считает хуки в функции Ядра (−557), L4 не считает умолчания не `bool` (−16), вызовы `void`-функций больше не
L1/L2, а новые предикаты и псевдонимы (L1 +134), индекс серверных функций (L3 +176), правка чужих таблиц и псевдонимы
регистрации (L9 +17) добавили строки. Прежний список 2570 к новым ключам не подходит: с ним проверка даёт FAIL (347), а
`--write-allow` без `--reset-ceiling` отказывает (324 новые или выросшие строки). 9 строк из 2308 — незакоммиченная работа
других исполнителей (`coop_story.cpp:1203`, `coop_quests_trust.script`, `coop_economy_mdata.script`,
`coop_npc_world.script`, `coop_tasks.script`): это новые проверки режима в Ядре; на HEAD без неё потолок 2301.

Потолок 2335 (2026-11-18, второе ревью, `--write-allow --reset-ceiling` на рабочем дереве; без `--reset-ceiling` отказ:
36 новых строк): +37 L9 — серверные скрипты сегодня делают при загрузке в каждом процессе то, что должно быть внутри
`when_srv` (`coop_scorcher.script:417` ставит функции условий, `coop_storyline.script:1474`, `coop_levels_tables.script:259`
… `share.up/down`, `coop_quests_far.script:1101` подписки `q.on`, записи `db.anomaly_by_name` / `db.actor_inside_zones`),
+1 L3 — `coop_join.cpp:1143 lua_getglobal(L, "coop_dedicated")`; −11 L4 — поля `bool … = false` в `.cpp`
(`BaseSeen::here` и подобные). По правилам: L1 817, L2 923, L3 240, L4 16, L5 131, L6 77, L7 7, L8 35, L9 89, L9C 0.
Статических инициализаторов с вызовом, `extern` серверных глобалов и членов классов Ядра в файлах `srv` сегодня нет.

Правила третьего ревью (2026-11-18, четвёртый круг: C1-C4, C6-C8) добавляют на дереве того дня 12 строк, которых нет в
списке (10 L9, 1 L9C, 1 L3): L9 в серверных скриптах `gate-core` (функции, которые зовутся при загрузке по цепочке: `coop_dedicated.script`
`new_world_settings()` пишет `config:w_value`, `step()` в `coop_scorcher` / `coop_storyline` зовёт `pcall(f)`, …), L9C
`xrGame/coop/srv/coop_host_console.cpp` (`OutputQueue g_queue` строится конструктором в каждом процессе), L3 `coop_quests_core.script`
(таблица имён модулей с `"coop_quests_far"`). Это правильные находки, а не ложные тревоги: список пересчитывает ведущая
(`python -I tools\check_layers.py --write-allow --reset-ceiling` после просмотра добавленных строк).

Правила четвёртого ревью (2026-11-19, пятый круг: X2-X11) на рабочем дереве того утра добавляют 19 строк L9 и убирают 2
ложные тревоги (`coop_dedicated.script:33` `pcall(pf, …)` при `local pf = rawget(_G, "printf")`, `:40`
`pcall(function() return _G[name] end)`). Новые строки — настоящие находки: регистрация условий и эффектов через
`local xc = rawget(_G, "xr_conditions") or xr_conditions` в `coop_scorcher.script` (10 строк `xc.` / `xe.`), правка
таблиц `drx_da_main` (GAMMA) в `coop_levels_tables.script` (8 строк) и запись в состояние `alife_storage_manager` в
`coop_storyline.script:167`. Их, как и прежние 25, вносит в список ведущая.

Где запускается: первой строкой в `tools\build_tests.cmd` и `tools\test_lua.cmd` (отказ останавливает прогон с кодом 254 и
своими строками; `COOP_SKIP_LAYERS=1` — аварийный обход ведущей, печатается громко, и `tools\run_all_tests.cmd` тогда не
пишет `tests.ok`), `tools\check_all.cmd`, `tools/release.py --channel dev --build <N> verify` (через
`check_gates.py --layers`: одна модель на обе проверки, ошибка блокирует черновик выпуска), `tests/tools/test_layers.py`.

### `tools/check_gates.py`

Запуск из `release.py verify`: `python -I tools\check_gates.py <прошлый тег>..HEAD --release --layers --exe <выпускаемый exe>`
в обоих репозиториях (тег движка указывает на публичный снимок — диапазон движка начинается с его «Source tree»); без
диапазона — рабочее дерево против HEAD. `--layers` сначала прогоняет `check_layers.py` на той же модели (одна сборка модели
вместо двух, около 7 с; код 3 — проверка слоёв не прошла). Переименование считается обоими путями (`git --no-renames`):
перенос файла Ядра под имя `coop_srv_*` — правка Ядра. Коммит слияния считается разницей со своим первым родителем
(`--diff-merges=first-parent`): правка, сделанная при слиянии, видна; коммиты боковой ветки проверяются каждый сам. Ни
один вызов git не пишет индекс (`GIT_OPTIONAL_LOCKS=0`).

**Правило выпуска (третье ревью, 2026-11-18).** Классификация файлов по слоям дырява (C1-C12 третьего ревью), поэтому
выпуск от неё не зависит: в режиме диапазона (`release.py`, `check_gates.py <диапазон>` без `--per-commit`) **любая правка
файла продукта** требует **обеих** меток стендов и метки тестов — `hostplay.ok`, `srv.ok`, `tests.ok`, — какой бы слой ни
был у файлов. С `--release` (выпуск везёт exe) три метки нужны всегда, и exe должен быть сборкой engine-ci из HEAD движка
(ниже). Слои файлов решают только раннее предупреждение: рабочее дерево и `--per-commit` (диапазон по коммитам, как
разработчик проверяет свои коммиты).

Для каждого коммита определяет слой по `layers.txt` (через `check_layers.py`); таблицы маршрутов читаются как данные: обе
версии разбираются в пары (секция, ключ) → значения, без `;`-комментариев; `srv` — только когда пары те же и значения
отличаются лишь `host` ↔ `level`; ключ, перенесённый в другую секцию, добавленный или убранный, — Ядро (C10). **Ядром**
для ворот считаются:

- списки и проверки, которые решают слой и ворота: `tools/layers.txt`, `layers_allow.txt`, `srv_entry.txt`,
  `persisted_keys.txt`, `stock_files.txt`, `check_layers.py`, `check_gates.py`, `release.py`, `stand_common.ps1`,
  `stand_hostplay.ps1`, `stand_srv.ps1` (одна строка `srv …` в `layers.txt` иначе превращала бы файл Ядра в серверный);
  прогонщики кооп-тестов `tools/test_lua.cmd`, `tools/build_tests.cmd`, `tools/run_all_tests.cmd`,
  `tests/lua/run_all.lua`; сценарии и пробы стендов — всё в `tools/stand/` и `tools/ded_check.ps1`;
- фасад `gamedata/scripts/coop_mode.script` и его слои `coop_srv_mode.script`, `coop_hostplay_mode.script`: они решают, в
  каком процессе выполняется код `when_srv` (C5);
- файл со строками в `layers_allow.txt`, сток, `dying`, `coop_protocol.h`, строки `gate-core`, файл, где определена
  функция из `srv_entry.txt`;
- файл `srv` или `hostplay`, до которого дотягивается Ядро, сток (и сток-Lua `engine/gamedata/scripts`,
  `gamedata_gamma/scripts`) или `dying` (`check_layers.core_reach`, по рабочему дереву): его включают (`#include`, по
  цепочке), в нём определена функция, которую зовут (`mapserver::host_incoming`, `mapserver_stats_frame`,
  `levels::logic_may_update` …; и перегрузка функции, которую определяет само Ядро, C9), его скрипт называют (Lua, в том
  числе строкой таблицы рассылки — C6; строка C++ `lua_getglobal(L, "coop_dedicated")`, конфиг
  `<precondition>coop_x.fn</precondition>`), в нём определён глобал, который Ядро объявляет `extern`, член (функция или
  статическое поле, C8) класса, который определяют только Ядро и сток, или класса, объявленного в уже достигнутом файле
  (`Book::may_run` из серверного `xrCoop/srv/coop_operator.h`, C11), или в нём статический инициализатор с вызовом или конструктором
  (работает в каждом процессе, C7). Дальше — **до неподвижной точки**: всё, что включает, зовёт или называет уже
  достигнутый файл (и файлы `gate-core` / `srv_entry.txt`), тоже достигнуто. На 2026-11-18 это 37 из 38 файлов
  `srv`/`hostplay` (последний, `coop_levels_tables.script`, — `gate-core`): **только-серверных файлов для ворот сегодня
  нет**. `xrCoop/srv/coop_levels_keeper.h` достигнут через `xrGame/coop/srv/coop_levels_xfer.cpp` (его `marked()` держит `online_at_server()`
  молчащим у кооп-хоста, а её зовёт сток), `coop_xfer*.h` — через него же. Так и должно быть до S4: этот код сегодня
  работает и в кооп-процессе.

Продукт для ворот: `gamedata/`, `gamedata_gamma/`, `engine/src/`, `engine/gamedata/` (правка `engine/README.md` или CI
движка стенда не требует). Все вызовы git идут с `core.quotePath=false`; путь в кавычках — ошибка ворот (код 2), а не
«вне продукта».

Метки — в `temp\gates\`: `hostplay.ok` и `srv.ok` (их пишут `tools\stand_hostplay.ps1` / `stand_srv.ps1`) и `tests.ok`
(её пишет `tools\run_all_tests.cmd`: N и L прошли, дерево чистое до и после прогона, HEAD не сдвинулись; ключи `mode=tests`,
оба HEAD, `dirty=0`, `native=0`, `lua=0`). Стенд гоняет **HEAD**: прогонщик сначала выкладывает на стенд gamedata из
`git archive HEAD` обоих репозиториев (`tools\stand\stand_head.py`: слой Engine, сверху Core, сверху GAMMA; файл Engine,
который на стенде перекрывает мод по `.raylink-stand.json`, не трогается; `axr_options.ltx` не трогается; заменённое — в
`temp\stand\head_backup`) и отказывается стартовать, пока в рабочем дереве есть изменения продукта или сценарий
отличается от HEAD; после сценариев сверяет, что на стенде всё ещё gamedata HEAD и ничего не сдвинулось. Сценарии и пробы
лежат в отслеживаемой `tools\stand\` (`temp\stand` — только история прогонов).

Целость метки стенда (третье ревью, S1-S3, C12):

- **Остатки (S1).** Файл наших слоёв, которого нет в HEAD, иначе остаётся на стенде, а `axr_main` выполняет каждый
  скрипт. Выкладка переносит в `head_backup\removed` каждый файл gamedata стенда, которого нет в HEAD и который манифест
  отдаёт нашему слою, или `coop_*.script`, которого манифест не знает, или который добавила прошлая выкладка
  (`new_files.txt`); проба `coop_zz_*` из `tools\stand` HEAD остаётся. Проверка после сценариев ничего не удаляет: называет
  такой файл и падает. `coop_*.script`, который везёт мод GAMMA (манифест называет мод: сегодня это
  `coop_compat_alq.script` мода «Alife CENSORED» — у игроков он тоже есть), остаётся, называется в `stand_foreign=`, а его
  байты входят в `stand_fingerprint`.
- **Профили (S2).** Режим процесса стенда решают и переменные профиля (`user.ltx`: `coop_max_map_servers`,
  `coop_map_servers_rev`, `coop_mapserver_*`), которые каждый прошлый запуск записал обратно. Перед выкладкой и **перед
  каждым сценарием** `stand_head.py profile` убирает эти строки из `user.ltx` каждой папки, которую называет
  `tools\stand\stand_profile.ltx` (`appdata_t`, `appdata_server`, `appdata_ms1`, `appdata_ms2`; профили хоста и одиночной
  игры сценарии копируют из `appdata_t`), и пишет строки шаблона. Четыре переменные шаг S2 убрал из движка
  (`coop_split_levels`, `coop_world_server`, `coop_story_together`, `coop_soft_host_move`): их строки `profile` тоже
  убирает из `user.ltx`, а строку шаблона с ними отклоняет (шестой круг).
- **Папка и exe (S3, C12).** Метка называет exe стенда; считается только exe по пути самого стенда (`--stand`, по
  умолчанию `E:\RayLinkGames\GAMMA\game-dev`) и только при том же `stand_fingerprint` (SHA-256 манифеста
  `.raylink-stand.json` и `coop_*.script` стенда, кроме проб). `exe_source=` — HEAD движка, из которого exe собран
  (`check_gates.exe_source`): exe побайтно равен сборке engine-ci (`engine-ci\_build\_game\bin_dbg\AnomalyDX11AVX.exe`),
  в `engine/src` нет незакоммиченных файлов, каждый файл `src/` HEAD движка лежит в engine-ci с содержимым HEAD
  (`raylink_build.h` — с точностью до номера сборки; `xrGame.vcxproj(.filters)`, которые правит `ci_sync.py`, не
  сравниваются), в engine-ci нет исходников, которых нет в HEAD, и ни один исходник engine-ci не менялся после записи exe.
  Штампу ничего не доверяется: дерево CI сравнивается с HEAD (индекс git рабочей копии engine-ci называет неизменённое,
  читаются только изменённые файлы, около 1-3 с). Сегодня (2026-11-18) engine-ci отличается от HEAD движка в 12 файлах
  Ядра и одного не имеет: метка такого exe не считается, пока ведущая не сделает `python tools\ci_sync.py --committed` и
  сборку. `tools\check_gates.py` и `tools\check_layers.py`, которые импортирует прогонщик, входят в проверку «грязного»
  дерева и в `scenarios_sha256`.

Жёсткие ссылки (ТЗ Р21, пятый круг защиты слоёв; слова владельца «ты не забывай что у нас работают здесь жесткие
ссылки»): лаунчер собирает стенд `E:\RayLinkGames\GAMMA\game-dev` из жёстких ссылок на `E:\RayLinkGames\GAMMA\mo2\mods`
(около 60,7 тыс. из 61,8 тыс. файлов). Запись в такой файл на месте меняет файл мода у всех, кто на него ссылается, а
снятие атрибута «только для чтения» меняет атрибут мода. Поэтому ни один наш инструмент не пишет в существующий файл
стенда:

- **Python** (`tools\stand\stand_head.py` deploy / profile / остатки / возврат, `tools\stand_overlay.py`) — через
  `tools\mo2_stand.py` `replace_file`: байты в новый файл рядом, старое имя удаляется
  (`FILE_DISPOSITION_FLAG_IGNORE_READONLY_ATTRIBUTE`: атрибут других ссылок не трогается), новый файл получает имя;
  `remove_file` — то же удаление одного имени. `keep_copy` пишет только в резервную папку.
- **PowerShell** (`tools\stand_common.ps1`: `Write-StandBytes`, `Write-StandText`, `Write-StandLines`, `Copy-StandFile`,
  `Copy-StandTree` вместо robocopy, `Remove-StandFile` вместо любого `Remove-Item`) — во всех сценариях `tools\stand\*.ps1`
  (пробы `coop_zz_*` в `gamedata\scripts`, `axr_options.ltx` и его возврат из копии, `fsgame_*.ltx`, `user.ltx`,
  `appdata_*`, `bin_b`), в `tools\deploy.ps1`, `tools\launch.ps1` и `tools\stand_server.ps1` (`fsgame_server.ltx`,
  `appdata_server`; пятое ревью, B1). Тест `test_stand_scripts_write_into_the_stand_only_through_the_helpers`
  (седьмой круг) проверяет **каждый** `tools\**\*.ps1` и `*.psm1`, найденный в момент прогона теста, а не при сборе
  pytest: новый сценарий (`phantoms_server.ps1`, `companions_group.ps1`) проверяется, никто его никуда не вписывает.
  Сегодня 20 файлов. Вне проверки только `NOT_A_GAME_ROOT_WRITER` с причиной (`package.ps1`: пишет только в
  репозиторий; `stand_common.ps1`: сами помощники, их проверяют тесты поведения); туда нельзя файл из `tools\stand` и
  файл, который принимает или называет корень игры (`$Stand`, `$Game`, `$GameDir`, `$TestRoot`, `$GameRoot`,
  `RayLinkGames`, `game-dev`). Правило записи: в стенд пишут только помощники. Любая другая запись — `Copy-Item`,
  `Set-/Add-/Clear-Content`, `Out-File`, `Tee-Object`, `Export-*`, `Remove-Item -Force`, `Move-/Rename-Item` (и их
  псевдонимы `copy`, `cp`, `sc`, `del`, `move`…), `[IO.File]::WriteAll*/AppendAll*/AppendText/Create*/Open*/Copy/Move/
  Replace`, `StreamWriter`/`FileStream`, `.Write()`, `.CopyTo()`, `-OutFile`, `-RedirectStandardOutput/-Error`, `>` и
  `>>`; robocopy, xcopy и `cmd /c copy` — никогда — допустима, только если то, что она пишет, удаляет или переносит,
  лежит в репозитории. **Копия ИЗ стенда в репозиторий разрешена:** источник копии может быть файлом стенда (копия его
  только читает), назначение — путь репозитория. «Путь репозитория» — переменная, у которой **каждое** присваивание в
  файле (у параметра — значение по умолчанию) — `Join-Path` от `$PSScriptRoot`, от папок репозитория из
  `stand_common.ps1` (`$script:Root`, `$script:StandDir`, `$script:MarkDir`, `$script:ScenarioDir` — только в файле,
  который подключает настоящий `tools\stand_common.ps1` и сам их не присваивает) или от другой такой переменной и не
  выходит за корень репозитория; либо `Join-Path` от неё (переменные в имени — одно имя: проверка судит код, а не то,
  что передаст вызывающий); либо такой путь с суффиксом (`$outPath + '.err'`). Запись в стандартный ввод процесса
  (`StreamWriter` на `.StandardInput`, `$in.WriteLine`) разрешена. Комментарии, `<# #>`, строки и here-строки не
  считаются командами; строка с `` ` `` или `|` в конце склеивается со следующей; несколько команд в строке проверяются
  все. Правило проверяют 31 случай «поймать» и 17 «пропустить» (`LINT_BAD`, `LINT_GOOD`): старая проверка шестого
  круга пропускала 18 из 25 (имя `$fixture`, назначенное от стенда, `>`, `Tee-Object`, `StreamWriter`, `CreateText`,
  `cmd /c copy`, xcopy…). Не судится: `Remove-Item` без `-Force` (удаляет одно имя, на ссылке «только для чтения»
  падает; через junction выше удалил бы файл мода — такие строки есть в сценариях других исполнителей, их список — в
  отчёте седьмого круга).
  Python-инструменты, которые пишут в корень игры (`--stand`, `--game`, `game-dev`, `import mo2_stand`: `stand_head.py`,
  `stand_overlay.py`, `mo2_stand.py`, `check_gates.py`), проверяет `test_python_stand_tools_never_write_in_place`:
  `write_bytes`/`write_text`, `open(…, "w"/"a"/"+")`, `shutil.copy*`, `os.chmod` допустимы только в строках списка
  `PY_WRITES_ALLOWED` (резервная папка, свой новый файл, метка в `temp\gates`). `tools\deploy.ps1` отказывается строить
  стенд поверх папки с `.raylink-stand.json`.
- **Связи папок (пятое ревью, S14).** Папка стенда, которая — junction или symlink в папку мода: запись через неё удалила
  бы файл мода и положила наш в папку мода. `stand_head.py deploy` до первой записи отказывает, `check` падает, `links`
  считает её в `blocked=`; `stand_overlay.py` отказывает до записи; `Set-StandFile`, `Remove-StandFile` и `Copy-StandTree`
  бросают ошибку. Лаунчер таких папок не делает (на 2026-11-19 на стенде их 0). **Седьмой круг (шестое ревью, B1):**
  помощники проверяли только папку самой цели, а `gamedata` стенда — junction в `gamedata` мода — пропускал запись
  `axr_options.ltx` в мод и удаление его `coop_zz_base.script`. Теперь `Assert-NoJunction` (PowerShell) и
  `mo2_stand.link_on_path` (Python: `replace_file`, `remove_file`, `remember_on_stand`, `materialize` для `--out`)
  проверяют **каждую** папку пути от корня тома до папки цели: корень игры, папки выше него и все ниже. Корня игры
  помощники не знают, поэтому проверяется весь путь (на 2026-11-19 `E:\`, `E:\RayLinkGames`, `GAMMA`, `game-dev`,
  `D:\Projects\…\anomaly-coop\temp` и `%TEMP%` — настоящие папки). `Remove-StandFile` отказывает и для отсутствующего
  файла под junction; `Copy-StandTree` проверяет `-To` до того, как `-Mirror` что-то удалит. Цена: `Copy-StandTree` 500
  файлов — 2,6 с вместо 1,9 с (замер 2026-11-19).
- **Проверка до записи.** `stand_head.py deploy` до первой записи проверяет, что каждое имя, которое он удалит, удалить
  можно (открытие с `DELETE`: имя держит запущенная со стенда игра — отказ, ничего не записано), и печатает
  `replaced_links=` — сколько заменённых файлов были ссылками. `stand_head.py links --stand <стенд>` — тот же план без
  записи: `would_replace=`, `would_replace_links=`, `would_add=`, `would_restore=`, `would_remove=`, `head_files_linked=`,
  `blocked=` (код 1, если имя удалить нельзя). NTFS проверяет совместный доступ по имени: открытый через папку мода файл
  не мешает удалить имя на стенде (проверено 2026-11-19).

Четвёртое ревью (B1-B5):

- **Старый вывод (B1).** `Invoke-Scenario` до запуска удаляет `<тег>_stand_<имя>.out` и `.err` прошлого прогона; не
  удалось (его держит осиротевший сценарий) — сценарий FAIL без прогона. После прогона FAIL, если `run_guarded.ps1`
  вернул не 0, не написал `run finished`, написал `GUARD:` или код выхода сценария (`scenario exit code: N`) не 0.
  Пустой `-ScriptArgs` не передаётся (пустой аргумент терялся по пути, и охранник не стартовал).
- **Файлы HEAD, которых не знает манифест (B2).** Выкладка вносит в `new_files.txt` каждый файл HEAD на стенде, которого
  манифест не называет, даже если его байты уже там (их положил `stand_overlay.py`: DXML-хуки `modxml_coop_*`, DLTX
  `mod_*_coop_*`, `game_schema.json`); выкладка после того, как HEAD их уронит, их уберёт.
- **Перекрытия модов (B3).** Файл, который выкладка заменила поверх файла мода (или поверх файла, который был на стенде
  до первой выкладки), записан в `head_backup\replaced_files.txt`. Когда HEAD его больше не перекрывает, выкладка
  возвращает файл мода (байты файла, который называет манифест, иначе первая копия в резервной папке), а `check`
  падает, пока на стенде наша брошенная правка.
- **exe (B4).** `exe_source` до доверия индексу git проверяет время каждого файла `src/` и `sdk/` HEAD движка в
  engine-ci (сборка из незакоммиченной правки, после которой `git checkout` вернул файл, ловится по времени: E2);
  сравнивает `sdk/` (E4) и `xrGame.vcxproj`: текст HEAD и engine-ci без однострочных элементов `coop\…`, которые пишет
  `vcxproj_add.py`, должен совпасть, и набор компилируемых `coop\*.cpp` тоже (`ClInclude` только перечисляет
  заголовок; E3).
- **Старый Lua-прогонщик (B5).** `check_gates.py --tests-mark write` не пишет `tests.ok`, если `temp\lua\runlua.exe` не
  содержит штампа исходников сейчас (`tools\test_lua.cmd`, когда не может пересобрать прогонщик, гоняет старый и
  возвращает 0). Штамп считается как в `test_lua.cmd`: первые 8 hex SHA-1 `runlua.c`, `native_coop.cpp`, заголовков
  `engine\src\xrCoop`, которые он включает, и `test_lua.cmd`.

Пятое ревью (B1-B4, шестой круг, 2026-11-19):

- **Пропущенный писатель (B1).** `tools\stand_server.ps1` писал `fsgame_server.ltx` через `[IO.File]::WriteAllText` и
  гнал robocopy `appdata` → `appdata_server` прямо в файлы стенда (на поддельном стенде изменил 2 файла мода по жёстким
  ссылкам). Теперь — `Write-StandText`, `Write-StandLines`, `Copy-StandTree`; тест запускает его на стенде из настоящих
  жёстких ссылок, а проверка «запись только через помощники» находит писателей сама (выше).
- **Публикация без ворот (B2).** `tools\publish_dev.sh` и `publish_dev_engine.sh` выкладывали `dev-<N>.<M>` без меток, без
  чистого дерева и без HEAD. Теперь они ничего не публикуют: отказ (код 2) и команды `release.py`. Тест
  `test_only_release_py_publishes` не пускает команду публикации (`gh release create/edit/upload/delete`, `gh api -X
  POST…`, `git push`) ни в один файл `tools/`, кроме `release.py`. Исключение одно и временное: `tools/publish_github.sh`
  (не файл защиты слоёв: выкладывает `b<N>` и двигает `main` без ворот) — ведущая убирает его или делает отказом, после
  чего строка уходит из `NOT_YET_GATED` (тест падает, пока строка лишняя).
- **Неотслеживаемые файлы оверлея (B3).** `stand_overlay.py` копирует рабочее дерево вместе с неотслеживаемыми файлами.
  На стенде лаунчера (`.raylink-stand.json`) `stand_head.py` считает остатком **каждый** файл под `gamedata`, которого
  манифест не называет и нет в HEAD, кто бы его ни положил: выкладка уносит его в `head_backup\removed`, `check` падает,
  пока он есть. Не трогаются: `gamedata/configs/localization.ltx` (его пишет игра), имена, которые игра не читает
  (`*.bak`, `*.tmp`, `*.log`, `*.orig`, `axr_options.ltx`, `cache_dbg.ltx`), пробы `coop_zz_*` из HEAD.
- **Память выкладки (B4).** Списки «что добавили мы» и «какой файл мода мы перекрыли» живут теперь в самом стенде —
  `<стенд>\.raylink-head-deploy.json` (свой новый файл, не ссылка; пишется до первой записи); их пишут и `stand_head.py`, и
  `stand_overlay.py`. `temp\stand\head_backup\new_files.txt` и `replaced_files.txt` остаются историей этого рабочего
  дерева и тоже читаются. Без всякой памяти (её удалили) решают манифест и история репозиториев: файл мода, который
  лаунчер положил ссылкой (`copy=false`), чья запись в папке разошлась с размером и временем манифеста, имя уже не
  ссылка и байты не мода, — возвращается из мода; файл, который лаунчер скопировал (`copy=true`), возвращается, если его
  байты — блоб наших репозиториев (`git cat-file`): копии, которые переписывает сама игра, не блоб наших и остаются.
  Цена: один обход `gamedata` стенда по записям папок (файлы не открываются) и `os.stat` только для разошедшихся.
  Не закрыто: перекрытие копии мода (`copy=true`) **неотслеживаемым** файлом оверлея, если удалили и память стенда, —
  таких байтов нет ни в одном блобе.

Шестое ревью (B1 и остатки, седьмой круг, 2026-11-19):

- **Junction выше папки цели (B1).** Помощники PowerShell и Python проверяют весь путь от корня тома (выше,
  «Связи папок»); тест `test_powershell_stand_helpers_refuse_a_junction_anywhere_above_the_target` — 12 записей через
  `gamedata`-junction и через стенд, который сам junction: все отказаны, файлы и атрибуты модов те же;
  `test_replace_and_remove_refuse_a_junction_anywhere_above_the_target` — то же для `mo2_stand.py`.
- **Stable без ворот.** `tools/publish_github.sh` сначала гонит `python -I tools/release.py --channel stable --build <N>
  verify` и при отказе выходит с кодом 2, не выполнив ни одной сетевой команды; сам выпуск — `release.py draft` и
  `publish` (своего `gh release create` и пуша `main` у скрипта больше нет). Подробно — раздел 10.
- **Проверка записи в стенд** находит файлы сама в момент прогона и судит по правилу «только помощники, копия ИЗ
  стенда — в репозиторий» (выше, PowerShell); слепые места шестого ревью (`>`, `>>`, `Tee-Object`, `StreamWriter`,
  `[IO.File]::Create/CreateText/AppendText`, `cmd /c copy`, xcopy) закрыты.
- **Остаток (a): exe читался дважды.** `release.py verify` копирует exe в `temp/<тег>/` до ворот; ворота, метка, хеш,
  сверка с пакетом и загрузка `draft` — по одной копии; копия, изменившаяся за время `verify`, — отказ.
- **Остаток (e): формы публикации.** `test_only_release_py_publishes` видит и список Python/JS (`["gh", "release",
  "create", …]`), `gh api` с полем (`-f`/`-F`/`--input`: неявный POST), отправку `curl`/`wget`/`Invoke-RestMethod`/
  `Invoke-WebRequest` и команду, разбитую на строки (`\`, `` ` ``, `^`).

Метка стенда считается, только если в ней `mode=` своего стенда, `dirty=0`, в `scenarios=` все сценарии своего стенда
(`check_gates.SCENARIOS`, тест сверяет их со списками в `stand_*.ps1`), совпали оба HEAD и SHA-256 exe, `exe=` — exe
самого стенда, `exe_source=` равен HEAD движка, `stand_extra=0`, `stand_fingerprint` равен нынешнему отпечатку стенда, а
`scenarios_sha256` (файлы сценариев, что отработали), `gamedata_sha256` (выложенная gamedata) и `profile_sha256` (шаблон
профилей) совпали с пересчётом из блобов HEAD; незакоммиченные файлы продукта метка не покрывает. Коммит, который трогает
и `hostplay`, и `srv` без Ядра, отклоняется («раздели коммит»; слияние — нет). В раннем предупреждении правка только `srv`
ещё требует неизменного **набора** кооп-тестов (имена `TEST(…)` в `tests/*.cpp` и файлы `tests/lua/test_*.lua`, кроме
`test_srv_*`) и **ни одной правки** в `tests/` и прогонщиках кроме файлов `test_srv_*` (тела тестов и вспомогательные
файлы тоже).

```
gates: dev-42.1..HEAD (mod fb8aa080, engine 99f74ddc), 172 commit(s)
gates: core 482 file(s), srv 0, hostplay 0, outside the product 299
gates: release rule: a product file changed in the range: both stand marks and tests.ok, whatever the files' layers (docs/MODES.md section 10)
gates: required: hostplay.ok, srv.ok, tests.ok
gates: hostplay.ok missing (run tools\stand_hostplay.ps1)
gates: srv.ok does not count: the stand ran a dirty tree (dirty=3): its exe may hold uncommitted code
gates: tests.ok missing (run tools\run_all_tests.cmd: N and L on the committed tree)
gates: FAIL (3)
```

### Как это не даёт «чинили сервер — сломали кооп»

| Как ломалось | Что теперь остановит |
|---|---|
| Серверная ветка `is_map_server()` / `is_map_authority()` посреди общей функции | L1 / L2: новая строка в Ядре не проходит |
| Серверная проверка, спрятанная в обёртку (`authority()`, `ghost()`) | L1 с заражением |
| Аргумент по умолчанию, который в коопе значит не то (R1) | L4 — гигиена; **поймает** R1 кооп-стенд `squads_group` и нативный тест `placement` под набором `hostplay` |
| Серверный скрипт, который заодно меняет кооп-условия и кадры | L9 + правило «до S4 эти файлы — Ядро» |
| Хук в стоке, который зовёт серверную функцию в кооп-процессе | L5 + `srv_entry.txt` + индекс серверных функций + вызов через `mode()` |
| Правка серверного заголовка, который включает Ядро, или серверной функции, которую зовёт Ядро (`host_incoming`, `mapserver_stats_frame`) | `check_gates.py` считает такой файл Ядром: оба стенда |
| Переименование файла Ядра в `coop_srv_*`, правка при слиянии, строка `srv …` в `layers.txt` | `check_gates.py`: старый путь считается, слияние — разницей с первым родителем, списки и проверки — Ядро |
| Правка серверного заголовка, который включает только достигнутый серверный `.cpp` (`Keeper::marked()` под `online_at_server`), члена класса Ядра в серверном файле, серверного глобала под `extern`, статической регистрации, серверного скрипта, который Ядро зовёт из C++ строкой, конфиг — из диалога, `axr_main` — из сток-Lua | `core_reach` до неподвижной точки и новые источники: оба стенда; в Ядре — L3, в серверном файле — L3 / L9C |
| Серверный скрипт при загрузке патчит не свою таблицу (`sim_board`, `db.флаг`) или зовёт таймер, консоль, сеттер Ядра | L9 |
| Серверная правка ослабляет тело кооп-теста или прогонщик Lua | ворота: правка `tests/` кроме `test_srv_*` в серверной правке — отказ; прогонщики — Ядро |
| Метка стенда, который гонял старые сценарии или старую gamedata | сценарии в `tools/stand` (Ядро), стенд сам выкладывает HEAD; `scenarios_sha256` и `gamedata_sha256` сверяются с HEAD |
| Правка стока, маршрута, протокола без единой проверки режима (`88a20a9b`, R4, R5) | правило 8 → `check_gates.py` требует оба стенда |
| Поломка вне сессии (R2, R3) | набор ответов `none` в тестах и одиночная игра в кооп-стенде |
| Скрытые условия по данным (`who:id() ~= db.actor:id()`, `link.plays`) | статическая проверка их не видит. Только оба стенда |
| Любая дыра классификации (третье ревью, C1-C11: `local db = db`, `when_srv(f())`, `setmetatable`, `on_game_start = start`, слой `srv` фасада, строка в таблице рассылки, статический объект, статическое поле, перегрузка, ключ маршрута в другой секции, член класса из серверного заголовка) | **правило выпуска**: в диапазоне любая правка продукта — обе метки стендов и `tests.ok`; классификация остаётся ранним предупреждением, и C1-C11 закрыты в ней правилами L3 / L9 / L9C и `core_reach` |
| exe, собранный не из HEAD движка (engine-ci отстаёт, рабочее дерево, `git stash`) — C12 | `exe_source`: exe — сборка engine-ci, engine-ci совпадает с HEAD движка и не менялся после сборки; без этого метка не считается и `release.py` отказывает |
| Метка стенда, на котором остались старые скрипты, профиль с чужими переменными режима, или метка другой папки (S1-S3) | выкладка убирает остатки наших слоёв, проверка их называет; переменные режима пишутся из `tools\stand\stand_profile.ltx` перед каждым сценарием; метка считается только с exe и отпечатком своего стенда |
| N и L не прогонялись или прогонялись на незакоммиченном дереве | `tests.ok` от `tools\run_all_tests.cmd` (оба HEAD, `dirty=0`) — для выпуска; `check_layers` первой строкой N и L |
| Выкладка или сценарий пишет в файл стенда, который — жёсткая ссылка на файл мода MO2 (Р21) | `replace_file` / `Write-Stand*` / `Copy-Stand*` / `Remove-StandFile`: старое имя удаляется, новый файл получает имя; проверка до записи и `replaced_links=`; тест не пускает запись на месте в сценарии |
| Сценарий упал, а судят старый `.out` того же тега (четвёртое ревью, B1) | старый вывод удаляется до прогона; код `run_guarded.ps1` и код выхода сценария проверяются |
| HEAD уронил файл, которого не знает манифест, или наше перекрытие файла мода (B2, B3) | `new_files.txt` пополняется файлами HEAD без строки манифеста; `replaced_files.txt` и возврат файла мода; `check` падает |
| exe собран из правки, которую `git checkout` вернул в engine-ci; правка `sdk/` или `xrGame.vcxproj` engine-ci (B4) | время каждого файла до доверия индексу; сравнение `sdk/` и `xrGame.vcxproj` без строк `vcxproj_add` |
| `tests.ok` от старого `runlua.exe` (B5) | `--tests-mark write` ищет в прогонщике штамп исходников сейчас |
| Инструмент, которого нет в списке, пишет в файл стенда на месте (пятое ревью, B1: `stand_server.ps1`) | тест сам находит каждый `.ps1` / `.py`, который берёт корень игры; новый `.ps1` без классификации не проходит |
| Dev-сборка выложена скриптом мимо `release.py` (пятое ревью, B2) | `publish_dev*.sh` отказывают; тест не пускает команды публикации в `tools/` кроме `release.py` |
| Неотслеживаемый файл оверлея (DLTX, DXML) остался на стенде, а метка его не видит (пятое ревью, B3) | на стенде лаунчера остаток — любой файл `gamedata`, которого нет ни в манифесте, ни в HEAD |
| Память выкладки потеряна (`temp\stand` почищен, другое рабочее дерево) — уроненный HEAD хук и перекрытие мода остались (пятое ревью, B4) | память в самом стенде; без неё — манифест (ссылка заменена) и блобы наших репозиториев |
| Запись через папку-junction в папку мода (пятое ревью, S14), в том числе через junction выше папки цели (шестое ревью, B1) | `stand_head`, `stand_overlay` отказывают до записи; помощники PowerShell и `mo2_stand.replace_file` / `remove_file` проверяют каждую папку пути от корня тома |
| Stable выложен `publish_github.sh` без ворот (шестое ревью) | скрипт сначала гонит `release.py --channel stable verify`, выпуск — `release.py draft` / `publish` |
| Новый сценарий пишет в стенд мимо помощников (`>`, `Tee-Object`, `StreamWriter`, копия в переменную, названную как папка репозитория) | проверка находит каждый `.ps1` при прогоне; запись разрешена только в путь, который по присваиваниям ведёт в репозиторий |

---

## 6. Имена

| Что | Ядро | Кооп | Сервер | Правило |
|---|---|---|---|---|
| Файлы движка | `xrGame/coop/`, `xrCoop/`, имена как есть | `xrGame/coop/hostplay/`, `xrCoop/hostplay/` | `xrGame/coop/srv/`, `xrCoop/srv/` (`srv/coop_mapserver.cpp`, `srv/coop_dedicated.cpp`) | слой = **папка**. Перенос — `git mv` и пути `#include`, без правки кода |
| Пространства имён | `coop::` | `coop::hostplay::` | `coop::srv::`; старые `coop::levels`, `coop::mapserver`, `coop::dedicated` остаются | переименовывать старое не нужно |
| Скрипты | `coop_<область>.script` | `coop_hostplay_<область>.script` | `coop_srv_<область>.script` | метка — всегда **второе** слово, поэтому `coop_core_*` и `coop_quests_party` меткой не читаются. Правило маршрута `coop_* = view` (`coop_route.ltx:66`) работает без изменений: самый длинный префикс |
| 9 серверных скриптов | | | `coop_dedicated` → `coop_srv_dedicated`, так же `levels`, `levels_brain`, `levels_share`, `levels_tables`, `quests_far`, `task_audience`, `storyline`, `scorcher` | ответ на слова владельца «coop_… в режиме сервера переименовывать». Вместе с именем меняется путь в `coop_npc_compat.script:229-235` |
| Процесс | | `AnomalyCoopDX11AVX.exe` | `RayLinkServer.exe`, только из лаунчера | серверы карт наследуют имя родителя (`xrGame/coop/srv/coop_mapserver.cpp:292`), не проверено вживую |
| Ключи командной строки | `-coop_host`, `-coop_connect` | | `-coop_dedicated`, `-coop_mapserver`, `-coop_operator`, `-coop_new`, `-coop_load(_hex)`, `-coop_stage`, `-coop_hidden` | **не меняются**: договор с лаунчером (`worlds/command.rs:126-141`) |
| Консольные команды | `coop_status`, `coop_debug…` | `coop_host`, `coop_connect`, `coop_disconnect` | `srv_levels_status`, `srv_levels_audit`, `srv_max_map_servers`, `srv_mapserver_linger`, `srv_map_servers_rev` (сегодня `coop_levels_*`, `coop_levels.cpp:613-619`) | старые имена — синонимы на одну dev-сборку; скрипты стенда меняются в том же шаге |
| Настройки мира `c|…` | `c|coop_*` | `c|coop_*` | **новые** только-серверные — `c|srv_*` | существующие ключи не переименовываются (правило 10) |
| Тексты | `st_coop_*` | `st_coop_*` | `st_srv_*` для текстов только сервера (`st_coop_together_row_other`, `st_coop_transition_row_elsewhere/_map`, `st_coop_comp_refused_elsewhere`, `st_coop_faction_split_joined`) | меняются, когда переезжает показывающий скрипт |
| Логи | префиксы модулей как сейчас | `[hostplay]` | `[srv]` у сервера мира, `[srv:ms <карта>]` у сервера карты | поиск по слою одной строкой |
| Тесты | `tests/test_*.cpp`, `tests/lua/test_*.lua` — гоняются под тремя наборами | `test_hostplay_*` | `test_srv_*` | `build_tests.cmd --layer core\|hostplay\|srv\|all` |
| Функция условий | | | `=coop_split_mode` остаётся | на неё ссылаются 25 DLTX-оверлеев; без гибрида имя не врёт |

---

## 7. Что убрано и что будет со старыми мирами

Убрано (шаг S2 плана):

- **Гибрид**: `xrCoop/coop_soft_move.h`, мягкий переход и `host_alone_*` в `coop_join.cpp`, «доска» разделённого
  перехода в `coop_transition.h`, `host_stop_for_move` … `host_launch_now` в `xrGame/coop/srv/coop_mapserver.cpp:708-808`, строка
  `HostProcess`, `led_by_host_process`, `xfer_host_carry_over`, `host_clock_ahead_now`, `rides_with_host`.
- **«Сюжетные карты вместе»**: `story_together`, `configs/coop_levels_together.ltx`, тексты `better_together`.
- **Запуск сервера из игры**: `coop_world_server.cpp/.h`, `coop_world_wait.script`, `coop_world_stage_file.script`,
  ветка `split_chosen` в `coop_newgame_modes.script`, `ContinueSplit` в `coop_menu.script:2113-2129`.
- **Пункты меню** «Разделённые карты», «Мир отдельным процессом», «Сюжетные карты вместе».

Остаётся как данные: ключи `c|coop_split_levels`, `c|coop_world_server` и `c|coop_story_together` в записи мира. Строки
схемы `coop_game_schema.script:81-82,87` остаются без пунктов меню. `coop_dedicated.script:126-134` по-прежнему пишет
оба ключа в каждый новый серверный мир. Держит ли `coop_game_settings` ключ, которого нет в схеме, не проверено, поэтому
строки схемы не удаляем.

| Мир | Что будет | На чём держится |
|---|---|---|
| Кооп-мир | без изменений | — |
| Мир, сохранённый в гибриде | **открывается как кооп-мир** сегодняшним кодом. Отдельная «свёртка журнала» не нужна | журнал передач `0xC0C0` возобновляется только при `split()` (`coop_levels.cpp:547,556`), в коопе он игнорируется, а новый не пишется (`xrGame/coop/srv/coop_levels_xfer.cpp:1035,1043-1065`); объекты остаются в последнем переданном состоянии по одному разу (`xrGame/coop/srv/coop_levels_xfer.cpp:23-24`); игрок, чей персонаж стоит на другой карте, переносится к хосту при входе (`coop_join.cpp:673-689`). Вживую не проверялось — проверка в шаге S2 на мире, сохранённом сборкой 56 |
| Серверный мир, созданный лаунчером | без изменений, запускается из лаунчера | ключ `c|coop_world_server` |
| Серверный мир, созданный из игры | запускается из лаунчера («Запустить сервер»): в записи тот же ключ | `coop_dedicated.script:126-134` писал его и раньше |
| Серверный мир в меню игры | не открывается; сообщение «Этот мир работает как сервер. Запустите его в лаунчере RayLink, раздел Миры» (`st_srv_world_from_launcher`) | замена `ContinueSplit` |

Флаг `"split"` в карточке мира (`coop_json_card.script:26-27,80`) можно убрать: тест лаунчера разбирает карточку без него
(`worlds/tests.rs:554`). Флаг `"world_server"` остаётся.

---

## 8. Steam — только в Коопе

| Где | Что |
|---|---|
| Лаунчер (репозиторий лаунчера, список изменений для его владельца) | `backend.rs:780-781`: ветка, которая отправляет игру хоста Steam в готовый сервер мира (`enter_world`), убирается. Хост Steam всегда хостит кооп. `launch/mod.rs:95-97,111`: `enter_world` больше не передаёт переменные Steam. Сервер (`server_spawn`) уже фильтрует их (`launch/mod.rs:130`) |
| Движок | `x_ray.cpp:985-1011` поднимает Steam только если лаунчер задал `RAYLINK_STEAM_API`; после правки лаунчера в серверном режиме он не задан. Дополнительно: `xrGame/coop/srv/coop_mapserver.cpp:301` получает отфильтрованное окружение вместо `nullptr` (тот же фильтр, что `xrCoop/srv/coop_world_server_rules.h:569`); окно приглашения и `steam_invite_*` (`coop_manager.cpp:920-948`) уезжают в `hostplay` |
| Проверка | L8: слово Steam вне `hostplay` и `x_ray.cpp` — ошибка |

Опрос приглашения Steam (`coop_manager.cpp:133-160,666-689`) остаётся в игровом процессе: так стартует кооп-клиент.

---

## 9. Аварийный путь между режимами

«Открыть серверный мир в коопе, если раздельные карты подведут». Сегодня **такого кода нет**: актор серверного сейва —
призрак сервера, персонаж создателя — прокси-сталкер, и ничего не превращает прокси в актора (`map-products.md` §2.2).

Решение по умолчанию (открытый вопрос плана): **сейчас не делаем**. Сейв защищают кольцо сохранений сервера и проверки
стенда «падение сервера карты» и «сохранение во время передачи карты» (шаг S7). Если серверный мир когда-нибудь
застрянет — пишем однонаправленный конвертер в слое `srv` (3-5 дней): сервер мира без сессии переносит персонажа
создателя в актора, сохраняет копию `<мир>_coop` с `world_server = false`, исходный мир не трогает. Кооп для этого не
меняется.

Обратного пути (кооп-мир → сервер) нет и не будет: старые миры не переносятся (решение владельца 2026-11-13,
`coop_dedicated.script:157-158`).

---

## 10. Как принимается правка (проверки по режимам)

Обозначения:

| Код | Команда | Что внутри |
|---|---|---|
| G | `python -I tools\check_layers.py` | раздел 5; первая строка N и L (отказ — код 254; `COOP_SKIP_LAYERS=1` — аварийный обход ведущей) |
| N | `tools\build_tests.cmd` | нативные тесты; тесты Ядра под наборами ответов `hostplay`, `srv`, `none` (`MODE_CASES`) |
| L | `tools\test_lua.cmd` | Lua-тесты; файл Ядра гоняется под каждым набором (`COOP_LUA_MODE`), файл режима — под своим |
| T | `tools\run_all_tests.cmd` | N и L целиком; оба прошли на чистом дереве, HEAD не сдвинулись и `temp\lua\runlua.exe` собран из исходников сейчас (четвёртое ревью, B5) — пишет `temp\gates\tests.ok` (оба HEAD, `dirty=0`) |
| LN | `python -I tools\stand\stand_head.py links --stand E:\RayLinkGames\GAMMA\game-dev` | перед выкладкой на стенд: что она заменит, сколько из этого жёсткие ссылки на файлы модов, и нет ли имени, которое сейчас нельзя удалить (Р21); ничего не пишет |
| SC | `powershell -ExecutionPolicy Bypass -File tools\stand_hostplay.ps1 -Tag b<N>` | стенд Коопа: выкладывает gamedata HEAD, затем `carry_group`, `base_group`, `sil_group`, `squads_group` (отряды рядом с клиентом, R1), `sp_smoke` (одиночная игра без ключей `-coop_`: новая игра, сохранение, загрузка, минута), `companions_group` (круг 8), `cover_group` из `tools\stand`. Пишет `temp\gates\hostplay.ok` |
| SS | `powershell -ExecutionPolicy Bypass -File tools\stand_srv.ps1 -Tag b<N>` | стенд Сервера: выкладывает gamedata HEAD, затем `ded_check -World new`, `base_server`, `carry_server`, `taskboard_ws`, `phantoms_server` (круг 8), `allymark_server`, `companions_server`, `weather_server`, `cover_server`, `ms_crash_server`, `save_handover_server`, `creator10_server`, `feed_server` из `tools\stand`. Пишет `temp\gates\srv.ok` |
| Еженедельно | `powershell -ExecutionPolicy Bypass -File tools\stand\run_guarded.ps1 -Script soak_hour_server.ps1 -Out soak_hour_server.out` | `soak_hour_server` — час на двух картах с записью памяти каждого сервера карты. Запускать отдельно на подготовленном стенде Сервера. |
| R | `python -I tools\release.py --channel dev --build <N> verify` | `check_gates.py <тег>..HEAD --release --layers` (G на той же модели + правило выпуска + exe из HEAD движка) + проверки пакета |

Стенд — только `E:\RayLinkGames\GAMMA\game-dev`. Живая игра владельца не трогается. Файлы стенда — жёсткие ссылки на
файлы модов MO2 (Р21): SC, SS и выкладка пишут в стенд только новыми файлами (раздел 5, «Жёсткие ссылки»); первую
выкладку после пятого круга ведущая начинает с LN. После шестого круга LN показывает и то, что выкладка уберёт без всякой
памяти прошлых прогонов (`would_remove=`: файлы `gamedata`, которых нет ни в манифесте, ни в HEAD; `would_restore=`:
файлы модов под нашей уроненной правкой): первую выкладку шестого круга ведущая начинает с LN и просматривает эти
строки. Память выкладки теперь в стенде (`.raylink-head-deploy.json`), а не только в `temp\stand\head_backup`.

**Выпуск (правило выпуска, третье ревью):** любая правка продукта в диапазоне выпуска — **G T SC SS на одном exe**, какой
бы слой ни был у файлов, и exe — сборка engine-ci из HEAD движка. Таблица ниже — раннее предупреждение для коммита и
рабочего дерева (`check_gates.py` без диапазона или с `--per-commit`): что понадобится, если чинить только этот слой.

| Что меняется | Раннее предупреждение |
|---|---|
| Ядро (включая сток, маршруты кроме `host`↔`level`, протокол, файлы из `layers_allow.txt`, списки и проверки `tools/` из раздела 5, фасад `coop_mode` и его слои, файлы `srv`/`hostplay`, которые Ядро включает или зовёт) | G N L SC SS на одном exe |
| Только `srv` | G N L SS; набор кооп-тестов (имена) не изменился, в `tests/` правлены только файлы `test_srv_*`; SC зелёный на той же сборке (к выпуску — обязательно: правило выпуска). Сегодня (до S4) Ядро достигает 37 из 38 серверных файлов, последний — `gate-core`: любая правка серверного файла требует обоих стендов |
| Только `hostplay` | G N L SC |
| `hostplay` и `srv` в одном коммите без Ядра | отказ: разделить коммит |

Прогоны стендов собираются пачкой на dev-сборку (около 20-30 минут стенда), а не на каждый коммит. Выпуск без
`hostplay.ok`, `srv.ok` и `tests.ok` этих HEAD `release.py verify` не пропускает. Метка стенда считается только полная (все
сценарии стенда), со своим `mode=`, `dirty=0` (стенд гонял exe без незакоммиченных и неотслеживаемых файлов продукта),
`exe_source=` HEAD движка, `stand_extra=0`, exe и отпечатком своего стенда и с `scenarios_sha256` / `gamedata_sha256` /
`profile_sha256`, равными пересчёту из HEAD (стенд гонял сценарии, gamedata и переменные режима этого HEAD; раздел 5).

`release.py`: `verify` гейтит от последнего тега выпуска своего канала (другой `--since` — только с `--since-override` и
только предок этого тега: диапазон можно расширить, сузить нельзя; печатается и пишется в `verified.json`; текст отказа
флаг не подсказывает), отказывает при неотслеживаемом файле продукта в любом репозитории, сверяет каждый файл пакета с
блобом HEAD (выходит только закоммиченное) и записывает SHA-256 текстов выпуска и `exe_built_from` (HEAD движка); `draft` и `publish` отказывают, если сдвинулся любой HEAD, текст выпуска изменился
после `verify`, диапазон начинался не с последнего опубликованного тега канала (с `--since-override` — не с его предка);
`publish` до правки проверяет оба
черновика (черновик, канал, дайджесты) и для Dev — что Stable `latest` тот же, что сохранил `draft`; Stable выходит только
на коммите, опубликованном как `dev-<N>`.

Публикует **только** `release.py` (пятое ревью, B2): `tools\publish_dev.sh` и `publish_dev_engine.sh` отказывают (код 2)
и печатают команды `release.py --channel dev --build <N> prepare / verify / draft / publish`; тест
`test_only_release_py_publishes` не пускает команду публикации ни в один другой файл `tools/` (с седьмого круга — и в
форме списка Python, `gh api -f`, `curl -X POST`, `Invoke-RestMethod -Method Post`, команды, разбитой на строки).

Stable (седьмой круг): `BUILD=<N> bash tools/publish_github.sh`. Скрипт проверяет ввод (`BUILD` — целый номер,
`OWNER` — только `stormie-labs`, как `ORG` в `release.py`; иначе код 2, ничего не запущено), затем первой командой —
`python -I tools/release.py --channel stable --build <N> verify` (сети не касается; отказ — код 2, «Nothing was
published», ни одной команды `gh`/`git` и подсказка `prepare` / `package.ps1` / `verify`), затем `gh auth`, проверку,
что публичный `main` RayLink-Engine сделан здесь (ветка `publish`, локальный тег движка или предок HEAD движка; иначе
код 4 — снимок поверх него стёр бы чужие коммиты), и выпуск **через `release.py draft` и `publish`** (тег `b<N>` и `main`
обоих публичных репозиториев, черновики с проверенными SHA-256, затем `latest`). Своих `gh release create` и пуша
`main` у скрипта нет; лаунчер (`SKIP_LAUNCHER=1` — без него) — как раньше: исходники в приватный
RayLink-Launcher-Source. Тесты: `test_publish_github_*` гоняют копию скрипта в поддельном проекте с поддельными
`python`, `gh` и `git`; `test_verify_first_tools_run_release_py_verify_before_any_network_command` следит, что строка
`verify` стоит раньше любой сетевой команды. `verify` копирует exe в `temp/<тег>/` до ворот и судит эту копию (шестое
ревью, остаток a).

Отчёт владельцу и `docs/TESTERS.md` — по каждому режиму отдельной строкой (`CLAUDE.md`, правила 4-5).
