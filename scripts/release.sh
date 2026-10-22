#!/bin/bash
# Publishes the next release. The version comes from the Conventional Commits since the last v* tag
# (see scripts/next-version.swift and CONTRIBUTING.md): while Mate is 0.x, feat → minor and fix/perf → patch, and
# 1.0.0 comes only from --major or a hand-edited VERSION. 0.x releases are published as GitHub pre-releases.
# The notes are bilingual: Spanish, "<!-- en -->", English. A notes file of your own must keep that separator.
# Usage: scripts/release.sh [--dry-run] [--major] [notes.md]
set -euo pipefail
cd "$(dirname "$0")/.."
# The version always comes from VERSION: a MATE_VERSION left in the shell would build a mislabeled DMG.
unset MATE_VERSION
DRY=0
MAJOR=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --major) MAJOR=(--major); shift ;;
    *) break ;;
  esac
done
NOTES=$(mktemp)
trap 'rm -f "$NOTES"' EXIT
NEXT=$(swift scripts/next-version.swift ${MAJOR[@]+"${MAJOR[@]}"} "$NOTES" 2>/dev/null | tail -1)
if [ "$NEXT" = "none" ]; then
  echo "No hay commits feat, fix ni perf desde el último release: no hay nada que publicar."
  exit 0
fi
if [ -z "$NEXT" ]; then echo "No se pudo calcular la versión (scripts/next-version.swift)." >&2; exit 1; fi
if [ $# -gt 0 ]; then
  cp "$1" "$NOTES"
  grep -q '<!-- en -->' "$NOTES" || { echo "Las notas tienen que traer el separador <!-- en --> (español arriba, inglés abajo)." >&2; exit 1; }
fi
PRERELEASE=()
case "$NEXT" in 0.*) PRERELEASE=(--prerelease) ;; esac
echo "Próxima versión: $NEXT${PRERELEASE[@]+ (pre-release)}"
echo
cat "$NOTES"
[ $DRY = 1 ] && exit 0

command -v gh >/dev/null || { echo "Falta gh (GitHub CLI)." >&2; exit 1; }
git remote get-url origin >/dev/null 2>&1 || { echo "No hay remoto origin (github.com/Coru29/mate)." >&2; exit 1; }
# Untracked files (like a notes file you just wrote) don't count; changes to tracked files do.
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "Hay cambios sin commitear." >&2; exit 1; }
scripts/test.sh >/dev/null || { echo "Fallan los tests." >&2; exit 1; }
scripts/check-localization.sh >/dev/null || { echo "Faltan traducciones (scripts/check-localization.sh)." >&2; exit 1; }
if [ "$(tr -d '[:space:]' < VERSION)" != "$NEXT" ]; then
  echo "$NEXT" > VERSION
  git add VERSION
  git commit -q -m "chore(release): v$NEXT"
fi
scripts/dmg.sh
# Releases must carry the project's signing certificate: installed copies only accept an update signed with it, and
# it is what keeps macOS's "Permitir siempre" keychain answers. An ad-hoc build is never published.
codesign -d -r- build/Mate.app 2>&1 | grep -q "certificate leaf" || { echo "El build no tiene la firma del proyecto (scripts/sign.sh)." >&2; exit 1; }
BUILT=$(plutil -extract CFBundleShortVersionString raw build/Mate.app/Contents/Info.plist)
[ "$BUILT" = "$NEXT" ] || { echo "El build dice $BUILT y el release es $NEXT: no se publica." >&2; exit 1; }
COMMIT=$(git rev-parse HEAD)
git push origin HEAD
# The release creates its tag on GitHub at that exact commit, in the same step: there is never a pushed tag without
# its release (installed copies would find nothing to download) nor a release without its tag.
if ! gh release create "v$NEXT" build/Mate.dmg --target "$COMMIT" --title "Mate $NEXT" --notes-file "$NOTES" \
    ${PRERELEASE[@]+"${PRERELEASE[@]}"}; then
  echo "No se pudo crear el release. El commit ya está en GitHub; para reintentar:" >&2
  echo "  gh release delete v$NEXT --yes --cleanup-tag 2>/dev/null; scripts/release.sh" >&2
  echo "(si quedó un release a medias sin Mate.dmg: gh release upload v$NEXT build/Mate.dmg)" >&2
  exit 1
fi
git fetch -q origin "refs/tags/v$NEXT:refs/tags/v$NEXT"
echo "Publicado: https://github.com/Coru29/mate/releases/tag/v$NEXT"
