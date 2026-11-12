# ExHtmltopdf

HTML → PDF for Elixir, natively. An Elixir NIF wrapper for
[sghtmltopdf](https://github.com/waka/sghtmltopdf), a PDF rendering engine
written in Rust on Servo components (html5ever, Stylo, Taffy).

- **No headless browser.** No Chrome, no wkhtmltopdf binary, no ports or
  System.cmd — the engine runs in-process on a dirty scheduler.
- **Modern CSS.** Flexbox, Grid, custom properties, `@page` rules, repeating
  table headers across page breaks. SVG (`<img>`, backgrounds, inline
  `<svg>`) is embedded as vectors.
- **Precompiled.** Ships prebuilt NIFs for macOS/Linux (arm64 + x86_64) via
  `rustler_precompiled` — users need no Rust toolchain.
- **Fast.** Upstream benchmarks ~21× faster than wkhtmltopdf and ~53× faster
  than headless Chrome on large documents.

```elixir
{:ok, pdf} = ExHtmltopdf.render("<h1>Hello</h1><p>from Elixir</p>")

:ok =
  ExHtmltopdf.render_to_file(html, "invoice.pdf",
    page_size: "A4",
    margin_top: "20mm",
    footer_center: "Page [page] of [topage]"
  )
```

## Installation

```elixir
def deps do
  [
    {:ex_htmltopdf, "~> 0.1"}
  ]
end
```

## Usage

```elixir
# To a binary (send it, store it, no temp files):
{:ok, pdf} = ExHtmltopdf.render(html, page_size: "A4")

# Raising variant:
pdf = ExHtmltopdf.render!(html)

# Straight to a file — written atomically (temp file + rename), a failed
# render never leaves a truncated PDF behind:
:ok = ExHtmltopdf.render_to_file(html, "out.pdf", grayscale: true)
```

### Options

sghtmltopdf exposes one option surface — its CLI flags — shared by the CLI,
HTTP server, Ruby gem, and this library. Options are the flag names as
underscored atoms; values follow a few simple rules
(see `ExHtmltopdf.Options`):

```elixir
page_size: "A4"                     # --page-size A4
orientation: "landscape"            # --orientation landscape
margin_top: "20mm"                  # --margin-top 20mm (all four sides available)
grayscale: true                     # bare flag; false/nil omits it
dpi: 300
zoom: 1.25
title: "Q3 Report"                  # PDF metadata (also author/subject/keywords/creator)
creation_date: "2026-10-22T10:30:00Z"  # fixed /CreationDate → byte-reproducible output
tagged: true                        # tagged PDF (structure tree for screen readers;
                                    # not available with streaming: true)
header_center: "Confidential"       # simple headers/footers (+ _left/_right)
footer_center: "Page [page] of [topage]"
header_html: "header.html"          # full HTML headers/footers from a file…
footer_html_content: "<p>[page]</p>"  # …or as markup, no temp file needed
toc: true                           # table of contents
cover: "cover.html"
user_style_sheet: "print.css"       # may repeat: pass a list
minimum_font_size: 9
encoding: "shift_jis"
base_url: "https://example.com/"    # resolve relative <img>/<link> paths —
                                    # rendering from a string has no document
                                    # directory, so without this (or an inline
                                    # <base href>) relative assets resolve to
                                    # nothing, silently (see below)
font: "/fonts/NotoSansJP.ttf"       # embed fonts; .ttc faces:
font: %{path: "/fonts/Hiragino.ttc", index: 1}
gothic_font: "/fonts/NotoSansJP.ttf"  # pin CSS generic families
disable_system_fonts: true          # only the fonts named above — same PDF on
                                    # every machine
```

See the [upstream documentation](https://waka.github.io/sghtmltopdf/en/) for
the full flag list — anything the CLI accepts works here, including new flags
after a dependency bump, with no wrapper changes.

Unsupported wkhtmltopdf options (JavaScript execution, forms, …) return a
clear `{:error, %ExHtmltopdf.Error{kind: :usage}}` explaining why, exactly
like the CLI does.

### Errors

Render functions return `{:error, %ExHtmltopdf.Error{kind: kind, message:
message}}` (bang variants raise it). `kind` mirrors the CLI's exit-code
classes: `:usage` (bad options), `:input` (missing file/font, unwritable
output), `:render` (engine constraint), `:timeout`, plus `:panic` for a
contained native bug (the VM survives; please report upstream).

Messages are upstream's text verbatim, and upstream treats the wording as
free to change. Match on `kind`, never on `message`.

### Missing assets, warnings, and runaway documents

Three operational behaviors worth knowing before production:

- **Missing assets degrade silently by default.** A broken `<img>`, dead
  `@import`, or unreadable font still returns `{:ok, pdf}` — upstream prints
  a warning to raw stderr (bypassing `Logger`; not suppressible via options)
  and renders without the asset. Pass `load_media_error_handling: "abort"`
  to get `{:error, %Error{}}` instead.
- **Renders are uninterruptible.** A render occupies one dirty CPU scheduler
  until the engine finishes; the BEAM cannot kill a running NIF, and
  `Task.shutdown` abandons the caller without stopping the work. Bound your
  concurrency (e.g. a fixed-size `Task.Supervisor` pool) — a deadline option
  is planned (PORTING.md phase 3).
- **Concurrent `render_to_file/3` calls are safe**, including to the same
  path (atomic per-call temp + rename; last writer wins).

## Rendering untrusted HTML

Two engine policies matter when the HTML isn't yours:

- **Remote assets are off by default.** `<img src="https://…">` and remote
  stylesheets are only fetched with `allow_remote_assets: true` (upstream
  guards fetches against SSRF/private addresses).
- **Local file access is ON by default** (upstream CLI compatibility):
  `<img src="/etc/anything">` and `file://` references read from the host
  filesystem. For untrusted input, pass `disable_local_file_access: true`,
  or `allow_path: ["/safe/dir"]` to restrict reads to specific directories
  (`allow:` is the wkhtmltopdf spelling and still works; use one spelling,
  not both — the two add up rather than override).

```elixir
ExHtmltopdf.render(untrusted_html, disable_local_file_access: true)
```

## Phoenix

Render any HTML your app can produce — a controller action for PDF invoices:

```elixir
def invoice(conn, %{"id" => id}) do
  html =
    Phoenix.Template.render_to_string(MyAppWeb.InvoiceHTML, "show", "html",
      invoice: Invoices.get!(id)
    )

  {:ok, pdf} = ExHtmltopdf.render(html, page_size: "A4")

  conn
  |> put_resp_content_type("application/pdf")
  |> put_resp_header("content-disposition", ~s(attachment; filename="invoice-#{id}.pdf"))
  |> send_resp(200, pdf)
end
```

## Development

Requires a Rust toolchain (1.89+, upstream's MSRV). `EXHTMLTOPDF_BUILD=1` forces building the NIF
from source instead of downloading a precompiled one:

```bash
EXHTMLTOPDF_BUILD=1 mix test     # or: just test
just fmt                           # mix format + cargo fmt
```

The upstream checkout is expected at `../sghtmltopdf`; `UPDATE_PROCEDURE.md`
documents how to bump the pinned revision, and `PORTING.md` the project's
design and staged plan.

## License

MIT. sghtmltopdf itself is MIT (© yo_waka).
