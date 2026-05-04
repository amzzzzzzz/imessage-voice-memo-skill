# iMessage Voice Memo Skill for OpenClaw

Send **native iMessage voice bubbles** (not file attachments) via BlueBubbles.

![Voice Bubble Demo](https://img.shields.io/badge/Status-Working-brightgreen)
![Platform](https://img.shields.io/badge/Platform-macOS-blue)
![License](https://img.shields.io/badge/License-MIT-yellow)

## Features

- 🎤 **Native voice bubbles** — Appears with waveform, tap to play (not as file attachment)
- 🗣️ **OpenClaw TTS personas** — Uses your active `messages.tts.persona` by default
- 🔊 **Gemini/Kore + ElevenLabs support** — Google Gemini TTS for the current Amz voice, ElevenLabs as fallback/back-compat
- ⚡ **Fast enough for voice notes** — Keeps native iMessage voice-bubble delivery while letting the TTS provider vary
- 🔄 **Bidirectional** — Send and receive voice memos via iMessage

## Requirements

- **macOS** (for `afconvert`)
- **BlueBubbles Server** running locally with **Private API enabled**
- **Google Gemini API key** (`GEMINI_API_KEY` or `GOOGLE_API_KEY`) for OpenClaw/Gemini TTS, or **ElevenLabs API key** for ElevenLabs fallback

## Installation

1. Clone this repo:
```bash
git clone https://github.com/amzzzzzzz/imessage-voice-memo-skill.git
cd imessage-voice-memo-skill
```

2. Copy the skill to your OpenClaw workspace:
```bash
cp -r . ~/.openclaw/workspace/skills/voice-memo-imessage/
```

3. Add required environment variables to `~/.openclaw/.env`:
```bash
GEMINI_API_KEY=your-gemini-key-here
BLUEBUBBLES_PASSWORD=your-bluebubbles-password
# Optional ElevenLabs fallback:
# ELEVENLABS_API_KEY=your-key-here
```

4. Make the script executable:
```bash
chmod +x ~/.openclaw/workspace/skills/voice-memo-imessage/send-voice-memo.sh
```

## Usage

### Command Line
```bash
./send-voice-memo.sh "Hey, how's it going?" +1234567890
```

### From OpenClaw Agent
The agent can invoke this skill to send voice responses.

## How It Works

### The Working Formula

After extensive debugging, we discovered the exact parameters needed for native voice bubbles:

```bash
# 1. Generate TTS
# Default: read ~/.openclaw/openclaw.json and use messages.tts.provider/persona
# Current Amz config: Google Gemini TTS + Kore + persona prompt

# 2. Convert to Opus CAF @ 24kHz (REQUIRED format for iMessage)
afconvert input.mp3 output.caf -f caff -d opus@24000 -c 1

# 3. Send via BlueBubbles with EXACT parameters
curl -X POST ".../api/v1/message/attachment" \
  --form-string "chatGuid=any;-;+PHONE" \  # NOT iMessage;-; !
  -F "method=private-api" \                 # REQUIRED
  -F "isAudioMessage=true" \                # REQUIRED
  -F "attachment=@output.caf;type=audio/x-caf"
```

### Critical Parameters

| Parameter | Correct Value | Wrong Value | Effect |
|-----------|--------------|-------------|--------|
| chatGuid | `any;-;+PHONE` | `iMessage;-;+PHONE` | Wrong = API timeouts |
| method | `private-api` | omitted or `apple-script` | Wrong = file attachment instead of voice bubble |
| Audio format | Opus @ 24kHz | PCM @ 44.1kHz | Wrong = 0-second unplayable audio |

### Why Pre-Conversion?

BlueBubbles' built-in conversion uses **PCM @ 44.1kHz**, but iMessage voice memos require **Opus @ 24kHz**. Pre-converting with `afconvert` bypasses this issue.

## Performance

| Step | Time | Notes |
|------|------|-------|
| Step | Time | Notes |
|------|------|-------|
| TTS | provider-dependent | Gemini/OpenClaw persona by default; ElevenLabs fallback supported |
| Convert | ~0.04s | Native macOS afconvert |
| Send | ~0.15s | Local BlueBubbles API |
| **Total** | provider-dependent | Still optimized around local BlueBubbles + native conversion |

## Configuration

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `BLUEBUBBLES_PASSWORD` | Yes | - | BlueBubbles server password |
| `VOICE_MEMO_TTS_PROVIDER` | No | `openclaw` | `openclaw`, `google`, or `elevenlabs` |
| `OPENCLAW_CONFIG_PATH` | No | `~/.openclaw/openclaw.json` | Config to read `messages.tts` from |
| `VOICE_MEMO_TTS_PERSONA` | No | active OpenClaw persona | Override persona id, e.g. `amz` |
| `GEMINI_API_KEY` / `GOOGLE_API_KEY` | For Google | - | Gemini TTS API key |
| `GOOGLE_TTS_MODEL` | No | OpenClaw/default | Override Gemini TTS model |
| `GOOGLE_TTS_VOICE` | No | OpenClaw/default | Override Gemini voice, e.g. `Kore` |
| `ELEVENLABS_API_KEY` | For ElevenLabs | - | ElevenLabs API key fallback |
| `ELEVENLABS_VOICE_ID` | No | `21m00Tcm4TlvDq8ikWAM` | ElevenLabs voice ID |
| `ELEVENLABS_MODEL_ID` | No | `eleven_turbo_v2_5` | ElevenLabs model |
| `BLUEBUBBLES_URL` | No | `http://127.0.0.1:1234` | BlueBubbles server URL |
| `VOICE_MEMO_DRY_RUN` | No | `0` | `1` generates/converts audio but does not send |

### Voice Options

Default mode is **OpenClaw persona-aware**: the script reads `messages.tts` from `~/.openclaw/openclaw.json`, including the active `persona` and provider-specific voice settings. For our current Amz setup, that means **Google Gemini TTS + Kore + the `amz` persona prompt**.

To force providers:

```bash
VOICE_MEMO_TTS_PROVIDER=google ./send-voice-memo.sh "Hey girl hey" +1234567890
VOICE_MEMO_TTS_PROVIDER=elevenlabs ./send-voice-memo.sh "Fallback test" +1234567890
```

To test without sending an iMessage:

```bash
VOICE_MEMO_DRY_RUN=1 ./send-voice-memo.sh "Tiny voice test" +1234567890
```

## Cost

Cost depends on the active TTS provider. Gemini TTS is preferred for Amz because it matches Call Amz v2 and avoids ElevenLabs subscription requirements. ElevenLabs fallback still works when a paid ElevenLabs API plan is active.

## Troubleshooting

### Voice memo arrives as file attachment (not voice bubble)
- Ensure `method=private-api` is set
- Ensure BlueBubbles Private API is enabled and helper is connected
- Check API response for `"isAudioMessage": true`

### API times out
- Use `any;-;+PHONE` format (NOT `iMessage;-;+PHONE`)
- Restart BlueBubbles if consistently slow

### Audio is 0 seconds / unplayable
- Ensure pre-conversion to Opus @ 24kHz
- Verify format: `afinfo output.caf` should show `opus @ 24000 Hz`

## Related

- [BlueBubbles](https://bluebubbles.app) — iMessage bridge for non-Apple devices
- [ElevenLabs](https://elevenlabs.io) — AI voice synthesis
- [OpenClaw](https://github.com/openclaw/openclaw) — AI agent framework

## License

MIT License — see [LICENSE](LICENSE)

## Credits

Developed by Amy & Amz while debugging BlueBubbles voice memos at 4am. 🌙

Special thanks to the BlueBubbles team and the OpenClaw community.
