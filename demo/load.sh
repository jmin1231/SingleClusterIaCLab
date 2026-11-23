#!/usr/bin/env bash
# Sends requests to PostgREST from fe-1 (through the tunnel and Traefik) until the time is up; prints a count per HTTP status at the end.
# Usage, on the lab host: demo/load.sh [seconds, default 120] [parallel clients, default 8]
DURATION=${1:-120}
PARALLEL=${2:-8}
ssh fe-1 "timeout $DURATION sh -c 'seq 1 10000000 | xargs -P $PARALLEL -I{} curl -s -o /dev/null -w \"%{http_code}\n\" --max-time 3 http://10.3.1.10:8000/items' | sort | uniq -c"
