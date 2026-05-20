# Rule — SQL 작성 규칙 (Trino)

AI가 쿼리를 만들 때 반드시 지킨다.

## 식별자
- 테이블 풀 경로 사용: `promotion.dice_board.<table>`
- 컬럼명은 `schema.yaml`에 정의된 것만. 추측 금지.
- 한국어 용어는 `schema.yaml::glossary` 먼저 매핑.

## 필터 (성능·정합성 필수)
- `participation_history` 는 **항상 `event_date` 범위 필터** 포함 (파티션 프루닝). 기간 미지정 시 기본값: 최근 30일.
- `promotion_id` 미지정이고 운영 프로모션이 1개면 `'dice_2026_spring'` 가정, 여러 개면 사용자에게 확인.
- `action_type` enum 값만 사용.

## 카운팅
- 참여자 수 = `COUNT(DISTINCT user_id)` (또는 `participant_id`)
- `participation_history` 에서 사람 수 셀 땐 반드시 `DISTINCT participant_id`. row 수 ≠ 사람 수.
- 비율은 `CAST(... AS DOUBLE) / NULLIF(분모, 0)`.

## NULL
- `participation_history` 의 `stage`, `dice_count`, `from_position`, `to_position`, `reward_*` 는 nullable.
- action_type 별 채워지는 컬럼은 `schema.yaml::action_type_columns` 참조.

## JOIN
- `participant ↔ participation_history` 는 **`participant_id` 로만** JOIN. `promotion_id` JOIN 금지.

## 시간대
- `event_date` 는 KST 기준.
- "오늘" = `current_date AT TIME ZONE 'Asia/Seoul'`.
- 일자 집계는 `event_date` 사용 (파티션 효율). 정밀 비교는 `created_at`.

## 금지
- `SELECT *` 금지. 필요한 컬럼만 명시.
- 정의 안 된 메트릭 임의 생성 금지. 사용자에게 정의 확인.
- `participant` 에 대한 시점(point-in-time) 쿼리 금지 (현재 상태만 보존). 과거 시점은 `participation_history` 에서 재구성.
- 탐색용 조회는 `LIMIT 100` 이내.

## 모호한 질문은 되묻기
- 기간 누락 → 기간 확인
- 프로모션 여러 개 → `promotion_id` 확인
- "사용자" 모집단(전체/활성/완주) 불명확 → 확인

## 표준 메트릭 (재발명 금지)
| 메트릭 | SQL |
|---|---|
| 총 참여자 수 | `COUNT(DISTINCT user_id)` on `participant` |
| 활성 참여자 수 | `COUNT(DISTINCT user_id) FILTER (WHERE status='active')` |
| 완주율 | `CAST(COUNT_IF(status='completed') AS DOUBLE) / NULLIF(COUNT(*),0)` |
| 이탈율 | `CAST(COUNT_IF(status='dropped') AS DOUBLE) / NULLIF(COUNT(*),0)` |
| 총 굴림 수 | `COUNT(*)` on history, `action_type='dice_roll'` |
| 사용된 주사위 합 | `SUM(dice_count)` on history, `action_type='dice_roll'` |
| 사용자당 평균 굴림 | `굴림수 / NULLIF(COUNT(DISTINCT participant_id), 0)` |
| 평균 도달 스테이지 | `AVG(current_stage)` on `participant` |
