--------------------------------------------------------------------------------
-- PDF → VectorDB 적재 파이프라인
--------------------------------------------------------------------------------
-- 이 스크립트는 PDF 파일을 읽어 텍스트를 추출하고, 청킹 후 임베딩하여
-- Vector 테이블에 저장하는 전체 파이프라인을 구현합니다.
--
-- 파이프라인 흐름:
--   PDF 파일 → [UTL_TO_TEXT] → 텍스트 → [UTL_TO_CHUNKS] → 청크 → [VECTOR_EMBEDDING] → Vector
--
-- 사전 조건:
--   1. 01_load_model.sql 실행 완료 (ONNX 모델 로드)
--   2. documents/ 폴더에 PDF 파일 존재
--   3. PDF_DOCS 디렉토리 객체 생성됨 (01_init.sql에서 자동 생성)
--
-- 실행:
--   sqlplus vctr_user/vctr_user@freepdb1 @04_pdf_to_vector.sql
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON;
SET LINESIZE 200;

--------------------------------------------------------------------------------
-- (A) 기존 테이블 삭제
--------------------------------------------------------------------------------
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE doc_chunks PURGE';
  DBMS_OUTPUT.PUT_LINE('doc_chunks 테이블 삭제됨');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('doc_chunks 테이블 없음 (스킵)');
END;
/

BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE pdf_documents PURGE';
  DBMS_OUTPUT.PUT_LINE('pdf_documents 테이블 삭제됨');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('pdf_documents 테이블 없음 (스킵)');
END;
/

--------------------------------------------------------------------------------
-- (B) PDF 문서 저장 테이블 생성
--------------------------------------------------------------------------------
-- PDF 파일의 원본 BLOB 데이터를 저장하는 테이블
-- BFILE로 외부 파일을 참조하여 BLOB으로 로드
--------------------------------------------------------------------------------
CREATE TABLE pdf_documents (
    doc_id       NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    file_name    VARCHAR2(255) NOT NULL,      -- 원본 파일명
    pdf_content  BLOB,                         -- PDF 바이너리 데이터
    created_at   TIMESTAMP DEFAULT SYSTIMESTAMP
);

COMMENT ON TABLE pdf_documents IS 'PDF 문서 원본 저장 테이블';
COMMENT ON COLUMN pdf_documents.doc_id IS '문서 고유 ID (자동 생성)';
COMMENT ON COLUMN pdf_documents.file_name IS '원본 PDF 파일명';
COMMENT ON COLUMN pdf_documents.pdf_content IS 'PDF 바이너리 콘텐츠 (BLOB)';

--------------------------------------------------------------------------------
-- (C) 청크 + 임베딩 저장 테이블 생성
--------------------------------------------------------------------------------
-- 하나의 PDF는 여러 개의 청크로 분할되며, 각 청크는 임베딩 벡터를 가짐
-- doc_id + chunk_id로 복합 기본키 구성
--------------------------------------------------------------------------------
CREATE TABLE doc_chunks (
    doc_id       NUMBER NOT NULL,             -- pdf_documents.doc_id 참조
    chunk_id     NUMBER NOT NULL,             -- 청크 순번 (1부터 시작)
    file_name    VARCHAR2(255),               -- 원본 파일명 (조회 편의용)
    chunk_text   CLOB,                        -- 청크 텍스트 내용
    embedding    VECTOR(384, FLOAT32),        -- 임베딩 벡터 (384차원, all-MiniLM 모델)
    created_at   TIMESTAMP DEFAULT SYSTIMESTAMP,
    --
    CONSTRAINT pk_doc_chunks PRIMARY KEY (doc_id, chunk_id),
    CONSTRAINT fk_doc_chunks_doc FOREIGN KEY (doc_id) REFERENCES pdf_documents(doc_id)
);

COMMENT ON TABLE doc_chunks IS 'PDF 청크 및 임베딩 저장 테이블';
COMMENT ON COLUMN doc_chunks.chunk_id IS '청크 순번 (문서 내에서 1부터 시작)';
COMMENT ON COLUMN doc_chunks.chunk_text IS '청크 텍스트 (UTL_TO_CHUNKS로 분할된 텍스트)';
COMMENT ON COLUMN doc_chunks.embedding IS '임베딩 벡터 (ALL_MINILM_L12_V2 모델, 384차원)';

-- 벡터 인덱스 생성 (유사도 검색 성능 향상)
-- COSINE: 코사인 유사도 기반 검색에 최적화
--------------------------------------------------------------------------------
-- [대안] 거리 측정 방식
--   - COSINE: 코사인 유사도 (텍스트 검색에 권장, 방향 기반)
--   - EUCLIDEAN (L2): 유클리드 거리 (절대적 거리 기반)
--   - DOT_PRODUCT: 내적 (정규화된 벡터에서 COSINE과 동일)
--   - MANHATTAN (L1): 맨해튼 거리
--------------------------------------------------------------------------------
CREATE VECTOR INDEX idx_doc_chunks_embedding
ON doc_chunks(embedding)
ORGANIZATION NEIGHBOR PARTITIONS
DISTANCE COSINE
WITH TARGET ACCURACY 95;

--------------------------------------------------------------------------------
-- (D) PDF 파일 로드
--------------------------------------------------------------------------------
-- BFILENAME: 디렉토리 객체와 파일명으로 외부 파일 참조
-- TO_BLOB: BFILE을 BLOB으로 변환하여 테이블에 저장
--
-- [주의] 파일명은 대소문자 구분됨 (Linux 환경)
-- [주의] PDF_DOCS 디렉토리는 /opt/oracle/documents를 가리킴
--------------------------------------------------------------------------------
-- 예시: sample.pdf 파일 로드
-- documents/ 폴더에 PDF 파일을 넣은 후 아래 파일명을 수정하세요
--------------------------------------------------------------------------------
INSERT INTO pdf_documents (file_name, pdf_content)
VALUES (
    'sample.pdf',  -- << 실제 파일명으로 변경
    TO_BLOB(BFILENAME('PDF_DOCS', 'sample.pdf'))  -- << 실제 파일명으로 변경
);
COMMIT;

--------------------------------------------------------------------------------
-- (E) PDF → 텍스트 → 청킹 → 임베딩 파이프라인
--------------------------------------------------------------------------------
-- Oracle DBMS_VECTOR_CHAIN을 사용한 체이닝 파이프라인
-- 한 번의 SQL문으로 PDF → Vector 전체 과정을 처리
--
-- 파이프라인 구조 (Oracle 공식 권장 패턴):
--   1. UTL_TO_TEXT: PDF BLOB → 텍스트 추출
--   2. UTL_TO_CHUNKS: 텍스트 → 청크 분할
--   3. UTL_TO_EMBEDDINGS: 청크 배열 → 임베딩 배열 (배치 처리)
--   4. JSON_TABLE: 임베딩 배열 → 관계형 테이블
--
-- [참고] https://docs.oracle.com/en/database/oracle/oracle-database/26/arpls/dbms_vector_chain1.html
--------------------------------------------------------------------------------
INSERT INTO doc_chunks (doc_id, chunk_id, file_name, chunk_text, embedding)
SELECT
    p.doc_id,
    et.embed_id,
    p.file_name,
    et.embed_data,
    ------------------------------------------------------------------------
    -- 임베딩 벡터 변환
    ------------------------------------------------------------------------
    -- TO_VECTOR: CLOB 형식의 임베딩을 VECTOR 타입으로 변환
    -- UTL_TO_EMBEDDINGS는 embed_vector를 CLOB으로 반환하므로 변환 필요
    ------------------------------------------------------------------------
    TO_VECTOR(et.embed_vector)
FROM
    pdf_documents p,
    ------------------------------------------------------------------------
    -- UTL_TO_EMBEDDINGS: 청크 배열을 임베딩 배열로 변환
    ------------------------------------------------------------------------
    -- 반환 타입: VECTOR_ARRAY_T (각 요소는 JSON 형식의 CLOB)
    -- 반환 형식:
    --   {"embed_id": 1, "embed_data": "청크텍스트", "embed_vector": "[0.1, 0.2, ...]"}
    --
    -- [선택된 옵션] DB 내장 ONNX 모델 (ALL_MINILM_L12_V2)
    --   - provider: "database" - DB에 로드된 ONNX 모델 사용
    --   - model: 모델명 (USER_MINING_MODELS에서 확인 가능)
    --   - 장점: 외부 API 의존 없음, 데이터가 DB 밖으로 나가지 않음
    --   - 단점: 모델 크기 제한 (1GB), 최신 모델 사용 불가
    --
    -- [대안 A] 외부 API - OpenAI
    --   JSON('{
    --       "provider": "openai",
    --       "credential_name": "OPENAI_CRED",
    --       "url": "https://api.openai.com/v1/embeddings",
    --       "model": "text-embedding-3-small",
    --       "batch_size": 25
    --   }')
    --
    -- [대안 B] 외부 API - Cohere
    --   JSON('{
    --       "provider": "cohere",
    --       "credential_name": "COHERE_CRED",
    --       "url": "https://api.cohere.ai/v1/embed",
    --       "model": "embed-multilingual-v3.0",
    --       "batch_size": 10
    --   }')
    --
    -- [대안 C] 외부 API - Oracle Generative AI
    --   JSON('{
    --       "provider": "ocigenai",
    --       "credential_name": "OCI_CRED",
    --       "url": "https://inference.generativeai.us-chicago-1.oci.oraclecloud.com/...",
    --       "model": "cohere.embed-english-v3.0"
    --   }')
    ------------------------------------------------------------------------
    DBMS_VECTOR_CHAIN.UTL_TO_EMBEDDINGS(
        --------------------------------------------------------------------
        -- UTL_TO_CHUNKS: 텍스트를 청크 배열로 분할
        --------------------------------------------------------------------
        -- 반환 타입: VECTOR_ARRAY_T (각 요소는 JSON 형식의 CLOB)
        -- 반환 형식:
        --   {"chunk_id": 1, "chunk_offset": 0, "chunk_length": 100, "chunk_data": "..."}
        --------------------------------------------------------------------
        DBMS_VECTOR_CHAIN.UTL_TO_CHUNKS(
            ----------------------------------------------------------------
            -- UTL_TO_TEXT: PDF BLOB → 텍스트 추출
            ----------------------------------------------------------------
            -- 지원 형식: PDF, DOC, DOCX, HTML, XML, JSON 등 ~150가지
            -- Oracle Text CONTEXT 구성요소 필요
            --
            -- [파라미터]
            --   plaintext: true - 순수 텍스트 추출 (기본값)
            --   charset: UTF8 - 문자 인코딩 (현재 UTF8만 지원)
            ----------------------------------------------------------------
            DBMS_VECTOR_CHAIN.UTL_TO_TEXT(p.pdf_content),
            ----------------------------------------------------------------
            -- 청킹 파라미터
            ----------------------------------------------------------------
            -- [선택된 옵션]
            --   by: "words" - 단어 단위로 청크 크기 계산
            --   max: "100" - 최대 100단어
            --   overlap: "10" - 이전 청크의 10단어를 포함 (컨텍스트 유지)
            --   split: "sentence" - 문장 경계에서 분할 (의미 보존)
            --   normalize: "all" - 공백, 특수문자 정규화
            --
            -- [대안 A] by: "characters"
            --   - 문자 수 기준 분할 (max: 50-4000 범위)
            --   - 장점: 청크 크기가 일정함
            --   - 단점: 단어 중간에서 잘릴 수 있음
            --   예: JSON('{"by":"characters", "max":"500", "overlap":"50"}')
            --
            -- [대안 B] by: "vocabulary"
            --   - 토크나이저 어휘 토큰 기준 분할
            --   - 모델 토크나이저와 일치시킬 때 유용
            --   예: JSON('{"by":"vocabulary", "vocabulary":"myvocab", "max":"100"}')
            --
            -- [대안 C] split: "recursively" (기본값)
            --   - 공백줄 → 줄바꿈 → 공백 순으로 자동 시도
            --   예: JSON('{"by":"words", "max":"100", "split":"recursively"}')
            --
            -- [대안 D] split: "custom"
            --   - 사용자 정의 구분자로 분할
            --   예: JSON('{"split":"custom", "custom_list":["<p>", "<section>"]}')
            --
            -- [추가 옵션]
            --   language: "korean" - 한국어 문장 경계 인식
            --   extended: true - 청크 크기 32767바이트까지 확장
            ----------------------------------------------------------------
            JSON('{"by":"words", "max":"100", "overlap":"10", "split":"sentence", "language":"american", "normalize":"all"}')
        ),
        JSON('{"provider":"database", "model":"ALL_MINILM_L12_V2"}')
    ) t,
    ------------------------------------------------------------------------
    -- JSON_TABLE: UTL_TO_EMBEDDINGS 결과를 관계형 테이블로 변환
    ------------------------------------------------------------------------
    -- t.column_value: VECTOR_ARRAY_T의 각 요소 (CLOB)
    -- '$[*]': JSON 배열의 모든 요소 선택
    ------------------------------------------------------------------------
    JSON_TABLE(
        t.column_value,
        '$[*]' COLUMNS (
            embed_id     NUMBER        PATH '$.embed_id',
            embed_data   VARCHAR2(4000) PATH '$.embed_data',
            embed_vector CLOB          PATH '$.embed_vector'
        )
    ) et;

COMMIT;

BEGIN
    DBMS_OUTPUT.PUT_LINE('PDF 적재 완료');
END;
/

--------------------------------------------------------------------------------
-- 끝
--------------------------------------------------------------------------------
