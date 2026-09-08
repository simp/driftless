#!/bin/bash

# Get current time in epoch seconds
now=$(date +%s)

# Get boot time in epoch seconds
boot=$(date -d "$(uptime -s)" +%s)

# Calculate the difference (in seconds)
elapsed_seconds=$((now - boot))

# Calculate time segments
days=$(( elapsed_seconds / 86400 ))
hours=$(( (elapsed_seconds % 86400) / 3600 ))
minutes=$(( (elapsed_seconds % 3600) / 60 ))
seconds=$(( elapsed_seconds % 60 ))

# Print the formatted output
echo "Time since boot: ${days}d ${hours}h ${minutes}m ${seconds}s"

# Round up/down to the nearest tenth
dec_minutes=$(( (minutes * 10 + 30) / 60 ))
if [[ dec_minutes -eq 10 ]]; then
  hours=$(( hours + 1 ))
  dec_minutes=0
fi
echo
echo "Hours since boot: ${hours}.${dec_minutes}"
