# Раздельные карты «нативно»: сервер мира из игры и из лаунчера (дизайн и план, 2026-11-12)

Основа: `docs/plans/2026-11-12-split-levels-no-reloads.md`, раздел 5a, записи 21:31 и 21:33 владельца. Они отменяют всё,
что в 5a записано раньше про «два режима» и «три значения».

Состояние кода на момент чтения: движок `5498e3fb` (`engine/src`, `master`), мод — рабочее дерево с чужими правками.
Лаунчер: `raylink-launcher` (`master`) и `raylink-launcher-ml` (ветка `multilevel`, правки не закоммичены).
Всё ниже прочитано в коде. Игра, сборка, лаунчер не запускались. Номера строк — на 2026-11-12 вечер, другой инженер правит
эти же файлы, номера могут сдвинуться.

Слова:
- **сервер мира** — процесс `-coop_dedicated`: ALife, сейвы, актёр-призрак на `fake_start`;
- **Mk** — сервер карты, процесс `-coop_mapserver`;
- **игра** — окно игрока;
- **создатель** — тот, кто создал мир (в игре или в лаунчере);
- **оператор** — узел сессии, которому сервер мира дал права хоста. В этом дизайне это всегда игра создателя на том же ПК.

## 0. Коротко

1. Настройка «Раздельные карты» = «мир живёт в отдельном процессе». Других раздельных карт нет. Без неё всё как сегодня:
   хост в игре, группа ходит вместе.
2. Игра создателя сама запускает сервер мира (тот же exe, `-coop_dedicated -coop_hidden`), ждёт строку готовности в канале
   stdout и входит в него клиентом на `127.0.0.1`. Для игрока это один экран загрузки.
3. Выбор нового мира (группировка, имя, снаряжение, деньги, старт, настройки игры) уходит серверу файлом до создания мира.
   Сервер сам делает персонажа создателя, когда тот впервые входит. Окна выбора нет.
4. Место сервера в сессии помечается движком (`host_plays = false` в `Welcome`). `coop.players()` и `coop.session_info()`
   его не отдают. Звезда хоста — новое поле `is_host` у строки оператора. Lua почти не меняется: ~10 мест с `id == 0`.
5. Права хоста у оператора. Его узнают по одноразовому жетону: игра передала его серверу в командной строке и предъявляет
   в `Hello`, только с loopback. Команды хоста идут серверу одним новым сообщением `OperatorCommand` со списком разрешённых
   консольных команд.
6. Старый режим (процесс хоста ведёт свою карту, Mk для остальных, мягкий переход) удаляется в 4 коммита.
   Общее остаётся: Mk, таблица мест, туннель, `LevelMove`, эпохи для отката.
7. Лаунчер создаёт мир тем же файлом, показывает карточку мира, запускает и останавливает сервер. Консоль — строки stdout
   сервера в канале с цветом по уровню. «Войти» запускает игру с `-coop_connect` и жетоном.

Блокер, не наш: на карте под Mk при выделенном сервере неписи одной группировки воюют друг с другом и с игроком
(5a, «Блокер режима», диагностика `gamedata/scripts/coop_npc_why.script`). Без его решения режим в руки игрокам не отдаём.
В плане ниже это зависимость этапа приёмки.

---

## 1. Сервер — не игрок: аудит

### 1.1 Откуда «server» попадает в списки

- У клиента `Session::peers()` — это «хост + PeerList» (`engine/src/xrCoop/coop_session.h:115`). Узел 0 (ник `server`)
  приходит в Lua как обычный игрок.
- `Seat::plays` (`engine/src/xrCoop/coop_levels_rules.h:83`) живёт только в таблице сервера мира. Ставится в
  `host_seat_self` / `host_seat_going` (`engine/src/xrGame/coop/coop_levels.cpp:101`, `:113`).
- `host_send_map` (`coop_levels.cpp:128-141`) шлёт все места, в том числе неиграющее, без бита `plays`.
  `LevelMapMsg::Player` (`engine/src/xrCoop/coop_levels_wire.h:137-144`) — это peer, level, in_world, proxy, money.
- Поэтому `level_of_player(0)` у клиента (`coop_levels.cpp:263-266`) даёт `fake_start`. Отсюда «На другой карте: Фальстарт».
- В самом процессе сервера мира `coop.players()` себя уже не кладёт (`engine/src/xrGame/coop/coop_script.cpp:728`,
  `!g_coop_dedicated`). А `coop.session_info().players` кладёт (`coop_script.cpp:1327`): окно «Кооператив» и запись игры
  на сервере видят `server`.
- Lua не может отличить неиграющий узел. `coop.is_dedicated()` (`coop_levels.cpp:617`) истинен только внутри процесса
  сервера мира. Флага на узле нет ни в проводе, ни в Lua.
- Места движка, где сервер уже не считается (аудит `docs/DEDICATED_AUDIT.md`, «Исправлено»):
  - сон: `host_tick`, `coop_rest.cpp:357`;
  - гибель группы: `host_check_wipe`, `coop_survival.cpp:1259`;
  - деньги: `receiver_of`, `coop_money.cpp:345`, узлу 0 отказ;
  - табло перехода: `session().players()`, `coop_join.cpp:3177`. У сервера мира нет локального канала
    (`coop_manager.cpp:473`), поэтому строки «server» там нет.

### 1.2 Места, где перечисляются или считаются игроки

Сводка аудита (полный проход по `gamedata/scripts/coop_*.script` и Lua-API движка). «Вид» — меняется только показ.
«Счёт» — меняется число или решение.

| # | Где | Что делает сервер сегодня | Что нужно | Вид/Счёт |
|---|---|---|---|---|
| 1 | Панель группы HUD: `coop_core_hud.script:70` `players()`, `:203` `views()`; звезда `:221` `host = p.id == 0`, рисуется `:580-583`, цвет `:672` | строка `server`, звезда, «На другой карте: Фальстарт» (`elsewhere_text`, `coop_levels.script:292`) | строки нет; звезда по `p.is_host` | вид |
| 2 | Метки на карте/КПК: `coop_allies_map.script:230` `sync`, `coop_core_hud.script:848` | у узла 0 нет аватара: метки нет | ничего | — |
| 3 | Новости «вошёл/вышел»: `coop_core_player.script:79` `players()`, `:212` `roster_tick`, `:230` «Connected to the co-op session of %s» через `nick_of(0)` | «подключён к сессии server», «server вышел» при падении сервера | имя в «подключён к…» — ник оператора или имя мира; падение сервера — отдельная строка «мир закрылся» | вид |
| 4 | Чат `/players`: `coop_core_chat.script:192`, `(host)` на `:198` (`p.id == 0`) | «Игроков: N» на одного больше, `(host)` у `server` | счёт без сервера, `(host)` по `p.is_host` | вид+счёт |
| 5 | Чат `/go`: `coop_core_chat.script:212-221` | клиенту отказ «только хост» | оператору — `OperatorCommand "/go"` (§2) | права |
| 6 | Окно «Кооператив», строки игроков: `coop_menu.script:217` `player_rows`, `:285` `players_text` (через `session_info().players`) | строка `server` с меткой «хост», «N/8» на одного больше; на самом сервере тоже | без сервера; «хост» по `is_host` | вид+счёт |
| 7 | Запись игры, список игроков: `coop_game_settings.script:631` `at_now` (`:651`) | в сохранённой карточке мира есть «server» | без сервера | вид (хранится) |
| 8 | Окно персонажа: `coop_menu_char.script:704` `host_nick` | «хост: server» | ник оператора, иначе имя мира | вид |
| 9 | Передача денег: `coop_ui.script:386` `other_players`, `:462` `on_money_button`, `:478` `money_button` | одинокий клиент видит кнопку; с одной целью окно суммы открывается сразу для узла 0, движок отказывает | цели без сервера, кнопки нет, если целей нет | счёт |
| 10 | Слоты денег в торговле: `coop_economy_money.script:474` `refresh_slots` | `server` в `money_slots` | убрать | счёт |
| 11 | Передача вещей: там же, слоты вещей требуют объект рядом | сервер не попадает | ничего | — |
| 12 | `others_count()`: `coop_economy_core.script:249`, `:284` | у клиента ≥ 1, даже когда он один | без сервера | счёт |
| 13 | Пропуск времени/сон с вопросом группе: `coop_economy_group.script:230` `request_skip` (на клиенте зависит от п.12); голосование у сервера `:316` `host_open`, `:337` правило «хост» → «голос» на выделенном | клиент спрашивает группу, которой нет | исправится п.12 | счёт |
| 14 | Групповой телепорт: `coop_economy_travel.script:108` `group_teleport`, `:233`, `:257`, `:303`, `:339` | клиент считает, что рядом кто-то есть | исправится п.12 | счёт |
| 15 | `coop_economy_mdata.script:172`, `:965` | то же | то же | счёт |
| 16 | «Все рядом», дальние игроки: `coop_economy_core.script:301` `far_players` | считается у сервера мира, себя там нет | ничего | — |
| 17 | Лимит заданий у непися: `coop_quests_offer.script:585` `#players` | клиент и сервер считают по-разному (клиент +1) | без сервера | счёт |
| 18 | Награда группе: `coop_reward_group.script:~44` `list()` через `coop.members()`, `:47` пропуск `is_dedicated()`; запасной путь `:61` | если членов нет, награда призраку (безвредно, `DEDICATED_AUDIT.md` «Не исправлено») | запасной путь — получатель создатель (персонаж оператора) или никто | счёт |
| 19 | Репутация группы: `coop_reputation.script:77`, `coop_npc_players.script:114/157/194` | по аватарам, призрак отсечён | ничего | — |
| 20 | Репутация у торговцев: `coop_trader_reputation.script:41` `refresh`, `:53` | нет `avatar_id` → пропуск | ничего | — |
| 21 | Компаньоны, «выбор игрока»: `coop_npc_companions.script:194` `other_players` (берёт и `elsewhere == true`) | `server` в списке, можно выбрать узел 0 | без сервера | счёт |
| 22 | Поднятие: `coop_survival.cpp:2049-2055` (решает Mk) | у призрака тела нет | ничего | — |
| 23 | Правила смерти, гибель группы: `coop_survival.cpp:1259` | призрак не считается | ничего | — |
| 24 | Чекпоинты: `coop_checkpoints.script:116`, `:231`, `:554` | по аватарам | ничего | — |
| 25 | Окна «вместе» и поездка группы: `coop_hud_transition.script:189`, `coop_transition_route.script:160` | табло без сервера (п.1.1) | ничего | — |
| 26 | Погода по карте хоста: `coop_world_weather.script:169` `on_host_level` через `level_of_player(0)` | клиент всегда берёт свою погоду | оставить как есть, но читать флаг, а не случайность `fake_start` | решение |
| 27 | Сюжетные условия «актёр хоста»: `coop_quests_core.script:51` `players`, `:68` `host_party`; `coop_quests_story.script:135`; `coop_quests_far.script:102`; `coop_tasks.script:164`, `:904`; `coop_npc_players.script:121` | всё на сервере мира, призрак отсечён (`DEDICATED_AUDIT.md`); `db.actor` сервера — призрак, ответы «игрок рядом» идут через дальний вид `coop_quests_far.script` | ничего в этом документе; дыры «актёр хоста» описаны в `DEDICATED_AUDIT.md` | — |
| 28 | Ключ заявок КПК: `coop_quests_pda.script:689` `session_key` — ник хоста `server` | безвредно, но имя мира лучше | имя мира | вид |
| 29 | Сеть: `coop_hud_netgraph.script:43` `HOST_PEER = 0`, `:144` (пинг клиента берётся из строки узла 0), `:138` `summarize`, `:190` `players_list` | число игроков +1 | **зависимость**: пинг брать из нового `coop.server_link()`, а не из строки узла 0 | вид+решение |
| 30 | Окно F7: `coop_debug_ui.script:1478` (`Page_me`, кнопка «ТП к server», `tp_peer` к 0), `:2024` (`BindOverview`, строка `server`) | кнопка ведёт в никуда | кнопки нет, строки нет | вид+решение |
| 31 | Тест-план: `coop_testplan.script:43`, `:48` `host_peer` ищет `p.id == 0` | сломается при скрытии | искать `p.is_host` или `coop.server_link()` | решение |
| 32 | Диагностика: `coop_parity.script:338`, `coop_mods_misc.script:610`, `coop_main.script:1165` `context_now` | счёт в логе | без сервера | вид |
| 33 | Свет фонаря, маркеры, смерть: `coop_hud_glare.script:111`, `coop_hud_markers.script:395`, `coop_death.script:324` | по аватарам | ничего | — |
| 34 | Мировые новости: `coop_core_world.script:207` `others_online` | у клиента всегда истина: лишний трафик | исправится в движке | трафик |
| 35 | Настройки игры у выделенного: `coop_settings.script:493` `players_count`, `:502` `< 2` | обратная ошибка: на сервере `coop.players()` даёт только клиентов, с одним клиентом ничего не шлётся | `< 1` на выделенном | счёт |
| 36 | Предел сессии: `coop_session.cpp:1303` `m_joined.size() + 1 >= m_max_players` (`kMaxPlayers = 8` включая хоста, `coop_protocol.h:88`) | на выделенном 7 игроков вместо 8 | у сервера без игрока предел считает только клиентов | счёт |

Не проверено чтением: `coop_hud_tc.script:147` (у агента «без позиции, безвредно»), `coop_mods_core.script:239/287/300`,
`coop_mods_nta.script`.

### 1.3 Один механизм вместо сорока проверок

**Провод (протокол 31, новое).**
- `WelcomeMsg` (`coop_protocol.h:374`) получает `u8 flags`. Бит `HostSeatPlays` ставит сервер, когда `!dedicated::on()`.
- `PeerListEntry` (`coop_protocol.h:397`) получает `u8 flags`. Бит `Operator` стоит у узла с правами хоста (§2).
- `kProtocolVersion` 30 → 31 (`coop_protocol.h:86`). Тесты: `tests/test_protocol_game.cpp` (round-trip и отказ на обрыве).

**Сессия (новое).**
- `PeerInfo` (`coop_session.h:42`) получает `bool plays = true` и `bool host_rights = false`.
- Клиент ставит `plays` строке узла 0 из `Welcome.flags`, `host_rights` строкам из `PeerList.flags`.
- Хост в своей таблице ставит `host_rights` оператору.
- Чистое правило: `xrCoop/coop_roster.h` (новый), header-only.
  - `bool listed(const PeerInfo&)` — `plays`;
  - `bool host_badge(const PeerInfo&, bool host_plays)` — оператор, а при `host_plays` узел 0;
  - `uint32_t player_count(...)`.
  Тест: `tests/test_roster.cpp` (новый).

**Lua (одна точка).**
- `l_players` (`coop_script.cpp:692-737`) и `l_session_info` (`:1279-1339`) строят строки через `roster::listed`.
  Узла с `plays = false` нет ни у клиента, ни на сервере (`:1327` перестаёт класть себя на выделенном).
- Новое поле строки `is_host` (в `session_info` оно уже есть, `:1320`, но сейчас это `id == kHostPeer`). Теперь оно
  считается через `roster::host_badge` в обоих.
- Новая функция `coop.server_link()` → `{ rtt, loss }` соединения с сервером мира (у клиента — узел 0, у хоста nil).
  Для `coop_hud_netgraph.script` и `coop_testplan.script`.
- Новая функция `coop.has_host_rights()`: `is_host()` процесса, или этот клиент — оператор.
- `coop.levels` (`coop_levels.cpp`): `host_send_map` не кладёт места с `plays = false`.
  - Тогда `level_of_player(0)` у клиента — `kNoLevel`: строки нет, «Фальстарт» не показывается.
  - `coop_world_weather.script:169` получает `nil` и берёт свою погоду. Это и сегодняшнее поведение.

**Что правится в Lua после этого.** Только места, где решает `id == 0`, а не список:
- `coop_core_hud.script:221`, `coop_core_chat.script:198`, `coop_hud_netgraph.script:43/144`, `coop_testplan.script:48`;
- `coop_core_player.script:230` (`nick_of(0)`), `coop_menu_char.script:704`;
- `coop_debug_ui.script:1478`, `coop_settings.script:502`, `coop_reward_group.script:61`.

Всё остальное (пункты 6, 9, 10, 12–15, 17, 21, 32, 34) исправляется само, потому что идёт через `coop.players()` или
`session_info()`.

Тесты Lua до кода: `tests/lua/test_env_players_client.lua` (есть) расширить строкой без `plays`. Новый
`tests/lua/test_roster_views.lua`: HUD-вид, `/players`, `others_count`, кнопка денег с одним клиентом.

---

## 2. Звезда и права хоста у персонажа создателя (оператор)

### 2.1 Из чего состоят права хоста сегодня

| Право | Где проверяется | Чем |
|---|---|---|
| Включить/выключить отладку (F7 у всех работает, пока она включена) | `coop_debug.cpp:225` (`coop_debug`), `:299` (`coop_dbg`); правило `coop_debug_rules.h:361-376` `switch_allowed` / `console_allowed` | `is_world_server()`; клиенту `Operator::NotServer` |
| Запросы отладки клиентов | `coop_debug.cpp:584` `refuses_request` | включена ли отладка сервера |
| `/go` | `coop_core_chat.script:212-221` | `api.is_host()` |
| `/go` в консоли сервера | `coop_dedicated_rules.h:265` (`parse_line`), `coop_dedicated.cpp:125` `run_line` | консоль сервера |
| kick | `coop_dedicated.cpp:197-203` `CCC_CoopKick` | `mgr().is_host()` |
| время | `coop_dedicated.cpp:247-253` `CCC_CoopTime` | `is_host()` и ALife |
| откат | `coop_dedicated.cpp:281-291` `CCC_CoopRestore`; в меню `coop_menu.script:2025` `OnRoll` (`api.is_host()`) | `is_host()` |
| автосейв сейчас | `coop_autosave.cpp:656` `coop_autosave_now` | не проверено |
| список игроков | `coop_dedicated.cpp:171-177` `CCC_CoopPlayers` | `is_host()` |
| настройки игры (MCM и правила) | `coop_settings.script:1189` `on_settings_request`, `:1228` `host_tick`, `:1234`, `:1256` | `api.is_host()`: значения машины хоста идут всем |
| настройки существующей игры в окне «Кооператив» | `docs/GAME_SETTINGS.md` §4.2, `coop_menu.script` | `api.is_host()` |
| звезда в HUD | `coop_core_hud.script:221` | `p.id == 0` |

### 2.2 Как сервер узнаёт создателя

**Жетон.** Тот же приём, что у Mk (`coop_mapserver.cpp:217-222`, `coop_session.cpp:1337-1360` `host_bridge_hello`,
правило `coop_mapserver_rules.h:317-331` `hello_verdict`).

1. Тот, кто запускает сервер (игра создателя или лаунчер), делает 128 случайных бит. В движке есть
   `generate_player_key()` (BCrypt, `coop_mapserver.cpp:217`), в лаунчере нужен свой генератор.
2. Сервер получает жетон новым ключом `-coop_operator <hex32>`. Разбор — как `parse_token`
   (`coop_mapserver_rules.h:127`), но в новом чистом `xrCoop/coop_operator.h`.
3. Игра создателя предъявляет его в `HelloMsg::token` (`coop_protocol.h:366`; сегодня у игрока там нули) с
   `role = kHelloRolePlayer`. Игра берёт жетон из памяти (§3) или ключом `-coop_operator <hex>` (лаунчер).
4. Сервер в `host_hello` (`coop_session.cpp:~1263`, после проверки содержимого) зовёт новое правило
   `operator_verdict(loopback, token_matches, bound_key, hello_key)`:
   - не loopback → жетон игнорируется, узел входит обычным игроком (не отказ: иначе жетон стал бы оракулом);
   - жетон не совпал → обычный игрок, строка в лог;
   - совпал, ключ ещё не привязан → оператор; жетон привязывается к ключу этого `Hello`;
   - совпал, ключ привязан и тот же → оператор (повторный вход после вылета игры);
   - совпал, ключ другой → обычный игрок, `!` в лог.
5. Оператор один. Сервер ставит `PeerInfo::host_rights` и рассылает `PeerList` с битом `Operator`.
6. Жетон живёт, пока живёт процесс сервера. Сравнение — за постоянное время.

**Почему не по ключу игрока.** Ключ создателя — его личность (`coop_player.key`). Сервер мог бы помнить его в записи мира
и давать права любому, кто войдёт с этим ключом. Но:
- ключ уходит в `Hello` с любого адреса;
- скопированная папка игры уже давала «чужой» ключ (`coop_session.cpp:1270-1279`).

Права по ключу с удалённого адреса — вопрос 8.3.

### 2.3 Что шлёт оператор

Новое сообщение `OperatorCommand` (клиент → сервер, Reliable, протокол 31): строка до `kMaxConsoleLine` (1024,
`coop_debug_rules.h:378`).

Сервер:
1. `from` — оператор, иначе отказ и счётчик.
2. Чистое правило `operator::allowed(line)` (новое, `coop_operator.h`) — список первых слов:
   - `coop_kick`, `coop_time`, `coop_restore`, `coop_autosave_now`, `coop_players`, `coop_status`;
   - `coop_debug on|off`, `coop_dbg …`;
   - `/go`, `say`;
   - `coop_game_set <ключ> <значение>` (новое, §2.4).
   - Никогда: `quit`, `coop_world`, `coop_host`, произвольная консоль движка (`run_string`, `cfg_*`, `load`, `save <имя>`
     с путём).
3. Выполняет через тот же `run_line` (`coop_dedicated.cpp:125`). Ответ консоли уходит оператору чатом-системой.
   Сегодня `CCC_*` пишут в лог; нужен перехват вывода одной команды — новый `dedicated::run_for(PeerId, line)`.

Rate limit: `kClientRateRules` (`xrCoop/coop_limits.h`) — `OperatorCommand {4, 1000}`.

Lua: `coop.operator_command(line)` (новое) — у оператора шлёт, иначе `false, "not_operator"`.
- `coop_core_chat.script:212` `cmd_go`: `api.has_host_rights()` → `operator_command("/go")`.
- `coop_debug.cpp:225`, `:299`: у клиента-оператора `coop_debug` и `coop_dbg` из своей консоли идут на сервер, а не
  отказываются `NotServer`. Правило `switch_allowed` получает третий аргумент `operator`.
- Окно «Кооператив» (`coop_menu.script:2025` `OnRoll`, `OnHostNow` и §4.2 GAME_SETTINGS): `api.is_host()` →
  `api.has_host_rights()`. Действие идёт командой.

### 2.4 Настройки игры у сервера мира

- Сегодня значения настроек — значения машины хоста. `coop_settings.script:384` `host_snapshot` читает axr и MCM
  процесса хоста.
- Сервер мира — отдельная папка данных с копией `user.ltx`. `axr_options.ltx` копируется только Mk
  (`coop_mapserver.cpp:189-193`). Для сервера мира не проверено.
- Решение: у сервера мира источник — запись игры (`.cgame`, `m_data.coop_game`, `docs/GAME_SETTINGS.md` §3.2-3.3). Всё,
  что создатель выбрал при создании, в ней есть.
- Правка из окна «Кооператив» у оператора — `OperatorCommand coop_game_set <ключ> <значение>`. Сервер правит запись
  (`rev + 1`) и применяет так же, как сегодня правку хоста (`coop_settings.script:1170-1182`).
- Ключи MCM, которых нет в записи, сервер берёт из своей копии `axr_options.ltx`. Её при первом запуске пишет тот, кто
  создал папку сервера: копия с машины создателя, как у Mk.

### 2.5 Безопасность: чего удалённый клиент не может никогда

- Стать оператором не с loopback (правило п.4, тест).
- Стать оператором чужим жетоном после того, как жетон привязан к ключу.
- Прислать `OperatorCommand`, не будучи оператором. Прислать команду вне списка, даже оператором.
- Увидеть жетон. Он не уходит в `PeerList`, лог пишет только «жетон совпал/нет».
- Получить права через ник `server`/`host`. Ник ничего не значит, `sanitize_nick` (`coop_session.cpp:1317`).
- Выдать себя за неиграющее место. `plays = false` сервер ставит только своему месту, клиент `Welcome` не шлёт.
- Mk по-прежнему только с loopback и своим жетоном (`hello_verdict`). Оператор и Mk — разные роли `Hello`, жетоны из
  разных таблиц.

Остаточный риск: на ПК создателя любой процесс того же пользователя может прочитать командную строку сервера и взять
жетон. Он уже может читать `coop_player.key`, так что граница та же. Записать в отчёт, не закрывать.

---

## 3. Поток в игре

### 3.1 «Кооператив → Новая игра», «Раздельные карты» включены

Сегодня:
1. `coop_menu.script:1897` `OnNewGame`.
2. `:1903` `OnModalOk`.
3. `:1991` `HostAfter("new")`: `api.host_when_ready(port)` и стоковый экран `owner:ShowFactionUI()`.
4. Экран нового мира (`coop_newgame_modes.script:434` `on_start_clicked`):
   - `write_rules` → `stage` (`:352`) → `coop_game_settings.stage_new` (`coop_game_settings.script:818`) →
     `coop.game.stage_new` (`coop_game_settings.cpp:161`);
   - потом стоковый `dlg:OnStartGame()`. Он пишет `[character_creation]` и зовёт `self.owner:StartGame()` (сток
     `ui_mm_faction_select.script:1671` и далее).

Новое (шаги игры создателя):

1. **Экран нового мира.** «Раздельные карты» = `c|coop_split_levels` (`coop_game_schema.script:81`).
   - Строка под настройкой: «Мир будет работать отдельным процессом на этом ПК: +2–4 ГБ памяти».
   - Если `GlobalMemoryStatusEx` даёт свободного commit меньше 4 ГБ, строка жёлтая: «Памяти мало: свободно N ГБ».
     Нужен новый `coop.machine_memory()`. Предела нет, выбор не блокируется (решение 20:08).
2. **«Начать».** `on_start_clicked`, если в собранной записи `coop_split_levels = 1`:
   1. `stage` собирает запись как сегодня, но не отдаёт её в `coop.game.stage_new` этого процесса;
   2. на время одного вызова `dlg:OnStartGame()` подменяется `dlg.owner.StartGame` (ловушка `capture_creator`, новое).
      Сток со всеми обёртками GAMMA пишет `[character_creation]`, ловушка читает из неё:
      - `new_game_faction`, `new_game_character_name`, `new_game_icon`;
      - `new_game_loadout`, `new_game_money`, `new_game_map`;
      - флаги мира;
      и сразу их стирает, чтобы одиночная игра не взяла их потом;
   3. закрывает экран, `api.host_when_ready(nil)`;
   4. вызывает `coop.world_server.start{ world = "new", stage = <запись + creator> }` (новое, §3.3).
3. **Экран ожидания** (§3.4) поверх главного меню.
4. Сервер готов → `coop.connect("127.0.0.1:<порт>")` с жетоном. Дальше — обычный вход клиента с его экраном загрузки:
   сохранение мира, Mk карты создателя.
5. Персонажа сервер делает сам (§4). Окна выбора нет.

### 3.2 «Продолжить» / «Играть» мира с раздельными картами

- `coop_menu.script:2012` `OnPlay` и `:2025` `OnRoll` → `HostAfter("save", stem)`.
- Новое: если в карточке мира (`list_games`, `coop_game_settings.script:832`) `values["c|coop_split_levels"] == 1`,
  вместо `load_save` → `coop.world_server.start{ world = "load", save = stem }`.
- Возвращённый создатель находит свой прокси по ключу (`coop_join.cpp:933-943`): окна нет.

### 3.3 Как игра запускает сервер мира (новый модуль движка)

Новый `engine/src/xrGame/coop/coop_world_server.{h,cpp}` по образцу `coop_mapserver.cpp:203-261` `launch`. Чистая часть —
новый `xrCoop/coop_world_server_rules.h`.

| Что | Решение | Почему |
|---|---|---|
| exe | `GetModuleFileNameA(nullptr)` — тот же exe, как у Mk (`coop_mapserver.cpp:225`) | та же VFS, MO2 USVFS доходит до дочернего (`:235`); содержимое совпадёт, иначе `ContentMismatch` |
| ключи | `-fsltx <fsgame_world.ltx> -coop_dedicated <порт> -coop_hidden -coop_new -coop_stage <файл>` или `-coop_load <stem>`; `-coop_operator <hex>`; `-silent_error_mode`; `-coop_nick <имя мира>`; `-dbg`, если у игры `-dbg` | как `command_tail` Mk (`coop_mapserver_rules.h:308-313`); порт — порт хоста из настроек игры (`coop_menu.script` `ReadPort`), тогда Steam-мост лаунчера (`rl-link/src/lib.rs:100`) попадает на сервер без правок |
| fsgame / appdata | `fsgame_world.ltx` рядом с fsgame игры. `$app_data_root$` = соседняя папка `<папка игры>_world` (новая чистая `world_dir`, как `sibling_dir`, `coop_mapserver_rules.h:257`). `$game_saves$` = **папка сейвов игры создателя** (новая чистая `rewrite_saves`) | один список миров: окно «Кооператив» читает карточки `$game_saves$\<id>.cgame` (`GAME_SETTINGS.md` §3.2), лаунчер — те же. Лог, `user.ltx`, `coop_player.key` сервера — свои. Mk сервера получают `appdata_ms<k>` рядом, как сегодня |
| `user.ltx` | копия игры через `map_server_user_ltx` (`coop_mapserver_rules.h:281`) | окно 640×480, `g_always_active on` |
| окружение | блок окружения без `RAYLINK_STEAM_JOIN` и `RAYLINK_STEAM_LOBBY` | иначе `steam_join_waits` (`coop_manager.cpp:133-140`, опрос `:640-643`) превратит сервер в клиента. Mk сегодня наследуют окружение (`CreateProcessA(..., nullptr env ...)`, `coop_mapserver.cpp:236`); влияет ли это на Mk, не проверено |
| stdio | stdin и stdout — каналы. `CREATE_NO_WINDOW` | `-coop_hidden` уже читает stdin из канала, EOF = сохранить и выйти (`coop_host_console.cpp:77-90`, `:133-151`) |
| вывод | новое: при `-coop_hidden` строки, которые прошли бы `log_shown` (`coop_dedicated_rules.h:436`), плюс служебные строки `@rl <событие> <поля>` пишутся в stdout UTF-8 | сегодня при `-coop_hidden` вывода нет вообще: `log_line` пишет только при `g_window` (`coop_host_console.cpp:157-161`) |
| job object | **без** `KILL_ON_JOB_CLOSE` для сервера; сервер сам кладёт свои Mk в свой job (`coop_mapserver.cpp:247-257`) | вылет игры не должен убивать мир без сейва. EOF stdin = сервер сохраняет мир и выходит сам. Убийство джобом теряет минуты игры у всех |

Служебные строки (новое, `coop_world_server_rules.h`, парсер общий для игры и лаунчера):

```
@rl phase starting|world|session|ready|saving|down
@rl ready port=<p>
@rl wait <причина world_wait>
@rl players n=<n>
@rl mapserver level=<имя> state=loading|ready|serving|gone
@rl error <код> <текст>
```

`ready` пишется рядом с `[coop] dedicated: the session is up on port %u` (`coop_manager.cpp:690`). `error` — рядом с
`gave up waiting` (`:677`) и отказом порта.

Lua (новое): `coop.world_server.start{...}` → `true | false, why`; `.state()` → `{ phase, port, progress, error, lines }`;
`.stop()` → пишет `quit\n`; `.running()`.

**Таймауты.**
- Ждать `ready` до 15 минут. Сервер сам сдаётся через 15 минут (`DEDICATED_HOST.md`, «Сессия поднимается сама»).
- Холодный старт GAMMA видели за 376 с (план 2026-11-12, §2A).
- Процесс умер до `ready` → экран ошибки с последними 20 строками и кнопками «Повторить» / «Открыть лог».

### 3.4 Что видит игрок (одна игра, а не две программы)

Окно ожидания — модальное поверх главного меню, в стиле окна «Кооператив» (`coop_menu_theme.script`). Не новый процесс
и не консоль. Фазы по `@rl phase`:

1. «Создаём мир…» / «Открываем мир «<имя>»…» — `starting`, `world` (полоса по `@rl wait`, без процентов, только шаги).
2. «Мир готов. Входим…» — `ready` → `coop.connect`.
3. Дальше штатный экран загрузки клиента со строками входа. Его Mk поднимается сам, сегодняшние строки
   `st_coop_levels_*`.

Внизу маленькая строка «Мир работает на этом ПК (+N ГБ)». Кнопка «Отмена» → `stop()`: сервер сохраняет, если мир уже есть,
и выходит.

### 3.5 Выход, вылеты, смена карты

| Событие | Что происходит |
|---|---|
| Создатель выходит в меню или из игры | Игра пишет `quit` в stdin. Экран «Сохраняем мир…» до `@rl phase down` или выхода процесса (до 60 с, как `server_stop` в ml). Остальные игроки получают «Хост закрыл мир» (обычный конец сессии клиента) |
| Игра создателя вылетела | Канал закрывается → EOF → сервер сохраняет и выходит (`coop_host_console.cpp:84-90`). Мир сохранён, друзья видят конец сессии, как сегодня при вылете хоста, но без потери прогресса. Вариант «мир ждёт создателя N минут» — вопрос 8.2 |
| Сервер вылетел | Игра создателя теряет сессию, как любой клиент. Окно: «Мир закрылся с ошибкой» и «Открыть снова» (запуск из последнего автосейва). Mk умирают с сервером через job сервера |
| Создатель сменил карту | Обычный `LevelMove` клиента. Перезагружается только он. Сервер мира и чужие Mk не меняются |
| Mk карты создателя упал | Как сегодня: `st_coop_levels_server_restart`, повторная загрузка только игроков этой карты |
| Создатель нажал «Отключиться» в окне «Кооператив» | То же, что выход: сервер закрывается с сейвом. Отключиться, оставив мир друзьям, — вопрос 8.2 |

---

## 4. Свой персонаж создателя без второго окна

### 4.1 Сегодня

- **Обычный хост** (не раздельные карты). Персонаж — стоковый актёр процесса.
  - `[character_creation]` пишет сток и читает стоковый `on_game_load`: деньги, снаряжение, `actor_<faction>`
    (`temp/anomaly_unpack/.../ui_mm_faction_select.script:295-360`).
  - Запись игры — `stage_new` → `before_world_start` (`GAME_SETTINGS.md` §3.4, `coop_game_settings.cpp:365-374`).
  - Новый персонаж после хардкора — `host_choose_self`: `coop_menu_char.script:556-564`, заголовок `:63-80`.
- **Клиент без персонажа.**
  - `host_send_world` (`coop_join.cpp:919-956`) → `host_offer_character` (`:869-913`, `Msg::CharOffer`).
  - Клиент: окно `UICoopNewChar` или `-coop_autochoose` (`coop_menu_char.script:1236-1241`, `:1361-1378`) → `CharChoice`
    (`coop_join.cpp:1639-1650`).
  - Хост: `host_on_char_choice` (`:1119`) → `host_make_new_character` (`:987`).
  - Lua хоста: `host_plan_character` (`coop_menu_char.script:617`, проверка покупок по очкам `plan_kit`) →
    `create_proxy` (`coop_join.cpp:554`) → `host_make_character` (`coop_menu_char.script:641`: кит, патроны `ammo_for`,
    деньги `money_set`).
- **Выделенный сервер сегодня.**
  - Мир создаёт `coop_dedicated.script:15-37`: жёсткие `difficulty 1`, `economy 1`, `story true`, `faction stalker`,
    `name server`. Лоадаут и деньги намеренно не берутся.
  - Записи игры нет: лог «no game staged» (`coop_game_settings.cpp:373-374`).
  - Создатель входит как любой клиент: окно выбора.

### 4.2 Новый путь

**Файл нового мира** (`-coop_stage <файл>`, новое).
- Текстовый `coop_new_world.ltx` в папке данных сервера. Пишет игра (§3.1) или лаунчер (§6).
- Секции:
  - `[world]`: `id`, `name`, `title`, `faction`, `story`, `routes`, `difficulty`, `economy`;
  - `[values]`: ключи записи `"<src>|<путь>" = значение`, как `GAME_SETTINGS.md` §3.3;
  - `[creator]`: `name`, `icon`, `loadout` (csv секций), `money`, `map` (стартовая карта или пусто), `bare` (0/1).
- Текст, а не marshal: лаунчер не умеет marshal, а Lua `coop_game_record.new(values, meta)` уже строит запись из пар.

**Кто ставит запись мира (stage).**
- Сервер в `first_frame` (`coop_dedicated.cpp:113`) до `start_world` (`:85`) зовёт Lua
  `coop_dedicated.stage_new_world(path)` (новое). Она:
  - читает файл;
  - строит запись `coop_game_record.new`;
  - кладёт `creator` в запись (новое поле `creator`, пока не `used`);
  - вызывает `coop_game_settings.stage_new` (`coop_game_settings.script:818`).
- Дальше штатно: `before_world_start("new")` берёт запись (`coop_game_settings.cpp:365-374` скажет «a new game is
  staged»).
- `coop_dedicated.script` `new_world_settings` (`:31-37`) пишет `[character_creation]` сервера из `[world]` файла, а не
  из `NEW_WORLD`.
  - `new_game_loadout`, `new_game_money`, `new_game_map` остаются вне (`NEVER`, `:24`): они для персонажа создателя,
    а не для призрака.
  - Имя актёра остаётся `server`: его никто не видит (§1).
- Файл после успешного stage переименовывается в `.used`, чтобы перезапуск не создал второй мир.

**Персонаж создателя.**
- Когда в мир впервые входит **оператор** без прокси, в `host_send_world` (`coop_join.cpp:944`) перед
  `host_offer_character` стоит новая ветка: `creator` в записи есть и не `used` → `host_make_creator(from)` (новое).
  - Синтетический `CharChoiceMsg`: `faction` = `[world] faction`, `buy` = `loadout`.
  - Дальше путь `host_make_new_character` (`coop_join.cpp:987`) с флагом `exact` (новое): Lua не проверяет покупки по
    очкам и выдаёт ровно этот список.
  - `host_plan_character` → новый параметр `exact`. `plan_kit` пропускается, деньги = `creator.money`, старт =
    `faction_starts(faction)` по `creator.map`, если карта из списка группировки (`coop_menu_char.script:358`, `:382`),
    иначе как сегодня.
  - `host_make_character` → с `exact`: те же `alife_create_item` и `ammo_for`, деньги из записи.
  - После успеха `creator.used = true`, запись сохраняется с ближайшим сейвом.
- Имя и иконка персонажа: если у прокси есть имя персонажа (не ник), ставится `creator.name` и `creator.icon`. Есть ли у
  прокси такое поле, не проверено. Если нет — только ник, этап 4 решает.
- Почему только оператору: сделать персонажа без окна может только тот, кто выбрал его в экране нового мира. Другой
  клиент с тем же жетоном невозможен (§2.2).
- **Возвращение.** Прокси найден по ключу (`coop_join.cpp:933-943`) → мир сразу, окна нет.
- **Мир из лаунчера без лоадаута** (`[creator] loadout` пуст, `bare = 0`). Создатель при первом входе получает обычное
  окно `CharOffer`, потому что выбора ещё не было. Это не второй раз, а первый. Вопрос 8.4.
- **Старый мир**, созданный обычным хостом (персонаж хоста — актёр сейва). Блокер `coop_join.cpp:5039-5044`:
  `place_ghost` делает актёра призраком. Перенос — этап 5 (§5.4).

Тесты до кода:
- `tests/test_newchar.cpp` (есть): синтетический выбор из `[creator]`, отказ без жетона;
- новый `tests/test_world_stage.cpp`: разбор файла, обрывы, лишние ключи, длины;
- `tests/lua/test_dedicated.lua` (есть): `stage_new_world` строит запись, `[character_creation]` сервера из `[world]`;
- `tests/lua/test_newchar_exact.lua` (новый): `exact` выдаёт ровно список, деньги из записи, `NEW_VAR` снят.

---

## 5. Удаление старого режима

### 5.1 Что такое старый режим в коде

Процесс хоста — сервер мира и авторитет своей карты, остальные карты на Mk, ход хоста меняет мир (эпоха), мягкий
переход паркует игроков Mk.

| Часть | Где |
|---|---|
| Правило «раздельные карты в процессе хоста» | `game_split()` `coop_levels.cpp:67` (`g_coop_split_levels != 0 \|\| dedicated::on()`), `split()` `:200-205`, `g.host_split` `:415`, `:481` |
| Место хоста, которое играет | `host_seat_self` `:89-103`, `host_seat_going` `:106-115` (`plays = !dedicated::on()`) |
| Карта хоста ведётся его процессом | `led_by_host_process` `:269-276` (Lua `:658`, `:896`), `on_host_level` `:297-305`, `LevelMapMsg::ServerKind::HostProcess` (`coop_levels_wire.h`), `Server::HostProcess` (`coop_levels_rules.h:~90`) |
| Ход хоста в одиночку | `host_alone_through` `coop_join.cpp:1894`, `host_goes_alone` `coop_levels.cpp:393-398`, `host_alone_start` `coop_join.cpp:2718`, `host_alone_go` `:2655`, `host_alone_step` `:2711` |
| Мягкий переход | `coop_soft_move.h` (354 строки; `stays` `:58`, `why_reloads` `:93`, `Stage` `:144`, часы `:215-233`), `host_pick_stays` `coop_join.cpp:2514`, `host_soft_begin/call_off/watch/release/back` `:2560-2650`, `host_soft_window`/`host_soft_stays` `:4048-4050`, `Session::soft_*` (`coop_session.h:155-187`, в `coop_session.cpp` 33 места), `coop_transport.cpp` (7 мест), `coop_mapserver.cpp` (`host_stop_for_move(..., soft)` `:595`, `host_kept` `:631`, `host_keeps` `:651`, `host_soft_over` `:657`, вердикты `:59`, `:645`), `coop_levels_xfer.cpp` (3), `coop_worldstate.cpp` (3), `coop_survival.cpp` (1) |
| Консоль | `coop_soft_host_move` `coop_levels.cpp:38`, `:560` |
| Тесты | `tests/test_soft_move.cpp`; ссылки в `tests/test_dedicated_start.cpp`, `test_trunk.cpp`, `test_transport_helper.cpp` |
| Строки | `gamedata/configs/text/{eng,rus}/st_coop_levels.xml` (`st_coop_load_stays` и строки мягкого перехода) |
| Lua | `coop_levels.script` (`led_by_host_process`), ссылки в `coop_debug_server.script`, `coop_economy_core.script`, `coop_main.script`, `coop_npc_effects.script`, `coop_npc_players.script`, `coop_world_fight.script`; `gamedata/configs/coop_compat_split_levels.ltx` |
| Документы | `docs/SPLIT_LEVELS.md` §7a (мягкий переход), план `2026-10-24-f3a-split-levels.md` |

### 5.2 Что остаётся общим

- Mk целиком: `coop_mapserver.cpp` `launch`, `host_frame`, `host_launch_now` (`:676`), `host_stop_all` (`:593`), мост,
  туннель, `ghost_frame`.
- `levels::Table`, `LevelMove`, `LevelMap`, ворота карт и «вместе» (`effective_gate`), дальний вид, `players_on`,
  `level_of_player`.
- Эпохи мира и `host_world_replaced`. На выделенном мир меняется при `coop_restore` и загрузке после вайпа группы.
- Без раздельных карт — всё: `host_pick_movers` (`coop_join.cpp:2072`), путь группы `:3009`, табло.

### 5.3 Порядок (каждый коммит собирается, «без раздельных» не трогается)

1. **Отрезать вход.** `game_split()` = `dedicated::on()`. `coop_split_levels` у обычного хоста больше не включает
   раздельные карты: настройка теперь решает только, кто поднимает мир (§3). Строка в лог, если значение 1 в процессе
   хоста.
   - Тесты: `tests/test_levels_logic.cpp` — `split()` ложно у хоста при `coop_split_levels 1`.
   - После этого весь код из 5.1 недостижим. Сборка та же.
2. **Мягкий переход.** Удалить:
   - `host_pick_stays`, `host_soft_*`, ветку `soft` в `host_alone_go`, `host_stop_for_move(…, soft)` → один аргумент;
   - `host_kept`, `host_keeps`, `host_soft_over`, вердикты;
   - `Session::soft_*` и места в транспорте;
   - `coop_soft_move.h`, `tests/test_soft_move.cpp`, ссылки в трёх тестах;
   - `coop_soft_host_move`;
   - строки мягкого перехода.
   Перед удалением grep по `softmove::` и `soft_` в xrCoop и xrGame должен показывать только эти места.
3. **Ход хоста в одиночку и карта процесса хоста.** Удалить `host_alone_*`, `host_goes_alone`, `led_by_host_process`
   (и Lua), `on_host_level`, `host_seat_going`. Свести `host_seat_self` к одной строке `plays = false` на выделенном.
   Тип `ServerKind::HostProcess` оставить в проводе до протокола 31, потом убрать.
4. **Lua и документы.** `coop_levels.script` без `led_by_host_process`. Шесть файлов из 5.1 — сверить по одному: многие
   читают `split()` и останутся. `coop_compat_split_levels.ltx` — проверить, нужен ли выделенному. В
   `docs/SPLIT_LEVELS.md` §7a пометить «удалено 2026-11, см. этот документ».

### 5.4 Что со старыми мирами

| Мир | Что будет |
|---|---|
| Создан обычным хостом, `coop_split_levels = 0` | Ничего не меняется |
| Создан обычным хостом, `coop_split_levels = 1` (старый режим) | «Продолжить» видит 1 в карточке → запускает сервер мира с этим сейвом. Актёр сейва — персонаж создателя. Сегодня `place_ghost` делает его призраком (`coop_join.cpp:5039-5044`): создатель потерял бы персонажа. **Этап 5:** при первой загрузке такого сейва сервер переносит актёра в прокси (инвентарь, деньги из книги узла 0, статы, задания, репутация), ключ прокси — ключ оператора при первом входе. Призрак ставится отдельно. Пока этапа нет — отказ с понятным текстом, а не тихая потеря |
| Сделан выделенным из лаунчера ml (`%APPDATA%\RayLink\server\<игра>`) | Тестовые миры. Лаунчер показывает их в списке с пометкой «старое место», кнопка «перенести» копирует в профиль создателя. Можно и не делать: вопрос 8.6 |

---

## 6. Лаунчер

### 6.1 Что есть

На `master` (`D:\Projects\ForEverything\raylink-launcher`):
- **Запуск игры:** `launch_game` (`src-tauri/src/backend.rs:641-669`) → `rl_core::launch::game`
  (`crates/rl-core/src/launch/mod.rs:54-64`). Ключи: `arguments` `:41-53`, `Join::Host` → `-coop_host`,
  `Join::Tunnel(p)` → `-coop_connect 127.0.0.1:p`.
- **Папка игрока:** `settings::player_dir` (`settings.rs:76-88`) = `%APPDATA%\RayLink\profiles\<nick>\<game>`;
  `stand::instance_config` (`stand/mod.rs:1437`) переписывает `$app_data_root$`.
- **«Игра запущена»:** `stand::running_processes` (`stand/mod.rs:941`); используется в `backend.rs:132`, `:224-231`,
  `:271-276`, `:342`, `launch/mod.rs:58`, `stand/mod.rs:247`, `:755`.
- **Сейвы:** только число и время (`stand::game_data`, `stand/mod.rs:660-690`). Миров, `.cgame`, папки сервера нет.
- **Каналы дочернего процесса:** образец `steam.rs:323-345` — stdin/stdout каналы, `CREATE_NO_WINDOW`, поток-читатель,
  `app.emit("steam", …)` `:321`.
- **Отчёты:** `reports/collect.rs:362-380` видит только `profiles\*` и `appdata_ms*`.
- **Живого хвоста лога в UI нет.**

В `raylink-launcher-ml` (не закоммичено, +221/−22 в 15 файлах):
- `launch/mod.rs`: `SERVER_EXE`, `server_arguments`, `server()` с жёсткой ссылкой `bin\RayLinkServer.exe` и stdin-каналом;
- `settings::server_dir`;
- `stand/mod.rs`: `is_server`, `game_processes`, `server_processes`, `server_saves`, `prepare_server`;
- `backend.rs`: `server_view`, `server_start`, `server_stop` (`quit\n`, ждать 60 с);
- UI-панель «Сервер на этом ПК».

### 6.2 Что переносится из ml

| Из ml | Как |
|---|---|
| `SERVER_EXE`, жёсткая ссылка `RayLinkServer.exe`, `is_server`, `game_processes`, `server_processes` | как есть. Затем места «игра запущена» из 6.1 — на `game_processes`, кроме `prepare` (`backend.rs:342`) и `materialize` (`stand/mod.rs:247`): сервер держит файлы стенда |
| `server_arguments` | переписать: `-fsltx fsgame_world.ltx -silent_error_mode -smap2048 -coop_nick <имя мира> -coop_dedicated <порт> -coop_hidden -coop_operator <hex> -coop_new -coop_stage <файл> \| -coop_load <stem>`. Тесты ml на индексы аргументов не брать: на `master` у `arguments` три параметра (`launch/mod.rs:73-94`) |
| `server()` | дописать stdout-канал, `CREATE_NO_WINDOW`, окружение без `RAYLINK_STEAM_*` |
| `settings::server_dir` | **не брать.** Миры живут в `$game_saves$` профиля создателя (§3.3). Папка данных сервера — `<player_dir>_world` (та же чистая функция, что в движке, повторить в Rust с тестом на одинаковый ответ) |
| `prepare_server` | как есть, но писать `fsgame_world.ltx` с `$game_saves$` профиля |
| `server_saves` | заменить на «миры» (6.3) |
| `server_start` / `server_stop`, `Backend.server` | как есть + поток-читатель stdout, событие `server-line` |
| UI-панель ml | не брать: экраны новые (6.5) |

### 6.3 Контракт лаунчер ↔ сервер

**Создать мир (без окна игры).**
1. Лаунчер пишет `coop_new_world.ltx` (формат §4.2) в `<player_dir>_world\`.
   - `[world]` из формы.
   - `[values]` — только тронутые ключи, остальное сервер возьмёт по умолчанию каталога.
   - `[creator]`: `name`, `faction`, `icon`; `loadout` пуст (вопрос 8.4).
2. Каталог настроек для формы: новый `tools/export_game_schema.lua` прогоняет `coop_game_schema.script` в Lua-стенде
   тестов (`tests/lua/runlua.c`) и пишет `gamedata/configs/coop/game_schema.json` (ключ, тип, пределы, умолчание, вкладка,
   id строки). Лаунчер читает его со стенда. Строки берёт из `configs/text/<язык>/st_coop_game*.xml`.
   Тест: `tests/lua/test_game_schema.lua` (есть) сверяет экспорт с каталогом.
3. Запуск сервера с `-coop_new -coop_stage …`. Мир создан, когда пришли `@rl phase ready` и первый автосейв (карточка
   `.cgame` появилась). Лаунчер может держать сервер или сразу сказать `quit`: форма предлагает «Создать» и
   «Создать и запустить».

**Список миров.** Источник — карточки `<player_dir>\savedgames\*.cgame`. Формат — marshal, как у `.scoc`
(`GAME_SETTINGS.md` §3.2).
- Лаунчер marshal не читает. Решение: сервер и игра при каждой записи карточки пишут рядом `<id>.cgame.json` (новое,
  `coop_game_settings.script`, место записи карточки).
- Поля:
  - `id`, `name`, `title`, `faction`, `created`, `last_played`, `last_save`;
  - `split` (значение `c|coop_split_levels`), `players` (ники без сервера, §1, п.7);
  - `size_bytes` — лаунчер считает сам по `last_save` `.scop/.scoc`;
  - `play_minutes` — если запись его хранит; не проверено.

**Запуск и остановка.**
- Старт — `server_start(world_id, port)`: `-coop_load <last_save>`.
- Стоп — `quit\n`, ждать `@rl phase down` или выход до 60 с; потом спросить «завершить принудительно?».
- Лаунчер закрывается при работающем сервере → EOF → сервер сохраняет и выходит. Это `-coop_hidden`
  (`coop_host_console.cpp:84-90`). Отдельно сказать в окне закрытия.

**Консоль.**
- Вход: строка → stdin. Подсказки — команды из `DEDICATED_HOST.md` «Консоль».
- Выход: строки stdout.
  - `@rl …` — не печатаются, а меняют шапку: фаза, порт, игроки, Mk по картам.
  - Остальное — с цветом по `log_shown`: `!`/`FATAL`/`[error]` — красный; `[coop]` — обычный; прочее — серый, скрыто при
    уровне 1.
  - Уровень — `coop_console_log 0|1|2` (`DEDICATED_HOST.md`).
  - Буфер на 5000 строк в Rust (`VecDeque`, как `gameinstall/watch.rs:55`). В UI — последние 500 с автопрокруткой.
- Источник лога для отчёта — файл `xray_*.log` папки сервера. `collect.rs:362` научить видеть `<player_dir>_world` и его
  `appdata_ms*`.

**Войти в мир.**
- `launch_game` с `Join::Tunnel(port)` и новым аргументом `-coop_operator <hex>` (тот же жетон, что у сервера).
- Игра предъявляет его в `Hello` (§2.2). Персонаж — по §4.

**Steam.**
- `join_mode()` при работающем сервере даёт хосту `Join::Tunnel(port)`, а не `Join::Host` (как ml `backend.rs:~416-418`).
- `HostBridge` друзей уже шлёт на `127.0.0.1:<порт>` (`rl-link/src/lib.rs:100`).

### 6.4 Rust-тесты до кода

- `cargo test -p rl-core`:
  - `server_arguments` (новый/загрузка, без `-coop_stage` при загрузке);
  - `world_dir` (совпадает с движком на тех же входах);
  - разбор `@rl` строк;
  - запись `coop_new_world.ltx` (экранирование, длины);
  - чтение `.cgame.json` (битые файлы пропускаются).
- `vitest`: состояния экранов 6.5 из мок-событий.
- e2e на моке процесса (скрипт, который печатает `@rl phase …`).

### 6.5 Экраны (состояния, без визуала)

1. **Миры** — список карточек: имя, группировка, последняя игра, игроки, размер, метка «раздельные карты». Пусто →
   кнопка «Создать мир». Сервер работает → у карточки «Работает: порт, N игроков».
2. **Новый мир**:
   - шаг 1 — имя, группировка, иконка, сложность, экономика, сюжет, открытая Зона;
   - шаг 2 — вкладки настроек из `game_schema.json` (Смерть, Группа, Мир, Сейвы, Прочее), значения по умолчанию;
   - шаг 3 — сводка и предупреждение о памяти (`GlobalMemoryStatusEx`).
   Кнопки «Создать», «Создать и запустить».
3. **Создаётся** — фазы из `@rl phase`, хвост консоли свёрнут. Ошибка → последние строки и «Открыть лог».
4. **Карточка мира** — факты, настройки (только чтение; правка — в игре оператором, §2.4), сейвы (список `.scop` мира,
   свежий первым, без `coop_auto_tmp/bak`), кнопки «Запустить сервер», «Войти в мир», «Открыть папку».
5. **Сервер работает** — шапка (порт, игроки, Mk по картам, память процессов), консоль, ввод, «Войти в мир»,
   «Сохранить сейчас» (`coop_autosave_now`), «Сохранить и остановить».
6. **Останавливается** — ждёт `down`, счётчик 60 с, «Завершить принудительно».
7. **Сервер упал** — код выхода, последние строки, «Запустить из последнего сейва», «Отправить отчёт».

---

## 7. Этапы

Правило: у двух параллельных этапов нет общих файлов. Где файл общий, этапы идут друг за другом.

| # | Этап | Файлы (владеет) | Тесты до кода | Проверка вживую | Зависит | Параллельно с |
|---|---|---|---|---|---|---|
| 1 | **Провод и сессия: место без игры, оператор, жетон.** `Welcome.flags`, `PeerListEntry.flags`, `PeerInfo::plays/host_rights`, `-coop_operator`, `operator_verdict`, привязка к ключу, `OperatorCommand` (приём, лимит), предел сессии без места сервера, протокол 31 | `xrCoop/coop_protocol.{h,cpp}`, `xrCoop/coop_session.{h,cpp}`, `xrCoop/coop_limits.h`, новые `xrCoop/coop_operator.h`, `xrCoop/coop_roster.h` | `tests/test_protocol_game.cpp` (round-trip, обрыв), новые `tests/test_operator.cpp` (loopback, чужой ключ, повторный вход, не оператор, список команд), `tests/test_roster.cpp`, `tests/test_session_limits.cpp` (8 клиентов на выделенном) | `ded_check.ps1` + `split_test.ps1` с `-coop_operator`: в логе сервера «operator: peer N» | — | 2, 6a |
| 2 | **Сервер мира пишет в канал.** `@rl`-строки, вывод `log_shown` в stdout при `-coop_hidden`, общий парсер | `xrEngine/coop_host_console.cpp`, `xrCoop/coop_dedicated_rules.h`, новый `xrCoop/coop_world_server_rules.h` (парсер `@rl`, `world_dir`, `rewrite_saves`), строки в `coop_manager.cpp:677-690` и `coop_dedicated.cpp:156` | `tests/test_dedicated.cpp`: формат и разбор `@rl`, `world_dir`, `rewrite_saves` на путях с пробелами и `\`/`/` | `ded_check.ps1` читает `@rl phase ready` вместо строки лога | — | 1, 6a |
| 3 | **Списки и права в Lua-API.** `l_players`, `l_session_info` через `coop_roster.h`; поля `is_host`; `coop.server_link`, `coop.has_host_rights`, `coop.operator_command`; `host_send_map` без неиграющих; `coop_debug`/`coop_dbg` у оператора; выполнение `OperatorCommand` (`run_for`) | `xrGame/coop/coop_script.cpp`, `xrGame/coop/coop_levels.cpp`, `xrGame/coop/coop_debug.cpp`, `xrCoop/coop_debug_rules.h`, `xrGame/coop/coop_dedicated.{h,cpp}` | `tests/test_debug_rules.cpp` (`switch_allowed` с оператором), `tests/test_levels_logic.cpp` (карта без неиграющих) | клиент на выделенном: панель группы без `server`, `/players` = 1, F7 у оператора включает отладку | 1 | 4 (Lua) после фикса имён API |
| 4 | **Lua: показ и права.** ~10 мест с `id == 0` (§1.3), `/go`, окно «Кооператив» `has_host_rights`, `coop_settings` `< 1` на выделенном, `coop_reward_group` запасной путь, F7 `Page_me`/`BindOverview`, netgraph на `server_link`, testplan | `coop_core_hud.script`, `coop_core_chat.script`, `coop_core_player.script`, `coop_menu.script` (только строки игроков и `OnRoll`), `coop_menu_char.script` (`host_nick`), `coop_settings.script`, `coop_reward_group.script`, `coop_debug_ui.script`, `coop_hud_netgraph.script`, `coop_testplan.script`, `coop_quests_pda.script` | `tests/lua/test_env_players_client.lua` (+строка без `plays`), новый `tests/lua/test_roster_views.lua`, `tests/lua/test_debug_client.lua` | чек-лист владельца: «сервера нигде нет, звезда у меня» | API этапа 3 (можно писать на заглушке одновременно с 3) | 3, 5 |
| 5 | **Мир из файла и персонаж создателя.** `-coop_stage`, `stage_new_world`, `[character_creation]` сервера из `[world]`, поле `creator`, `host_make_creator`, `exact` в `host_plan_character`/`host_make_character`; перенос актёра старого мира в прокси создателя | `xrGame/coop/coop_join.cpp` (`host_send_world`, `host_make_new_character`, место `place_ghost`), `xrCoop/coop_newchar.h`, новый `xrCoop/coop_world_stage.h`, `coop_dedicated.script`, `coop_menu_char.script` (только хостовые функции 617-700), `coop_game_record.script` | `tests/test_newchar.cpp`, новый `tests/test_world_stage.cpp`, `tests/lua/test_dedicated.lua`, новый `tests/lua/test_newchar_exact.lua`, `tests/lua/test_game_record.lua` | `ded_check.ps1 -World new` с файлом: лог «a new game is staged», сложность и сюжет из файла; `split_test.ps1` с жетоном: персонаж создан без окна, кит из файла | 1, 3 | 4, 6a, 7 |
| 6a | **Модуль запуска сервера в движке.** `coop_world_server.{h,cpp}`: процесс, каналы, окружение без Steam, `fsgame_world.ltx`, состояние, Lua `coop.world_server.*`, `coop.machine_memory` | новые `xrGame/coop/coop_world_server.{h,cpp}`, регистрация в `xrGame/coop/coop_script.cpp` — одна строка (после этапа 3 по времени, чтобы не делить файл) | на чистую часть — этап 2; модуль — без тестов exe, только чек | из консоли игры `coop.world_server.start{world="new"}` через `ded_probe.ps1`: процесс есть, `phase ready`, `stop()` сохраняет | 2 | 1, 3, 4, 5 |
| 6b | **Экран нового мира и «Продолжить» в игре.** Ловушка `capture_creator`, запись + `[creator]` в файл, окно ожидания, `coop.connect` с жетоном, выход и вылеты (§3.5), строка памяти | `coop_newgame_modes.script`, `coop_menu.script` (`HostAfter`, `OnPlay`, новое окно ожидания), новый `coop_world_wait.script`, строки `configs/text/*/st_coop_menu*.xml` | новый `tests/lua/test_newgame_split.lua`: ловушка читает и чистит `[character_creation]`, файл собран, `dlg:OnStartGame` без старта мира; `tests/lua/test_games.lua`: «Продолжить» мира со `split = 1` идёт в сервер | **владелец:** «Кооператив → Новая игра → Раздельные карты → Начать»: одна загрузка, персонаж с выбранным китом, окна нет; выход в меню сохраняет мир | 4 (файл `coop_menu.script` после 4), 5, 6a | 7 |
| 7 | **Удаление старого режима.** 4 коммита §5.3 | `xrGame/coop/coop_levels.{h,cpp}` (после 3), `coop_join.cpp` (после 5), `coop_mapserver.{h,cpp}`, `xrCoop/coop_soft_move.h`, `xrCoop/coop_session.*` (после 1), `coop_transport.cpp`, `coop_levels_xfer.cpp`, `coop_worldstate.*`, `coop_survival.cpp` (одна строка), тесты из §5.1, `coop_levels.script`, строки `st_coop_levels.xml` | `tests/test_levels_logic.cpp`: `split()` ложно у обычного хоста при `coop_split_levels 1`; весь набор зелёный после каждого коммита | без раздельных карт: группа ходит вместе как раньше (2 игрока, 3 перехода) | 1, 3, 5 по файлам | 6b, 8 |
| 8 | **Лаунчер.** Перенос из ml (6.2), миры, новый мир, консоль, «Войти», отчёты сервера, `game_schema.json` | `raylink-launcher/src-tauri/crates/rl-core/src/{launch,stand,settings,dto}`, `src-tauri/src/{backend,main}.rs`, `reports/collect.rs`, `src/*.ts`, `src/style.css`; в моде — новый `tools/export_game_schema.lua`, `gamedata/configs/coop/game_schema.json`, `.cgame.json` в `coop_game_settings.script` (место записи карточки) | 6.4 | создать мир из лаунчера, запустить, консоль, войти, выйти — мир на месте; та же карточка видна в игре | 2 (формат `@rl`), 5 (формат файла) | 3–7 |
| 9 | **Приёмка.** 2–3 игрока, мир из игры и мир из лаунчера; ход создателя 10 раз; выход и вылет игры создателя; вылет сервера | — | — | в логах клиентов нет `load:`/`world replaced` по ходу создателя; сервера нигде нет; звезда у создателя; память всех процессов записана | **блокер «неписи воюют»** (5a), 1–8 | — |

Параллельно с самого начала: **1, 2**. После них: **3 + 6a**, затем **4 + 5**, затем **6b + 7 + 8**.

Общие файлы, которые этапы делят по очереди:
- `coop_script.cpp` (3 → 6a);
- `coop_menu.script` (4 → 6b);
- `coop_join.cpp` (5 → 7);
- `coop_levels.cpp` (3 → 7);
- `coop_session.cpp` (1 → 7).

---

## 8. Вопросы владельцу

1. **Сюжетные карты «вместе» в новом режиме.** Сегодня на выделенном окно ожидания выключено: `story_together()` ложно
   при `dedicated::on()` (`coop_levels.cpp:208`). Значит, настройка «Сюжетные карты — вместе» в новом режиме ничего не
   делает. **Рекомендую** вернуть окно: группа едет вместе, грузятся едущие. Иначе настройку убрать из экрана при
   включённых раздельных картах.
2. **Вылет или уход создателя, когда в мире есть друзья.** Сейчас по дизайну мир сохраняется и закрывается
   (EOF = quit). **Рекомендую** так в первой версии. Следом — «мир ждёт создателя 10 минут, если в нём кто-то есть»:
   файл-замок с портом и жетоном в папке сервера, игра при старте находит работающий мир и входит в него.
3. **Права хоста с другого ПК.** Сейчас оператор — только игра на том же ПК по жетону. **Рекомендую** так и оставить.
   Передача прав другу или вход создателя на свой мир с другого ПК — потом, по ключу игрока и подтверждению в консоли
   сервера.
4. **Снаряжение мира из лаунчера.** Выбор кита по очкам требует каталога предметов GAMMA в лаунчере. **Рекомендую:**
   в лаунчере имя, группировка и настройки, а кит создатель выбирает в игре при первом входе (одно окно, первое и
   единственное).
5. **Где лежат миры.** **Рекомендую** в профиле создателя (`profiles\<ник>\<игра>\savedgames`): один список в игре и в
   лаунчере. Папку `server\<игра>` из ветки ml не использовать.
6. **Тестовые миры из ml-лаунчера и старые миры с раздельными картами.** **Рекомендую:** старые миры игры переносить
   (этап 5, перенос актёра в прокси). Миры ml-лаунчера не переносить: это тестовые прогоны.

---

## 9. Что не проверено

- Ничего не собиралось и не запускалось. Игра, лаунчер, MSBuild, `cargo`, `vitest` — нет.
- Lua-аудит §1.2 сделан проходом по файлам. Строки 13–15, 17, 21, 26, 29–31 сверены выборочно (`coop_core_hud.script:221`,
  `coop_core_chat.script:198`, `coop_hud_netgraph.script:43/144`, `coop_testplan.script:48`,
  `coop_economy_core.script:284`, `coop_ui.script:386`). Остальные номера взяты из того прохода без второго чтения.
- Номера строк лаунчера (§6.1, 6.2) взяты из прохода по `raylink-launcher` и `-ml`. Сверены `launch/mod.rs:41-54`,
  `backend.rs:224-226`, `steam.rs:321-334` и список изменённых файлов ml.
- Проверка прав `coop_autosave_now` (`coop_autosave.cpp:656`) не читалась.
- Копирует ли что-то `axr_options.ltx` в папку сервера мира, не проверено (§2.4). Пишет ли клиент свои сейвы в
  `$game_saves$` (важно для общей папки миров, §3.3), не проверено: нашла только `saves_open()` для режима отката
  (`coop_survival.cpp:3321`).
- Наследуют ли Mk `RAYLINK_STEAM_JOIN` и опрашивают ли его, не проверено (`coop_mapserver.cpp:236` передаёт `nullptr`
  как окружение).
- Есть ли у прокси поле имени и иконки персонажа (не ника), не проверено (§4.2).
- Есть ли в записи игры время в игре для карточки лаунчера, не проверено.
- Мягкий переход: число мест (`coop_session.cpp` 33, `coop_join.cpp` 110 и т. д.) — счёт grep по `soft`. Список функций к
  удалению надо пересобрать grep'ом перед этапом 7.
- Блокер «неписи одной группировки воюют» на картах Mk не разбирался.
- Память сервера мира и игры-клиента на GAMMA не мерилась. Цифра +2–4 ГБ — оценка плана 2026-11-12 §2A.
