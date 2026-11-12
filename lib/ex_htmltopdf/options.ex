defmodule ExHtmltopdf.Options do
  @moduledoc """
  Turns an Elixir options keyword list into the CLI-style option list the
  native engine consumes.

  sghtmltopdf exposes one option surface — the CLI flags — shared by the CLI,
  the HTTP server, and the Ruby gem. This module is the Elixir equivalent of
  the gem's options layer: option names are the CLI flag names with underscores
  (`:page_size` → `--page-size`), and no option semantics live on this side.
  Run `sghtmltopdf --help` (or see the upstream docs) for the full list.

  Conversion rules:

      page_size: "A4"          → ["--page-size", "A4"]
      grayscale: true          → ["--grayscale"]
      grayscale: false         → []  (also for nil)
      allow_path: ["/a", "/b"] → ["--allow-path", "/a", "--allow-path", "/b"]
      margin_top: 20           → ["--margin-top", "20"]

  `:font` is the one special case, because `--font-index` binds to the
  preceding `--font` by position:

      font: "a.ttf"                      → ["--font", "a.ttf"]
      font: %{path: "a.ttc", index: 1}   → ["--font", "a.ttc", "--font-index", "1"]
      font: ["a.ttf", %{path: "b.ttc", index: 2}]
        → ["--font", "a.ttf", "--font", "b.ttc", "--font-index", "2"]

  Two keys are rejected: `:input` and `:output` are owned by the NIF (the
  HTML bytes cross the boundary directly, and the output destination is the
  return value or the `render_to_file/3` path), so passing them would be
  silently ignored — an error is clearer.

  Charlists are also rejected: a charlist is indistinguishable from a "repeat
  this option" list of values, so `title: ~c"Report"` would silently become
  per-character flags. Pass binaries (`"Report"`).
  """

  @doc """
  Builds the option list for the native option parser — the flags as they
  would be written on the command line, without a program name, input, or
  output (upstream's `Converter` supplies those itself).

      iex> ExHtmltopdf.Options.to_argv(page_size: "A4", grayscale: true)
      ["--page-size", "A4", "--grayscale"]

      iex> ExHtmltopdf.Options.to_argv([])
      []
  """
  @spec to_argv(keyword() | map()) :: [String.t()]
  def to_argv(options) do
    Enum.flat_map(options, fn {key, value} ->
      Enum.flat_map(pairs_for(key, value), fn
        {name, nil} -> ["--#{name}"]
        {name, arg} -> ["--#{name}", arg]
      end)
    end)
  end

  # One key/value into a list of {flag-name, value-or-nil} pairs. A nil value
  # means a bare flag (e.g. --toc).
  defp pairs_for(key, _value) when key in [:input, :output, "input", "output"] do
    raise ArgumentError,
          "#{inspect(key)} is owned by the NIF — the HTML crosses the boundary " <>
            "directly and the output is the return value (or the render_to_file/3 path)"
  end

  defp pairs_for(key, value) do
    if flag_name(key) == "font" do
      font_pairs(value)
    else
      value_pairs(key, value)
    end
  end

  defp value_pairs(_key, nil), do: []
  defp value_pairs(_key, false), do: []
  defp value_pairs(key, true), do: [{flag_name(key), nil}]

  # A charlist is also a list, and treating it as option repetition would
  # silently emit one flag per character. Refuse rather than guess.
  defp value_pairs(key, [c | _] = value) when is_integer(c) do
    raise ArgumentError,
          "#{inspect(key)} got a charlist (#{inspect(value)}); pass a binary string — " <>
            "lists are reserved for repeating an option"
  end

  # A list repeats the same option; each element follows the same rules.
  defp value_pairs(key, value) when is_list(value),
    do: Enum.flat_map(value, &value_pairs(key, &1))

  # Structs (Date, etc.) fall through to String.Chars below, like any scalar.
  defp value_pairs(key, value) when is_map(value) and not is_struct(value) do
    # Nested maps like wicked_pdf's `margin: %{top: 10}` are rejected rather
    # than flattened: the unit interpretation differs (wicked_pdf is mm, here
    # it's px), so mechanical flattening would silently produce different
    # margins. Use flat keys (`margin_top: "20mm"`) instead.
    example = value |> Map.keys() |> List.first()

    hint =
      if example do
        ~s( — e.g. #{key}_#{example}: "...")
      else
        ""
      end

    raise ArgumentError,
          "#{inspect(key)} does not accept a map (only :font takes path/index); " <>
            "use flat option keys#{hint}"
  end

  defp value_pairs(key, value), do: [{flag_name(key), string_value(key, value)}]

  # The NIF decodes argv as Rust Strings, so a non-UTF-8 binary would raise a
  # bare ArgumentError at the boundary with no clue which option it was.
  defp string_value(key, value) do
    string = to_string(value)

    unless String.valid?(string) do
      raise ArgumentError,
            "#{inspect(key)} is not valid UTF-8: #{inspect(value, limit: 32)}"
    end

    string
  end

  # --font-index binds to the nearest preceding --font, so the index pair must
  # immediately follow its font pair.
  defp font_pairs(nil), do: []
  defp font_pairs(false), do: []

  defp font_pairs([c | _] = value) when is_integer(c) do
    raise ArgumentError,
          ":font got a charlist (#{inspect(value)}); pass a binary string — " <>
            "lists are reserved for repeating an option"
  end

  defp font_pairs(values) when is_list(values), do: Enum.flat_map(values, &font_pairs/1)

  defp font_pairs(%{} = font) do
    path =
      Map.get(font, :path) ||
        raise ArgumentError, "a :font map requires :path — got #{inspect(font)}"

    case Map.get(font, :index) do
      nil -> [{"font", string_value(:font, path)}]
      index -> [{"font", string_value(:font, path)}, {"font-index", to_string(index)}]
    end
  end

  defp font_pairs(path), do: [{"font", string_value(:font, path)}]

  # :page_size → "page-size"
  defp flag_name(key), do: key |> to_string() |> String.replace("_", "-")
end
