#!/usr/bin/env bash
# Re-trae las skills de terceros y las de repos propios a plugins/*/skills/.
# Sobrescribe lo que haya — revisa el diff antes de commitear.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND="$ROOT/plugins/backend/skills"
FRONTEND="$ROOT/plugins/frontend/skills"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Skill que ocupa un repo entero (SKILL.md + templates/ + reference/).
sync_repo() {
  local repo="$1" skill="$2"
  echo "==> $repo -> skills/$skill"
  git clone --depth 1 --quiet "https://github.com/$repo.git" "$TMP/$skill"
  rsync -a --delete --exclude '.git' --exclude 'README.md' "$TMP/$skill/" "$BACKEND/$skill/"
}

# Skill de un solo SKILL.md dentro de un repo ajeno.
sync_file() {
  local repo="$1" path="$2" dest="$3" skill="$4" branch="${5:-main}"
  echo "==> $repo:$path -> $skill"
  mkdir -p "$dest/$skill"
  curl -fsSL "https://raw.githubusercontent.com/$repo/$branch/$path" -o "$dest/$skill/SKILL.md"
}

# Skill de varios archivos dentro de un repo ajeno (clone disperso).
sync_subdir() {
  local repo="$1" path="$2" dest="$3" skill="$4"; shift 4
  echo "==> $repo:$path -> $skill"
  git clone --depth 1 --filter=blob:none --sparse --quiet "https://github.com/$repo.git" "$TMP/$skill"
  git -C "$TMP/$skill" sparse-checkout set "$path" >/dev/null
  local excludes=(--exclude '.git' --exclude 'README.md')
  for e in "$@"; do excludes+=(--exclude "$e"); done
  rsync -a --delete "${excludes[@]}" "$TMP/$skill/$path/" "$dest/$skill/"
}

sync_repo JoseLuis21/github-actions-skills github-actions-skills
sync_repo JoseLuis21/docker-golang-skills  docker-golang-skills

sync_file github/awesome-copilot skills/git-commit/SKILL.md "$BACKEND"  git-commit
sync_file github/awesome-copilot skills/git-commit/SKILL.md "$FRONTEND" git-commit

sync_subdir shadcn/ui               skills/shadcn               "$FRONTEND" shadcn evals agents
sync_subdir vercel-labs/agent-skills skills/react-best-practices "$FRONTEND" vercel-react-best-practices

# Las dos owasp-security (backend y frontend) son propias: se editan aqui mismo.

echo "Listo. Revisa: git -C \"$ROOT\" status"
