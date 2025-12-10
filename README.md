# oracle_vectorsearch_example
oracle26ai 기반의 Oracle AI Vector Search 활용 예제입니다.

## 사전 요구사항

- Docker Desktop 설치
- Oracle Container Registry 로그인
  ```bash
  docker login container-registry.oracle.com
  ```

## 환경 설정

### 1. 환경변수 파일 생성

`.env.example`을 복사하여 `.env` 파일을 생성합니다.

```bash
cp .env.example .env
```

`.env` 파일을 열어 비밀번호를 설정합니다.

```env
ORACLE_PWD=your_oracle_password
VCTR_USER_PWD=your_vctr_user_password
```

### 2. 컨테이너 실행

```bash
# DB 준비 완료까지 대기 (healthcheck 통과 시 완료)
docker-compose up -d --wait
```

초기화는 최초 실행 시 약 5~10분 소요됩니다.

로그를 확인하려면:

```bash
docker-compose logs -f
```

### 3. 접속 테스트

```bash
# SQL*Plus로 접속
docker exec -it oracle26ai sqlplus vctr_user/vctr_user@//localhost:1521/freepdb1

# 또는 호스트에서 직접 접속 (SQL*Plus 설치 시)
sqlplus vctr_user/vctr_user@//localhost:1521/freepdb1
```

## 컨테이너 관리

```bash
# 중지
docker-compose stop

# 시작
docker-compose start

# 삭제 (데이터는 oracle-data/에 유지됨)
docker-compose down

# 데이터 포함 완전 삭제
docker-compose down -v
rm -rf oracle-data/
```

## 디렉토리 구조

```
.
├── docker-compose.yml      # 컨테이너 정의
├── .env                    # 환경변수 (Git 제외)
├── .env.example            # 환경변수 템플릿
├── oracle-data/            # DB 데이터 (Git 제외)
├── models/                 # ONNX 모델 파일 (Git 제외)
└── scripts/
    └── setup/
        └── 01_init.sql     # 초기화 스크립트 (자동 실행)
```

## 초기화 스크립트

`scripts/setup/01_init.sql`은 컨테이너 최초 시작 시 자동 실행되며 다음을 수행합니다:

- 테이블스페이스 생성 (`vctr_ts`, 500MB, 자동확장)
- 사용자 생성 (`vctr_user`)
- DBA, DB_DEVELOPER_ROLE, CREATE MINING MODEL 권한 부여
- ONNX 모델 디렉토리 생성 (`ONNX_MODELS`)

## ONNX 모델 설정

ONNX 모델 다운로드 및 사용법은 [models/README.md](models/README.md)를 참고하세요.
