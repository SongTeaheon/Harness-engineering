#!/usr/bin/env bash
# Symphony Python MVP — install script
#
# 멱등(idempotent): 여러 번 실행해도 안전.
# OS 도구(python3/git/node)는 검사만, 언어 도구는 자동 설치.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$HERE/.venv"
REQ_PY_MAJOR=3
REQ_PY_MINOR=10
REQ_NODE_MAJOR=18

c_blue()  { printf '\033[36m%s\033[0m' "$*"; }
c_green() { printf '\033[32m%s\033[0m' "$*"; }
c_red()   { printf '\033[31m%s\033[0m' "$*"; }
log()     { printf '%s %s\n' "$(c_blue '[install]')" "$*"; }
ok()      { printf '  %s %s\n' "$(c_green '✓')" "$*"; }
fail()    { printf '%s %s\n' "$(c_red '[install]')" "$*" >&2; exit 1; }

# ── 1. 시스템 전제 검사 ────────────────────────────────────────────
log "1/4 시스템 전제 검사"

command -v git >/dev/null \
  || fail "git 가 필요합니다. (macOS: brew install git / Debian: apt install git)"
ok "git: $(git --version)"

command -v python3 >/dev/null \
  || fail "python3 가 필요합니다. Python ${REQ_PY_MAJOR}.${REQ_PY_MINOR}+ 를 설치하세요."
PYV=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
PYV_MAJOR=${PYV%.*}
PYV_MINOR=${PYV#*.}
if [ "$PYV_MAJOR" -lt "$REQ_PY_MAJOR" ] \
   || { [ "$PYV_MAJOR" -eq "$REQ_PY_MAJOR" ] && [ "$PYV_MINOR" -lt "$REQ_PY_MINOR" ]; }; then
  fail "Python ${REQ_PY_MAJOR}.${REQ_PY_MINOR}+ 필요 (현재 ${PYV})"
fi
ok "python3: $PYV"

# ── 2. Claude Code CLI ────────────────────────────────────────────
log "2/4 Claude Code CLI"

if command -v claude >/dev/null; then
  ok "claude: $(claude --version 2>/dev/null || echo 'installed')"
else
  command -v npm >/dev/null \
    || fail "claude 설치에 npm 이 필요합니다. Node.js ${REQ_NODE_MAJOR}+ 를 먼저 설치하세요."
  NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]')
  if [ "$NODE_MAJOR" -lt "$REQ_NODE_MAJOR" ]; then
    fail "Node.js ${REQ_NODE_MAJOR}+ 필요 (현재 v$(node -v))"
  fi
  log "  claude 미설치 → npm 전역 설치"
  if npm install -g @anthropic-ai/claude-code; then
    ok "claude 설치 완료"
  else
    fail "claude 설치 실패. 권한 문제면 'sudo npm install -g @anthropic-ai/claude-code'"
  fi
fi

# ── 3. Python venv + 의존성 ───────────────────────────────────────
log "3/4 Python 가상환경"

if [ ! -d "$VENV" ]; then
  python3 -m venv "$VENV"
  ok "venv 생성: $VENV"
else
  ok "venv 존재: $VENV"
fi

"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet -r "$HERE/requirements.txt"
PKG_COUNT=$("$VENV/bin/pip" list --format=freeze | wc -l | tr -d ' ')
ok "Python 의존성 설치 완료 ($PKG_COUNT 패키지)"

# ── 4. .env 초기화 ────────────────────────────────────────────────
log "4/5 .env 초기화"

if [ -f "$HERE/.env" ]; then
  ok ".env 이미 존재 (덮어쓰지 않음)"
elif [ -f "$HERE/.env.example" ]; then
  cp "$HERE/.env.example" "$HERE/.env"
  ok ".env.example → .env 복사 (실제 값으로 채우세요)"
else
  log "  .env.example 없음 — 건너뜀"
fi

# ── 5. 최종 안내 ──────────────────────────────────────────────────
log "5/5 완료"
cat <<EOF

설치 완료. 다음 단계:

  1) Claude Code 로그인 (최초 1회):
       claude /login

  2) .env 에 실제 값 채우기 (DB_API_TOKEN, JIRA_API_TOKEN 등):
       \$EDITOR ${HERE}/.env

  3) 가상환경 활성화:
       source ${VENV}/bin/activate

  4) 설정 파일 작성 (참고: PLAN.md §9):
       ${HERE}/config.yaml
       ${HERE}/workflow.md

  5) 실행:
       python -m symphony.main

EOF
