defmodule ExHtmltopdf.Error do
  @moduledoc """
  Error returned (or raised, from the bang variants) by render functions.

  `kind` mirrors the upstream CLI's error classes:

    * `:usage` — bad options (unknown flag, malformed value, unsupported
      wkhtmltopdf option)
    * `:input` — input/resource problems (missing file, unreadable font,
      output not writable)
    * `:render` — the engine rejected the document (e.g. `[topage]` in
      streaming mode)
    * `:timeout` — the render deadline was exceeded
    * `:panic` — a bug in the native engine, contained and reported instead of
      crashing the VM (please report upstream)

  `message` is upstream's text verbatim. Upstream treats the classification
  as public API and the wording as free to change — match on `kind`, never
  on `message`.
  """

  defexception [:kind, :message]

  @type kind :: :usage | :input | :render | :timeout | :panic

  @type t :: %__MODULE__{kind: kind(), message: String.t()}

  @impl true
  def message(%__MODULE__{kind: kind, message: message}), do: "(#{kind}) #{message}"
end
