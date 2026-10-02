#!/bin/bash
#SBATCH --job-name=Classification_LLM
#SBATCH --time=72:00:00
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=32
#SBATCH --mem=80G
#SBATCH --output=../logs/classification-%j.out # Les logs remonteront au dossier parent
#SBATCH --error=../logs/classification-%j.out

set -e
start_time=$(date +%s)
echo "=========================================="
echo "Job started at $(date)"
echo "Running on node: $(hostname)"
echo "=========================================="

# ─────────────────────────────────────────────────────────────────
# 1. Environment & Project setup
# ─────────────────────────────────────────────────────────────────
# Assume que le script est lancé depuis le dossier src/
SRC_DIR=$(pwd)
REPO_ROOT=$(dirname "$SRC_DIR") # Remonte d'un niveau pour trouver la racine
OLLAMA_SIF="$SRC_DIR/ollama_env.sif"

export OLLAMA_HOST="127.0.0.1:11434"
export OLLAMA_MODELS="$SLURM_TMPDIR/.ollama"
export OLLAMA_KEEP_ALIVE="60m"
export PYTHONUNBUFFERED=1

export PROMPT_FILE="$REPO_ROOT/config/prompt.txt"

# Validation des variables obligatoires
if [ -z "$INPUT_FILE" ] || [ -z "$NUM_ITERATIONS" ] || [ -z "$OPEN_ALEX" ]; then
    echo "ERROR: Missing environment variables. Please set INPUT_FILE, NUM_ITERATIONS, and OPEN_ALEX."
    exit 1
fi

if [ ! -f "PROMPT_FILE" ]; then
    echo "ERROR: Prompt file not found at $PROMPT_FILE"
    exit 1
fi

if [ ! -f "$OLLAMA_SIF" ]; then
    echo "ERROR: Apptainer image not found at $OLLAMA_SIF. Please ensure it is in the src/ directory."
    exit 1
fi

# Models to use for classification
MODEL_TAGS=("qwen2.5:14b")
export CLASSIFIER_MODELS="qwen2.5:14b"

echo "Models to use: ${MODEL_TAGS[*]}"
echo "Project Root: $REPO_ROOT"
echo "Source Directory: $SRC_DIR"

# ─────────────────────────────────────────────────────────────────
# 2. Restore cached models from scratch (if available)
# ─────────────────────────────────────────────────────────────────
if [[ -d "$SCRATCH/.ollama" ]]; then
    echo "Restoring cached models from $SCRATCH/.ollama..."
    rsync -a "$SCRATCH/.ollama/" "$OLLAMA_MODELS/"
    echo "Restored models:"
    ls -la "$OLLAMA_MODELS/" 2>/dev/null || echo "(empty)"
else
    echo "No cached models found in $SCRATCH/.ollama"
    mkdir -p "$OLLAMA_MODELS"
fi

# ─────────────────────────────────────────────────────────────────
# 3. Start Ollama server
# ─────────────────────────────────────────────────────────────────
echo "Starting Ollama server..."
module load apptainer/1.4.5

apptainer exec --bind /localscratch,/scratch,/project --nv "$OLLAMA_SIF" ollama serve > "$SLURM_TMPDIR/ollama.log" 2>&1 &
OLLAMA_PID=$!
echo "Ollama PID: $OLLAMA_PID"

# Wait for server to be ready
echo "Waiting for Ollama server to be ready..."
for i in {1..60}; do
    if curl -s http://127.0.0.1:11434/api/tags > /dev/null 2>&1; then
        echo "Ollama server is ready after ${i}s"
        break
    fi
    sleep 1
done

# Verify server is running
if ! curl -s http://127.0.0.1:11434/api/tags > /dev/null 2>&1; then
    echo "ERROR: Ollama server failed to start"
    cat "$SLURM_TMPDIR/ollama.log"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────
# 4. Pull models (if not already cached)
# ─────────────────────────────────────────────────────────────────
echo "Checking/pulling models..."
for model in "${MODEL_TAGS[@]}"; do
    echo "Checking model: $model"
    if apptainer exec --bind /localscratch,/scratch,/project --nv "$OLLAMA_SIF" ollama list | grep -q "^${model}"; then
        echo "  ✓ $model already available"
    else
        echo "  Pulling $model..."
        apptainer exec --bind /localscratch,/scratch,/project --nv "$OLLAMA_SIF" ollama pull "$model"
        echo "  ✓ $model pulled successfully"
        
        # Save immediately after pulling
        echo "  Saving $model to cache..."
        rsync -a "$OLLAMA_MODELS/" "$SCRATCH/.ollama/"
    fi
done

# ─────────────────────────────────────────────────────────────────
# 5. Activate Python environment and run classification
# ─────────────────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "Starting classification..."
echo "=========================================="

module load scipy-stack/2026a
cd "$SRC_DIR"

echo "Working directory: $(pwd)"
echo "Running: python LLM_classification_informalite.py"
echo ""
export INPUT_FILE="../data/reseaux_entiers/reseau${ITERATION}.csv"
export OUTPUT_FILE="../data/output_data/classified_file_${ITERATION}.csv"

apptainer exec --cleanenv \
  --env CLASSIFIER_MODELS="$CLASSIFIER_MODELS" \
  --env INPUT_FILE="$INPUT_FILE" \
  --env NUM_ITERATIONS="$NUM_ITERATIONS" \
  --env OPEN_ALEX="$OPEN_ALEX" \
  --env PROMPT_FILE="$PROMPT_FILE" \
  --bind /localscratch,/scratch,/project \
  --nv "$OLLAMA_SIF" python3 -u LLM_classification_informalite.py

echo ""
echo "=========================================="
echo "Classification completed at $(date)"
echo "=========================================="

# ─────────────────────────────────────────────────────────────────
# 6. Final cache save
# ─────────────────────────────────────────────────────────────────
echo "Saving models to persistent cache..."
rsync -a "$OLLAMA_MODELS/" "$SCRATCH/.ollama/"
echo "Models cached to $SCRATCH/.ollama"

# Cleanup
kill $OLLAMA_PID 2>/dev/null || true
end_time=$(date +%s)
execution_time=$((end_time - start_time))
echo "Total runtime: $execution_time seconds"
echo "Job finished at $(date)"