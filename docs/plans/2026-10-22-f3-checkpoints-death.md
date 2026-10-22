# Ф3. Привалы и смерть — план реализации

> **Для исполнителей-агентов:** обязательный навык — superpowers:subagent-driven-development (рекомендуется) или
> superpowers:executing-plans; задачи выполняются по шагам. Шаги размечены чекбоксами (`- [ ]`) для отслеживания.

**Цель:** у каждого игрока свой привал; смерть не откатывает мир (эвакуация с задержкой T, потери по `death_drop`,
износ, контузия, режимы `checkpoint` / `hardcore`); общий сон начинается, только когда отдыхают все; задания при вайпе
идут по таблице; хост сам пишет аварийные автосейвы с ротацией; у игроков нет меню сохранения и загрузки.

**Архитектура:**
- Чистая логика — header-only в `engine/src/xrCoop/coop_*_rules.h`, без движковых типов, с юнит-тестами в `tests/`:
  - запись привала и её разбор;
  - откат на предыдущую запись и выбор точки возрождения;
  - таймер «5 с у костра»;
  - правила смерти и выбор потерь;
  - решение об общем сне;
  - ротация автосейвов.
- Движок (`engine/src/xrGame/coop/`), всё решает хост:
  - хранилище привалов — `coop_checkpoints`;
  - распознавание источников — `coop_checkpoint_sources`;
  - смерть — `coop_survival` и `coop_death`;
  - общий сон — `coop_rest`;
  - автосейвы — `coop_autosave`.

  Клиент только сообщает: «лёг», «встал», «поставил палатку».
- Lua и ltx (`gamedata/scripts/coop_checkpoints|coop_rest|coop_death|coop_wipe|coop_saves.script`):
  - триггеры стока;
  - тексты и метки КПК;
  - контузия;
  - задания при вайпе;
  - меню и опции.

  Движок зовёт Lua через `SendScriptCallback` из очереди кадра (`coop::script::queue_callback`, Task 2).
- Ф3 живёт в новых файлах. Общие с Ф2 файлы правятся ранней задачей (Task 2) и поздней (Task 18).

**Стек:** C++ (MSVC 2022, xray-monolith `ad9d841660` + `engine/src/xrCoop`, `engine/src/xrGame/coop`), Lua 5.1 /
LuaJIT 2.0.4 движка, ltx и xml (cp1251, CRLF), инструменты `tools/`.

**Спецификация:**
- `docs/CHECKPOINTS_DEATH.md` — главная;
- `TZ.md` — строка Ф3, P6, P7, P8, P11;
- `docs/SPLIT_LEVELS.md` §5;
- `docs/MOD_REPLACEMENTS.md`;
- `SYNC_SPEC.md` §6.1.

Факты стока и GAMMA — в vault: «Anomaly и GAMMA — сохранения, автосейвы, костры и смерть».

## Глобальные ограничения

**Из спецификации:**
- Привал у каждого игрока свой. Запись: `{уровень, позиция, level_vertex, game_vertex, вид, id объекта-источника,
  время}` плюс предыдущая запись. Хост держит её по игроку в своём сейве (§2.1).
- Инвариант: привал на той карте, где его поставили. В Ф3 все игроки на одной карте, но уровень в записи хранится
  всегда (P11, `SPLIT_LEVELS.md` §5).
- Костёр — объект `CZoneCampfire` с `is_on()`, радиус 3 м. Игрок пробыл рядом 5 с и не в бою (§2.2).
- Привал ставит только хост, после проверки: игрок жив, не в бою, позиция валидна, источник существует, игрок рядом.
  Клиент может лишь сообщить (§2.2, P8).
- Значения по умолчанию:
  - T = 30 с;
  - `death_mode` = `checkpoint`;
  - `death_drop` = `drop`;
  - ранг и репутация при смерти не теряются.

  Квестовые предметы не теряются никогда (§3).
- Смерть мир не откатывает, даже при вайпе (P7).
- Сон начинается, только когда отдыхают все члены группы, никто не в бою и нет выброса (§4).
- Автосейвы хоста пишутся при переходе на карту, после общего сна, раз в 10 мин и в конце сессии. Ротация
  `coop_auto_N`, хранится 10 (§7).
- Таблица заданий — `configs/coop_wipe_tasks.ltx`. Незнакомое задание не трогается (§6).
- Языки — русский и английский (P9). Каждая строка `st_coop_*` есть в `text/eng` и `text/rus`, файлы в cp1251 с CRLF
  (`tests/tools/test_strings.py`).
- Мод или механика выключены, заменены или урезаны → строка в `docs/MOD_REPLACEMENTS.md` в том же коммите (P5).

**Процесс:**
- Агенты не коммитят и не правят `docs/*.md` и `MODLOG.md`. Нужные правки документов агент пишет в отчёт, ведущая
  вносит их в коммит задачи. Так параллельные задачи не конфликтуют в документах.
- Строгая типизация, без хаков. Стиль окружающего кода:
  - таб;
  - у врезок в стоковые файлы — комментарий `// Anomaly Coop:`, сама врезка в одну строку.
- Новый тест сначала падает по утверждению, а не по компиляции. Вместе с тестом кладётся заголовок с объявлениями и
  заглушками: `tests/test_*.cpp` собираются в один exe у всех параллельных агентов.
- `tools/build_tests.cmd` не запускать одновременно с другим агентом:
  - перед запуском — `mkdir temp\build_tests.lock`, если папка есть — ждать;
  - после — `rmdir temp\build_tests.lock`.
- Проверки:

  | Что | Команда | Успех |
  |---|---|---|
  | Компиляция xrGame | `tools/compile_files.sh <пути от engine/src/xrGame>` (держит `temp/compile.lock`) | 0 ошибок |
  | Юнит-тесты | `tools/build_tests.cmd [фильтр]` | код 0 |
  | Lua | `tools/test_lua.cmd [фильтр]` | код 0 |
  | Строки | `python -m pytest tests/tools/test_strings.py -q` | все тесты прошли |
- Новые `.cpp` движка уже внесены в `xrGame.vcxproj` задачей 2. Задачи их только наполняют.
- Игру не запускать. Живые сценарии — Task 19, по слову владельца.
- Коммиты: движок — репозиторий `engine/` (ветка `coop`), всё остальное — корень `anomaly-coop`. Задача, которая
  трогает оба, даёт два коммита с одним заголовком.

## Что проверить отдельно (Review Focus)

1. **Игрок вышел, пока мёртв или эвакуируется, и вернулся.** Ожидается: он возвращается живым на своём привале, вещи
   второй раз не теряются. Тесты `death_tracker_left_return` и `death_tracker_once` (Task 4), применение — Task 8,
   шаг 4.
2. **Хост сменил карту или загрузил автосейв, пока кто-то мёртв или отдыхает.** Ожидается: после возвращения в мир
   все живы, никто не завис в дрёме или в смерти, вещи второй раз не теряются. Тест `death_tracker_world_replaced`
   (Task 4), шаги — Task 8 шаг 4 и Task 11 шаг 5.
3. **Смерть самого хоста (персонаж id 0).** Ожидается: тот же путь, что у клиента — эвакуация, потери, возрождение на
   привале хоста. Автосейв по таймеру ждёт, пока хост снова жив. Тест `autosave_timer_postpone` (Task 5), шаг —
   Task 8 шаг 6, сценарий 19.8.
4. **`drop`: выпавшее недоступно** — провалилось, укатилось или убрано чисткой мода. Ожидается: всё выпавшее лежит не
   дальше 3 м от места гибели и через 10 мин на месте. Шаг — Task 9 шаг 4, сценарий 19.9.
5. **Новый или вернувшийся игрок входит, пока остальные отдыхают.** Ожидается: без него сон не начинается, а
   отдыхающие продолжают отдыхать. Тест `rest_newcomer_blocks` (Task 5).

## Распределение по исполнителям и волны

Не больше 4 агентов одновременно, у каждого свои файлы. Модели — по CLAUDE.md §8: Opus — движок, Sonnet — Lua по
готовому контракту, чистые правила с готовыми тестами, разведка.

| Волна | Агент | Задачи | Файлы |
|---|---|---|---|
| 0 | A (Sonnet) | 3 → 4 → 5 | `xrCoop/coop_checkpoint_rules.h`, `coop_death_rules.h`, `coop_rest_rules.h`, `coop_autosave_rules.h`, `tests/test_{checkpoint,death,rest,autosave}_rules.cpp` |
| 0 | B (Opus) | 2 | общие с Ф2 (таблица ниже), каркасы новых модулей, `tests/test_protocol_f3.cpp` |
| 0 | C (Sonnet) | 1 | `docs/research/2026-10-22-f3-saves-sleep-recon.md` |
| 0 | D (Sonnet) | 16 | `coop_wipe.script`, `configs/coop_wipe_tasks.ltx`, `configs/coop_domains_checkpoints.ltx`, `tests/lua/test_wipe.lua` |
| 1 | B (Opus) | 6 | `coop_checkpoints.{h,cpp}`, `coop_checkpoints_lua.cpp`, `alife_update_manager.cpp` |
| 1 | A (Opus) | 9 | `coop_death.{h,cpp}`, `configs/mod_system_coop_death.ltx` |
| 1 | D (Opus) | 12 | `coop_autosave.{h,cpp}`, `coop_manager.cpp` |
| 1 | C (Sonnet) | 17 | `ui/UIMMShniaga.cpp`, `coop_saves.script`, `coop_core_player.script`, `coop_menu.script`, `coop_menu_options.script` (только снять флаг), `text/*/st_coop_saves.xml`, `tests/lua/test_saves.lua` |
| 2 | B (Opus) | 7 | `coop_checkpoint_sources.{h,cpp}`, `coop_checkpoints_lua.cpp`, `configs/mod_system_coop_checkpoints.ltx` |
| 2 | A (Opus) | 8 | `coop_survival.{h,cpp}`, `text/*/st_coop_survival.xml` |
| 2 | C (Sonnet) | 13 | `coop_checkpoints.script`, `coop_allies.script`, `text/*/st_coop_checkpoints.xml`, `tests/lua/test_checkpoints.lua` |
| 3 | A (Opus) | 10 | `coop_survival.cpp`, `coop_death.cpp`, `coop_join.{h,cpp}`, `coop_menu_char.script`, `text/*/st_coop_survival.xml` |
| 3 | B (Opus) | 11 | `coop_rest.{h,cpp}` |
| 3 | C (Sonnet) | 15 | `coop_death.script`, `coop_menu_options.script`, `text/*/st_coop_death.xml`, `tests/lua/test_death.lua` |
| 4 | C (Sonnet) | 14 | `coop_rest.script`, `configs/ui/ui_coop_rest.xml`, `coop_allies.script`, `coop_economy_group.script`, `text/*/st_coop_rest.xml`, `tests/lua/test_rest.lua`, `tests/lua/test_economy.lua` |
| 4 | ведущая | 18 | `coop_main.script`, `coop_domains_checkpoints.ltx` → `coop_route_f3.ltx` — после Ф2 задачи 10 и слияния её правок `coop_main.script` |
| 5 | ведущая + владелец | 19 | приёмка |

Зависимости:
- 6 ← 2, 3;
- 7 ← 6;
- 8 ← 4, 6, 9;
- 9 ← 2, 4;
- 10 ← 8, 9;
- 11 ← 5, 7, 12;
- 12 ← 2, 5;
- 13 ← 6, 7 (имена API зафиксированы здесь, тест — на заглушках);
- 14 ← 1, 11;
- 15 ← 8, 9, 12;
- 16 — независима;
- 17 ← 1.

## Общие с Ф2 файлы и порядок

| Файл | Задача Ф3 | Что меняет Ф3 | Порядок |
|---|---|---|---|
| `xrGame/coop/coop_script.{h,cpp}` | 2 | `CallbackArg` и `queue_callback` (новый вид `EngineEvent::Callback`) | Ф3 первой, ~60 строк; Ф2 ребейзится |
| `xrGame/coop/coop_sync.cpp` | 2 | по строке `install/reset/frame/print_status` для 4 модулей | Ф3 первой |
| `xrGame/coop/coop_console.cpp` | 2 | `register_console()` 4 модулей | Ф3 первой |
| `xrCoop/coop_protocol.{h,cpp}` | 2 | `Msg` 0x01C0–0x01C6, `msg_name`, `msg_sender` | диапазоны разведены планом Ф2: Ф2 — 0x0190–0x019F, Ф3 — 0x01C0–0x01CF. `kProtocolVersion` и строку истории версии ставит ведущая по порядку коммитов (счётчик общий) |
| `xrGame/xrGame.vcxproj(.filters)` | 2 | 6 новых `.cpp` и их заголовки (`tools/vcxproj_add.py`, фильтр `Coop`) | Ф3 первой, инструмент идемпотентен |
| `xrServerEntities/script_engine_export.cpp` | 2 | include и строка регистратора `coop_checkpoints_script_registrator` | риск низкий |
| `gamedata/configs/coop_domains_*.ltx` → `coop_route*.ltx` | 16, 18 | Task 16 — новый файл `coop_domains_checkpoints.ltx` (формат до Ф2). Task 18 переводит его в `coop_route_f3.ltx` формата Ф2 | Ф2 задача 10 переименовывает домены и меняет формат; Ф3 — после неё |
| `gamedata/scripts/coop_economy_group.script`, `tests/lua/test_economy.lua` | 14 | сон уходит из голосования `economy.propose/vote/…` в общий сон движка; `wait` и `travel` остаются | план Ф2 отдаёт этот файл Ф3 (Ф2 задача 23 его не трогает) |
| `coop_join.cpp` | 10 | `host_rejoin_peer` | после Ф2 задачи 3 (`kRateRules` → `coop_limits.h`, волна 1 Ф2) |
| выброс | 11, 14 | Lua хоста сообщает `coop.rest.set_world_block("emission")` | после Ф2 задачи 18 состояние выброса есть в движке (`coop_envstate.h`), `rest` может читать его сам — необязательная правка |
| задания | 16 | провал при вайпе — стоковым `set_task_failed` у хоста | живую проверку — после Ф2 задачи 16 (`host_on_task_state`) |
| `gamedata/scripts/coop_main.script` | 18 | снять клиентские гейты сейва (`:915-960`, `:1013`, `:1100-1101`): их заменил `coop_saves.script` | после Ф2 |
| `gamedata/scripts/coop_menu_options.script` | 17, 15 | снять флаг `client_quicksave`; правила смерти и автосейва на странице «Кооператив» | если Ф2 переносит настройки в движок — Ф3 после Ф2 |
| `gamedata/scripts/coop_core_player.script` | 17 | убрать запрос быстрого сейва клиентом (§3 файла) | ребейз при конфликте |
| деньги | 15 | штраф денег пока у владельца: `db.actor:give_money(-x)` | после Ф2 («деньги под властью хоста») — перенести на API денег Ф2, пометка `-- F2:` в коде |

Не трогаем: `coop_requests.cpp` (палатка определяется по близости, Task 7) и `coop_trade.cpp` (свой помощник переноса
вещей, Task 9).

## Временное хранилище player-области (до API Ф2)

API `player`-области (`SYNC_SPEC.md` §6.1) появится в Ф2 (`coop_sync_api`). До него в Ф3 привалы живут в custom data
персонажа игрока:
- у клиента — прокси `coop_player_avatar`;
- у хоста — актор id 0.

Формат: секция `[coop_checkpoint]`, ключи `cur` и `prev` — строка `checkpoint::encode` (Task 3); у актора хоста ещё
ключ `arrival`. Custom data пишется в сейв (`CSE_ALifeObject::STATE_Write`, `xrServer_Objects_ALife.cpp:434`) и
ходит вместе с персонажем (W9, ключ игрока уже лежит там же). Поэтому аварийное восстановление (§10.7) получает
привалы из сейва без отдельного файла.

Переезд на API Ф2:
- В плане Ф2 (задача 14) область `player` есть только в Lua (`coop.sync`, адрес `player:<peer>`). В сейв она идёт
  через Lua: `m_data.coop_sync`. Доступа из C++ там нет.
- Переезд возможен, когда Ф2 добавит `coop::syncapi::player_get/player_set(u16 character, key, value)`. Это
  предложение в Ф2. Тогда `checkpoints::store_slot / load_slot` (Task 6) переключаются на него, ключи
  `coop.checkpoint.cur|prev`, строка формата та же. При загрузке старого сейва секцию custom data переносят в область
  и стирают.
- Если C++-доступа не будет, custom data остаётся постоянным хранилищем: она тоже в сейве хоста, тоже по персонажу и
  не зависит от Lua.

Это же записывается в `docs/CHECKPOINTS_DEATH.md` §2.1 (Task 6).

## Совместимость с Ф3a (раздельные карты)

- В записи всегда хранится уровень.
- `checkpoint::resolve` в Ф3 пропускает запись на другой карте (падает на следующий вариант). В Ф3a эта ветка
  заменяется переходом на карту привала. Место одно — `Pick` в `resolve`.
- Точка прибытия ставится по персонажу: `checkpoints::host_set_arrival(character, record)`. В Ф3 её зовёт групповой
  `change_level`. В Ф3a — переход одного игрока.
- Общий сон считает группу целиком, независимо от карт (`SPLIT_LEVELS.md` §5).

## Решения, принятые в плане (с причиной)

1. **Хранилище привалов** — custom data персонажа до API Ф2 (раздел выше). Причина: попадает в тот же сейв, что и
   мир, нет осиротевших файлов, восстановление согласовано само.
2. **Доли потерь по категориям** — в ltx (`mod_system_coop_death.ltx`), выбор предметов — чистая функция C++. Lua в
   этой цепочке не участвует. Причина: §3.3 требует «доли в ltx, перенос — движок на хосте». DLTX позволяет GAMMA
   переопределять доли.
3. **«Труп» в режиме `corpse`** — контейнер `coop_death_stash` (наследник стокового `inv_backpack`), а не NPC-труп.
   Причина: тела NPC убирает `death_manager`, а стоковый тайник-рюкзак `item_backpack` — такой же контейнер.
4. **Часы общего сна** — минимум из выбранных отдыхающими. Причина: никто не проспит дольше, чем хотел.
5. **Настройки хоста** — страница «Опции → Кооператив», а не MCM. Причина: в стоке Anomaly 1.5.3 MCM нет, правила
   хоста уже живут там (`coop_menu_options.script`).
6. **Палатка определяется по близости.** Lua игрока сообщает «поставил палатку здесь», хост находит рядом ничью
   палатку не старше 15 с. Причина: не трогаем `coop_requests.cpp` (Ф2), работает на любой машине.
7. **Метка КПК привала** — только на объекте-источнике (костёр, палатка, рестриктор, объект мода). У точки прибытия
   и сюжетного привала метки нет, игрок получает только подсказку. Причина: в движке нет меток по позиции
   (`map_manager_script.cpp:15`, `AddUserLocation` закомментирован).
8. **Контузия не переживает переподключение** (не хранится у хоста). Причина: YAGNI. Переподключение стоит дороже
   контузии.
9. **Сейвы скрыты у всех игроков в сессии, хоста тоже.** У хоста вместо них «Восстановить» и `coop_autosave_now`.
   Консольный `save` у хоста остаётся для отладки. Причина: P7 — сейвы только аварийные.
10. **Сон в общий сон, `wait` и `travel` — по-прежнему голосованием** (`coop_economy_group.script`). Причина:
    §4 описывает только сон. Предметы, пропускающие время (GAMMA Books Pass Time), и путешествия спецификация не
    трогает. Их правило хоста `sleep_rule` (`host` / `gather` / `vote` / `safe_or_vote`) остаётся.
11. **Старые значения `coop_death_mode`.** `respawn` и `respawn_keep` — синонимы `checkpoint` в токенах консоли,
    чтобы `user.ltx` старых установок не ломался.

## Нужны решения владельца

- **Числа** (§11, подбираются на плейтесте; в плане стоят как значения по умолчанию):

  | Параметр | По умолчанию | Чем задаётся |
  |---|---|---|
  | T | 30 с | спецификация |
  | Контузия | 10 мин | предложение |
  | Штраф денег | 10 % | предложение |
  | Износ надетого | 10 % за смерть | предложение |
  | Доли потерь: материалы, патроны, расходники | 0.5 | предложение |
  | Доли потерь: оружие и броня в рюкзаке | 0.25 | предложение |
  | Доли потерь: артефакты, инструменты | 0.1 | предложение |
  | Доли потерь: прочее | 0.25 | предложение |
- Режим `corpse`: тайник-рюкзак вместо тела NPC (решение 3) — подтвердить.
- `hardcore` для хоста. Его «новый персонаж» — тот же актор: снаряжение уходит в тайник у тела, состояние обнуляется,
  набор выбирается по группировке в окне `coop_menu_char`. Подтвердить.
- Сценарий §10.4 («привал хоста не изменился») в полном виде возможен только с раздельными картами (Ф3a). В Ф3
  переход групповой: точку прибытия получают все, у хоста прежний привал уходит в `prev`. В приёмке Ф3 он проверяется
  в этом виде (19.4), полный — в приёмке Ф3a. Подтвердить.
- Задания «защита» и «сопровождение» при вайпе. В стоке нет функторов с такими именами. В плане:
  - проваливаются `gd_task_status_functor` (оборона насосной) и `spy_task_status_functor` (спасение агента);
  - не трогаются `smart_control_task_status_functor` и `dominance_task_status_functor`.

  Подтвердить.

---

### Task 1: Recon — stock save/load UI and sleep/tent entry points in a coop session

Разведка, кода не пишет. Результат — `docs/research/2026-10-22-f3-saves-sleep-recon.md` с двумя разделами. В каждом
решения с файлом и строкой. Его читают задачи 13, 14, 17.

**Файлы:** создать `docs/research/2026-10-22-f3-saves-sleep-recon.md`.

**Даёт:**
- **§A Сейвы.** Механизм скрытия кнопок «Сохранить», «Загрузить» и «Последний сейв» в игровом меню в сессии, у хоста
  и у клиентов, и всех путей быстрого сейва и загрузки.
- **§B Сон и палатка.** Таблица «вход → функция стока (файл:строка) → на какой машине исполняется сейчас → что
  делает Ф3».

- [ ] **Шаг 1 (§A):** прочитать:
  - `engine/src/xrGame/ui/UIMMShniaga.cpp:68-100` — выбор списка кнопок по состоянию; `CreateList` `:114`;
    `IsButton` `:242`;
  - XML `menu_main_single` в `anomaly-ref/unpacked/configs/ui/ui_mm_main*.xml` — имена кнопок;
  - `CMainMenu::Activate` и `ReloadUI` (`MainMenu.cpp:182`, `:301-323`) — пересоздаётся ли список при каждом
    открытии меню.

  Записать: где фильтровать кнопки, если `coop::mgr().active()` (по умолчанию — в `CreateList`), и нужен ли сброс
  меню при старте и конце сессии.
- [ ] **Шаг 2 (§A):** перечислить пути сейва и загрузки с файлом и строкой и указать, какой закрывается
  `on_before_save_input` / `on_before_load_input`:
  - `level_input.script:48-60`, `:106-113`;
  - `ui_main_menu.script:164-173` (тип 1), `:300`, `:307-316` (F6, тип 3), `:198`, `:120`, `:269`;
  - `xr_effects.on_tutor_gameover_quickload` `:2887`;
  - моды GAMMA из профиля `E:\GAMMA\profiles\G.A.M.M.A`, которые сами зовут `exec_console_cmd("save` (grep по
    включённым модам).
- [ ] **Шаг 3 (§B):** по `configs/coop_domains*.ltx` и коду стока определить, где сейчас исполняются входы сна и
  палатки:
  - `ui_sleep_dialog.sleep_in_zone` — через `sr_sleep.ltx` → `run_tutorial` (логика рестриктора у хоста);
  - `sleep_bag`, `sleep_forced` (`actor_status_sleep.script:84`), `UISleep:TestAndShow` `:95-133`,
    `OnButtonSleep` `:153-200`, `dream_callback` `:233-248`;
  - `item_tent.actor_on_item_use` `:121`, `itm_tent_func` `:30-45`, `itm_tent_bag_func` `:68-82`,
    `use_compression_bag` `:84-108`, `physic_object_on_use_callback` `:149-154`.
- [ ] **Шаг 4 (§B):** проверить по `coop_requests.h:105-114`, что делает `item_tent.itm_tent_func` у клиента, когда
  `alife_create` возвращает `nil`. Записать вывод: нужна ли Ф3 Lua-обёртка `item_tent` для коопа или хватит
  маршрутизатора вызовов Ф2 (`docs/MOD_LAYER.md` §2.3). Ф3 палатку в любом случае определяет по близости (Task 7).
- [ ] **Шаг 5:** ведущая читает отчёт. Если §A требует правки движка вне `UIMMShniaga.cpp` — дописывает её шагом в
  Task 17.
- [ ] **Шаг 6:** коммит (проект): `docs: F3 recon of save/load UI and sleep/tent entry points in a co-op session`.

### Task 2: F3 contract in files shared with F2 (messages, script callback queue, module slots)

**Файлы:**
- Изменить:
  - `engine/src/xrCoop/coop_protocol.h:43-141` (enum `Msg`) и `coop_protocol.cpp` (`msg_name`, `msg_sender`);
  - `engine/src/xrGame/coop/coop_script.{h,cpp}` (`EngineEvent` `:69-81`, `deliver_engine`);
  - `coop_sync.cpp` (`on_session_started`, `reset`, `frame`, `print_status`, `install`);
  - `coop_console.cpp:161`;
  - `engine/src/xrServerEntities/script_engine_export.cpp:25,278`;
  - `engine/src/xrGame/xrGame.vcxproj` и `.filters`.
- Создать каркасы с пустыми телами:
  - `coop_checkpoints.{h,cpp}`, `coop_checkpoint_sources.{h,cpp}`, `coop_checkpoints_lua.cpp`;
  - `coop_death.{h,cpp}`, `coop_rest.{h,cpp}`, `coop_autosave.{h,cpp}`.
- Тест: `tests/test_protocol_f3.cpp`.

**Интерфейсы — даёт:**
```cpp
// coop_protocol.h — диапазон Ф3 0x01C0..0x01CF (Ф2 занимает 0x0190..0x019F, план Ф2 «Глобальные ограничения»)
CheckpointState = 0x01C0, // host -> client(s): u16 character, u8 flags (1 rollback, 2 cleared), checkpoint::write(Record)
CheckpointClaim = 0x01C1, // client -> host: u8 what (1 = tent placed), vec3 pos
RestRequest     = 0x01C2, // client -> host: u8 op (1 lie down, 2 get up), u8 hours, u8 forced
RestState       = 0x01C3, // host -> all: u8 world_block, u8 n, n x {u16 character, u8 state, u8 hours}
RestSleep       = 0x01C4, // host -> all: u8 hours
DeathMarker     = 0x01C5, // host -> all: u16 character, u16 marker object, u8 drop mode
NewCharacter    = 0x01C6, // client -> host: hardcore, the dead player starts a new character
// msg_sender: 0x01C0, 0x01C3, 0x01C4, 0x01C5 -> HostOnly; 0x01C1, 0x01C2, 0x01C6 -> ClientOnly

// coop_script.h
struct CallbackArg { enum Kind : u8 { Nil, Bool, Int, Str } kind = Nil; s64 i = 0; std::string s; };
CallbackArg cb_nil(); CallbackArg cb_bool(bool); CallbackArg cb_int(s64); CallbackArg cb_str(const char*);
// SendScriptCallback(name, args...) from frame() (main thread, in the world; stale after kStaleMs dropped, as other events)
void queue_callback(const char* name, std::initializer_list<CallbackArg> args);

// lifecycle of every new module (namespaces coop::checkpoints, coop::death, coop::rest, coop::autosave)
void install(Session& s); void reset(); void frame(); void print_status(); void register_console();
// coop::checkpoints and coop::rest also: void register_lua(lua_State* L);  (fills coop.checkpoint / coop.rest)
const char* autosave::level_change_name(); // skeleton returns nullptr (Task 12 fills it)
rest::State rest::state_of(u16 local_id);  // skeleton returns rest::State::Awake (Task 11 fills it; Task 12 reads it)
struct coop_checkpoints_script_registrator { DECLARE_SCRIPT_REGISTER_FUNCTION }; // coop_checkpoints.h, runs after coop_script_registrator
```

- [ ] **Шаг 1: тест** `tests/test_protocol_f3.cpp`:
  - `protocol_f3_names`: `msg_name(Msg::CheckpointState) == "CheckpointState"`, и так для всех семи;
  - `protocol_f3_senders`: `msg_sender(Msg::CheckpointState) == MsgSender::HostOnly`,
    `msg_sender(Msg::RestRequest) == MsgSender::ClientOnly`, и так для всех семи.

  Значения enum в заглушке объявить сразу, чтобы тест компилировался.
- [ ] **Шаг 2:** `tools/build_tests.cmd protocol_f3` → FAIL: имена `Msg_0x01C0`, отправитель `Either`.
- [ ] **Шаг 3:** записи в `msg_name` и `msg_sender`.
- [ ] **Шаг 4:** `tools/build_tests.cmd protocol_f3` → PASS; `tools/build_tests.cmd` → PASS.
- [ ] **Шаг 5:** `queue_callback`:
  - новый `EngineEvent::Callback` с `std::string name` и `std::vector<CallbackArg>`;
  - доставка через существующий `send_script_callback` (Nil → `lua_pushnil`, Bool → `lua_pushboolean`,
    Int → `lua_pushinteger`, Str → `lua_pushlstring`);
  - лимит очереди и устаревание — как у остальных событий.
- [ ] **Шаг 6:** каркасы модулей с пустыми функциями жизненного цикла и вызовы:
  - из `coop_sync.cpp` — в том же порядке, что `survival::`;
  - из `coop_console.cpp` — `register_console`;
  - регистратор — в `script_engine_export.cpp` после `coop_script_registrator`. Он вызывает
    `checkpoints::register_lua` и `rest::register_lua`, когда в `_G` уже есть таблица `coop`.
- [ ] **Шаг 7:** внести файлы в проект:
  `python tools/vcxproj_add.py engine/src/xrGame/xrGame.vcxproj Coop coop\coop_checkpoints.cpp coop\coop_checkpoint_sources.cpp coop\coop_checkpoints_lua.cpp coop\coop_death.cpp coop\coop_rest.cpp coop\coop_autosave.cpp`,
  затем то же для `.h`.
- [ ] **Шаг 8:** компиляция → 0 ошибок:
  `tools/compile_files.sh coop/coop_script.cpp coop/coop_sync.cpp coop/coop_console.cpp coop/coop_checkpoints.cpp coop/coop_checkpoint_sources.cpp coop/coop_checkpoints_lua.cpp coop/coop_death.cpp coop/coop_rest.cpp coop/coop_autosave.cpp ../xrServerEntities/script_engine_export.cpp`.
- [ ] **Шаг 9:** коммиты:
  - движок: `Coop F3: message ids 0x01C0-0x01C6, engine-to-Lua callback queue, checkpoint/death/rest/autosave module slots`;
  - проект: `tests: F3 message names and senders`.

### Task 3: Checkpoint rules (record, slot, respawn choice, campfire dwell, custom data)

**Файлы:** создать `engine/src/xrCoop/coop_checkpoint_rules.h` и `tests/test_checkpoint_rules.cpp`.

**Интерфейсы — даёт** (`namespace coop::checkpoint`, header-only, только `<string>`, `<cmath>`, `<cstdint>`,
`<cstdio>` и `coop_wire.h`):
```cpp
enum class Kind : uint8_t { None = 0, Campfire = 1, Rest = 2, Tent = 3, Arrival = 4, Story = 5, Mod = 6 };
const char* kind_name(Kind k);           // "none","campfire","rest","tent","arrival","story","mod"
constexpr uint16_t kNoSource = 0xffff;
struct Record {
	std::string level; float pos[3] = {0, 0, 0}; uint32_t level_vertex = 0xffffffff; uint16_t game_vertex = 0xffff;
	Kind kind = Kind::None; uint16_t source = kNoSource; uint64_t game_time_ms = 0;
	bool valid() const;                  // kind != None, level_ok(level), all pos finite
};
bool level_ok(const std::string& s);     // 1..64 chars of [A-Za-z0-9_]
std::string encode(const Record& r);     // "v1|<level>|<x>|<y>|<z>|<lv>|<gv>|<kind>|<src>|<time>", %.3f
bool decode(const std::string& line, Record& out); // strict; false leaves out untouched
void write(Writer& w, const Record& r); bool read(Reader& r, Record& out);
struct Slot { Record cur, prev; };
void set(Slot& s, const Record& r);      // same kind and source as cur -> cur = r; else prev = cur, cur = r
bool source_lost(Slot& s, uint16_t source); // cur from it -> cur = prev, prev = {}; prev from it -> prev = {}; true if changed
enum class Pick : uint8_t { Current, Previous, Anchor, Arrival, Body };
struct Choice { Pick pick; float pos[3]; };
// F3: a record on another level is skipped (F3a: a transition goes here instead)
Choice resolve(const Slot& s, const std::string& level, const float* anchor, const float* arrival, const float body[3]);
struct Dwell { uint16_t source = kNoSource; uint64_t since = 0; bool fired = false; };
bool dwell_update(Dwell& d, uint16_t near, bool in_combat, uint64_t now_ms, uint32_t dwell_ms); // true once per visit
bool ini_get(const std::string& text, const char* section, const char* key, std::string& value);
void ini_set(std::string& text, const char* section, const char* key, const std::string& value);
void ini_erase(std::string& text, const char* section, const char* key);
```

- [ ] **Шаг 1: тесты** в `tests/test_checkpoint_rules.cpp`, рядом заголовок с заглушками:
  - `cp_encode_roundtrip`:
    - запись `{level "l01_escape", pos {-123.456, 7.5, 88.125}, lv 12345, gv 77, Campfire, src 4321,
      time 3600000}` проходит `encode` и `decode`;
    - все поля равны, `pos` с точностью 0.001.
  - `cp_decode_rejects` → `false`, и `out` не тронут, для каждой строки:
    - пустая; `v2|…`; 9 полей;
    - `nan` в x; уровень `l01 escape`; уровень из 65 символов;
    - вид 7; `lv` = `abc`.
  - `cp_slot_set_shift`:
    - `set(A)` → cur=A, prev пуст;
    - `set(B)` → cur=B, prev=A;
    - повторный `set` того же источника и вида, что cur → prev не меняется.
  - `cp_slot_source_lost`:
    - cur = палатка 10, prev = костёр 5 → `source_lost(10)` даёт cur = костёр, prev пуст, `true`;
    - `source_lost(99)` → `false`;
    - cur = костёр 5, prev = палатка 10 → `source_lost(10)` очищает prev, cur прежний, `true`.
  - `cp_resolve_chain`, текущий уровень `l01_escape`:
    - cur на `l02_garbage`, prev на `l01_escape` → `Previous`;
    - обе записи на другой карте, `anchor` задан → `Anchor`;
    - `anchor == nullptr`, `arrival` задан → `Arrival`;
    - ничего нет → `Body`;
    - cur на текущей карте → `Current`, позиция равна cur.
  - `cp_dwell`, источник 7, `dwell_ms` = 5000:
    - t=4999 → `false`; t=5000 → `true`; t=6000 → `false` (срабатывает один раз);
    - ушёл (`kNoSource`) на t=6500 и вернулся на t=7000 → `true` на t=12000;
    - `in_combat` на t=3000 сбрасывает отсчёт → `true` не раньше t=8000;
    - переход на источник 8 начинает отсчёт заново.
  - `cp_ini_keeps_other_sections`:
    - текст `"[coop]\nkey = abc\nnick = Bob\n"`, после `ini_set("coop_checkpoint","cur",enc)`:
      `ini_get("coop","key")` = `abc`, `ini_get("coop_checkpoint","cur")` = `enc`;
    - второй `ini_set` даёт ровно одну строку `cur`;
    - `ini_erase` её убирает;
    - значение с `|` не портится.
  - `cp_wire_roundtrip` и `cp_wire_truncated`: усечённый пакет → `read` = `false`.
- [ ] **Шаг 2:** `tools/build_tests.cmd cp_` → FAIL (утверждения).
- [ ] **Шаг 3:** реализовать функции в заголовке:
  - числа — `snprintf` и `strtod`/`strtoul` с проверкой конца строки;
  - секция в `ini_set` дописывается в конец, если её нет;
  - перевод строки — как в исходном тексте (`\r\n` или `\n`).
- [ ] **Шаг 4:** `tools/build_tests.cmd cp_` → PASS; `tools/build_tests.cmd` → PASS.
- [ ] **Шаг 5:** коммиты:
  - движок: `Coop F3: checkpoint record, slot rollback, respawn choice and campfire dwell rules`;
  - проект: `tests: checkpoint rules`.

### Task 4: Death rules (host rules wire, item loss choice, wipe, death tracker)

**Файлы:** создать `engine/src/xrCoop/coop_death_rules.h` и `tests/test_death_rules.cpp`.

**Интерфейсы — даёт** (`namespace coop::death`, header-only):
```cpp
enum class Mode : uint8_t { Checkpoint = 0, Hardcore = 1 };
enum class Drop : uint8_t { Drop = 0, Corpse = 1, Lose = 2 };
struct Rules {
	Mode mode = Mode::Checkpoint; Drop drop = Drop::Drop;
	uint32_t bleedout_ms = 60000; float revive_health = 0.3f;
	uint32_t delay_ms = 30000; uint32_t contusion_s = 600;
	uint8_t money_pct = 10, wear_pct = 10, rank_pct = 0;
	bool operator==(const Rules& o) const; void write(Writer& w) const;
	bool read(Reader& r); // unknown mode/drop or non-finite -> false; clamps: bleedout 5000..600000, revive 0.05..1,
	                      // delay 0..300000, contusion 0..3600, every pct 0..100
};
enum Category : uint8_t { Materials, Ammo, Consumables, Gear, Artefacts, Tools, Other, kCategories };
bool category_from_name(const char* name, uint8_t& out); // "materials".."other"
struct Candidate { uint16_t id; uint8_t category; };
using Shares = std::array<float, kCategories>;
// per category: floor(n*s) items + one more with probability frac(n*s); items by seeded shuffle (xorshift32)
std::vector<uint16_t> pick_losses(const std::vector<Candidate>& items, const Shares& shares, uint32_t seed);
// survival::Life numbers (coop_survival.h): 0 Alive, 1 Wounded, 2 Dead, 3 Spectating, 4 Respawning
bool is_wipe(const std::vector<uint8_t>& lives_of_present_players); // non-empty and all in {2, 3, 4}
struct Tracker { uint16_t decided_seq = 0xffff; uint64_t respawn_at = 0; bool respawn_due = false; bool hardcore_out = false; };
enum class Action : uint8_t { None, LossesAndEvacuate, Spectate };
Action on_died(Tracker& t, uint16_t seq, uint64_t now_ms, const Rules& r); // first call per seq only
bool due(Tracker& t, uint64_t now_ms);   // respawn_at reached -> true once
void on_left(Tracker& t);                // left while dead: respawn_due = true, respawn_at = 0
bool on_returned(Tracker& t);            // true once if respawn_due (not hardcore_out)
bool on_world_replaced(Tracker& t);      // true if dead/evacuating (not hardcore_out); keeps decided_seq
void on_alive(Tracker& t);               // stood up: respawn_at = 0, respawn_due = false (decided_seq stays)
```

- [ ] **Шаг 1: тесты** `tests/test_death_rules.cpp`:
  - `death_rules_wire_roundtrip` — значения по умолчанию и изменённые совпадают после `write` и `read`.
  - `death_rules_clamp`:
    - delay 999999 → 300000;
    - revive 2.0 → 1.0;
    - money 250 → 100;
    - contusion 99999 → 3600.
  - `death_rules_reject` → `false`: mode 2; drop 3; revive NaN; усечённый пакет.
  - `death_losses_counts`:
    - 10 материалов при доле 0.5 → ровно 5;
    - доля 0 → 0, доля 1 → 10;
    - 4 патрона при 0.5 и 10 материалов при 0.1 → 2 и 1, категории считаются отдельно.
  - `death_losses_fraction`: 3 предмета при доле 0.5, сиды 1..1000 → каждый раз 1 или 2, среднее 1.45..1.55.
  - `death_losses_deterministic`:
    - один сид → те же id;
    - 20 предметов, сиды 1..10 → хотя бы два разных набора.
  - `death_losses_subset`: каждый id из входа, повторов нет; пустой вход → пустой выход.
  - `death_wipe`:

    | Жизни | Результат |
    |---|---|
    | `{}` | `false` |
    | `{0,2}` | `false` |
    | `{2,4}` | `true` |
    | `{1,2}` | `false` |
    | `{3,2}` | `true` |
  - `death_tracker_once`:
    - `on_died(seq 1)` → `LossesAndEvacuate`, `respawn_at = now + delay_ms`;
    - повтор seq 1 → `None`;
    - seq 2 → `LossesAndEvacuate`.
  - `death_tracker_due`: до `respawn_at` → `false`; в момент `respawn_at` → `true`; следующий вызов → `false`.
  - `death_tracker_left_return` (Review Focus 1):
    - умер, `on_left` → `on_returned` = `true`;
    - второй `on_returned` = `false`;
    - `on_died` с тем же seq после возврата → `None`.
  - `death_tracker_world_replaced` (Review Focus 2):
    - умер → `on_world_replaced` = `true`, потом `on_died` с тем же seq → `None`;
    - живой → `false`.
  - `death_tracker_hardcore`:
    - правила Hardcore → `Spectate`, `hardcore_out = true`;
    - `on_returned` и `on_world_replaced` → `false`.
- [ ] **Шаг 2:** `tools/build_tests.cmd death_` → FAIL.
- [ ] **Шаг 3:** реализация. RNG — `xorshift32` (своя, детерминированная): `std::uniform_*` на разных платформах
  даёт разные числа.
- [ ] **Шаг 4:** `tools/build_tests.cmd death_` → PASS; весь набор → PASS.
- [ ] **Шаг 5:** коммиты:
  - движок: `Coop F3: death rules (checkpoint/hardcore, drop modes), item loss choice, wipe and death tracker`;
  - проект: `tests: death rules`.

### Task 5: Rest decision and autosave rotation rules

**Файлы:** создать `engine/src/xrCoop/coop_rest_rules.h`, `engine/src/xrCoop/coop_autosave_rules.h`,
`tests/test_rest_rules.cpp`, `tests/test_autosave_rules.cpp`.

**Интерфейсы — даёт:**
```cpp
namespace coop::rest {
enum class State : uint8_t { Awake = 0, Resting = 1, Sleeping = 2 };
const char* state_name(State s);         // "awake","resting","sleeping"
struct Member { uint16_t id; State state; uint8_t hours; bool in_combat; bool alive; };
enum class Block : uint8_t { None, NotAll, Combat, World, Dead };
struct Decision { bool start = false; uint8_t hours = 0; Block block = Block::None; };
// start: present non-empty, every member alive, Resting, not in combat, !world_blocked; hours = min(hours)
// block priority when not starting: Dead > Combat > World > NotAll
Decision decide(const std::vector<Member>& present, bool world_blocked);
uint8_t clamp_hours(int h);              // 1..24
}
namespace coop::autosave {
std::string slot_name(uint32_t index);   // "coop_auto_<index>", 1-based
bool parse_slot(const std::string& file_stem, uint32_t& index); // "coop_auto_7" -> 7; "coop_auto_0", "coop_auto_x", "x" -> false
struct SlotInfo { uint32_t index; uint64_t file_time; };
uint32_t next_slot(const std::vector<SlotInfo>& existing, uint32_t count); // first free 1..count, else the oldest
enum class Reason : uint8_t { Timer, Sleep, LevelChange, SessionEnd, Manual };
struct Schedule { uint64_t last_ms = 0; uint64_t busy_since = 0; };
// interval_min 0 = off; busy postpones up to max_postpone_ms, then due anyway; a due save sets last_ms = now
bool timer_due(Schedule& s, uint64_t now_ms, uint32_t interval_min, bool busy, uint32_t max_postpone_ms);
}
```

- [ ] **Шаг 1: тесты** `tests/test_rest_rules.cpp`:
  - `rest_all_resting_starts`: двое Resting, 8 ч и 5 ч → `start`, `hours` = 5.
  - `rest_one_awake_waits`: один Awake → не `start`, `NotAll`.
  - `rest_newcomer_blocks` (Review Focus 5): двое Resting, вошёл третий Awake → `NotAll`.
  - `rest_combat_blocks` → `Combat`; `rest_world_blocks` → `World`; `rest_dead_blocks` (alive=false) → `Dead`.
  - `rest_single_player`: один Resting, 3 ч → `start`, 3.
  - `rest_hours_clamp`: 0 → 1; 30 → 24; -5 → 1.
- [ ] **Шаг 2: тесты** `tests/test_autosave_rules.cpp`:
  - `autosave_names`: `slot_name(3)` = `coop_auto_3`; `parse_slot` отказывает на `coop_auto_0`, `coop_auto_`,
    `coop_auto_3a`, `quicksave`.
  - `autosave_next_slot_fills_gaps`: есть 1, 2, 4 при count 10 → 3.
  - `autosave_next_slot_oldest`: заняты 1..10, у 6 самый старый `file_time` → 6.
  - `autosave_next_slot_count_shrunk`: заняты 1..10 при count 5 → самый старый среди 1..5.
  - `autosave_timer`, интервал 10 мин:
    - t = 599999 мс → `false`, t = 600000 → `true`;
    - после этого `last_ms` = 600000 и следующий срок — 1200000.
  - `autosave_timer_postpone` (Review Focus 3): срок наступил, `busy` → `false`; `busy` ещё 119 с → `false`; на 120-й
    секунде при `max_postpone_ms` = 120000 → `true`.
  - `autosave_interval_zero_off`: интервал 0 → всегда `false`.
- [ ] **Шаг 3:** `tools/build_tests.cmd rest_` и `tools/build_tests.cmd autosave_` → FAIL.
- [ ] **Шаг 4:** реализация.
- [ ] **Шаг 5:** обе команды → PASS; весь набор → PASS.
- [ ] **Шаг 6:** коммиты:
  - движок: `Coop F3: shared sleep decision and autosave rotation rules`;
  - проект: `tests: rest and autosave rules`.

### Task 6: Host checkpoint store, persistence, level-change arrival, story checkpoints

**Файлы:**
- Изменить:
  - `engine/src/xrGame/coop/coop_checkpoints.{h,cpp}`, `coop_checkpoints_lua.cpp` (каркасы из Task 2);
  - `engine/src/xrGame/alife_update_manager.cpp` — врезки после `:201` и в `:224-225`.

**Интерфейсы:**
- Использует:
  - `checkpoint::*` (Task 3);
  - `queue_callback`, `Msg::CheckpointState` (Task 2);
  - `survival::life_of`, `join::host_world_epoch`, `join::peer_of_proxy`, `join::host_player_in_world`,
    `world::is_player_character`, `world::is_parked`;
  - `autosave::level_change_name()` (каркас Task 2, наполняет Task 12).
- Даёт (`namespace coop::checkpoints`):
  ```cpp
  bool host_set(u16 character, const checkpoint::Record& r);   // checks: alive, level vertex valid on this level, finite pos
  void host_source_lost(u16 source);                           // every slot using it rolls back, owner/group notified
  void host_set_arrival(u16 character, const checkpoint::Record& r); // kind Arrival; host's own also kept as "arrival"
  void host_on_level_change(const CSE_ALifeCreatureActor& actor);   // change_level hook: arrival for the host and every player in the world
  bool host_story(const char* reason);                         // kind Story at the current position of every living present player
  bool host_respawn_point(u16 character, const Fvector* anchor, const Fvector& body, Fvector& out, checkpoint::Kind& kind);
  checkpoint::Record record_here(const CGameObject* character, checkpoint::Kind kind, u16 source);
  const checkpoint::Slot* host_slot(u16 character);
  bool get(u16 local_id, checkpoint::Record& out);             // any machine: own always, others if the host shares them
  ```
- Lua: `coop.checkpoint.get(local_id)` → `nil` | `{kind, level, x, y, z, source}`, где `source` — локальный id или
  `nil`. `coop.checkpoint.story(reason)` → `bool`, только у хоста.
- Колбэк: `coop_checkpoint_changed(local_id, kind, source_local_id_or_-1, rollback, level)` — у владельца и, если
  показ группе включён, у всех.
- Консоль:
  - `coop_checkpoints_group` (0/1, по умолчанию 1) — показывать привалы группе;
  - `coop_checkpoint_status`;
  - `coop_checkpoint_here` (хост, отладка: привал вида Rest в своей позиции).

- [ ] **Шаг 1:** хранилище хоста — `xr_map<u16, checkpoint::Slot>` по id персонажа в нумерации хоста. О custom data
  знают только две внутренние функции — `bool store_slot(u16 character, const checkpoint::Slot&)` и
  `bool load_slot(u16 character, checkpoint::Slot&)`. Их и заменит переезд на API Ф2.
  - Запись сквозная: каждое изменение сразу пишется в custom data персонажа через `checkpoint::ini_set`, секция
    `coop_checkpoint`, ключи `cur` и `prev`. Персонаж: `ai().alife().objects().object(id)` → `m_ini_string`;
    у хоста — `ai().alife().graph().actor()`.
  - При смене эпохи мира (`join::host_world_epoch()` изменилась) — заново прочитать слоты:
    - актор;
    - все сущности, для которых `world::is_player_character(e)`;
    - ключ `arrival` актора.
  - Перевод `Fvector` ↔ `float[3]` и имя уровня по `game_vertex`
    (`ai().game_graph().header().level(gg.vertex(gv)->level_id()).name()`) — в `record_here`.
- [ ] **Шаг 2:** `CheckpointState`:
  - хост шлёт владельцу каждое изменение, а если `coop_checkpoints_group` = 1 — ещё и всем;
  - игроку, который только что вошёл в мир (переход `join::host_player_in_world(proxy)` в `true` между кадрами
    `frame()`), — весь список;
  - клиент хранит записи по локальному id (`join::to_local`), `get()` читает их;
  - на хосте и у получателя — колбэк `coop_checkpoint_changed`.
- [ ] **Шаг 3:** врезка в `CALifeUpdateManager::change_level` после `alife_update_manager.cpp:201` (новые
  gv/lv/pos актора уже прочитаны), до `save()` в `:231`:
  `coop::checkpoints::host_on_level_change(*graph().actor()); // Anomaly Coop: arrival checkpoints go into this save`.
  - Каждый игрок в мире получает `Arrival` в позиции хоста со сдвигом `+0.8 м × номер` по x, если там валидная
    вершина. Иначе — позиция хоста.
  - Вторая врезка, в `:224-225`: если `coop::autosave::level_change_name()` не `nullptr`, имя сейва берётся из неё
    (стоковый `<ник> - autosave` остаётся вне сессии).
- [ ] **Шаг 4:** `host_respawn_point` — через `checkpoint::resolve`. Уровень — текущий уровень хоста. `arrival` —
  ключ `arrival` актора.
- [ ] **Шаг 5:** `host_story` — для хоста и каждого прокси, у которых `life_of` = Alive и `!world::is_parked`.
  `host_source_lost` — `checkpoint::source_lost` по всем слотам. Для изменённых слотов — запись, сообщение и колбэк
  с `rollback = true`.
- [ ] **Шаг 6:** Lua в `coop_checkpoints_lua.cpp` — сырые C-функции, неверный аргумент → `nil`/`false`, как
  `coop_script.cpp:1366`. Консольные команды — в `register_console`.
- [ ] **Шаг 7:** компиляция:
  `tools/compile_files.sh coop/coop_checkpoints.cpp coop/coop_checkpoints_lua.cpp alife_update_manager.cpp` → 0;
  `tools/build_tests.cmd` → PASS.
- [ ] **Шаг 8:** в отчёт — правка `docs/CHECKPOINTS_DEATH.md` §2.1: «до API Ф2 запись лежит в custom data персонажа
  (`[coop_checkpoint] cur/prev`), переезд — план Ф3, раздел „Временное хранилище“».
- [ ] **Шаг 9:** коммиты:
  - движок: `Coop F3: host checkpoint store in the character's custom data, arrival on level change, story checkpoints`;
  - проект: `docs: checkpoint storage until the F2 player scope`.

### Task 7: Checkpoint sources on the host (campfires, tents, mod objects, rest places, combat)

> **Поправка по разведке Task 1 (2026-10-22, `docs/research/2026-10-22-f3-saves-sleep-recon.md` §B.3):** `alife_create` у клиента для объекта без родителя **не пересылается** хосту, а отбрасывается (`coop_requests.cpp:1428-1430`) — «хост найдёт ничью палатку не старше 15 с» для клиента не сработает. Палатку клиента ставит хост по просьбе игрока (форма просьбы — §B.3 отчёта; после Ф2 Task 12b — через аренду id). Хук — на `item_tent` (в GAMMA вход идёт через `use1_action_functor` → `item_tent.func_use_*`), а не на колбэк `actor_on_item_use`.

**Файлы:**
- Изменить: `engine/src/xrGame/coop/coop_checkpoint_sources.{h,cpp}`, `coop_checkpoints.cpp` (вызов `host_frame`),
  `coop_checkpoints_lua.cpp`.
- Создать: `gamedata/configs/mod_system_coop_checkpoints.ltx`.

**Интерфейсы:**
- Использует: `checkpoints::host_set`, `host_source_lost`, `record_here` (Task 6); `checkpoint::Dwell`,
  `dwell_update` (Task 3); `Msg::CheckpointClaim` (Task 2).
- Даёт (`namespace coop::checkpoints::sources`):
  ```cpp
  void host_frame(u64 now_ms);           // called by checkpoints::frame on the host
  bool in_combat(const CGameObject* character); // an online CAI_Stalker / CBaseMonster within combat_radius whose selected enemy is it
  enum class Place : u8 { None, Rest, Tent, Campfire, Mod };
  Place rest_place(u16 character, u16& source); // rest zone restrictor / own tent within tent_rest_radius / lit campfire within campfire_radius / mod source radius
  bool host_register_source(u16 id, float radius); bool host_unregister_source(u16 id);
  void host_claim_tent(u16 character, const Fvector& pos);
  void reset(); void print_status();
  ```
- Lua:
  - `coop.checkpoint.register_source(id, radius)` и `unregister_source(id)` — только хост;
  - `coop.checkpoint.claim_tent(x, y, z)` — на клиенте уходит `CheckpointClaim`.
- Колбэк владельцу: `coop_checkpoint_refused(reason)` — `"combat"`, `"dead"`, `"far"`.

- [ ] **Шаг 1:** `mod_system_coop_checkpoints.ltx`:
  ```
  [coop_checkpoints]
  campfire_radius   = 3
  campfire_dwell_ms = 5000
  combat_radius     = 50
  tent_sections     = ph_tent, ph_sleepbag
  tent_rest_radius  = 2
  tent_claim_radius = 4
  tent_claim_ms     = 15000
  cover_list        = misc\surge_manager.ltx   ; section [list]: stock surge covers (294)

  [coop_rest_zones]   ; stock sleep restrictors, ui_sleep_dialog.script:292-318
  actor_surge_hide_2
  agr_army_sleep
  agr_sr_sleep_tunnel
  agr_sr_sleep_wagon
  bar_actor_sleep_zone
  cit_merc_sleep
  ds_farmhouse_sleep
  esc_basement_sleep_area
  esc_secret_sleep
  gar_angar_sleep
  gar_dolg_sleep
  jup_a6_sr_sleep
  mar_a3_sr_sleep
  mil_freedom_sleep
  mil_smart_terran_2_4_sleep
  pri_a16_sr_sleep
  pri_monolith_sleep
  pri_room27_sleep
  rad_sleep_room
  ros_vagon_sleep
  val_abandoned_house_sleep
  val_vagon_sleep
  yan_bunker_sleep_restrictor
  zat_a2_sr_sleep
  pol_secret_sleep
  ```
- [ ] **Шаг 2:** кэш раз в 1 с.
  - Список костров — объекты уровня, где `smart_cast<CZoneCampfire*>`, плюс зарегистрированные объекты модов.
  - Палатки секций `tent_sections` с временем первого появления.
  - Отображение «id рестриктора → имя» строится при смене эпохи мира: из ALife по `name_replace()` и спискам
    `[coop_rest_zones]` и `[list]` файла `cover_list` (`CInifile` по `$game_config$`).
- [ ] **Шаг 3:** раз в 500 мс для хоста и каждого прокси в мире (`join::host_player_in_world`) с `life_of` = Alive:
  - ближайший горящий костёр (`is_on()`) или объект мода в радиусе;
  - `dwell_update(dwell[character], near, in_combat(obj), now, campfire_dwell_ms)`;
  - на `true` — `checkpoints::host_set(character, record_here(obj, Kind::Campfire или Kind::Mod, source))`.
- [ ] **Шаг 4:** палатки.
  - `host_claim_tent` и `CheckpointClaim` от клиента (позиция проходит `validate::finite3`; персонаж —
    `join::proxy_of_peer(from)`, не из пакета) кладут заявку на `tent_claim_ms`.
  - Заявка закрывается первой ничьей палаткой не дальше `tent_claim_radius` от позиции, увиденной не раньше чем за
    `tent_claim_ms`. Владелец → `host_set(Kind::Tent)`.
  - Отказ (в бою, мёртв) → колбэк `coop_checkpoint_refused`.
- [ ] **Шаг 5:** раз в 1 с — проверка существования каждого источника из слотов и списка модов:
  `ai().alife().objects().object(id, true) == nullptr` → `checkpoints::host_source_lost(id)`.
- [ ] **Шаг 6:** `in_combat` и `rest_place`.
  - `in_combat`: онлайн-`CAI_Stalker` с `memory().enemy().selected() == character` или `CBaseMonster` с
    `EnemyMan.get_enemy() == character` в радиусе `combat_radius`.
  - `rest_place`: рестриктор — `smart_cast<CSpaceRestrictor*>(obj)->inside(Fsphere{pos, 0.3f})`
    (`space_restrictor.h:59`).
- [ ] **Шаг 7:** компиляция:
  `tools/compile_files.sh coop/coop_checkpoint_sources.cpp coop/coop_checkpoints.cpp coop/coop_checkpoints_lua.cpp` → 0.
- [ ] **Шаг 8:** коммиты:
  - движок: `Coop F3: host finds checkpoint sources (lit campfires, own tents, mod objects, rest zones) and combat`;
  - проект: `gamedata: checkpoint source settings and the stock sleep zones`.

### Task 8: Death flow — checkpoint/hardcore modes, evacuation, respawn at the own checkpoint

**Файлы:**
- Изменить: `engine/src/xrGame/coop/coop_survival.{h,cpp}`.
- Создать: `gamedata/configs/text/{eng,rus}/st_coop_survival.xml`.

**Интерфейсы:**
- Использует: `death::Rules`, `Tracker`, `is_wipe` (Task 4); `checkpoints::host_respawn_point` (Task 6);
  `death::host_apply_losses` (Task 9); `script::queue_callback` (Task 2).
- Даёт:
  - `survival::Rules` заменён на `death::Rules`. `PlayerRules` несёт `death::Rules::write`.
  - Колбэки:
    - `coop_respawned(kind, contusion_s, money_pct, rank_pct)` — владельцу;
    - `coop_group_wipe()` — хосту, один раз за вайп.
  - `PlayerRevive`:
    - новый `OpEvacuate = 5 {u16 target, u16 seq, u32 delay_ms}`;
    - `OpRespawn = {u16 target, u16 seq, vec3 pos, u8 checkpoint kind}` — байт `drop` убран.
- Консоль хоста:

  | Переменная | Значения | По умолчанию |
  |---|---|---|
  | `coop_death_mode` | `checkpoint`, `hardcore`; синонимы `respawn`, `respawn_keep` → `checkpoint` | `checkpoint` |
  | `coop_death_drop` | `drop`, `corpse`, `lose` | `drop` |
  | `coop_respawn_delay` | 0..300 с | 30 |
  | `coop_contusion` | 0..60 мин | 10 |
  | `coop_death_money` | 0..100 % | 10 |
  | `coop_death_wear` | 0..100 % | 10 |
  | `coop_death_rank` | 0..100 % | 0 |

  `coop_bleedout` и `coop_revive_health` — без изменений.

- [ ] **Шаг 1:** заменить правила и токены.
  - `DeathMode`, `Rules`, `console_rules`, `mode_name` (`coop_survival.cpp:104-175`) → `death::Rules`.
  - `coop_survival.h:53-58` → `death::Mode` / `death::Drop`.
  - Токены `g_death_mode_tokens`: `checkpoint`, `hardcore`, `respawn` (= Checkpoint), `respawn_keep`
    (= Checkpoint).
- [ ] **Шаг 2:** решение хоста на смерть.
  - `HostRec` получает `death::Tracker`; `host_on_died` `:884-903` → `death::on_died`.
  - `LossesAndEvacuate`:
    - `death::host_apply_losses(id, seq, rules.drop)`;
    - `OpEvacuate` владельцу;
    - через `Tracker::due` — `OpRespawn` с точкой `checkpoints::host_respawn_point(id, anchor, body)`. `anchor`
      берётся из `HostRec`, `body` — позиция тела.
  - `Spectate` — как сейчас (`host_order_spectate`).
  - `pick_respawn_point` `:843-882` удалить.
- [ ] **Шаг 3:** вайп. После каждого решения хост собирает `life` всех присутствующих: сам, `g_players` без
  `world::is_parked`. Если `death::is_wipe` — колбэк `coop_group_wipe` один раз, пока хоть кто-то не станет Alive.
- [ ] **Шаг 4:** Review Focus 1 и 2.
  - Уход игрока (`host_frame` `:1011-1024`) → `death::on_left` вместо обнуления `respawn_at`.
  - Возврат (`host_on_state(Alive)` от вернувшегося, у которого `respawn_due`) → сразу `OpRespawn` на привал.
  - Смена эпохи мира `:992-999`: перед `g_host.clear()` запомнить персонажей, у которых `on_world_replaced` = `true`.
    После их возвращения в мир — `OpRespawn` на привал. Это точка прибытия: её поставила Task 6. Вещи второй раз не
    отбираются.
- [ ] **Шаг 5:** у владельца.
  - `apply_respawn` `:679-699`: без `drop_carried_items`, функция `:637-660` удалена.
  - Износ: `ChangeCondition(-wear_pct / 100.f)` у предметов в слотах `KNIFE_SLOT`, `INV_SLOT_2`, `INV_SLOT_3`,
    `OUTFIT_SLOT`, `HELMET_SLOT`. Кондиция уходит хосту штатно через `ItemState` (WP9).
  - После `finish_respawn` — колбэк `coop_respawned(checkpoint::kind_name(kind), contusion_s, money_pct, rank_pct)`.
  - Состояние Dead по `OpEvacuate`:
    - камера на живом союзнике — существующий `spectate_frame`;
    - если живых нет — новый эффектор `OverheadCam`, id `0x434F4F03`: 6 м над телом, взгляд вниз, медленный поворот.
  - Строки HUD в `build_hud` `:1326-1394` через `CStringTable().translate`:

    | Строка | eng | rus |
    |---|---|---|
    | `st_coop_evac_title` | You were pulled out... | Тебя вытащили... |
    | `st_coop_evac_wait` | Back at your camp in %d s | Возвращение на привал через %d с |
    | `st_coop_evac_watch` | Watching: %s | Смотришь: %s |
    | `st_coop_evac_no_allies` | Nobody is left alive. The world is not rolled back. | Живых не осталось. Мир не откатывается. |
- [ ] **Шаг 6:** Review Focus 3. Хост — персонаж 0, тот же путь: `host_send_order(0, w)` применяет приказ локально.
  Проверка без игры — чтение кода: ветки `id == 0` в `host_on_died`, `host_frame`, `apply_respawn` не расходятся с
  клиентскими. Живая проверка — сценарий 19.8 (`coop_wound_me`, затем удерживать USE 3 с — сдаться).
- [ ] **Шаг 7:** проверки:
  - `tools/compile_files.sh coop/coop_survival.cpp coop/coop_presence.cpp coop/coop_script.cpp` → 0;
  - `tools/build_tests.cmd` → PASS;
  - `python -m pytest tests/tools/test_strings.py -q` → PASS.
- [ ] **Шаг 8:** в отчёт — правка `docs/CHECKPOINTS_DEATH.md` §3.2: «старые `respawn` / `respawn_keep` в консоли —
  синонимы `checkpoint`».
- [ ] **Шаг 9:** коммиты:
  - движок: `Coop F3: checkpoint and hardcore death modes, evacuation delay with ally camera, respawn at the own checkpoint, wipe`;
  - проект: `text: evacuation lines (st_coop_evac_*)`.

### Task 9: Host-side item loss on death (drop / corpse / lose), death stash, death marker

**Файлы:**
- Изменить: `engine/src/xrGame/coop/coop_death.{h,cpp}`.
- Создать: `gamedata/configs/mod_system_coop_death.ltx`.

**Интерфейсы:**
- Использует: `death::pick_losses`, `Category`, `Shares`, `category_from_name` (Task 4); `Msg::DeathMarker`,
  `queue_callback` (Task 2).
- Даёт (`namespace coop::death`, `coop_death.h`):
  ```cpp
  u32 host_apply_losses(u16 character, u16 seq, Drop mode); // items moved/destroyed; sends DeathMarker
  u16 host_move_to_stash(u16 character, bool everything);   // Corpse and Task 10: new coop_death_stash at the body, returns its id
  void host_preview(u16 character);                        // console: logs what would go, moves nothing
  ```
- Колбэк всем: `coop_death_marker(player_local_id, marker_local_id, drop)`, где `drop` — `"drop"` или `"corpse"`.
- Консоль хоста: `coop_death_preview`.

- [ ] **Шаг 1:** `mod_system_coop_death.ltx`:
  ```
  [coop_death_drop]          ; share of the backpack lost per category (drop: falls out, lose: gone)
  materials   = 0.5
  ammo        = 0.5
  consumables = 0.5
  gear        = 0.25
  artefacts   = 0.1
  tools       = 0.1
  other       = 0.25

  [coop_death_kinds]         ; item ltx `kind` -> category
  i_part = materials
  i_mutant_raw = materials
  i_mutant_part = materials
  i_mutant_cooked = materials
  i_arty_junk = materials
  i_misc = materials
  w_ammo = ammo
  i_food = consumables
  i_drink = consumables
  i_medical = consumables
  i_arty = artefacts
  i_arty_cont = artefacts
  i_mutant_belt = artefacts
  i_tool = tools
  i_kit = tools
  i_repair = tools
  i_upgrade = tools
  i_device = tools
  i_attach = tools
  w_pistol = gear
  w_rifle = gear
  w_smg = gear
  w_shotgun = gear
  w_sniper = gear
  w_misc = gear

  [coop_death_stash]:inv_backpack
  ```
- [ ] **Шаг 2:** кандидаты.
  - Берутся из `inventory().m_ruck` персонажа на хосте: актор или прокси `CAI_Stalker`.
  - Исключаются `IsQuestItem()`, `kind` `i_quest` / `i_letter` и КПК.
  - Категория:
    - `CWeaponAmmo` → `Ammo`;
    - иначе `kind` по `[coop_death_kinds]`;
    - броня и шлемы в рюкзаке (`CCustomOutfit`, `CHelmet`) → `Gear`;
    - остальное → `Other`.
  - Сид: `character ^ (u32(seq) << 16) ^ u32(alife().time_manager().game_time())`.
- [ ] **Шаг 3:** действия на хосте событиями движка, как сделка хоста над прокси (`coop_trade.cpp`, «ownership
  mirror» доводит их до владельца):
  - `Drop` — `GE_OWNERSHIP_REJECT` от персонажа на каждый выбранный предмет; маркер — первый выпавший.
  - `Lose` — `DestroyObject()`, как аптечка в `coop_survival.cpp:968`; маркера нет.
  - `Corpse` — `host_move_to_stash(character, false)`:
    - `alife_rw().spawn_item("coop_death_stash", pos, lv, gv, kNoId)`;
    - перенос, когда объект тайника появился онлайн (ждать до 5 с), парой `GE_TRADE_SELL` от персонажа и
      `GE_TRADE_BUY` тайнику, как `move_item_from_to` в `ui/UIActorMenuDeadBodySearch.cpp:22-34`;
    - маркер — тайник.
- [ ] **Шаг 4:** Review Focus 4. Перед выпадением проверить позицию тела. Если `level_vertex` персонажа невалиден
  или тело ниже вершины больше чем на 1 м, выбросить в точке вершины +0.3 м (`ai().level_graph().vertex_position`):
  событием `GE_CHANGE_POS` сразу после `REJECT`, путь `inventory_item.cpp:277-290`. Живая проверка — сценарий 19.9.
- [ ] **Шаг 5:** `DeathMarker` всем и колбэк `coop_death_marker` на хосте. Клиент переводит id в локальные
  (`join::to_local`) и тоже зовёт колбэк.
- [ ] **Шаг 6:** компиляция `tools/compile_files.sh coop/coop_death.cpp` → 0; `tools/build_tests.cmd` → PASS.
- [ ] **Шаг 7:** в отчёт — правка `docs/CHECKPOINTS_DEATH.md` §3.3: «`corpse` — тайник-рюкзак `coop_death_stash`
  у тела (решение плана 3); доли и категории — `mod_system_coop_death.ltx`».
- [ ] **Шаг 8:** коммиты:
  - движок: `Coop F3: host drops, stashes or destroys a share of a dead player's backpack by ltx categories, death marker`;
  - проект: `gamedata: death loss shares, item kinds and the death stash`.

### Task 10: Hardcore — the character is out, the player starts a new one

**Файлы:**
- Изменить:
  - `engine/src/xrGame/coop/coop_survival.cpp`, `coop_death.cpp`;
  - `coop_join.{h,cpp}` (+ `host_rejoin_peer`);
  - `gamedata/scripts/coop_menu_char.script` (ветка хоста);
  - `gamedata/configs/text/{eng,rus}/st_coop_survival.xml`.

**Интерфейсы:**
- Использует: `death::Tracker.hardcore_out` (Task 4), `death::host_move_to_stash` (Task 9), `Msg::NewCharacter`
  (Task 2).
- Даёт:
  - `bool join::host_rejoin_peer(PeerId peer, const char* why);` — `SessionReset` с текущей эпохой одному пиру;
  - колбэк хосту `coop_host_new_character()`;
  - консоль `coop_new_character`.

- [ ] **Шаг 1:** в состоянии Spectating при `hardcore_out` HUD показывает:

  | Строка | eng | rus |
  |---|---|---|
  | `st_coop_hardcore_out` | Your character is gone. | Твой персонаж погиб окончательно. |
  | `st_coop_hardcore_new_hold` | Hold USE for 3 s to start a new character | Удерживай «Использовать» 3 с — новый персонаж |

  Удержание USE 3 с (как `kGiveUpHoldMs`) или `coop_new_character`:
  - у клиента → `NewCharacter`;
  - у хоста → локально.
- [ ] **Шаг 2:** хост, `NewCharacter` от клиента. Персонаж — `join::proxy_of_peer(from)`. Требуется
  `tracker.hardcore_out`, иначе отказ в лог. Действия:
  1. `death::host_move_to_stash(proxy, true)` — всё снаряжение, включая надетое и квестовое, плюс `DeathMarker`;
  2. в custom data прокси убрать строку `key` секции `[coop]` и дописать `retired = 1`;
  3. `join::host_rejoin_peer(peer, "new character")`, затем `alife_rw().release(proxy)`.

  Клиент входит заново, `find_proxy_by_key` ничего не находит → `create_proxy` → окно нового персонажа
  `coop_menu_char`.
- [ ] **Шаг 3:** `host_rejoin_peer`. Пир помечается `loading`, `sync::host_begin_join(peer)`, `SessionReset`
  `{why, g.epoch}` уходит только ему. Проверить, что `client_on_session_reset` (`coop_join.cpp:475-505`) и гейт входа
  (лимит 1 вход в 5 с) принимают ту же эпоху. Если нет — отправлять после истечения лимита.
- [ ] **Шаг 4:** хост, свой новый персонаж:
  1. `host_move_to_stash(0, true)`;
  2. актор: здоровье 1, радиация 0, кровотечение снято, сытость 1, выносливость 1, деньги 0;
  3. позиция — `arrival` хоста (Task 6);
  4. колбэк `coop_host_new_character()`.

  В `coop_menu_char.script`: на этот колбэк хост открывает `UICoopNewChar` и применяет набор к `db.actor` той же
  функцией `apply_kit` (`:215`). Хост сам себе авторитет.
- [ ] **Шаг 5:** проверки:
  - `tools/compile_files.sh coop/coop_survival.cpp coop/coop_death.cpp coop/coop_join.cpp` → 0;
  - `tools/test_lua.cmd menu_char` → PASS (если набора нет — `tools/test_lua.cmd` целиком);
  - `python -m pytest tests/tools/test_strings.py -q` → PASS.
- [ ] **Шаг 6:** в отчёт — `docs/MOD_REPLACEMENTS.md`: «208 Ironman Roguelite» → статус «сделано».
- [ ] **Шаг 7:** коммиты:
  - движок: `Coop F3: hardcore — the dead character is retired with its gear in a stash, the player rejoins as a new character`;
  - проект: `Coop menu: the host picks a new character after a hardcore death`.

### Task 11: Shared sleep on the host (consent, time skip for everyone, autosave)

**Файлы:** изменить `engine/src/xrGame/coop/coop_rest.{h,cpp}`.

**Интерфейсы:**
- Использует:
  - `rest::decide`, `clamp_hours`, `State` (Task 5);
  - `sources::rest_place`, `in_combat` (Task 7); `checkpoints::host_set`, `record_here` (Task 6);
  - `autosave::request(Reason::Sleep)` (Task 12);
  - `worldstate::intercept_time_jump` (`coop_worldstate.h:31-35`);
  - `Msg::RestRequest`, `RestState`, `RestSleep` (Task 2).
- Даёт:
  - `rest::State rest::state_of(u16 local_id);`
  - `void rest::host_cancel(u16 character, const char* reason);`
  - Lua (`coop.rest`):
    - `lie_down(hours, forced)`, `get_up()`;
    - `state_of(local_id)` → `"awake"` | `"resting"` | `"sleeping"`;
    - `hours_of(local_id)`;
    - `waiting_for()` → массив ников, кто не отдыхает;
    - `set_world_block(reason)` — хост, `""` снимает.
  - Колбэки:
    - `coop_rest_changed(local_id, state, hours)` — всем;
    - `coop_rest_sleep(hours)` — всем;
    - `coop_rest_refused(reason)` — владельцу, `reason`: `"place"`, `"combat"`, `"dead"`, `"busy"`.
  - Консоль: `coop_rest_status`.

- [ ] **Шаг 1:** запрос «лёг», `RestRequest` op 1 или локальный у хоста.
  - Лимит — 1 запрос в секунду на пира.
  - Часы — `clamp_hours`.
  - Проверки:
    - `life_of` = Alive, иначе `dead`;
    - без `forced`: не `in_combat`, иначе `combat`;
    - без `forced`: `rest_place` ≠ None, иначе `place`.
  - Если проверки прошли и запрос без `forced` — `checkpoints::host_set(character, record_here(obj, kind, source))`.
    Вид: Rest, Tent, Campfire или Mod — из `Place`.
  - Состояние → Resting, `RestState` всем.
  - `forced` (обморок от усталости) — Resting без привала и без проверки места.
- [ ] **Шаг 2:** «встал», op 2 — Awake, `RestState`. Отдыхающий попал в бой (`in_combat`), умер или ушёл →
  `host_cancel` + колбэк владельцу.
- [ ] **Шаг 3:** раз в 500 мс — `decide(присутствующие, world_block)`. Присутствующие — хост и прокси в мире без
  `hardcore_out`. При `start`:
  1. всем `Sleeping`;
  2. `worldstate::intercept_time_jump(0, hours, 0)` — у хоста только помечает TimeSync;
  3. сам скачок, как `change_game_time` в `level_script.cpp:329-342`:
     `g_pGamePersistent->Environment().ChangeGameTime(float(hours*3600))` и
     `ai().alife().time_manager().change_game_time(u32(hours)*3600*1000)`;
  4. `RestSleep{hours}` всем и колбэк `coop_rest_sleep` на хосте;
  5. `autosave::request(Reason::Sleep)`;
  6. через 12 с — всем Awake.
- [ ] **Шаг 4:** `RestState` раз в 5 с и при изменении. Клиент хранит состояния для `state_of`, `hours_of`,
  `waiting_for` и зовёт `coop_rest_changed` на изменение.
- [ ] **Шаг 5:** Review Focus 2. Смена эпохи мира или `reset()` → все Awake. Колбэки `coop_rest_changed(…, "awake")`
  уходят после возвращения в мир, чтобы окно дрёмы закрылось.
- [ ] **Шаг 6:** компиляция `tools/compile_files.sh coop/coop_rest.cpp` → 0; `tools/build_tests.cmd` → PASS.
- [ ] **Шаг 7:** в отчёт — правка `docs/CHECKPOINTS_DEATH.md` §4: «часы сна — минимум из выбранных; обморок от
  усталости — отдых без привала».
- [ ] **Шаг 8:** коммит (движок): `Coop F3: shared sleep — the host skips time only when every player rests, then autosaves`.

### Task 12: Host autosaves with rotation (timer, after sleep, level change, session end)

**Файлы:**
- Изменить: `engine/src/xrGame/coop/coop_autosave.{h,cpp}`, `coop_manager.cpp` (`Manager::stop` `:392-401`).

**Интерфейсы:**
- Использует: `autosave::*` правила (Task 5), `survival::life_of(0)`.
- Даёт (`namespace coop::autosave`):
  ```cpp
  void request(Reason r);             // host in a session: save at the next safe frame
  const char* level_change_name();    // host in a session: "coop_auto_N" (slot taken now); else nullptr
  void host_on_session_end();         // Manager::stop on the host, before shutdown
  ```
- Консоль:

  | Команда | Значения |
  |---|---|
  | `coop_autosave_interval` | мин, 0..120, по умолчанию 10; 0 — выключено |
  | `coop_autosave_count` | 1..50, по умолчанию 10 |
  | `coop_autosave_now` | — |

- [ ] **Шаг 1:** слоты — `FS.file_list_open("$game_saves$", FS_ListFiles)`, затем фильтр
  `parse_slot(<имя без .scop>)` и время файла. Следующее имя — `next_slot(existing, count)`.
- [ ] **Шаг 2:** сохранение — `Console->Execute("save coop_auto_N")` в главном потоке. Хост не клиент, гейт
  `console_commands.cpp:1094` пропускает. `busy`, если `survival::life_of(0) != Life::Alive`,
  `Device.dwPrecacheFrame` или `rest::state_of(0) == State::Sleeping`. Таймер — `timer_due(schedule, now, interval,
  busy, 120000)`.
- [ ] **Шаг 3:** `level_change_name` используется во врезке Task 6 (`alife_update_manager.cpp:224-225`).
  `host_on_session_end` — строкой в `Manager::stop` перед `m_session.shutdown`. Перед этим проверить все вызовы
  `Manager::stop`: если он зовётся из разрушения уровня, сейв там не писать (условия `g_pGameLevel`, `g_actor`,
  `ai().get_alife()`, уровень не выгружается).
- [ ] **Шаг 4:** компиляция `tools/compile_files.sh coop/coop_autosave.cpp coop/coop_manager.cpp` → 0;
  `tools/build_tests.cmd autosave_` → PASS.
- [ ] **Шаг 5:** коммит (движок): `Coop F3: host autosaves coop_auto_N (timer, after sleep, level change, session end), rotation of 10`.

### Task 13: Lua checkpoints — story checkpoints, tent claims, tips, PDA spots, party panel mark

> **Поправка по разведке Task 1 (2026-10-22, `docs/research/2026-10-22-f3-saves-sleep-recon.md` §B.3):** `alife_create` у клиента для объекта без родителя **не пересылается** хосту, а отбрасывается (`coop_requests.cpp:1428-1430`) — «хост найдёт ничью палатку не старше 15 с» для клиента не сработает. Палатку клиента ставит хост по просьбе игрока (форма просьбы — §B.3 отчёта; после Ф2 Task 12b — через аренду id). Хук — на `item_tent` (в GAMMA вход идёт через `use1_action_functor` → `item_tent.func_use_*`), а не на колбэк `actor_on_item_use`.

**Файлы:**
- Создать:
  - `gamedata/scripts/coop_checkpoints.script`;
  - `gamedata/configs/text/{eng,rus}/st_coop_checkpoints.xml`;
  - `tests/lua/test_checkpoints.lua`.
- Изменить: `gamedata/scripts/coop_allies.script` (метка «привал обновлён» в панели группы).

**Интерфейсы:**
- Использует:
  - `coop.checkpoint.get`, `story`, `claim_tent` (Tasks 6, 7);
  - колбэки `coop_checkpoint_changed`, `coop_checkpoint_refused`;
  - отчёт Task 1 §B.
- Даёт: `coop_checkpoints.last_update(local_id) -> time_global() ms | nil` — для панели группы.

- [ ] **Шаг 1: тесты** `tests/lua/test_checkpoints.lua`. Режимы `host` и `client`, заглушки `coop.checkpoint` и
  `level.map_*` объявлены в самом файле:
  - `story_calls_engine`: в сессии у хоста `xr_effects.scenario_autosave(nil, nil, {"st_save_x"})` вызывает
    `coop.checkpoint.story("st_save_x")`, а `exec_console_cmd("save …")` не вызывается.
  - `story_outside_session_original`: без сессии зовётся исходная функция.
  - `changed_own_tip_and_spot`:
    - `coop_checkpoint_changed(0, "campfire", 123, false, "l01_escape")` → `MSG` = перевод
      `st_coop_cp_updated_campfire`;
    - метка `ui_pda2_actor_sleep_location` на 123;
    - после колбэка с источником 124 метка на 123 снята.
  - `changed_rollback_tip`: `rollback = true` → `st_coop_cp_rollback`.
  - `arrival_no_spot`: вид `arrival` (источник -1) → подсказка есть, метки нет.
  - `group_spot`: колбэк про союзника → метка на источнике с подсказкой `st_coop_cp_ally` и его ником.
  - `tent_claim_sent`: `actor_on_item_use` с секцией `itm_tent` → через `CreateTimeEvent` 6 с
    `coop.checkpoint.claim_tent(x, y, z)` с позицией актора.
  - `refused_tip`: `coop_checkpoint_refused("combat")` → `st_coop_cp_refused_combat`.
- [ ] **Шаг 2:** `tools/test_lua.cmd checkpoints` → FAIL.
- [ ] **Шаг 3:** `coop_checkpoints.script`. `on_game_start`:
  - `AddScriptCallback` для двух колбэков движка и регистрация обработчиков;
  - обёртка `xr_effects.scenario_autosave`;
  - `actor_on_item_use` для `itm_tent`, `itm_sleepbag`, `sleep_bag` — по входам из отчёта Task 1 §B.

  Тексты на eng и rus:
  - `st_coop_cp_updated_campfire`, `_rest`, `_tent`, `_arrival`, `_story`, `_mod`;
  - `st_coop_cp_rollback`, `st_coop_cp_ally`, `st_coop_cp_refused_combat`, `_dead`, `_far`.

  Метки снимаются, когда меняется источник.
- [ ] **Шаг 4:** `coop_allies.script`: 10 с после `last_update` в строке игрока на панели — краткая пометка
  `st_coop_cp_panel` («привал»).
- [ ] **Шаг 5:** `tools/test_lua.cmd checkpoints` → PASS; `tools/test_lua.cmd` целиком → PASS;
  `python -m pytest tests/tools/test_strings.py -q` → PASS.
- [ ] **Шаг 6:** в отчёт:
  - `docs/MOD_REPLACEMENTS.md`:
    - «203 YACS Better Campfire Saves» и «G.A.M.M.A. YACS no quit» → «сделано»;
    - новая строка «`xr_effects.scenario_autosave` (сток) — в коопе ставит сюжетный привал всем живым вместо сейва —
      заменено — сделано».
  - `docs/CHECKPOINTS_DEATH.md` §2.3: «у точки прибытия и сюжетного привала метки КПК нет (решение плана 7)».
- [ ] **Шаг 7:** коммит (проект): `Coop checkpoints: story checkpoints, tent claims, tips, PDA spots and the party panel mark`.

### Task 14: Lua shared sleep — stock sleep dialog in co-op, doze window, prompts, sleep effects

**Файлы:**
- Создать:
  - `gamedata/scripts/coop_rest.script`, `gamedata/configs/ui/ui_coop_rest.xml`;
  - `gamedata/configs/text/{eng,rus}/st_coop_rest.xml`;
  - `tests/lua/test_rest.lua`.
- Изменить:
  - `gamedata/scripts/coop_allies.script` — статус отдыха в панели;
  - `gamedata/scripts/coop_economy_group.script` — убрать `patch_sleep` (`:435-462`) и вид `sleep` из голосования.
    Голосование `economy.propose/vote/ballot/verdict` остаётся для `wait` (GAMMA Books Pass Time) и `travel`;
  - `tests/lua/test_economy.lua` — раздел «group: sleep vote» (`:134-180`).

**Интерфейсы:**
- Использует:
  - `coop.rest.*` и колбэки `coop_rest_changed`, `coop_rest_sleep`, `coop_rest_refused` (Task 11);
  - отчёт Task 1 §B.

- [ ] **Шаг 1: тесты** `tests/lua/test_rest.lua`. Заглушки `ui_sleep_dialog.UISleep`, `level.change_game_time`,
  `exec_console_cmd` — в файле:
  - `sleep_button_asks_engine`: в сессии `UISleep:OnButtonSleep()` с ползунком 6 →
    - `coop.rest.lie_down(6, false)`;
    - `level.change_game_time` не вызывался;
    - сейва нет;
    - окно дрёмы открыто.
  - `forced_sleep_dozes`: `ui_sleep_dialog.sleep_forced(4)` → `lie_down(4, true)`.
  - `shelter_check_skipped_in_session`: в сессии `TestAndShow` вне укрытия и без палатки открывает диалог. Проверки
    кровотечения и радиации остаются.
  - `outside_session_stock`: без сессии исходные функции, `change_game_time` вызывается.
  - `sleep_event_runs_stock_effects`: `coop_rest_sleep(5)` и затем `coop_rest.dream_end()` →
    - `actor_on_sleep` отправлен с 5;
    - `db.actor.power == 1`;
    - `change_game_time` не вызывался;
    - окно закрыто;
    - `actor_is_sleeping` снят.
  - `prompt_for_others`: `coop_rest_changed(7, "resting", 8)` про союзника → `st_coop_rest_prompt` с его ником и 8.
  - `doze_clears_sleep_active`: при открытии окна дрёмы снимается `sleep_active` (иначе у хоста замирают
    `CreateTimeEvent`, `_g.script:364-367`) и выдаётся `actor_is_sleeping` (машинно-локальная инфо, `coop_rules.h`).
  - `world_block_reports_emission`: у хоста идёт выброс → `coop.rest.set_world_block("emission")`; выброс кончился →
    `""`.
  - `refused_tip`: `coop_rest_refused("place")` → `st_coop_rest_refused_place`.
- [ ] **Шаг 2:** `tools/test_lua.cmd rest` → FAIL.
- [ ] **Шаг 3:** `coop_rest.script` — обёртки `ui_sleep_dialog` в сессии:
  - `UISleep.TestAndShow` — без проверки укрытия;
  - `UISleep.OnButtonSleep` → `lie_down` + окно;
  - `sleep_forced` → `lie_down(h, true)`;
  - `sleep_bag` — через `TestAndShow`.

  Окно `UICoopDoze` (`ui_coop_rest.xml`):
  - затемнение;
  - строка «Ждём: <ники>» из `coop.rest.waiting_for()`, раз в 1 с;
  - причина блокировки (`st_coop_rest_block_combat`, `_world`);
  - кнопка «Встать» и ESC/USE → `coop.rest.get_up()`.

  Последовательность сна по `coop_rest_sleep` — как `ui_sleep_dialog.script:153-261`, без `change_game_time` и без
  сейва. Колбэк конца камерного эффектора — `coop_rest.dream_end` (публичная функция модуля). У хоста `actor_on_update` раз в 1 с: выброс (`surge_manager.is_started` / `psi_storm_manager.is_started`) →
  `set_world_block`.
- [ ] **Шаг 4:** `coop_allies.script`: в строке игрока `st_coop_rest_panel` («отдыхает %d ч»), пока
  `coop.rest.state_of(id) == "resting"`.
- [ ] **Шаг 4a:** `coop_economy_group.script`.
  - Убрать `patch_sleep` и вид `sleep` в `KINDS`, `propose` его больше не принимает.
  - `coop_mods_misc.with_party_sleepiness` (W5) звался только из `patch_sleep`. Если он делает больше, чем эффекты сна
    на своей машине, `coop_rest.dream_end` зовёт его вокруг стоковых эффектов. Иначе вызов не нужен.
  - В `test_economy.lua` раздел «group: sleep vote» заменить двумя проверками:
    - сон клиента не открывает голосование — уходит в `coop.rest.lie_down`;
    - `wait` голосуется по-прежнему.
- [ ] **Шаг 5:** `tools/test_lua.cmd rest` → PASS; весь набор → PASS; строки → PASS.
- [ ] **Шаг 6:** в отчёт — `docs/MOD_REPLACEMENTS.md`, новая строка: «Сон стока (`ui_sleep_dialog`) — в коопе общий
  сон: время идёт, только когда отдыхают все — заменено — сделано».
- [ ] **Шаг 7:** коммит (проект): `Coop rest: stock sleep becomes shared rest, doze window, prompts, sleep effects on every machine`.

### Task 15: Lua death — contusion, money and rank penalty, death marker spots, host rules page

**Файлы:**
- Создать:
  - `gamedata/scripts/coop_death.script`;
  - `gamedata/configs/text/{eng,rus}/st_coop_death.xml`;
  - `tests/lua/test_death.lua`.
- Изменить: `gamedata/scripts/coop_menu_options.script` (группа `coop_session`).

**Интерфейсы:**
- Использует:
  - колбэки `coop_respawned`, `coop_death_marker` (Tasks 8, 9);
  - консольные переменные Task 8 и Task 12.

- [ ] **Шаг 1: тесты** `tests/lua/test_death.lua`:
  - `contusion_applies_and_ends`:
    - `coop_respawned("campfire", 600, 10, 0)` → `level.add_pp_effector("blur.ppe", 39570, true)`;
    - `conditions():SetMaxPower(0.6)`;
    - через 600 с `time_global` → `remove_pp_effector(39570)` и `SetMaxPower(1)`.
  - `contusion_zero_nothing`: 0 с → эффекторов нет.
  - `money_penalty`: денег 1234, 10 % → `give_money(-123)`; денег 0 → вызова нет.
  - `rank_off_by_default`: 0 % → ранг и репутация не меняются; 10 % → `set_character_rank(floor(rank * 0.9))`.
  - `marker_spot_add_remove`:
    - `coop_death_marker(7, 555, "corpse")` → метка на 555 с ником игрока 7;
    - у объекта 555 появился родитель или объект исчез → через 2 с метка снята.
  - `outside_session_nothing`.
  - `options_page_has_rules`:
    - группа `coop_session` в `build_page()` содержит `death_mode` (`checkpoint` / `hardcore`), `death_drop`,
      `respawn_delay`, `contusion`, `death_money`, `death_wear`, `death_rank`, `checkpoints_group`,
      `autosave_interval`, `autosave_count`;
    - каждая с `cmd` = имени консольной переменной;
    - у галочек `bool_to_num = true`.
- [ ] **Шаг 2:** `tools/test_lua.cmd death` → FAIL.
- [ ] **Шаг 3:** `coop_death.script`:
  - контузия — эффектор `blur.ppe` с затухающим фактором и предел выносливости 0.6, повторяется раз в 5 с: другие
    скрипты поднимают предел;
  - штраф денег — `-- F2: move to the host money API` (раздел «Общие с Ф2»);
  - тексты: `st_coop_respawned_<kind>`, `st_coop_death_marker`, `st_coop_contusion_on`, `st_coop_contusion_off`;
  - метка — стоковый тип для тел: найти в `configs/ui/map_spots*.xml` стока `deadbody_location`, иначе
    `secondary_task_location`.
- [ ] **Шаг 4:** `coop_menu_options.script`. Поле `death_mode` `:58-62` получает токены `checkpoint` / `hardcore`.
  Новые поля — по шаблону `track` и `check` из файла. Строки `st_coop_opt_*` — в `st_coop_death.xml`.
- [ ] **Шаг 5:** `tools/test_lua.cmd death` → PASS; `tools/test_lua.cmd menu_options` → PASS; весь набор → PASS;
  строки → PASS.
- [ ] **Шаг 6:** в отчёт:
  - `docs/MOD_REPLACEMENTS.md`: «338 Soulslike Gamemode» → «сделано»;
  - `docs/CHECKPOINTS_DEATH.md` §3.1: «контузия не переживает переподключение (решение плана 8)»; §9: «настройки —
    Опции → Кооператив, доли — `mod_system_coop_death.ltx`».
- [ ] **Шаг 7:** коммит (проект): `Coop death: contusion, money and rank penalty, death marker spots, host death rules in the options`.

### Task 16: Lua wipe tasks table and F3 script domains

**Файлы:**
- Создать:
  - `gamedata/scripts/coop_wipe.script`;
  - `gamedata/configs/coop_wipe_tasks.ltx`, `gamedata/configs/coop_domains_checkpoints.ltx`;
  - `tests/lua/test_wipe.lua`.

**Интерфейсы:**
- Использует:
  - колбэк `coop_group_wipe()` (Task 8, только хост);
  - стоковые `task_manager.get_task_manager().task_info` и `:set_task_failed(id)` (`task_manager.script:91`), поле
    `tsk.status_functor`;
  - отказ задания с `repeat_timeout` оставляет запись со `stage = 255` (`task_manager.script:195-223`).
- Даёт: `coop_wipe.action_for(id, functor) -> "fail" | "keep"` — для тестов и консоли.

- [ ] **Шаг 1:** `coop_wipe_tasks.ltx`:
  ```
  ; Tasks when the whole group is dead (docs/CHECKPOINTS_DEATH.md §6). fail = stock on_fail, then retake at once; keep = untouched.
  ; Precedence: [by_id] > [by_prefix] (longest) > [by_functor] > [settings] default. GAMMA mods add lines here.
  [settings]
  default = keep
  [by_functor]
  assault_task_status_functor = fail
  bounty_task                 = fail
  hostage_task                = fail
  gd_task_status_functor      = fail   ; defence (pump station)
  spy_task_status_functor     = fail   ; rescue/escort of an agent
  actor_has_fetch_item        = keep
  delivery_task               = keep
  measure_task                = keep
  [by_prefix]
  lttz_ = keep                         ; Lost to the Zone: never (a failure there can be final)
  [by_id]
  ```
- [ ] **Шаг 2:** `coop_domains_checkpoints.ltx`. Секции в формате `coop_domains.ltx`:
  - `[view]`: `coop_checkpoints`, `coop_saves`;
  - `[owner]`: `coop_rest`, `coop_death`;
  - `[host]`: `coop_wipe`.
- [ ] **Шаг 3: тесты** `tests/lua/test_wipe.lua`:
  - `assault_bounty_hostage_fail` — `set_task_failed` для трёх заданий с этими функторами.
  - `fetch_keep`.
  - `lttz_prefix_wins`: `lttz_hb_x` с функтором `assault_task_status_functor` → `keep`.
  - `by_id_wins` — строка `[by_id]` перекрывает функтор.
  - `unknown_keep`.
  - `retake_at_once`: после штатной обработки отказа (`stage == 255`) запись удаляется из `task_info` на следующем
    обновлении.
  - `client_ignores` — `MODE = "client"`, ничего не происходит.
  - `domains_listed` — `ini_file("coop_domains_checkpoints.ltx")` даёт пять скриптов в своих секциях.
- [ ] **Шаг 4:** `tools/test_lua.cmd wipe` → FAIL.
- [ ] **Шаг 5:** `coop_wipe.script`:
  - на `coop_group_wipe` — проход по `task_info`;
  - для `fail` — `set_task_failed(id)` и запоминание id;
  - `actor_on_update`: запомненные задания со `stage == 255` → `task_info[id] = nil`;
  - лог на каждое решение.
- [ ] **Шаг 6:** `tools/test_lua.cmd wipe` → PASS; весь набор → PASS.
- [ ] **Шаг 7:** коммит (проект): `Coop wipe: group-wipe task table (coop_wipe_tasks.ltx) and F3 script domains`.

### Task 17: Saves hidden from players, stock save modes neutralized, host restore

**Файлы:**
- Изменить:
  - `engine/src/xrGame/ui/UIMMShniaga.cpp` (по отчёту Task 1 §A);
  - `gamedata/scripts/coop_core_player.script` (§3 — запрос быстрого сейва клиентом), `coop_menu.script` (кнопка
    хоста «Восстановить»), `coop_menu_options.script` (снять `flag("client_quicksave")` `:68`).
- Создать:
  - `gamedata/scripts/coop_saves.script`;
  - `gamedata/configs/text/{eng,rus}/st_coop_saves.xml`;
  - `tests/lua/test_saves.lua`.

**Интерфейсы:**
- Использует: отчёт Task 1 §A, имена `coop_auto_N` (Task 5 и 12), `CSavedGameWrapper` (Lua, `saved_game_wrapper_script.cpp:27-34`).
- Даёт: `coop_saves.list_autosaves() -> { {name, level, game_time_str, file_time}, … }` — новые сверху.

- [ ] **Шаг 1:** движок. В `CUIMMShniaga::CreateList` (`ui/UIMMShniaga.cpp:114`) кнопки `btn_save`, `btn_load`,
  `btn_lastsave` и другие имена из отчёта не создаются, если `coop::mgr().active()`. Если по отчёту список не
  пересоздаётся при открытии меню — пересобрать меню в начале и в конце сессии способом из отчёта.
  `tools/compile_files.sh ui/UIMMShniaga.cpp` → 0.
- [ ] **Шаг 2: тесты** `tests/lua/test_saves.lua`:
  - `save_input_refused_host_and_client`: в сессии у хоста и у клиента `on_before_save_input` типов 1, 2, 3 даёт
    `flags.ret == true` и подсказку `st_coop_saves_auto_host` / `st_coop_saves_auto_client`.
  - `load_input_refused`: `on_before_load_input` в сессии → `flags.ret == true`.
  - `no_session_untouched`: без сессии `flags.ret` не меняется.
  - `autosave_new_neutralized`: в сессии `game_autosave_new.autosave()` при истёкшем таймере не вызывает
    `exec_console_cmd("save …")`.
  - `client_quicksave_request_gone`: в `coop_core_player` нет `request_quicksave`, событие `core.save_req` не
    обрабатывается.
  - `restore_list`:
    - файлы `coop_auto_2.scop` (новее), `coop_auto_1.scop`, `quicksave.scop` → `list_autosaves()` = `coop_auto_2`,
      `coop_auto_1`;
    - выбор → `exec_console_cmd("load coop_auto_2")`, только у хоста.
- [ ] **Шаг 3:** `tools/test_lua.cmd saves` → FAIL.
- [ ] **Шаг 4:** реализация.
  - `coop_saves.script`: обработчики сейва и загрузки для всех в сессии; обёртка `game_autosave_new.autosave` в
    сессии.
  - Убрать §3 из `coop_core_player.script` и флаг из опций.
  - В окне `coop_menu.script` у хоста кнопка «Восстановить»: список, подтверждение, `load`.
  - Остальные режимы стока (костёр, «Агония», «Таймер», «Железный человек», «Азазель») нейтрализуются тем, что в
    сессии актор не умирает (`coop_survival intercept_actor_kill`) и сейвы игроку недоступны. Это записать в отчёт
    для реестра.
- [ ] **Шаг 5:** `tools/test_lua.cmd saves` → PASS; весь набор → PASS; строки → PASS.
- [ ] **Шаг 6:** в отчёт — `docs/MOD_REPLACEMENTS.md` → «сделано»:
  - «Сохранение у костра»;
  - «Агония, Таймер, Железный человек, Азазель»;
  - «Автосейв по таймеру»;
  - «Меню сохранения/загрузки и быстрые сейвы у игрока».

  В графе «Чем заменено» указать механизм нейтрализации.
- [ ] **Шаг 7:** коммиты:
  - движок: `Coop F3: no save/load buttons in the in-game menu during a session`;
  - проект: `Coop saves: players never save in a session, stock save modes neutralized, host restore from coop_auto_N`.

### Task 18: Shared-file cleanup after F2 (client save gates in coop_main, F3 route file)

Делает ведущая после того, как Ф2 задача 10 (маршрутизатор колбэков, `coop_route*.ltx`) и правки Ф2 в
`coop_main.script` слиты.

**Файлы:**
- Изменить: `gamedata/scripts/coop_main.script`, `tests/lua/test_wipe.lua`.
- Переименовать: `gamedata/configs/coop_domains_checkpoints.ltx` → `coop_route_f3.ltx`.

- [ ] **Шаг 1:** `coop_domains_checkpoints.ltx` → `coop_route_f3.ltx` в формате Ф2 задачи 10. Домены те же:
  - `coop_checkpoints`, `coop_saves` — `view`;
  - `coop_rest`, `coop_death` — `owner`;
  - `coop_wipe` — `host`.

  Тест `domains_listed` в `test_wipe.lua` переводится на новый файл.
- [ ] **Шаг 2:** из `coop_main.script` убрать — всё это закрывает `coop_saves.script` у хоста и у клиентов:
  - `on_before_save_input` и `on_before_load_input` `:921-939`;
  - `patch_main_menu` `:941-960` и вызов `:1013`;
  - регистрацию `:1100-1101`.

  Номера строк — до правок Ф2, искать по именам функций.
  Проверка: `grep -n "on_before_save_input\|patch_main_menu" gamedata/scripts/coop_main.script` → пусто.
- [ ] **Шаг 3:** `tools/test_lua.cmd` → PASS. Наборы, проверявшие эти гейты в `coop_main`, переписать на
  `coop_saves`.
- [ ] **Шаг 4:** коммит (проект): `Coop main: client save gates live in coop_saves now, F3 route file in the F2 format`.

### Task 19: F3 acceptance (lead + owner)

- [ ] **Шаг 1:** полная сборка: `python tools/ci_sync.py`, затем MSBuild `engine-ci/src/engine-vs2022.sln`
  `-p:Configuration=DX11-AVX -p:Platform=x64` → `exit=0`. Дальше по очереди, каждый шаг с кодом 0:
  - `tools/build_tests.cmd`;
  - `tools/test_lua.cmd`;
  - `python -m pytest tests/tools -q`.
- [ ] **Шаг 2:** `tools/deploy.ps1`. Хост и клиент запускаются **по слову владельца**.
- [ ] **Шаг 3: живые сценарии.** Результат и время каждого — в `MODLOG.md`.
  - **Спецификация §10:**
    1. Хост у костра 5 с → «Привал обновлён». Клиент умирает → через T возрождается у **своего** привала, а не у
       хоста.
    2. Клиент ставит палатку, хост её сворачивает → привал клиента откатывается на предыдущий, метка снята.
    3. Оба мертвы → оба на своих привалах. Задания по §6: зачистка провалена и снова доступна, fetch не тронут.
       Сейв не грузился.
    4. Клиент переходит на другую карту → его привал в точке прибытия, привал хоста не изменился. В Ф3 переход
       групповой: проверить точку прибытия у обоих и что прежний привал хоста лежит в `prev`.
    5. Клиент ложится спать один → дремлет, время не идёт. Ложится хост → сон у обоих, время промотано, есть
       `coop_auto_N`.
    6. `death_drop = drop`: часть материалов лежит на месте гибели, напарник подбирает и передаёт.
    7. Аварийное восстановление: хост загружает автосейв из «Восстановить», клиент перезагружает мир, привалы — из
       сейва.
  - **Review Focus и остальное:**
    8. Смерть хоста: эвакуация, потери, возрождение на привале хоста. Автосейв не пишется, пока хост мёртв.
    9. `drop` на склоне и у воды: выпавшее не дальше 3 м и на месте через 10 мин.
    10. Клиент выходит, пока мёртв, и входит снова → живой на своём привале, вещи второй раз не теряются.
    11. Хост переходит на карту, пока клиент мёртв или отдыхает → после возврата оба живы, дрёмы нет.
    12. Третий игрок (если есть) входит, пока двое отдыхают → сон не начинается, пока он не ляжет.
    13. `hardcore`: клиент погибает → тайник с его вещами, «Новый персонаж» → вход новым персонажем.
    14. Меню в сессии у хоста и у клиента: нет «Сохранить», «Загрузить», «Последний сейв». F5 и F9 молчат с
        подсказкой. Чат во время эвакуации работает.
- [ ] **Шаг 4:** итог:
  - `MODLOG.md`;
  - vault `10 Projects/Anomaly Coop`;
  - `docs/MOD_REPLACEMENTS.md` — статусы «проверено <дата>»;
  - `docs/XRRAZOM_PARITY.md` — строки про смерть, сейвы и сон.
