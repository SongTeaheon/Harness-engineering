# Rule — SQL 작성 규칙 (Trino)

AI가 자연어 질문 → SQL 을 만들 때 반드시 지킨다.
컨텍스트 로드 순서: `model.yaml` → 이 파일 → `sample.md`.

## 식별자
- 테이블 풀 경로 사용: `promotion.dice_board.<table>` (= `model.yaml::entities[].full_path`)
- 컬럼명은 `model.yaml::entities` 에 정의된 것만. 추측 금지.
- 한국어 용어는 `model.yaml::glossary` 로 먼저 매핑.

## 시맨틱 모델 사용 (재발명 금지)
- 집계 수치는 `model.yaml::metrics` 의 `sql` 을 사용/응용. 메트릭 의미를 임의로 만들지 말 것.
- "활성/완주/이탈/주사위 소진" 같은 필터는 `model.yaml::segments` 의 `filter` 를 사용.
- GROUP BY 축으로 쓸 컬럼은 `model.yaml::dimensions` 에 있는 것만. (필터 전용 컬럼은 `entities` 에 선언돼 있으면 WHERE 에 바로 사용 가능)
- metric 에 `apply_segment` 가 있으면 그 세그먼트 필터를 WHERE 에 반드시 포함.
- 정의에 없는 metric/segment 가 필요하면 임의 생성하지 말고 사용자에게 정의를 확인한 뒤 `model.yaml` 에 등록.

## 오토필터 (model.yaml::autofilters)
- `participation_history` 조회 시 `event_date` 범위 필터를 **항상** 건다. 질문에 기간이 없으면 최근 30일.
- `promotion_id` 는 항상 WHERE 에 포함. 운영 프로모션이 1개면 `'dice_2026_spring'` 기본값, 여러 개면 사용자에게 확인.
- autofilter 는 질문에 명시적 값(기간 등)이 있으면 그 값으로 대체(override)한다.

## 카운팅
- 참여자 수 = `COUNT(DISTINCT user_id)` (또는 `participant_id`).
- `participation_history` 에서 사람 수를 셀 땐 반드시 `DISTINCT participant_id`. row 수 ≠ 사람 수.
- 비율은 `CAST(... AS DOUBLE) / NULLIF(분모, 0)`.

## NULL
- `participation_history` 의 `stage`, `dice_count`, `from_position`, `to_position`, `reward_*` 는 nullable.
- action_type 별 채워지는 컬럼은 `model.yaml::action_type_columns` 참조.

## JOIN
- `participant ↔ participation_history` 는 **`participant_id` 로만** JOIN. `promotion_id` JOIN 금지.
- 카디널리티는 1:N 이므로 history 쪽 집계 후 JOIN 하거나 중복 집계에 주의.

## 시간대
- `event_date` 는 KST 기준. "오늘" = `current_date AT TIME ZONE 'Asia/Seoul'`.
- 일자 집계는 `event_date` 사용 (파티션 효율). 정밀 비교는 `created_at`.

## 금지
- `SELECT *` 금지. 필요한 컬럼만 명시.
- `participant` 에 대한 시점(point-in-time) 쿼리 금지 (현재 상태만 보존). 과거 시점은 `participation_history` 에서 재구성.
- 탐색용 조회는 `LIMIT 100` 이내.

## 모호한 질문은 되묻기
- 기간 누락 → 기간 확인 (또는 오토필터 기본값 사용 후 명시)
- 프로모션 여러 개 → `promotion_id` 확인
- "사용자" 모집단(전체/활성/완주) 불명확 → 모집단 확인
