# ClipMaster Pro — Project Roadmap

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     ClipMaster Pro (Flutter Desktop)            │
│                                                                 │
│  ┌──────────┐  ┌──────────────┐  ┌────────────┐  ┌──────────┐  │
│  │ Magnetic  │  │  Fact-Shorts │  │   Viral    │  │ API Key  │  │
│  │ Timeline  │  │  Generator   │  │   Scout    │  │ Settings │  │
│  └─────┬────┘  └──────┬───────┘  └─────┬──────┘  └─────┬────┘  │
│        │               │               │               │        │
│  ┌─────┴───────────────┴───────────────┴───────────────┴─────┐  │
│  │               IPC Client (WebSocket :9120)                │  │
│  └───────────────────────┬───────────────────────────────────┘  │
│                          │                                      │
│  ┌───────────────────────┴───────────────────────────────────┐  │
│  │        Dev Console (in-app log viewer)                    │  │
│  └───────────────────────────────────────────────────────────┘  │
└──────────────────────────┬──────────────────────────────────────┘
                           │ WebSocket JSON
┌──────────────────────────┴──────────────────────────────────────┐
│                  Python Sidecar (FastAPI)                        │
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │
│  │ Script       │  │ Viral Scout  │  │ LLM Gateway          │   │
│  │ Analyzer     │  │ Service      │  │ (Gemini/Claude/OAI)  │   │
│  └──────────────┘  └──────────────┘  └──────────────────────┘   │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │
│  │ Stock        │  │ Faster-      │  │ Kokoro-82M           │   │
│  │ Footage API  │  │ Whisper      │  │ TTS Engine           │   │
│  └──────────────┘  └──────────────┘  └──────────────────────┘   │
│  ┌─────────────────────────────────────┐                        │
│  │ FFmpeg (h264_nvenc) + yt-dlp        │                        │
│  │ (bundled binaries, relative paths)  │                        │
│  └─────────────────────────────────────┘                        │
└─────────────────────────────────────────────────────────────────┘
```

## Folder Structure

```
ClipMaster/
├── clipmaster_app/                    # Flutter Desktop Application
│   ├── lib/
│   │   ├── main.dart                  # App entry point
│   │   ├── core/
│   │   │   ├── ipc/
│   │   │   │   ├── ipc_message.dart   # IPC protocol message types
│   │   │   │   └── ipc_client.dart    # WebSocket client + sidecar launcher
│   │   │   ├── services/
│   │   │   │   └── api_key_service.dart  # BYOK round-robin key manager
│   │   │   ├── logging/
│   │   │   │   └── dev_console.dart   # In-app dev console log system
│   │   │   ├── utils/
│   │   │   │   └── binary_paths.dart  # Bundled binary path resolution
│   │   │   └── models/               # Shared data models
│   │   ├── features/
│   │   │   ├── timeline/             # Magnetic Timeline UI
│   │   │   │   ├── models/
│   │   │   │   ├── widgets/
│   │   │   │   │   └── magnetic_timeline.dart
│   │   │   │   └── providers/
│   │   │   ├── fact_shorts/          # Fact-Shorts Generator
│   │   │   │   ├── models/
│   │   │   │   ├── widgets/
│   │   │   │   └── providers/
│   │   │   ├── viral_scout/          # Viral Scout Discovery
│   │   │   │   ├── models/
│   │   │   │   ├── widgets/
│   │   │   │   └── providers/
│   │   │   ├── api_keys/             # API Key Management UI
│   │   │   │   └── widgets/
│   │   │   │       └── api_key_settings.dart
│   │   │   └── dev_console/          # Dev Console UI
│   │   │       └── widgets/
│   │   │           └── dev_console_panel.dart
│   │   └── widgets/                  # Shared widgets
│   ├── assets/
│   ├── test/
│   ├── windows/
│   └── pubspec.yaml
│
├── clipmaster_sidecar/                   # Python Backend Sidecar
│   ├── __main__.py                   # Entry point (uvicorn)
│   ├── server.py                     # FastAPI + WebSocket server
│   ├── models/
│   │   └── ipc_models.py            # Pydantic IPC message models
│   ├── services/
│   │   ├── script_analyzer.py       # Fact-Shorts visual keyword mapper
│   │   ├── viral_scout.py           # Trending video discovery + ranking
│   │   ├── stock_footage.py         # Pexels/Pixabay B-roll search
│   │   └── llm_gateway.py          # Multi-provider LLM interface
│   ├── utils/
│   ├── tests/
│   │   ├── test_script_analyzer.py
│   │   └── test_viral_scout.py
│   ├── pyproject.toml
│   └── requirements.txt
│
├── bundled_binaries/                 # ffmpeg.exe, yt-dlp.exe (gitignored)
├── docs/
│   └── ROADMAP.md                   # This file
└── .gitignore
```

## IPC Protocol

**Transport:** WebSocket on `ws://127.0.0.1:9120/ws`

**Message Envelope:**
```json
{
  "id": "uuid-v4",
  "type": "downloadVideo | transcribe | progress | result | error | ...",
  "payload": { },
  "timestamp": "2026-03-02T12:00:00.000Z"
}
```

**Progress Updates** (same `id` as the originating request):
```json
{
  "id": "original-request-uuid",
  "type": "progress",
  "payload": {
    "stage": "Transcribing",
    "percent": 45,
    "detail": "Processing segment 12/27"
  }
}
```

**Message Types:**
| Type              | Direction         | Description                                |
|-------------------|-------------------|--------------------------------------------|
| `ping`            | Flutter → Python  | Health check                               |
| `pong`            | Python → Flutter  | Health check response                      |
| `downloadVideo`   | Flutter → Python  | Start yt-dlp download                      |
| `generateProxy`   | Flutter → Python  | Generate 720p proxy from 4K source         |
| `transcribe`      | Flutter → Python  | Run Faster-Whisper transcription           |
| `generateTts`     | Flutter → Python  | Run Kokoro-82M TTS                         |
| `analyzeScript`   | Flutter → Python  | Extract visual keywords from narration     |
| `queryStockFootage`| Flutter → Python | Search Pexels/Pixabay for B-roll          |
| `scoutTrending`   | Flutter → Python  | Fetch & rank trending videos               |
| `ffmpegRender`    | Flutter → Python  | Start FFmpeg render (h264_nvenc)           |
| `progress`        | Python → Flutter  | Real-time progress update                  |
| `result`          | Python → Flutter  | Final result payload                       |
| `error`           | Python → Flutter  | Error with message and optional code       |

## Roadmap Phases

### Phase 1: Foundation (Current)
- [x] Project structure and folder layout
- [x] IPC protocol definition and WebSocket transport
- [x] API Key Service with secure storage + round-robin
- [x] Dev Console logging system
- [x] Bundled binary path resolution
- [x] Script Analyzer (visual keyword extraction)
- [x] Viral Scout ranking algorithm
- [x] LLM Gateway (multi-provider)
- [x] Stock Footage query service
- [x] Magnetic Timeline UI shell
- [x] API Key Settings UI

### Phase 2: Video Pipeline
- [ ] yt-dlp integration with progress reporting
- [ ] Proxy video generation (4K → 720p)
- [ ] FFmpeg render pipeline with h264_nvenc
- [ ] Video preview player (media_kit)
- [ ] Clip extraction and trimming

### Phase 3: AI Integration
- [ ] Faster-Whisper transcription with word-level timestamps
- [ ] Kokoro-82M TTS generation
- [ ] LLM-powered fact brainstorming (10 engagement-optimized facts)
- [ ] LLM-powered script generation (45-second narrations)
- [ ] LLM-enhanced visual keyword extraction

### Phase 4: Timeline Features
- [ ] Drag-and-drop clip placement with magnetic snapping
- [ ] Auto-Caption as editable timeline objects
- [ ] Auto-Crop as editable timeline objects
- [ ] B-roll auto-assembly (stipple onto video track)
- [ ] Multi-track audio mixing
- [ ] Non-destructive effect stack

### Phase 5: Viral Scout
- [ ] YouTube trending integration (API + yt-dlp fallback)
- [ ] Twitch Helix API integration
- [ ] In-app WebView with "Analyze for Viral Clips" button
- [ ] Background monitoring worker
- [ ] "Recommended to Clip" feed UI

### Phase 6: Polish & Distribution
- [ ] Windows installer (MSIX)
- [ ] Auto-update mechanism
- [ ] Onboarding wizard
- [ ] Error reporting and crash analytics
- [ ] Performance profiling and optimization

## Technical Constraints

1. **Security:** All API keys stored in Windows Credential Manager via `flutter_secure_storage`
2. **Proxy System:** 4K VODs downloaded, 720p proxies used for timeline scrubbing
3. **Non-destructive:** Auto-Crop and Auto-Caption are editable timeline objects, never baked in
4. **Bundled Binaries:** ffmpeg.exe and yt-dlp.exe resolved via relative paths in installation dir
5. **Hardware Acceleration:** FFmpeg uses h264_nvenc for GPU-accelerated encoding
