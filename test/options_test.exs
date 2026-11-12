defmodule ExHtmltopdf.OptionsTest do
  use ExUnit.Case, async: true

  alias ExHtmltopdf.Options

  doctest ExHtmltopdf.Options

  defp argv(opts), do: Options.to_argv(opts)

  test "empty options produce an empty list (no program name or placeholders)" do
    assert Options.to_argv([]) == []
  end

  test "value options become --flag value with underscores dashed" do
    assert argv(page_size: "A4") == ["--page-size", "A4"]
    assert argv(margin_top: "20mm") == ["--margin-top", "20mm"]
  end

  test "non-string values are stringified" do
    assert argv(minimum_font_size: 9) == ["--minimum-font-size", "9"]
    assert argv(zoom: 1.5) == ["--zoom", "1.5"]
  end

  test "true means a bare flag; false and nil are omitted" do
    assert argv(grayscale: true) == ["--grayscale"]
    assert argv(grayscale: false) == []
    assert argv(grayscale: nil) == []
  end

  test "lists repeat the option per element" do
    assert argv(allow: ["/a", "/b"]) == ["--allow", "/a", "--allow", "/b"]
  end

  test "options keep their given order" do
    assert argv(page_size: "A4", grayscale: true, dpi: 300) ==
             ["--page-size", "A4", "--grayscale", "--dpi", "300"]
  end

  test "font accepts a plain path" do
    assert argv(font: "a.ttf") == ["--font", "a.ttf"]
  end

  test "font map places --font-index immediately after its --font" do
    assert argv(font: %{path: "a.ttc", index: 1}) ==
             ["--font", "a.ttc", "--font-index", "1"]

    assert argv(font: ["a.ttf", %{path: "b.ttc", index: 2}]) ==
             ["--font", "a.ttf", "--font", "b.ttc", "--font-index", "2"]
  end

  test "font map without index emits only --font" do
    assert argv(font: %{path: "a.ttf"}) == ["--font", "a.ttf"]
  end

  test "font map without path raises" do
    assert_raise ArgumentError, ~r/requires :path/, fn ->
      Options.to_argv(font: %{index: 1})
    end
  end

  test "maps for other options raise with a flat-key hint" do
    assert_raise ArgumentError, ~r/margin_top/, fn ->
      Options.to_argv(margin: %{top: "10mm"})
    end
  end

  test "structs stringify like scalars instead of hitting the map rejection" do
    assert argv(title: ~D[2026-01-01]) == ["--title", "2026-01-01"]
  end

  test "charlist values are rejected, not exploded into per-character flags" do
    assert_raise ArgumentError, ~r/charlist/, fn ->
      Options.to_argv(title: ~c"Report")
    end

    assert_raise ArgumentError, ~r/charlist/, fn ->
      Options.to_argv(font: ~c"a.ttf")
    end
  end

  test "non-UTF-8 values are rejected naming the key" do
    assert_raise ArgumentError, ~r/:title.*not valid UTF-8/s, fn ->
      Options.to_argv(title: <<0xFF, 0xFE>>)
    end
  end

  test ":input and :output are NIF-owned and rejected" do
    assert_raise ArgumentError, ~r/owned by the NIF/, fn ->
      Options.to_argv(output: "/tmp/x.pdf")
    end

    assert_raise ArgumentError, ~r/owned by the NIF/, fn ->
      Options.to_argv(input: "page.html")
    end
  end
end
