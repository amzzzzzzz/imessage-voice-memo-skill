# Voice Memo iMessage Skill

Send native iMessage voice bubbles via BlueBubbles + OpenClaw TTS personas.

**Status:** ✅ Working

---

## Quick Start

```bash
./send-voice-memo.sh "Hey, how are you?" +1234567890
```

By default, the script reads `~/.openclaw/openclaw.json` and uses the active `messages.tts.provider` + `messages.tts.persona`. For Amz, that currently means Google Gemini TTS voice `Kore` with the `amz` persona prompt.

---

## Requirements

- macOS (for `afconvert`)
- BlueBubbles with Private API enabled
- BlueBubbles password
- `GEMINI_API_KEY` / `GOOGLE_API_KEY` for Gemini TTS, or `ELEVENLABS_API_KEY` for ElevenLabs fallback

## Environment Variables

Required in `~/.openclaw/.env`:

```bash
GEMINI_API_KEY=your-gemini-key
BLUEBUBBLES_PASSWORD=your-password
```

Optional:

```bash
VOICE_MEMO_TTS_PROVIDER=openclaw   # openclaw|google|elevenlabs
VOICE_MEMO_TTS_PERSONA=amz         # override OpenClaw active persona
VOICE_MEMO_DRY_RUN=1               # generate/convert but do not send
ELEVENLABS_API_KEY=your-key        # fallback provider only
```

---

## The Working Formula

```bash
# 1. TTS via OpenClaw persona config (Gemini/Kore by default for Amz)
# 2. Convert: afconvert -f caff -d opus@24000 -c 1
# 3. Send with:
#    - chatGuid: any;-;+PHONE (NOT iMessage;-;)
#    - method: private-api
#    - isAudioMessage: true
```

---

## Cost

Depends on active TTS provider. Gemini TTS is now preferred for Amz because it matches Call Amz v2 and avoids ElevenLabs subscription requirements.
