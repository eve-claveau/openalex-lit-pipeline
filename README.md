# Processus lors du roulement de plusieurs itérations
L'utilisateur appelle le script en roulant:
```shell
sbatch submit_job.sh <nombre_diterations>
```
Les articles de base se trouvent dans le dossier reseaux_filtres, sous le nom "reseau0.csv".

Premièrement le script query.R roulera sur les articles de base et sortira le premier réseau de citations ("reseau1.csv"), dans le dossier reseaux_entiers. Ce fichier est ensuite copié dans le dossier "Data_storage" sous le nom "file_1.csv", pour faire passer les articles dans la classification LLM. 

La classification LLM est effectuée avec la tâche run_classification.sh, qui appelle le script LLM_classification.py. Le output se trouve dans le dossier output_data, sous le nom `classified_file_1.csv`.  

Par la suite, le script filter_by_label.R dépose dans le dossier reseaux_filtres le fichier "reseau1.csv", qui contient seulement les articles classifiés positifs par le LLM. 

La deuxième itération partira du fichier reseau1.csv pour créer un nouveau réseau de citations, en s'assurant d'exclure les articles du reseau0.csv. Ainsi de suite jusqu'à la dernière itération.

Le réseau complet final est obtenu en combinant les reseaux_filtres, sous le nom "combined.csv".
Pour obtenir le réseau périphérique, combiner les fichiers de reseaux_entiers, en excluant ceux de reseaux_filtres.

# En cas d'interuption d'une tâche

