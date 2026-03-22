---
name: stt
description: Transcribe audio files to text using the Parakeet STT API (Whisper-compatible). Use when you need to convert speech/audio to text.
---

# Speech-to-Text (STT)

Transcribe audio files using the built-in STT service (Whisper-compatible API).

## Quick Usage

```bash
# Transcribe an audio file
stt /path/to/audio.wav

# Transcribe with language hint
stt --language de /path/to/audio.ogg

# Transcribe from URL (downloads first)
stt https://example.com/recording.mp3
```

## How It Works

- Audio is converted to 16kHz mono WAV via ffmpeg
- Long files (>120s) are automatically split into overlapping chunks
- Each chunk is sent to the STT API and results are concatenated
- Supports: wav, mp3, ogg, m4a, aac, flac, webm, mp4 (audio)

## Configuration

The STT endpoint is configured in `config.yml`:

```yaml
stt:
  url: "http://stt:5092/v1/audio/transcriptions"
  enabled: true
```

Override via environment variables:
- `STT_URL` — API endpoint URL
- `STT_ENABLED` — set to `false` to disable

## API (Direct)

The STT service exposes a Whisper-compatible API:

```bash
curl -X POST "$STT_URL" \
  -F "file=@/path/to/audio.wav" \
  -F "response_format=json"
```

Response: `{"text": "transcribed text here"}`

## Signal Integration

Audio messages received via Signal are **automatically transcribed** before reaching the agent. The transcription is included inline in the message — no manual action needed.

## Notes

- The STT service (Parakeet) must be deployed and reachable at the configured URL
- ffmpeg must be installed (included in the Atlas Docker image)
- For best results, use clear audio with minimal background noise
- German, English, and most common languages are supported
