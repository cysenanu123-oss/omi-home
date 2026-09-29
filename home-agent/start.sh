#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo ""
echo "══════════════════════════════════════"
echo "  🏠  Ama — Personal AI Assistant"
echo "══════════════════════════════════════"

# ─── Check / create venv ───────────────────────────────────────────────────────
if [ ! -d ".venv" ]; then
    echo "Setting up Python environment..."
    python3 -m venv .venv
    .venv/bin/pip install -q --upgrade pip
    .venv/bin/pip install -q -r requirements.txt
    echo "✓ Environment ready"
fi

# ─── Gemini API key ────────────────────────────────────────────────────────────
if [ -z "$GEMINI_API_KEY" ]; then
    # Try loading from Backend-Rust/.env
    ENV_FILE="$SCRIPT_DIR/../Backend-Rust/.env"
    if [ -f "$ENV_FILE" ]; then
        KEY=$(grep "^GEMINI_API_KEY=" "$ENV_FILE" | cut -d= -f2- | tr -d '"' | tr -d "'")
        if [ -n "$KEY" ]; then
            export GEMINI_API_KEY="$KEY"
            echo "✓ Loaded GEMINI_API_KEY from Backend-Rust/.env"
        fi
    fi
fi

if [ -z "$GEMINI_API_KEY" ]; then
    echo ""
    echo "  ⚠️  GEMINI_API_KEY is not set."
    echo "  Get a FREE key at: https://aistudio.google.com/"
    echo ""
    echo "  Then either:"
    echo "    export GEMINI_API_KEY=your_key && ./start.sh"
    echo "    OR add GEMINI_API_KEY=your_key to Backend-Rust/.env"
    echo ""
fi

# ─── Print network info ─────────────────────────────────────────────────────────
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")
echo ""
echo "  Open on this machine: http://localhost:3000"
echo "  Open on phone/tablet: http://$LOCAL_IP:3000"
echo ""
echo "  Say 'Hey Ama' to wake her up!"
echo "══════════════════════════════════════"
echo ""

# ─── Start server ──────────────────────────────────────────────────────────────
exec .venv/bin/python server.py
