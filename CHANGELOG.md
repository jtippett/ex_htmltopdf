# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## 0.7.0 - 2026-11-12

### Changed

- Updated sghtmltopdf from v0.1.1 to v0.7.0 (`91b85a61`). Rendered output
  changes for existing documents — re-check anything you compare byte for
  byte or by page count:
  - `line-height: normal` is now the font's own line spacing instead of a
    fixed 1.2em (CJK text loosens by about a fifth and may gain pages; a
    document that sets `line-height` explicitly is unaffected);
  - custom properties (`var()`) follow the cascade and inheritance per
    element instead of last-declaration-wins, and `inherit`/`initial`/`unset`,
    `@supports`, `@property` and `display: inline-flex` are honoured
    (Tailwind v4 and Bootstrap resets now render correctly);
  - every PDF carries a trailer `/ID`, `/ModDate`, an XMP metadata stream, a
    `/Lang` from `<html lang>`, and embedded fonts are named after the font
    (`ABCDEF+DMSans-Regular`) instead of `EmbeddedFont`;
  - a font with no glyph outlines (colour emoji fonts) is declined with a
    warning instead of producing invisible text.
- Error and warning messages from the engine are now English (they were
  Japanese). `kind` is unchanged; keep matching on it, not on `message`.
- `ExHtmltopdf.Options.to_argv/1` returns only the option flags — the
  `["sghtmltopdf", "-", "--output", "-"]` placeholder prefix is gone, because
  upstream's new binding entry point (`Converter`) supplies it.
- Building from source now needs Rust 1.89+ (upstream's MSRV). Precompiled
  NIF users are unaffected.

### Added

- SVG support: the NIF is built with upstream's `svg` feature, so
  `<img src="*.svg">`, `background-image: url(*.svg)` and inline `<svg>` are
  embedded as vectors. (`<text>` inside an SVG is not drawn — upstream's
  `svg-text` feature is off, as in the CLI default.)
- New options from upstream, available with no wrapper changes: `tagged`
  (tagged PDF), `creator`, `creation_date` (fixed creation date; makes output
  byte-reproducible), `disable_system_fonts`, `header_html_content` /
  `footer_html_content` (header/footer markup without a file), and
  `allow_path` (the new primary spelling of `allow`, which remains an alias).
- PDF outline (bookmarks) from the CSS `bookmark-level` / `bookmark-label` /
  `bookmark-state` properties.

## 0.1.0 - 2026-08-12

### Added

- Initial release: `ExHtmltopdf.render/2`, `render!/2`, `render_to_file/3`,
  `render_to_file!/3` — HTML to PDF via a Rustler NIF over
  [sghtmltopdf](https://github.com/waka/sghtmltopdf) (pinned at v0.1.1,
  `d774b79a`), rendered on a dirty CPU scheduler with the engine's dedicated
  16 MiB render stack.
- `ExHtmltopdf.Options` — keyword options mapped to the upstream CLI's
  shared option parser (one option surface across CLI/server/Ruby/Elixir).
- `ExHtmltopdf.Error` with kinds `:usage`/`:input`/`:render`/`:timeout`
  mirroring the CLI error classes, and `:panic` for contained native panics.
- Precompiled NIFs for aarch64/x86_64 macOS and Linux via
  `rustler_precompiled`; `EXHTMLTOPDF_BUILD=1` forces a source build.
