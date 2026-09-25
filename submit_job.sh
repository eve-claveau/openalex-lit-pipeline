#!/bin/bash
#SBATCH --account=def-yacineb      
#SBATCH --time=72:00:00           
#SBATCH --mem=128G                 
#SBATCH --cpus-per-task=4         
#SBATCH --output=logs/iteration_log_%j.out   
#SBATCH --error=logs/iteration_log_%j.out 

# Script d'execution d'une requête de réseau de citations
# Prends 1 argument: le nombre d'iterations a executer

source /project/def-yacineb/openalex_snapshot/data_env/bin/activate
module load r/4.3.1          
module load scipy-stack

mkdir -p "reseaux_entiers"
mkdir -p "reseaux_entiers/parquet-files"
mkdir -p "reseaux_filtres/parquet-files"
echo "Environment setup done"

set -e
for ((i=2; i<=$1; i++))
do 
    echo "Starting iteration ${i} with the DuckDB query"
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
