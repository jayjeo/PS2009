# korean_hsk_concordance.do 상세 해설

> **본 문서의 통계 수치 갱신**: 본 문서에 수록된 모든 정량 수치는 `2025 replication/main.do` 650~989행의 양방향(순방향+역방향) 검증·정정 절차를 거친 현재의 t12.dta(8,876행, year_old 2009~2024 / year_new 2011~2025)와 `import.do` 절차로 산출된 현재의 HSlist_{2010~2026}.dta를 입력으로 한 실행 결과를 기준으로 한다. 정정 이전 원본 자료(8,927행, 9자리 77건, 빈 HS_new 12건 등)에 기반한 과거 산출물과는 다소의 수치 차이가 있다.

## 목차
1. [개요: 무엇을 하는 코드인가?](#1-개요)
2. [P&S 방법론과의 관계](#2-ps-방법론과의-관계)
3. [PHASE 0: 데이터 준비](#3-phase-0-데이터-준비)
4. [PHASE 1: 연결 요소 분석 (Family Identification)](#4-phase-1-연결-요소-분석)
5. [PHASE 2: 최종 패널 생성](#5-phase-2-최종-패널-생성)
6. [출력 파일 설명](#6-출력-파일-설명)
7. [전체 데이터 흐름 다이어그램](#7-전체-데이터-흐름-다이어그램)

---

## 1. 개요

`korean_hsk_concordance.do`는 Pierce & Schott (2012) "Concording U.S. HS Codes Over Time" 방법론을 한국 HSK 코드에 적용한 Stata 코드이다.

**목표:** 2010~2026년 기간 동안 변경된 한국 HSK 10자리 코드들을 "가족(family)"으로 묶어, 시계열에서 동일한 상품 바구니를 추적할 수 있는 `syntheticID`를 모든 HSK 코드에 부여한다.

**입력:**
- `t12.dta` — HSK 변경 연계표 (HS_old, year_old, HS_new, year_new), 8,876행. 본 파일은 `2025 replication/main.do` 650~989행의 양방향(순방향+역방향) 검증 절차를 거쳐 정정된 결과로, 원본 기재부 연계표(`y0.dta`)에 존재하던 자기 매핑 잘못 기재 사례(살렸어야 하는데 죽인 경우 / 죽였어야 하는데 살린 경우)가 모두 교정된 상태이다.
- `HSlist_{2010~2026}.dta` — 각 연도별 유효 HSK 코드 목록. CLIP/UNIPASS와 CIEL 두 출처를 교차 검증한 `HSlist_fin.dta`에서 연도별로 분리한 파일이다 (`import.do` 참조).

**출력:**
- `hsk_concordance_2010_2026.dta` — 최종 패널 (HSK, year, syntheticID)
- `hsk_node_families.dta` — HSK → syntheticID 매핑표
- `hsk_families_detail.dta` — family별 HS_old→HS_new 상세 정보

---

## 2. P&S 방법론과의 관계

### P&S 원본 알고리즘 (3단계)

```
Step 1: Chopping — 연도별 데이터 분리
Step 2: Chaining — joinby로 연도 간 순차 merge하여 다년간 체인 발견
Step 3: Min-Propagation — egen min(setyr), by(obs) ↔ by(new) 교대 반복
```

### 본 코드의 알고리즘 (2단계)

```
Phase 1: Long 변환 — 각 간선을 (HSK, edge_id) 2행으로 분리
Phase 1: Min-Propagation — egen min(family_id), by(HSK) ↔ by(edge_id) 교대 반복
```

**핵심 차이:** P&S의 Step 2(Chaining)를 완전히 생략한다.

이것이 가능한 이유는 이분 그래프의 구조를 바꿨기 때문이다:
- **P&S:** (obs 열 코드) ↔ (new 열 코드) — 같은 코드가 obs와 new에 각각 등장하면 연결되지 않음 → Chaining 필요
- **본 코드:** (HSK 열 코드) ↔ (edge_id) — 같은 코드는 항상 HSK 열에서 만남 → by(HSK)로 자동 연결

상세한 설명은 `edge-based min-propagation.md`를 참조.

---

## 3. PHASE 0: 데이터 준비

### 3-1. t12.dta 로드 및 기본 정보 확인

```stata
use t12, clear
```

t12.dta는 8,876행, 4개 변수(HS_old, year_old, HS_new, year_new)로 구성된다. year_old는 2009~2024 범위, year_new는 2011~2025 범위에 분포한다 (year_new가 분석 시작 연도인 2010 이전인 행은 `main.do`에서 사전 제거됨).

**t12.dta의 구조적 특징 (plan.md 참조):**
- 변경된 HSK에 한정해서만 행이 존재한다. 변경 없는 1:1 연속 코드는 행이 없다.
- `year_old`와 `year_new`는 연계표에 기록된 change event의 메타데이터이다.
- 따라서 t12만으로 어떤 코드의 **실제 연도별 존재 여부 전체**를 확정하면 안 된다. 최종 패널에서 해당 연도에 HSK가 실제로 존재했는지는 `HSlist_{year}.dta`가 결정한다.
- 본 알고리즘에서 t12는 family 연결 관계를 제공하고, HSlist는 연도별 존재 여부를 제공한다.

### 3-2. HS_new 길이 이상치 처리 (Phase 0-A)

t12.dta의 HS_new 길이를 점검하는 두 가지 방어적 정제 단계가 코드에 포함되어 있다. 현재 입력 자료(2025 replication 정정본)에서는 두 단계 모두 0행에 적용되지만, 입력 자료가 갱신될 가능성을 대비하여 코드는 그대로 유지한다.

#### (a) 9자리 HS_new — 앞자리 "0" 누락 (현재 데이터 0행)

```stata
gen len_new = strlen(HS_new)
replace HS_new = "0" + HS_new if len_new == 9
```

**왜 발생할 수 있는가?** 03류(수산물) 등 첫 자리가 0인 코드에서 선행 0이 누락되어 9자리로 기록된 경우. 과거 원본 자료에서는 77행이 발견되었으나, `main.do` 700~759행의 정제 절차에서 모두 사전 보정되어 현재 t12.dta에는 0건이다.

**처리:** 단순히 앞에 "0"을 추가하여 10자리로 복원한다. 이는 내용의 변경이 아니라 형식의 보정이다.

#### (b) 빈 문자열 HS_new — 삭제된 코드 (현재 데이터 0행)

```stata
preserve
    keep if len_new == 0
    save hsk_deleted_codes, replace
restore
drop if len_new == 0
```

**의미:** HS_new가 빈 문자열이면, HS_old 코드가 후속 코드 없이 완전히 삭제된 것이다. 이 코드는 그래프에서 간선을 형성할 수 없으므로 별도 파일(`hsk_deleted_codes.dta`)로 분리 보관한다. 과거 원본 자료에서는 12행이 발견되었으나, `main.do`의 양방향 검증 절차에서 정정 또는 통합되어 현재 t12.dta에는 0건이다. 따라서 본 단계의 `if _N > 0` 조건이 충족되지 않아 `hsk_deleted_codes.dta` 파일은 새로 생성되지 않는다.

### 3-3. 길이 검증 및 정리

```stata
assert strlen(HS_old) == 10
assert strlen(HS_new) == 10
save t12_clean, replace
```

모든 HS_old와 HS_new가 정확히 10자리인지 확인한 후, 정리된 데이터를 `t12_clean.dta`로 저장한다. 현재 입력 자료에서는 빈 HS_new가 0건이므로 t12_clean의 행 수는 원본과 동일한 8,876행이다.

---

## 4. PHASE 1: 연결 요소 분석

이 Phase가 P&S 방법론의 핵심인 "family identification"을 수행한다.

### 4-1. Self-loop 제거 및 간선 번호 부여 (Phase 1-A)

```stata
use t12_clean, clear
gen byte selfloop = (HS_old == HS_new)
drop if selfloop == 1
gen long edge_id = _n
```

**Self-loop이란?** HS_old == HS_new인 행. 예를 들어:

```
HS_old=5506900000, year_old=2014, HS_new=5506900000, year_new=2017
```

이 경우 5506900000은 2017년에도 존속하지만, 동시에 다른 새 코드(5506400000)도 함께 생겨난 것이다. t12.dta에서 이 두 행은 함께 나타난다:

```
5506900000 → 5506400000   (실제 변경 — 유효 간선)
5506900000 → 5506900000   (self-loop — 그래프 연결에 무의미)
```

**왜 제거하는가?** 그래프에서 self-loop은 노드를 자기 자신에게 연결하는 것이므로 연결 요소(connected component) 탐색에 기여하지 않는다. 5506900000은 첫 번째 간선(5506900000→5506400000)을 통해 이미 family에 포함된다.

**self-loop만 있고 다른 간선이 없는 코드는?** 현재 구현에서는 실질적으로 변화가 없는 코드처럼 취급하여 family에 별도 포함시키지 않는다. Phase 1-E에서 이를 확인한다.

**self-loop 제거 후:** t12_clean의 1,479개 self-loop 행을 제거하여 7,397개의 유효 간선이 남는다 (8,876 − 1,479 = 7,397). 각 간선에 `edge_id = _n`으로 순차 번호를 부여한다.

### 4-2. Long 형태 변환 — 이분 그래프 구축 (Phase 1-B)

이 단계가 edge-based min-propagation의 핵심 준비 과정이다.

**목표:** 각 간선 `(HS_old, HS_new, edge_id)`를 두 행으로 분리하여 `(HSK, edge_id)` 형태의 이분 그래프를 만든다.

```stata
/* HS_old 쪽 */
use edges, clear
rename HS_old HSK
drop HS_new
save temp_side1, replace

/* HS_new 쪽 */
use edges, clear
rename HS_new HSK
drop HS_old
save temp_side2, replace

/* 합치기 */
use temp_side1, clear
append using temp_side2
gen long family_id = edge_id
```

**변환 예시:**

간선 `edge_id=5: HS_old=2833299000, HS_new=2833292010`이 다음 두 행으로 변환된다:

```
행 1: HSK=2833299000, edge_id=5, family_id=5
행 2: HSK=2833292010, edge_id=5, family_id=5
```

**왜 이렇게 하는가?**

이 변환 후의 데이터는 이분 그래프(bipartite graph)를 표현한다:
- 한쪽 노드 집합: 고유 HSK 코드 (7,816개)
- 다른쪽 노드 집합: edge_id (7,397개)
- 간선: 각 edge_id는 정확히 2개의 HSK 노드와 연결 (그래프 추상화 시 중복 매핑이 27건 존재하여 networkx 기준 고유 간선 수는 7,370개로 줄지만, Stata edge-based 알고리즘은 모든 7,397개 매핑을 별개로 처리한다)

**P&S 방식과의 핵심 차이:**

P&S는 `(obs 열, new 열)`이라는 두 개의 분리된 열을 가진다. 같은 코드 B가 한 행에서 `new`로, 다른 행에서 `obs`로 등장하면 이 두 행은 **서로 다른 열**에 있으므로 `by(obs)나` `by(new)` 어느 쪽으로도 연결되지 않는다.

본 코드에서는 B가 어디에 등장하든 항상 `HSK` 열에 있다. 따라서 `by(HSK)`로 min을 전파하면 B를 공유하는 모든 간선이 자동으로 같은 최소값을 갖게 된다.

**이것이 Chaining을 불필요하게 만드는 핵심 메커니즘이다.**

전체 행 수: 유효 간선 수 × 2 (각 간선이 obs쪽 1행 + new쪽 1행)

`family_id`의 초기값은 `edge_id`와 동일하게 설정한다. 이는 "처음에 각 간선이 자기 자신만으로 구성된 가족"이라는 의미이다. min-propagation을 통해 연결된 간선들의 family_id가 통합될 것이다.

### 4-3. 반복적 min 전파 — 수렴까지 (Phase 1-C)

```stata
local stop = 0
local iter = 1

while `stop' == 0 {
    /* Step A: HSK 기준 min 전파 */
    egen long fid_by_node = min(family_id), by(HSK)
    replace family_id = fid_by_node
    drop fid_by_node

    /* Step B: edge_id 기준 min 전파 */
    egen long fid_by_edge = min(family_id), by(edge_id)

    /* 수렴 확인 */
    gen byte changed = (fid_by_edge != family_id)
    quietly sum changed
    local stop = (r(sum) == 0)

    replace family_id = fid_by_edge
    drop fid_by_edge changed
    local iter = `iter' + 1
}
```

**각 반복(iteration)에서 일어나는 일:**

#### Step A: `egen min(family_id), by(HSK)`

같은 HSK 코드를 공유하는 모든 행(= 해당 HSK가 관여하는 모든 간선)이 **동일한 최소 family_id**를 갖게 된다.

예: HSK=B가 edge_id=1(family_id=1)과 edge_id=3(family_id=3)에 등장하면:
```
행 2: HSK=B, edge_id=1, family_id=1
행 5: HSK=B, edge_id=3, family_id=3
                              ↓ min by HSK
행 2: HSK=B, edge_id=1, family_id=1  (변화 없음)
행 5: HSK=B, edge_id=3, family_id=1  (3→1, edge 3이 edge 1의 family에 합류)
```

**이 단계가 P&S의 Chaining을 대체한다.** B가 edge_id=1에서 new(HS_new)로, edge_id=3에서 obs(HS_old)로 등장하는 경우를 자동으로 포착한다.

#### Step B: `egen min(family_id), by(edge_id)`

같은 간선의 양쪽 노드(HS_old, HS_new)가 **동일한 최소 family_id**를 갖게 된다.

예: edge_id=2의 두 행:
```
행 3: HSK=A(obs쪽), edge_id=2, family_id=1  (Step A에서 업데이트됨)
행 4: HSK=C(new쪽), edge_id=2, family_id=2
                              ↓ min by edge_id
행 3: HSK=A, edge_id=2, family_id=1  (변화 없음)
행 4: HSK=C, edge_id=2, family_id=1  (2→1, C가 family 1에 합류)
```

#### 수렴 판단

`fid_by_edge != family_id`인 행이 0개이면, 더 이상 전파할 새로운 정보가 없으므로 루프를 종료한다.

**P&S 원본과의 대응:**

| P&S 원본 | 본 코드 |
|----------|--------|
| `egen min(setyr), by(obs)` | `egen min(family_id), by(HSK)` |
| `egen min(setyr), by(new)` | `egen min(family_id), by(edge_id)` |
| `compare t_zzz t_zlag` + `tab idx` | `gen changed = (fid_by_edge != family_id)` + `sum changed` |

P&S에서는 짝수 반복에 `by(new)`, 홀수 반복에 `by(obs)`를 교대 수행한다. 본 코드에서는 매 반복마다 `by(HSK)`와 `by(edge_id)`를 **모두** 수행한다. 이는 P&S의 2회 반복이 본 코드의 1회 반복에 대응하는 것과 유사하다.

**수렴 속도:** 유한 그래프에서 min 전파는 반드시 수렴한다. 최악의 경우 반복 횟수는 그래프의 지름(diameter)이다. 현재 한국 데이터(t12.dta 8,876행)에서는 12회 반복 후 수렴한다. 가장 큰 가족이 590개의 코드를 포함하기 때문에 단순 1:1 매핑 위주의 데이터셋보다 더 많은 반복이 필요하다.

### 4-4. 구체적 전파 예시: 3단계 체인

다음과 같은 3단계 체인을 생각하자:

```
2011년: 2833299000 → 2833292010    (edge 1)
2011년: 2833299000 → 2833292090    (edge 2)
2014년: 2833292010 → 2833292011    (edge 3)
2014년: 2833292010 → 2833292019    (edge 4)
2022년: 2833292011 → 2833292015    (edge 5)
```

Long 변환 후 초기 상태:

```
행   HSK           edge_id  family_id
 1   2833299000      1         1
 2   2833292010      1         1
 3   2833299000      2         2
 4   2833292090      2         2
 5   2833292010      3         3       ★ 2833292010이 행2와 행5에 등장
 6   2833292011      3         3
 7   2833292010      4         4
 8   2833292019      4         4
 9   2833292011      5         5       ★ 2833292011이 행6과 행9에 등장
10   2833292015      5         5
```

**반복 1 — min by HSK:**
```
HSK=2833299000: 행1(fid=1), 행3(fid=2)        → min=1, 행3 변경: 2→1
HSK=2833292010: 행2(fid=1), 행5(fid=3), 행7(fid=4) → min=1, 행5: 3→1, 행7: 4→1  ★ 체인 연결!
HSK=2833292090: 행4(fid=2)                     → min=2, 변화 없음
HSK=2833292011: 행6(fid=3), 행9(fid=5)         → min=3, 행9: 5→3
HSK=2833292019: 행8(fid=4)                     → min=4, 변화 없음
HSK=2833292015: 행10(fid=5)                    → min=5, 변화 없음
```

**반복 1 — min by edge_id:**
```
edge 1: 행1(1), 행2(1)  → min=1 (변화 없음)
edge 2: 행3(1), 행4(2)  → min=1, 행4: 2→1      ★ 2833292090이 family 1에 합류
edge 3: 행5(1), 행6(3)  → min=1, 행6: 3→1      ★ 2833292011이 family 1에 합류
edge 4: 행7(1), 행8(4)  → min=1, 행8: 4→1      ★ 2833292019가 family 1에 합류
edge 5: 행9(3), 행10(5) → min=3, 행10: 5→3
```

**반복 2 — min by HSK:**
```
HSK=2833292011: 행6(fid=1), 행9(fid=3) → min=1, 행9: 3→1   ★ 마지막 연결
```

**반복 2 — min by edge_id:**
```
edge 5: 행9(1), 행10(3) → min=1, 행10: 3→1
```

**반복 3:** 모든 family_id = 1. 변화 없음 → **수렴!**

최종 결과: 6개 코드 모두 `family_id = 1`.

Chaining 없이 3단계에 걸친 연쇄 변경이 하나의 family로 올바르게 식별되었다.

### 4-5. 노드별 family_id 추출 (Phase 1-D)

```stata
keep HSK family_id
duplicates drop HSK family_id, force
duplicates tag HSK, gen(dup)
assert dup == 0
```

min-propagation이 완료된 후, 각 HSK 코드에 대해 하나의 family_id를 추출한다.

**검증:** 하나의 HSK가 두 개 이상의 family_id를 가질 수 없다. 만약 그런 경우가 있다면 알고리즘에 오류가 있다는 뜻이므로 `assert`로 중단한다.

### 4-6. Self-loop only 코드 확인 (Phase 1-E)

```stata
use t12_clean, clear
keep if HS_old == HS_new
keep HS_old
rename HS_old HSK
duplicates drop HSK, force
merge 1:1 HSK using hsk_node_families_raw
```

Phase 1-A에서 self-loop을 제거했으므로, "self-loop만 있고 다른 간선이 없는 HSK"가 누락될 수 있다. 이 단계에서 이를 확인한다:

- `_merge==3`: 이미 다른 간선을 통해 family에 포함됨 → 문제 없음
- `_merge==1`: self-loop만 있는 코드 → 실질적 변화 없음 → family 부여 불필요

### 4-7. syntheticID 부여 (Phase 1-F)

```stata
use hsk_node_families_raw, clear
preserve
    keep family_id
    duplicates drop
    sort family_id
    gen long syntheticID = _n
    save family_id_map, replace
restore
merge m:1 family_id using family_id_map, nogen
keep HSK syntheticID
```

`family_id`는 `edge_id`에서 유래한 임의의 정수이다. 사용 편의를 위해 1부터 시작하는 순차 정수(`syntheticID`)로 재매핑한다.

**P&S의 `setyr`와의 관계:**
- P&S: `setyr = 순번.연도` (예: 1404.1998)
- 본 코드: `syntheticID = 순차 정수` (예: 42)

둘 다 family의 고유 식별자라는 점에서 동일한 역할을 한다.

---

## 5. PHASE 2: 최종 패널 생성

### 5-1. HSlist 패널 구축 (Phase 2-A)

```stata
use HSlist_2010, clear
keep HSK HSlist_year
rename HSlist_year year
replace year = round(year)
recast int year
save hsk_panel_all, replace

forvalues y = 2011/2026 {
    capture confirm file "HSlist_`y'.dta"
    if _rc == 0 {
        use HSlist_`y', clear
        keep HSK HSlist_year
        rename HSlist_year year
        replace year = round(year)
        recast int year
        append using hsk_panel_all
        save hsk_panel_all, replace
    }
}

duplicates drop HSK year, force
sort HSK year
```

2010~2026년의 모든 `HSlist_{year}.dta` 파일을 순차적으로 로드하여 하나의 패널로 합친다.

**결과:** (HSK, year) 쌍의 목록 — "이 10자리 코드가 이 연도에 유효했다"는 정보. 202,682행 (17개 연도, 평균 11,922개 코드/연도).

**`year`를 `round()`하는 이유:** Stata에서 dta 파일의 숫자가 float으로 저장될 경우 소수점 오차가 발생할 수 있으므로, 정수로 반올림 후 `recast int`로 형변환한다.

### 5-2. syntheticID merge (Phase 2-B)

```stata
merge m:1 HSK using hsk_node_families
```

HSK 패널에 Phase 1에서 생성한 syntheticID를 결합한다.

**merge 결과 해석:**
- `_merge==3` (match): HSK가 family에 속함 → syntheticID가 부여됨
- `_merge==1` (master only): HSK가 family에 속하지 않음 → **변경 없는 코드** → syntheticID가 아직 없음(missing)
- `_merge==2` (using only): family에 있지만 HSlist에 없음 → 있을 수 없는 경우 → 제거

### 5-3. 변경 없는 코드에 고유 syntheticID 부여

```stata
quietly sum syntheticID
local max_family_id = r(max)

preserve
    keep if _merge == 1
    keep HSK
    duplicates drop HSK, force
    sort HSK
    gen long syntheticID = _n + `max_family_id'
    save temp_no_family_ids, replace
restore

drop syntheticID _merge
merge m:1 HSK using hsk_node_families, nogen keep(master match)
merge m:1 HSK using temp_no_family_ids, update nogen
```

**plan.md의 요구사항:** "모든 행의 HSK, year에 상응하는 syntheticID가 존재해야함."

family에 속하지 않는 코드(2010~2026 기간 동안 전혀 변경되지 않은 코드)에도 고유한 syntheticID를 부여한다.

**방법:**
1. family syntheticID의 최대값(`max_family_id`)을 구한다
2. 변경 없는 고유 HSK를 정렬하여 `max_family_id + 1`부터 순차 번호를 부여한다
3. 같은 HSK는 여러 연도에 등장해도 **동일한 syntheticID**를 받는다

**현재 데이터 결과:** family는 1,809개이며:
- syntheticID 1~1,809: family에 속하는 코드 7,816개 (같은 family 내 코드들이 공유)
- syntheticID 1,810~9,315: 변경 없는 코드 7,506개 (각 HSK가 고유하게 보유)
- 총 9,315개 syntheticID

```stata
assert syntheticID != .
```

최종 검증: 모든 행에 syntheticID가 존재하는지 확인한다.

### 5-4. Family 상세 정보 저장 (Phase 2-C)

```stata
use edges_with_info, clear
rename HS_old HSK
merge m:1 HSK using hsk_node_families, keep(match master) nogen
rename HSK HS_old
rename syntheticID syntheticID_old

rename HS_new HSK
merge m:1 HSK using hsk_node_families, keep(match master) nogen
rename HSK HS_new
rename syntheticID syntheticID_new

/* 검증: 같은 간선의 양쪽이 같은 family인지 확인 */
gen byte id_match = (syntheticID_old == syntheticID_new)
```

각 간선(HS_old→HS_new 매핑)에 대해 양쪽 노드의 syntheticID를 부여하고, **두 값이 일치하는지 검증**한다.

만약 같은 간선의 HS_old와 HS_new가 서로 다른 syntheticID를 갖는다면, 알고리즘에 오류가 있다는 뜻이다. 정상적인 경우 모든 행에서 일치해야 한다.

### 5-5. 요약 통계 및 임시 파일 정리 (Phase 2-D, 2-E)

Family 크기 분포, 연도별 HSK 현황 등 요약 통계를 출력하고, 중간에 생성된 임시 파일을 삭제한다.

```stata
capture erase edges.dta
capture erase edge_long.dta
capture erase hsk_node_families_raw.dta
capture erase family_id_map.dta
capture erase hsk_panel_all.dta
capture erase edges_with_info.dta
capture erase t12_clean.dta
```

---

## 6. 출력 파일 설명

### hsk_concordance_2010_2026.dta (최종 패널)

| 변수 | 설명 |
|------|------|
| HSK | 10자리 HSK 코드 (문자열) |
| year | 해당 코드가 유효한 연도 (2010~2026, 정수) |
| syntheticID | 가족 식별자 (정수, missing 없음) |

- **202,682행** (17개 연도 × 평균 11,922개 코드/연도)
- 같은 syntheticID를 공유하는 코드들은 **같은 family** = **같은 상품 바구니**
- syntheticID가 고유한(다른 코드와 공유하지 않는) 코드는 기간 내 변경 없음

**사용 예시:**
```stata
use hsk_concordance_2010_2026, clear
merge 1:1 HSK year using trade_data
collapse (sum) trade_value, by(syntheticID year)
* → 시계열에서 동일 상품 바구니 추적 가능
```

### hsk_node_families.dta (HSK → syntheticID 매핑표)

family에 속하는 HSK 코드만 포함. 7,816행 (1,809개 family에 분포).

| 변수 | 설명 |
|------|------|
| HSK | 10자리 HSK 코드 |
| syntheticID | family 번호 (1 ~ family 수) |

### hsk_families_detail.dta (Family 상세)

각 syntheticID(family)에 어떤 HS_old→HS_new 매핑이 속하는지 기록.

| 변수 | 설명 |
|------|------|
| syntheticID | family 번호 |
| HS_old | 변경 전 HSK 코드 |
| year_old | HS_old가 최소한 유효했던 연도 |
| HS_new | 변경 후 HSK 코드 |
| year_new | 변경이 발효된 연도 |

### hsk_deleted_codes.dta (참고용)

후속 코드 없이 완전 삭제된 HSK 코드 목록. 현재 입력 자료(2025 replication 정정본)에서는 빈 HS_new가 0건이므로 이 파일은 새로 생성되지 않는다 (3-2절 (b) 참조). 폴더에 남아 있는 동일 명칭의 파일은 정정 작업 이전 시점의 산출물이다.

---

## 7. 전체 데이터 흐름 다이어그램

```
                          입력 파일
                    ┌────────┴────────┐
                    │                 │
               t12.dta          HSlist_{year}.dta
            (8,876행)            (2010~2026, 17개)
                    │                 │
                    ▼                 │
            ┌─── PHASE 0 ───┐        │
            │  0-A: 9자리 보정  │        │
            │     (현재 0행)    │        │
            │  0-A: 빈HS_new분리│        │
            │     (현재 0행)    │        │
            │  → t12_clean.dta │        │
            │    (8,876행)     │        │
            └───────┬────────┘        │
                    │                 │
                    ▼                 │
         ┌──── PHASE 1 ────────┐     │
         │                      │     │
         │  1-A: self-loop 제거  │     │
         │       (1,479행 제거)  │     │
         │       edge_id 부여    │     │
         │       (7,397 간선)    │     │
         │                      │     │
         │  1-B: Long 변환       │     │
         │       (HSK, edge_id)  │     │
         │       (14,794행)      │     │
         │                      │     │
         │  1-C: min 전파        │     │
         │       by(HSK) ↔       │     │
         │       by(edge_id)     │     │
         │       12회 후 수렴    │     │
         │                      │     │
         │  1-D: HSK별 family_id │     │
         │       추출 + 검증     │     │
         │                      │     │
         │  1-F: syntheticID     │     │
         │       순차 정수 매핑   │     │
         │                      │     │
         │  → hsk_node_families  │     │
         │    (7,816 HSK,        │     │
         │     1,809 families)   │     │
         │    최대 family 590개  │     │
         └──────────┬───────────┘     │
                    │                 │
                    ▼                 ▼
              ┌─── PHASE 2 ────────────┐
              │                         │
              │  2-A: HSlist 패널 구축    │
              │       (HSK, year) 합치기  │
              │       (202,682행)        │
              │                         │
              │  2-B: syntheticID merge  │
              │       family → 공유 ID   │
              │       non-family → 고유ID │
              │       (1,810~9,315)     │
              │                         │
              │  2-C: family 상세 저장    │
              │       (양쪽 노드 검증)    │
              │                         │
              └────────┬────────────────┘
                       │
                       ▼
                  출력 파일
           ┌──────┼──────┐
           │      │      │
    concordance  families  detail
    (패널)      (매핑표)   (상세)
```

---

## 부록: 한국 데이터의 특수성

### t12.dta의 구조적 특징이 알고리즘에 미치는 영향

1. **변경된 코드만 기록됨:** 변경 없는 1:1 연속 코드는 t12.dta에 행이 없다. 이 코드들은 HSlist에만 존재하며, Phase 2에서 고유 syntheticID를 부여받는다.

2. **self-loop의 의미:** HS_old==HS_new인 행은 "삭제"가 아닌 "변경(일부 분화)"을 의미한다. 해당 코드가 존속하면서 동시에 새 코드도 탄생한 경우이다.

3. **연도 간격이 불규칙:** P&S의 미국 데이터는 매년 또는 월별 변경이지만, 한국 데이터는 2009→2011, 2014→2017 등 불규칙 간격이다. edge-based 방식은 연도 정보를 사용하지 않으므로 이 차이에 영향을 받지 않는다.

4. **year_old / year_new의 의미:** 이 값들은 연계표에 기록된 change event의 연도 정보다. 이 값만으로 HS_old의 실제 유효 구간을 완전히 확정하지는 않는다. 어떤 HSK가 특정 연도에 실제 존재했는지는 `HSlist_{year}.dta`를 기준으로 판단하고, t12는 그 코드가 어떤 family 연결에 속하는지를 제공한다.
