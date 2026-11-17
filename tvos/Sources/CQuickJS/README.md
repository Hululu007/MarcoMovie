# CQuickJS Target (tvOS / macOS)

This target wraps the repository's shared QuickJS-NG 0.14.0 C sources located at:
`../flutter/packages/quickjs_engine/native/cxx/quickjs/`

Before running `swift test` or `xcodebuild`, execute:

```bash
python3 tvos/prepare_tvos.py
```

`prepare_tvos.py` copies `quickjs.c`, `libregexp.c`, `libunicode.c`, `dtoa.c`, and all required headers into `tvos/Sources/CQuickJS/` and `tvos/Sources/CQuickJS/include/`. All copied vendor files are git-ignored so QuickJS-NG remains single-sourced in the repository.
