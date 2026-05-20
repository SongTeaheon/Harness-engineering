# Promotion Semantic Layer — Dice-Roll Board

AI 에이전트가 이 한 파일을 읽고 Trino SQL을 생성합니다.

## 도메인
"주사위 굴리기 보드" 프로모션. 사용자가 주사위를 굴려 보드 칸을 이동하고 스테이지를 클리어해 보상을 받습니다.
이 시맨틱 레이어는 **참여자(participant)** 와 **참여이력(participation_history)** 두 테이블만 다룹니다.

## 한국어 → 영문 매핑
- 참여자 → `participant`
- 참여이력 → `participation_history`
- 보드판 → `board_id`
- 보드 위치 / 칸 → `current_position` (0-based)
- 주사위 수 → `dice_remaining`
- 주사위 굴리기 → `action_type = 'dice_roll'`
- 스테이지 → `current_stage` (1-based)
- 스테이지 클리어 → `action_type = 'stage_clear'`
- 활성/완주/이탈 → `status = 'active' | 'completed' | 'dropped'`

## 스키마

```yaml
catalog: promotion
schema: dice_board

tables:
  participant:
    grain: 1 row per (promotion_id, user_id)
    pk: participant_id
    columns:
      participant_id:   { type: bigint,    null: false }
      promotion_id:     { type: varchar,   null: false, example: "dice_2026_spring" }
      user_id:          { type: bigint,    null: false }
      board_id:         { type: varchar,   null: false, example: "board_A" }
      current_stage:    { type: integer,   null: false, note: "1-based" }
      current_position: { type: integer,   null: false, note: "0-based, 0=시작칸" }
      dice_remaining:   { type: integer,   null: false }
      total_dice_used:  { type: integer,   null: false, note: "누적" }
      total_rolls:      { type: integer,   null: false, note: "누적 dice_roll 횟수" }
      status:           { type: varchar,   null: false, enum: [active, completed, dropped] }
      joined_at:        { type: timestamp(3) with time zone, null: false }
      updated_at:       { type: timestamp(3) with time zone, null: false }

  participation_history:
    grain: 1 row per action event (append-only)
    pk: history_id
    partition_key: event_date
    columns:
      history_id:       { type: bigint,  null: false }
      participant_id:   { type: bigint,  null: false, fk: participant.participant_id }
      promotion_id:     { type: varchar, null: false }
      action_type:      { type: varchar, null: false, enum: [join, dice_roll, dice_charged, stage_clear, reward_earned, completed, dropped] }
      stage:            { type: integer, null: true }
      dice_count:       { type: integer, null: true,  note: "dice_roll=사용량, dice_charged=충전량" }
      from_position:    { type: integer, null: true,  note: "dice_roll에서만 채워짐" }
      to_position:      { type: integer, null: true,  note: "dice_roll에서만 채워짐" }
      reward_type:      { type: varchar, null: true,  enum: [point, coupon, item, dice_extra] }
      reward_value:     { type: bigint,  null: true }
      event_date:       { type: date,    null: false, note: "KST 기준, 파티션 키" }
      created_at:       { type: timestamp(3) with time zone, null: false }
```

## action_type 별 채워지는 컬럼
| action_type     | 채워지는 컬럼                                  | 의미 |
|-----------------|----------------------------------------------|------|
| `join`          | (기본만)                                     | 최초 참여 |
| `dice_roll`     | `dice_count`, `from_position`, `to_position`, `stage` | 주사위 사용 + 이동 |
| `dice_charged`  | `dice_count`, `stage`                        | 주사위 충전 |
| `stage_clear`   | `stage` (+ 선택적 `reward_*`)                | 스테이지 통과 |
| `reward_earned` | `reward_type`, `reward_value`, `stage`       | 보상 획득 |
| `completed`     | (선택적 `reward_*`)                          | 프로모션 완주 |
| `dropped`       | (기본만)                                     | 이탈 |

## JOIN 규칙
- `participant.participant_id = participation_history.participant_id` **만** 사용
- `promotion_id`로 JOIN 금지 (카테시안 폭발)

## 쿼리 규칙
1. 테이블은 풀 경로: `promotion.dice_board.<table>`
2. `participation_history` 조회 시 **항상 `event_date` 범위 필터** (파티션 프루닝). 기본값: 최근 30일.
3. `promotion_id` 가 명시 안 됐고 운영 프로모션이 1개면 `'dice_2026_spring'` 가정, 여러 개면 사용자에게 확인.
4. 참여자 수 = `COUNT(DISTINCT user_id)` 또는 `COUNT(DISTINCT participant_id)`. `participation_history`에서 사람 수 셀 땐 반드시 DISTINCT.
5. 비율 계산은 `CAST(... AS DOUBLE) / NULLIF(분모, 0)`.
6. "오늘" = `current_date AT TIME ZONE 'Asia/Seoul'`.
7. `participant`는 **현재 상태**만 가짐 → 과거 시점 분석은 `participation_history`에서 재구성.
8. `SELECT *` 금지, 탐색용 쿼리는 `LIMIT 100` 이내.

## 표준 메트릭
| 메트릭 | SQL |
|---|---|
| 총 참여자 수 | `COUNT(DISTINCT user_id)` on `participant` |
| 활성 참여자 수 | `COUNT(DISTINCT user_id) FILTER (WHERE status='active')` |
| 완주율 | `CAST(COUNT_IF(status='completed') AS DOUBLE) / NULLIF(COUNT(*),0)` |
| 이탈율 | `CAST(COUNT_IF(status='dropped') AS DOUBLE) / NULLIF(COUNT(*),0)` |
| 총 굴림 수 | `COUNT(*) WHERE action_type='dice_roll'` |
| 사용된 주사위 합 | `SUM(dice_count) WHERE action_type='dice_roll'` |
| 사용자당 평균 굴림 | `굴림수 / NULLIF(COUNT(DISTINCT participant_id),0)` |
| 평균 도달 스테이지 | `AVG(current_stage)` on `participant` |

## 샘플 row (값 포맷 참고용)

**participant**
```
participant_id=1001, promotion_id='dice_2026_spring', user_id=90011234,
board_id='board_A', current_stage=2, current_position=14,
dice_remaining=3, total_dice_used=9, total_rolls=9,
status='active', joined_at=2026-05-01 09:12:33+09, updated_at=2026-05-19 21:04:11+09
```

**participation_history**
```
50003 | 1001 | dice_2026_spring | dice_roll     | stage=1 | dice_count=1 | from=0 | to=4 | -    | -    | 2026-05-01
50004 | 1001 | dice_2026_spring | reward_earned | stage=1 | -            | -      | -    | point | 100 | 2026-05-01
50006 | 1001 | dice_2026_spring | stage_clear   | stage=1 | -            | -      | -    | dice_extra | 2 | 2026-05-02
```

## 예시 쿼리 (NL → SQL)

**활성 참여자 수**
```sql
SELECT COUNT(DISTINCT user_id) AS active_participants
FROM promotion.dice_board.participant
WHERE promotion_id = 'dice_2026_spring' AND status = 'active';
```

**최근 7일 일자별 굴림 수**
```sql
SELECT event_date, COUNT(*) AS rolls
FROM promotion.dice_board.participation_history
WHERE promotion_id = 'dice_2026_spring'
  AND event_date BETWEEN current_date - INTERVAL '7' DAY AND current_date
  AND action_type = 'dice_roll'
GROUP BY event_date ORDER BY event_date;
```

**스테이지별 도달 인원**
```sql
SELECT current_stage, COUNT(*) AS participants
FROM promotion.dice_board.participant
WHERE promotion_id = 'dice_2026_spring'
GROUP BY current_stage ORDER BY current_stage;
```

**유저 액션 타임라인 (JOIN)**
```sql
SELECT p.user_id, h.created_at, h.action_type, h.stage,
       h.from_position, h.to_position, h.reward_type, h.reward_value
FROM promotion.dice_board.participant p
LEFT JOIN promotion.dice_board.participation_history h
       ON p.participant_id = h.participant_id
WHERE p.promotion_id = 'dice_2026_spring'
  AND p.user_id = 90011234
  AND h.event_date BETWEEN DATE '2026-05-01' AND current_date
ORDER BY h.created_at;
```

**주사위 0개 보유한 활성 참여자 (충전 유도 대상)**
```sql
SELECT user_id, current_stage, current_position, updated_at
FROM promotion.dice_board.participant
WHERE promotion_id = 'dice_2026_spring' AND status = 'active' AND dice_remaining = 0
ORDER BY updated_at DESC LIMIT 100;
```
