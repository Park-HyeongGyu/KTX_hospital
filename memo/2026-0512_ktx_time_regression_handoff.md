# KTX Travel-Time Shock and Local Medical Supply: Regression Handoff

## 0. Purpose

이 handoff 파일은 KTX 접근성 개선으로 인해 서울 대형병원권까지의 travel time이 줄어들었을 때, 지역 의료공급이 어떻게 변하는지를 회귀식으로 분석하기 위한 작업 지시서이다.

핵심 연구 질문은 다음과 같다.

> Does improved KTX access to Seoul affect local medical supply?

여기서 local medical supply는 크게 두 종류로 나누어 본다.

1. 병원타입별 의료공급
   - 상급종합병원
   - 종합병원
   - 의원
   - 병원

2. 의사타입별 의료공급
   - 인턴
   - 레지던트
   - 전문의
   - 일반의

중요한 점은 다음과 같다.

> 각 회귀식마다 병원타입 4개 회귀와 의사타입 4개 회귀를 각각 따로 돌린다.

즉, 하나의 stacked panel에서 hospital-type fixed effect나 doctor-type fixed effect를 넣는 것이 아니다.  
각 column은 서로 다른 dependent variable을 사용한 separate regression이다.

---

## 1. Required Output Structure

각 regression specification마다 결과 테이블을 두 개 만든다.

### 1.1 Hospital-type outcome table

각 specification마다 다음 네 개의 separate regressions를 돌린 뒤 하나의 table로 묶는다.

| Column | Dependent variable |
|---:|---|
| (1) | 상급종합병원 |
| (2) | 종합병원 |
| (3) | 의원 |
| (4) | 병원 |

### 1.2 Doctor-type outcome table

각 specification마다 다음 네 개의 separate regressions를 돌린 뒤 하나의 table로 묶는다.

| Column | Dependent variable |
|---:|---|
| (1) | 인턴 |
| (2) | 레지던트 |
| (3) | 전문의 |
| (4) | 일반의 |

### 1.3 Fixed effects

각 column은 separate regression이므로 다음 fixed effects만 넣는다.

\[
\alpha_i + \tau_t
\]

- \(\alpha_i\): region fixed effects
- \(\tau_t\): year fixed effects

Do **not** include hospital-type fixed effects.  
Do **not** include doctor-type fixed effects.

이유: 병원타입과 의사타입은 이미 dependent variable column별로 분리되어 있기 때문이다.

---

## 2. Unit of Observation

기본 unit은 region-year panel이다.

\[
(i,t)
\]

- \(i\): region, preferably `region = region_sido + "_" + region_sigungu`
- \(t\): year or quarter

Recommended main frequency:

- Use annual panel if KTX treatment and outcomes are mostly annual.
- Use quarterly panel only if travel-time variables and outcome data are consistently available at quarterly frequency.

---

## 3. Outcome Variables

## 3.1 Hospital-type outcomes

For each hospital type \(m\), define:

\[
y^{H,m}_{it} = \log(hospital\_no^{m}_{it}+1)
\]

where \(m\) is one of:

| Korean label | Suggested variable name |
|---|---|
| 상급종합병원 | `tertiary_hospital_no` |
| 종합병원 | `general_hospital_no` |
| 의원 | `clinic_no` |
| 병원 | `secondary_hospital_no` |

Main hospital-type outcome regressions:

\[
y^{H,tertiary}_{it} = \log(tertiary\_hospital\_no_{it}+1)
\]

\[
y^{H,general}_{it} = \log(general\_hospital\_no_{it}+1)
\]

\[
y^{H,clinic}_{it} = \log(clinic\_no_{it}+1)
\]

\[
y^{H,secondary}_{it} = \log(secondary\_hospital\_no_{it}+1)
\]

Alternative outcomes, if needed:

\[
hospital\_no^{m}_{it}
\]

\[
hospital\_no\_per10k^{m}_{it}
=
\frac{hospital\_no^{m}_{it}}{population_{it}} \times 10000
\]

---

## 3.2 Doctor-type outcomes

For each doctor type \(d\), define:

\[
y^{D,d}_{it} = \log(doctor\_no^{d}_{it}+1)
\]

where \(d\) is one of:

| Korean label | Suggested variable name |
|---|---|
| 인턴 | `intern_no` |
| 레지던트 | `resident_no` |
| 전문의 | `specialist_no` |
| 일반의 | `gp_no` |

Main doctor-type outcome regressions:

\[
y^{D,intern}_{it} = \log(intern\_no_{it}+1)
\]

\[
y^{D,resident}_{it} = \log(resident\_no_{it}+1)
\]

\[
y^{D,specialist}_{it} = \log(specialist\_no_{it}+1)
\]

\[
y^{D,gp}_{it} = \log(gp\_no_{it}+1)
\]

Alternative outcomes, if needed:

\[
doctor\_no^{d}_{it}
\]

\[
doctor\_no\_per10k^{d}_{it}
=
\frac{doctor\_no^{d}_{it}}{population_{it}} \times 10000
\]

---

## 4. Critical Sample Caveat

## 4.1 Hospital-type regressions

For hospital-type regressions, exclude regions where the dependent variable is always zero across all years.

This restriction must be applied separately for each hospital-type outcome.

For hospital type \(m\), keep region \(i\) only if:

\[
\sum_t hospital\_no^{m}_{it} > 0
\]

Example:

If `general_hospital_no` is 0 for `경남_합천군` in every year, then exclude `경남_합천군` from the `종합병원` column regression.

However, this does not imply that `경남_합천군` should be excluded from the `의원` or `병원` regressions.  
Each column has its own sample restriction.

The hospital-type regression samples may therefore differ across columns.

---

## 4.2 Doctor-type regressions

For doctor-type regressions, use the full valid region-year sample by default.

However, if a doctor-type dependent variable is always zero for a region across all years, record this in the regression log.

Do not automatically drop such regions unless:

1. the model fails to estimate, or
2. the outcome has no meaningful identifying variation.

---

## 5. Travel-Time Construction

Let \(Tr_{it}\) denote the minimum travel time from region \(i\) to the Seoul medical destination in year \(t\).

Conceptually:

\[
Tr_{it}
=
\min\{Tr^{car}_{it}, Tr^{KTX}_{it}\}
\]

where

\[
Tr^{KTX}_{it}
=
\min_{h \in H_i}
\left\{
Tr^{car}_{i,h,t}
+
WaitPenalty_{h,t}
+
Tr^{KTX}_{h,Seoul,t}
\right\}
\]

Definitions:

- \(H_i\): candidate KTX stations available to region \(i\)
- \(Tr^{car}_{i,h,t}\): car travel time from region centroid to KTX station \(h\)
- \(WaitPenalty_{h,t}\): wait penalty, baseline 30 minutes unless better interval data are available
- \(Tr^{KTX}_{h,Seoul,t}\): KTX travel time from station \(h\) to Seoul Station or Yongsan Station
- \(Tr^{car}_{it}\): car travel time from region centroid to Seoul medical destination

Use hours as the unit if possible.

---

## 6. Treatment Variables

## 6.1 Baseline travel time

Define baseline pre-KTX travel time as:

\[
Tr_{i,pre}
\]

Preferred construction:

- Use the last pre-treatment travel time for each region.
- If region-specific pre-treatment timing is ambiguous, use a common baseline year before major KTX accessibility improvements.
- Save the chosen baseline rule explicitly in the code log.

---

## 6.2 Continuous travel-time saving

\[
Saving_{it}
=
Tr_{i,pre}
-
Tr_{it}
\]

Interpretation:

- Larger \(Saving_{it}\) means better access to Seoul.
- If \(Saving_{it}=1\), travel time to Seoul decreased by one hour relative to baseline.

---

## 6.3 Annual travel-time shock

\[
ShockSaving_{it}
=
Tr_{i,t-1}
-
Tr_{it}
\]

Interpretation:

- This captures the year-to-year reduction in travel time.
- Use this mainly for local projection regressions.

---

## 6.4 Threshold access indicator

For cutoff \(c\), define:

\[
WithinC_{it}
=
\mathbf{1}\{Tr_{it} \leq c\}
\]

Main cutoff:

\[
Within2h_{it}
=
\mathbf{1}\{Tr_{it} \leq 2\}
\]

Robustness cutoffs:

\[
c \in \{1.5,\ 2,\ 2.5,\ 3\}
\]

---

## 6.5 Threshold crossing shock

For cutoff \(c\), define:

\[
CrossC_{it}
=
\mathbf{1}\{Tr_{i,t-1} > c,\ Tr_{it} \leq c\}
\]

Main version:

\[
Cross2h_{it}
=
\mathbf{1}\{Tr_{i,t-1} > 2,\ Tr_{it} \leq 2\}
\]

Interpretation:

- This equals 1 only in the year when a region crosses into the two-hour access zone.

---

## 6.6 KTX chosen as fastest route

\[
KTXChosen_{it}
=
\mathbf{1}\{Tr^{KTX}_{it}<Tr^{car}_{it}\}
\]

Interpretation:

- This equals 1 when the KTX route is faster than driving all the way to Seoul.

---

## 6.7 KTX within two-hour access zone

\[
KTXWithin2h_{it}
=
\mathbf{1}\{Tr^{KTX}_{it}\leq 2,\ Tr^{KTX}_{it}<Tr^{car}_{it}\}
\]

Interpretation:

- This equals 1 when KTX is the fastest route and puts the region within 2 hours of Seoul.

This is the preferred KTX-specific threshold treatment variable.

---

## 6.8 Saving toward two-hour threshold

\[
SavingTo2h_{it}
=
\max(0,Tr_{i,pre}-2)
-
\max(0,Tr_{it}-2)
\]

Interpretation:

- This captures how much the region moved toward the two-hour access threshold.
- Travel-time improvements below the two-hour threshold are not additionally counted.

---

## 7. Control Variables

Preferred lagged controls:

\[
X_{i,t-1}
=
\{
\log(population_{i,t-1}),
old\_rate_{i,t-1},
\log(grdp_{i,t-1}),
employment\_rate_{i,t-1},
unemployment\_rate_{i,t-1}
\}
\]

Use lagged controls by default to reduce bad-control concerns.

Do not include contemporaneous population or GRDP in the main specification unless explicitly justified, because KTX itself may affect population and local economic activity.

If some controls are unavailable for early years, run:

1. baseline no-control version, and
2. control-included version on the restricted sample.

Record sample changes.

---

## 8. General Regression Template

For any hospital-type outcome \(m\):

\[
y^{H,m}_{it}
=
\alpha_i
+
\tau_t
+
Treatment_{it}'\theta
+
X_{i,t-1}'\Gamma
+
\epsilon^{H,m}_{it}
\]

For any doctor-type outcome \(d\):

\[
y^{D,d}_{it}
=
\alpha_i
+
\tau_t
+
Treatment_{it}'\theta
+
X_{i,t-1}'\Gamma
+
\epsilon^{D,d}_{it}
\]

Important:

- Run each \(m\) separately.
- Run each \(d\) separately.
- Do not include hospital-type fixed effects.
- Do not include doctor-type fixed effects.
- Cluster standard errors at the region level.

---

# 9. Regression Specifications

For every specification below:

1. Run four hospital-type regressions.
2. Run four doctor-type regressions.
3. Save one hospital-type TeX table.
4. Save one doctor-type TeX table.
5. Each column in each table is a separate regression.

---

## Regression 1. Continuous Saving Model

### Equation

For hospital-type outcome \(m\):

\[
y^{H,m}_{it}
=
\alpha_i
+
\tau_t
+
\beta Saving_{it}
+
X_{i,t-1}'\Gamma
+
\epsilon^{H,m}_{it}
\]

For doctor-type outcome \(d\):

\[
y^{D,d}_{it}
=
\alpha_i
+
\tau_t
+
\beta Saving_{it}
+
X_{i,t-1}'\Gamma
+
\epsilon^{D,d}_{it}
\]

### Interpretation

\(\beta\) captures the effect of a one-hour reduction in travel time to Seoul on local medical supply.

### Table 1H. Continuous Saving Model: Hospital-Type Outcomes

|  | 상급종합병원 | 종합병원 | 의원 | 병원 |
|---|---:|---:|---:|---:|
| \(Saving_{it}\) |  |  |  |  |
| Controls | Yes | Yes | Yes | Yes |
| Region FE | Yes | Yes | Yes | Yes |
| Year FE | Yes | Yes | Yes | Yes |
| Observations |  |  |  |  |
| Regions |  |  |  |  |
| Adjusted \(R^2\) |  |  |  |  |

Output file:

```text
tables/reg01_continuous_saving_hospital.tex
```

### Table 1D. Continuous Saving Model: Doctor-Type Outcomes

|  | 인턴 | 레지던트 | 전문의 | 일반의 |
|---|---:|---:|---:|---:|
| \(Saving_{it}\) |  |  |  |  |
| Controls | Yes | Yes | Yes | Yes |
| Region FE | Yes | Yes | Yes | Yes |
| Year FE | Yes | Yes | Yes | Yes |
| Observations |  |  |  |  |
| Regions |  |  |  |  |
| Adjusted \(R^2\) |  |  |  |  |

Output file:

```text
tables/reg01_continuous_saving_doctor.tex
```

---

## Regression 2. Two-Hour Access Model

### Equation

For hospital-type outcome \(m\):

\[
y^{H,m}_{it}
=
\alpha_i
+
\tau_t
+
\delta Within2h_{it}
+
X_{i,t-1}'\Gamma
+
\epsilon^{H,m}_{it}
\]

For doctor-type outcome \(d\):

\[
y^{D,d}_{it}
=
\alpha_i
+
\tau_t
+
\delta Within2h_{it}
+
X_{i,t-1}'\Gamma
+
\epsilon^{D,d}_{it}
\]

### Interpretation

\(\delta\) captures the discrete effect of being within two hours of Seoul.

### Table 2H. Two-Hour Access Model: Hospital-Type Outcomes

|  | 상급종합병원 | 종합병원 | 의원 | 병원 |
|---|---:|---:|---:|---:|
| \(Within2h_{it}\) |  |  |  |  |
| Controls | Yes | Yes | Yes | Yes |
| Region FE | Yes | Yes | Yes | Yes |
| Year FE | Yes | Yes | Yes | Yes |
| Observations |  |  |  |  |
| Regions |  |  |  |  |
| Adjusted \(R^2\) |  |  |  |  |

Output file:

```text
tables/reg02_within2h_hospital.tex
```

### Table 2D. Two-Hour Access Model: Doctor-Type Outcomes

|  | 인턴 | 레지던트 | 전문의 | 일반의 |
|---|---:|---:|---:|---:|
| \(Within2h_{it}\) |  |  |  |  |
| Controls | Yes | Yes | Yes | Yes |
| Region FE | Yes | Yes | Yes | Yes |
| Year FE | Yes | Yes | Yes | Yes |
| Observations |  |  |  |  |
| Regions |  |  |  |  |
| Adjusted \(R^2\) |  |  |  |  |

Output file:

```text
tables/reg02_within2h_doctor.tex
```

---

## Regression 3. Hybrid Saving + Two-Hour Access Model

### Equation

For hospital-type outcome \(m\):

\[
y^{H,m}_{it}
=
\alpha_i
+
\tau_t
+
\beta Saving_{it}
+
\delta Within2h_{it}
+
X_{i,t-1}'\Gamma
+
\epsilon^{H,m}_{it}
\]

For doctor-type outcome \(d\):

\[
y^{D,d}_{it}
=
\alpha_i
+
\tau_t
+
\beta Saving_{it}
+
\delta Within2h_{it}
+
X_{i,t-1}'\Gamma
+
\epsilon^{D,d}_{it}
\]

### Interpretation

\(\beta\) captures the continuous travel-time saving effect.

\(\delta\) captures the additional discrete effect of being within the two-hour access zone.

This is one of the preferred main specifications.

### Table 3H. Hybrid Saving + Two-Hour Access Model: Hospital-Type Outcomes

|  | 상급종합병원 | 종합병원 | 의원 | 병원 |
|---|---:|---:|---:|---:|
| \(Saving_{it}\) |  |  |  |  |
| \(Within2h_{it}\) |  |  |  |  |
| Controls | Yes | Yes | Yes | Yes |
| Region FE | Yes | Yes | Yes | Yes |
| Year FE | Yes | Yes | Yes | Yes |
| Observations |  |  |  |  |
| Regions |  |  |  |  |
| Adjusted \(R^2\) |  |  |  |  |

Output file:

```text
tables/reg03_hybrid_saving_within2h_hospital.tex
```

### Table 3D. Hybrid Saving + Two-Hour Access Model: Doctor-Type Outcomes

|  | 인턴 | 레지던트 | 전문의 | 일반의 |
|---|---:|---:|---:|---:|
| \(Saving_{it}\) |  |  |  |  |
| \(Within2h_{it}\) |  |  |  |  |
| Controls | Yes | Yes | Yes | Yes |
| Region FE | Yes | Yes | Yes | Yes |
| Year FE | Yes | Yes | Yes | Yes |
| Observations |  |  |  |  |
| Regions |  |  |  |  |
| Adjusted \(R^2\) |  |  |  |  |

Output file:

```text
tables/reg03_hybrid_saving_within2h_doctor.tex
```

---

## Regression 4. KTX Two-Hour Access Model

### Equation

For hospital-type outcome \(m\):

\[
y^{H,m}_{it}
=
\alpha_i
+
\tau_t
+
\delta KTXWithin2h_{it}
+
X_{i,t-1}'\Gamma
+
\epsilon^{H,m}_{it}
\]

For doctor-type outcome \(d\):

\[
y^{D,d}_{it}
=
\alpha_i
+
\tau_t
+
\delta KTXWithin2h_{it}
+
X_{i,t-1}'\Gamma
+
\epsilon^{D,d}_{it}
\]

### Interpretation

\(\delta\) captures the effect of being able to reach Seoul within two hours using KTX as the fastest route.

### Table 4H. KTX Two-Hour Access Model: Hospital-Type Outcomes

|  | 상급종합병원 | 종합병원 | 의원 | 병원 |
|---|---:|---:|---:|---:|
| \(KTXWithin2h_{it}\) |  |  |  |  |
| Controls | Yes | Yes | Yes | Yes |
| Region FE | Yes | Yes | Yes | Yes |
| Year FE | Yes | Yes | Yes | Yes |
| Observations |  |  |  |  |
| Regions |  |  |  |  |
| Adjusted \(R^2\) |  |  |  |  |

Output file:

```text
tables/reg04_ktx_within2h_hospital.tex
```

### Table 4D. KTX Two-Hour Access Model: Doctor-Type Outcomes

|  | 인턴 | 레지던트 | 전문의 | 일반의 |
|---|---:|---:|---:|---:|
| \(KTXWithin2h_{it}\) |  |  |  |  |
| Controls | Yes | Yes | Yes | Yes |
| Region FE | Yes | Yes | Yes | Yes |
| Year FE | Yes | Yes | Yes | Yes |
| Observations |  |  |  |  |
| Regions |  |  |  |  |
| Adjusted \(R^2\) |  |  |  |  |

Output file:

```text
tables/reg04_ktx_within2h_doctor.tex
```

---

## Regression 5. Hybrid Saving + KTX Two-Hour Access Model

### Equation

For hospital-type outcome \(m\):

\[
y^{H,m}_{it}
=
\alpha_i
+
\tau_t
+
\beta Saving_{it}
+
\delta KTXWithin2h_{it}
+
X_{i,t-1}'\Gamma
+
\epsilon^{H,m}_{it}
\]

For doctor-type outcome \(d\):

\[
y^{D,d}_{it}
=
\alpha_i
+
\tau_t
+
\beta Saving_{it}
+
\delta KTXWithin2h_{it}
+
X_{i,t-1}'\Gamma
+
\epsilon^{D,d}_{it}
\]

### Interpretation

\(\beta\) captures general travel-time saving effects.

\(\delta\) captures the additional effect of entering the two-hour Seoul access zone specifically through KTX.

This is the preferred KTX-specific main specification.

### Table 5H. Hybrid Saving + KTX Two-Hour Access Model: Hospital-Type Outcomes

|  | 상급종합병원 | 종합병원 | 의원 | 병원 |
|---|---:|---:|---:|---:|
| \(Saving_{it}\) |  |  |  |  |
| \(KTXWithin2h_{it}\) |  |  |  |  |
| Controls | Yes | Yes | Yes | Yes |
| Region FE | Yes | Yes | Yes | Yes |
| Year FE | Yes | Yes | Yes | Yes |
| Observations |  |  |  |  |
| Regions |  |  |  |  |
| Adjusted \(R^2\) |  |  |  |  |

Output file:

```text
tables/reg05_hybrid_saving_ktx_within2h_hospital.tex
```

### Table 5D. Hybrid Saving + KTX Two-Hour Access Model: Doctor-Type Outcomes

|  | 인턴 | 레지던트 | 전문의 | 일반의 |
|---|---:|---:|---:|---:|
| \(Saving_{it}\) |  |  |  |  |
| \(KTXWithin2h_{it}\) |  |  |  |  |
| Controls | Yes | Yes | Yes | Yes |
| Region FE | Yes | Yes | Yes | Yes |
| Year FE | Yes | Yes | Yes | Yes |
| Observations |  |  |  |  |
| Regions |  |  |  |  |
| Adjusted \(R^2\) |  |  |  |  |

Output file:

```text
tables/reg05_hybrid_saving_ktx_within2h_doctor.tex
```

---

## Regression 6. Saving Toward Two-Hour Threshold Model

### Equation

For hospital-type outcome \(m\):

\[
y^{H,m}_{it}
=
\alpha_i
+
\tau_t
+
\beta SavingTo2h_{it}
+
X_{i,t-1}'\Gamma
+
\epsilon^{H,m}_{it}
\]

For doctor-type outcome \(d\):

\[
y^{D,d}_{it}
=
\alpha_i
+
\tau_t
+
\beta SavingTo2h_{it}
+
X_{i,t-1}'\Gamma
+
\epsilon^{D,d}_{it}
\]

### Interpretation

\(\beta\) captures how local medical supply changes as regions move toward the two-hour access threshold.

### Table 6H. Saving Toward Two-Hour Threshold Model: Hospital-Type Outcomes

|  | 상급종합병원 | 종합병원 | 의원 | 병원 |
|---|---:|---:|---:|---:|
| \(SavingTo2h_{it}\) |  |  |  |  |
| Controls | Yes | Yes | Yes | Yes |
| Region FE | Yes | Yes | Yes | Yes |
| Year FE | Yes | Yes | Yes | Yes |
| Observations |  |  |  |  |
| Regions |  |  |  |  |
| Adjusted \(R^2\) |  |  |  |  |

Output file:

```text
tables/reg06_saving_to_2h_hospital.tex
```

### Table 6D. Saving Toward Two-Hour Threshold Model: Doctor-Type Outcomes

|  | 인턴 | 레지던트 | 전문의 | 일반의 |
|---|---:|---:|---:|---:|
| \(SavingTo2h_{it}\) |  |  |  |  |
| Controls | Yes | Yes | Yes | Yes |
| Region FE | Yes | Yes | Yes | Yes |
| Year FE | Yes | Yes | Yes | Yes |
| Observations |  |  |  |  |
| Regions |  |  |  |  |
| Adjusted \(R^2\) |  |  |  |  |

Output file:

```text
tables/reg06_saving_to_2h_doctor.tex
```

---

## Regression 7. Threshold Robustness Model

### Equation

Run the threshold access model for each cutoff:

\[
c \in \{1.5,\ 2,\ 2.5,\ 3\}
\]

For hospital-type outcome \(m\):

\[
y^{H,m}_{it}
=
\alpha_i
+
\tau_t
+
\delta_c WithinC_{it}
+
X_{i,t-1}'\Gamma
+
\epsilon^{H,m}_{it}
\]

For doctor-type outcome \(d\):

\[
y^{D,d}_{it}
=
\alpha_i
+
\tau_t
+
\delta_c WithinC_{it}
+
X_{i,t-1}'\Gamma
+
\epsilon^{D,d}_{it}
\]

### Interpretation

This checks whether the results are specific to the two-hour cutoff or robust across alternative travel-time thresholds.

### Required output files

For each cutoff \(c\), save two tables.

Example output files:

```text
tables/reg07_threshold_1p5h_hospital.tex
tables/reg07_threshold_1p5h_doctor.tex
tables/reg07_threshold_2h_hospital.tex
tables/reg07_threshold_2h_doctor.tex
tables/reg07_threshold_2p5h_hospital.tex
tables/reg07_threshold_2p5h_doctor.tex
tables/reg07_threshold_3h_hospital.tex
tables/reg07_threshold_3h_doctor.tex
```

Each hospital table must have four columns:

|  | 상급종합병원 | 종합병원 | 의원 | 병원 |
|---|---:|---:|---:|---:|

Each doctor table must have four columns:

|  | 인턴 | 레지던트 | 전문의 | 일반의 |
|---|---:|---:|---:|---:|

---

## Regression 8. Local Projection with Continuous Shock

### Equation

Use annual travel-time shock:

\[
ShockSaving_{it}=Tr_{i,t-1}-Tr_{it}
\]

For horizon:

\[
h \in \{0,1,2,3,4,5\}
\]

For hospital-type outcome \(m\):

\[
y^{H,m}_{i,t+h}
-
y^{H,m}_{i,t-1}
=
\alpha_i^h
+
\tau_t^h
+
\beta_h ShockSaving_{it}
+
X_{i,t-1}'\Gamma_h
+
\epsilon^{H,m,h}_{i,t+h}
\]

For doctor-type outcome \(d\):

\[
y^{D,d}_{i,t+h}
-
y^{D,d}_{i,t-1}
=
\alpha_i^h
+
\tau_t^h
+
\beta_h ShockSaving_{it}
+
X_{i,t-1}'\Gamma_h
+
\epsilon^{D,d,h}_{i,t+h}
\]

### Interpretation

\(\beta_h\) captures the effect of a one-hour travel-time reduction shock at time \(t\) on the \(h\)-period cumulative change in medical supply.

### Required output

For each horizon \(h\), produce two tables:

```text
tables/reg08_lp_shocksaving_h{h}_hospital.tex
tables/reg08_lp_shocksaving_h{h}_doctor.tex
```

Also produce coefficient plots over horizons:

```text
figures/reg08_lp_shocksaving_hospital.pdf
figures/reg08_lp_shocksaving_doctor.pdf
```

Hospital plot:

- four series: 상급종합병원, 종합병원, 의원, 병원

Doctor plot:

- four series: 인턴, 레지던트, 전문의, 일반의

---

## Regression 9. Local Projection with Two-Hour Crossing Shock

### Equation

Use:

\[
Cross2h_{it}
=
\mathbf{1}\{Tr_{i,t-1} > 2,\ Tr_{it} \leq 2\}
\]

For horizon:

\[
h \in \{0,1,2,3,4,5\}
\]

For hospital-type outcome \(m\):

\[
y^{H,m}_{i,t+h}
-
y^{H,m}_{i,t-1}
=
\alpha_i^h
+
\tau_t^h
+
\delta_h Cross2h_{it}
+
X_{i,t-1}'\Gamma_h
+
\epsilon^{H,m,h}_{i,t+h}
\]

For doctor-type outcome \(d\):

\[
y^{D,d}_{i,t+h}
-
y^{D,d}_{i,t-1}
=
\alpha_i^h
+
\tau_t^h
+
\delta_h Cross2h_{it}
+
X_{i,t-1}'\Gamma_h
+
\epsilon^{D,d,h}_{i,t+h}
\]

### Interpretation

\(\delta_h\) captures the effect of crossing into the two-hour Seoul access zone on the \(h\)-period cumulative change in medical supply.

### Required output

For each horizon \(h\), produce two tables:

```text
tables/reg09_lp_cross2h_h{h}_hospital.tex
tables/reg09_lp_cross2h_h{h}_doctor.tex
```

Also produce coefficient plots over horizons:

```text
figures/reg09_lp_cross2h_hospital.pdf
figures/reg09_lp_cross2h_doctor.pdf
```

---

## Regression 10. KTX Chosen Model

### Equation

For hospital-type outcome \(m\):

\[
y^{H,m}_{it}
=
\alpha_i
+
\tau_t
+
\delta KTXChosen_{it}
+
X_{i,t-1}'\Gamma
+
\epsilon^{H,m}_{it}
\]

For doctor-type outcome \(d\):

\[
y^{D,d}_{it}
=
\alpha_i
+
\tau_t
+
\delta KTXChosen_{it}
+
X_{i,t-1}'\Gamma
+
\epsilon^{D,d}_{it}
\]

### Interpretation

\(\delta\) captures the effect of KTX becoming the fastest route to Seoul, regardless of whether the region is within two hours.

### Table 10H. KTX Chosen Model: Hospital-Type Outcomes

|  | 상급종합병원 | 종합병원 | 의원 | 병원 |
|---|---:|---:|---:|---:|
| \(KTXChosen_{it}\) |  |  |  |  |
| Controls | Yes | Yes | Yes | Yes |
| Region FE | Yes | Yes | Yes | Yes |
| Year FE | Yes | Yes | Yes | Yes |
| Observations |  |  |  |  |
| Regions |  |  |  |  |
| Adjusted \(R^2\) |  |  |  |  |

Output file:

```text
tables/reg10_ktx_chosen_hospital.tex
```

### Table 10D. KTX Chosen Model: Doctor-Type Outcomes

|  | 인턴 | 레지던트 | 전문의 | 일반의 |
|---|---:|---:|---:|---:|
| \(KTXChosen_{it}\) |  |  |  |  |
| Controls | Yes | Yes | Yes | Yes |
| Region FE | Yes | Yes | Yes | Yes |
| Year FE | Yes | Yes | Yes | Yes |
| Observations |  |  |  |  |
| Regions |  |  |  |  |
| Adjusted \(R^2\) |  |  |  |  |

Output file:

```text
tables/reg10_ktx_chosen_doctor.tex
```

---

# 10. Table Requirements

All tables should be written in English.

Dependent variable column labels can be Korean.

Each table must include:

- coefficient estimates
- standard errors in parentheses
- significance stars
- controls indicator
- region fixed effects indicator
- year fixed effects indicator
- number of observations
- number of regions
- adjusted \(R^2\), if available

Preferred notes:

```text
Notes: Each column reports a separate region-year fixed-effects regression. 
Standard errors clustered at the region level are reported in parentheses. 
All specifications include region and year fixed effects. 
Controls include lagged log population, old-age share, lagged log GRDP, employment rate, and unemployment rate where available.
```

For hospital-type tables, add:

```text
Regions where the relevant hospital-type outcome is zero in all years are excluded separately for each column.
```

---

# 11. Standard Errors

Use cluster-robust standard errors at the region level:

\[
cluster = i
\]

If the number of regions is small for a specific hospital-type outcome, report this issue in the regression log.

---

# 12. Recommended R Implementation Logic

The implementation should follow this structure.

## 12.1 Define outcome lists

```r
hospital_outcomes <- list(
  "상급종합병원" = "tertiary_hospital_no",
  "종합병원" = "general_hospital_no",
  "의원" = "clinic_no",
  "병원" = "secondary_hospital_no"
)

doctor_outcomes <- list(
  "인턴" = "intern_no",
  "레지던트" = "resident_no",
  "전문의" = "specialist_no",
  "일반의" = "gp_no"
)
```

## 12.2 Create log outcomes

For each outcome:

```r
df <- df |>
  mutate(
    y = log(.data[[outcome_var]] + 1)
  )
```

## 12.3 Apply hospital zero-only-region exclusion

For hospital-type regressions:

```r
df_reg <- df |>
  group_by(region) |>
  filter(sum(.data[[outcome_var]], na.rm = TRUE) > 0) |>
  ungroup()
```

Apply this separately for each hospital-type outcome.

## 12.4 Regression formula template

```r
formula <- y ~ treatment_variables + controls | region + year
```

Using `fixest`:

```r
model <- feols(
  formula,
  data = df_reg,
  cluster = ~ region
)
```

## 12.5 Table export

Use `etable()` or another TeX table exporter.

Each table combines four separate model objects.

Example:

```r
etable(
  model_tertiary,
  model_general,
  model_clinic,
  model_secondary,
  tex = TRUE,
  file = "tables/reg01_continuous_saving_hospital.tex",
  headers = c("상급종합병원", "종합병원", "의원", "병원")
)
```

Doctor table:

```r
etable(
  model_intern,
  model_resident,
  model_specialist,
  model_gp,
  tex = TRUE,
  file = "tables/reg01_continuous_saving_doctor.tex",
  headers = c("인턴", "레지던트", "전문의", "일반의")
)
```

---

# 13. Main Interpretation Strategy

## 13.1 Continuous saving coefficients

If \(\beta < 0\):

> A reduction in travel time to Seoul is associated with a decline in local medical supply.

If \(\beta > 0\):

> A reduction in travel time to Seoul is associated with an increase in local medical supply, possibly through local economic activation or improved regional connectivity.

## 13.2 Threshold coefficients

If \(\delta < 0\) for \(Within2h_{it}\) or \(KTXWithin2h_{it}\):

> Entering the two-hour Seoul access zone is associated with weaker local medical supply.

If \(\delta > 0\):

> Entering the two-hour Seoul access zone is associated with stronger local medical supply.

## 13.3 Hybrid model

The hybrid model should be interpreted as follows.

\[
\beta
\]

captures the smooth continuous effect of travel-time reductions.

\[
\delta
\]

captures the discrete threshold effect of becoming sufficiently close to Seoul.

This is important because medical-care behavior may respond nonlinearly to travel time.  
For example, moving from 2.5 hours to 1.8 hours may matter more than moving from 5 hours to 4.3 hours, even though the latter has a larger absolute saving.

---

# 14. Recommended Main Tables for Report

For the main report, prioritize:

1. Regression 1: Continuous Saving Model
2. Regression 3: Hybrid Saving + Two-Hour Access Model
3. Regression 5: Hybrid Saving + KTX Two-Hour Access Model
4. Regression 8 or 9: Local Projection plots

Use other regressions as robustness checks.

---

# 15. Required Regression Log

Create a regression log file:

```text
logs/regression_sample_log.md
```

The log must include:

1. sample period
2. frequency: annual or quarterly
3. number of regions before sample restrictions
4. number of regions after sample restrictions for each hospital-type outcome
5. number of observations for each regression
6. control variables used
7. treatment variable construction rule
8. baseline travel-time year or rule
9. list of dropped regions for each hospital-type outcome due to always-zero outcome
10. any model failures or collinearity drops

For hospital-type sample restrictions, write a section like this:

```markdown
## Hospital-type always-zero region exclusions

### 상급종합병원
Dropped regions:
- ...

### 종합병원
Dropped regions:
- ...

### 의원
Dropped regions:
- ...

### 병원
Dropped regions:
- ...
```

---

# 16. Final Checklist

Before finishing, verify the following.

- [ ] Each specification has two output tables: hospital and doctor.
- [ ] Each hospital table has four columns: 상급종합병원, 종합병원, 의원, 병원.
- [ ] Each doctor table has four columns: 인턴, 레지던트, 전문의, 일반의.
- [ ] Each column is a separate regression.
- [ ] No hospital-type fixed effects are included.
- [ ] No doctor-type fixed effects are included.
- [ ] Region fixed effects are included.
- [ ] Year fixed effects are included.
- [ ] Standard errors are clustered at the region level.
- [ ] Hospital-type always-zero regions are dropped separately by column.
- [ ] All tables are exported as `.tex`.
- [ ] Regression sample log is created.
- [ ] LP coefficient plots are created for dynamic specifications.
