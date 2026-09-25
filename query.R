
args = commandArgs(trailingOnly = TRUE)

num <- as.numeric(args[1])
library(duckdb)
library(dbplyr)
library(dplyr)
library(stringr)

con <- dbConnect(duckdb::duckdb())
dir.create("/project/def-yacineb/informalite/duckdb_temp", showWarnings = FALSE)
dbExecute(con,"PRAGMA temp_directory='/project/def-yacineb/informalite/duckdb_temp';")
dbExecute(con, "PRAGMA memory_limit='96GB';")
dbExecute(con, "PRAGMA threads=4;")

input_csv <- Sys.getenv("INPUT_FILE")
input <- paste0("reseaux_filtres/parquet-files/reseau", (num - 1), ".parquet")
dbExecute(con, paste0("
  COPY (SELECT * FROM '", input_csv, "') TO '", input, "' (FORMAT PARQUET);
"))
oa_dir <- Sys.getenv("OPEN_ALEX")
output <- paste0('reseaux_entiers/parquet-files/reseau', num, '.parquet')

seen_ids_file <- "/project/def-yacineb/informalite/reseaux_entiers/parquet-files/all_seen_ids.parquet"
# dependament de si cest la premiere iteration, approches differentes pour eviter les duplications
if (num < 2) {
  avoiding <- input
} else {
  avoiding <- seen_ids_file
}

# dans l'integralite du reseau deja determine, make sure pas de doublons
sql_time <- system.time({
  dbExecute(con, paste0("
  COPY (
      WITH base_ids AS (
        SELECT id AS work_id 
        FROM read_parquet('", input ,"')
        ),
      
      -- Les articles du réseau
      cited_by_ids AS (
        SELECT work_id 
        FROM read_parquet('", oa_dir ,"' || '/works_referenced_works.parquet')
        WHERE referenced_work_id IN (
          SELECT id
          FROM read_parquet('", input , "')
        
        ) AND work_id NOT IN (
-- not in base articles
          SELECT id
          FROM read_parquet('", avoiding, "')
        )
      ),
 
     citing_ids AS (
        SELECT referenced_work_id AS work_id
        FROM read_parquet('", oa_dir ,"' || '/works_referenced_works.parquet')
        WHERE work_id IN (
          SELECT id
          FROM read_parquet('", input , "')
        ) AND referenced_work_id NOT IN 
-- not in base articles 
        ( SELECT id
          FROM read_parquet('", avoiding , "'))
      ), 
 
      combined_ids AS (
        SELECT work_id FROM cited_by_ids
        UNION
        SELECT work_id FROM citing_ids
        UNION
        SELECT work_id FROM base_ids
      )
 
      -- pour section cited by
     /* citations_lists AS (
          SELECT 
          ref.referenced_work_id AS target_work_id,
          -- cited_by sous format liste
          LIST(ref.work_id) AS cited_by
          FROM read_parquet('", oa_dir ,"' || 'works_referenced_works.parquet') ref
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
      JOIN read_parquet('", oa_dir ,"' || '/works.parquet') w
        ON c.work_id = w.id
     -- LEFT JOIN citations_lists cl
        -- ON w.id = cl.target_work_id
      LEFT JOIN read_parquet('", oa_dir ,"' || '/works_primary_locations.parquet') ploc
        ON w.id = ploc.work_id
      LEFT JOIN read_parquet('", oa_dir ,"' || '/sources.parquet') s
        ON ploc.source_id = s.id
        
      -- pour authorships
      LEFT JOIN read_parquet('", oa_dir ,"' || '/works_authorships.parquet') wa
        ON w.id = wa.work_id
      LEFT JOIN read_parquet('", oa_dir ,"' || '/authors.parquet') a
        ON wa.author_id = a.id
      LEFT JOIN read_parquet('", oa_dir ,"' || '/institutions.parquet') i
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
        -- cl.cited_by
        
    ) TO '", output, "' (FORMAT PARQUET);
  "))
})

csv_output <- paste0('reseaux_entiers/temp_reseau', num, '.csv')

# 2. Safely glue the SQL together using paste0()
dbExecute(con, paste0("
  COPY (SELECT * FROM '", output , "') 
  TO '", csv_output , "' (HEADER, DELIMITER ',');
"))

# Mettre a jour le fichier cumulatif : ancien "vu" + le frontier de cette iteration 
# (base_ids) + les nouveaux articles trouves cette iteration
dbExecute(con, paste0("
  COPY (
    SELECT id FROM read_parquet('", avoiding, "')
    UNION
    SELECT id FROM read_parquet('", input, "')
    UNION
    SELECT id FROM read_parquet('", output, "')
  ) TO '", seen_ids_file, "' (FORMAT PARQUET);
"))


dbDisconnect(con, shutdown = TRUE)
print(paste0("Temps de la requête: ", sql_time[3]))



