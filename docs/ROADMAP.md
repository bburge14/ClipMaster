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
│  │ Stock        │  │ Whisper API  │  │ OpenAI TTS           │   │
│  │ Footage API  │  │ (OpenAI)     │  │ (6 voices)           │   │
│  └──────────────┘  └──────────────┘  └──────────────────────┘   │
│  ┌──────────────┐  ┌──────────────┐                             │
│  │ YouTube      │  │ Twitch       │                             │
│  │ Data API v3  │  │ Helix API    │                             │
│  └──────────────┘  └──────────────┘                             │
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
│   │   │   ├── timeline/             # Magnetic Timeline / NLE Editor
│   │   │   │   ├── widgets/
│   │   │   │   │   ├── magnetic_timeline.dart
│   │   │   │   │   ├── editor_toolbar.dart
│   │   │   │   │   ├── editor_menu_bar.dart
│   │   │   │   │   └── script_generator_panel.dart
│   │   │   │   └── providers/
│   │   │   │       └── editor_layout_provider.dart
│   │   │   ├── fact_shorts/          # Fact-Shorts Generator
│   │   │   │   └── widgets/
│   │   │   │       └── fact_shorts_page.dart
│   │   │   ├── viral_scout/          # Viral Scout Discovery
│   │   │   │   └── widgets/
│   │   │   │       └── viral_scout_page.dart
│   │   │   ├── activity/             # Download/Task Activity Feed
│   │   │   │   └── widgets/
│   │   │   │       ├── activity_page.dart
│   │   │   │       └── media_browser.dart
│   │   │   ├── settings/             # Settings & API Key Management
│   │   │   │   └── widgets/
│   │   │   │       └── settings_page.dart
│   │   │   ├── onboarding/           # First-launch Onboarding Wizard
│   │   │   │   └── widgets/
│   │   │   │       └── onboarding_wizard.dart
│   │   │   └── dev_console/          # Dev Console UI
│   │   │       └── widgets/
│   │   │           └── dev_console_panel.dart
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
│   │   ├── llm_gateway.py          # Multi-provider LLM interface
│   │   ├── fact_generator.py       # AI-powered fact generation
│   │   ├── media_tools.py          # FFmpeg/yt-dlp video processing
│   │   ├── youtube_search.py       # YouTube Data API v3 integration
│   │   └── twitch_search.py        # Twitch Helix API integration
│   ├── utils/
│   ├── tests/
│   │   ├── test_script_analyzer.py
│   │   ├── test_viral_scout.py
│   │   ├── test_fact_generator.py
│   │   ├── test_stock_footage.py
│   │   ├── test_media_tools.py
│   │   ├── test_llm_gateway.py
│   │   ├── test_youtube_search.py
│   │   ├── test_twitch_search.py
│   │   └── test_ipc_models.py
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
| Type                | Direction         | Description                                |
|---------------------|-------------------|--------------------------------------------|
| `ping`              | Flutter → Python  | Health check                               |
| `pong`              | Python → Flutter  | Health check response                      |
| `downloadVideo`     | Flutter → Python  | Start yt-dlp download                      |
| `downloadClip`      | Flutter → Python  | Download specific time range from video    |
| `generateProxy`     | Flutter → Python  | Generate 720p proxy from 4K source         |
| `transcribe`        | Flutter → Python  | Run Whisper API transcription              |
| `generateTts`       | Flutter → Python  | Run OpenAI TTS generation                  |
| `analyzeScript`     | Flutter → Python  | Extract visual keywords from narration     |
| `queryStockFootage` | Flutter → Python  | Search Pexels/Pixabay for B-roll           |
| `scoutTrending`     | Flutter → Python  | Fetch & rank trending videos               |
| `scoutChannel`      | Flutter → Python  | Search for a YouTube/Twitch channel        |
| `scoutVods`         | Flutter → Python  | Fetch VODs for a channel                   |
| `scoutClips`        | Flutter → Python  | Fetch clips for a broadcaster              |
| `resolveStreamUrl`  | Flutter → Python  | Resolve direct stream URL via yt-dlp       |
| `generateFacts`     | Flutter → Python  | AI-generate engagement-optimized facts     |
| `createShort`       | Flutter → Python  | Full pipeline: TTS + video + text overlay  |
| `ffmpegRender`      | Flutter → Python  | Start FFmpeg render (h264_nvenc)           |
| `previewSnapshot`   | Flutter → Python  | Generate WYSIWYG preview PNG               |
| `previewVideoClip`  | Flutter → Python  | Generate WYSIWYG preview video             |
| `setCookieBrowser`  | Flutter → Python  | Set browser for yt-dlp cookie auth         |
| `getCookieBrowser`  | Flutter → Python  | Get current cookie browser setting         |
| `progress`          | Python → Flutter  | Real-time progress update                  |
| `result`            | Python → Flutter  | Final result payload                       |
| `error`             | Python → Flutter  | Error with message and optional code       |

## Roadmap Phases

### Phase 1: Foundation
- [x] Project structure and folder layout
- [x] IPC protocol definition and WebSocket transport
- [x] API Key Service with secure storage + round-robin
- [x] Dev Console logging system
- [x] Bundled binary path resolution
- [x] Script Analyzer (visual keyword extraction)
- [x] Viral Scout ranking algorithm
- [x] LLM Gateway (multi-provider: OpenAI, Claude, Gemini)
- [x] Stock Footage query service (Pexels + Pixabay)
- [x] Magnetic Timeline UI shell
- [x] API Key Settings UI

### Phase 2: Video Pipeline
- [x] yt-dlp integration with progress reporting (parallel downloads, aria2c support)
- [x] Proxy video generation (4K → 720p)
- [x] FFmpeg render pipeline with h264_nvenc
- [x] Video preview player (media_kit with transport controls)
- [x] Clip extraction and trimming (stream-seeking via FFmpeg)

### Phase 3: AI Integration
- [x] Whisper API transcription with word-level timestamps
- [x] OpenAI TTS generation (alloy, echo, fable, onyx, nova, shimmer)
- [x] LLM-powered fact brainstorming (engagement-optimized facts per category)
- [x] LLM-powered script generation (45-second narrations)
- [x] LLM-enhanced visual keyword extraction

### Phase 4: Timeline Features
- [x] Drag-and-drop clip placement with magnetic snapping
- [x] Auto-Caption as editable timeline objects
- [x] Auto-Crop as editable timeline objects
- [x] B-roll auto-assembly (stock footage stipple onto video track)
- [x] Multi-track audio mixing (TTS + background music via FFmpeg amix)
- [x] Non-destructive effect stack (proxy editing, original for render)

### Phase 5: Viral Scout
- [x] YouTube trending integration (Data API v3 + yt-dlp fallback)
- [x] Twitch Helix API integration (top games → top clips)
- [x] Channel-first discovery (search channel → VODs → clips)
- [x] Clip download and stream URL resolution
- [x] "Recommended to Clip" feed UI with velocity/engagement ranking

### Phase 6: Polish & Distribution
- [x] Windows installer (Inno Setup with VBS launcher)
- [x] Auto-update mechanism (GitHub Releases check + download)
- [x] Onboarding wizard (first-launch API key setup)
- [x] Error reporting and dev console logging
- [x] Performance optimization (proxy playback, ValueNotifier streams)

## Technical Constraints

1. **Security:** All API keys stored in Windows Credential Manager via `flutter_secure_storage`
2. **Proxy System:** 4K VODs downloaded, 720p proxies used for timeline scrubbing
3. **Non-destructive:** Auto-Crop and Auto-Caption are editable timeline objects, never baked in
4. **Bundled Binaries:** ffmpeg.exe and yt-dlp.exe resolved via relative paths in installation dir
5. **Hardware Acceleration:** FFmpeg uses h264_nvenc for GPU-accelerated encoding
