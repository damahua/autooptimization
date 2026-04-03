#!/bin/bash
set -euo pipefail

HOST="${SERVICE_HOST:-localhost}"
PORT="${SERVICE_PORT:-8000}"
BASE_URL="http://$HOST:$PORT"
TENANT="default_tenant"
DATABASE="default_database"
API="$BASE_URL/api/v2/tenants/$TENANT/databases/$DATABASE"

# Workload parameters
EMBEDDING_DIM=768
TOTAL_EMBEDDINGS=50000
BATCH_SIZE=500
NUM_BATCHES=$((TOTAL_EMBEDDINGS / BATCH_SIZE))
NUM_QUERIES=100
CONCURRENT_QUERIES=8
COLLECTION_NAME="autoopt_bench"

echo "[chroma-workload] Running workload against $BASE_URL"
echo "[chroma-workload] Config: ${TOTAL_EMBEDDINGS} embeddings, dim=${EMBEDDING_DIM}, batch=${BATCH_SIZE}"

# Wait for server ready
for i in $(seq 1 30); do
    if curl -sf "$BASE_URL/api/v2/heartbeat" > /dev/null 2>&1; then
        echo "[chroma-workload] Server ready"
        break
    fi
    echo "[chroma-workload] Waiting for server... ($i/30)"
    sleep 2
done

# Reset state
curl -sf -X POST "$BASE_URL/api/v2/reset" > /dev/null 2>&1 || true

TOTAL_REQUESTS=0
FAILED_REQUESTS=0
LATENCIES=""

record_latency() {
    local start_ms=$1
    local end_ms=$2
    local exit_code=$3
    TOTAL_REQUESTS=$((TOTAL_REQUESTS + 1))
    if [ "$exit_code" -ne 0 ]; then
        FAILED_REQUESTS=$((FAILED_REQUESTS + 1))
    else
        local latency=$((end_ms - start_ms))
        LATENCIES="$LATENCIES $latency"
    fi
}

now_ms() {
    python3 -c "import time; print(int(time.time()*1000))"
}

# ===== Phase 1: Create collection =====
echo "[chroma-workload] Phase 1: Creating collection..."
START_MS=$(now_ms)
set +e
curl -sf -X POST -H "Content-Type: application/json" \
    -d "{\"name\": \"$COLLECTION_NAME\", \"metadata\": {\"hnsw:space\": \"cosine\"}}" \
    "$API/collections" > /tmp/chroma_collection.json
EXIT_CODE=$?
set -e
END_MS=$(now_ms)
record_latency "$START_MS" "$END_MS" "$EXIT_CODE"

# Extract collection ID
COLLECTION_ID=$(python3 -c "import json; print(json.load(open('/tmp/chroma_collection.json'))['id'])" 2>/dev/null || echo "")
if [ -z "$COLLECTION_ID" ]; then
    echo "[chroma-workload] ERROR: Failed to create collection"
    cat /tmp/chroma_collection.json 2>/dev/null
    echo "latency_p99_ms=0"
    echo "throughput_qps=0"
    echo "error_rate=1.0"
    exit 1
fi
echo "[chroma-workload] Collection created: $COLLECTION_ID"

# ===== Phase 2: Insert embeddings in batches =====
echo "[chroma-workload] Phase 2: Inserting ${TOTAL_EMBEDDINGS} embeddings (${NUM_BATCHES} batches of ${BATCH_SIZE})..."

for batch_num in $(seq 0 $((NUM_BATCHES - 1))); do
    OFFSET=$((batch_num * BATCH_SIZE))

    # Generate deterministic embeddings to temp file (too large for shell args)
    python3 -c "
import json, math, hashlib, struct

dim = $EMBEDDING_DIM
batch_size = $BATCH_SIZE
offset = $OFFSET

ids = []
embeddings = []
documents = []
metadatas = []

for i in range(batch_size):
    idx = offset + i
    ids.append(f'doc_{idx:06d}')

    # Deterministic embedding: hash-based, reproducible
    seed = hashlib.sha256(struct.pack('>I', idx)).digest()
    raw = []
    for d in range(dim):
        byte_idx = (d * 4) % len(seed)
        val = struct.unpack_from('>I', seed, byte_idx % (len(seed)-3))[0]
        raw.append((val ^ (d * 2654435761)) / 4294967295.0 * 2.0 - 1.0)
    # L2 normalize
    norm = math.sqrt(sum(x*x for x in raw))
    if norm > 0:
        raw = [x/norm for x in raw]
    embeddings.append(raw)

    # Deterministic metadata
    category = ['science', 'tech', 'art', 'history', 'math'][idx % 5]
    priority = idx % 10
    metadatas.append({'category': category, 'priority': priority, 'idx': idx})
    documents.append(f'Document number {idx} in category {category} with priority {priority}')

payload = {
    'ids': ids,
    'embeddings': embeddings,
    'documents': documents,
    'metadatas': metadatas
}
with open('/tmp/chroma_batch.json', 'w') as f:
    json.dump(payload, f)
"

    START_MS=$(now_ms)
    set +e
    HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d @/tmp/chroma_batch.json \
        "$API/collections/$COLLECTION_ID/add")
    EXIT_CODE=$?
    set -e
    END_MS=$(now_ms)

    if [ "$HTTP_CODE" != "201" ] && [ "$HTTP_CODE" != "200" ]; then
        EXIT_CODE=1
    fi
    record_latency "$START_MS" "$END_MS" "$EXIT_CODE"

    if [ $((batch_num % 20)) -eq 0 ]; then
        echo "[chroma-workload]   Batch $((batch_num+1))/$NUM_BATCHES inserted"
    fi
done

echo "[chroma-workload] Phase 2 complete: ${TOTAL_EMBEDDINGS} embeddings inserted"

# ===== Phase 3: Sequential similarity queries =====
echo "[chroma-workload] Phase 3: Running ${NUM_QUERIES} sequential similarity queries..."

for q in $(seq 1 $NUM_QUERIES); do
    python3 -c "
import json, math, hashlib, struct

dim = $EMBEDDING_DIM
q_idx = $q + 100000
seed = hashlib.sha256(struct.pack('>I', q_idx)).digest()
raw = []
for d in range(dim):
    byte_idx = (d * 4) % len(seed)
    val = struct.unpack_from('>I', seed, byte_idx % (len(seed)-3))[0]
    raw.append((val ^ (d * 2654435761)) / 4294967295.0 * 2.0 - 1.0)
norm = math.sqrt(sum(x*x for x in raw))
if norm > 0:
    raw = [x/norm for x in raw]

q = $q
if q % 3 == 0:
    payload = {
        'query_embeddings': [raw],
        'n_results': 10,
        'where': {'category': ['science', 'tech', 'art', 'history', 'math'][q % 5]}
    }
elif q % 3 == 1:
    payload = {
        'query_embeddings': [raw],
        'n_results': 20,
        'where': {'priority': {'\$gte': q % 5}}
    }
else:
    payload = {
        'query_embeddings': [raw],
        'n_results': 50
    }
with open('/tmp/chroma_seq_query.json', 'w') as f:
    json.dump(payload, f)
"

    START_MS=$(now_ms)
    set +e
    curl -sf -X POST -H "Content-Type: application/json" \
        -d @/tmp/chroma_seq_query.json \
        "$API/collections/$COLLECTION_ID/query" > /dev/null
    EXIT_CODE=$?
    set -e
    END_MS=$(now_ms)
    record_latency "$START_MS" "$END_MS" "$EXIT_CODE"
done

echo "[chroma-workload] Phase 3 complete"

# ===== Phase 4: Concurrent queries =====
echo "[chroma-workload] Phase 4: Running ${NUM_QUERIES} queries with concurrency=${CONCURRENT_QUERIES}..."

# Generate query payloads
for q in $(seq 1 $NUM_QUERIES); do
    python3 -c "
import json, math, hashlib, struct

dim = $EMBEDDING_DIM
q_idx = $q + 200000
seed = hashlib.sha256(struct.pack('>I', q_idx)).digest()
raw = []
for d in range(dim):
    byte_idx = (d * 4) % len(seed)
    val = struct.unpack_from('>I', seed, byte_idx % (len(seed)-3))[0]
    raw.append((val ^ (d * 2654435761)) / 4294967295.0 * 2.0 - 1.0)
norm = math.sqrt(sum(x*x for x in raw))
if norm > 0:
    raw = [x/norm for x in raw]

payload = {
    'query_embeddings': [raw],
    'n_results': 10,
    'where': {'category': ['science', 'tech', 'art', 'history', 'math'][$q % 5]}
}
print(json.dumps(payload))
" > "/tmp/chroma_query_${q}.json"
done

CONCURRENT_START_MS=$(now_ms)
seq 1 $NUM_QUERIES | xargs -P $CONCURRENT_QUERIES -I {} bash -c "
    curl -sf -X POST -H 'Content-Type: application/json' \
        -d @/tmp/chroma_query_{}.json \
        '$API/collections/$COLLECTION_ID/query' > /dev/null 2>&1 || echo 'FAIL {}'
" 2>&1 | grep -c '^FAIL' > /tmp/chroma_concurrent_failures.txt || echo "0" > /tmp/chroma_concurrent_failures.txt

CONCURRENT_END_MS=$(now_ms)
CONCURRENT_DURATION=$((CONCURRENT_END_MS - CONCURRENT_START_MS))
CONCURRENT_FAILURES=$(cat /tmp/chroma_concurrent_failures.txt)
TOTAL_REQUESTS=$((TOTAL_REQUESTS + NUM_QUERIES))
FAILED_REQUESTS=$((FAILED_REQUESTS + CONCURRENT_FAILURES))
echo "[chroma-workload] Phase 4 complete: ${NUM_QUERIES} concurrent queries in ${CONCURRENT_DURATION}ms (${CONCURRENT_FAILURES} failures)"

# ===== Phase 5: Get operations (metadata retrieval) =====
echo "[chroma-workload] Phase 5: Running 50 get operations..."

for g in $(seq 1 50); do
    python3 -c "
import json
offset = $g * 100
ids = [f'doc_{i:06d}' for i in range(offset, offset + 100)]
with open('/tmp/chroma_get.json', 'w') as f:
    json.dump({'ids': ids, 'include': ['embeddings', 'metadatas', 'documents']}, f)
"

    START_MS=$(now_ms)
    set +e
    curl -sf -X POST -H "Content-Type: application/json" \
        -d @/tmp/chroma_get.json \
        "$API/collections/$COLLECTION_ID/get" > /dev/null
    EXIT_CODE=$?
    set -e
    END_MS=$(now_ms)
    record_latency "$START_MS" "$END_MS" "$EXIT_CODE"
done

echo "[chroma-workload] Phase 5 complete"

# ===== Compute metrics =====
if [ -n "$LATENCIES" ]; then
    SORTED=$(echo "$LATENCIES" | tr ' ' '\n' | sort -n | grep -v '^$')
    COUNT=$(echo "$SORTED" | wc -l | tr -d ' ')
    P99_IDX=$(echo "$COUNT * 99 / 100" | bc)
    P99_IDX=${P99_IDX:-1}
    [ "$P99_IDX" -lt 1 ] && P99_IDX=1
    LATENCY_P99=$(echo "$SORTED" | sed -n "${P99_IDX}p")

    SUM=0
    for lat in $LATENCIES; do
        SUM=$((SUM + lat))
    done
    MEAN=$((SUM / COUNT))
else
    LATENCY_P99=0
    MEAN=0
fi

ERROR_RATE=$(echo "scale=4; $FAILED_REQUESTS / $TOTAL_REQUESTS" | bc 2>/dev/null || echo 0)

echo ""
echo "latency_p99_ms=${LATENCY_P99:-0}"
echo "latency_mean_ms=${MEAN:-0}"
echo "throughput_qps=${TOTAL_REQUESTS}"
echo "error_rate=${ERROR_RATE}"
echo "total_requests=${TOTAL_REQUESTS}"
echo "total_embeddings=${TOTAL_EMBEDDINGS}"
echo "embedding_dim=${EMBEDDING_DIM}"
echo "concurrent_queries=${CONCURRENT_QUERIES}"

# Cleanup temp files
rm -f /tmp/chroma_collection.json /tmp/chroma_query_*.json /tmp/chroma_concurrent_failures.txt
