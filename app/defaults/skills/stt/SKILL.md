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

Long files (>2 min) are automatically chunked and concatenated.

## Signal Voice Messages

Audio messages received via Signal are **automatically transcribed** before reaching the agent — no manual action needed.
