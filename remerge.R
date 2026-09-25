# script that adds missing records to classified_file_2.csv and marks them as pending

library(duckdb)
library(DBI)

con <- dbConnect(duckdb::duckdb())

# Optional: Set temp directory if memory spills are a concern
dbExecute(con, sprintf("PRAGMA temp_directory='%s';", Sys.getenv("SLURM_TMPDIR", "/tmp")))

dbExecute(con, "
  COPY (
    -- 1. Keep the 400,000 already classified records intact
    SELECT * 
    FROM read_csv_auto('output_data/classified_file_2.csv')
    
    UNION ALL BY NAME
    
    -- 2. Grab the 360,000 missing records and append them
    SELECT f.*
    FROM read_csv_auto('Data_storage/file_2.csv') f
    ANTI JOIN read_csv_auto('output_data/classified_file_2.csv') c
      ON f.id = c.id  -- IMPORTANT: Change 'id' to your actual ID column (e.g., 'work_id')
  ) TO 'output_data/classified_file_2_ready.csv' (FORMAT CSV, HEADER);
")

dbDisconnect(con, shutdown = TRUE)