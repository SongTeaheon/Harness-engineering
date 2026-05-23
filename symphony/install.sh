#!/usr/bin/env bash
# Symphony Python MVP — install + setup script
#
# 멱등(idempotent): 여러 번 실행해도 안전.
# 한 방으로: 시스템 검사 → claude CLI 설치 → venv → 템플릿 생성 → 로그인 트리거 → 안내.

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
skip()    { printf '  %s %s\n' "$(c_blue '·')" "$*"; }
fail()    { printf '%s %s\n' "$(c_red '[install]')" "$*" >&2; exit 1; }

# stdin 이 TTY 일 때만 prompt. (CI/pipe 환경에서는 자동으로 건너뜀)
prompt_yn() {
  local msg="$1"; local ans
  [ -t 0 ] || { skip "TTY 아님 — '$msg' 건너뜀"; return 1; }
  printf '\n  %s [Y/n] ' "$msg"
  read -r ans || return 1
  ans=${ans:-y}
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ── 1. 시스템 전제 검사 ────────────────────────────────────────────
log "1/6 시스템 전제 검사"

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
log "2/6 Claude Code CLI"

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
log "3/6 Python 가상환경"

if [ ! -d "$VENV" ]; then
  python3 -m venv "$VENV"
  ok "venv 생성: $VENV"
else
  skip "venv 존재: $VENV"
fi

"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet -r "$HERE/requirements.txt"
PKG_COUNT=$("$VENV/bin/pip" list --format=freeze | wc -l | tr -d ' ')
ok "Python 의존성 ($PKG_COUNT 패키지)"

# ── 4. 설정/프롬프트/실행 래퍼 템플릿 생성 ────────────────────────
log "4/6 템플릿 파일"

# .env
if [ -f "$HERE/.env" ]; then
  skip ".env 존재 (덮어쓰지 않음)"
elif [ -f "$HERE/.env.example" ]; then
  cp "$HERE/.env.example" "$HERE/.env"
  ok ".env.example → .env 복사"
fi

# config.yaml
if [ -f "$HERE/config.yaml" ]; then
  skip "config.yaml 존재 (덮어쓰지 않음)"
else
  cat > "$HERE/config.yaml" <<'YAML'
# Symphony Python MVP — operational config
# 비밀 값(토큰 등)은 .env 에 둔다.

polling:
  interval_seconds: 30          # 폴링 주기

agent:
  max_concurrent: 3             # 동시 실행 워커 수
  timeout_seconds: 1800         # claude -p 타임아웃 (30분)

workspace:
  root: ./workspaces            # 작업 폴더 루트

branch:
  prefix: symphony/             # task.branch_name 없을 때 생성 규칙

# DB API URL, 토큰, REPO_URL 등은 .env 에서 읽음.
YAML
  ok "config.yaml 생성"
fi

# workflow.md (에이전트 프롬프트 템플릿)
if [ -f "$HERE/workflow.md" ]; then
  skip "workflow.md 존재 (덮어쓰지 않음)"
else
  cat > "$HERE/workflow.md" <<'MD'
You are working on task {{ issue.identifier }}.

**Title**: {{ issue.title }}

**Description**:
{{ issue.description }}

Complete the work on the current branch. When done, commit your changes
with a clear message and stop.
MD
  ok "workflow.md 생성"
fi

# run.sh (실행 래퍼 — activate 불필요)
if [ -f "$HERE/run.sh" ]; then
  skip "run.sh 존재 (덮어쓰지 않음)"
else
  cat > "$HERE/run.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "$HERE/main.py" ]; then
  echo "[run] symphony/main.py 가 아직 없습니다. 구현 필요 (PLAN.md §10)." >&2
  exit 1
fi
cd "$HERE"
exec ./.venv/bin/python main.py "$@"
BASH
  chmod +x "$HERE/run.sh"
  ok "run.sh 생성 (실행 래퍼)"
fi

# ── 5. 인터랙티브 마무리 ──────────────────────────────────────────
log "5/6 인터랙티브 마무리"

# Claude Code 로그인 트리거
if prompt_yn "Claude Code 로그인을 지금 시도할까요? (claude /login)"; then
  if claude /login; then
    ok "로그인 완료"
  else
    log "  로그인 실패/취소 — 나중에 수동으로: claude /login"
  fi
fi

# .env 편집 트리거
if prompt_yn ".env 를 ${EDITOR:-nano} 로 지금 열까요?"; then
  "${EDITOR:-nano}" "$HERE/.env"
  ok ".env 편집 완료"
fi

# ── 6. 완료 안내 ──────────────────────────────────────────────────
log "6/6 완료"
cat <<EOF

준비 완료. 다음 한 줄이면 실행:
  ${HERE}/run.sh

남은 manual 항목 (있다면):
  · claude /login          (위에서 건너뛰었다면)
  · ${HERE}/.env 비밀 값  (위에서 건너뛰었다면)

EOF
