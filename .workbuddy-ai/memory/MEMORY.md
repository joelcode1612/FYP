# FYP — Long-term project notes

## Brand assets (since 2026-10-26)

- The app icon is the user-uploaded rounded-square isometric map tile. Source of
  truth: `fyp_jaspr_web/tool/_src/sitewise_icon_source.jpg`; regeneration script:
  `fyp_jaspr_web/tool/make_app_icon.py` (emits web `sitewise-icon*`/`sitewise-mark-64`
  + Android/iOS/macOS launcher icons). Do NOT reintroduce glyph/inline-SVG logos.
- Web brand marks reference `assets/sitewise-mark-64.png` (floating rounded tile):
  `lib/components/ui.dart` (Brand), `landing_page.dart` nav, `auth_icons.dart`,
  `signup_page._brandMark`. Favicon/touch icon: `sitewise-icon-32.png` /
  `sitewise-icon-180.png` in `main.server.dart`. Mobile launchers use the square
  master (`square_master` fills outside-of-squircle corners via cv2.inpaint).
- Signup hero uses the photographic backdrop `assets/signup-city.jpg`
  (cleaned by `tool/extract_signup_bg.py`), rendered as `<img class="su-hero__art">`,
  NOT an inline SVG.

## Build / verify workflow

- Build: `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy dart run
  jaspr_cli:jaspr build` in `fyp_jaspr_web` (proxy intercepts the build daemon's
  websocket -> 502). `jaspr build` deletes `build/jaspr` — stop any server serving it first.
- Verify: `python -m http.server 8141` in `build/jaspr` (run_in_background), then
  `node tool/verify_pages.js http://127.0.0.1:8141`, `tool/verify_icon.js`,
  `tool/probe_signup.js` with NODE_PATH=<managed node workspace>/node_modules.
- Playwright chromium at `C:/Users/Lenovo/AppData/Local/ms-playwright/chromium-1248/...`.

## Gotchas

- `<base href="/">` in built HTML: asset refs in Dart must be root-relative
  (`assets/...`), not `../assets`.
- `main_()` is used for the `<main>` element (`main` is a Dart reserved word).
- Read an entire CSS rule before editing — some rules (`.brand-icon`) have
  properties continuing past what a grep -A8 snippet shows.
- The model in this environment cannot view images; verify visual work with
  numeric pixel probes or headless-browser DOM checks (`naturalWidth`, class audits).
