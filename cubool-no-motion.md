---
width: 1400
height: 900
theme: my-talk
highlightTheme: monokai
---

![height:50px right](cubrid-logo-big-transparent.png)
## 큐브리드 대용량 컬럼 저장 구조 개선

>큐브리드 **Out-of-Line Column Storage (TOAST)** 도입 논의

개발2팀 김대현

---

## 🎯 미팅 목적

- 현재 CUBRID 저장 구조의 **대용량 컬럼 처리 한계** 공유  
- 주요 DBMS(PostgreSQL, MySQL, Oracle) 사례 비교 및 제약사항 이해  
- 성능 실험 결과 기반으로 TOAST/Off-Page 장단점 검토  
- CUBRID에 필요한 **개선 방향성 및 요구사항 수집**  

---

## 📌 발표 순서

- 용어 정의
- 큐브리드 대용량 컬럼 저장의 문제점
- 타 DBMS 사례 조사 결과 공유
    - **PostgreSQL TOAST**
    - **MySQL InnoDB off-page**
    - **Oracle**
- pg toast 성능 실험 결과 공유
- 요구사항 수집

---

## 용어 정의 및 설명

**TOAST: The Over-sized Attribute Storage Technique**

- 레코드(튜플)을 연속적으로 저장하지 않고, 큰 속성 (Attribute)를 튜플로부터 떨어진 다른 **보조 저장소에 저장**하고, 기존 레코드에는 데이터에 대한 **포인터**를 남겨 **튜플 크기를 줄이는** 기법
- 해당 **보조 저장소**는 여전히 DBMS에 의해 관리됨.
- 주의: **외부 저장소**라고 표현할 경우, BFILE, BLOB External 등과 같이 OS File Storage 와 혼동할 수 있음.

---

## 비슷한 용어들

- Out of Line 저장 (PostgreSQL, Oracle)
- Toast 저장 (PostgreSQL), sent to Toast table
- Off-page 저장 (InnoDB)


본 발표에서는 **Out of Line 저장 기법**이라는 용어로 통일하겠습니다.

---
	
## ⚠️ 현재 문제점

```sql
create table tbl (id int, txt varchar); -- 매우 큰 varchar

-- insert 1000000 rows...

select id from tbl;
```

- 큐브리드 현재 동작 방식
    - `id` 컬럼만 조회해도 **txt까지 모두 디스크에서 fetch**

- 결과
    - 불필요한 I/O 발생 → **성능 저하**
    - 큰 VARCHAR / LOB / Vector 컬럼이 많을수록 **악영향**

---

## 🎯 큐브리드 개선 필요성

- 대규모 **VARCHAR / BLOB / CLOB / Vector** 등 큰 컬럼 데이터가 존재하는 경우,
    - 컬럼 데이터를 제외하고 조회할 경우 **Full table scan 성능 개선 필요**
	    - **Out of Line Column Storage** 미지원
    - 여전히 Recovery와 Replication, HA를 지원해야 함

---

## 🏗️ 타 DBMS 사례

- **PostgreSQL**: TOAST (The Oversized-Attribute Storage Technique)
- **MySQL (InnoDB)**: Off-Page Storage (Singly-Linked Overflow Pages)
- **Oracle**: LOB (SecureFiles), In-row chaining

---

## PostgreSQL: TOAST 

- 레코드 크기가 대략 2KB를 넘을 시, 컬럼들을 큰 순서대로 **TOAST 테이블**로 분리
- 모든 테이블은 **단 하나**의 숨겨진 TOAST 테이블을 소유하고 있음.
- 분할하여 하나의 TOAST 테이블에 저장
- 분할 데이터는 (chunk_id, chunk_seq) 부여. 유니크 인덱스가 걸려 있음.

---

## TOAST 과정

1. Record 크기가 Threshold (~2kB) 이상일 경우,
2. 압축을 시도
3. 큰 속성부터 차례대로
	1. Toast **가능 여부** 검사 (**PLAIN**으로 회피 가능)
	2. Toast Table에 해당 컬럼 값을 따로 삽입
4. **2, 3** 과정 후에도 만약 8kB 이상일 경우 **에러 처리**

---

## 📍TOAST 레코드 단위 동작 

```sql
CREATE TABLE tbl (a VARCHAR, b VARCHAR);
```

- **레코드 단위**로 TOAST 여부가 결정됨
- a, b 두 개의 큰 varchar 컬럼이 있을 경우:
	- 어떤 행은 **a만 TOAST**, 어떤 행은 **b만 TOAST**
	- 두 컬럼 모두 TOAST **될 수도** 있고, 둘 다 **안 될 수도** 있음
- 즉, TOAST 적용 여부는 "**컬럼별 + 행별로 달라질 수 있음**"

---

### PostgreSQL Toast 제어

- 특정 컬럼만을 항상 Toast로 보내기 불가능 ❌
- 특정 컬럼만을 항상 Toast 금지 가능 ✅ 
	- 단, 8kB 에러 주의  ⛔️
- 임의로 TOAST 촉발(trigger)시키는 것은 불가능하다 (Threshold 2kB) ❌
- TOAST 촉발되었을 경우, 나누는 크기 조절 가능 ✅
- TOAST 이후 남은 튜플 크기 조절 가능 ✅
- 압축 알고리즘 컬럼 단위로 설정 가능 ✅

---

## MySQL (InnoDB)

- 레코드 크기가 Page Size (기본 16K) 절반을 넘을 경우, 컬럼들을 순서대로 **Off-Page** 저장소 (Singly Linked Overflow Pages)로 분리 저장
- 모든 컬럼은 각자 하나씩 **Off-Page** 저장소를 가지고 있음.

---

## MySQL Off-Page 과정

- 테이블⚠️ 별로 설정하는 Row Format 으로 제어
	- Pg와 달리 컬럼별 설정 불가능 ❌
- Row Format 종류:
	- Redundant, Compact
	- Dynamic, Compressed

---

## MySQL Row Format

- Dynamic Row Format (Default), Compressed
	- **큰 속성부터 차례로** Off-Page Storage로 이주
	- 20바이트 포인터만 레코드에 남음
	- **각 행은** 각각 Off-Page Storage를 가지고 있으며, **Singly Linked Overflow Pages**로 구현되어 있음
	- **50바이트 이하는** Off-Page로 가지 않음 ✅
- Redundant, Compact ⚠️
	- 768바이트는 Record에 남겨두고, 나머지 (size - 768) byte는 Off-Page Storage로 보냄

---

## MySQL 유저 레벨 제어

- 컬럼 기반 제어 불가능
	- 특정 컬럼만을 Off Page 하지 않기 불가능 ❌
	- 특정 컬럼만을 Off Page 하기 불가능  ❌
- Off-Page 임계치(threshold)는 page_size/2  
	- Page Size를 바꿔야만 기준 변경 가능 ⚠️  
	- REDUNDANT, COMPACT 에서는 항상 768B In-row 고정 ⚠️
- Off Page 이후 남은 튜플 크기 조절 불가능 ❌
- 압축 알고리즘은 테이블 단위 설정 ⚠️

---

## Oracle

- BLOB, CLOB, BFILE, CFILE  타입만 지원
	- 개발자가 타입을 명시해야 함 ⚠️
	- 행의 나머지 타입들은 항상 연속적으로 저장
- 한 행 크기가 블록 (페이지) 크기를 넘어갈 경우⚠️
	- Row Chaining: 여러 블록에 나누어 저장 후 체인 포인터로 연결
- 큰 데이터에 대해서는 사용자가 직접 LOB(SECUREFILE) 컬럼 지정 및 사용 권장 ⚠️

---

## 행 크기를 줄이고 싶다면...

- postgresql, mysql: 자동으로 Out of Line 💯
- Oracle : 개발자가 직접 LOB 타입을 사용해야 함 ⚠️

---

## 🔒 벤더별 제약사항 비교

|DBMS|컬럼 단위 제어|Threshold 제어|분할 저장(청크)|LOB 타입 필요 여부|특이사항|
|----|--------------|--------------|----------------|-----------------|---------|
|**PostgreSQL (TOAST)**|가능 (STORAGE 옵션)|불가능 (2KB~ 자동)|있음 (chunk 단위)|불필요|행마다 다른 컬럼만 TOAST 될 수 있음|
|**MySQL (InnoDB Off-Page)**|불가능|Page Size 변경 필요 (기본 16KB → 8KB 기준)|없음 (컬럼값 통째로)|불필요|행당 컬럼별 overflow chain|
|**Oracle**|불가능|불가능|없음 (Row Chaining만)|필요 (BLOB, CLOB, SecureFile)|일반 컬럼은 무조건 in-row 저장|

---

## 🧪 성능 실험 (Postgresql)

벤치마크 준비

```sql
CREATE TABLE IF NOT EXISTS s.t_plain
(
  id bigserial PRIMARY KEY,
  payload varchar STORAGE PLAIN -- TOAST 금지
);
CREATE TABLE IF NOT EXISTS s.t_ext
(
  id bigserial PRIMARY KEY,
  payload varchar STORAGE EXTERNAL -- TOAST
);
```

```sql
INSERT INTO s.t_plain  (payload) SELECT s.gen_rand_text(3000)   FROM generate_series(1,200000) ON CONFLICT DO NOTHING;
INSERT INTO s.t_ext    (payload) SELECT s.gen_rand_text(3000)   FROM generate_series(1,200000) ON CONFLICT DO NOTHING;
```

각각 3000-byte varchar 데이터 20만 행 삽입

---

## 📊 실험 시나리오

1. **Full Table Scan**    
    - TOAST 시
    - TOAST 아닐 시
    
2. **Primary Key (b-tree) random access**    
    - TOAST 시
    - TOAST 아닐 시

---

## 📈 성능 결과: Full Table Scan

- Query: `select id from tbl;`

|Case|실행 (ms)|Read (pages)|≈ Disk (MiB)|I/O시간 (ms)|Notes|
|---|--:|--:|--:|--:|---|
|`t_plain`|**1,549.3**|**100,000**|**~781**|**1,447.1**|Big heap; payload inline.|
|`t_ext`|**29.5**|**1,471**|**~11.5**|**9.7**|Tiny heap; payload out-of-line.|

**TOAST**가 압도적으로 빠름.

---

## 📈 성능 결과: PK random access

Query: `select id, payload from (... random temp table 1만) join tbl using (id);` 

|테이블|실행 (ms)|Read (pages)|≈ Disk(MiB)|Hit (pages)|I/O시간 (ms)|계획(요약)|
|---|--:|--:|--:|--:|--:|---|
|`s.t_plain`|**1,767.6**|**10,057**|**≈ 78.6**|28,918|1,660.8|Nested Loop + Index Scan|
|`s.t_ext`|**1,977.4**|**12,666**|**≈ 99.0**|66,424|1,824.3|Nested Loop + Index Scan (+ TOAST)|

인라인(PLAIN)이 TOAST보다 **~11.9%** 빠름

---

### 📈 성능으로 보는 Toast 장단점

- 콜드 캐시 랜덤 접근에서 `t_plain`(인라인) 가 `t_ext`(TOAST) 보다 ~11.9% 빠름 
	- **(1,767.6 ms vs 1,977.4 ms)**
- TOAST 테이블은 동일한 랜덤 샘플을 읽을 때 **추가 TOAST 페이지**를 더 읽어야 해서 디스크 읽기(page read)가 더 큼
	- (12,666 pages ≈ 99 MiB vs 10,057 pages ≈ 78.6 MiB).
---

### 📈 성능으로 보는 Toast 장단점

- 두 경우 모두 **I/O가 지배적**:
	- I/O read 시간이 각각 **~1.66s**(plain) vs **~1.82s**(ext).  
    즉, 랜덤 패턴 + 콜드 캐시에서는 TOAST 경로가 **디스크에서 더 많은 바이트**를 가져오게 되어 느려짐.

---

## ⚖️ TOAST 적용 vs 미적용 장단점

|구분|TOAST 적용 (Out-of-Line)|TOAST 미적용 (Inline)|
|----|------------------------|----------------------|
|**Full Table Scan**|힙 크기 작음 → 작은 컬럼만 읽을 때 **매우 빠름** (I/O 절감)|불필요한 대용량 컬럼까지 읽음 → **느림**|
|**Random Access (PK 등)**|추가 TOAST 페이지 읽기 필요 → **3kB 기준 약간 느림** (~10~20%)|모든 데이터가 한 페이지에 → **조금 더 빠름**|
|**스토리지 효율**|대용량 속성은 압축 + 분리 저장 → **공간 절약**|압축 없음, 큰 컬럼이 항상 힙에 포함됨|
|**유연성**|행/컬럼 단위로 일부만 TOAST 가능|모든 컬럼이 항상 인라인|
|**복잡성**|추가 페이지 관리 필요 (성능 변동 요인)|단순 (추가 관리 없음)|

---

## ✅ 정리

- **메타데이터만**(예: `SELECT id`) 읽을 때는 TOAST가 매우 유리(힙이 작음).
    
- **랜덤으로 실제 페이로드를 읽을 때**는 인라인(`PLAIN/MAIN`)이 유리하거나 비슷—여기서는 인라인이 약 **12%** 빠름.
    
- (toast 한정) 샘플을 더 늘리거나(예: 100k) 데이터가 더 커질수록(행당 더 많은 TOAST 청크) **TOAST 패널티**가 커질 수 있음.
	- 청크들을 찾아서 재조립 필요
- (toast 한정) TOAST 되는 column 숫자가 증가하면 **TOAST 패널티가 커질 수 있음**.
	- 같은 TOAST 테이블에 나뉘어 저장되기 때문

---

## ✅ 결론

- 현재 문제: 모든 컬럼을 디스크에서 읽는 비효율
- 필요성: 다른 DBMS처럼 Out-of-Line 저장 필요

---

## ✅ 요구사항 수집

- [ ] 특정 타입들은 자동 Out of Line (LOB, VECTOR, VARCHAR)
- [ ] 사용자가 컬럼 단위로 Out of Line 강제/금지 설정 가능
- [ ] Threshold 기반 자동 결정 가능 (기본값 제공, 컬럼 별 튜닝 가능)
- [ ] Recovery / Replication / HA

---

## ✨ 구현 계획 제안

1. **BLOB, CLOB, Vector** 타입 우선 적용
2. 성능 이슈 없으면 **VARCHAR**로 지원 범위 확대 (threshold 기반)
3. **모든 가변 길이 타입**으로 범위 확대

---

## (추가) 개발자 관점 고민 포인트

1. Out of Line 저장소를 pg처럼 테이블 기반으로 할 것인가?
2. InnoDB처럼 Linked Overflow Pages 기반으로 할 것인가? 

---

감사합니다.
