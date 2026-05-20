# Sample — 값 포맷 참고용

실제 데이터 아님. 컬럼 값의 모양만 보여준다.

## participant

| participant_id | promotion_id | user_id | board_id | current_stage | current_position | dice_remaining | total_dice_used | total_rolls | status | joined_at | updated_at |
|---:|---|---:|---|---:|---:|---:|---:|---:|---|---|---|
| 1001 | dice_2026_spring | 90011234 | board_A | 2 | 14 | 3 | 9  | 9  | active    | 2026-05-01 09:12:33+09 | 2026-05-19 21:04:11+09 |
| 1002 | dice_2026_spring | 90011287 | board_A | 3 | 30 | 0 | 18 | 18 | completed | 2026-05-01 10:00:01+09 | 2026-05-15 12:33:00+09 |
| 1003 | dice_2026_spring | 90011355 | board_B | 1 | 4  | 1 | 2  | 2  | dropped   | 2026-05-02 13:21:09+09 | 2026-05-03 08:00:00+09 |
| 1004 | dice_2026_spring | 90011401 | board_A | 1 | 0  | 2 | 0  | 0  | active    | 2026-05-19 22:15:00+09 | 2026-05-19 22:15:00+09 |

## participation_history

| history_id | participant_id | action_type   | stage | dice_count | from | to | reward_type | reward_value | event_date | created_at |
|---:|---:|---|---:|---:|---:|---:|---|---:|---|---|
| 50001 | 1001 | join          | 1 | -  | -  | -  | -          | -    | 2026-05-01 | 2026-05-01 09:12:33+09 |
| 50002 | 1001 | dice_charged  | 1 | 3  | -  | -  | -          | -    | 2026-05-01 | 2026-05-01 09:12:34+09 |
| 50003 | 1001 | dice_roll     | 1 | 1  | 0  | 4  | -          | -    | 2026-05-01 | 2026-05-01 09:13:00+09 |
| 50004 | 1001 | reward_earned | 1 | -  | -  | -  | point      | 100  | 2026-05-01 | 2026-05-01 09:13:01+09 |
| 50005 | 1001 | dice_roll     | 1 | 1  | 4  | 9  | -          | -    | 2026-05-01 | 2026-05-01 09:14:11+09 |
| 50006 | 1001 | stage_clear   | 1 | -  | -  | -  | dice_extra | 2    | 2026-05-02 | 2026-05-02 10:00:01+09 |
| 50007 | 1002 | completed     | 3 | -  | -  | -  | coupon     | 5000 | 2026-05-15 | 2026-05-15 12:33:00+09 |
| 50008 | 1003 | dropped       | 1 | -  | -  | -  | -          | -    | 2026-05-03 | 2026-05-03 08:00:00+09 |

## 예시 쿼리 (NL → SQL)

**활성 참여자 수**
```sql
SELECT COUNT(DISTINCT user_id)
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

**완주율**
```sql
SELECT CAST(COUNT_IF(status='completed') AS DOUBLE) / NULLIF(COUNT(*), 0) AS completion_rate
FROM promotion.dice_board.participant
WHERE promotion_id = 'dice_2026_spring';
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

**주사위 0개 보유한 활성 참여자**
```sql
SELECT user_id, current_stage, current_position, updated_at
FROM promotion.dice_board.participant
WHERE promotion_id = 'dice_2026_spring' AND status = 'active' AND dice_remaining = 0
ORDER BY updated_at DESC LIMIT 100;
```
