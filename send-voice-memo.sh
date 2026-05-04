#!/bin/bash
#
# send-voice-memo.sh
# Send native iMessage voice bubbles via BlueBubbles + configurable TTS.
#
# Usage: ./send-voice-memo.sh "Your message" +1234567890
#
# Requirements:
#   - macOS (for afconvert)
#   - BlueBubbles running locally with Private API enabled
#   - BLUEBUBBLES_PASSWORD in environment or ~/.openclaw/.env
#   - For Google/Gemini TTS: GEMINI_API_KEY or GOOGLE_API_KEY
#   - For ElevenLabs fallback: ELEVENLABS_API_KEY
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

# Load environment from .env if exists. These variables intentionally remain
# local shell variables; provider subprocess calls receive only the keys they need.
[[ -f ~/.openclaw/.env ]] && source ~/.openclaw/.env

# OpenClaw TTS settings
OPENCLAW_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$HOME/.openclaw/openclaw.json}"
VOICE_MEMO_TTS_PROVIDER="${VOICE_MEMO_TTS_PROVIDER:-openclaw}" # openclaw|google|elevenlabs
VOICE_MEMO_TTS_PERSONA="${VOICE_MEMO_TTS_PERSONA:-}"
VOICE_MEMO_DRY_RUN="${VOICE_MEMO_DRY_RUN:-0}"

# Google/Gemini settings. Defaults mirror OpenClaw's Google TTS provider.
GEMINI_API_KEY="${GEMINI_API_KEY:-}"
GOOGLE_API_KEY="${GOOGLE_API_KEY:-}"
GOOGLE_TTS_MODEL="${GOOGLE_TTS_MODEL:-}"
GOOGLE_TTS_VOICE="${GOOGLE_TTS_VOICE:-}"

# ElevenLabs settings retained as backwards-compatible fallback.
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
    echo "  BLUEBUBBLES_PASSWORD    - Required: BlueBubbles server password"
    echo "  VOICE_MEMO_TTS_PROVIDER - Optional: openclaw|google|elevenlabs (default: openclaw)"
    echo "  OPENCLAW_CONFIG_PATH    - Optional: OpenClaw config path (default: ~/.openclaw/openclaw.json)"
    echo "  VOICE_MEMO_TTS_PERSONA  - Optional: Override OpenClaw messages.tts.persona"
    echo "  GEMINI_API_KEY          - Required for Google/Gemini TTS"
    echo "  GOOGLE_API_KEY          - Alternative to GEMINI_API_KEY"
    echo "  ELEVENLABS_API_KEY      - Required for ElevenLabs fallback"
    echo "  ELEVENLABS_VOICE_ID     - Optional: ElevenLabs voice ID"
    echo "  ELEVENLABS_MODEL_ID     - Optional: ElevenLabs model"
    echo "  BLUEBUBBLES_URL         - Optional: Server URL (default: http://127.0.0.1:1234)"
    echo "  VOICE_MEMO_DRY_RUN=1    - Generate/convert audio but do not send"
    exit 1
}

[[ -z "${1:-}" ]] && usage
[[ -z "${2:-}" ]] && { echo "❌ Error: Phone number required"; usage; }
[[ -z "$BLUEBUBBLES_PASSWORD" && "$VOICE_MEMO_DRY_RUN" != "1" ]] && { echo "❌ Error: BLUEBUBBLES_PASSWORD not set"; exit 1; }

TEXT="$1"
RECIPIENT="$2"

# Generate unique filenames
TIMESTAMP=$(date +%s%N)
AUDIO_FILE="$TMP_DIR/voice_${TIMESTAMP}"
CAF_FILE="$TMP_DIR/voice_${TIMESTAMP}.caf"

# Cleanup on exit
cleanup() { rm -f "$AUDIO_FILE" "$AUDIO_FILE".* "$CAF_FILE" 2>/dev/null; }
trap cleanup EXIT

# ============================================================================
# Helpers
# ============================================================================

resolve_openclaw_tts_provider() {
    if [[ "$VOICE_MEMO_TTS_PROVIDER" != "openclaw" ]]; then
        printf '%s\n' "$VOICE_MEMO_TTS_PROVIDER"
        return
    fi

    python3 - "$OPENCLAW_CONFIG_PATH" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1]).expanduser()
try:
    cfg = json.loads(path.read_text())
    provider = (cfg.get("messages", {}).get("tts", {}) or {}).get("provider") or "elevenlabs"
except Exception:
    provider = "elevenlabs"
print(provider)
PY
}

render_google_tts() {
    local output_wav="$1"

    GEMINI_API_KEY="$GEMINI_API_KEY" \
    GOOGLE_API_KEY="$GOOGLE_API_KEY" \
    GOOGLE_TTS_MODEL="$GOOGLE_TTS_MODEL" \
    GOOGLE_TTS_VOICE="$GOOGLE_TTS_VOICE" \
    VOICE_MEMO_TTS_PERSONA="$VOICE_MEMO_TTS_PERSONA" \
    python3 - "$OPENCLAW_CONFIG_PATH" "$TEXT" "$output_wav" <<'PY'
import base64
import json
import os
import struct
import sys
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_MODEL = "gemini-3.1-flash-tts-preview"
DEFAULT_VOICE = "Kore"
DEFAULT_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"
SAMPLE_RATE = 24000
CHANNELS = 1
BITS_PER_SAMPLE = 16

config_path, text, output_wav = sys.argv[1:4]


def clean(value):
    if isinstance(value, str):
        value = value.strip()
        return value or None
    return None


def load_config(path):
    try:
        return json.loads(Path(path).expanduser().read_text())
    except Exception:
        return {}


def merge(*records):
    out = {}
    for record in records:
        if isinstance(record, dict):
            out.update({k: v for k, v in record.items() if v is not None})
    return out


def normalize_model(model):
    model = clean(model)
    if not model:
        return DEFAULT_MODEL
    if model.startswith("google/"):
        model = model[len("google/"):]
    if model == "gemini-3.1-flash-tts":
        return DEFAULT_MODEL
    return model


def provider_api_key(value):
    # Standalone skill keeps secret handling simple: env vars first, then plain
    # string config values only. OpenClaw SecretRef objects are intentionally not
    # resolved here.
    env_key = clean(os.environ.get("GEMINI_API_KEY")) or clean(os.environ.get("GOOGLE_API_KEY"))
    if env_key:
        return env_key
    return clean(value) if isinstance(value, str) else None


def section_text(value):
    value = clean(value.replace("\r\n", "\n").replace("\r", "\n")) if isinstance(value, str) else None
    if not value:
        return None
    return "".join(ch for ch in value if ord(ch) >= 32 or ch in "\n\t")


def section_list(values):
    if not isinstance(values, list):
        return []
    return [v for v in (section_text(x) for x in values) if v]


def render_audio_profile(transcript, persona, persona_prompt):
    prompt = persona.get("prompt", {}) if isinstance(persona, dict) else {}
    label = section_text(persona.get("label") or persona.get("id")) if isinstance(persona, dict) else None
    profile = section_text(prompt.get("profile"))
    scene = section_text(prompt.get("scene"))
    sample_context = section_text(prompt.get("sampleContext"))
    style = section_text(prompt.get("style"))
    accent = section_text(prompt.get("accent"))
    pacing = section_text(prompt.get("pacing"))
    constraints = section_list(prompt.get("constraints"))
    persona_prompt = section_text(persona_prompt)

    sections = [
        "Synthesize speech from the TRANSCRIPT section only. Use the other sections only\n"
        "as performance direction. Do not read section titles, notes, labels, or\n"
        "configuration aloud."
    ]
    if label or profile:
        sections.append("\n".join(x for x in [f"# AUDIO PROFILE: {label or 'voice'}", profile] if x))
    if scene:
        sections.append("## THE SCENE\n" + scene)

    notes = []
    if style:
        notes.append("Style: " + style)
    if accent:
        notes.append("Accent: " + accent)
    if pacing:
        notes.append("Pacing: " + pacing)
    if constraints:
        notes.append("Constraints:\n" + "\n".join(f"- {item}" for item in constraints))
    if persona_prompt:
        notes.append("Provider notes:\n" + persona_prompt)
    if notes:
        sections.append("### DIRECTOR'S NOTES\n" + "\n".join(notes))
    if sample_context:
        sections.append("### SAMPLE CONTEXT\n" + sample_context)
    sections.append("### TRANSCRIPT\n" + transcript.strip())
    return "\n\n".join(sections)


def wav_bytes_from_pcm16(pcm):
    byte_rate = SAMPLE_RATE * CHANNELS * (BITS_PER_SAMPLE // 8)
    block_align = CHANNELS * (BITS_PER_SAMPLE // 8)
    header = b"".join([
        b"RIFF",
        struct.pack("<I", 36 + len(pcm)),
        b"WAVEfmt ",
        struct.pack("<IHHIIHH", 16, 1, CHANNELS, SAMPLE_RATE, byte_rate, block_align, BITS_PER_SAMPLE),
        b"data",
        struct.pack("<I", len(pcm)),
    ])
    return header + pcm

cfg = load_config(config_path)
tts = (cfg.get("messages", {}).get("tts", {}) or {})
providers = tts.get("providers", {}) if isinstance(tts.get("providers"), dict) else {}
personas = tts.get("personas", {}) if isinstance(tts.get("personas"), dict) else {}
persona_id = clean(os.environ.get("VOICE_MEMO_TTS_PERSONA")) or clean(tts.get("persona"))
persona = personas.get(persona_id, {}) if persona_id else {}
persona_provider = ((persona.get("providers") or {}).get("google") if isinstance(persona, dict) else {}) or {}
global_provider = providers.get("google", {}) if isinstance(providers.get("google"), dict) else {}
provider = merge(global_provider, persona_provider)

api_key = provider_api_key(provider.get("apiKey"))
if not api_key:
    raise SystemExit("Google/Gemini API key missing. Set GEMINI_API_KEY or GOOGLE_API_KEY.")

model = normalize_model(clean(os.environ.get("GOOGLE_TTS_MODEL")) or provider.get("model"))
voice = clean(os.environ.get("GOOGLE_TTS_VOICE")) or clean(provider.get("voiceName") or provider.get("voice")) or DEFAULT_VOICE
base_url = clean(provider.get("baseUrl")) or DEFAULT_BASE_URL
prompt_template = clean(provider.get("promptTemplate"))
persona_prompt = clean(provider.get("personaPrompt"))
audio_profile = clean(provider.get("audioProfile"))
speaker_name = clean(provider.get("speakerName"))

speech_text = text
if prompt_template == "audio-profile-v1" or persona_prompt:
    speech_text = render_audio_profile(text, persona if isinstance(persona, dict) else {}, persona_prompt)
elif audio_profile or speaker_name:
    speech_text = "\n\n".join(x for x in [audio_profile, f"Speaker name: {speaker_name}" if speaker_name else None, text] if x)

body = {
    "contents": [{"role": "user", "parts": [{"text": speech_text}]}],
    "generationConfig": {
        "responseModalities": ["AUDIO"],
        "speechConfig": {"voiceConfig": {"prebuiltVoiceConfig": {"voiceName": voice}}},
    },
}
url = f"{base_url.rstrip('/')}/models/{model}:generateContent"
req = urllib.request.Request(
    url,
    data=json.dumps(body).encode("utf-8"),
    headers={"Content-Type": "application/json", "x-goog-api-key": api_key},
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=60) as res:
        payload = json.loads(res.read().decode("utf-8"))
except urllib.error.HTTPError as e:
    detail = e.read().decode("utf-8", "replace")[:1000]
    raise SystemExit(f"Google TTS failed (HTTP {e.code}): {detail}")

pcm = None
for candidate in payload.get("candidates", []):
    for part in (candidate.get("content", {}) or {}).get("parts", []):
        inline = part.get("inlineData") or part.get("inline_data") or {}
        data = inline.get("data")
        if data:
            pcm = base64.b64decode(data)
            break
    if pcm:
        break
if not pcm:
    raise SystemExit("Google TTS response missing audio data")

Path(output_wav).write_bytes(wav_bytes_from_pcm16(pcm))
PY
}

render_elevenlabs_tts() {
    local output_mp3="$1"
    [[ -z "$ELEVENLABS_API_KEY" ]] && { echo "❌ Error: ELEVENLABS_API_KEY not set"; exit 1; }

    # Escape text for JSON (handle quotes and special chars)
    TEXT_JSON=$(printf '%s' "$TEXT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

    HTTP_CODE=$(curl -s -w "%{http_code}" -X POST \
        "https://api.elevenlabs.io/v1/text-to-speech/$VOICE_ID" \
        -H "xi-api-key: $ELEVENLABS_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"text\": $TEXT_JSON, \"model_id\": \"$MODEL_ID\", \"voice_settings\": {\"stability\": 0.5, \"similarity_boost\": 0.75}}" \
        -o "$output_mp3")

    [[ "$HTTP_CODE" != "200" ]] && { echo "❌ ElevenLabs TTS failed (HTTP $HTTP_CODE)"; exit 1; }
}

# ============================================================================
# Step 1: Generate TTS
# ============================================================================

TTS_PROVIDER=$(resolve_openclaw_tts_provider)
case "$TTS_PROVIDER" in
    google)
        AUDIO_FILE="$AUDIO_FILE.wav"
        echo "🎤 Generating voice with OpenClaw persona via Gemini/Kore..."
        render_google_tts "$AUDIO_FILE"
        ;;
    elevenlabs)
        AUDIO_FILE="$AUDIO_FILE.mp3"
        echo "🎤 Generating voice with ElevenLabs..."
        render_elevenlabs_tts "$AUDIO_FILE"
        ;;
    *)
        echo "❌ Unsupported TTS provider: $TTS_PROVIDER (expected google or elevenlabs)"
        exit 1
        ;;
esac

[[ ! -s "$AUDIO_FILE" ]] && { echo "❌ TTS returned empty file"; exit 1; }

# ============================================================================
# Step 2: Convert to Opus CAF @ 24kHz (iMessage native format)
# ============================================================================

echo "🔄 Converting..."

# Opus @ 24kHz in CAF container — the EXACT format iMessage expects
afconvert "$AUDIO_FILE" "$CAF_FILE" -f caff -d opus@24000 -c 1 2>/dev/null \
    || { echo "❌ Conversion failed"; exit 1; }

[[ ! -s "$CAF_FILE" ]] && { echo "❌ Conversion produced empty file"; exit 1; }

if [[ "$VOICE_MEMO_DRY_RUN" == "1" ]]; then
    echo "✅ Dry run complete: generated native voice-bubble CAF at $CAF_FILE"
    trap - EXIT
    exit 0
fi

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
