import pandas as pd
import json
import os
import sys
from pathlib import Path
# prend un argument: le nombre de l'iteration

num = sys.argv[1]
PARENT_DIR = Path(__file__).resolve().parents[1]
NAME_IN = "temp_reseau" + num + ".csv"
NAME_OUT = "reseaux_entiers/reseau" + num + ".csv"
FILE = os.path.join(PARENT_DIR, "data", "reseaux_entiers", NAME_IN)
PATH_OUT = os.path.join(PARENT_DIR, "data", "reseaux_entiers", NAME_OUT)
def undo_inverted_index(inverted_index):
    """
    The purpose of the function is to 'undo' an inverted index. It inputs an inverted index and
    returns the original string.
    """
    # return empty string if missing
    if pd.isna(inverted_index):
        return ""
        
    # Transform the json string into python dictionary
    inverted_index = json.loads(inverted_index)

    word_index = []
    words_unindexed = []

    # loop through index and return key-value pairs
    for k, v in inverted_index.items():
        for index in v: 
            word_index.append([k, index])

    # sort by the index
    word_index = sorted(word_index, key=lambda x: x[1])

    # join only the values and flatten
    for pair in word_index:
        words_unindexed.append(pair[0])
        
    words_unindexed = ' '.join(words_unindexed)

    return words_unindexed

# Load the data
table = pd.read_csv(FILE)

# Apply the un-indexing function
table["abstract_inverted_index"] = table["abstract_inverted_index"].apply(undo_inverted_index)

# Rename the column to just "abstract"
table.rename(columns={"abstract_inverted_index": "abstract"}, inplace=True)

# Save the output

table.to_csv(PATH_OUT, index=False)
