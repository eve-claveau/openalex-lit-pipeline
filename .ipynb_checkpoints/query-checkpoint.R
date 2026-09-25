
args = commandArgs(trailingOnly = TRUE)
# ajouter user input du tableau initial
if (length(args) == 0) {
  stop("Spécifier le fichier csv de base.", call.= TRUE)
} else if (length(args) == 1) {
  args[2] = "/project/def-yacineb/reproduction/output.parquet"
}

library(duckdb)
library(dbplyr)
library(dplyr)
library(stringr)

con <- dbConnect(duckdb::duckdb())
dir.create("/project/def-yacineb/reproduction/duckdb_temp", showWarnings = FALSE)
dbExecute(con,"PRAGMA temp_directory='/project/def-yacineb/reproduction/duckdb_temp';")
dbExecute(con, "PRAGMA memory_limit='96GB';")
dbExecute(con, "PRAGMA threads=4;")

input <- args[1]
output <- 'test_out.parquet'
if (str_detect(input, "\\.csv$")) {
  # conversion en .parquet
  parquet_file <- str_replace(input, "\\.csv$", ".parquet")
  
  dbExecute(con, paste0("
    COPY (SELECT * FROM '", input, "') 
    TO '", parquet_file, "' (FORMAT PARQUET);"
  ))
  
  input <- parquet_file
  
} else if (str_detect(input, '\\.parquet$')) {
  
} else if (str_detect(input, '\\.json$')) {
  parquet_file <- str_replace(input, "\\.json$", ".parquet")
  
  dbExecute(con, paste0("
    COPY (SELECT * FROM '", input, "') 
    TO '", parquet_file, "' (FORMAT PARQUET);"
  ))
  
  input <- parquet_file
} else
{
  stop("Fichier doit être en format .parquet ou .csv '", input,"'", call.= TRUE)
}

output <- args[2]

# S'assurer que le fichier intermédiaire est bien en .parquet et que le
# fichier final est bien en .csv, peu importe l'extension fournie par
# l'utilisateur (sinon on se retrouve avec un fichier binaire parquet
# nommé "*.csv", ce qui fait échouer la relecture en CSV plus loin).
if (str_detect(output, "\\.parquet$")) {
  parquet_output <- output
  csv_output <- str_replace(output, "\\.parquet$", ".csv")
} else if (str_detect(output, "\\.csv$")) {
  csv_output <- output
  parquet_output <- str_replace(output, "\\.csv$", ".parquet")
} else {
  parquet_output <- paste0(output, ".parquet")
  csv_output <- paste0(output, ".csv")
}

# changer la logique des id pour une logique avec les titres
# ajouter un comparatif avec le tableau initial pour vérifier que le nouveau réseau n'est pas doublonné
sql_time <- system.time({
  dbExecute(con, paste0("
  COPY (
      
      -- les articles de base
      WITH sample_works AS (
        SELECT id AS work_id
        FROM read_parquet('", input , "')
      ),
      
      -- Les articles du réseau
      cited_by_ids AS (
        SELECT work_id 
        FROM read_parquet('/project/def-yacineb/openalex_snapshot/parquet-files/works_referenced_works.parquet')
        WHERE referenced_work_id IN (
          SELECT id
          FROM read_parquet('", input , "')
        
        ) AND work_id NOT IN (
          SELECT id FROM read_parquet('input1.parquet')
        )
      ),
 
     citing_ids AS (
        SELECT referenced_work_id AS work_id
        FROM read_parquet('/project/def-yacineb/openalex_snapshot/parquet-files/works_referenced_works.parquet')
        WHERE work_id IN (
          SELECT id
          FROM read_parquet('", input , "')
        ) AND referenced_work_id NOT IN 
        ( SELECT id FROM read_parquet('input1.parquet'))
      ), 
 
      network_ids AS (
        SELECT work_id FROM cited_by_ids
        UNION
        SELECT work_id FROM citing_ids
      ),
 
      -- ajout d'une colonne pour flag les articles de base
      ids_flagged AS (
        SELECT work_id, true AS sample_work FROM sample_works
        UNION ALL
        SELECT work_id, false AS sample_work FROM network_ids
      ),
 
      -- tout les articles combinés
      combined_ids AS (
        SELECT work_id, 
        BOOL_OR(sample_work) AS sample_work
        FROM ids_flagged 
        GROUP BY work_id
      )
      -- pour section cited by
     /* citations_lists AS (
          SELECT 
          ref.referenced_work_id AS target_work_id,
          -- cited_by sous format liste
          LIST(ref.work_id) AS cited_by
          FROM read_parquet('/project/def-yacineb/openalex_snapshot/parquet-files/works_referenced_works.parquet') ref
          -- joindre la liste cités par seulement sur les articles qui nous concernent
          JOIN combined_ids c 
          ON ref.referenced_work_id = c.work_id
          GROUP BY ref.referenced_work_id
      ) */
      
      -- La sélection finale
      SELECT 
        w.id, 
        w.title, 
        w.display_name, 
        w.abstract_inverted_index, 
        w.doi, 
        w.publication_date, 
        w.type, 
        w.language,
        ploc.source_id,
        ploc.pdf_url,
        s.display_name AS source_display_name,
        c.sample_work AS article_du_sample,
        -- cl.cited_by,
        
        
        -- sub tableau pour informations authorships
        list({
          'author_id': a.id,
          'author_name': a.display_name,
          'position': wa.author_position,
          'institution_id': i.id,
          'institution_name': i.display_name
        }) AS authorships
        
      FROM combined_ids c
      JOIN read_parquet('/project/def-yacineb/openalex_snapshot/parquet-files/works.parquet') w
        ON c.work_id = w.id
     -- LEFT JOIN citations_lists cl
        -- ON w.id = cl.target_work_id
      LEFT JOIN read_parquet('/project/def-yacineb/openalex_snapshot/parquet-files/works_primary_locations.parquet') ploc
        ON w.id = ploc.work_id
      LEFT JOIN read_parquet('/project/def-yacineb/openalex_snapshot/parquet-files/sources.parquet') s
        ON ploc.source_id = s.id
        
      -- pour authorships
      LEFT JOIN read_parquet('/project/def-yacineb/openalex_snapshot/parquet-files/works_authorships.parquet') wa
        ON w.id = wa.work_id
      LEFT JOIN read_parquet('/project/def-yacineb/openalex_snapshot/parquet-files/authors.parquet') a
        ON wa.author_id = a.id
      LEFT JOIN read_parquet('/project/def-yacineb/openalex_snapshot/parquet-files/institutions.parquet') i
        ON wa.institution_id = i.id
        
      -- grouper au niveau des travaux
      GROUP BY 
        w.id, 
        w.title, 
        w.display_name,
        w.abstract_inverted_index,
        w.doi, 
        w.type,
        w.language,
        w.publication_date, 
        ploc.source_id,
        ploc.pdf_url,
        s.display_name,
        c.sample_work
        -- cl.cited_by
        
    ) TO '", parquet_output, "' (FORMAT PARQUET);
  "))
})

# 2. Safely glue the SQL together using paste0()
dbExecute(con, paste0("
  COPY (SELECT * FROM '", parquet_output , "') 
  TO '", csv_output , "' (HEADER, DELIMITER ',');
"))

dbDisconnect(con, shutdown = TRUE)
print(paste0("Temps de la requête: ", sql_time[3]))



