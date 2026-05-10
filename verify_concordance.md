# verify_concordance.py 상세 해설

> **본 문서의 통계 수치 갱신**: 본 문서에 수록된 모든 정량 수치는 `2025 replication/main.do` 650~989행의 양방향 검증·정정 절차를 거친 현재의 t12.dta(8,876행)와 `import.do`로 산출된 현재의 HSlist_{2010~2026}.dta를 입력으로 한 실행 결과를 기준으로 한다. 정정 이전 원본 자료(8,927행, 9자리 77건, 빈 HS_new 12건)에 기반한 과거 산출물과는 다소의 수치 차이가 있다.

## 목차
1. [개요: 무엇을 하는 코드인가?](#1-개요)
2. [P&S 방법론과의 관계](#2-ps-방법론과의-관계)
3. [PHASE 0: 데이터 준비](#3-phase-0-데이터-준비)
4. [PHASE 1: Connected Component 분석](#4-phase-1-connected-component-분석)
5. [PHASE 2: 최종 패널 생성](#5-phase-2-최종-패널-생성)
6. [결과 저장 및 교차검증](#6-결과-저장-및-교차검증)
7. [Stata 코드와의 알고리즘 비교](#7-stata-코드와의-알고리즘-비교)
8. [전체 데이터 흐름 다이어그램](#8-전체-데이터-흐름-다이어그램)

---

## 1. 개요

`verify_concordance.py`는 `korean_hsk_concordance.do`의 결과를 **Python(networkx)**으로 독립 검증하는 스크립트이다.

**목적:**
- Stata 실행 전에 **예상 결과를 미리 확인** (ground truth 생성)
- Stata 실행 후에 결과를 **교차검증** (두 결과가 동일한지 비교)

**사용 라이브러리:**
- `pandas` — 데이터 로드/변환/저장
- `networkx` — 그래프 구축 및 연결 요소(connected component) 탐색
- `collections.Counter` — 빈도 집계

**핵심 차이:** Stata 코드가 "edge-based min-propagation"이라는 반복적 알고리즘을 사용하는 반면, Python 코드는 **networkx의 `connected_components()`**를 사용하여 동일 문제를 직접적으로 해결한다.

---

## 2. P&S 방법론과의 관계

### 왜 connected component인가?

Pierce & Schott (2012)의 핵심 통찰은 다음과 같다:

> HS 코드 변경 이력에서 직접·간접으로 연결된 모든 코드는 하나의 "가족(family)"을 형성한다. 이 가족에 속하는 코드들의 무역액을 합산해야 시계열 비교가 가능하다.

이를 그래프 이론으로 표현하면:
- **노드(node):** 각 HSK 코드
- **간선(edge):** HS_old→HS_new 매핑 (코드 변경 관계)
- **가족(family):** 이 그래프의 **연결 요소(connected component)**

P&S는 이 연결 요소를 Stata에서 찾기 위해 복잡한 "chaining + min-propagation" 알고리즘을 구현했다. 하지만 Python에서는 networkx 라이브러리가 제공하는 `connected_components()` 함수로 동일한 결과를 **단 한 줄**로 얻을 수 있다.

### 세 가지 구현의 관계

```
P&S 원본 (Stata):    Chaining + Min-Propagation (by obs/new)
korean_hsk_concordance.do: Edge-Based Min-Propagation (by HSK/edge_id)
verify_concordance.py:     networkx.connected_components() (BFS/DFS)
```

세 가지 모두 **무방향 그래프의 connected component를 찾는 문제**를 서로 다른 방식으로 해결한다. 수학적으로 동일한 결과를 보장한다.

---

## 3. PHASE 0: 데이터 준비

### 3-1. t12.dta 로드

```python
t12 = pd.read_stata("t12.dta")
```

pandas의 `read_stata()`로 Stata dta 파일을 로드한다. 결과는 8,876행 × 4열(HS_old, year_old, HS_new, year_new)의 DataFrame이다. 본 t12.dta는 `2025 replication/main.do`의 양방향 검증·정정 절차를 거쳐 산출된 정정본이다.

### 3-2. 9자리 HS_new 보정 (현재 데이터 0행)

```python
mask_9 = t12.HS_new.str.len() == 9
t12.loc[mask_9, "HS_new"] = "0" + t12.loc[mask_9, "HS_new"]
```

**처리 내용:** HS_new가 9자리인 경우(선행 0 누락) 앞에 "0"을 추가하여 10자리로 보정한다. 정정 이전 원본 자료에서는 77행이 발견되었으나, 현재 입력 자료는 `main.do`의 사전 정제 절차에서 모두 보정되어 0행이다. 본 코드는 입력 자료 갱신 시의 방어적 정제 단계로 유지된다.

**작동 원리:**
1. `t12.HS_new.str.len() == 9` → 각 행의 HS_new 문자열 길이가 9인지 판단하여 boolean mask 생성
2. `"0" + t12.loc[mask_9, "HS_new"]` → mask가 True인 행에만 문자열 결합 수행
3. 결과를 원래 위치에 대입

예: `"306141011"` → `"0306141011"` (03류 수산물 코드)

### 3-3. 빈 HS_new 분리 (현재 데이터 0행)

```python
mask_empty = t12.HS_new.str.len() == 0
deleted = t12[mask_empty][["HS_old", "year_old", "year_new"]].copy()
t12 = t12[~mask_empty].copy()
```

**처리 내용:** HS_new가 빈 문자열(길이 0)인 행은 후속 코드 없이 삭제된 HSK이다. 이 행들은 그래프에서 간선을 형성할 수 없으므로 별도 DataFrame(`deleted`)에 보관하고 메인 데이터에서 제거한다. 정정 이전 원본 자료에서는 12행이 발견되었으나, 현재 입력 자료에서는 `main.do`의 양방향 검증 절차에서 모두 정정 또는 통합되어 0행이다.

**`.copy()`를 사용하는 이유:** pandas에서 슬라이싱으로 생성된 DataFrame은 원본의 view일 수 있다. `.copy()`로 독립적인 복사본을 만들어 SettingWithCopyWarning을 방지한다.

### 3-4. Self-loop 제거 (1,479행)

```python
mask_self = t12.HS_old == t12.HS_new
t12_edges = t12[~mask_self].copy()
```

**처리 내용:** HS_old == HS_new인 행(self-loop)을 제거한다.

**Stata 코드와 동일한 로직:** self-loop은 그래프에서 노드를 자기 자신에게 연결하는 것이므로 connected component 탐색에 기여하지 않는다. self-loop 코드가 다른 간선에도 등장하면 그 간선을 통해 family에 자동 포함된다.

**결과:** t12_edges는 7,397행 (8,876 − 1,479)의 유효 간선 데이터이다.

---

## 4. PHASE 1: Connected Component 분석

### 4-1. 그래프 구축

```python
G = nx.Graph()
for _, row in t12_edges.iterrows():
    G.add_edge(row.HS_old, row.HS_new)
```

**작동 원리:**

1. `nx.Graph()` — **무방향 그래프** 객체를 생성한다. HS 코드 변경은 "A→B"라는 방향이 있지만, family 관점에서는 "A와 B가 연결되어 있다"는 무방향 관계가 중요하다.

2. `G.add_edge(row.HS_old, row.HS_new)` — 각 매핑을 그래프의 간선으로 추가한다. networkx에서 노드는 `add_edge` 호출 시 존재하지 않으면 자동 생성된다.

**중복 간선 처리:** 동일한 (HS_old, HS_new) 쌍이 여러 번 나타나더라도 `Graph()`는 **다중 간선을 허용하지 않으므로** 자동으로 하나의 간선만 유지된다. connected component 탐색에는 간선의 개수가 아니라 존재 여부만 중요하므로 이것이 올바른 동작이다.

**생성되는 그래프의 특성:**
- 노드: 고유 HSK 코드 7,816개 (HS_old와 HS_new에 등장하는 모든 코드)
- 간선: 고유 매핑 관계 7,370개 (중복 제거 후. 원본 7,397개 매핑 중 27건이 중복)

**Stata 코드와의 차이:**
- Stata: edge_id를 매개로 한 이분 그래프 → min-propagation 반복
- Python: HSK 코드를 직접 연결한 일반 그래프 → connected_components() 호출

### 4-2. 연결 요소 탐색

```python
components = list(nx.connected_components(G))
```

**이 한 줄이 P&S 전체 알고리즘(Chaining + Min-Propagation)과 동치이다.**

**`connected_components()`의 내부 작동:**

networkx의 `connected_components()`는 **BFS(너비 우선 탐색)** 알고리즘을 사용한다:

1. 방문하지 않은 임의의 노드 s를 선택한다
2. s에서 BFS를 수행하여 도달 가능한 모든 노드를 수집한다 → 이것이 하나의 connected component
3. 방문하지 않은 노드가 남아 있으면 1로 돌아간다
4. 모든 노드를 방문할 때까지 반복한다

**시간 복잡도:** O(V + E) — 노드 수 + 간선 수에 비례. 매우 효율적이다.

**반환값:** 각 connected component를 `set`으로 담은 generator. `list()`로 변환하면 set의 리스트가 된다.

예:
```python
components = [
    {'2833299000', '2833292010', '2833292090', '2833292011', '2833292019', '2833292015'},
    {'5506900000', '5506400000'},
    ...
]
```

### 4-3. Family 크기 분포 확인

```python
sizes = [len(c) for c in components]
dist = Counter(sizes)
for k in sorted(dist.keys())[:15]:
    print(f"  {k}개 코드: {dist[k]}개 family")
```

각 component(family)에 속하는 코드 수를 세어 분포를 출력한다. 이 분포는 Stata 코드의 `tab family_size` 결과와 일치해야 한다.

**실제 결과 (Python 실행, 현재 정정본 기준):**
- 총 1,809개 family
- 2개 코드 family가 가장 많음 (766개 family, 단순 1:1 코드 변경)
- 평균 family 크기 4.32개 코드, 중앙값 3개 코드
- **최대 family는 590개 코드를 포함** (8542·9031·9030·9027·8524·8517 등 전기·계측기 류가 누적 분화·수렴되어 형성된 거대 family)
- 두 번째로 큰 family는 245개 코드 (3824·3002·2933·3907 등 화학·의약품 류)
- 16개 이상 코드를 포함하는 거대 family는 36개

### 4-4. HSK → syntheticID 매핑 생성

```python
# HSK → edge_id 매핑 (Stata의 edge_id = _n 에 대응, 1-based)
hsk_edge_ids = {}
for idx, row in t12_edges.iterrows():
    eid = idx + 1
    for code in [row.HS_old, row.HS_new]:
        if code not in hsk_edge_ids:
            hsk_edge_ids[code] = []
        hsk_edge_ids[code].append(eid)

def min_edge_id(comp):
    return min(eid for code in comp for eid in hsk_edge_ids[code])

hsk_to_family = {}
for fam_id, comp in enumerate(sorted(components, key=min_edge_id), start=1):
    for code in comp:
        hsk_to_family[code] = fam_id
```

**작동 원리:**

1. **edge_id 매핑 구축:** t12_edges의 각 행(간선)에 1-based 순차 번호(`eid`)를 부여한다. 이는 Stata의 `gen long edge_id = _n`과 동일하다. 각 HSK 코드가 참여하는 edge_id 목록을 딕셔너리로 관리한다.

2. **min_edge_id 함수:** component에 속하는 모든 HSK 코드가 참여하는 edge_id 중 최소값을 반환한다. 이는 Stata의 min-propagation이 수렴한 후의 `family_id = min(edge_id in component)`와 동일하다.

3. `sorted(components, key=min_edge_id)` — 각 component를 **최소 edge_id** 기준으로 정렬한다. Stata에서 `sort family_id` 후 `gen syntheticID = _n`과 동일한 순서를 보장한다.

4. `enumerate(..., start=1)` — 1부터 시작하는 순차 정수 ID(fam_id)를 부여한다.

5. component 내 모든 code에 동일한 fam_id를 매핑한다.

**결과:** `hsk_to_family` 딕셔너리 — 7,816개 HSK → 1,809개 syntheticID

**Stata와의 번호 일치:**

- Stata: min-propagation 수렴 → `family_id = min(edge_id in component)` → `sort family_id` → `gen syntheticID = _n`
- Python: `sorted(components, key=min_edge_id)` → `enumerate(..., start=1)`

두 방법 모두 동일한 정렬 기준(최소 edge_id)을 사용하므로, **syntheticID 번호가 행 단위로 일치**한다. 이를 통해 Stata의 `cf` 명령으로 직접 비교 가능하다.

---

## 5. PHASE 2: 최종 패널 생성

### 5-1. HSlist 패널 구축

```python
panels = []
for year in range(2010, 2027):
    fname = f"HSlist_{year}.dta"
    if os.path.exists(fname):
        df = pd.read_stata(fname)
        df = df[["HSK", "HSlist_year"]].copy()
        df.rename(columns={"HSlist_year": "year"}, inplace=True)
        df["year"] = df["year"].round().astype(int)
        panels.append(df)

panel = pd.concat(panels, ignore_index=True)
panel.drop_duplicates(subset=["HSK", "year"], inplace=True)
panel.sort_values(["HSK", "year"], inplace=True)
```

**작동 원리:**

1. 2010~2026년(range(2010, 2027))의 각 연도에 대해 `HSlist_{year}.dta` 파일 존재 여부를 확인한다.

2. 존재하는 파일을 로드하여 (HSK, year) 열만 추출한다.

3. `round().astype(int)` — Stata dta에서 float으로 저장된 year를 정수로 변환한다. 이는 Stata 코드의 `replace year = round(year)` + `recast int year`와 동일하다.

4. 모든 연도의 DataFrame을 `pd.concat()`으로 합치고, 중복 제거 및 정렬한다.

**Stata 코드와의 대응:**
- Stata: `forvalues y = 2011/2026` + `append using hsk_panel_all`
- Python: `for year in range(2010, 2027)` + `pd.concat(panels)`

**결과:** 202,682행의 (HSK, year) 패널 (17개 연도, 평균 11,922개 코드/연도).

### 5-2. Family에 속하는 코드에 syntheticID 부여

```python
panel["syntheticID"] = panel["HSK"].map(hsk_to_family)
```

**`map()` 함수의 작동:**

`panel["HSK"]` 시리즈의 각 값을 `hsk_to_family` 딕셔너리에서 찾아 대응하는 값으로 변환한다.

- HSK가 딕셔너리에 존재하면 → 해당 syntheticID 반환
- HSK가 딕셔너리에 없으면 → `NaN` 반환

**Stata 코드와의 대응:**
- Stata: `merge m:1 HSK using hsk_node_families`
- Python: `panel["HSK"].map(hsk_to_family)`

둘 다 HSK를 key로 하여 syntheticID를 join하는 작업이다.

### 5-3. 변경 없는 코드에 고유 syntheticID 부여

```python
no_family = panel[panel.syntheticID.isna()]["HSK"].unique()
no_family_map = {hsk: i + num_families + 1 for i, hsk in enumerate(sorted(no_family))}
panel.loc[panel.syntheticID.isna(), "syntheticID"] = panel.loc[
    panel.syntheticID.isna(), "HSK"
].map(no_family_map)

panel["syntheticID"] = panel["syntheticID"].astype(int)
```

**작동 원리:**

1. `panel[panel.syntheticID.isna()]["HSK"].unique()` — syntheticID가 NaN인 행에서 고유 HSK 코드를 추출한다. 이 코드들은 t12.dta에 등장하지 않은, 즉 2010~2026 기간 동안 전혀 변경되지 않은 코드이다.

2. `enumerate(sorted(no_family))` — 이 코드들을 사전순으로 정렬하여 순차 번호를 매긴다.

3. `i + num_families + 1` — family syntheticID(1~num_families)와 겹치지 않도록, `num_families + 1`부터 시작하는 고유 번호를 부여한다.

4. `panel.loc[panel.syntheticID.isna(), "HSK"].map(no_family_map)` — NaN인 행에만 새 번호를 적용한다.

**Stata 코드와의 대응:**
```
Python:                                    Stata:
no_family = unique(HSK where NaN)     →   keep if _merge == 1; duplicates drop
no_family_map = dict(sorted, n+1~)    →   gen syntheticID = _n + max_family_id
panel.loc[NaN].map(no_family_map)     →   merge m:1 HSK using temp_no_family_ids, update
```

### 5-4. 최종 검증

```python
assert panel.syntheticID.notna().all(), "ERROR: syntheticID에 missing 존재!"
```

모든 행에 syntheticID가 존재하는지 확인한다. 하나라도 NaN이 있으면 AssertionError를 발생시킨다.

```python
n_changed = panel[panel.syntheticID <= num_families].shape[0]
n_unchanged = panel[panel.syntheticID > num_families].shape[0]
```

- `syntheticID <= num_families`: family에 속하는 행 (변경된 코드)
- `syntheticID > num_families`: 고유 ID 행 (변경 없는 코드)

### 5-5. 연도별 요약 통계

```python
summary = panel.groupby("year").agg(
    total=("HSK", "count"),
    in_family=("syntheticID", lambda x: (x <= num_families).sum()),
).reset_index()
summary["pct_changed"] = (summary.in_family / summary.total * 100).round(1)
```

**작동 원리:**

1. `groupby("year")` — 연도별로 그룹화한다.
2. `agg()` — 각 그룹에 대해:
   - `total`: 해당 연도의 총 HSK 코드 수 (행 수)
   - `in_family`: syntheticID가 num_families 이하인 행의 수 (family에 속하는 코드 수)
3. `pct_changed`: family에 속하는 코드의 비율 (%) — "이 연도의 코드 중 몇 %가 기간 중 변경을 경험했는가"

---

## 6. 결과 저장 및 교차검증

### 6-1. 패널 저장

```python
panel[["HSK", "year", "syntheticID"]].to_stata(
    "hsk_concordance_2010_2026_py.dta", write_index=False, version=118
)
```

**`to_stata()` 매개변수:**
- `write_index=False` — pandas DataFrame의 인덱스를 변수로 저장하지 않음
- `version=118` — Stata 14 호환 dta 형식 (Stata 13 이상에서 읽기 가능)

파일명에 `_py` 접미사를 붙여 Stata 결과(`hsk_concordance_2010_2026.dta`)와 구분한다.

### 6-2. HSK → syntheticID 매핑표 저장

```python
family_df = pd.DataFrame(
    [(k, v) for k, v in hsk_to_family.items()],
    columns=["HSK", "syntheticID"],
)
family_df.sort_values("HSK", inplace=True)
family_df.to_stata("hsk_node_families_py.dta", write_index=False, version=118)
```

`hsk_to_family` 딕셔너리를 DataFrame으로 변환하고 HSK 순으로 정렬하여 저장한다. family에 속하는 코드만 포함 (7,816행).

### 6-3. Family 상세 정보 저장

```python
detail = t12_edges.copy()
detail["syntheticID"] = detail["HS_old"].map(hsk_to_family)
detail.sort_values(["syntheticID", "year_old", "HS_old", "HS_new"], inplace=True)
detail = detail[["syntheticID", "HS_old", "year_old", "HS_new", "year_new"]]
detail.to_stata("hsk_families_detail_py.dta", write_index=False, version=118)
```

각 간선(HS_old→HS_new 매핑)에 HS_old의 syntheticID를 부여한다. HS_old와 HS_new는 같은 family에 속하므로, HS_old의 syntheticID를 사용하면 충분하다.

### 6-4. Stata 결과와의 교차검증 방법

코드 마지막에 안내하는 Stata 검증 명령:

```stata
use hsk_concordance_2010_2026, clear
cf HSK year syntheticID using hsk_concordance_2010_2026_py
```

`cf` (compare files) 명령은 두 dta 파일의 지정된 변수가 **행 단위로 완전히 동일**한지 비교한다. "variables are identical" 메시지가 나오면 검증 성공.

Python 코드는 Stata와 동일한 syntheticID 번호 부여 규칙(각 component의 최소 edge_id 기준 정렬)을 사용하므로, `cf` 명령으로 행 단위 완전 일치를 확인할 수 있다.

만약 `cf`가 실패한다면, family partition 수준의 일치를 다음과 같이 확인한다:

```stata
* family label의 일대일 대응성 검증
use hsk_node_families, clear
rename syntheticID sid_stata
merge 1:1 HSK using hsk_node_families_py
rename syntheticID sid_python
drop _merge

* 각 sid_stata가 정확히 하나의 sid_python에만 대응하는지 확인
bysort sid_stata: egen n_py_per_stata = nvals(sid_python)
assert n_py_per_stata == 1

* 각 sid_python이 정확히 하나의 sid_stata에만 대응하는지 확인
bysort sid_python: egen n_sta_per_py = nvals(sid_stata)
assert n_sta_per_py == 1
```

---

## 7. Stata 코드와의 알고리즘 비교

### 같은 문제, 다른 알고리즘

| 측면 | korean_hsk_concordance.do (Stata) | verify_concordance.py (Python) |
|------|----------------------------------|-------------------------------|
| **핵심 알고리즘** | Edge-based min-propagation | BFS/DFS (networkx) |
| **그래프 구조** | 이분 그래프 (HSK ↔ edge_id) | 일반 그래프 (HSK ↔ HSK) |
| **반복 여부** | 수렴까지 반복 (현재 데이터 12회) | 반복 없음 (1회 탐색) |
| **시간 복잡도** | O(V × E × 반복횟수) (egen min 기반) | O(V + E) (BFS) |
| **구현 복잡도** | 높음 (Long 변환, while 루프, 수렴 판단) | 낮음 (connected_components 한 줄) |
| **Chaining 필요** | 불필요 (edge-based 구조가 대체) | 불필요 (그래프 탐색이 대체) |
| **결과** | **동일** | **동일** |

### 왜 두 가지 구현이 모두 필요한가?

1. **Stata 코드**: P&S 방법론의 정신을 최대한 유지하면서 한국 데이터에 적용한 것. Stata 사용자가 원본 P&S 논문과 대조하며 이해할 수 있다. 또한 무역 데이터 분석의 후속 작업(merge, collapse 등)이 Stata에서 수행되므로 같은 환경에서의 연계가 자연스럽다.

2. **Python 코드**: 독립적인 검증 수단. 완전히 다른 알고리즘(BFS vs min-propagation)으로 동일한 결과를 얻는지 확인함으로써, 어느 한쪽의 구현 오류를 탐지할 수 있다.

### 구체적 예시로 보는 차이

**상황:** A→B(2011), B→C(2014), B→D(2014)

**Stata (Edge-based min-propagation):**
```
Long 변환:
  HSK=A, edge_id=1, fid=1
  HSK=B, edge_id=1, fid=1
  HSK=B, edge_id=2, fid=2     ← B가 edge 1과 2에 등장
  HSK=C, edge_id=2, fid=2
  HSK=B, edge_id=3, fid=3
  HSK=D, edge_id=3, fid=3

반복 1 — min by HSK:
  HSK=B → min(1, 2, 3) = 1    ← B를 통해 edge 1,2,3 연결!
반복 1 — min by edge_id:
  edge 2 → min(1, 2) = 1      ← C가 family 1에 합류
  edge 3 → min(1, 3) = 1      ← D가 family 1에 합류
반복 2: 변화 없음 → 수렴
```

**Python (networkx):**
```python
G.add_edge("A", "B")   # edge A→B
G.add_edge("B", "C")   # edge B→C
G.add_edge("B", "D")   # edge B→D

components = list(nx.connected_components(G))
# → [{'A', 'B', 'C', 'D'}]  ← BFS가 A에서 출발하여 B,C,D 모두 방문
```

**결과는 동일:** {A, B, C, D}가 하나의 family.

Stata는 min 값을 반복적으로 전파하여 수렴으로 도달하고, Python은 BFS로 한 번에 모든 연결 노드를 탐색한다. 경로는 다르지만 목적지는 같다.

---

## 8. 전체 데이터 흐름 다이어그램

```
                          입력 파일
                    ┌────────┴────────┐
                    │                 │
               t12.dta          HSlist_{year}.dta
            (8,876행)            (2010~2026, 17개)
                    │                 │
                    ▼                 │
            ┌─── PHASE 0 ───┐        │
            │  9자리 보정 (0행) │        │
            │  빈 HS_new 제거   │        │
            │    (0행)         │        │
            │  self-loop 제거  │        │
            │    (1,479행)     │        │
            │  → t12_edges     │        │
            │    (7,397행)     │        │
            └───────┬────────┘        │
                    │                 │
                    ▼                 │
         ┌──── PHASE 1 ────────┐     │
         │                      │     │
         │  nx.Graph() 구축      │     │
         │  G.add_edge(old,new) │     │
         │  → 7,816 노드        │     │
         │  → 7,370 고유 간선   │     │
         │                      │     │
         │  nx.connected_       │     │
         │  components(G)       │     │
         │  → 1,809 families    │     │
         │  최대 590개 코드     │     │
         │                      │     │
         │  HSK→family 매핑     │     │
         │  hsk_to_family dict  │     │
         └──────────┬───────────┘     │
                    │                 │
                    ▼                 ▼
              ┌─── PHASE 2 ────────────┐
              │                         │
              │  HSlist 패널 구축         │
              │  pd.concat(panels)      │
              │  → 202,682행             │
              │                         │
              │  panel["HSK"].map()     │
              │  → family→syntheticID   │
              │                         │
              │  no_family 코드에        │
              │  고유 ID 부여            │
              │  (1,810 ~ 9,315)        │
              │                         │
              │  assert notna().all()   │
              └────────┬────────────────┘
                       │
                       ▼
                  출력 파일
           ┌──────┼──────┐
           │      │      │
    _py.dta    _py.dta    _py.dta
    (패널)    (매핑표)    (상세)
```

---

## 부록: 실행 결과 (Python 실행 기준, 2025 replication 정정본 t12.dta)

```
PHASE 0: 데이터 준비
  원본 t12: 8,876 행
  9자리→10자리 보정: 0 행 (main.do 사전 정제)
  삭제된 코드 (빈 HS_new): 0 행 (main.do 사전 정제)
  Self-loop (HS_old==HS_new): 1,479 행
  유효 간선 수: 7,397
  year_old 범위: 2009 ~ 2024
  year_new 범위: 2011 ~ 2025

PHASE 1: Connected Component 분석
  총 노드 (고유 HSK): 7,816
  총 간선 (중복 제거 후): 7,370
  총 Family 수: 1,809
  Family 크기 통계:
    최소: 2개 코드, 최대: 590개 코드
    평균: 4.32개 코드, 중앙값: 3개 코드
    16개 이상 거대 family: 36개
  가장 큰 5개 family 크기: 590, 245, 129, 114, 85

PHASE 2: 최종 패널 생성
  HSK × Year 패널: 202,682 행
  syntheticID 범위: 1 ~ 9,315
  고유 syntheticID: 9,315
  Family에 속하는 행 (변경된 코드): syntheticID 1 ~ 1,809
  고유 ID 행 (변경 없는 코드): syntheticID 1,810 ~ 9,315
  변경 없는 고유 HSK 코드: 7,506개

연도별 HSK 코드 수:
  2010: 11,881    2017: 12,232
  2011: 11,900    2018: 12,232
  2012: 12,232    2019: 12,236
  2013: 12,233    2020: 12,234
  2014: 12,243    2021: 12,242
  2015: 12,243    2022: 11,293
  2016: 12,243    2023: 11,293
                  2024: 11,293
                  2025: 11,326
                  2026: 11,326
  연 평균: 11,922
```

**핵심 수치 해석:**
- 1,809개 family가 7,816개 HSK 코드를 묶는다 → 평균 family 크기 4.32개 코드
- 9,315 − 1,809 = 7,506개 코드는 변경 없이 고유 ID를 보유
- 202,682행 모두에 syntheticID가 존재 (missing 0건)
- 가장 큰 family는 590개 코드를 포함하며, 8542·9031·9030·9027·8524 등 전기·계측기·통신장비 류가 17년에 걸쳐 누적 분화·수렴된 결과이다. 두 번째로 큰 family는 245개로 화학·의약품 류(3824·3002·2933·3907)에 분포한다.
- 본 결과는 `2025 replication/main.do` 650~989행의 양방향 검증·정정 절차를 거친 t12.dta(8,876행)에 기반하며, 정정 이전 원본(8,927행, 9자리 77행, 빈 HS_new 12행, self-loop 1,518행)과 비교 시 자기 매핑의 정확성이 크게 개선되어 있다.
