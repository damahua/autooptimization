# Optimization Hints: pyserver

## Known hot spots
- DATA_STORE is a list used for membership checks (O(n) per lookup)
- HISTORY grows without bound, storing full deep copies of the data store
- Stats computation materializes multiple full intermediate lists

## Architecture notes
- Pure stdlib Python HTTP server, single file server.py
- All state is in module-level globals DATA_STORE and HISTORY
- /proc/self/status is readable for RSS tracking
