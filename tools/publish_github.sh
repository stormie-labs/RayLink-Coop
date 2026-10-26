#!/usr/bin/env bash
# RayLink on GitHub (owner's layout 2026-10-24): three repositories and their releases. Needs `gh auth login` first.
#   OWNER=stormie-labs bash tools/publish_github.sh        (VISIBILITY=private for closed repositories; BUILD=<N>)
# RayLink-Engine    main = one commit per build with the tree of engine\ (branch coop): the history of xray-monolith (74
#                   authors) stays local and upstream, not on GitHub (owner 2026-10-26); release b<N> = the engine exe
# RayLink-Coop      main = this project (gamedata, tools, tests, docs); release b<N> = releases\anomaly-coop-0.<N>.0.zip
#                   (tools\package.ps1: the build the launcher installs)
# RayLink-Launcher  main = ..\raylink-launcher; release v0.1.0 = RayLinkLauncher.exe + RayLinkSetup.exe (channel RayLink-Coop)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAUNCHER="$(cd "$ROOT/../raylink-launcher" && pwd)"
VIS="${VISIBILITY:-public}"
BUILD="${BUILD:-16}"
ZIP="$ROOT/releases/anomaly-coop-0.${BUILD}.0.zip"
ENGINE_EXE="$ROOT/engine-ci/_build/_game/bin_dbg/AnomalyDX11AVX.exe"
[ -f "$ZIP" ] || { echo "no $ZIP (powershell -File tools/package.ps1 -Version 0.${BUILD}.0 -Force)"; exit 2; }
gh auth status >/dev/null 2>&1 || { echo "gh is not logged in: run gh auth login"; exit 3; }
gh auth setup-git
OWNER="${OWNER:-$(gh api user -q .login)}"
echo "owner: $OWNER, visibility: $VIS, build $BUILD"

repo_exists() { gh repo view "$1" >/dev/null 2>&1; }
ensure_repo() { repo_exists "$OWNER/$1" || gh repo create "$OWNER/$1" "--$VIS" --description "$2"; }

ensure_repo RayLink-Engine "RayLink Engine - co-op engine for S.T.A.L.K.E.R. Anomaly 1.5.3 (fork of themrdemonized/xray-monolith with a network layer)"
# This build's tree as one commit on top of what main has now (a plain push, never a force). The local branch `publish`
# names it.
publish_engine() {
	local url="https://github.com/$OWNER/RayLink-Engine.git" prev tree snap uid
	prev="$(git ls-remote "$url" refs/heads/main | cut -f1)"
	tree="$(git -C "$ROOT/engine" rev-parse 'HEAD^{tree}')"
	if [ -n "$prev" ]; then
		git -C "$ROOT/engine" fetch -q "$url" main
		if [ "$(git -C "$ROOT/engine" rev-parse "$prev^{tree}")" = "$tree" ]; then
			echo "engine: main already has this tree"
			return
		fi
	fi
	uid="$(gh api user -q .id)"
	local mail="$uid+$OWNER@users.noreply.github.com"
	snap="$(GIT_AUTHOR_NAME="$OWNER" GIT_AUTHOR_EMAIL="$mail" GIT_COMMITTER_NAME="$OWNER" GIT_COMMITTER_EMAIL="$mail" \
		git -C "$ROOT/engine" commit-tree "$tree" ${prev:+-p "$prev"} -m "RayLink Engine, build $BUILD")"
	git -C "$ROOT/engine" branch -f publish "$snap"
	git -C "$ROOT/engine" push "$url" "$snap:refs/heads/main"
}
publish_engine
ensure_repo RayLink-Coop "RayLink - co-op layer for S.T.A.L.K.E.R. Anomaly and G.A.M.M.A (scripts, configs, UI, mod compatibility)"
git -C "$ROOT" push "https://github.com/$OWNER/RayLink-Coop.git" HEAD:refs/heads/main

ENGINE_SHA="$(git ls-remote "https://github.com/$OWNER/RayLink-Engine.git" refs/heads/main | cut -c1-8)"
PROJECT_SHA="$(git -C "$ROOT" rev-parse --short HEAD)"
if ! gh release view "b$BUILD" --repo "$OWNER/RayLink-Coop" >/dev/null 2>&1; then
	gh release create "b$BUILD" "$ZIP" --repo "$OWNER/RayLink-Coop" --target main --title "Сборка $BUILD" --notes \
"Сборка $BUILD RayLink: движок $OWNER/RayLink-Engine $ENGINE_SHA + надстройка $PROJECT_SHA, протокол 14.
Ставится лаунчером RayLink (кнопка «Обновить сборку») или вручную как мод MO2 (архив с FOMOD). Что проверено — docs/STATUS.md."
fi
if [ -f "$ENGINE_EXE" ] && ! gh release view "b$BUILD" --repo "$OWNER/RayLink-Engine" >/dev/null 2>&1; then
	STAGE="$ROOT/temp/engine_rel"
	mkdir -p "$STAGE" && cp "$ENGINE_EXE" "$STAGE/AnomalyCoopDX11AVX.exe"
	gh release create "b$BUILD" "$STAGE/AnomalyCoopDX11AVX.exe" --repo "$OWNER/RayLink-Engine" --target main \
		--title "RayLink Engine, сборка $BUILD" --notes \
"Движок RayLink для S.T.A.L.K.E.R. Anomaly 1.5.3 (DX11 AVX), коммит $ENGINE_SHA, протокол 14.
Для игры нужна надстройка $OWNER/RayLink-Coop — её сборка уже содержит этот exe."
fi

ensure_repo RayLink-Launcher "RayLink Launcher - one button: update the build, build the stand, play"
(cd "$LAUNCHER" && cmd //c "lite\\build.cmd $OWNER/RayLink-Coop")
git -C "$LAUNCHER" push "https://github.com/$OWNER/RayLink-Launcher.git" HEAD:refs/heads/main
echo "launcher release: build lite\\out\\rel\\RayLinkLauncher.exe and RayLinkSetup.exe, then"
echo "  gh release upload v0.1.0 <both> --repo $OWNER/RayLink-Launcher --clobber"
echo "done: https://github.com/$OWNER/RayLink-Coop/releases  https://github.com/$OWNER/RayLink-Engine/releases"
