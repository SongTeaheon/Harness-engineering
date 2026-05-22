# OpenAI Symphony 분석

> 원본: https://github.com/openai/symphony
> 이 문서는 Symphony가 무엇이고 어떻게 동작하는지 정리한 분석 노트다.
> 구현 계획은 [`PLAN.md`](./PLAN.md) 참고.

---

## 1. Symphony란

코딩 에이전트(원본은 OpenAI Codex)를 **감독하는 게 아니라**, 처리해야 할
**"작업(work)"을 관리**하게 해주는 오케스트레이터다. 이슈 트래커(원본은 Linear)를
주기적으로 폴링해 작업 대상을 찾고, 작업마다 격리된 워크스페이스를 만들어
에이전트를 자율 실행시킨다.

저장소 구성:

- `SPEC.md` (약 2,200줄) — 언어 무관 명세. "이걸 보고 직접 구현하라"가 공식 권장.
- `elixir/` — 실험용 Elixir 레퍼런스 구현체 (프로토타입, as-is).
- `.codex/skills/` — commit/push/pull/land/linear 스킬.

README의 권장 사용법 두 가지:

1. 원하는 언어로 `SPEC.md` 기반 직접 구현 (← 본 프로젝트가 택한 길, Python)
2. Elixir 레퍼런스 구현체 사용

---

## 2. 한 바퀴 도는 흐름

Symphony의 본질은 **타이머 하나가 같은 일을 반복하는 것**이다.

```
N초마다 깨어남
   │
   ├─ ① 작업 대상 가져오기   (트래커/DB 조회)
   ├─ ② 처리할 게 있나? 빈 슬롯 있나?
   └─ ③ 있으면 → 작업 하나 띄움
          ├─ 폴더 하나 만들고 (workspace)
          ├─ 그 안에서 에이전트 실행
          └─ 에이전트가 코드 작업 수행
   │
   └─ (다시 잠듦, N초 뒤 반복)
```

핵심 개념 3가지:

- **폴링(Polling)** — 요청을 기다리는 게 아니라, 알람시계처럼 주기적으로 깨어나
  "할 일 있나?" 확인한다.
- **워크스페이스 격리** — 작업마다 별도 폴더. 작업 A와 B가 안 섞이게. 보통 그 폴더에
  `git clone`으로 깨끗한 코드 사본을 둔다.
- **동시성 슬롯** — "최대 N개까지만 동시 실행" 제한. 슬롯이 차면 다음 tick까지 대기.

---

## 3. 구성 요소 7개

```
Policy(WORKFLOW.md 프롬프트) → Config → Orchestrator → Workspace → Agent Runner → Tracker
                                                                            └ Observability
```

1. **Workflow Loader** — `WORKFLOW.md`를 읽어 설정과 프롬프트로 분리.
2. **Config Layer** — 타입 있는 설정, 기본값, 환경변수 치환, 디스패치 전 검증.
3. **Issue Tracker Client** — 작업 대상 조회 + 상태 재조회 + 정규화.
4. **Orchestrator** — 폴링 tick, 런타임 상태, 디스패치/재시도/중단 결정.
5. **Workspace Manager** — 작업별 폴더 생성, 라이프사이클 훅, 정리.
6. **Agent Runner** — 워크스페이스 생성, 프롬프트 빌드, 에이전트 실행, 이벤트 스트림.
7. **Status Surface / Logging** — 운영자 가시성 (로그 + 선택적 대시보드).

---

## 4. WORKFLOW.md — 설정 파일이자 에이전트 지시서

Symphony의 설정 파일은 **딱 하나**, `WORKFLOW.md`. 두 부분으로 나뉜다.

```md
---
tracker:
  kind: linear
  project_slug: "..."
polling:
  interval_ms: 30000
agent:
  max_concurrent_agents: 5
---

작업 {{ issue.identifier }}을 처리하세요.
제목: {{ issue.title }}
내용: {{ issue.description }}
```

- **`---` 위 (YAML front matter)** — 기계가 읽는 "설정". 어떻게 동작할지.
  - `tracker` 작업 대상 소스, `polling` 폴링 주기, `workspace` 작업 폴더 위치,
    `hooks` 전/후처리 셸 명령, `agent` 동시성/턴 수, `codex` 에이전트 실행 명령.
  - 값을 안 적으면 기본값 적용.
- **`---` 아래 (Markdown body)** — 에이전트한테 줄 "프롬프트". 무엇을 할지.
  - `{{ issue.* }}` 플레이스홀더가 실행 시점에 실제 작업 데이터로 치환된다.

설계 의도: "워크플로를 어떻게 굴릴지(설정)"와 "에이전트한테 뭘 시킬지(정책)"는
같이 바뀌는 경우가 많으므로 한 파일에 묶어 버전 관리한다.

---

## 5. Tracker — 작업 대상을 가져오는 창구

Symphony가 바깥 세계와 만나는 지점. 원본은 Linear(GraphQL).

### 읽기 연산 3종 (SPEC 11.1)

- `fetch_candidate_issues()` — active 상태 작업 목록. 매 tick 호출. **가장 중요.**
- `fetch_issue_states_by_ids(ids)` — 특정 작업들의 현재 상태 (reconcile용).
- `fetch_issues_by_states(states)` — terminal 상태 작업 (시작 시 정리용).

세 연산 모두 **읽기**. 트래커는 기본적으로 읽기 전용 창구다.

### 정규화(Normalization) — Tracker의 진짜 역할

소스마다 응답 모양이 다르다. Tracker는 **어떤 소스든 똑같은 표준 `Issue` 모양**으로
변환한다. 덕분에 오케스트레이터 본체는 소스를 몰라도 된다 (어댑터 패턴).

표준 `Issue` 필드:

```
id            작업 고유 ID
identifier    사람이 읽는 키 (TASK-42)
title         제목
description   내용 → 에이전트 프롬프트로 들어감
state         현재 상태 (todo / done ...)
branch_name   git 브랜치명
labels        라벨 목록
priority, url, blocked_by, created_at, updated_at ...
```

```
오케스트레이터  ──"작업 목록 줘"──>  Tracker 어댑터  ──HTTP──>  외부 API
              <──[Issue, Issue]──                <──JSON──
```

소스를 바꿔도 어댑터 하나만 새로 쓰면 본체는 손 안 댄다.

### 트래커 쓰기 경계 (SPEC 11.5)

상태 변경·코멘트 등 **쓰기는 오케스트레이터 필수 기능이 아니다.** 보통 에이전트가
워크플로 프롬프트가 정의한 툴로 직접 수행한다. 서비스 본체는 "스케줄러 + 트래커
리더"로 남는다.

---

## 6. Orchestrator — 두뇌이자 심장

### 철칙 — "상태를 바꾸는 건 오직 오케스트레이터" (SPEC 7)

워커(작업)는 동시에 여러 개 돈다. 여러 곳에서 작업 목록을 제멋대로 건드리면 같은
작업을 두 번 띄우는 사고가 난다. 그래서 모든 결정·기록을 한 곳(single authority)에
모은다. 워커는 보고만 하고, 판단·기록은 오케스트레이터가 혼자 한다.

### 런타임 상태

메모리에 표 몇 개를 든다: `running` / `claimed` / `retry_attempts` / `blocked`.
이 상태는 **메모리에만** 존재 — 재시작하면 사라진다. 그래도 괜찮은 이유:
다음 tick에 트래커를 다시 조회하면 미완 작업이 또 잡힌다. **트래커/DB가 진실의
원천(source of truth), 오케스트레이터 메모리는 임시 작업판.**

### 작업 하나의 상태머신 (SPEC 7.1)

```
Unclaimed   아직 아무도 안 건드림
    ↓
Claimed     "내가 찜함" — 중복 디스패치 방지 표시
    ↓
Running     워커가 실제로 돌고 있음
    ↓ (실패 시)
RetryQueued 재시도 타이머 대기 중
    ↓
Released    찜 해제 (끝났거나 더 이상 대상 아님)
```

`Claimed`이 따로 있는 이유: "띄우기로 결정한 순간"과 "실제 워커가 뜨는 순간" 사이의
틈에 다음 tick이 같은 작업을 또 잡으면 안 되므로, 찜 표시를 먼저 박는다.

### 매 tick의 4단계 (SPEC 7.3, 8.1)

```
① Reconcile  — 실행 중 작업들, 그새 상태 바뀌었나 확인 (terminal이면 워커 중단)
② Validate   — 설정 정상 점검
③ Fetch      — 트래커에서 작업 대상 목록 조회
④ Dispatch   — 빈 슬롯만큼 작업 띄움
```

Reconcile이 Fetch보다 먼저인 이유: 디스패치 결정 전에 현재 상황을 최신화해야 한다.
끝난 작업 슬롯을 비워야 그 자리에 새 작업을 넣을 수 있다.

### 후보 선별 (SPEC 8.2, 8.3)

가져온 목록에서 거른다: 이미 `running`/`claimed`/`blocked`이면 건너뜀. 빈 슬롯은
`max_concurrent_agents - 현재 실행 수`. 0이면 이번 tick은 디스패치 없이 종료.

---

## 7. Workspace — 작업 폴더

### 경로 규칙 (SPEC 9.1)

```
<workspace.root> / <sanitize한 작업 식별자>
예: /tmp/symphony_ws/TASK-42
```

### 안전 불변식 3종 (SPEC 9.5) — "가장 중요한 이식 제약"

에이전트는 셸 명령을 자유롭게 실행하므로 폴더 격리가 유일한 안전벽이다.

1. **에이전트는 그 작업의 워크스페이스 안에서만 실행** → 실행 전 `cwd == workspace_path` 확인.
2. **워크스페이스 경로는 root 밖으로 못 나간다** → 절대경로 정규화 후 root가 prefix인지 검사.
3. **식별자 sanitize** → `[A-Za-z0-9._-]`만 허용, 나머지는 `_`로 치환 (경로 탈출 방지).

### 라이프사이클 훅 (SPEC 9.4)

`after_create` / `before_run` / `after_run` / `before_remove` 4종 셸 훅.
워크스페이스 디렉터리를 `cwd`로, `sh -lc`로 실행. `hooks.timeout_ms` 기본 60초.
보통 `after_create`에 `git clone`을 넣어 폴더에 코드를 채운다.

---

## 8. Agent Runner — 에이전트 실행

원본은 **Codex app-server 프로토콜**(SPEC 10장)을 쓴다:

- 서브프로세스를 띄우고 JSON-line으로 양방향 통신.
- 세션 초기화 → 스레드 생성 → 턴 시작 → 스트리밍 이벤트 수신.
- `session_started`, `turn_completed`, `turn_failed` 등 이벤트 파싱.
- 연속 턴(continuation turns): 정상 종료해도 작업이 아직 active면 같은 스레드에서
  `max_turns`까지 턴 반복. 첫 턴은 전체 프롬프트, 이후 턴은 continuation 가이드만.

이 프로토콜 복잡도는 헤드리스 CLI(예: `claude -p`)를 쓰면 "실행 → 대기 → 종료 코드
확인"으로 통째로 단순화된다 (PLAN.md 참고).

---

## 9. 재시도 · 복구 (SPEC 8.4, 14)

- **비정상 종료** → 지수 백오프 재시도 (`max_retry_backoff_ms` 기본 5분).
- **정상 종료** → 약 1초 후 continuation retry로 작업이 아직 active인지 재확인.
- 재시도 큐는 메모리에만 존재 (재시작하면 사라짐).
- 재시작 복구는 트래커·파일시스템 기반 (durable DB 없음).
- 시작 시 terminal 상태 작업의 stale 워크스페이스 정리.

---

## 10. 컨퍼먼스 체크리스트 요약 (SPEC 18)

### REQUIRED (18.1) — Symphony라 부를 최소선

워크플로 경로 선택 · `WORKFLOW.md` 로더 · 타입 설정 레이어 · 동적 리로드 ·
폴링 오케스트레이터(단일 권한 상태) · 트래커 클라이언트(조회/재조회/terminal) ·
워크스페이스 매니저(sanitize) · 라이프사이클 훅 4종 · 훅 타임아웃 ·
에이전트 app-server 클라이언트 · 프롬프트 렌더링 · 지수 백오프 재시도 ·
reconciliation · 워크스페이스 정리 · 구조화 로그.

### RECOMMENDED (18.2) — 컨퍼먼스 불필요

HTTP 서버 + 대시보드 · `linear_graphql` client-side 툴 ·
재시도 큐/세션 영속화 · 오케스트레이터 1급 트래커 쓰기 API · 플러그형 트래커 어댑터.

### OPTIONAL (Appendix A)

SSH 워커 — 오케스트레이터 1개 + 원격 호스트 N개. 호스트 풀, 페일오버,
호스트별 동시성 제한. 단일 머신이면 통째로 제외.

---

## 11. 본 프로젝트의 적용 방향

목표 흐름: **DB 조회 API로 작업 대상 가져오기 → 작업 → 상태변경 API 호출.**

- "DB 조회 API" = `fetch_candidate_issues()` — Linear GraphQL을 자체 DB REST API로 교체.
- "작업" = 에이전트 실행 — Codex app-server 대신 Claude Code CLI 헤드리스(`claude -p`).
- "상태변경 API" = 작업 시작 시 `in_progress`, 종료 시 `done`/`failed`.

핵심 단순화 — **DB 상태 자체를 "찜(claim)" 도구로 활용**한다. 작업을 집으면 즉시
`in_progress`로 바꾸므로, DB 조회(`status=todo`)에서 자동으로 빠진다. 그 결과
오케스트레이터의 복잡한 메모리 상태머신·재시도 큐·reconcile이 대부분 증발한다.

상세 범위와 모듈 설계는 [`PLAN.md`](./PLAN.md) 참고.
