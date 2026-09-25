# Suite à la classification des articles, ce script filtre le réseau pour garder 
# seulement ceux avec label < 6 et les rediriger vers le folder "reseaux_filtres"
# Il prend en argument l'index de l'iteration et survient a la fin de l'iteration

library(dplyr)

args = commandArgs(trailingOnly = TRUE)
num = args[1]
data <- read.csv(paste0("output_data/classified_file_", num, ".csv"))
filtered_data <- filter(data, `qwen2.5:14b_label`< 6)
write.csv(filtered_data, paste0("reseaux_filtres/reseau", num, ".csv"))


