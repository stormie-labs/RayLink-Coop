# Переезд тяжёлой работы с игрового ПК на сервер (Р100, 2026-11-25)

Цель: игровой ПК владельца только играет. Агенты (Claude Code, Codex/Sol), сборка движка (MSBuild), сборка лаунчера
(cargo, npm), тесты и стенды работают на сервере под Proxmox в Windows-ВМ. Перевод на Linux не нужен: в ВМ тот же MSVC.

## Что стоит на ПК сейчас (проверено 2026-11-25 22:55)

| Что | Версия |
|---|---|
| Visual Studio Build Tools 2022 | 17.14.36915.13, MSVC 14.44.35207, Windows SDK 10.0.26100.0 |
| Rust | 1.99.1, `stable-x86_64-pc-windows-msvc` |
| Node / npm | 24.13.0 / 11.6.2 |
| Python / uv | 3.14.2 / 0.12.15 |
| Git / gh | 2.52.0 / 2.101.0 |
| Codex (приложение, `codex.exe` для Sol) | 26.1117.4957.0 |
| Claude Code | npm (`%APPDATA%\npm\claude.ps1`) |

Диски ПК: C: свободно 0 ГБ, D: 2 ГБ, E: 114 ГБ.

## Что переезжает

- Мод и движок: `D:\Projects\ForEverything\anomaly-coop` (вместе с `engine`, `engine-ci`), `D:\Projects\ForEverything\anomaly-ref`.
- Лаунчер: репозиторий `raylink-launcher` и рабочие копии `E:\RayLinkRustCache\wt-launcher-*`, `E:\coop-sol\launcher-rc3` (там же
  текущий cargo target).
- Движок на Rust: `D:\Projects\RayLink Engine Rust Optimized`.
- Стенд: `E:\RayLinkGames\GAMMA\game-dev` и копия `E:\coop-stand-b61` (около 77 ГБ каждый, большие файлы — жёсткие ссылки).
- Хранилище заметок `D:\Projects\OpenCode Vault`: агенты в ВМ должны его читать и писать. Варианты: перенести в ВМ и открыть
  владельцу общей папкой, или синхронизация (Syncthing / git). Решает ведущая при переезде.
- Входы (gh, Codex, Claude) переносить нельзя: владелец входит в ВМ сам. Секреты в файлы не копируются.

## Размер ВМ (ориентир, уточнить по железу сервера)

- 12+ vCPU, 32–48 ГБ RAM; диск 600+ ГБ NVMe (репозитории, кэши cargo/MSBuild, два стенда).
- Видеокарта, проброшенная в ВМ (IOMMU), + заглушка HDMI + Sunshine/Parsec — только для стендов с окном игры.
  Без неё в ВМ идут сборки, Lua- и нативные тесты, сервер мира.

## Порядок

1. Владелец: железо сервера (CPU, RAM, диски, видеокарта), доступ (SSH или IPMI), проверка питания и земли
   (инцидент «сервер выключается при подключении патчкорда», Stormie Infra 13).
2. Proxmox на сервер (чистая установка), Windows 11 в ВМ с драйверами VirtIO.
3. Инструменты в ВМ теми же версиями (winget: `Microsoft.VisualStudio.2022.BuildTools` с нагрузкой C++ и SDK 26100,
   `Rustlang.Rustup`, `OpenJS.NodeJS` 24, `Python.Python.3.14`, `astral-sh.uv`, `Git.Git`, `GitHub.cli`), приложение Codex,
   Claude Code.
4. Репозитории — клонами с GitHub, большие кэши и стенды — копией по сети (robocopy /MIR), с проверкой хешей exe.
5. Проверка в ВМ: сборка движка (`temp/build_guarded_fast.ps1`), `cargo test -p rl-core`, `npm run check` + vitest, Lua-тесты,
   `sp_smoke` на стенде (после проброса видеокарты).
6. Сессия Claude Code переходит в ВМ. На ПК остаются игра и лаунчер.

## До переезда

- Пока владелец играет, тяжёлая работа на ПК стоит (Р98).
- Сборки на ПК — с пониженным приоритетом и ограничением потоков, чтобы не забирать машину целиком.
