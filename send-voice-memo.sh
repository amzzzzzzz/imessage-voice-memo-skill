#!/bin/bash
#
# send-voice-memo.sh
# Send native iMessage voice bubbles via BlueBubbles + ElevenLabs TTS
#
# Usage: ./send-voice-memo.sh "Your message" +1234567890
#
# Requirements:
#   - macOS (for afconvert)
#   - BlueBubbles running locally with Private API enabled
#   - ELEVENLABS_API_KEY in environment or ~/.openclaw/.env
#   - BLUEBUBBLES_PASSWORD in environment or ~/.openclaw/.env
#
# Working formula discovered 2026-02-19:
#   - Audio: Opus CAF @ 24kHz (pre-converted)
#   - chatGuid: any;-;+PHONE (NOT iMessage;-;)
#   - method: private-api (REQUIRED for native bubble)
#   - isAudioMessage: true

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

# Load environment from .env if exists
[[ -f ~/.openclaw/.env ]] && source ~/.openclaw/.env

# ElevenLabs settings
ELEVENLABS_API_KEY="${ELEVENLABS_API_KEY:-}"
VOICE_ID="${ELEVENLABS_VOICE_ID:-21m00Tcm4TlvDq8ikWAM}"  # Rachel
MODEL_ID="${ELEVENLABS_MODEL_ID:-eleven_turbo_v2_5}"      # Turbo (fastest)

# BlueBubbles settings
BLUEBUBBLES_URL="${BLUEBUBBLES_URL:-http://127.0.0.1:1234}"
BLUEBUBBLES_PASSWORD="${BLUEBUBBLES_PASSWORD:-}"

# Temp directory
TMP_DIR="${TMPDIR:-/tmp}"

# ============================================================================
# Input validation
# ============================================================================

usage() {
    echo "Usage: $0 \"message text\" +1234567890"
    echo ""
    echo "Environment variables:"
    echo "  ELEVENLABS_API_KEY    - Required: ElevenLabs API key"
    echo "  BLUEBUBBLES_PASSWORD  - Required: BlueBubbles server password"
    echo "  ELEVENLABS_VOICE_ID   - Optional: Voice ID (default: Rachel)"
    echo "  ELEVENLABS_MODEL_ID   - Optional: Model (default: eleven_turbo_v2_5)"
    echo "  BLUEBUBBLES_URL       - Optional: Server URL (default: http://127.0.0.1:1234)"
    exit 1
}

[[ -z "${1:-}" ]] && usage
[[ -z "${2:-}" ]] && { echo "❌ Error: Phone number required"; usage; }
[[ -z "$ELEVENLABS_API_KEY" ]] && { echo "❌ Error: ELEVENLABS_API_KEY not set"; exit 1; }
[[ -z "$BLUEBUBBLES_PASSWORD" ]] && { echo "❌ Error: BLUEBUBBLES_PASSWORD not set"; exit 1; }

TEXT="$1"
RECIPIENT="$2"

# Generate unique filenames
TIMESTAMP=$(date +%s%N)
MP3_FILE="$TMP_DIR/voice_${TIMESTAMP}.mp3"
CAF_FILE="$TMP_DIR/voice_${TIMESTAMP}.caf"

# Cleanup on exit
cleanup() { rm -f "$MP3_FILE" "$CAF_FILE" 2>/dev/null; }
trap cleanup EXIT

# ============================================================================
# Step 1: Generate TTS (ElevenLabs)
# ============================================================================

echo "🎤 Generating voice..."

# Escape text for JSON (handle quotes and special chars)
TEXT_JSON=$(printf '%s' "$TEXT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

HTTP_CODE=$(curl -s -w "%{http_code}" -X POST \
    "https://api.elevenlabs.io/v1/text-to-speech/$VOICE_ID" \
    -H "xi-api-key: $ELEVENLABS_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"text\": $TEXT_JSON, \"model_id\": \"$MODEL_ID\", \"voice_settings\": {\"stability\": 0.5, \"similarity_boost\": 0.75}}" \
    -o "$MP3_FILE")

[[ "$HTTP_CODE" != "200" ]] && { echo "❌ TTS failed (HTTP $HTTP_CODE)"; exit 1; }
[[ ! -s "$MP3_FILE" ]] && { echo "❌ TTS returned empty file"; exit 1; }

# ============================================================================
# Step 2: Convert to Opus CAF @ 24kHz (iMessage native format)
# ============================================================================

echo "🔄 Converting..."

# Opus @ 24kHz in CAF container — the EXACT format iMessage expects
afconvert "$MP3_FILE" "$CAF_FILE" -f caff -d opus@24000 -c 1 2>/dev/null \
    || { echo "❌ Conversion failed"; exit 1; }

[[ ! -s "$CAF_FILE" ]] && { echo "❌ Conversion produced empty file"; exit 1; }

# ============================================================================
# Step 3: Send via BlueBubbles (working formula)
# ============================================================================

echo "📱 Sending..."

# URL-encode password for special characters
PASSWORD_ENC=$(printf '%s' "$BLUEBUBBLES_PASSWORD" | xxd -plain | tr -d '\n' | sed 's/\(..\)/%\1/g')

# CRITICAL: chatGuid format is "any;-;+PHONE" — NOT "iMessage;-;+PHONE"
CHAT_GUID="any;-;$RECIPIENT"

# Send with the EXACT parameters that produce native voice bubbles
RESPONSE=$(curl -s -X POST \
    "$BLUEBUBBLES_URL/api/v1/message/attachment?password=$PASSWORD_ENC" \
    -F "attachment=@$CAF_FILE;type=audio/x-caf" \
    --form-string "chatGuid=$CHAT_GUID" \
    -F "name=voice.caf" \
    -F "tempGuid=temp-$TIMESTAMP" \
    -F "isAudioMessage=true" \
    -F "method=private-api" \
    --max-time 30)

# Verify success
if echo "$RESPONSE" | grep -q '"isAudioMessage":true'; then
    echo "✅ Voice memo sent!"
    exit 0
elif echo "$RESPONSE" | grep -q '"status":200'; then
    echo "⚠️  Sent (but may be attachment, not voice bubble)"
    exit 0
else
    echo "❌ Send failed"
    echo "$RESPONSE" | head -c 500
    exit 1
fi
