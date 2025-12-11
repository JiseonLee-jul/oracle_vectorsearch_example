#!/usr/bin/env python3
"""Oracle DB에서 ONNX 모델을 삭제하는 스크립트

사용법:
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
"""

import argparse
import json
import os
import sys
from pathlib import Path

import oracledb
from dotenv import load_dotenv


# =============================================================================
# DB 유틸리티 함수 (추후 utils.py로 분리 가능)
# =============================================================================


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


# =============================================================================
# 설정 유틸리티 함수 (추후 utils.py로 분리 가능)
# =============================================================================


def load_config() -> dict:
    """models.json 로드"""
    config_path = Path(__file__).parent / "models.json"
    with open(config_path, encoding="utf-8") as f:
        return json.load(f)


def get_model_by_db_name(config: dict, db_model_name: str) -> dict | None:
    """DB 모델명으로 설정 정보 조회"""
    for model in config["models"]:
        if model["db_model_name"] == db_model_name:
            return model
    return None


def get_model_by_id(config: dict, model_id: str) -> dict | None:
    """모델 ID로 설정 정보 조회"""
    for model in config["models"]:
        if model["id"] == model_id:
            return model
    return None


# =============================================================================
# 메인 기능
# =============================================================================


def list_models(config: dict, loaded_models: set[str]) -> None:
    """로드된 모델 목록 출력"""
    if not loaded_models:
        print("\n로드된 모델이 없습니다.")
        return

    print("\n로드된 모델:")
    print("-" * 70)

    # 설정에 정의된 모델 중 로드된 것
    for model in config["models"]:
        db_name = model["db_model_name"]
        if db_name in loaded_models:
            print(f"  {model['id']:15} {db_name:25} {model['description']}")

    # 고아 모델 (설정에 없지만 DB에 로드된 모델)
    config_db_names = {m["db_model_name"] for m in config["models"]}
    orphan_models = loaded_models - config_db_names
    for db_name in sorted(orphan_models):
        print(f"  {'(unknown)':15} {db_name:25} [models.json에 미정의]")

    print("-" * 70)
    print(f"총 {len(loaded_models)}개 모델 로드됨")


def confirm_deletion(models_to_drop: list[tuple[str, str | None]]) -> bool:
    """삭제 확인 프롬프트

    Args:
        models_to_drop: [(db_model_name, model_id or None), ...]

    Returns:
        True: 삭제 진행, False: 취소
    """
    print(f"\n삭제 예정 모델 ({len(models_to_drop)}개):")
    for db_name, model_id in models_to_drop:
        if model_id:
            print(f"  - {db_name} ({model_id})")
        else:
            print(f"  - {db_name} (고아 모델)")

    try:
        answer = input("\n삭제하시겠습니까? (y/N): ").strip().lower()
        return answer == "y"
    except (KeyboardInterrupt, EOFError):
        print("\n취소됨")
        return False


def main():
    parser = argparse.ArgumentParser(description="Oracle DB에서 ONNX 모델 삭제")
    parser.add_argument(
        "model_ids", nargs="*", help="삭제할 모델 ID (복수 지정 가능)"
    )
    parser.add_argument("--all", action="store_true", help="모든 모델 삭제")
    parser.add_argument("--list", action="store_true", help="로드된 모델 목록 출력")
    parser.add_argument(
        "-y", "--yes", action="store_true", help="확인 프롬프트 생략"
    )
    args = parser.parse_args()

    # 인자 검증
    if not args.list and not args.all and not args.model_ids:
        parser.print_help()
        sys.exit(1)

    if args.all and args.model_ids:
        print("Error: --all 옵션과 model_ids는 함께 사용할 수 없습니다.")
        sys.exit(1)

    config = load_config()

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

        # 삭제할 모델 목록 결정
        models_to_drop: list[tuple[str, str | None]] = []  # (db_name, model_id)

        if args.all:
            # 전체 삭제: 로드된 모든 모델
            for db_name in loaded_models:
                model = get_model_by_db_name(config, db_name)
                model_id = model["id"] if model else None
                models_to_drop.append((db_name, model_id))
        else:
            # 특정 모델 삭제
            for model_id in args.model_ids:
                model = get_model_by_id(config, model_id)
                if not model:
                    print(f"Error: 모델 '{model_id}'을(를) 찾을 수 없습니다.")
                    print("\n사용 가능한 모델 ID:")
                    for m in config["models"]:
                        print(f"  - {m['id']}")
                    sys.exit(1)

                db_name = model["db_model_name"]
                if db_name not in loaded_models:
                    print(f"Warning: '{model_id}' ({db_name})은(는) 로드되지 않았습니다.")
                    continue

                models_to_drop.append((db_name, model_id))

        # 삭제할 모델이 없는 경우
        if not models_to_drop:
            print("삭제할 모델이 없습니다.")
            return

        # 삭제 확인
        if not args.yes and not confirm_deletion(models_to_drop):
            print("취소됨")
            return

        # 모델 삭제 실행
        print()
        dropped_count = 0

        for db_name, model_id in models_to_drop:
            if model_id:
                model = get_model_by_id(config, model_id)
                print(f"[{model_id}] {model['name']}")
            else:
                print(f"[unknown] {db_name}")

            drop_model(conn, db_name)
            dropped_count += 1

        print(f"\n완료: {dropped_count}개 삭제")

    finally:
        conn.close()


if __name__ == "__main__":
    main()
