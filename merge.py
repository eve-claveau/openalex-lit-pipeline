import pandas as pd

dfs = []
for i in range(3):
    df = pd.read_csv(f'reseaux_filtres/reseau{i}.csv')
    df['iteration_number'] = i
    dfs.append(df)

# Combine all dataframes and save to a new CSV
pd.concat(dfs, ignore_index=True).to_csv('reseaux_filtres/reseau_combine.csv', index=False)
