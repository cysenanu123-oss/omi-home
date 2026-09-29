#!/bin/bash
# Kill anything on port 3000
fuser -k 3000/tcp 2>/dev/null || true
sleep 1

# Load key from Backend-Rust/.env
ENV_FILE="$(dirname "$0")/../Backend-Rust/.env"
if [ -f "$ENV_FILE" ]; then
    KEY=$(grep "^GEMINI_API_KEY=" "$ENV_FILE" | cut -d= -f2-)
    if [ -n "$KEY" ]; then
        export GEMINI_API_KEY="$KEY"
    fi
fi

echo "Starting Ama with GEMINI key: ${GEMINI_API_KEY:0:10}..."
exec "$(dirname "$0")/.venv/bin/python" "$(dirname "$0")/server.py"
