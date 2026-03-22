#!/bin/bash

# Lire le JSON du hook sur stdin
input=$(cat)

# Vérifier si mise.toml a été modifié via create_file ou replace_string_in_file
if echo "$input" | grep -q "mise.toml"; then
    # Auto-run mise install
    mise install
fi
