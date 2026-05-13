#!/usr/bin/env bash
# =============================================================================
# load-test.sh  —  Generate realistic traffic to populate dashboards & alerts
# =============================================================================
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
DURATION="${DURATION:-300}"   # seconds to run
RPS="${RPS:-20}"              # requests per second

echo "🔥 Load test starting"
echo "   Target:   $BASE_URL"
echo "   Duration: ${DURATION}s"
echo "   RPS:      $RPS"
echo ""

# Check dependencies
for cmd in curl bc; do
  command -v "$cmd" &>/dev/null || { echo "Missing: $cmd"; exit 1; }
done

ENDPOINTS=(
  "GET /api/products"
  "GET /api/users/1"
  "GET /api/users/2"
  "GET /api/users/3"
  "POST /api/orders"
  "GET /api/reports"
  "GET /health"
  # Intentionally invalid to generate 404s
  "GET /api/nonexistent"
)

WEIGHTS=(30 15 15 10 15 5 5 5)   # percentage weight for each endpoint

TOTAL_REQUESTS=0
START_TIME=$(date +%s)
END_TIME=$((START_TIME + DURATION))

make_request() {
  local method=$1
  local path=$2

  case "$method" in
    POST)
      curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d '{"item":"widget","quantity":1}' \
        --max-time 5 \
        "$BASE_URL$path" 2>/dev/null || echo "000"
      ;;
    *)
      curl -s -o /dev/null -w "%{http_code}" \
        --max-time 5 \
        "$BASE_URL$path" 2>/dev/null || echo "000"
      ;;
  esac
}

pick_weighted_endpoint() {
  local rand=$((RANDOM % 100))
  local cumulative=0

  for i in "${!WEIGHTS[@]}"; do
    cumulative=$((cumulative + WEIGHTS[i]))
    if [[ $rand -lt $cumulative ]]; then
      echo "${ENDPOINTS[$i]}"
      return
    fi
  done
  echo "${ENDPOINTS[0]}"
}

# Traffic loop
INTERVAL=$(echo "scale=4; 1 / $RPS" | bc)

while [[ $(date +%s) -lt $END_TIME ]]; do
  ENDPOINT=$(pick_weighted_endpoint)
  METHOD=$(echo "$ENDPOINT" | awk '{print $1}')
  PATH=$(echo "$ENDPOINT" | awk '{print $2}')

  STATUS=$(make_request "$METHOD" "$PATH")
  TOTAL_REQUESTS=$((TOTAL_REQUESTS + 1))

  ELAPSED=$(($(date +%s) - START_TIME))
  REMAINING=$((END_TIME - $(date +%s)))

  printf "\r  Requests: %6d | Elapsed: %3ds | Remaining: %3ds | Last: %s %s → %s" \
    "$TOTAL_REQUESTS" "$ELAPSED" "$REMAINING" "$METHOD" "$PATH" "$STATUS"

  sleep "$INTERVAL" 2>/dev/null || true
done

echo ""
echo ""
echo "✅ Load test complete!"
echo "   Total requests: $TOTAL_REQUESTS"
echo "   Duration: ${DURATION}s"
echo "   Avg RPS: $(echo "scale=2; $TOTAL_REQUESTS / $DURATION" | bc)"
echo ""
echo "📊 Check your dashboards:"
echo "   Grafana:     http://localhost:3000"
echo "   Prometheus:  http://localhost:9090"
