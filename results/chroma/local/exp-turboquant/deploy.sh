#!/bin/bash
# Deploy Chroma with TurboQuant — toggle quantization via env var
# Usage: ./deploy.sh [BITS]
#   ./deploy.sh 0  → baseline (float32)
#   ./deploy.sh 4  → TurboQuant 4-bit
# Same binary, different env var — the cleanest possible A/B comparison
set -euo pipefail

QUANT_BITS="${1:-4}"  # Default to TurboQuant
PORT=8000

echo "=== DEPLOY: Chroma TurboQuant (QUANTIZATION_BITS=$QUANT_BITS) ==="

# 1. Clean up previous
docker rm -f autoopt-chroma 2>/dev/null || true

# 2. Deploy with quantization env var
echo "[deploy] Starting container with CHROMA_QUANTIZATION_BITS=$QUANT_BITS..."
docker run -d --name autoopt-chroma \
  -p "$PORT:8000" \
  -e IS_PERSISTENT=1 \
  -e ANONYMIZED_TELEMETRY=FALSE \
  -e CHROMA_QUANTIZATION_BITS="$QUANT_BITS" \
  autoopt-chroma:turboquant

# 3. Wait for ready
echo "[deploy] Waiting for service..."
for i in $(seq 1 30); do
  curl -sf "http://localhost:$PORT/api/v2/heartbeat" > /dev/null 2>&1 && break
  sleep 1
done

curl -sf "http://localhost:$PORT/api/v2/heartbeat" || { echo "[deploy] FAILED"; exit 1; }
echo "=== DEPLOY COMPLETE: localhost:$PORT (QUANTIZATION_BITS=$QUANT_BITS) ==="
