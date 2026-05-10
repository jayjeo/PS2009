"""
verify_concordance.py
─────────────────────────────────────────────────────────────────────────────
korean_hsk_concordance.do의 결과를 Python(networkx)으로 독립 검증.
Stata 실행 전 예상 결과 확인 또는 Stata 결과 교차검증 용도.

사용법:
  python verify_concordance.py
─────────────────────────────────────────────────────────────────────────────
"""

import pandas as pd
import networkx as nx
from collections import Counter
import os

# ─────────────────────────────────────────────────────────────────────────────
# 작업 디렉토리
# ─────────────────────────────────────────────────────────────────────────────
WORK_DIR = "/mnt/d/JJ Dropbox/KCTDI_Research/덤핑방지 수입동향 모니터링/품목분류표/Pierce&Schott"
os.chdir(WORK_DIR)


# =============================================================================
# PHASE 0: 데이터 준비
# =============================================================================
print("=" * 60)
print("PHASE 0: 데이터 준비")
print("=" * 60)

t12 = pd.read_stata("t12.dta")
print(f"원본 t12: {len(t12)} 행")

# 9자리 HS_new → 10자리 (앞에 0 추가)
mask_9 = t12.HS_new.str.len() == 9
t12.loc[mask_9, "HS_new"] = "0" + t12.loc[mask_9, "HS_new"]
print(f"  9자리→10자리 보정: {mask_9.sum()} 행")

# 빈 HS_new 분리 (삭제된 코드)
mask_empty = t12.HS_new.str.len() == 0
deleted = t12[mask_empty][["HS_old", "year_old", "year_new"]].copy()
print(f"  삭제된 코드 (빈 HS_new): {len(deleted)} 행")
t12 = t12[~mask_empty].copy()

# ★ audit용: self-loop 제거 전의 t12_clean 보존 (Phase 2-C2에서 사용)
t12_clean = t12.copy()

# self-loop 제거 (HS_old == HS_new)
mask_self = t12.HS_old == t12.HS_new
print(f"  Self-loop (HS_old==HS_new): {mask_self.sum()} 행 — 그래프에서 제거")
t12_edges = t12[~mask_self].copy()
t12_edges.reset_index(drop=True, inplace=True)
print(f"  유효 간선 수: {len(t12_edges)}")


# =============================================================================
# PHASE 1: Connected Component (networkx)
# =============================================================================
print(f"\n{'=' * 60}")
print("PHASE 1: Connected Component 분석")
print("=" * 60)

# 그래프 구축
G = nx.Graph()
for _, row in t12_edges.iterrows():
    G.add_edge(row.HS_old, row.HS_new)

# self-loop 코드 중 다른 간선에 등장하는 것도 포함 (이미 G에 있음)
# self-loop만 있고 다른 간선이 없는 코드는 isolated node → G에 미포함 → family 불필요

components = list(nx.connected_components(G))
print(f"총 노드 (고유 HSK): {G.number_of_nodes()}")
print(f"총 간선 (매핑): {G.number_of_edges()}")
print(f"총 Family 수: {len(components)}")

# Family 크기 분포
sizes = [len(c) for c in components]
dist = Counter(sizes)
print(f"\nFamily 크기 분포:")
for k in sorted(dist.keys())[:15]:
    print(f"  {k}개 코드: {dist[k]}개 family")
if max(sizes) > 15:
    print(f"  ... (중략)")
    print(f"  최대: {max(sizes)}개 코드")

# HSK → edge_id 매핑 (Stata의 edge_id = _n 에 대응, 1-based)
hsk_edge_ids = {}
for idx, row in t12_edges.iterrows():
    eid = idx + 1  # 1-based, Stata의 gen long edge_id = _n 과 동일
    for code in [row.HS_old, row.HS_new]:
        if code not in hsk_edge_ids:
            hsk_edge_ids[code] = []
        hsk_edge_ids[code].append(eid)

# HSK → syntheticID 매핑 생성
# ★ Stata와 동일한 순서: 각 component의 최소 edge_id 기준 정렬
#    Stata min-propagation 수렴 시 family_id = min(edge_id in component)이므로,
#    sort family_id → gen syntheticID = _n 과 동일한 결과를 보장
def min_edge_id(comp):
    return min(eid for code in comp for eid in hsk_edge_ids[code])

hsk_to_family = {}
for fam_id, comp in enumerate(sorted(components, key=min_edge_id), start=1):
    for code in comp:
        hsk_to_family[code] = fam_id

print(f"\nFamily에 속하는 고유 HSK: {len(hsk_to_family)}")
num_families = len(components)
print(f"Family syntheticID 범위: 1 ~ {num_families}")


# =============================================================================
# PHASE 2: HSlist 패널 구축 + syntheticID 부여
# =============================================================================
print(f"\n{'=' * 60}")
print("PHASE 2: 최종 패널 생성")
print("=" * 60)

# HSlist 로드 및 합치기
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
print(f"HSK × Year 패널: {len(panel)} 행")

# syntheticID 부여
# (1) family에 속하는 코드 → family syntheticID (1 ~ num_families)
panel["syntheticID"] = panel["HSK"].map(hsk_to_family)

# (2) family에 속하지 않는 코드 → 고유 syntheticID (num_families+1 ~ ...)
no_family = panel[panel.syntheticID.isna()]["HSK"].unique()
no_family_map = {hsk: i + num_families + 1 for i, hsk in enumerate(sorted(no_family))}
panel.loc[panel.syntheticID.isna(), "syntheticID"] = panel.loc[
    panel.syntheticID.isna(), "HSK"
].map(no_family_map)

panel["syntheticID"] = panel["syntheticID"].astype(int)

# 검증
assert panel.syntheticID.notna().all(), "ERROR: syntheticID에 missing 존재!"
print(f"\n최종 패널:")
print(f"  총 행: {len(panel)}")
print(f"  syntheticID 범위: {panel.syntheticID.min()} ~ {panel.syntheticID.max()}")
print(f"  고유 syntheticID: {panel.syntheticID.nunique()}")

n_changed = panel[panel.syntheticID <= num_families].shape[0]
n_unchanged = panel[panel.syntheticID > num_families].shape[0]
print(f"  Family에 속하는 행 (변경된 코드): {n_changed}")
print(f"  고유 ID 행 (변경 없는 코드): {n_unchanged}")

# 연도별 요약
print(f"\n연도별 현황:")
summary = panel.groupby("year").agg(
    total=("HSK", "count"),
    in_family=("syntheticID", lambda x: (x <= num_families).sum()),
).reset_index()
summary["pct_changed"] = (summary.in_family / summary.total * 100).round(1)
print(summary.to_string(index=False))


# =============================================================================
# 결과 저장 (Stata 결과와 비교용)
# =============================================================================
print(f"\n{'=' * 60}")
print("결과 저장")
print("=" * 60)

# 패널 저장
panel[["HSK", "year", "syntheticID"]].to_stata(
    "hsk_concordance_2010_2026_py.dta", write_index=False, version=118
)
print("  hsk_concordance_2010_2026_py.dta 저장 완료")

# HSK → syntheticID 매핑표 (family 코드만)
family_df = pd.DataFrame(
    [(k, v) for k, v in hsk_to_family.items()],
    columns=["HSK", "syntheticID"],
)
family_df.sort_values("HSK", inplace=True)
family_df.to_stata("hsk_node_families_py.dta", write_index=False, version=118)
print("  hsk_node_families_py.dta 저장 완료")

# Family 상세 (edge 정보)
detail = t12_edges.copy()
detail["syntheticID"] = detail["HS_old"].map(hsk_to_family)
detail.sort_values(["syntheticID", "year_old", "HS_old", "HS_new"], inplace=True)
detail = detail[["syntheticID", "HS_old", "year_old", "HS_new", "year_new"]]
detail.to_stata("hsk_families_detail_py.dta", write_index=False, version=118)
print("  hsk_families_detail_py.dta 저장 완료")

# =============================================================================
# PHASE 2-C2: Audit용 전체 변경 이력 저장
# =============================================================================
print(f"\n{'=' * 60}")
print("PHASE 2-C2: Audit용 전체 변경 이력 (hsk_change_log_full)")
print("=" * 60)

# record_type 분류: nonself / selfloop / deleted
change_log = t12_clean.copy()
change_log["record_type"] = "nonself"
change_log.loc[change_log.HS_old == change_log.HS_new, "record_type"] = "selfloop"

# 삭제 코드 복원 (빈 HS_new였던 행)
if len(deleted) > 0:
    del_rows = deleted.copy()
    del_rows["HS_new"] = ""
    del_rows["record_type"] = "deleted"
    # deleted에는 HS_old가 HSK로 rename되어 있을 수 있으므로 원본 열 이름 사용
    if "HSK" in del_rows.columns:
        del_rows.rename(columns={"HSK": "HS_old"}, inplace=True)
    change_log = pd.concat([change_log, del_rows], ignore_index=True)

# syntheticID 부여 (HS_old 기준)
change_log["syntheticID"] = change_log["HS_old"].map(hsk_to_family)

# selfloop_only: self-loop만 있고 family에 속하지 않는 코드
change_log["selfloop_only"] = (
    (change_log["record_type"] == "selfloop") & change_log["syntheticID"].isna()
).astype(int)

# syntheticID: NaN은 Stata에서 missing(.)으로 저장됨 (float64 유지)
# pandas to_stata는 float64의 NaN을 Stata missing으로 자동 변환

# 정렬 및 열 순서
change_log = change_log[
    ["record_type", "syntheticID", "selfloop_only", "HS_old", "year_old", "HS_new", "year_new"]
]
change_log.sort_values(["record_type", "year_old", "HS_old", "HS_new"], inplace=True)

# 저장
change_log.to_stata("hsk_change_log_full_py.dta", write_index=False, version=118)
print(f"  hsk_change_log_full_py.dta 저장 완료")
print(f"  총 행: {len(change_log)}")
print(f"  record_type별:")
print(change_log["record_type"].value_counts().to_string())
print(f"  selfloop_only=1: {change_log['selfloop_only'].sum()}")


print(f"\n{'=' * 60}")
print("검증 완료!")
print("=" * 60)
print(f"\nStata 결과와 비교:")
print(f"  use hsk_concordance_2010_2026, clear")
print(f"  cf HSK year syntheticID using hsk_concordance_2010_2026_py")
print(f"  → 'variables are identical' 메시지가 나오면 검증 성공")
