#!/usr/bin/env python3
"""ONNX 모델을 Oracle DB에 로딩하는 스크립트

사용법:
    # 전체 모델 로딩
    python models/load_models.py

    # 특정 모델만 로딩
    python models/load_models.py all-minilm

    # 모델 목록 확인
    python models/load_models.py --list

    # 강제 재로딩 (기존 모델 삭제 후 재로딩)
    python models/load_models.py --force
    python models/load_models.py all-minilm --force
"""

import argparse
import json
import os
import sys
from pathlib import Path

import oracledb
from dotenv import load_dotenv


def get_db_connection() -> oracledb.Connection:
    """DB 연결 생성"""
    load_dotenv()

    host = os.getenv("ORACLE_HOST", "localhost")
    port = os.getenv("ORACLE_PORT", "1521")
    service = os.getenv("ORACLE_SERVICE", "freepdb1")
    user = os.getenv("ORACLE_USER", "vctr_user")
    password = os.getenv("VCTR_USER_PWD")

    if not password:
        print("Error: VCTR_USER_PWD 환경 변수가 설정되지 않았습니다.")
        print("  .env 파일에 VCTR_USER_PWD=<비밀번호> 를 추가하세요.")
        sys.exit(1)

    dsn = f"{host}:{port}/{service}"
    return oracledb.connect(user=user, password=password, dsn=dsn)


def load_config() -> dict:
    """models.json 로드"""
    config_path = Path(__file__).parent / "models.json"
    with open(config_path, encoding="utf-8") as f:
        return json.load(f)


def get_loaded_models(conn: oracledb.Connection) -> set[str]:
    """DB에 이미 로드된 모델 목록 조회"""
    with conn.cursor() as cursor:
        cursor.execute("SELECT MODEL_NAME FROM USER_MINING_MODELS")
        return {row[0] for row in cursor.fetchall()}


def drop_model(conn: oracledb.Connection, model_name: str) -> None:
    """DB에서 모델 삭제"""
    with conn.cursor() as cursor:
        cursor.execute(
            "BEGIN DBMS_VECTOR.DROP_ONNX_MODEL(:name, force => TRUE); END;",
            {"name": model_name},
        )
    print(f"  [DROP] {model_name} 삭제됨")


def load_model(conn: oracledb.Connection, model: dict, models_dir: Path) -> bool:
    """단일 모델 로딩

    Returns:
        True: 로딩 성공, False: 스킵됨
    """
    onnx_file = models_dir / model["output"]
    db_model_name = model["db_model_name"]

    # ONNX 파일 존재 확인
    if not onnx_file.exists():
        print(f"  [SKIP] {model['output']} 파일 없음")
        print(f"         python models/download_models.py {model['id']} 로 다운로드하세요.")
        return False

    # DB에 모델 로딩
    with conn.cursor() as cursor:
        cursor.execute(
            """
            BEGIN
                DBMS_VECTOR.LOAD_ONNX_MODEL(
                    directory  => 'ONNX_MODELS',
                    file_name  => :file_name,
                    model_name => :model_name
                );
            END;
            """,
            {"file_name": model["output"], "model_name": db_model_name},
        )
    print(f"  [LOAD] {db_model_name} 로딩 완료")
    return True


def list_models(config: dict, loaded_models: set[str]) -> None:
    """모델 목록 출력"""
    print("\n사용 가능한 모델:")
    print("-" * 60)
    for model in config["models"]:
        db_name = model["db_model_name"]
        status = "[로드됨]" if db_name in loaded_models else "[미로드]"
        print(f"  {model['id']:15} {status:10} {model['description']}")
    print("-" * 60)


def main():
    parser = argparse.ArgumentParser(description="ONNX 모델을 Oracle DB에 로딩")
    parser.add_argument("model_id", nargs="?", help="로딩할 모델 ID (생략시 전체 로딩)")
    parser.add_argument("--list", action="store_true", help="모델 목록 출력")
    parser.add_argument("--force", action="store_true", help="기존 모델 삭제 후 재로딩")
    args = parser.parse_args()

    config = load_config()
    models_dir = Path(__file__).parent / "onnx"

    # DB 연결
    try:
        conn = get_db_connection()
    except oracledb.Error as e:
        print(f"Error: DB 연결 실패 - {e}")
        sys.exit(1)

    try:
        loaded_models = get_loaded_models(conn)

        # --list 옵션
        if args.list:
            list_models(config, loaded_models)
            return

        # 로딩할 모델 필터링
        if args.model_id:
            models_to_load = [m for m in config["models"] if m["id"] == args.model_id]
            if not models_to_load:
                print(f"Error: 모델 '{args.model_id}'을(를) 찾을 수 없습니다.")
                list_models(config, loaded_models)
                sys.exit(1)
        else:
            models_to_load = config["models"]

        print(f"\n{len(models_to_load)}개 모델 로딩 시작...\n")

        # 모델 로딩
        loaded_count = 0
        skipped_count = 0

        for model in models_to_load:
            db_name = model["db_model_name"]
            print(f"[{model['id']}] {model['name']}")

            # 이미 로드된 경우
            if db_name in loaded_models:
                if args.force:
                    drop_model(conn, db_name)
                else:
                    print(f"  [SKIP] 이미 로드됨 (재로딩: --force 옵션 사용)")
                    skipped_count += 1
                    continue

            # 모델 로딩
            if load_model(conn, model, models_dir):
                loaded_count += 1
            else:
                skipped_count += 1

        print(f"\n완료: {loaded_count}개 로딩, {skipped_count}개 스킵")

    finally:
        conn.close()


if __name__ == "__main__":
    main()
