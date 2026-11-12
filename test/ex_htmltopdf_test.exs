defmodule ExHtmltopdfTest do
  use ExUnit.Case, async: true

  alias ExHtmltopdf.Error

  doctest ExHtmltopdf

  @html "<!doctype html><html><body><h1>Hello, PDF</h1><p>from Elixir</p></body></html>"

  describe "NIF loading" do
    test "the native library links against sghtmltopdf" do
      assert ExHtmltopdf.Native.default_page_size() =~ ~r/^\d+(\.\d+)?x\d+(\.\d+)?$/
    end

    test "upstream_version/0 exposes the version in Cargo.lock, matching the Cargo.toml pin" do
      version = ExHtmltopdf.upstream_version()
      assert version =~ ~r/^\d+\.\d+\.\d+/
      assert File.read!("native/ex_htmltopdf/Cargo.toml") =~ ~s(version = "=#{version}")
    end
  end

  describe "render/2" do
    test "renders HTML to a PDF binary" do
      assert {:ok, pdf} = ExHtmltopdf.render(@html)
      assert <<"%PDF-", _::binary>> = pdf
    end

    test "accepts iodata" do
      assert {:ok, <<"%PDF-", _::binary>>} =
               ExHtmltopdf.render(["<h1>", "chunked", "</h1>"])
    end

    test "options actually reach the engine (A5 changes the MediaBox)" do
      {:ok, a4} = ExHtmltopdf.render(@html, page_size: "A4", grayscale: true)
      {:ok, a5} = ExHtmltopdf.render(@html, page_size: "A5", grayscale: true)

      assert a4 =~ "MediaBox [0 0 595.275 841.875]"
      assert a5 =~ "MediaBox [0 0 419.55002 595.275]"
    end

    test "empty HTML still renders a document" do
      assert {:ok, <<"%PDF-", _::binary>>} = ExHtmltopdf.render("")
    end

    test "an unknown option is a :usage error, not a crash" do
      assert {:error, %Error{kind: :usage, message: message}} =
               ExHtmltopdf.render(@html, no_such_option: "x")

      assert message =~ "no-such-option"
    end

    test "an unsupported wkhtmltopdf option is a :usage error" do
      # upstream keeps a deliberate unsupported-flags list with explanations
      assert {:error, %Error{kind: :usage}} =
               ExHtmltopdf.render(@html, enable_javascript: true)
    end

    test "flags added upstream since the first pin pass straight through" do
      assert {:ok, pdf} =
               ExHtmltopdf.render(@html,
                 tagged: true,
                 creator: "ExHtmltopdf tests",
                 creation_date: "2026-10-22T10:30:00Z",
                 disable_system_fonts: false,
                 footer_html_content: "<p>[page]</p>"
               )

      assert <<"%PDF-", _::binary>> = pdf
      assert pdf =~ "ExHtmltopdf tests"
      assert pdf =~ "StructTreeRoot"
    end

    test "creation_date makes output reproducible" do
      opts = [creation_date: "2026-10-22"]
      assert ExHtmltopdf.render(@html, opts) == ExHtmltopdf.render(@html, opts)
    end

    test "inline <svg> renders (the svg feature is compiled in)" do
      svg =
        ~s(<svg width="20" height="20" viewBox="0 0 20 20"><circle cx="10" cy="10" r="8"/></svg>)

      {:ok, with_svg} = ExHtmltopdf.render("<p>x</p>" <> svg, no_pdf_compression: true)
      {:ok, without} = ExHtmltopdf.render("<p>x</p>", no_pdf_compression: true)
      assert byte_size(with_svg) > byte_size(without)
      assert with_svg =~ "/XObject"
    end

    test "a missing font file is an :input error" do
      assert {:error, %Error{kind: :input}} =
               ExHtmltopdf.render(@html, font: "/nonexistent/font.ttf")
    end

    test "an engine constraint is a :render error ([topage] in streaming mode)" do
      assert {:error, %Error{kind: :render}} =
               ExHtmltopdf.render(@html,
                 streaming: true,
                 footer_center: "Page [page] of [topage]"
               )
    end

    test "the VM and session survive an error (subsequent renders work)" do
      assert {:error, _} = ExHtmltopdf.render(@html, font: "/nonexistent/font.ttf")
      assert {:ok, _} = ExHtmltopdf.render(@html)
    end
  end

  describe "render!/2" do
    test "returns the PDF binary" do
      assert <<"%PDF-", _::binary>> = ExHtmltopdf.render!(@html)
    end

    test "raises ExHtmltopdf.Error with the kind in the message" do
      assert_raise Error, ~r/\(usage\)/, fn ->
        ExHtmltopdf.render!(@html, bogus: "yes")
      end
    end
  end

  describe "render_to_file/3" do
    @tag :tmp_dir
    test "writes a PDF to the given path", %{tmp_dir: tmp} do
      path = Path.join(tmp, "out.pdf")
      assert :ok = ExHtmltopdf.render_to_file(@html, path)
      assert <<"%PDF-", _::binary>> = File.read!(path)
    end

    @tag :tmp_dir
    test "a failed parse never creates a file", %{tmp_dir: tmp} do
      path = Path.join(tmp, "never.pdf")

      assert {:error, %Error{kind: :usage}} =
               ExHtmltopdf.render_to_file(@html, path, bogus: true)

      assert File.ls!(tmp) == []
    end

    @tag :tmp_dir
    test "a render failing mid-write leaves neither the PDF nor a temp file", %{tmp_dir: tmp} do
      path = Path.join(tmp, "never.pdf")

      # header_html is only read inside the render, after the sink is created —
      # this exercises the temp-file cleanup path, not just the parse guard.
      assert {:error, %Error{kind: :input}} =
               ExHtmltopdf.render_to_file(@html, path, header_html: "/definitely/missing.html")

      assert File.ls!(tmp) == []
    end

    @tag :tmp_dir
    test "concurrent writes to the same path are atomic (no interleaved temp files)",
         %{tmp_dir: tmp} do
      path = Path.join(tmp, "same.pdf")

      1..8
      |> Task.async_stream(
        fn i -> :ok = ExHtmltopdf.render_to_file("<h1>writer #{i}</h1>", path) end,
        timeout: 60_000
      )
      |> Stream.run()

      # Exactly the final PDF remains — no .part/.tmp leftovers — and it is
      # one writer's intact output, not an interleaving.
      assert File.ls!(tmp) == ["same.pdf"]
      assert <<"%PDF-", _::binary>> = File.read!(path)
    end

    test "an unwritable output path is an :input error" do
      assert {:error, %Error{kind: :input}} =
               ExHtmltopdf.render_to_file(@html, "/nonexistent-dir/out.pdf")
    end
  end

  describe "concurrency" do
    test "parallel renders are independent" do
      results =
        1..4
        |> Task.async_stream(fn i -> ExHtmltopdf.render("<h1>doc #{i}</h1>") end,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, <<"%PDF-", _::binary>>}, &1))
    end
  end
end
