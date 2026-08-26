#!/usr/bin/env bash
# Re-trae las skills desde sus repos de origen a plugins/backend/skills/.
# Sobrescribe lo que haya — revisa el diff antes de commitear.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/plugins/backend/skills"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Skill que ocupa un repo entero (SKILL.md + templates/ + reference/).
sync_repo() {
  local repo="$1" skill="$2"
  echo "==> $repo -> skills/$skill"
  git clone --depth 1 --quiet "https://github.com/$repo.git" "$TMP/$skill"
  rsync -a --delete --exclude '.git' --exclude 'README.md' "$TMP/$skill/" "$DEST/$skill/"
}

# Skill de un solo SKILL.md dentro de un repo ajeno.
sync_file() {
  local repo="$1" path="$2" skill="$3" branch="${4:-main}"
  echo "==> $repo:$path -> skills/$skill"
  mkdir -p "$DEST/$skill"
  curl -fsSL "https://raw.githubusercontent.com/$repo/$branch/$path" -o "$DEST/$skill/SKILL.md"
}

sync_repo JoseLuis21/github-actions-skills github-actions-skills
sync_repo JoseLuis21/docker-golang-skills  docker-golang-skills

sync_file github/awesome-copilot     skills/git-commit/SKILL.md     git-commit

# owasp-security no se sincroniza: es propia y se edita aqui mismo.

echo "Listo. Revisa: git -C \"$ROOT\" status"
