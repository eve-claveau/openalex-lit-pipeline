#!/bin/bash
#SBATCH --account=def-yacineb      
#SBATCH --time=72:00:00           
#SBATCH --mem=128G                 
#SBATCH --cpus-per-task=4         
#SBATCH --output=logs/iteration_log_%j.out   
#SBATCH --error=logs/iteration_log_%j.out 

# Script d'execution d'une requête de réseau de citations
# Prends 3 arguments: la trajectoire vers le fichier de base, le nombre d'iterations a executer, et la trajectoire vers le dossier des tableaux de openalex en format parquet.

source /project/def-yacineb/openalex_snapshot/data_env/bin/activate
module load r/4.3.1          
module load scipy-stack
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
if [[ -z "$INPUT_FILE" || -z "$NUM_ITERATIONS || -z "$OPEN_ALEX" ]]; then
    echo "Erreur: --input --num et --open_alex arguments sont requis. Voir submit_job.sh --help pour instructions."
    exit 1
fi

echo "Input file path is: $INPUT_FILE"
echo "Number of iterations is: $NUM_ITERATIONS"
echo "Path to open alex files is: $OPEN_ALEX"

export INPUT_FILE
export NUM_ITERATIONS
export OPEN_ALEX

mkdir -p "reseaux_entiers"
mkdir -p "reseaux_entiers/parquet-files"
mkdir -p "reseaux_filtres/parquet-files"
echo "Environment setup done"

set -e
for ((i=1; i<=NUM_ITERATIONS; i++))
do 
    echo "Starting iteration ${i} with the DuckDB query"

    # le fichier input de la requete de reseau change a chaque iteration
    if [[ $i -ne 1 ]]; then
        INPUT_FILE="reseaux_filtres/reseau{$i - 1}.csv"
        export INPUT_FILE
    fi
    # les scripts prennent le numero de l'iteration en input
    Rscript query.R $i #duckdb query
    echo "DuckDB query done"
    python convert_abstract.py $i # convertir les resumes en textes
    echo "Conversion done"
    rm "reseaux_entiers/temp_reseau${i}.csv"
    cp "reseaux_entiers/reseau${i}.csv" "Data_storage/file_${i}.csv"
    echo "Files reorganized"
    sbatch --wait run_classification.sh # tache de classification
    echo "Classification Done"
    Rscript filter_by_label.R $i         # filtrage des articles pertinents
    echo "Iteration ${i} done"
done

head -1 reseaux_filtres/file1.csv > reseaux_filtres/combined.csv && tail -n +2 -q resaux_filtres/*.csv >> reseaux_filtres/combined.csv

echo "All done. Final output is in reseaux_filtres/combined.csv"
