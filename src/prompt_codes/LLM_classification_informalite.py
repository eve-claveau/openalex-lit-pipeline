#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# multi-LLM version

"""
Informalite papers classifier (Ollama, zero-shot simplified, 6-class)
- supports multiple target models via CLASSIFIER_MODELS
- per-thread Ollama clients
- resume-safe CSV
- tracks cumulative runtime in seconds per processed row
"""

import os
import re
import time
import json
import sys
import pandas as pd
print("✅ Basic imports completed", flush=True)

from ollama import Client
print("✅ Ollama client imported", flush=True)

from concurrent.futures import ThreadPoolExecutor, as_completed
from threading import Lock
print("✅ Threading imports completed", flush=True)

# ╔══════════════════════ 0. PATHS & RUNTIME ══════════════════════╗

INPUT_CSV = os.environ.get("INPUT_FILE")
OUTPUT_CSV = os.environ.get("OUTPUT_FILE")

if not INPUT_CSV or not OUTPUT_CSV:
    raise ValueError("ERROR: INPUT_FILE and OUTPUT_FILE environment variables must be set.")

# Ensure output directory exists
os.makedirs(os.path.dirname(OUTPUT_CSV), exist_ok=True)
print(f"✅ Paths setup: IN={INPUT_CSV} | OUT={OUTPUT_CSV}", flush=True)

os.environ.setdefault("OLLAMA_HOST", "http://127.0.0.1:11434")
os.environ.setdefault("OLLAMA_CONTEXT_LENGTH", "9192")
os.environ.setdefault("OLLAMA_MAX_LOADED_MODELS", "1")
os.environ.setdefault("OLLAMA_NUM_PARALLEL", "4")
os.environ.setdefault("OLLAMA_MAX_QUEUE", "9192")
os.environ.setdefault("OLLAMA_FLASH_ATTENTION", "false")

if "SLURM_CPUS_PER_TASK" in os.environ:
    os.environ.setdefault("OLLAMA_NUM_THREADS", os.environ["SLURM_CPUS_PER_TASK"])
else:
    os.environ.setdefault("OLLAMA_NUM_THREADS", "16")

OLLAMA_HOST = os.environ["OLLAMA_HOST"]
print("✅ OLLAMA_HOST loaded", flush=True)

# ╔══════════════════════ 1. CONFIG ══════════════════════╗
_models_env = os.environ.get("CLASSIFIER_MODELS")
if not _models_env:
    raise ValueError("CLASSIFIER_MODELS env var must be set, e.g. 'qwen2.5:14b'")

MODEL_NAMES = [m.strip() for m in _models_env.split(",") if m.strip()]
if not MODEL_NAMES:
    raise ValueError("CLASSIFIER_MODELS is empty after parsing.")
print("✅ Model names parsed", flush=True)

PY_MAX_WORKERS = int(os.environ.get("PY_MAX_WORKERS", "2"))
MAX_ABSTRACT_CHARS = int(os.environ.get("MAX_ABSTRACT_CHARS", "900"))

# ╔══════════════════════ 2. SYSTEM INSTRUCTIONS (External) ══════════════════════╗
PROMPT_FILE = os.environ.get("PROMPT_FILE")

if not PROMPT_FILE:
    raise ValueError("ERROR: PROMPT_FILE environment variable must be set.")
if not os.path.exists(PROMPT_FILE):
    raise FileNotFoundError(f"ERROR: Prompt file not found at {PROMPT_FILE}")

with open(PROMPT_FILE, "r", encoding="utf-8") as f:
    SYSTEM_INSTRUCTIONS = f.read().strip()

print(f"✅ System instructions loaded from {PROMPT_FILE}", flush=True)

# ╔══════════════════════ 3. PROMPT BUILDER ══════════════════════╗
def _truncate_abstract(abstract: str) -> str:
    if not abstract:
        return ""
    abstract = abstract.strip()
    if len(abstract) > MAX_ABSTRACT_CHARS:
        return abstract[:MAX_ABSTRACT_CHARS].rsplit(" ", 1)[0] + " ..."
    return abstract

def build_user_prompt(title: str, abstract: str) -> str:
    title = "" if pd.isna(title) else str(title).strip()
    abstract = "" if pd.isna(abstract) else str(abstract).strip()
    abstract = _truncate_abstract(abstract)

    parts = [
        "PAPER TO CLASSIFY:\n\n",
        f"Title: {title}\n\n",
        f"Abstract: {abstract}\n\n",
        "---\n\n",
        "Classify this paper and return ONLY the JSON output as specified in your instructions."
    ]
    return "".join(parts)

# ╔══════════════════════ 4. PARSING ══════════════════════╗
THINK_PATTERN = re.compile(r"<think>.*?</think>", re.DOTALL | re.IGNORECASE)

def strip_think_blocks(text: str) -> str:
    if not text:
        return text
    return THINK_PATTERN.sub("", text).strip()

def sanitize_json_text(txt: str) -> str:
    if not txt:
        return ""
    s = txt.strip()
    s = re.sub(r'^```json\s*', '', s)
    s = re.sub(r'^```\s*', '', s)
    s = re.sub(r'\s*```$', '', s)
    s = s.strip()

    if s.startswith("{") and s.endswith("}"):
        return s
    start = s.find("{")
    end = s.rfind("}")
    if start != -1 and end != -1 and end > start:
        return s[start : end + 1]
    return ""

def parse_llm_response(text: str):
    if not text:
        return None, ""
    text_wo_think = strip_think_blocks(text)
    json_candidate = sanitize_json_text(text_wo_think)

    if json_candidate:
        try:
            obj = json.loads(json_candidate)
            label_raw = obj.get("class", None)
            reason_raw = obj.get("reason", "")
            label = None
            if isinstance(label_raw, (bool, int, float)):
                label = int(label_raw)
            elif isinstance(label_raw, str) and label_raw.strip().isdigit():
                label = int(label_raw.strip())
            reason = str(reason_raw).strip() if reason_raw is not None else ""
            if label in {1, 2, 3, 4, 5, 6, 7}:
                return label, reason
        except json.JSONDecodeError:
            pass

    s = " ".join(text_wo_think.strip().split())
    m = re.search(r"\b([1-7])\b", s)
    if m:
        return int(m.group(1)), s
    return None, s

# ╔══════════════════════ 5. OLLAMA CLIENT ══════════════════════╗
def classify_paper(model_name: str, title: str, abstract: str) -> dict:
    prompt = build_user_prompt(title, abstract)
    client = Client(host=OLLAMA_HOST)
    ctx_len = int(os.environ.get("OLLAMA_CONTEXT_LENGTH", "9192"))
    num_thread = int(os.environ.get("OLLAMA_NUM_THREADS", "16"))

    options = {
        "temperature": 0.0,
        "top_p": 0.8,
        "num_ctx": ctx_len,
        "num_thread": num_thread,
        "num_predict": 150,
    }
    try:
        resp = client.chat(
            model=model_name,
            messages=[
                {"role": "system", "content": SYSTEM_INSTRUCTIONS},
                {"role": "user", "content": prompt},
            ],
            options=options,
            format="json",
        )
        content = resp.get("message", {}).get("content", "")
    except Exception:
        gen = client.generate(
            model=model_name,
            prompt=SYSTEM_INSTRUCTIONS + "\n\n" + prompt + "\n",
            options=options,
            format="json",
        )
        content = gen.get("response", "")
    
    label, reason = parse_llm_response(content)
    return {"label": label, "reason": reason, "raw": content}

def get_col_names(model_name: str):
    return f"{model_name}_label", f"{model_name}_reason", f"{model_name}_raw"

# ╔══════════════════════ 6. DATAFRAME LOAD ══════════════════════╗
def ensure_model_columns(df: pd.DataFrame) -> pd.DataFrame:
    for model_name in MODEL_NAMES:
        label_col, reason_col, raw_col = get_col_names(model_name)
        if label_col not in df.columns:
            df[label_col] = pd.NA
        if reason_col not in df.columns:
            df[reason_col] = ""
        if raw_col not in df.columns:
            df[raw_col] = ""
    return df

def load_df() -> pd.DataFrame:
    # Always try to load OUTPUT_CSV first to resume progress. If missing, start from INPUT_CSV.
    if os.path.exists(OUTPUT_CSV):
        df_ = pd.read_csv(OUTPUT_CSV)
        print(f"🔄 Resuming from {OUTPUT_CSV}")
    else:
        df_ = pd.read_csv(INPUT_CSV)
        required_cols = {"title", "abstract"}
        missing = required_cols - set(df_.columns)
        if missing:
            raise ValueError(f"Missing required columns in input CSV: {missing}")
        print(f"📥 Loaded {INPUT_CSV} — initializing output columns.")

    df_ = ensure_model_columns(df_)
    if "run_seconds" not in df_.columns:
        df_["run_seconds"] = pd.NA
    return df_

# ╔══════════════════════ 7. MAIN ══════════════════════╗
def main():
    print("==== PY OLLAMA SETTINGS ====")
    print("OLLAMA_HOST:", os.environ.get("OLLAMA_HOST"))
    print("MODELS     :", ", ".join(MODEL_NAMES))
    print("PY_MAX_WORKERS:", PY_MAX_WORKERS)
    print("INPUT_FILE :", INPUT_CSV)
    print("OUTPUT_FILE:", OUTPUT_CSV)
    print("=====================================")

    df = load_df()
    start_time = time.time()

    pending = []
    for idx in df.index:
        for model_name in MODEL_NAMES:
            label_col, _, _ = get_col_names(model_name)
            val = df.at[idx, label_col]
            if pd.isna(val) or (isinstance(val, str) and not val.strip()):
                pending.append(idx)
                break

    if not pending:
        print("🎉 Nothing to do — everything already classified for all models.")
        # Save anyway to ensure the file exists for downstream R script
        df.to_csv(OUTPUT_CSV, index=False)
        return

    total = len(pending)
    print(f"🚀 Starting: {total} rows, {PY_MAX_WORKERS} workers", flush=True)

    lock = Lock()
    processed = 0

    def worker(idx):
        row = df.loc[idx]
        title = row["title"]
        abstract = row["abstract"]
        err_any = None

        for model_name in MODEL_NAMES:
            label_col, reason_col, raw_col = get_col_names(model_name)
            current = df.at[idx, label_col]
            if not (pd.isna(current) or (isinstance(current, str) and not current.strip())):
                continue

            try:
                result = classify_paper(model_name, title, abstract)
                elapsed = time.time() - start_time
                with lock:
                    df.at[idx, label_col] = result["label"]
                    df.at[idx, reason_col] = result["reason"]
                    df.at[idx, raw_col] = result["raw"]
                    df.at[idx, "run_seconds"] = elapsed
            except Exception as e:
                err_any = e
                elapsed = time.time() - start_time
                with lock:
                    df.at[idx, label_col] = pd.NA
                    df.at[idx, reason_col] = f"error: {e}"
                    df.at[idx, raw_col] = ""
                    df.at[idx, "run_seconds"] = elapsed
        return idx, err_any

    with ThreadPoolExecutor(max_workers=PY_MAX_WORKERS) as ex:
        futures = {ex.submit(worker, idx): idx for idx in pending}
        for n, fut in enumerate(as_completed(futures), 1):
            idx, err = fut.result()
            processed += 1
            if processed % 50 == 0:
                with lock:
                    df.to_csv(OUTPUT_CSV, index=False)
                    print(f"💾 Saved progress ({processed}/{total})")

    df.to_csv(OUTPUT_CSV, index=False)
    print(f"\n🎉 Done — results in {OUTPUT_CSV}")

if __name__ == "__main__":
    main()
