#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# multi-LLM version

"""
Informalite papers classifier (Ollama, zero-shot simplified, 6-class)
- supports multiple target models via CLASSIFIER_MODELS
- per-thread Ollama clients
- resume-safe CSV
- tracks cumulative runtime in seconds per processed row
re
Classes :
1 - On informality (spatial/infrastructure focus)
2 - On informality (sociocultural/practice focus)
3 - On informality (governance/theoretical focus)
4 - On informality (general/multiple focus)
5 – On informality (unclear focus)
6 – Clearly not about informality
7 – Info not sufficient
"""

import os
import re
import time  # for runtime tracking
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

# Get the script directory and set up folder structure
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(SCRIPT_DIR)  # parent of prompt_codes/
INPUT_DIR = os.path.join(ROOT_DIR, "data")
OUTPUT_DIR = os.path.join(ROOT_DIR, "output_data")
DATA_STORAGE_DIR = os.path.join(ROOT_DIR, "Data_storage")
PROGRESS_FILE = os.path.join(ROOT_DIR, ".classification_progress.json")
print("✅ Path setup completed", flush=True)

# Ensure directories exist
os.makedirs(INPUT_DIR, exist_ok=True)
os.makedirs(OUTPUT_DIR, exist_ok=True)
os.makedirs(DATA_STORAGE_DIR, exist_ok=True)
print("✅ Directories created", flush=True)

os.environ.setdefault("OLLAMA_HOST", "http://127.0.0.1:11434")
os.environ.setdefault("OLLAMA_CONTEXT_LENGTH", "9192")
os.environ.setdefault("OLLAMA_MAX_LOADED_MODELS", "1")
os.environ.setdefault("OLLAMA_NUM_PARALLEL", "4")
os.environ.setdefault("OLLAMA_MAX_QUEUE", "9192")
os.environ.setdefault("OLLAMA_FLASH_ATTENTION", "false")
# if Slurm gives us 32 cores, reuse them for tokenization
if "SLURM_CPUS_PER_TASK" in os.environ:
    os.environ.setdefault("OLLAMA_NUM_THREADS", os.environ["SLURM_CPUS_PER_TASK"])
else:
    os.environ.setdefault("OLLAMA_NUM_THREADS", "16")

OLLAMA_HOST = os.environ["OLLAMA_HOST"]
print("✅ OLLAMA_HOST loaded", flush=True)

# ╔══════════════════════ 1. CONFIG ══════════════════════╗
# CLASSIFIER_MODELS is REQUIRED, e.g.:
#   export CLASSIFIER_MODELS="qwen2.5:14b,llama3.1:70b"
_models_env = os.environ.get("CLASSIFIER_MODELS")
print("✅ Environment vars loaded", flush=True)
if not _models_env:
    raise ValueError(
        "CLASSIFIER_MODELS env var must be set, e.g. "
        "'qwen2.5:14b,llama3.1:70b'"
    )

MODEL_NAMES = [m.strip() for m in _models_env.split(",") if m.strip()]
if not MODEL_NAMES:
    raise ValueError("CLASSIFIER_MODELS is empty after parsing (no valid model names).")
print("✅ Model names parsed", flush=True)

# Will be set dynamically based on current file number
INPUT_CSV = None
OUTPUT_CSV = None

PY_MAX_WORKERS = int(os.environ.get("PY_MAX_WORKERS", "2"))
print("✅ Configuration complete")

# to speed up: don't send huge abstracts
MAX_ABSTRACT_CHARS = int(os.environ.get("MAX_ABSTRACT_CHARS", "900"))

# ╔══════════════════════ 2. SYSTEM INSTRUCTIONS ══════════════════════╗
SYSTEM_INSTRUCTIONS = """
You are a scholar, classifying papers based on their title and/or abstract for a literature review.

Decide if the provided text represents a paper on one of the following categories:
1 - On informality (spatial/infrastructure focus)
2 - On informality (sociocultural/practice focus)
3 - On informality (governance/theoretical focus)
4 - On informality (general/multiple focus)
5 – On informality (unclear focus)
6 – Clearly not about informality
7 – Info not sufficient


OUTPUT FORMAT (STRICT):
Return ONLY a single valid JSON object with exactly these two fields:
{
  "class": 1,
  "reason": "short sentence explaining why this class was chosen"
}

Requirements:
- "class" must be an integer (1, 2, 3, 4, 5, 6 or 7), not a string.
- "reason" must briefly explain why this class was chosen, ideally citing key words or phrases from the title/abstract.
- Do NOT include markdown, backticks, comments, or <think> blocks.
- Output ONLY the JSON object, nothing else.
"""

# ╔══════════════════════ 3. PROMPT BUILDER (zero-shot) ══════════════════════╗
def _truncate_abstract(abstract: str) -> str:
    if not abstract:
        return ""
    abstract = abstract.strip()
    if len(abstract) > MAX_ABSTRACT_CHARS:
        return abstract[:MAX_ABSTRACT_CHARS].rsplit(" ", 1)[0] + " ..."
    return abstract


def build_user_prompt(title: str, abstract: str) -> str:
    """
    Build a zero-shot prompt: just give the paper and ask for JSON output.
    """
    title = "" if pd.isna(title) else str(title).strip()
    abstract = "" if pd.isna(abstract) else str(abstract).strip()
    abstract = _truncate_abstract(abstract)

    parts = []
    parts.append("PAPER TO CLASSIFY:\n\n")
    parts.append(f"Title: {title}\n\n")
    parts.append(f"Abstract: {abstract}\n\n")
    parts.append("---\n\n")
    parts.append("Classify this paper and return ONLY the JSON output as specified in your instructions.")

    return "".join(parts)


# ╔══════════════════════ 4. PARSING (defensive) ══════════════════════╗
THINK_PATTERN = re.compile(r"<think>.*?</think>", re.DOTALL | re.IGNORECASE)


def strip_think_blocks(text: str) -> str:
    """
    Remove DeepSeek-style <think>...</think> blocks if present.
    """
    if not text:
        return text
    return THINK_PATTERN.sub("", text).strip()


def sanitize_json_text(txt: str) -> str:
    """
    Extract the first valid-looking JSON object from a text blob.
    If the entire text is JSON, return it directly; otherwise take the
    substring between the first '{' and the last '}'.
    """
    if not txt:
        return ""
    s = txt.strip()
    # Remove markdown code fences if present
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
    """
    Try hard to get a 6-class label even if the model adds small extra text.
    Primary path: parse a JSON object with fields:
      - class (int 1–7)
      - reason (string)
    Fallback: attempt to recover a standalone digit 1–6.
    """
    if not text:
        return None, ""

    text_wo_think = strip_think_blocks(text)
    json_candidate = sanitize_json_text(text_wo_think)

    # 1) Preferred: parse JSON
    if json_candidate:
        try:
            obj = json.loads(json_candidate)
            label_raw = obj.get("class", None)
            reason_raw = obj.get("reason", "")

            label = None
            if isinstance(label_raw, bool):
                label = int(label_raw)
            elif isinstance(label_raw, (int, float)):
                label = int(label_raw)
            elif isinstance(label_raw, str) and label_raw.strip().isdigit():
                label = int(label_raw.strip())

            reason = str(reason_raw).strip() if reason_raw is not None else ""

            if label in {1, 2, 3, 4, 5, 6, 7}:
                return label, reason
        except json.JSONDecodeError:
            # fall through to non-JSON fallback
            pass

    # 2) Fallback: look for any single digit 1–7 in the text
    s = " ".join(text_wo_think.strip().split())
    m = re.search(r"\b([1-7])\b", s)
    if m:
        return int(m.group(1)), s

    # 3) Give up: no label, put cleaned text into "reason"
    return None, s


# ╔══════════════════════ 5. OLLAMA CLIENT (per-thread) ══════════════════════╗
def make_client():
    return Client(host=OLLAMA_HOST)


def classify_paper(model_name: str, title: str, abstract: str) -> dict:
    """
    Run classification for a single model.
    """
    print(f"    🔧 classify_paper: building prompt...", flush=True)
    prompt = build_user_prompt(title, abstract)
    print(f"    🔧 classify_paper: creating client...", flush=True)
    client = make_client()
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
        print(f"    🔧 classify_paper: calling client.chat for {model_name}...", flush=True)
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
            
        # Extract token usage from the chat response
        prompt_tokens = resp.get("prompt_eval_count", 0)
        completion_tokens = resp.get("eval_count", 0)
            
    except Exception:
        # fallback to /generate
        gen = client.generate(
            model=model_name,
            prompt=SYSTEM_INSTRUCTIONS + "\n\n" + prompt + "\n",
            options=options,
            format="json",
        )
        content = gen.get("response", "")
            
        # Extract token usage from the generate response
        prompt_tokens = gen.get("prompt_eval_count", 0)
        completion_tokens = gen.get("eval_count", 0)
    
    # Print the token metrics directly to the console/log
    total_tokens = prompt_tokens + completion_tokens
    print(f"  📊 Token usage for {model_name}: {prompt_tokens} prompt + {completion_tokens} completion = {total_tokens} total tokens", flush=True)
    
    label, reason = parse_llm_response(content)
    return {
        "label": label,
        "reason": reason,
        "raw": content,
    }
        


# Helper: column names for a given model
def get_col_names(model_name: str):
    """
    Build column names using the model name as prefix.
    Example: model_name='deepseek-r1:32b' ->
      'deepseek-r1:32b_label', 'deepseek-r1:32b_reason', 'deepseek-r1:32b_raw'
    """
    label_col = f"{model_name}_label"
    reason_col = f"{model_name}_reason"
    raw_col = f"{model_name}_raw"
    return label_col, reason_col, raw_col


# ╔══════════════════════ 6. FILE MANAGEMENT & PROGRESS ══════════════════════╗
def get_progress():
    """Load progress tracking file."""
    if os.path.exists(PROGRESS_FILE):
        with open(PROGRESS_FILE, 'r') as f:
            print("progress file exists at", os.path.dirname(PROGRESS_FILE))
            return json.load(f)
    return {"last_completed": 0}


def save_progress(file_num: int):
    """Save progress after completing a file."""
    with open(PROGRESS_FILE, 'w') as f:
        json.dump({"last_completed": file_num}, f)
    print(f"💾 Progress saved: completed file {file_num}")


def find_next_file():
    """Find the next numbered CSV file to process."""
    progress = get_progress()
    last_completed = progress.get("last_completed", 0)
    
    # Look for files numbered from 1 to 10
    for file_num in range(1, 11):
        if file_num <= last_completed:
            continue
        
        # Try different naming patterns in multiple locations
        patterns = [
            f"full_data_part_{file_num}.csv",
            f"file_{file_num}.csv",
            f"split_{file_num}.csv",
            f"part_{file_num}.csv",
            f"{file_num}.csv",
        ]
        
        # Check in DATA_STORAGE_DIR and split_sample subdirectory
        search_dirs = [
            DATA_STORAGE_DIR,
            os.path.join(DATA_STORAGE_DIR, "split_sample"),
        ]
        
        for search_dir in search_dirs:
            for pattern in patterns:
                source_path = os.path.join(search_dir, pattern)
                if os.path.exists(source_path):
                    return file_num, source_path
    
    return None, None


def setup_current_file():
    """
    Find next file to process, copy to input directory, set up paths.
    Returns (file_num, input_path, output_path) or (None, None, None) if done.
    """
    file_num, source_path = find_next_file()
    
    if file_num is None:
        print("🎉 All files (1-10) have been processed!")
        return None, None, None
    
    # Set up input/output paths
    input_path = os.path.join(INPUT_DIR, f"current_file_{file_num}.csv")
    output_path = os.path.join(OUTPUT_DIR, f"classified_file_{file_num}.csv")
    
    # Copy source file to input directory
    import shutil
    shutil.copy2(source_path, input_path)
    print(f"📋 Copied {os.path.basename(source_path)} to input directory")
    print(f"📝 Processing file {file_num}/10")
    
    return file_num, input_path, output_path


# ╔══════════════════════ 7. DATAFRAME LOAD / RESUME ══════════════════════╗
def ensure_model_columns(df: pd.DataFrame) -> pd.DataFrame:
    """
    Ensure that for each model we have <model_name>_label/reason/raw columns.
    """
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


# ╔══════════════════════ 8. MAIN ══════════════════════╗
def main():
    global INPUT_CSV, OUTPUT_CSV
    
    # Find and set up the next file to process
    current_file_num, INPUT_CSV, OUTPUT_CSV = setup_current_file()
    
    if current_file_num is None:
        # All files completed
        return
    
    print("==== PY OLLAMA SETTINGS ====")
    print("OLLAMA_HOST:", os.environ.get("OLLAMA_HOST"))
    print("MODELS     :", ", ".join(MODEL_NAMES))
    print("PY_MAX_WORKERS:", PY_MAX_WORKERS)
    print("OLLAMA_NUM_THREADS:", os.environ.get("OLLAMA_NUM_THREADS"))
    print("CURRENT_FILE_NUM:", current_file_num)
    print("INPUT_FILE :", INPUT_CSV)
    print("OUTPUT_FILE:", OUTPUT_CSV)
    print("LD_LIBRARY_PATH:", os.environ.get("LD_LIBRARY_PATH", ""))
    print("MODEL -> columns:")
    for model_name in MODEL_NAMES:
        label_col, reason_col, raw_col = get_col_names(model_name)
        print(f"  {model_name}: {label_col}, {reason_col}, {raw_col}")
    print("=====================================")

    df = load_df()

    start_time = time.time()

    # A row is pending if ANY model's label column is missing/empty
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
        return

    total = len(pending)
    print(f"🚀 Starting: {total} rows, {PY_MAX_WORKERS} workers, host={OLLAMA_HOST}", flush=True)

    lock = Lock()
    processed = 0

    def worker(idx):
        print(f"🔄 Worker starting on row {idx}", flush=True)
        row = df.loc[idx]
        title = row["title"]
        abstract = row["abstract"]
        err_any = None

        for model_name in MODEL_NAMES:
            print(f"  📝 Row {idx}: trying model {model_name}", flush=True)
            label_col, reason_col, raw_col = get_col_names(model_name)

            current = df.at[idx, label_col]
            if not (pd.isna(current) or (isinstance(current, str) and not current.strip())):
                continue

            try:
                print(f"  🤖 Row {idx}: calling classify_paper for {model_name}...", flush=True)
                result = classify_paper(model_name, title, abstract)
                print(f"  ✅ Row {idx}: got result from {model_name}", flush=True)
                now = time.time()
                elapsed = now - start_time
                with lock:
                    df.at[idx, label_col] = result["label"]
                    df.at[idx, reason_col] = result["reason"]
                    df.at[idx, raw_col] = result["raw"]
                    df.at[idx, "run_seconds"] = elapsed
            except Exception as e:
                print(f"  ❌ Row {idx}: error with {model_name}: {e}", flush=True)
                err_any = e
                now = time.time()
                elapsed = now - start_time
                with lock:
                    df.at[idx, label_col] = pd.NA
                    df.at[idx, reason_col] = f"error with model {model_name}: {e}"
                    df.at[idx, raw_col] = ""
                    df.at[idx, "run_seconds"] = elapsed

        return idx, err_any

    with ThreadPoolExecutor(max_workers=PY_MAX_WORKERS) as ex:
        futures = {ex.submit(worker, idx): idx for idx in pending}
        for n, fut in enumerate(as_completed(futures), 1):
            idx, err = fut.result()
            if err:
                print(f"⚠️ row {idx} error: {err}")
            else:
                print(f"✅ row {idx} classified for all pending models ({n}/{total})")
            processed += 1
            if processed % 50 == 0:
                with lock:
                    df.to_csv(OUTPUT_CSV, index=False)
                    elapsed = time.time() - start_time
                    print(f"💾 Saved progress ({processed}/{total}) at {elapsed:.1f}s")

    df.to_csv(OUTPUT_CSV, index=False)
    total_elapsed = time.time() - start_time
    print(f"\n🎉 Done — results in {OUTPUT_CSV} (total runtime {total_elapsed:.1f}s)")
    
    # Mark this file as completed
    save_progress(current_file_num)
    print(f"✅ File {current_file_num}/10 completed and marked as done")
    print(f"💡 Next run will process file {current_file_num + 1}")


if __name__ == "__main__":
    main()
