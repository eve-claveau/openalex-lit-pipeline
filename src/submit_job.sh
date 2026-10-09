#!/bin/bash
#SBATCH --time=72:00:00           
#SBATCH --mem=128G                 
#SBATCH --cpus-per-task=4         
#SBATCH --output=logs/iteration_log_%j.out   
#SBATCH --error=logs/iteration_log_%j.out 

# Script d'execution d'une requête de réseau de citations
# Prends 3 arguments: la trajectoire vers le fichier de base, le nombre d'iterations a executer, et la trajectoire vers le dossier des tableaux de openalex en format parquet.

source /project/def-yacineb/openalex_snapshot/data_env/bin/activate
module purge
module load r/4.3.1          
module load scipy-stack
PARENT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
INPUT_FILE="" 
NUM_ITERATIONS=""
OPEN_ALEX=""

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -i|--input)
            INPUT_FILE="$2"
            shift 2 # Shift past the flag and its value
            ;;
        -h|--help)
            echo "Usage: $0 [-i|--input <path to input file> -n|--num <number of iterations, integer> -oa|--open_alex <path to folder of open alex files in parquet format>]"
            exit 0
            ;;
        -n|--num)
            NUM_ITERATIONS="$2"
            shift 2
            ;;
        -oa|--open_alex)
            OPEN_ALEX="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac

done

# Verify that the argument was provided
if [[ -z "$INPUT_FILE" || -z "$NUM_ITERATIONS" || -z "$OPEN_ALEX" ]]; then
    echo "Erreur: --input --num et --open_alex arguments sont requis. Voir submit_job.sh --help pour instructions."
    exit 1
fi

echo "Input file path is: $INPUT_FILE"
echo "Number of iterations is: $NUM_ITERATIONS"
echo "Path to open alex files is: $OPEN_ALEX"

export INPUT_FILE
export NUM_ITERATIONS
export OPEN_ALEX

mkdir -p "data/reseaux_entiers"
mkdir -p "data/reseaux_entiers/parquet-files"
mkdir -p "data/reseaux_filtres/parquet-files"    
mkdir -p "data/reseaux_peripheriques"
echo "Environment setup done"

# Iteration Loop
set -e
for ((i=1; i<=NUM_ITERATIONS; i++))
do 
    echo "Starting iteration ${i} with the DuckDB query"
    export ITERATION=$i
    
    if [[ $i -ne 1 ]]; then
        INPUT_FILE="data/reseaux_filtres/reseau$((i - 1)).csv" 
        export INPUT_FILE
    fi

    # ---------------------------------------------------------
    # STEP 1: DuckDB Query & Conversion
    # ---------------------------------------------------------
    if [ ! -f "data/reseaux_entiers/reseau${i}.csv" ]; then
        echo "Running DuckDB query..."
        Rscript src/query.R $i
        
        echo "Converting abstracts..."
        python src/convert_abstract.py $i
        
        rm -f "data/reseaux_entiers/temp_reseau${i}.csv"
    else
        echo "✓ Query and conversion already done for iteration ${i}. Skipping."
    fi

    # ---------------------------------------------------------
    # STEP 2: Batch Classification
    # ---------------------------------------------------------
    CLASSIFICATION_DONE=false
    
    # Si le fichier existe, on vérifie s'il est 100% complété
    if [ -f "data/output_data/classified_file_${i}.csv" ]; then
        echo "Verifying if classification is 100% complete..."
        
        # Ce petit script Python retourne 1 s'il trouve des cases vides, et 0 si tout est complet
        if python -c "
import pandas as pd
try:
    df = pd.read_csv('data/output_data/classified_file_${i}.csv', dtype=str)
    cols = [c for c in df.columns if c.endswith('_label')]
    if not cols: 
        exit(1) # Les colonnes n'existent pas
    for c in cols:
        if df[c].isna().any() or (df[c].str.strip() == '').any() or (df[c] == 'nan').any():
            exit(1) # Il reste des articles non classifiés
    exit(0) # Le fichier est 100% complet
except:
    exit(1) # Erreur de lecture
"; then
            CLASSIFICATION_DONE=true
            echo "✓ Classification already 100% completed for iteration ${i}. Skipping."
        else
            echo "⚠️ File exists but contains unclassified rows. Resuming array..."
        fi
    fi

    # Si le fichier n'existe pas ou s'il n'est pas terminé, on lance/relance l'Array
    if [ "$CLASSIFICATION_DONE" = false ]; then
        echo "Preparing batches for classification..."
        BATCH_SIZE=10000
        
        # Nettoyer les anciens lots d'entrée en cas de redémarrage
        rm -f data/reseaux_entiers/reseau${i}_part_*
        
        head -n 1 "data/reseaux_entiers/reseau${i}.csv" > "data/reseaux_entiers/header.csv"
        tail -n +2 "data/reseaux_entiers/reseau${i}.csv" | split -l $BATCH_SIZE -d -a 3 - "data/reseaux_entiers/reseau${i}_part_"
        
        NUM_CHUNKS=0
        for file in data/reseaux_entiers/reseau${i}_part_*; do
            cat "data/reseaux_entiers/header.csv" "$file" > "${file}_tmp.csv"
            mv "${file}_tmp.csv" "$file"
            NUM_CHUNKS=$((NUM_CHUNKS + 1))
        done
        rm -f "data/reseaux_entiers/header.csv"

        echo "Submitting classification array (1-$NUM_CHUNKS)..."
        sbatch --wait --array=1-$NUM_CHUNKS src/run_classification.sh
        
        echo "Merging classified batches..."
        head -n 1 "data/output_data/classified_file_${i}_part_000.csv" > "data/output_data/classified_file_${i}.csv"
        tail -n +2 -q data/output_data/classified_file_${i}_part_*.csv >> "data/output_data/classified_file_${i}.csv"
    fi

    # ---------------------------------------------------------
    # STEP 3: Filtering the Network
    # ---------------------------------------------------------
    if [ ! -f "data/reseaux_filtres/reseau${i}.csv" ]; then
        echo "Filtering by label..."
        Rscript src/filter_by_label.R $i
    else
        echo "✓ Filtering already done for iteration ${i}. Skipping."
    fi
    
    echo "Iteration ${i} successfully completed."
done

echo "All iterations done"
echo "Combining networks"

# reseau filtre
head -n 1 "data/reseaux_filtres/reseau1.csv" > "data/reseaux_filtres/combined.csv"
tail -n +2 -q data/reseaux_filtres/reseau*.csv >> "data/reseaux_filtres/combined.csv"

# reseau peripherique
head -n 1 "data/reseaux_peripheriques/reseau1.csv" > "data/reseaux_peripheriques/combined_peripherique.csv"
tail -n +2 -q data/reseaux_peripheriques/reseau*.csv >> "data/reseaux_peripheriques/combined_peripherique.csv"

# reseau entier
head -n 1 "data/reseaux_entiers/reseau1.csv" > "data/reseaux_entiers/combined_entiers.csv"
tail -n +2 -q data/reseaux_entiers/reseau*.csv >> "data/reseaux_entiers/combined_entiers.csv"

echo "All done."
echo "- Final filtered output: data/reseaux_filtres/combined.csv"
echo "- Final peripheral output: data/reseaux_peripheriques/combined_peripherique.csv"
echo "- Final full network: data/reseaux_entiers/combined_entiers.csv"
