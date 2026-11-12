defmodule ExHtmltopdf do
  @moduledoc """
  HTML to PDF, natively — an Elixir NIF wrapper for
  [sghtmltopdf](https://github.com/waka/sghtmltopdf), a PDF rendering engine
  built on Servo components (html5ever, Stylo, Taffy). No headless browser, no
  external binary, no ports: the engine runs in-process on a dirty scheduler.

      {:ok, pdf} = ExHtmltopdf.render("<h1>Hello</h1>")
      :ok = ExHtmltopdf.render_to_file("<h1>Hello</h1>", "/tmp/hello.pdf", page_size: "A4")

  ## Options

  Options mirror the upstream CLI flags one-to-one — underscored atom keys map
  to the flag names (`page_size: "A4"` → `--page-size A4`). See
  `ExHtmltopdf.Options` for the conversion rules and the upstream
  documentation for the full flag list. Commonly used:

    * `page_size: "A4"`, `orientation: "landscape"`
    * `margin_top: "20mm"` (and `_bottom`/`_left`/`_right`)
    * `grayscale: true`, `no_images: true`, `no_background: true`
    * `header_html: path`, `footer_html: path`, `toc: true`, `cover: path`
    * `header_html_content: html`, `footer_html_content: html` (markup
      instead of a file)
    * `tagged: true` (tagged PDF for assistive technology),
      `creation_date: "2026-10-22"` (reproducible output), `creator: "…"`
    * `disable_system_fonts: true` (only the fonts you pass — same PDF on
      every machine)
    * `font: "/path/to/font.ttf"` (see `ExHtmltopdf.Options` for `.ttc` faces)
    * `user_style_sheet: path`, `minimum_font_size: 9`

  ## Security posture

  Remote asset fetching (`<img src="https://…">`, remote stylesheets) is
  **off** by default upstream; opt in with `allow_remote_assets: true`.
  Local file access follows the upstream CLI default (allowed, unrestricted);
  restrict it with `disable_local_file_access: true` or
  `allow_path: ["/safe/dir"]` (`allow:` is an alias) when rendering
  untrusted HTML.

  ## Operational notes

    * **Renders are uninterruptible.** Each render occupies one dirty CPU
      scheduler until the engine finishes — the BEAM cannot kill a running
      NIF, so `Task.shutdown`/`:timer` timeouts abandon the caller but not
      the work. Bound your concurrency (the dirty CPU pool defaults to the
      core count) and don't feed unbounded untrusted documents until the
      `timeout_ms:` deadline option ships (PORTING.md phase 3).
    * **Missing assets degrade silently by default.** A broken `<img>`,
      unresolvable `@import`, or unreadable font still yields `{:ok, pdf}`
      (with a warning printed to raw stderr, bypassing `Logger` — upstream
      doesn't gate these). Pass `load_media_error_handling: "abort"` to turn
      asset failures into `{:error, %Error{}}`.
    * **Relative asset paths resolve to nothing** when rendering from a
      string (there is no document directory). Pass `base_url:` (or inline
      a `<base href>`) if your HTML references relative images/stylesheets.
  """

  alias ExHtmltopdf.{Error, Native, Options}

  @typedoc "See the module documentation for common options."
  @type options :: keyword() | map()

  @doc """
  Renders an HTML document to a PDF binary.

  Returns `{:ok, pdf_binary}` or `{:error, %ExHtmltopdf.Error{}}`. Raises
  `ArgumentError` for malformed option *shapes* (option *values* the engine
  rejects come back as `{:error, %Error{kind: :usage}}`).

      {:ok, pdf} = ExHtmltopdf.render("<p>hi</p>", page_size: "A5")

  """
  @spec render(iodata(), options()) :: {:ok, binary()} | {:error, Error.t()}
  def render(html, options \\ []) do
    case Native.render(IO.iodata_to_binary(html), Options.to_argv(options)) do
      {:ok, pdf} -> {:ok, pdf}
      {:error, {kind, message}} -> {:error, %Error{kind: kind, message: message}}
    end
  end

  @doc """
  Same as `render/2`, but returns the PDF binary directly and raises
  `ExHtmltopdf.Error` on failure.
  """
  @spec render!(iodata(), options()) :: binary()
  def render!(html, options \\ []) do
    case render(html, options) do
      {:ok, pdf} -> pdf
      {:error, %Error{} = error} -> raise error
    end
  end

  @doc """
  Renders an HTML document to a PDF file at `path`.

  The file is written atomically (temp file + rename), so a failed render
  never leaves a truncated PDF at `path`. Returns `:ok` or
  `{:error, %ExHtmltopdf.Error{}}`.

      :ok = ExHtmltopdf.render_to_file("<p>hi</p>", "out.pdf", grayscale: true)

  """
  @spec render_to_file(iodata(), Path.t(), options()) :: :ok | {:error, Error.t()}
  def render_to_file(html, path, options \\ []) do
    html = IO.iodata_to_binary(html)

    case Native.render_to_file(html, Options.to_argv(options), IO.chardata_to_string(path)) do
      :ok -> :ok
      {:error, {kind, message}} -> {:error, %Error{kind: kind, message: message}}
    end
  end

  @doc """
  Same as `render_to_file/3`, but raises `ExHtmltopdf.Error` on failure.
  """
  @spec render_to_file!(iodata(), Path.t(), options()) :: :ok
  def render_to_file!(html, path, options \\ []) do
    case render_to_file(html, path, options) do
      :ok -> :ok
      {:error, %Error{} = error} -> raise error
    end
  end

  # Extracted at compile time from the lockfile (what the NIF is actually
  # built against, whether the dependency is the crates.io pin or a path
  # checkout during an upstream bump) so it can never drift.
  @external_resource cargo_lock =
                       Path.expand("../native/ex_htmltopdf/Cargo.lock", __DIR__)
  [_, upstream_version] =
    Regex.run(~r/name = "sghtmltopdf"\nversion = "([^"]+)"/, File.read!(cargo_lock))

  @upstream_version upstream_version

  @doc """
  The version of the [sghtmltopdf](https://crates.io/crates/sghtmltopdf)
  crate this build wraps. Include it in upstream bug reports.

      iex> ExHtmltopdf.upstream_version() =~ ~r/^\\d+\\.\\d+\\.\\d+/
      true

  """
  @spec upstream_version() :: String.t()
  def upstream_version, do: @upstream_version
end
