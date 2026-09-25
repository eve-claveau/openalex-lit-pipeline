#!/bin/bash
#SBATCH --job-name=Informalite_Classification
#SBATCH --account=def-yacineb
#SBATCH --time=72:00:00
#SBATCH --gres=gpu:h100:1
#SBATCH --cpus-per-task=32
#SBATCH --mem=80G
#SBATCH --output=slurm-%j.out
#SBATCH --error=slurm-%j.out

set -e
start_time=$(date +%s)
echo "=========================================="
echo "Job started at $(date)"
echo "Running on node: $(hostname)"
echo "=========================================="

# ─────────────────────────────────────────────────────────────────
# 1. Environment setup
# ─────────────────────────────────────────────────────────────────
export HOME="/project/def-yacineb"
export PATH="$HOME/bin:$PATH"
export OLLAMA_HOST="127.0.0.1:11434"
export OLLAMA_MODELS="$SLURM_TMPDIR/.ollama"
export OLLAMA_KEEP_ALIVE="60m"
export PYTHONUNBUFFERED=1

# Models to use for classification - ONLY qwen for speed
MODEL_TAGS=("qwen2.5:14b")
export CLASSIFIER_MODELS="qwen2.5:14b"

echo "Models to use: ${MODEL_TAGS[*]}"
echo "CLASSIFIER_MODELS=$CLASSIFIER_MODELS"

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
apptainer exec --bind /localscratch,/scratch,/project --nv /project/def-yacineb/reproduction/ollama_env.sif ollama serve > "$SLURM_TMPDIR/ollama.log" 2>&1 &
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
    if apptainer exec --bind /local,/scratch,/project --nv /project/def-yacineb/reproduction/ollama_env.sif ollama list | grep -q "^${model}"; then
        echo "  ✓ $model already available"
    else
        echo "  Pulling $model..."
        apptainer exec --bind /local,/scratch,/project --nv /project/def-yacineb/reproduction/ollama_env.sif ollama pull "$model"
        echo "  ✓ $model pulled successfully"
        
        # Save immediately after pulling
        echo "  Saving $model to cache..."
        rsync -a "$OLLAMA_MODELS/" "$SCRATCH/.ollama/"
    fi
done

echo ""
echo "Available models:"
apptainer exec --bind /local,/scratch,/project --nv /project/def-yacineb/reproduction/ollama_env.sif ollama list

# ─────────────────────────────────────────────────────────────────
# 5. Activate Python environment and run classification
# ─────────────────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "Starting classification..."
echo "=========================================="

#source "$HOME/openalex_snapshot/data_env/bin/activate"
module load scipy-stack/2026a
cd "$HOME/informalite/prompt_codes"

echo "Python: $(which python)"
echo "Working directory: $(pwd)"
echo "Running: python LLM_classification_informalite.py"
echo ""

apptainer exec --cleanenv --env CLASSIFIER_MODELS="$CLASSIFIER_MODELS" --bind /local,/scratch,/project --nv /project/def-yacineb/reproduction/ollama_env.sif python3 -u LLM_classification_informalite.py

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
