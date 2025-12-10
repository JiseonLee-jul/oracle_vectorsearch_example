-- Oracle DB 초기화 스크립트
-- 컨테이너 최초 시작 시 자동 실행

-- (A) CDB에서 PDB로 전환
ALTER SESSION SET CONTAINER = freepdb1;

-- (B) 테이블스페이스 생성
CREATE TABLESPACE vctr_ts
    DATAFILE '/opt/oracle/oradata/FREE/FREEPDB1/vctr_ts01.dbf'
    SIZE 500M
    AUTOEXTEND ON NEXT 100M MAXSIZE UNLIMITED
    EXTENT MANAGEMENT LOCAL AUTOALLOCATE
    SEGMENT SPACE MANAGEMENT AUTO;

-- (C) 사용자 생성 + 기본 테이블스페이스 지정
CREATE USER vctr_user IDENTIFIED BY vctr_user
    DEFAULT TABLESPACE vctr_ts
    TEMPORARY TABLESPACE TEMP;

-- (D) 사용자 quota 설정
ALTER USER vctr_user QUOTA UNLIMITED ON vctr_ts;

-- (E) 사용자 권한 부여
GRANT DBA TO vctr_user;
GRANT DB_DEVELOPER_ROLE, CREATE MINING MODEL TO vctr_user;

-- (F) ONNX 모델 디렉토리 생성 및 권한 부여
CREATE OR REPLACE DIRECTORY ONNX_MODELS AS '/opt/oracle/models';
GRANT READ ON DIRECTORY ONNX_MODELS TO vctr_user;
GRANT WRITE ON DIRECTORY ONNX_MODELS TO vctr_user;

EXIT;
