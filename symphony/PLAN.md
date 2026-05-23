# Symphony Python MVP — 구현 계획

> 분석 배경은 [`ANALYSIS.md`](./ANALYSIS.md) 참고.
> 이 문서는 "무엇을, 어떻게 만들지"를 정의한다.

---

## 1. 목표

작업 처리 파이프라인을 자동화한다:

```
DB 조회 API로 작업 대상 가져오기  →  에이전트가 작업 수행  →  상태변경 API 호출
```

원본 OpenAI Symphony를 참고하되, Linear → 자체 DB API, Codex → Claude Code CLI로
교체하고 MVP 범위로 축소한다.

---

## 2. 확정된 결정 사항

| 항목 | 결정 | 비고 |
|---|---|---|
| 구현 언어 | Python | |
| 범위 | 최소 MVP | 컨퍼먼스 추구 안 함 |
| 코딩 에이전트 | Claude Code CLI 헤드리스 (`claude -p`) | |
| 코드 위치 | 현재 레포 신규 디렉터리 (`symphony/`) | |
| 동시 실행 | **필요** | → `in_progress` 찜 필수 |
| 작업 대상 소스 | 자체 DB 조회 API (REST) | |
| 상태 변경 | DB 상태변경 API | `in_progress` / `done` / `failed` |

---

## 3. 핵심 설계 원리 — "DB 상태 = 찜(claim)"

원본 Symphony가 메모리에 복잡한 상태머신(`claimed`/`running`/`retry_attempts`)을
드는 이유는 Linear 이슈 상태를 함부로 못 바꾸기 때문이다.

본 프로젝트는 **상태변경 API가 있다.** 따라서:

```
작업을 집으면  → 즉시 in_progress 로 변경   ← 이게 곧 "찜"
작업 끝나면    → done 으로 변경
작업 실패하면  → failed 로 변경
```

DB 조회는 항상 `status=todo`만 가져오므로, `in_progress`로 바꾸는 순간 다음
폴링에서 자동으로 제외된다. **중복 디스패치 방지가 공짜로 해결**되고, 메모리
상태머신·재시도 큐·reconcile이 대부분 불필요해진다. **DB가 곧 상태 저장소.**

---

## 4. 범위 — IN / OUT

### ✅ IN (MVP 필수 6요소)

| # | 요소 | 내용 |
|---|---|---|
| 1 | 설정 파일 | YAML 하나. front matter 파싱 불필요 |
| 2 | DB API 어댑터 | `조회` + `상태변경` 두 함수 |
| 3 | 폴링 루프 | `while True: 조회 → 디스패치 → sleep` |
| 4 | 워크스페이스 | 작업마다 폴더 + `git clone` |
| 5 | 에이전트 실행 | `subprocess`로 `claude -p` 실행 후 대기 |
| 6 | 상태변경 | 시작 시 `in_progress`, 종료 시 `done`/`failed` |

### ❌ OUT (MVP 제외)

| 제외 항목 | 제외 근거 |
|---|---|
| 메모리 5단계 상태머신 | DB 상태(`todo`/`in_progress`/`done`/`failed`)가 대신 |
| 재시도 큐 + 지수 백오프 | 실패 시 `failed`로 둠. 재시도는 후순위 |
| Reconcile (실행 중 외부 취소 감지) | 작업이 짧으면 불필요. `fetch_states_by_ids` 미구현 |
| 연속 턴 (`max_turns`) | 에이전트가 한 번에 끝냄 |
| Stall timeout 감시 스레드 | `subprocess` 자체 timeout으로 대체 |
| 동적 `WORKFLOW.md` watch/reload | 설정 변경 시 재시작 |
| HTTP 서버 / 대시보드 | 로그로 충분 |
| SSH 워커 (Appendix A) | 단일 머신 |
| 워크스페이스 재사용 / 시작 sweep | 매번 새 폴더 사용 |
| Codex app-server JSON 프로토콜 | 헤드리스 CLI가 통째로 대체 |
| 토큰 회계 / 메트릭 집계 | 관측용. 로그로 충분 |

### ⚠️ 유지 필수 (단순화 불가)

- **워크스페이스 안전 불변식 3종** — 경로 격리는 보안. 절대 빼지 않는다.
- **subprocess 타임아웃** — 멈춘 에이전트 방어.
- **`finally`에서 슬롯 반납** — 안 하면 슬롯이 영영 막힘.

---

## 5. 오케스트레이터 설계 (동시 실행 버전)

### 큰 그림

```
메인 스레드 (폴링 루프) — 절대 블로킹 안 됨
   │
   ├─ DB 조회 (todo)
   ├─ 빈 슬롯만큼:
   │     ① in_progress 찜 (동기, 응답 확인)
   │     ② 워커를 백그라운드로 던짐 ──┐
   └─ sleep(N)                       │
                                     ▼
                          워커 스레드들 (동시 최대 N개)
                          각자: 워크스페이스 → 에이전트 → done/failed
```

메인 루프는 워커를 던지기만 하고 절대 기다리지 않는다 → 폴링 주기 유지.

### `in_progress` 찜 타이밍 — 핵심 규칙

순서는 반드시 **① 찜 → ② 슬롯 점유 → ③ 워커 spawn.**

- 찜은 **메인 루프에서, 워커 spawn 전에, 동기적으로** (응답 확인 후 진행).
- 찜이 워커 안에서 늦게 일어나면: `git clone` 등 느린 작업 중 다음 tick이 같은
  작업을 또 잡아 **중복 실행**된다.
- 찜 API가 실패하면 워커를 띄우지 않고 `continue` → 작업은 `todo`로 남아 다음
  tick에 자연 재시도 (공짜 재시도).
- 느리고 오래 걸리는 일(clone, 에이전트 실행)은 전부 찜 이후에 둔다.

### 동시성 제어

- `ThreadPoolExecutor(max_workers=N)` — 동시성 제한이 공짜.
- `claude -p`는 별도 subprocess라 GIL을 잡지 않으므로 워커는 **스레드로 충분**
  (multiprocessing 불필요).
- 진행 중 작업 ID 집합 `in_flight`(+`threading.Lock`)로 같은 프로세스 내 이중
  안전망. 빈 슬롯 = `N - len(in_flight)`.

### 골격 코드

```python
from concurrent.futures import ThreadPoolExecutor
import threading, time

in_flight = set()
lock = threading.Lock()
MAX = 5
pool = ThreadPoolExecutor(max_workers=MAX)

def 폴링루프():
    while True:
        tasks = db_api.fetch(status="todo")
        with lock:
            빈슬롯 = MAX - len(in_flight)
        for task in tasks[:빈슬롯]:
            with lock:
                if task.id in in_flight:
                    continue
            branch_name = task.branch_name or f"symphony/{task.identifier}"
            ok = db_api.set_status(task.id, "in_progress",
                                   branch_name=branch_name)   # ① 찜 (동기)
            if not ok:
                continue
            with lock:
                in_flight.add(task.id)                         # ② 슬롯 점유
            pool.submit(워커, task, branch_name)                # ③ 백그라운드 spawn
        time.sleep(POLL_INTERVAL)

def 워커(task, branch_name):
    ws = None
    try:
        ws = 워크스페이스준비(task, branch_name)               # A
        prompt = 프롬프트(task, TEMPLATE)
        ok, output = 에이전트실행(ws, prompt)                   # B (응답도 반환)
        db_api.set_status(
            task.id,
            "done" if ok else "failed",
            result=output,                                      # Claude 응답
            branch_name=branch_name,                            # 작업 브랜치
        )
    except Exception as e:
        log(task.id, "실패", e)
        db_api.set_status(task.id, "failed",
                          result=str(e), branch_name=branch_name)
    finally:
        if ws:
            shutil.rmtree(ws, ignore_errors=True)
        with lock:
            in_flight.discard(task.id)                          # ④ 슬롯 반납
```

---

## 6. 워커 내부 설계

### A. 워크스페이스 준비

```
경로: <workspace.root> / <sanitize(identifier)>
```

- **sanitize**: `[A-Za-z0-9._-]`만 허용, 나머지 `_`로 치환.
- **경로 검증**: 절대경로 정규화 후 root가 prefix인지 확인 (탈출 차단).
- **코드 채우기**: `git clone --depth 1 <REPO_URL> .`, 필요 시 `branch_name` 체크아웃.
- 훅 시스템은 일반화하지 않고 `git clone`을 코드에 직접 호출.
- 작업 종료 시 폴더 삭제 (재사용 안 함).

```python
import re, os, subprocess

def sanitize(identifier):
    return re.sub(r'[^A-Za-z0-9._-]', '_', identifier)

def 워크스페이스경로(root, identifier):
    path = os.path.abspath(os.path.join(root, sanitize(identifier)))
    root = os.path.abspath(root)
    if not path.startswith(root + os.sep):          # 안전 불변식 2
        raise ValueError(f"경로 탈출 시도: {path}")
    return path

def 워크스페이스준비(task, branch_name):
    ws = 워크스페이스경로(ROOT, task.identifier)
    os.makedirs(ws, exist_ok=True)
    subprocess.run(["git", "clone", "--depth", "1", REPO_URL, "."],
                   cwd=ws, check=True, timeout=120)
    subprocess.run(["git", "checkout", "-b", branch_name],
                   cwd=ws, check=True)
    return ws
```

### B'. 프롬프트 전략 — 고정 + Jira 키 위임

DB가 작업 내용(title/description)을 들고 있지 않는다. 대신 **Jira 키만 전달**하고
에이전트가 Jira skill 로 직접 읽는다.

`workflow.md` (고정 템플릿):
```md
Jira 티켓 {{ issue.identifier }} 를 보고, 거기 적힌 스펙에 맞도록
개발하세요.

규칙:
- Jira skill 로 티켓 본문/코멘트/링크된 자료를 직접 읽으세요.
- 작업은 현재 git 브랜치에서 진행합니다.
- 완료되면 명확한 커밋 메시지로 커밋하고 종료하세요.
```

플레이스홀더는 **`{{ issue.identifier }}` 하나만** (Jira 키, 예: `MEGA-1234`).

**전제**: Claude Code 에 Jira skill 이 설치·구성돼 있어야 한다.
필요 환경변수: `JIRA_BASE_URL`, `JIRA_USER_EMAIL`, `JIRA_API_TOKEN` (이미 `.env`에 있음).

**이 선택의 효과**
| 항목 | 효과 |
|---|---|
| DB 모델 | 작업 내용 미러링 불필요 — `id` + `identifier` 만 핵심 |
| 신선도 | 항상 최신 Jira 내용 (캐시 stale 없음) |
| 새 정보 필드 추가 | 코드 수정 불필요 (Claude가 알아서 읽음) |
| 의존성 | **Jira skill 필수** — 없으면 실패 |
| 가용성 | Jira 다운 시 작업 블록 (DB 미러링이 없으므로 fallback 없음) |

### B. 에이전트 실행 (Claude Code 헤드리스)

원본의 Codex app-server JSON 프로토콜을 전부 버리고, 헤드리스 CLI 한 방으로 대체.

```python
def 프롬프트(task, template):
    return (template
        .replace("{{ issue.identifier }}", task.identifier)
        .replace("{{ issue.title }}", task.title)
        .replace("{{ issue.description }}", task.description or ""))

MAX_OUTPUT_BYTES = 64 * 1024   # set_status 바디 비대화 방지용 상한

def 에이전트실행(ws, prompt):
    """(성공여부, 응답텍스트) 튜플 반환."""
    try:
        proc = subprocess.run(
            ["claude", "-p", prompt,
             "--permission-mode", "acceptEdits"],   # 정확한 플래그는 claude --help 확인
            cwd=ws,                                  # 안전 불변식 1
            capture_output=True, text=True,
            timeout=1800,                            # 30분 (stall 대체)
        )
        output = (proc.stdout or "") + (proc.stderr or "")
        if len(output) > MAX_OUTPUT_BYTES:
            output = output[:MAX_OUTPUT_BYTES] + "\n...[truncated]"
        return proc.returncode == 0, output
    except subprocess.TimeoutExpired as e:
        partial = (e.stdout or "") + (e.stderr or "") if hasattr(e, "stdout") else ""
        return False, f"[TIMEOUT after {e.timeout}s]\n{partial}"
```

> 정확한 CLI 플래그(`--permission-mode`, `--output-format`,
> `--dangerously-skip-permissions` 등)는 사용하는 Claude Code 버전에서
> `claude --help`로 확인한다. 핵심: `-p` 헤드리스 실행, 종료 코드로 성공 판정.
>
> **응답 형식 옵션**: `--output-format json`을 쓰면 stdout이 구조화된 JSON
> (응답 텍스트 + 비용 + 세션ID 등)이 나온다. DB에 깔끔히 저장하려면 권장.
> 텍스트면 그대로 저장, JSON이면 그대로 또는 파싱해 일부만 저장.

---

## 7. DB API 어댑터 — 확정 필요 (블로킹 항목)

구현 전 **DB API 스펙 확정 필요.** 어댑터는 두 함수만 있으면 된다.

```python
# 어댑터가 제공해야 하는 인터페이스
db_api.fetch(status="todo") -> list[Issue]

db_api.set_status(
    task_id: str,
    status: str,                       # "in_progress" | "done" | "failed"
    *,
    branch_name: str | None = None,    # 작업이 진행되는 git 브랜치
    result: str | None = None,         # Claude가 뱉은 응답 (done/failed 시)
) -> bool                              # 성공 시 True
```

호출 시점별 페이로드:

| 시점 | status | branch_name | result |
|---|---|---|---|
| 디스패치 직전 (찜) | `in_progress` | ✅ 포함 | (없음) |
| 작업 성공 | `done` | ✅ 포함 | ✅ Claude stdout/stderr |
| 작업 실패/타임아웃/예외 | `failed` | ✅ 포함 | ✅ 응답 또는 에러 메시지 |

확정해야 할 내용:

- [ ] 작업 조회 엔드포인트 (메서드, 경로, 쿼리 파라미터, 페이지네이션 유무)
- [ ] 작업 조회 응답 JSON 형태 → **반드시** `id` + `identifier`(=Jira 키),
      선택으로 `title`/`branch_name`
- [ ] 상태 변경 엔드포인트 (메서드, 경로, **바디 스키마 = status/branch_name/result 필드명**)
- [ ] `result` 필드의 형태 (text 그대로 저장? JSON 구조화? 길이 상한?)
- [ ] 인증 방식 (API 키 / 토큰 / 헤더)
- [ ] 상태 값 이름 (`todo`/`in_progress`/`done`/`failed` 또는 다른 명칭)
- [ ] 작업 → git 레포 연결 방법 (`REPO_URL` 출처, 자격증명)
- [ ] `identifier` 가 **Jira 키 그대로**인지 확인 (예: `MEGA-1234`).
      Jira 키가 별도 필드면 그 이름.
- [ ] `branch_name`을 DB가 사전 할당하는지(`Issue.branch_name`으로 내려옴) 아니면
      워커가 생성하는지 (생성 시 명명 규칙, 예: `symphony/<identifier>`)
- [ ] **Claude Code 에 Jira skill 설치·구성 완료** — `JIRA_*` 환경변수 사용 가능

`Issue` 표준 구조 (Jira 위임 전략 기준 최소 필드):

```python
@dataclass
class Issue:
    id: str                         # DB primary key — set_status 호출용
    identifier: str                 # Jira 키 (예: MEGA-1234) — 프롬프트로 들어감
    state: str                      # 폴링 필터용 ("todo" 등)
    branch_name: str | None = None  # DB 사전할당 or 워커가 생성
    title: str | None = None        # 로깅용 (있으면 좋음, 필수 아님)
```

**핵심**: 프롬프트가 Jira 키만 전달하므로 DB는 `title`/`description` 을 보낼
의무가 없다. 있으면 로그 가독성이 좋아질 뿐. 어댑터는 둘 다 없어도 동작해야 함.

### 브랜치명 정책

- `task.branch_name`이 있으면 그걸 사용.
- 없으면 워커가 `symphony/<sanitize(identifier)>` 형태로 생성.
- 어느 쪽이든 **디스패치 시점에 확정해서** `in_progress` set_status 호출에
  같이 보낸다 → DB가 처음부터 어느 브랜치에서 작업이 일어나는지 안다.
- 워커는 그 이름으로 `git checkout -b` 후 에이전트 실행.

> 주의: `Issue.state`는 설정의 `active_states`/`terminal_states`와 글자가
> 맞아야 한다. 정규화 시 소문자 통일 권장.

---

## 8. 결정 미정 항목

| # | 질문 | 옵션 |
|---|---|---|
| D1 | 작업 실패 시 상태 | `failed` 고정(추천) / `todo` 복귀(자동 재시도, 실패 카운트 필요) |
| D2 | 프로세스가 작업 도중 죽으면 | 방치(사람 확인) / 시작 시 stale `in_progress` 회수 한 줄 추가 |
| D3 | 동시 실행 개수 N | 머신 사양에 맞춰 결정 (예: 3~5) |
| D4 | 폴링 주기 | 기본 30초 — 작업 도착 빈도에 맞춰 조정 |
| D5 | git 레포 URL / 인증 | clone 대상과 자격증명 전달 방법 |
| D6 | `result` 저장 형태 | 텍스트 그대로 / `--output-format json` 구조화 / 핵심만 추출 |
| D7 | `result` 길이 상한 | DB 컬럼 한도와 합의 (PLAN 기본값 64KB) |
| D8 | 브랜치명 출처 | DB 사전할당 / 워커 생성 (명명 규칙) |

---

## 9. 파일 구조 (예정)

```
symphony/
├── ANALYSIS.md          # 원본 분석 (작성 완료)
├── PLAN.md              # 본 문서
├── install.sh           # 설치 스크립트 (작성 완료)
├── requirements.txt     # Python 의존성 (작성 완료)
├── .env.example         # 환경변수 템플릿 (작성 완료, 커밋됨)
├── .env                 # 실제 비밀 값 (커밋 안 함, install.sh가 복사 생성)
├── .gitignore           # .env, .venv 차단 (작성 완료)
├── config.yaml          # 비밀 아닌 설정 (동시성, 폴링 주기 등)
├── workflow.md          # 에이전트 프롬프트 템플릿
├── main.py              # 진입점 + 폴링 루프
├── orchestrator.py      # 디스패치 / 동시성 / in_flight
├── db_adapter.py        # DB 조회·상태변경 API 클라이언트
├── worker.py            # 워크스페이스 준비 + 에이전트 실행
└── models.py            # Issue 데이터클래스
```

### 9.1 설치 — `install.sh` (한 방)

```bash
./symphony/install.sh
```

스크립트가 멱등하게 하는 일 (여러 번 실행해도 안전):

1. **시스템 전제 검사** — `git`, `python3 >= 3.10`. 없으면 안내만.
2. **Claude Code CLI** — 없으면 `npm install -g @anthropic-ai/claude-code`.
   npm/Node.js 18+ 필요.
3. **Python venv** — `symphony/.venv` + `requirements.txt` 설치.
4. **템플릿 생성** (없는 경우만) — `.env` (← `.env.example`),
   `config.yaml`, `workflow.md`, `run.sh` (실행 래퍼, `chmod +x`).
5. **인터랙티브 마무리** (TTY 일 때만):
   - "Claude 로그인 지금?" Y/n → 누르면 `claude /login` 실행.
   - ".env 편집 지금?" Y/n → 누르면 `$EDITOR .env`.
6. **완료 안내** — `./run.sh` 한 줄이면 실행.

결과: 5단계 manual이 **사실상 0~2단계**로 줄어든다. 인터랙티브 프롬프트에 Y만
누르면 0단계. 건너뛴 경우만 직접 처리.

**한 번에 실행 흐름**
```bash
./symphony/install.sh   # 설치 + 템플릿 + (로그인) + (.env 편집)
./symphony/run.sh       # 구현 완료 후 한 줄 실행
```

`run.sh`는 venv activate 가 필요 없다 — `.venv/bin/python`을 직접 사용.

### 9.2 환경변수 — `.env` 패턴

비밀 값(DB 토큰, Jira 토큰, GitHub 토큰 등)은 `.env`에 둔다. 코드에 박지 않고
셸 rc 도 안 건드린다.

**커밋 정책**
- `.env.example` — 커밋됨. 어떤 변수가 필요한지 알려주는 템플릿(빈 값).
- `.env` — **절대 커밋 안 함** (`.gitignore`). 실제 값.

**전파 경로** — 앱 시작 시 한 번만 로드하면 자동으로 흐른다:

```
.env
  └─(python-dotenv가 main.py 시작 시 load_dotenv())
       └─ 오케스트레이터 프로세스의 os.environ
            └─(subprocess.run의 기본 동작 = 부모 env 상속)
                 └─ claude -p 자식 프로세스
                      └─ Claude skill 의 bash/curl 명령
                           └─ $JIRA_API_TOKEN 등을 그대로 사용
```

`subprocess.run`은 `env=None`(기본값)일 때 부모 환경을 그대로 물려준다. 따라서
`main.py` 첫 줄에서 `load_dotenv()`만 부르면 끝. Claude skill 안에서 curl 한 줄로
Jira API 호출 가능.

**`main.py` 진입부 예시**

```python
from dotenv import load_dotenv
load_dotenv()                              # 가장 먼저
# 이후 코드 어디서든 os.getenv("JIRA_API_TOKEN") 가능
# subprocess.run([...], cwd=ws) 는 자동으로 이 env 상속
```

**`.env.example` 에 들어가는 항목** (실제 채움은 `.env`에)

| 변수 | 용도 | 소비처 |
|---|---|---|
| `DB_API_BASE_URL`, `DB_API_TOKEN` | 작업 조회·상태변경 API | `db_adapter.py` |
| `REPO_URL`, `GITHUB_TOKEN` | 워크스페이스 `git clone` | `worker.py` |
| `JIRA_BASE_URL`, `JIRA_USER_EMAIL`, `JIRA_API_TOKEN` | Claude skill의 Jira 호출 | claude subprocess |
| (추가) `SLACK_WEBHOOK_URL` 등 | 도메인별 Claude skill | claude subprocess |

새 skill이 새 토큰을 요구하면 → `.env.example`에 항목 추가 + 팀에 공유.
코드 수정 불필요 (환경변수 이름만 일치하면 됨).

---

## 10. 구현 순서

1. **`models.py`** — `Issue` 데이터클래스.
2. **`db_adapter.py`** — `fetch` / `set_status`. (DB API 스펙 확정 후) — 모킹으로 선개발 가능.
3. **`worker.py`** — 워크스페이스 준비(안전 불변식 포함) + 에이전트 실행.
4. **`orchestrator.py`** — 폴링 루프 + 동시성 + `in_progress` 찜.
5. **`main.py`** — 설정 로드 + 기동.
6. **단위 검증** — DB 어댑터를 모킹해 폴링·찜·동시성·슬롯 반납 흐름 확인.
7. **통합 검증** — 실제 DB API + `claude -p`로 작업 1건 end-to-end.

> 블로킹: 10번 단계 2·7은 **DB API 스펙(7장 체크리스트) 확정** 후 진행.
> 그전까지 1·3·4·5는 모킹 어댑터로 선개발 가능.

---

## 11. 한 줄 요약

**타이머가 todo를 폴링 → 빈 슬롯만큼 브랜치명 정하고 `in_progress`로 찜하고
워커 spawn → 워커는 격리 폴더에서 그 브랜치 체크아웃 후 `claude -p "Jira <키>
보고 개발해"` 실행 → Claude 가 Jira skill 로 스펙 직접 읽고 작업·커밋 → 종료
코드로 `done`/`failed`를 Claude 응답·브랜치명과 함께 기록.**

원본의 상태머신·프로토콜 복잡도는 "DB 상태를 찜으로 활용" + "헤드리스 CLI"로,
DB 모델 복잡도는 "Jira 키만 전달, 내용은 Claude 가 직접" 으로 대부분 증발한다.
