# Ф0. Стабилизация — план реализации

> **Для исполнителей-агентов:** обязательный навык — superpowers:subagent-driven-development (рекомендуется) или
> superpowers:executing-plans; задачи выполняются по шагам. Шаги размечены чекбоксами (`- [ ]`) для отслеживания.

**Цель:** убрать падения, рассинхрон и дюпы, найденные ревью R1–R6, и закрыть проверку входящих запросов в движке.

**Архитектура:**
- Проверки чисел и имён — чистые функции в `xrCoop` (без зависимостей от движка), покрытые юнит-тестами.
- Код `xrGame/coop` вызывает их на границе приёма сообщения.
- Lua-исправления — точечные, со стаб-тестами на LuaJIT движка.
- Lua-синхра с дырами доверия (деньги, задания, `quests.act`) здесь не латается, а переезжает в движок в Ф2.

**Стек:** C++ (MSVC 2022, xray-monolith `ad9d841660` + `engine/src/xrCoop`, `engine/src/xrGame/coop`), Lua 5.1 /
LuaJIT 2.0.4 движка, PowerShell и bash-инструменты из `tools/`.

**Спецификация:** `TZ.md` (Ф0), `REVIEW_FINDINGS.md` (номера находок ниже — оттуда), `SYNC_SPEC.md` §9.

## Глобальные ограничения

- Хост авторитетен; клиенту не доверяем (P8): любое число из сети проверяется до использования.
- Строгая типизация, без хаков. Комментарии и стиль — как в окружающем коде (`coop_*.cpp`: таб, `// R… :` у правок
  по ревью).
- Агенты не коммитят: коммит делает ведущая после проверки задачи. У каждого агента свои файлы (таблица ниже).
- Временные файлы — только в `temp/`.
- Проверка компиляции: `tools/compile_files.sh <пути от engine/src/xrGame>` (держит `temp/compile.lock`). Полная
  сборка — ведущая: `python tools/ci_sync.py`, затем MSBuild `engine-ci/src/engine-vs2022.sln`
  `-p:Configuration=DX11-AVX -p:Platform=x64`.
- Юнит-тесты: `tools/build_tests.cmd [фильтр]` → `temp/tests/coop_tests.exe`, код выхода 0.
- Lua-тесты: `tools/test_lua.cmd` (задача 2) → код выхода 0.
- Игру не запускать. Живые сценарии — задача 15, вместе с владельцем.

## Что проверить отдельно (риски, которые тесты задач не ловят)

1. Хост с клиентом на старой версии протокола: несовпадение версии отклоняется при рукопожатии с понятной причиной,
   а не падением. Проверка — сценарий 15.6.
2. Пакет на границе размера (ровно лимит и лимит + 1 байт) для каждого ограничения задачи 12. Тест есть в задаче 12.
3. Переподключение во время загрузки мира у клиента (задача 11 + R2 minor «обрыв во время LoadingWorld»): клиент не
   должен играть за персонажа хоста. Проверка — сценарий 15.4.
4. Три игрока (хост + 2): метки, цвета и передача предметов чужим аватарам (задача 8). Проверка — сценарий 15.7.
5. Длинная сессия: рост памяти и очередей. Счётчики очередей в `coop_status` не растут за 2 ч (сценарий 15.1).

## Распределение файлов (параллельная работа)

| Агент | Задачи | Файлы |
|---|---|---|
| A (Opus) | 1, 10 | `xrCoop/coop_validate.h` (новый), `tests/test_validate.cpp` (новый), `coop_players.cpp`, `coop_equip.cpp`, `coop_requests.cpp`, `coop_events.cpp` |
| B (Opus) | 11, 12 | `xrCoop/coop_session.cpp`, `coop_join.cpp`, `coop_manager.cpp`, `tests/test_session_limits.cpp` (новый) |
| C (Opus) | 5, 13 | `coop_story.cpp`, `coop_trade.cpp`, `xrCoop/coop_rules.h` (новый), `tests/test_rules.cpp` (новый) |
| D (Sonnet) | 2, 3, 4 | `tests/lua/*`, `tools/test_lua.cmd`, `gamedata/scripts/coop_menu_options.script`, `gamedata/scripts/coop_main.script` |
| E (Opus, после A и B) | 6, 7, 8, 9, 14 | `coop_items.cpp`, `coop_world.cpp`, `coop_remote*.cpp`, `coop_entities.cpp` (по месту находок) |

---

### Задача 1: Ядро проверок и критичные К1/К2

**Файлы:**
- Создать: `engine/src/xrCoop/coop_validate.h`, `tests/test_validate.cpp`
- Изменить: `engine/src/xrGame/coop/coop_players.cpp` (`State::read`, уже частично), `engine/src/xrGame/coop/coop_equip.cpp` (`Equip::read`, уже частично), `tools/build_tests.cmd` (добавить файл теста, если список явный)

**Интерфейсы:**
- Даёт (`namespace coop::validate`, header-only, только `<cmath>`, `<cstddef>`, `<cstring>`):
  - `bool finite(float x)`
  - `bool finite3(const float v[3])`
  - `bool speed_ok(const float v[3], float max_speed)` — длина ≤ `max_speed`
  - `bool in_box(const float p[3], const float lo[3], const float hi[3], float margin)`
  - `bool resource_name_ok(const char* s, size_t max_len)` — не пусто, длина ≤ `max_len`, нет `..`, нет `:`, только
    печатные ASCII 0x20–0x7E
- Использует: ничего.

- [ ] **Шаг 1: тесты** `tests/test_validate.cpp`:
  - `validate_finite`: NaN, +inf, −inf → false; 0, −1e6, 1e6 → true.
  - `validate_speed`: {0,0,100} при max 100 → true; {0,0,100.01} → false; NaN-компонента → false.
  - `validate_box`: точка на границе +50 при margin 50 → true; +50.01 → false; 1e30 → false.
  - `validate_name`: `actors\stalker_neutral\stalker_neutral_1` (200) → true; пусто, `..\x`, `c:\x`, 201 символ,
    байт 0x7F → false.
- [ ] **Шаг 2:** `tools/build_tests.cmd validate` — ожидается ошибка компиляции (нет заголовка).
- [ ] **Шаг 3:** написать `coop_validate.h`.
- [ ] **Шаг 4:** `tools/build_tests.cmd validate` → PASS, затем `tools/build_tests.cmd` целиком → PASS.
- [ ] **Шаг 5:** перевести `State::read` на `validate::finite3` / `speed_ok`. Константы уже в файле:
  `kMaxSpeed = 100.f`, `kLevelMargin = 50.f`, граница — `Level().ObjectSpace.GetBoundingVolume()`.
  `Equip::read` — на `validate::resource_name_ok(visual, kMaxVisual = 200)` плюс существующий `visual_exists`
  (поиск файла как в `CModelPool::Instance_Load`).
- [ ] **Шаг 6:** `tools/compile_files.sh coop/coop_players.cpp coop/coop_equip.cpp` → 0 ошибок.
- [ ] **Шаг 7:** коммит (ведущая): `Coop: validate player state and equipment from the network (R3 K1, K2)`.

### Задача 2: Lua-тесты в репозитории

**Файлы:**
- Создать: `tests/lua/` (перенос `temp/luacheck/runlua.c`, `stubs.lua` и тестов `temp/luacheck_*` / `temp/w6`), `tools/test_lua.cmd`
- Изменить: нет

**Интерфейсы:**
- Даёт: `tools/test_lua.cmd [фильтр]` — собирает `runlua.exe` из `tests/lua/runlua.c` (если нет), гоняет
  `tests/lua/test_*.lua`, печатает `passed/failed` по файлу, код выхода = число упавших файлов.

- [ ] **Шаг 1:** перенести файлы, поправить пути внутри тестов на относительные к `tests/lua`.
- [ ] **Шаг 2:** `tools/test_lua.cmd` → все прежние наборы зелёные: W3c 58/58, W4q 74/74, core 100/100, W6 94/94,
  W10 и W12 (135/135), W5 R 310/0.
- [ ] **Шаг 3:** коммит: `tests: Lua stub suites live in tests/lua with one runner`.

### Задача 3: Галочки «Кооператив» в опциях (R5 I1)

**Файлы:** изменить `gamedata/scripts/coop_menu_options.script:20-54`; тест `tests/lua/test_menu_options.lua`

- [ ] **Шаг 1: тест** `menu_options_bool_to_num`:
  - у каждой галочки, пишущей целочисленную консольную переменную (огонь по своим, общие награды, ники), есть
    `bool_to_num = true`;
  - сохранение `true` даёт `1`, `false` даёт `0`.
- [ ] **Шаг 2:** прогнать тест — ожидается FAIL.
- [ ] **Шаг 3:** добавить `bool_to_num = true` этим опциям.
- [ ] **Шаг 4:** тест → PASS; `tools/test_lua.cmd` целиком → PASS.
- [ ] **Шаг 5:** коммит: `Coop menu: checkbox options write 1/0 into integer console vars (R5 I1)`.

### Задача 4: Выброс у клиента (R5 I2)

**Файлы:** изменить `gamedata/scripts/coop_main.script:761-863`; тест `tests/lua/test_client_emission.lua`

- [ ] **Шаг 1: тест** `client_never_ends_emission`: в режиме клиента `surge_manager` не завершает и не перезапускает
  выброс сам, `launch_rockets` не вызывается, ранг за цикл не начисляется; события выброса приходят только от хоста.
- [ ] **Шаг 2:** FAIL.
- [ ] **Шаг 3:** на клиенте `surge_time` (и `psi_storm`) — «никогда»; `launch_rockets` — пустая обёртка у клиента.
- [ ] **Шаг 4:** PASS; весь набор → PASS.
- [ ] **Шаг 5:** коммит: `Coop: clients never end or restart emissions themselves (R5 I2)`.

### Задача 5: Машинные инфопорции локальны (R4 1, R6 minor про сон)

**Файлы:**
- Создать: `engine/src/xrCoop/coop_rules.h`, `tests/test_rules.cpp`
- Изменить: `engine/src/xrGame/coop/coop_story.cpp:2365` (отправка, применение, хеш)

**Интерфейсы:** даёт `bool coop::rules::is_machine_info(const char* id)` — `ui_pda`, `ui_talk*`, `*_wnd_open`,
`actor_is_sleeping`, `sleep_active`.

- [ ] **Шаг 1: тест** `rules_machine_info`: перечисленные → true; `esc_trader_task_1_done`, `ui` (без суффикса),
  `pda_found` → false.
- [ ] **Шаг 2:** FAIL. **Шаг 3:** `coop_rules.h`. **Шаг 4:** PASS.
- [ ] **Шаг 5:** в `coop_story.cpp` такие инфо не отправляются, не применяются и не входят в хеш домена.
  `tools/compile_files.sh coop/coop_story.cpp` → 0 ошибок.
- [ ] **Шаг 6:** коммит: `Coop story: UI and sleep info portions stay on their machine (R4 1)`.

### Задача 6: «Застрявшие» предметы — тег прицела (R3 В1)

**Файлы:** изменить код захвата и сравнения тегов предмета (`TagScope`, `same()`; найти `grep -n "has_scope" engine/src/xrGame/coop/*.cpp`).

- [ ] **Шаг 1:** при `m_scopes` пусто `has_scope` не трогать; `same()` сравнивает по тегам владельца.
- [ ] **Шаг 2:** расходящийся тег пишется в лог один раз на предмет и тег (для еды — найти причину по логу).
- [ ] **Шаг 3:** `tools/compile_files.sh` по изменённым файлам → 0 ошибок. Живая проверка — сценарий 15.3 (пистолет,
  нож, еда больше не «stuck» в `coop_status`).
- [ ] **Шаг 4:** коммит: `Coop items: scope tag no longer marks scopeless weapons as stuck (R3 В1)`.

### Задача 7: Взрывы ранят клиентов (R3 В2)

**Файлы:** путь хита взрыва с инициатором-не-существом (бочки, аномалии, осколки) — `coop_requests.cpp` / `coop_events.cpp`.

- [ ] **Шаг 1:** хит по прокси игрока от взрыва без существа-инициатора доходит до владельца как PlayerHit. Огонь по
  своим фильтрует и взрывы клиента (R3 minor).
- [ ] **Шаг 2:** компиляция → 0 ошибок. Живая проверка — сценарий 15.5.
- [ ] **Шаг 3:** коммит: `Coop: explosions without a creature initiator hurt players (R3 В2)`.

### Задача 8: Владельцы чужих аватаров при 3+ игроках (R3 В3)

**Файлы:** `coop_world.cpp`, `coop_join.cpp` (рассылка `avatar_id` ↔ игрок), панель группы и метки (`coop_core_hud.script` — только чтение API).

- [ ] **Шаг 1:** хост рассылает каждому клиенту таблицу `аватар → (peer, ник, цвет)` при входе и при изменениях.
  Клиент знает владельца каждого аватара.
- [ ] **Шаг 2:** метки, цвет и передача предметов работают для всех чужих аватаров, не только для хоста.
- [ ] **Шаг 3:** компиляция → 0 ошибок. Живая проверка — сценарий 15.7.
- [ ] **Шаг 4:** коммит: `Coop: every client knows who owns each avatar (R3 В3)`.

### Задача 9: Т-поза после смены визуала (R3 В4)

- [ ] **Шаг 1:** после `ChangeVisual` аватара сбросить `applied_*` и проиграть текущие MotionID заново
  (`coop_players.cpp` `Track`), если `motion_valid` для нового визуала.
- [ ] **Шаг 2:** компиляция → 0. Живая — сценарий 15.2 (сменить броню у клиента).
- [ ] **Шаг 3:** коммит: `Coop: avatars replay their motions after a visual change (R3 В4)`.

### Задача 10: Проверка запросов (R3 В5–В8)

**Файлы:** `coop_requests.cpp` (ReqHit, ReqSpawn, расход гранат, `kMoveLocal`).

- [ ] **Шаг 1:** ReqHit: номер кости < `LL_BoneCount()` цели, иначе отказ.
- [ ] **Шаг 2:** ReqSpawn: секция существует и содержит `class`, иначе отказ; пакет не читается как сырые байты
  `Spawn_Read`.
- [ ] **Шаг 3:** расход гранаты решает хост: граната берётся из инвентаря прокси, флаг клиента игнорируется.
- [ ] **Шаг 4:** `kMoveLocal` от клиента не отключает проверку дальности.
- [ ] **Шаг 5:** все числа запросов — через `coop::validate` (задача 1).
- [ ] **Шаг 6:** компиляция → 0. Коммит: `Coop: host validates hit bones, spawn sections, grenade use and move range (R3 В5-В8)`.

### Задача 11: Ключ игрока и переподключение (R1 I1, I2)

**Файлы:** `coop_join.cpp:120-137,156,291,364-374`, `xrCoop/coop_session.cpp:713-725`, `coop_manager.cpp:24,484-489`; тест `tests/test_session_limits.cpp`.

- [ ] **Шаг 1: тест** `session_reconnect_same_key`: второй вход с тем же ключом до таймаута выбивает старое соединение
  и принимает новое (не DuplicateKey). DuplicateKey — только для ключа хоста.
- [ ] **Шаг 2:** FAIL → реализация → PASS.
- [ ] **Шаг 3:**
  - в custom data прокси хранится SHA-256 ключа, а не ключ;
  - разбор — строгий по строке `key=`, а не `strstr` по всей custom data;
  - старые сейвы мигрируются при первом входе.
- [ ] **Шаг 4:** убрать совет «удалить ключ»; `hold_connection(0)` в краш-хуке.
- [ ] **Шаг 5:** тесты + компиляция → 0. Коммит: `Coop: hashed player keys, reconnect replaces the old link (R1 I1, I2)`.

### Задача 12: Лимиты и эпоха мира (R1 I3, I4; R2 I1, I3, I4)

**Файлы:** `xrCoop/coop_session.cpp:33-34,1012-1064`, `coop_join.cpp:215-301,589-636`; тест `tests/test_session_limits.cpp`.

- [ ] **Шаг 1: тесты:**
  - `limits_blob_kind`: хост принимает от клиента только разрешённые виды блобов, ≤ 1 МиБ, байтов в полёте ≤ 4 МиБ;
    на ровно 1 МиБ — принят, на 1 МиБ + 1 — отказ;
  - `limits_join_rate`: один вход в полёте на пира, не чаще 1 раза в 5 с;
  - `world_epoch`: сообщения и блоб с эпохой старого мира отбрасываются после SessionReset.
- [ ] **Шаг 2:** FAIL → реализация → PASS.
- [ ] **Шаг 3:**
  - TransitionVote: хост не исполняет сырой пакет клиента — только id перехода из своего списка;
  - StateDumpRequest: только хосту-отладчику, лимит частоты, без тайников.
- [ ] **Шаг 4:** компиляция → 0. Коммит: `Coop: blob and join limits, world epoch, no raw packets from clients (R1 I3-I4, R2 I1, I3, I4)`.

### Задача 13: Торговля, метки КПК (R4 2 — торговля, R4 3, R4 5)

**Файлы:** `coop_trade.cpp:380-459,819`, `coop_story.cpp:798-849,1646-1660`.

- [ ] **Шаг 1:** цены считает хост (`CTrade`, `GetItemPrice`); клиент шлёт только id предметов и контрагента. Хост
  проверяет дистанцию до торговца и его флаги торговли.
- [ ] **Шаг 2:** SpotRemove / RemoveAll от клиента удаляют только его собственные метки, метки заданий — никогда.
- [ ] **Шаг 3:** метка задания неизвестного типа у клиента пропускается с записью в лог, без `R_ASSERT3` в `LoadSpot`.
- [ ] **Шаг 4:** компиляция → 0. Коммит: `Coop: host-priced trade, clients remove only their own map spots, unknown spot types skipped (R4 2, 3, 5)`.

### Задача 14: Спам «destroyed object» после ухода клиента

- [ ] **Шаг 1:** найти источник ~25 000 строк `you are trying to use a destroyed object [15208..15253]` у клиента после
  выхода другого игрока (вероятно, инвентарь ушедшего аватара): `MODLOG.md`, логи `E:\AnomalyCoop\appdata_b\logs`.
- [ ] **Шаг 2:** обращения к уничтоженным объектам прекращаются в момент ухода аватара из мира (W9).
- [ ] **Шаг 3:** компиляция → 0. Живая — сценарий 15.4. Коммит: `Coop: no access to a departed avatar's items`.

### Задача 15: Приёмка Ф0 (ведущая + владелец)

- [ ] **Шаг 1:** полная сборка `engine-ci` → `exit=0`; `tools/build_tests.cmd` → 0; `tools/test_lua.cmd` → 0.
- [ ] **Шаг 2:** `tools/deploy.ps1`; запуск хоста и клиента — **по слову владельца**.
- [ ] **Шаг 3: живые сценарии**, у каждого результат и время записываются в `MODLOG.md`:
  1. Сессия 2 ч: в `coop_status` очереди не растут, FATAL нет.
  2. Клиент меняет броню: аватар без Т-позы.
  3. Пистолет, нож, еда: нет «stuck».
  4. Клиент выходит и входит снова (в том числе во время загрузки мира): нет вылета, нет игры за персонажа хоста,
     нет спама «destroyed object».
  5. Взрыв бочки рядом с клиентом ранит его.
  6. Клиент со старой версией: понятный отказ при рукопожатии.
  7. Третий игрок (если есть возможность): метки, цвета и передача предметов чужим аватарам.
  8. Переход уровня после 5+ минут сессии: клиент не выбит (R2 C1).
  9. Торговля у клиента: цены как у хоста; отказы `TooFar` / `NotTraded` у сталкера-торговца понятны игроку.
  10. Клиент ставит апгрейд у механика → хост сохраняется и загружается → апгрейд на месте (задача 10b).
  11. Огонь по своим выключен: мина хоста рядом с клиентом и мина клиента рядом с хостом не ранят; включён — ранят
      (задача 7).
  12. Урон от взрыва бочки рядом с клиентом такой же, как в одиночной игре, не вдвое больше (задача 7).
  13. Клиент открывает КПК — у хоста не закрываются окна, хосту не уходят запросы (задача 5).
  14. После сессии в `coop_status` равны 0:
      - отказы `refused as invalid (R3)`, `upgrades dropped`, `spawn sections/states`;
      - `rate limit StateDumpRequest: N dropped`.
      Ненулевое значение = честное действие отклонено; искать по логу.
  15. К пункту 4: в логах обеих сторон `grep -n -m3 -A60 "you are trying to use a destroyed object"` (полная фраза:
      заголовок диагностики тоже содержит «destroyed object»). Lua-стек, затем C++-стек называют виновника (задача 14).
  - Как читать «stuck»: тег `upgrades` на оружии с апгрейдами по умолчанию — известная мелочь задачи 10 (`host_push`
    без игрового объекта), не регрессия задачи 6.
- [ ] **Шаг 4:** итог в `MODLOG.md`, в vault (`10 Projects/Anomaly Coop`) и в `docs/XRRAZOM_PARITY.md` (строки
  «Синхра», «Дюпы», «Безопасность», «Анимации»).
