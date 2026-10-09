## Prérequis
Pour faire rouler les itérations sur les services de l'Alliance Numérique du Canada, le set-up suivant est requis:

### 1. Structure de fichiers
```text
openalex-lit-pipeline/
├── data/
├── src/
|   ├── prompt_codes/
|   ├── convert_abstract.py
|   ├── filter_by_label.R
|   ├── query.R
|   ├── submit_job.sh
|   ├── run_classification.sh
|   └── ollama_env.sif
├── logs/
└── config/
    └── prompt.txt
```
Le fichier `config/prompt.txt` contient le prompt utilisé pour la classification, à personnaliser au besoin.

### 2. Modules du Cluster
Les modules suivants sont chargés automatiquement par les scripts, mais s'assurer que le cluster les supportent:
    - **Apptainer:** `module load apptainer/1.4.5` (Ollama server).  
    - **Python Stack:** `module load scipy-stack` ( Python 3, Pandas, NumPy).

### 3. Environnement R
Le script pour le réseau de citations requiert R avec les packages suivants:
    - `duckdb`(pour le SQL sur fichiers .parquet)
    - `DBI`(Database Interface)

### 4. Apptainer pour Ollama
La classification LLM roule à l'intérieur d'un apptainer personnalisé (installé  à travers le fichier <ollama_env.def>(ollama_env.def)).

Le construire vous-même à l'aide de la définition fournie.

Naviguer vers le dossier src/ et construire le conteneur. Sur les grappes de l'Alliance, utiliser l'option --fakeroot :
```Bash
cd src
tmux
apptainer build --fakeroot ollama_env.sif ollama_env.def
```

## Processus lors du roulement de plusieurs itérations
L'utilisateur appelle le script en roulant:
```shell
sbatch src/submit_job.sh -i <trajectoire vers le fichier csv avec articles de base> -n <nombre d'iterations> -oa <trajectoire vers le dossier avec les tableaux de openalex en format parquet>
```

Premièrement le script query.R roulera sur les articles de base et sortira le premier réseau de citations (`reseau1.csv`), dans le dossier `reseaux_entiers`. Ce fichier est ensuite copié dans le dossier `Data_storage` sous le nom `file_1.csv`, pour faire passer les articles dans la classification LLM. 

La classification LLM est effectuée avec la tâche run_classification.sh, qui appelle le script LLM_classification.py. Le output se trouve dans le dossier output_data, sous le nom `classified_file_1.csv`.  

Par la suite, le script filter_by_label.R dépose dans le dossier reseaux_filtres le fichier `reseau1.csv`, qui contient seulement les articles classifiés positifs par le LLM. 

La deuxième itération partira du fichier reseau1.csv pour créer un nouveau réseau de citations, en s'assurant d'exclure les articles du `reseau0.csv`. Ainsi de suite jusqu'à la dernière itération.

Le réseau complet final est obtenu en combinant les `reseaux_filtres`, sous le nom `combined.csv`.
Pour obtenir le réseau périphérique, combiner les fichiers de `reseaux_entiers`, en excluant ceux de `reseaux_filtres`.

## En cas d'interuption d'une tâche
Sur un très grand corpus, il arrive souvent que la classification soit interompue en milieu de tâche.  
Le progrès des iterations se trouvera dans:
`logs/iteration_log_%j.out` (où %j est l'identifiant de la tâche)

Ceux de chaque classification dans:
`logs/classification-%j.out`







