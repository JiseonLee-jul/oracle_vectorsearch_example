#!/usr/bin/env python3
"""ONNX 모델 다운로드 스크립트"""

import json
import sys
import urllib.request
import zipfile
from pathlib import Path


def load_config():
    """models.json 로드"""
    config_path = Path(__file__).parent / "models.json"
    with open(config_path, encoding="utf-8") as f:
        return json.load(f)


def download_model(model: dict, output_dir: Path):
    """모델 다운로드 및 압축 해제"""
    url = model["url"]
    output_file = output_dir / model["output"]

    # 이미 존재하면 스킵
    if output_file.exists():
        print(f"  [SKIP] {model['output']} already exists")
        return

    # ZIP 파일인 경우
    if url.endswith(".zip"):
        zip_path = output_dir / f"{model['id']}_temp.zip"

        print(f"  Downloading {model['name']}...")
        urllib.request.urlretrieve(url, zip_path)

        print(f"  Extracting...")
        with zipfile.ZipFile(zip_path, "r") as zf:
            # .onnx 파일만 추출
            for file_info in zf.namelist():
                if file_info.endswith(".onnx"):
                    zf.extract(file_info, output_dir)

        # ZIP 파일 삭제
        zip_path.unlink()
        print(f"  [OK] {model['output']}")
    else:
        # ONNX 파일 직접 다운로드
        print(f"  Downloading {model['name']}...")
        urllib.request.urlretrieve(url, output_file)
        print(f"  [OK] {model['output']}")


def main():
    config = load_config()
    output_dir = Path(__file__).parent

    # 특정 모델만 다운로드
    target_id = sys.argv[1] if len(sys.argv) > 1 else None

    models_to_download = []
    for model in config["models"]:
        if target_id is None or model["id"] == target_id:
            models_to_download.append(model)

    if not models_to_download:
        print(f"Model '{target_id}' not found.")
        print("Available models:")
        for m in config["models"]:
            print(f"  - {m['id']}: {m['name']}")
        sys.exit(1)

    print(f"Downloading {len(models_to_download)} model(s)...\n")

    for model in models_to_download:
        download_model(model, output_dir)

    print("\nDone!")


if __name__ == "__main__":
    main()
