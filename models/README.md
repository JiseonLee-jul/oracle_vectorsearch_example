# ONNX 모델 관리

Oracle DB에서 사용할 ONNX 임베딩 모델을 다운로드하고 관리하는 스크립트 모음입니다.

## 디렉토리 구조

```
models/
├── download_models.py   # 모델 다운로드 스크립트
├── load_models.py       # DB 로드 스크립트
├── drop_models.py       # DB 삭제 스크립트
├── models.json          # 모델 설정
├── README.md
└── onnx/                # ONNX 모델 파일 (Git 제외)
    └── all_MiniLM_L12_v2.onnx
```

## 워크플로우

```
1. 다운로드 (download_models.py)
   ↓
2. DB 로드 (load_models.py)
   ↓
3. 사용 (SQL에서 VECTOR_EMBEDDING 함수 호출)
   ↓
4. 삭제 (drop_models.py) - 필요시
```

## 빠른 시작

```bash
# 1. 모델 다운로드
python models/download_models.py all-minilm

# 2. Oracle DB에 로드
python models/load_models.py all-minilm

# 3. SQL에서 사용
# SELECT VECTOR_EMBEDDING(ALL_MINILM_L12_V2 USING '텍스트' AS DATA) FROM DUAL;
```

## 모델 목록

| ID | 모델명 | DB 모델명 | 차원 | 설명 |
|----|--------|-----------|------|------|
| `all-minilm` | all-MiniLM-L12-v2 | `ALL_MINILM_L12_V2` | 384 | 범용 텍스트 임베딩 |

## 스크립트 사용법

### download_models.py - 모델 다운로드

ONNX 모델 파일을 다운로드합니다.

```bash
# 전체 모델 다운로드
python models/download_models.py

# 특정 모델만 다운로드
python models/download_models.py all-minilm
```

### load_models.py - DB 로드

다운로드한 ONNX 모델을 Oracle DB에 로드합니다.

```bash
# 전체 모델 로드
python models/load_models.py

# 특정 모델만 로드
python models/load_models.py all-minilm

# 모델 목록 확인
python models/load_models.py --list

# 강제 재로드 (기존 모델 삭제 후 재로드)
python models/load_models.py --force
python models/load_models.py all-minilm --force
```

### drop_models.py - DB에서 삭제

Oracle DB에 로드된 모델을 삭제합니다.

```bash
# 특정 모델 삭제
python models/drop_models.py all-minilm

# 여러 모델 삭제
python models/drop_models.py all-minilm multilingual-e5

# 전체 모델 삭제 (고아 모델 포함)
python models/drop_models.py --all

# 로드된 모델 목록 확인
python models/drop_models.py --list

# 확인 프롬프트 생략
python models/drop_models.py all-minilm -y
```

## models.json 작성 가이드

### 스키마

```json
{
  "models": [
    {
      "id": "모델 식별자 (CLI에서 사용)",
      "name": "모델 표시명",
      "description": "모델 설명",
      "url": "다운로드 URL (.zip 또는 .onnx)",
      "output": "저장될 파일명 (.onnx)",
      "db_model_name": "Oracle DB에 등록될 모델명 (대문자)"
    }
  ]
}
```

### 필드 설명

| 필드 | 필수 | 설명 | 예시 |
|------|------|------|------|
| `id` | O | CLI에서 사용하는 짧은 식별자 | `all-minilm` |
| `name` | O | 원본 모델의 정식 명칭 | `all-MiniLM-L12-v2` |
| `description` | O | 모델 용도 및 차원 수 | `범용 텍스트 임베딩 (384차원)` |
| `url` | O | 다운로드 URL (zip 또는 onnx) | `https://...` |
| `output` | O | 로컬에 저장될 파일명 | `all_MiniLM_L12_v2.onnx` |
| `db_model_name` | O | Oracle DB 모델명 (대문자, 언더스코어) | `ALL_MINILM_L12_V2` |

### 새 모델 추가 예시

```json
{
  "models": [
    {
      "id": "multilingual-e5",
      "name": "multilingual-e5-small",
      "description": "다국어 텍스트 임베딩 (384차원)",
      "url": "https://example.com/multilingual_e5_small.zip",
      "output": "multilingual_e5_small.onnx",
      "db_model_name": "MULTILINGUAL_E5_SMALL"
    }
  ]
}
```

### 작성 규칙

1. **id**: 소문자, 하이픈 사용 (예: `all-minilm`, `multilingual-e5`)
2. **db_model_name**: 대문자, 언더스코어 사용, Oracle 식별자 규칙 준수
3. **url**: `.zip` 파일인 경우 내부의 `.onnx` 파일이 자동 추출됨
4. **output**: 실제 `.onnx` 파일명과 일치해야 함

## 트러블슈팅

### DB 연결 실패

```
Error: VCTR_USER_PWD 환경 변수가 설정되지 않았습니다.
```

→ `.env` 파일에 `VCTR_USER_PWD=<비밀번호>` 추가

### 모델 파일 없음

```
[SKIP] all_MiniLM_L12_v2.onnx 파일 없음
```

→ `python models/download_models.py all-minilm` 실행

### 이미 로드된 모델

```
[SKIP] 이미 로드됨 (재로딩: --force 옵션 사용)
```

→ `--force` 옵션으로 재로드하거나, 먼저 `drop_models.py`로 삭제

### 고아 모델

`--list`에서 `(unknown)`으로 표시되는 모델은 `models.json`에 정의되지 않았지만 DB에 로드된 모델입니다.

→ `drop_models.py --all`로 삭제하거나, `models.json`에 정의 추가
