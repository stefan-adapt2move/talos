---
name: stt
description: Transcribe audio files to text. Use when you need to convert speech/audio to text.
---

# Speech-to-Text (STT)

Transcribe audio files to text using the `stt` CLI.

## Usage

```bash
# Transcribe an audio file
stt /path/to/audio.wav

# Transcribe with language hint
stt --language de /path/to/audio.ogg

# Transcribe from a URL (downloads first)
stt https://example.com/recording.mp3
```

## Supported Formats

wav, mp3, ogg, m4a, aac, flac, webm, mp4 (audio track)

## Direct API Usage

The STT endpoint is Whisper-compatible (OpenAI `/v1/audio/transcriptions` format):

```bash
curl -X POST "$STT_URL" \
  -F "file=@/path/to/audio.wav" \
  -F "response_format=json" \
  -F "language=de"
```

Response: `{"text": "transcribed text here"}`

The `STT_URL` is read from `config.yml` (`stt.url`) or the `STT_URL` env var.

## Limitations

- Long files (>2 min) are split into 120s chunks with 5s overlap — minor artifacts at chunk boundaries are possible
- Accuracy depends on audio quality; background noise reduces quality significantly
- The model runs on CPU (int8 quantized) — expect ~5-15s processing per minute of audio
- Single-speaker optimized; multi-speaker conversations may lose speaker attribution
- No diarization (speaker identification) — only raw text output

## Signal Integration

Audio messages received via Signal are **automatically transcribed** before reaching the agent — no manual action needed.
