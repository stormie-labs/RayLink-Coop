#!/usr/bin/env bash
# RayLink: the two GitHub repositories and their releases (owner's request 2026-10-24). Needs `gh auth login` first.
#   bash tools/publish_github.sh            private repositories (the launcher's Settings take a read-only key)
#   VISIBILITY=public bash tools/publish_github.sh
# RayLink-Engine    main = this project (gamedata, tools, tests, docs), engine = engine\ (fork of xray-monolith, branch coop)
#                   release b<N> = releases\anomaly-coop-0.<N>.0.zip (tools\package.ps1)
# RayLink-Launcher  main = ..\raylink-launcher; release v0.1.0 = lite\out\RayLinkLauncher.exe built for <owner>/RayLink-Engine
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAUNCHER="$(cd "$ROOT/../raylink-launcher" && pwd)"
VIS="${VISIBILITY:-private}"
BUILD="${BUILD:-16}"
ZIP="$ROOT/releases/anomaly-coop-0.${BUILD}.0.zip"
[ -f "$ZIP" ] || { echo "no $ZIP (powershell -File tools/package.ps1 -Version 0.${BUILD}.0 -Force)"; exit 2; }
gh auth status >/dev/null 2>&1 || { echo "gh is not logged in: run gh auth login"; exit 3; }
gh auth setup-git
OWNER="$(gh api user -q .login)"
echo "owner: $OWNER, visibility: $VIS"

repo_exists() { gh repo view "$1" >/dev/null 2>&1; }

if ! repo_exists "$OWNER/RayLink-Engine"; then
	gh repo create "$OWNER/RayLink-Engine" "--$VIS" \
		--description "RayLink - co-op for S.T.A.L.K.E.R. Anomaly and G.A.M.M.A: engine (fork of xray-monolith) + mod layer"
fi
URL="https://github.com/$OWNER/RayLink-Engine.git"
git -C "$ROOT" push "$URL" HEAD:refs/heads/main
git -C "$ROOT/engine" push "$URL" HEAD:refs/heads/engine
if ! gh release view "b$BUILD" --repo "$OWNER/RayLink-Engine" >/dev/null 2>&1; then
	gh release create "b$BUILD" "$ZIP" --repo "$OWNER/RayLink-Engine" --target main --title "Сборка $BUILD" --notes \
"Сборка $BUILD RayLink (протокол 11; движок $(git -C "$ROOT/engine" rev-parse --short HEAD), проект $(git -C "$ROOT" rev-parse --short HEAD)).
Ставится лаунчером RayLink (кнопка «Обновить сборку») или вручную как мод MO2 (архив с FOMOD).
В ней: переход без отсчёта и затемнения до ухода, удержание [F] «идти с группой» (в т.ч. когда клавишу забирает мод GAMMA),
замирание клиента при молчании хоста (30 с), net graph, A-Life и способности монстров у каждого игрока, выброс/пси-шторм
у каждого, вертолёты, DAO у клиента. В игре проверено не всё — см. docs/STATUS.md."
fi

if ! repo_exists "$OWNER/RayLink-Launcher"; then
	gh repo create "$OWNER/RayLink-Launcher" "--$VIS" --description "RayLink Launcher - one button: update the build, build the stand, play"
fi
(cd "$LAUNCHER" && cmd //c "lite\\build.cmd $OWNER/RayLink-Engine")
git -C "$LAUNCHER" push "https://github.com/$OWNER/RayLink-Launcher.git" HEAD:refs/heads/main
if ! gh release view v0.1.0 --repo "$OWNER/RayLink-Launcher" >/dev/null 2>&1; then
	gh release create v0.1.0 "$LAUNCHER/lite/out/RayLinkLauncher.exe" --repo "$OWNER/RayLink-Launcher" --target main \
		--title "RayLink Launcher 0.1.0" --notes \
"Первый лаунчер RayLink: выбор игры (G.A.M.M.A / Anomaly) слева сверху с запросом путей, скачивание сборки из релизов $OWNER/RayLink-Engine,
сборка стенда жёсткими ссылками (файлы GAMMA и Anomaly не меняются, место почти не занимает; стенд на том же диске, что игра и моды),
запуск хоста или подключение, второе окно для проверки в одиночку. Нужен Windows 10/11 (.NET Framework 4.8 уже в системе).
Для закрытого репозитория: Настройки → ключ GitHub (fine-grained, только чтение Contents)."
fi
echo "done: https://github.com/$OWNER/RayLink-Engine/releases  https://github.com/$OWNER/RayLink-Launcher/releases"
