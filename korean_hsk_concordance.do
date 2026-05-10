/*=============================================================================
  korean_hsk_concordance.do
  ─────────────────────────────────────────────────────────────────────────────
  한국 HSK 코드의 시계열 연계표(concordance) 구축
  Pierce & Schott (2012) "Concording U.S. HS Codes Over Time" 방법론의 한국 적용

  ─────────────────────────────────────────────────────────────────────────────
  방법론 개요:
    P&S는 (1)체인 구축 → (2)min 전파로 family를 식별한다.
    본 코드는 P&S의 핵심인 "min 전파"를 유지하되,
    체인 구축 단계를 "edge-based bipartite min-propagation"으로 대체하여
    동일한 결과를 더 간결하게 달성한다.

    핵심 아이디어:
      t12의 각 (HS_old, HS_new) 매핑을 그래프의 간선(edge)으로 보고,
      간선(edge_id)과 노드(HSK)로 구성된 이분 그래프에서
      반복적 min() 전파로 연결 요소(connected component)를 찾는다.

      이것은 P&S가 사용한 "egen min(), by(obs)" ↔ "egen min(), by(new)"
      교대 전파와 수학적으로 동치이나, 명시적 chaining이 불필요하다.

  ─────────────────────────────────────────────────────────────────────────────
  입력 파일:
    - t12.dta: HSK 변경 연계표 (HS_old, year_old, HS_new, year_new)
    - HSlist_{year}.dta: 연도별 유효 HSK 목록 (2010~2026)

  출력 파일:
    - hsk_concordance_2010_2026.dta: 최종 패널 (HSK, year, syntheticID)
    - hsk_node_families.dta: HSK → syntheticID 매핑표
    - hsk_families_detail.dta: family별 상세 (edge 정보 포함)
    - hsk_change_log_full.dta: audit용 전체 변경 이력 (self-loop, 삭제 포함)

  ─────────────────────────────────────────────────────────────────────────────
  실행 전 확인:
    - 작업 디렉토리에 t12.dta, HSlist_2010.dta ~ HSlist_2026.dta 존재
    - Stata 13 이상 권장 (egen, joinby 등 사용)
  =============================================================================*/

clear all
set more off
set type double

/* ★ 작업 디렉토리 설정 — 사용자 환경에 맞게 수정 */
//cd "D:\JJ Dropbox\KCTDI_Research\덤핑방지 수입동향 모니터링\품목분류표\Pierce&Schott"
cd "D:\JJ Dropbox\KCTDI_Research\덤핑방지 수입동향 모니터링\2025 replication"


/*#############################################################################
  엑셀 import
  #############################################################################
do import 
*/


/*#############################################################################
  PHASE 0: 데이터 준비
  #############################################################################

  t12.dta 정리:
    (1) HS_new가 9자리인 경우 → 앞에 "0" 추가하여 10자리로 표준화
    (2) HS_new가 빈 문자열인 경우 → 후속 코드 없이 삭제된 HSK. 간선 형성 불가 → 별도 보관
    (3) HS_old == HS_new인 경우 → "변경" 케이스 (코드는 동일하나 다른 분화가 함께 발생)
        - 그래프에서 self-loop이므로 연결에 영향 없으나, 해당 코드가 family에 속한다는 정보 보존 필요
  #############################################################################*/

display _n "============================================="
display "PHASE 0: 데이터 준비"
display "=============================================" _n

use t12, clear
describe
display "원본 t12: " _N " 행"

/*─────────────────────────────────────────────────────────────────────────────
  0-A: HS_new 길이 이상치 처리
  ─────────────────────────────────────────────────────────────────────────────
  문제: 일부 HS_new가 9자리 (앞자리 "0" 누락) 또는 0자리 (빈 문자열 = 삭제)

  9자리 예: "306141011" → "0306141011" (수산물 코드, 03류는 0으로 시작)
  0자리 예: 2933599000(2013) → ""(2014) = 해당 코드 완전 삭제
─────────────────────────────────────────────────────────────────────────────*/

gen len_new = strlen(HS_new)
tab len_new

/* 9자리: 앞에 "0" 추가 */
replace HS_new = "0" + HS_new if len_new == 9
display "9자리→10자리 보정: " r(N) " 행 (주로 03류 수산물 코드)"

/* 0자리(빈 문자열): 삭제된 코드 → 별도 파일로 분리 보관 */
preserve
    keep if len_new == 0
    display "삭제된 코드 (HS_new 빈 문자열): " _N " 행"
    if _N > 0 {
        keep HS_old year_old year_new
        rename HS_old HSK
        gen byte deleted = 1
        save hsk_deleted_codes, replace
    }
restore
drop if len_new == 0

/* 최종 검증: 모든 HS_old, HS_new가 10자리인지 확인 */
assert strlen(HS_old) == 10
assert strlen(HS_new) == 10

drop len_new

display "정리된 t12: " _N " 행 (빈 HS_new 제거 후)"

save t12_clean, replace



/*#############################################################################
  PHASE 1: 연결 요소 분석 (Connected Component via Min-Propagation)
  #############################################################################

  ★★★ 핵심 알고리즘 ★★★

  P&S 방법론과의 관계:
  ──────────────────────────────────────────────────────────────────
  P&S 원본:
    Step 1: 연도별 데이터 분리 (chopping)
    Step 2: 체인 구축 (joinby로 연도 간 순차 merge)  ← 복잡
    Step 3: min 전파 (egen min() by obs/new 교대)    ← 핵심

  본 코드:
    Step 1: 간선 리스트 생성 + Long 변환
    Step 2: min 전파 (egen min() by HSK/edge_id 교대) ← P&S Step 3과 동치
  ──────────────────────────────────────────────────────────────────

  왜 chaining이 불필요한가?
    P&S에서 chaining은 "B가 year1에서 new, year2에서 obs로 등장"하는
    간접 연결을 발견하기 위한 것이다.

    본 코드에서는 t12의 모든 간선을 단일 그래프에 넣고,
    "edge_id"를 매개로 한 이분 그래프 min 전파가
    자동으로 모든 직접·간접 연결을 발견한다.

    원리: HSK 코드가 HS_old로도 HS_new로도 등장하면,
    같은 HSK를 공유하는 모든 간선이 min(by HSK)에 의해 연결된다.
    → P&S의 chaining과 동일한 결과.

  이분 그래프 구조:
    한쪽 노드: 고유 HSK 코드
    다른쪽 노드: edge_id (유효 간선, self-loop 제외)
    간선: 각 edge_id는 정확히 2개의 HSK 노드와 연결
  #############################################################################*/

display _n "============================================="
display "PHASE 1: 연결 요소 분석 (Family Identification)"
display "=============================================" _n


/*─────────────────────────────────────────────────────────────────────────────
  1-A: 간선(edge) 번호 부여
  ─────────────────────────────────────────────────────────────────────────────
  t12_clean의 각 행이 하나의 간선.
  self-loop (HS_old == HS_new) 제거: 그래프 연결에 기여하지 않음.
  단, self-loop에 해당하는 HSK가 다른 간선에도 등장하면 family에 포함됨.
─────────────────────────────────────────────────────────────────────────────*/

use t12_clean, clear

/* self-loop 제거 — HS_old==HS_new인 행은 그래프 연결에 무의미 */
gen byte selfloop = (HS_old == HS_new)
display "Self-loop (HS_old==HS_new) 행 수:"
tab selfloop

/*─────────────────────────────────────────────────────────────────────────────
  ★ self-loop 코드의 family 귀속 보장:

  plan.md 예시: 5506900000(2014) → 5506400000(2017) + 5506900000(2017)
  여기서 5506900000→5506900000은 self-loop이지만,
  5506900000→5506400000은 실제 간선.
  따라서 5506900000은 이 간선을 통해 family에 자동 포함됨.

  만약 self-loop만 있는 HSK라면 (다른 간선 없음)?
  → 실질적으로 변화가 없는 코드이므로 family 불필요.
─────────────────────────────────────────────────────────────────────────────*/

drop if selfloop == 1
drop selfloop

/* 간선 번호 부여 */
gen long edge_id = _n
display "유효 간선 수 (self-loop 제외): " _N

/* 원본 간선 정보 보존 (나중에 상세 출력용) */
save edges_with_info, replace

keep HS_old HS_new edge_id
save edges, replace


/*─────────────────────────────────────────────────────────────────────────────
  1-B: Long 형태 변환 — 이분 그래프의 간선 생성
  ─────────────────────────────────────────────────────────────────────────────
  각 간선 (HS_old, HS_new)를 두 행으로 분리:
    행 1: HSK = HS_old, edge_id = N
    행 2: HSK = HS_new, edge_id = N

  이렇게 하면 (HSK, edge_id) 쌍으로 구성된 이분 그래프가 만들어진다.

  예: 간선 edge_id=5: HS_old=2833299000, HS_new=2833292010
    → (HSK=2833299000, edge_id=5)
    → (HSK=2833292010, edge_id=5)

  이 구조에서:
    - by(HSK) min: 같은 HSK 노드를 공유하는 간선들이 같은 최소값을 공유
    - by(edge_id) min: 같은 간선의 양쪽 HSK 노드가 같은 최소값을 공유
─────────────────────────────────────────────────────────────────────────────*/

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

/* 합치기: Long 형태 이분 그래프 */
use temp_side1, clear
append using temp_side2

/* 초기 family_id = edge_id (각 간선이 자기 자신을 고유 ID로 시작) */
gen long family_id = edge_id

sort edge_id HSK
display "이분 그래프 행 수: " _N " (간선 수 × 2)"

save edge_long, replace

/* 임시 파일 정리 */
erase temp_side1.dta
erase temp_side2.dta


/*─────────────────────────────────────────────────────────────────────────────
  1-C: 반복적 min 전파 — 수렴할 때까지
  ─────────────────────────────────────────────────────────────────────────────

  ★ P&S의 핵심 알고리즘과 동치:

  P&S 원본 (schedule_b.do 142~166행):
    while `stop'==0 {
        if mod(`zzz',2)==0 { egen t`zzz' = min(t`zlag'), by(new) }
        if mod(`zzz',2)~=0 { egen t`zzz' = min(t`zlag'), by(obs) }
        ...수렴 확인...
    }

  본 코드:
    while `stop'==0 {
        egen ... = min(family_id), by(HSK)      ← P&S의 by(obs) + by(new) 통합
        egen ... = min(family_id), by(edge_id)   ← P&S의 bipartite 다른 쪽
        ...수렴 확인...
    }

  차이점: P&S는 obs와 new가 서로 다른 열이므로 교대 전파.
  본 코드는 HSK가 단일 열이므로 한 번에 양쪽 모두 전파.
  edge_id가 P&S의 "행(row)"에 해당하여 양쪽 노드를 연결.

  수렴 보장: 유한 그래프에서 min 전파는 반드시 수렴.
  최악의 경우 반복 횟수 = 그래프 지름(diameter).
  한국 데이터에서는 5~10회 이내 수렴 예상.
─────────────────────────────────────────────────────────────────────────────*/

use edge_long, clear

local stop = 0
local iter = 1

while `stop' == 0 {
    display _n "--- Iteration `iter' ---"

    /*─────────────────────────────────────────────────────────────────────
      Step A: HSK 기준 min 전파

      같은 HSK 코드를 공유하는 모든 간선(edge_id)이
      동일한 최소 family_id를 갖게 된다.

      예: HSK=B가 edge_id=1(A→B)과 edge_id=5(B→C)에 등장하면,
          두 간선 모두 min(family_id of edge1, family_id of edge5)를 받음.
      → 이것이 P&S의 chaining을 대체하는 핵심 메커니즘!
         B가 HS_new(간선1)이면서 HS_old(간선5)인 것을 자동 포착.
    ─────────────────────────────────────────────────────────────────────*/
    egen long fid_by_node = min(family_id), by(HSK)
    replace family_id = fid_by_node
    drop fid_by_node

    /*─────────────────────────────────────────────────────────────────────
      Step B: edge_id 기준 min 전파

      같은 간선의 양쪽 노드(HS_old, HS_new)가
      동일한 최소 family_id를 갖게 된다.

      예: edge_id=1의 두 행 (HSK=A, HSK=B)에서
          A의 family_id=10, B의 family_id=3이면 → 둘 다 3이 됨.
    ─────────────────────────────────────────────────────────────────────*/
    egen long fid_by_edge = min(family_id), by(edge_id)

    /*─────────────────────────────────────────────────────────────────────
      수렴 확인: 이번 반복에서 변화가 없으면 종료

      P&S 원본에서는 compare + tab으로 수렴 판단 (r(r)==1).
      본 코드에서는 직접 차이를 계산.
    ─────────────────────────────────────────────────────────────────────*/
    gen byte changed = (fid_by_edge != family_id)
    quietly sum changed
    display "  변경된 행: " r(sum) " / " _N

    local stop = (r(sum) == 0)

    replace family_id = fid_by_edge
    drop fid_by_edge changed

    local iter = `iter' + 1
}

display _n "★ " `iter'-1 " 회 반복 후 수렴 완료"


/*─────────────────────────────────────────────────────────────────────────────
  1-D: 노드별 family_id 추출
  ─────────────────────────────────────────────────────────────────────────────
  각 HSK 코드에 family_id를 부여.
  하나의 HSK는 정확히 하나의 family에만 속해야 한다.
─────────────────────────────────────────────────────────────────────────────*/

keep HSK family_id
duplicates drop HSK family_id, force

/* 검증: 하나의 HSK가 두 개 이상의 family에 속하는 경우가 없는지 확인 */
duplicates report HSK
/* 만약 중복이 있다면 알고리즘 오류 → assert로 중단 */
duplicates tag HSK, gen(dup)
assert dup == 0
drop dup

sort HSK
display _n "Family에 속하는 고유 HSK 코드 수: " _N

save hsk_node_families_raw, replace


/*─────────────────────────────────────────────────────────────────────────────
  1-E: self-loop only 코드 추가
  ─────────────────────────────────────────────────────────────────────────────
  Phase 1-A에서 self-loop을 제거했으므로,
  "self-loop만 있고 다른 간선이 없는 HSK"가 누락될 수 있다.

  이런 코드는 t12에 등장하지만 실질적 변화가 없는 코드이다.
  다만, 다른 코드와 함께 같은 change event에 속해 있었을 수 있으므로,
  정확성을 위해 이 코드들도 family에 포함시킨다.

  처리: self-loop의 HS_old가 이미 family에 있으면 → 그 family_id 사용
        없으면 → 해당 코드는 변화가 없으므로 family 미부여
─────────────────────────────────────────────────────────────────────────────*/

use t12_clean, clear
keep if HS_old == HS_new
keep HS_old
rename HS_old HSK
duplicates drop HSK, force

/* 이미 family에 있는지 확인 */
merge 1:1 HSK using hsk_node_families_raw
/* _merge==3: 이미 family에 속함 (다른 간선으로 포함됨) → OK */
/* _merge==1: self-loop만 있는 코드 → family 미부여 (변화 없음) */
display "Self-loop only 코드 중 이미 family에 속한 코드:"
tab _merge
drop if _merge == 1  /* family에 속하지 않는 self-loop only 코드 제거 */
drop _merge

/* hsk_node_families_raw 그대로 사용 (self-loop only는 이미 포함되어 있거나 불필요) */


/*─────────────────────────────────────────────────────────────────────────────
  1-F: syntheticID 부여 (family_id를 1부터 순차 정수로 재매핑)
  ─────────────────────────────────────────────────────────────────────────────
  family_id는 edge_id에서 유래한 임의의 정수.
  사용 편의를 위해 1부터 시작하는 순차 정수로 변환.

  P&S에서는 setyr = count.year 형태를 사용했으나,
  한국 데이터에서는 단순 정수 ID가 더 직관적.

  syntheticID가 P&S의 setyr에 대응하는 개념이다.
─────────────────────────────────────────────────────────────────────────────*/

use hsk_node_families_raw, clear

/* family_id → syntheticID 매핑 테이블 생성 */
preserve
    keep family_id
    duplicates drop
    sort family_id
    gen long syntheticID = _n
    display "총 family(syntheticID) 수: " _N
    save family_id_map, replace
restore

/* HSK에 syntheticID 부여 */
merge m:1 family_id using family_id_map, nogen
keep HSK syntheticID
sort HSK

display "최종 HSK-syntheticID 매핑:"
display "  고유 HSK: " _N
quietly sum syntheticID
display "  고유 syntheticID: " r(max)

save hsk_node_families, replace



/*#############################################################################
  PHASE 2: 최종 출력 생성 — HSK × Year 패널
  #############################################################################

  목표: (HSK, year, syntheticID) 형태의 패널 데이터 생성

  - HSK: 10자리 HSK 코드
  - year: 해당 코드가 유효한 연도 (2010~2026)
  - syntheticID: 모든 HSK에 부여. family에 속하면 공유 ID, 아니면 고유 ID.

  사용법:
    * 같은 syntheticID를 가진 코드들은 동일 family → 시계열에서 같은 "상품 바구니"
    * syntheticID가 고유한(다른 코드와 공유하지 않는) 코드는 기간 내 변경 없음
    * 모든 행에 syntheticID가 존재 (missing 없음)
  #############################################################################*/

display _n "============================================="
display "PHASE 2: 최종 패널 생성"
display "=============================================" _n


/*─────────────────────────────────────────────────────────────────────────────
  2-A: HSlist 패널 구축 (2010~2026)
  ─────────────────────────────────────────────────────────────────────────────
  각 연도의 HSlist_{year}.dta를 읽어서 하나의 패널로 합친다.
  결과: (HSK, year) 쌍의 목록 — "이 코드가 이 연도에 유효했다"
─────────────────────────────────────────────────────────────────────────────*/

/* 첫 번째 연도 로드 */
use HSlist_2010, clear
keep HSK HSlist_year
rename HSlist_year year
/* year가 float일 수 있으므로 정수 변환 */
replace year = round(year)
recast int year
save hsk_panel_all, replace

/* 나머지 연도 append */
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
    else {
        display "주의: HSlist_`y'.dta 파일 없음 — 건너뜀"
    }
}

/* 중복 제거 및 정렬 */
duplicates drop HSK year, force
sort HSK year

display "HSK × Year 패널:"
display "  총 행: " _N
quietly tab year
display "  연도 범위: 2010 ~ 2026"


/*─────────────────────────────────────────────────────────────────────────────
  2-B: syntheticID merge
  ─────────────────────────────────────────────────────────────────────────────
  HSK 패널에 syntheticID를 결합.

  _merge 결과 해석:
    _merge==3: HSK가 family에 속함 → syntheticID 부여됨
    _merge==1: HSK가 family에 속하지 않음 → syntheticID = . (변경 없는 코드)
    _merge==2: family에 있지만 HSlist에 없음 → 있을 수 없음 (drop)
─────────────────────────────────────────────────────────────────────────────*/

merge m:1 HSK using hsk_node_families
display _n "패널-Family merge 결과:"
tab _merge

/* _merge==2는 HSlist에 없는 코드 → 제거 */
drop if _merge == 2

/*─────────────────────────────────────────────────────────────────────────────
  ★ 변경 없는 코드에도 고유한 syntheticID 부여

  _merge==1: family에 속하지 않는 코드 (기간 내 변경 없음)
  이 코드들에도 고유한 syntheticID를 부여하여
  최종 데이터의 모든 행에 syntheticID가 존재하게 한다.

  방법: family syntheticID의 최대값 이후부터 고유 HSK별 순차 번호 부여.
  → 같은 HSK가 여러 연도에 등장해도 동일한 syntheticID를 받음.
─────────────────────────────────────────────────────────────────────────────*/

/* family가 없는 코드의 고유 HSK 목록 추출 및 번호 부여 */
quietly sum syntheticID
local max_family_id = r(max)
display "  Family syntheticID 최대값: " `max_family_id'

/* 같은 HSK는 같은 syntheticID를 받아야 하므로, HSK별로 고유 번호 생성 */
preserve
    keep if _merge == 1
    keep HSK
    duplicates drop HSK, force
    sort HSK
    gen long syntheticID = _n + `max_family_id'
    display "  변경 없는 고유 HSK 코드 수: " _N
    display "  이들의 syntheticID 범위: " `max_family_id'+1 " ~ " _N+`max_family_id'
    save temp_no_family_ids, replace
restore

/* _merge==1인 행에 syntheticID 부여 */
drop syntheticID
drop _merge
merge m:1 HSK using hsk_node_families, nogen keep(master match)
merge m:1 HSK using temp_no_family_ids, update nogen

/* 모든 행에 syntheticID가 존재하는지 최종 확인 */
assert syntheticID != .

sort HSK year
order HSK year syntheticID

display _n "최종 패널 구성:"
display "  총 행: " _N
quietly sum syntheticID
display "  syntheticID 범위: " r(min) " ~ " r(max)
display "  고유 syntheticID 수: " r(max)

/* 변경된 코드 vs 변경 없는 코드 구분 */
gen byte changed = (syntheticID <= `max_family_id')
display _n "  변경된 코드 (family에 속함): "
count if changed == 1
display "  변경 없는 코드 (고유 ID): "
count if changed == 0
drop changed

save hsk_concordance_2010_2026, replace
capture erase temp_no_family_ids.dta


/*─────────────────────────────────────────────────────────────────────────────
  2-C: Family별 상세 정보 저장
  ─────────────────────────────────────────────────────────────────────────────
  각 syntheticID(family)에 어떤 HS_old→HS_new 매핑이 속하는지 상세 기록.
  이 파일을 통해 "syntheticID=42는 어떤 코드 변경 이력을 가지는가?" 확인 가능.
─────────────────────────────────────────────────────────────────────────────*/

use edges_with_info, clear

/* HS_old 기준으로 family 부여 */
rename HS_old HSK
merge m:1 HSK using hsk_node_families, keep(match master) nogen
rename HSK HS_old
rename syntheticID syntheticID_old

/* HS_new 기준으로 family 부여 (검증용 — 같아야 함) */
rename HS_new HSK
merge m:1 HSK using hsk_node_families, keep(match master) nogen
rename HSK HS_new
rename syntheticID syntheticID_new

/* 검증: 같은 간선의 양쪽이 같은 family에 속하는지 확인 */
gen byte id_match = (syntheticID_old == syntheticID_new)
quietly sum id_match
if r(mean) < 1 {
    display "경고: syntheticID 불일치 발견 — 알고리즘 검토 필요"
    list if id_match == 0 in 1/10
}
else {
    display "검증 완료: 모든 간선의 양쪽 노드가 동일 family에 속함 ✓"
}

rename syntheticID_old syntheticID
drop syntheticID_new id_match edge_id

order syntheticID HS_old year_old HS_new year_new
sort syntheticID year_old HS_old HS_new

save hsk_families_detail, replace


/*─────────────────────────────────────────────────────────────────────────────
  2-C2: Audit용 전체 변경 이력 저장
  ─────────────────────────────────────────────────────────────────────────────
  hsk_families_detail.dta는 family 식별에 사용된 유효 간선(self-loop 제외)만 포함.
  audit 목적으로 t12.dta의 전체 매핑(self-loop, 삭제 코드 포함)을 보존하는
  별도 파일을 생성한다.

  record_type 변수:
    "nonself"  — 실제 변경 간선 (HS_old ≠ HS_new, HS_new 비어있지 않음)
    "selfloop" — self-loop (HS_old == HS_new)
    "deleted"  — 삭제 (HS_new 빈 문자열)
─────────────────────────────────────────────────────────────────────────────*/

use t12_clean, clear

/* record_type 분류 */
gen str8 record_type = "nonself"
replace record_type = "selfloop" if HS_old == HS_new

/* 삭제 코드 복원 (hsk_deleted_codes.dta에서) */
capture confirm file "hsk_deleted_codes.dta"
if _rc == 0 {
    preserve
        use hsk_deleted_codes, clear
        rename HSK HS_old
        gen HS_new = ""
        gen str8 record_type = "deleted"
        drop deleted
        save temp_deleted_for_log, replace
    restore
    append using temp_deleted_for_log
    capture erase temp_deleted_for_log.dta
}

/* syntheticID 부여 (HS_old 기준) */
rename HS_old HSK
merge m:1 HSK using hsk_node_families, keep(master match) nogen
rename HSK HS_old

/* selfloop_only 표시: self-loop만 있고 family에 속하지 않는 코드 */
gen byte selfloop_only = (record_type == "selfloop" & syntheticID == .)

order record_type syntheticID selfloop_only HS_old year_old HS_new year_new
sort record_type year_old HS_old HS_new

save hsk_change_log_full, replace
display "  hsk_change_log_full.dta 저장 완료 (" _N " 행)"
display "    record_type별:"
tab record_type


/*─────────────────────────────────────────────────────────────────────────────
  2-D: 요약 통계
─────────────────────────────────────────────────────────────────────────────*/

display _n "============================================="
display "요약 통계"
display "=============================================" _n

/* Family 크기 분포 */
use hsk_node_families, clear
bysort syntheticID: gen family_size = _N
bysort syntheticID: keep if _n == 1

display "Family(syntheticID) 크기 분포:"
tab family_size if family_size <= 10
display "  10개 초과: "
count if family_size > 10
display "  최대: "
sum family_size
display "  최대 family 크기: " r(max)

/* 최종 패널 연도별 현황 */
use hsk_concordance_2010_2026, clear
display _n "연도별 HSK 코드 현황:"
gen byte has_id = (syntheticID != .)
table year, c(n syntheticID sum has_id) format(%10.0f)


/*─────────────────────────────────────────────────────────────────────────────
  2-E: 임시 파일 정리
─────────────────────────────────────────────────────────────────────────────*/

capture erase edges.dta
capture erase edge_long.dta
capture erase hsk_node_families_raw.dta
capture erase family_id_map.dta
capture erase hsk_panel_all.dta
capture erase edges_with_info.dta
capture erase t12_clean.dta


display _n "============================================="
display "완료!"
display "============================================="
display _n "출력 파일:"
display "  1. hsk_concordance_2010_2026.dta  (HSK, year, syntheticID) 패널"
display "  2. hsk_node_families.dta          HSK → syntheticID 매핑표 (family 코드만)"
display "  3. hsk_families_detail.dta        Family별 HS_old→HS_new 상세"
display "  4. hsk_deleted_codes.dta          삭제된 코드 목록 (참고용)"
display "  5. hsk_change_log_full.dta        Audit용 전체 변경 이력 (self-loop/삭제 포함)"
display _n "사용법 예시:"
display "  use hsk_concordance_2010_2026, clear"
display "  * 무역 데이터와 merge 후, syntheticID 기준으로 합산:"
display "  * merge 1:1 HSK year using trade_data"
display "  * collapse (sum) trade_value, by(syntheticID year)"
display "  * → 이렇게 하면 시계열에서 동일 상품 바구니 추적 가능"
display _n "주의:"
display "  * syntheticID는 모든 행에 존재 (missing 없음)"
display "  * 같은 syntheticID = 같은 family = 같은 상품 바구니"
display "  * 변경 없는 코드도 고유 syntheticID를 가짐 (다른 코드와 공유하지 않음)"
