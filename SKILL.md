# Voice Memo iMessage Skill

Send native iMessage voice bubbles via BlueBubbles + ElevenLabs TTS.

**Status:** ✅ Working

---

## Quick Start

```bash
./send-voice-memo.sh "Hey, how are you?" +1234567890
```

---

## Requirements

- macOS (for `afconvert`)
- BlueBubbles with Private API enabled
- ElevenLabs API key

## Environment Variables

Required in `~/.openclaw/.env`:
```bash
ELEVENLABS_API_KEY=your-key
BLUEBUBBLES_PASSWORD=your-password
```

---

## The Working Formula

```bash
# 1. TTS → MP3
# 2. Convert: afconvert -f caff -d opus@24000 -c 1
# 3. Send with:
#    - chatGuid: any;-;+PHONE (NOT iMessage;-;)
#    - method: private-api
#    - isAudioMessage: true
```

---

## Performance

~0.4 seconds end-to-end.

---

## Cost

~$0.04 per 30-second message (ElevenLabs).
