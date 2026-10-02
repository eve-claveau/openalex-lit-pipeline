# Suite à la classification des articles, ce script filtre le réseau pour garder 
# seulement ceux avec label < 6 et les rediriger vers le folder "reseaux_filtres"
# Il prend en argument l'index de l'iteration et survient a la fin de l'iteration
args <- commandArgs(trailingOnly = TRUE)
num <- args[1]

# read_csv is replaced by read.csv
data <- read.csv(paste0("output_data/classified_file_", num, ".csv"), stringsAsFactors = FALSE)

# str_detect is replaced by grepl for regular expression matching
label_col <- names(data)[grepl("_label$", names(data))]

# filter is replaced by base R subsetting
# Using which() safely drops any NA values, matching dplyr::filter behavior
filtered_data <- data[which(data[[label_col]] < 6), ]

# write_csv is replaced by write.csv (row.names = FALSE prevents adding an index column)
write.csv(filtered_data, paste0("reseaux_filtres/reseau", num, ".csv"), row.names = FALSE)
