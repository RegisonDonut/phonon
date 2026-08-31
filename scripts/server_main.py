#!/usr/bin/env python3
"""Frozen-server entrypoint: dispatch to the right backend by the active model.

The PyInstaller bundle (dist/phonon-server) freezes BOTH backends; at runtime
we read the user's chosen model and run the matching server on 127.0.0.1:8799:
  - "qwen-pipeline" -> pipeline_server (Qwen3-ASR + Qwen3.5-4B two-layer)
  - anything else   -> omni_server   (MiniCPM-o single model)
"""
import os


def _model_id():
    try:
        cfg = os.path.expanduser("~/Library/Application Support/Phonon/model")
        return open(cfg, encoding="utf-8").read().strip()
    except Exception:
        return "minicpm"


def main():
    if _model_id() == "qwen-pipeline":
        import pipeline_server as server
    else:
        import omni_server as server
    server.main()


if __name__ == "__main__":
    main()
