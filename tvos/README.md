# Marco Movie for Apple TV (tvOS 16.0+)

Native SwiftUI + AVKit + QuickJS-NG living-room application for Apple TV (`tvOS 16.0+`), sharing the canonical CMS, Live TV, Backup (`marco-movie-backup`), WebDAV Cloud Sync v2, and LAN Peer Configuration contracts with Android, iOS, macOS, and Windows.

## Architecture Overview

- **`CQuickJS` (`Sources/CQuickJS/`)**: SwiftPM / Xcode C11 target compiling the shared QuickJS-NG `0.14.0` engine (`quickjs.c`, `libregexp.c`, `libunicode.c`, `dtoa.c`) synced by `prepare_tvos.py`.
- **`MarcoTVCore` (`Sources/MarcoTVCore/`)**: Cross-compiles cleanly on both **macOS 13+** (for `swift test` CI) and **tvOS 16.0+**:
  - `Parser/`: Full 20-case conformance decoder (`ConfigDecoder` + `CmsParser` + `LiveCatalogParser`) supporting UTF-8 BOM, UTF-16LE/BE, GZIP, JPEG/PNG `**` steganography, `2423...2324` even-byte-aligned AES-128-CBC hex configs, Base64, JSON comment/trailing-comma stripping, MacCMS JSON & XML, `vod_play_list`, header priority merging, and M3U/TXT live catalogues.
  - `Network/`: `CmsClient` (concurrent `withTaskGroup` multi-site search, multi-depot switching) and `LocalHeaderProxyServer` (`NWListener` on `127.0.0.1` port `0` rewriting HLS `.m3u8` variant/segment/`#EXT-X-KEY` URLs and injecting custom `Referer` / `User-Agent` / `Cookie` headers for `AVPlayer`).
  - `JavaScript/`: `QuickJSBridge` (memory-capped, wall-clock interrupt-guarded QuickJS runtime + bridged HTTP `req()`) and `JsSourceHost` (CatVod / TVBox Type-3 JS spider runner).
  - `Storage/`: tvOS-compliant dual-layer self-healing persistence (`TvStorageManager` combining a DEFLATE-compressed `Security` Keychain Anchor with `Library/Caches/MarcoMovie/` working JSON files so data survives tvOS `Caches` eviction without ever writing persistent files to `Documents` or bloating `UserDefaults`), `WebDavSyncService` (`jianguoyun.com` auto-path normalization, recursive `MKCOL`, `ETag` `If-Match`, 3-way timestamp + tombstone merge), and `LanConfigServer` (QR-driven mobile web push console + peer sync).
- **`MarcoMovieTV` (`Sources/MarcoMovieTV/`)**: 10-foot Apple TV Focus Engine UI (`发现`, `直播`, `搜索`, `片库`, `设置`), remote-friendly on-screen grid keyboard, 50-episode paged detail view, crisp `CIQRCodeGenerator` LAN push modal, and `PlayerEngineProtocol` + `AVPlayerViewController` player.

## Build & Verification Commands

### 1. Prepare Vendor Sources, Layered Icons & Xcode Project

```bash
python3 tvos/prepare_tvos.py
python3 -m unittest discover -s tvos -p "test_*.py"
```

### 2. Run Core Conformance & Unit Tests (`swift test` on macOS)

```bash
cd tvos
swift test
```

### 3. Build Apple TV Application (`MarcoMovieTV.app`)

```bash
python3 tvos/prepare_tvos.py
xcodebuild \
  -project tvos/RunnerProject/MarcoMovieTV.xcodeproj \
  -scheme MarcoMovieTV \
  -sdk appletvos \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO
```

### 4. Normalize `tvOS 16.0` Deployment Target, Ad-Hoc Sign & Pack `.ipa`

```bash
python3 tvos/patch_tvos_ipa.py \
  path/to/MarcoMovieTV.app \
  --ipa MarcoMovieTV-tvOS16.ipa
```
