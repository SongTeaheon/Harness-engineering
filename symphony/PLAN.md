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
            ok = db_api.set_status(task.id, "in_progress")   # ① 찜 (동기)
            if not ok:
                continue
            with lock:
                in_flight.add(task.id)                        # ② 슬롯 점유
            pool.submit(워커, task)                            # ③ 백그라운드 spawn
        time.sleep(POLL_INTERVAL)

def 워커(task):
    ws = None
    try:
        ws = 워크스페이스준비(task)                            # A
        prompt = 프롬프트(task, TEMPLATE)
        ok = 에이전트실행(ws, prompt)                          # B
        db_api.set_status(task.id, "done" if ok else "failed")
    except Exception as e:
        log(task.id, "실패", e)
        db_api.set_status(task.id, "failed")
    finally:
        if ws:
            shutil.rmtree(ws, ignore_errors=True)
        with lock:
            in_flight.discard(task.id)                         # ④ 슬롯 반납
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

def 워크스페이스준비(task):
    ws = 워크스페이스경로(ROOT, task.identifier)
    os.makedirs(ws, exist_ok=True)
    subprocess.run(["git", "clone", "--depth", "1", REPO_URL, "."],
                   cwd=ws, check=True, timeout=120)
    if task.branch_name:
        subprocess.run(["git", "checkout", "-b", task.branch_name],
                       cwd=ws, check=True)
    return ws
```

### B. 에이전트 실행 (Claude Code 헤드리스)

원본의 Codex app-server JSON 프로토콜을 전부 버리고, 헤드리스 CLI 한 방으로 대체.

```python
def 프롬프트(task, template):
    return (template
        .replace("{{ issue.identifier }}", task.identifier)
        .replace("{{ issue.title }}", task.title)
        .replace("{{ issue.description }}", task.description or ""))

def 에이전트실행(ws, prompt):
    try:
        result = subprocess.run(
            ["claude", "-p", prompt,
             "--permission-mode", "acceptEdits"],   # 정확한 플래그는 claude --help 확인
            cwd=ws,                                  # 안전 불변식 1
            capture_output=True, text=True,
            timeout=1800,                            # 30분 (stall 대체)
        )
        return result.returncode == 0
    except subprocess.TimeoutExpired:
        return False
```

> 정확한 CLI 플래그(`--permission-mode`, `--output-format`,
> `--dangerously-skip-permissions` 등)는 사용하는 Claude Code 버전에서
> `claude --help`로 확인한다. 핵심: `-p` 헤드리스 실행, 종료 코드로 성공 판정.

---

## 7. DB API 어댑터 — 확정 필요 (블로킹 항목)

구현 전 **DB API 스펙 확정 필요.** 어댑터는 두 함수만 있으면 된다.

```python
# 어댑터가 제공해야 하는 인터페이스
db_api.fetch(status="todo")        -> list[Issue]
db_api.set_status(task_id, status) -> bool   # 성공 시 True
```

확정해야 할 내용:

- [ ] 작업 조회 엔드포인트 (메서드, 경로, 쿼리 파라미터, 페이지네이션 유무)
- [ ] 작업 조회 응답 JSON 형태 → `Issue`로 매핑할 필드
- [ ] 상태 변경 엔드포인트 (메서드, 경로, 바디 형태)
- [ ] 인증 방식 (API 키 / 토큰 / 헤더)
- [ ] 상태 값 이름 (`todo`/`in_progress`/`done`/`failed` 또는 다른 명칭)
- [ ] 작업 → git 레포/브랜치 연결 방법 (`branch_name` 출처)

`Issue` 표준 구조 (MVP 최소 필드):

```python
@dataclass
class Issue:
    id: str
    identifier: str          # 사람이 읽는 키
    title: str
    description: str | None
    state: str
    branch_name: str | None = None
```

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

---

## 9. 파일 구조 (예정)

```
symphony/
├── ANALYSIS.md          # 원본 분석 (작성 완료)
├── PLAN.md              # 본 문서
├── config.yaml          # 설정 (DB API URL, 동시성, 폴링 주기, 레포 URL)
├── workflow.md          # 에이전트 프롬프트 템플릿
├── main.py              # 진입점 + 폴링 루프
├── orchestrator.py      # 디스패치 / 동시성 / in_flight
├── db_adapter.py        # DB 조회·상태변경 API 클라이언트
├── worker.py            # 워크스페이스 준비 + 에이전트 실행
├── models.py            # Issue 데이터클래스
└── requirements.txt     # requests, pyyaml 등
```

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

**타이머가 todo를 폴링 → 빈 슬롯만큼 `in_progress`로 찜하고 워커 spawn →
워커는 격리 폴더에서 `claude -p` 실행 → 종료 코드로 `done`/`failed` 기록.**
원본의 상태머신·프로토콜 복잡도는 "DB 상태를 찜으로 활용" + "헤드리스 CLI"로
대부분 증발한다.
