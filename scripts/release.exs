# Interactive release assistant. Run from the project root:
#
#     just release            # or:  elixir scripts/release.exs
#     just release 0.7.0      # skip the menu and release exactly this version
#
# Shows the current and published versions, asks for a patch/minor/major bump
# (or any higher version you type in), updates the README install snippet,
# rolls the CHANGELOG, then (with your confirmation) commits, tags, and pushes —
# which starts the release workflow. The Hex publish still waits for your
# approval on the `hex` GitHub environment.
#
# Standalone Elixir — no mix/NIF compilation, just file edits + git.

defmodule Release do
  @release_files ["mix.exs", "README.md", "CHANGELOG.md"]

  def run(argv) do
    {app, current} = read_mix()
    branch = trimmed(git!(["rev-parse", "--abbrev-ref", "HEAD"]))

    info("package", app)
    info("current (mix.exs)", current)
    if v = published(app), do: info("latest on Hex", v)
    info("branch", branch)

    ensure_clean_tree!()
    confirm_branch!(branch)

    new =
      case argv do
        [] -> choose(current)
        [version] -> validate!(version, current)
        _ -> die("usage: elixir scripts/release.exs [VERSION]")
      end

    unless yes?("bump #{current} → #{new} ?"), do: abort()

    bump_mix!(current, new)
    bump_readme!(app, new)
    roll_changelog!(new)

    IO.puts("\nchanges:")
    IO.puts(git!(["--no-pager", "diff", "--" | @release_files]))

    unless yes?("commit, tag v#{new}, and push? (this starts the release build)") do
      IO.puts("""
      Edits left in place, uncommitted.
      Run `git checkout -- #{Enum.join(@release_files, " ")}` to discard them.
      """)

      System.halt(0)
    end

    git!(["add" | @release_files])
    git!(["commit", "-m", "Release #{new}"])
    git!(["tag", "-a", "v#{new}", "-m", "v#{new}"])
    git!(["push", "origin", branch])
    git!(["push", "origin", "v#{new}"])

    IO.puts("""

    ✅ pushed v#{new} — the release workflow is building the NIFs.
       Final step: approve the `hex` deployment to publish:
       #{actions_url()}
    """)
  end

  # ── version choice ─────────────────────────────────────────────────────────
  defp choose(current) do
    {maj, min, pat} = parse(current)

    choices = %{
      "1" => {"patch", "#{maj}.#{min}.#{pat + 1}", "bug fixes"},
      "2" => {"minor", "#{maj}.#{min + 1}.0", "new features, backwards-compatible"},
      "3" => {"major", "#{maj + 1}.0.0", "breaking changes"}
    }

    IO.puts("\nselect the release type:")

    for k <- ["1", "2", "3"] do
      {name, ver, note} = choices[k]
      IO.puts("  #{k}) #{name} → #{ver}\t(#{note})")
    end

    IO.puts("  4) other → enter a version\t(e.g. to track upstream's number)")

    case prompt("choice [1-4, or type a version]: ") do
      "" -> abort()
      "4" -> validate!(prompt("version: "), current)
      input when is_map_key(choices, input) -> elem(choices[input], 1)
      input -> validate!(input, current)
    end
  end

  # A hand-entered version must be plain semver, move forward, and not collide
  # with an existing tag — the menu choices satisfy the first two by construction.
  defp validate!(input, current) do
    version = String.trim_leading(input, "v")

    with {:ok, parsed} <- Version.parse(version),
         :gt <- Version.compare(parsed, Version.parse!(current)) do
      if tag_exists?("v#{version}"), do: die("tag v#{version} already exists.")
      version
    else
      :error -> die("'#{input}' is not a version (expected MAJOR.MINOR.PATCH).")
      _ -> die("#{version} is not newer than the current #{current}.")
    end
  end

  # ── mix.exs ────────────────────────────────────────────────────────────────
  defp read_mix do
    src = File.read!("mix.exs")
    [_, version] = Regex.run(~r/@version "([^"]+)"/, src) || die("no @version in mix.exs")
    [_, app] = Regex.run(~r/app:\s*:([a-z0-9_]+)/, src) || die("no `app:` in mix.exs")
    {app, version}
  end

  defp parse(version) do
    [maj, min, pat] =
      version
      |> String.split("-")
      |> hd()
      |> String.split(".")
      |> Enum.map(&String.to_integer/1)

    {maj, min, pat}
  end

  defp bump_mix!(old, new) do
    src = File.read!("mix.exs")
    File.write!("mix.exs", String.replace(src, ~s(@version "#{old}"), ~s(@version "#{new}")))
  end

  # ── README ─────────────────────────────────────────────────────────────────
  # Keeps the install snippet (`{:app, "~> X.Y"}`) pointing at the new series.
  defp bump_readme!(app, new) do
    {maj, min, _} = parse(new)

    with true <- File.exists?("README.md") do
      src = File.read!("README.md")

      File.write!(
        "README.md",
        Regex.replace(~r/(\{:#{app},\s*"~> )[^"]+(")/, src, "\\g{1}#{maj}.#{min}\\g{2}")
      )
    end
  end

  # ── CHANGELOG ──────────────────────────────────────────────────────────────
  defp roll_changelog!(new) do
    path = "CHANGELOG.md"

    with true <- File.exists?(path),
         src = File.read!(path),
         true <- String.contains?(src, "## [Unreleased]") do
      today = Date.to_iso8601(Date.utc_today())
      heading = "## [Unreleased]\n\n## #{new} - #{today}"
      File.write!(path, String.replace(src, "## [Unreleased]", heading, global: false))
    else
      _ -> :ok
    end
  end

  # ── Hex (best-effort) ──────────────────────────────────────────────────────
  defp published(app) do
    case System.cmd("mix", ["hex.info", app], stderr_to_stdout: true) do
      {out, 0} -> Regex.run(~r/[0-9]+\.[0-9]+\.[0-9]+/, out) |> then(&(&1 && hd(&1)))
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # ── git ────────────────────────────────────────────────────────────────────
  defp ensure_clean_tree! do
    case trimmed(git!(["status", "--porcelain"])) do
      "" -> :ok
      _ -> die("working tree is dirty — commit or stash first.")
    end
  end

  defp tag_exists?(tag) do
    match?(
      {_, 0},
      System.cmd("git", ["rev-parse", "-q", "--verify", "refs/tags/#{tag}"],
        stderr_to_stdout: true
      )
    )
  end

  defp confirm_branch!(b) when b in ["master", "main"], do: :ok

  defp confirm_branch!(b) do
    unless yes?("⚠  not on master/main (on '#{b}'). release from here anyway?"), do: abort()
  end

  defp git!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, code} -> die("git #{Enum.join(args, " ")} failed (#{code}):\n#{out}")
    end
  end

  defp actions_url do
    case System.cmd("git", ["config", "--get", "remote.origin.url"]) do
      {url, 0} ->
        slug =
          url
          |> String.trim()
          |> String.replace(~r/\.git$/, "")
          |> String.replace(~r{^git@github\.com:}, "")
          |> String.replace(~r{^https://github\.com/}, "")

        "https://github.com/#{slug}/actions"

      _ ->
        "your repo's Actions tab"
    end
  end

  # ── IO ─────────────────────────────────────────────────────────────────────
  defp info(label, value), do: IO.puts(String.pad_trailing("#{label}:", 19) <> value)
  defp prompt(label), do: IO.gets(label) |> to_string() |> String.trim()
  defp yes?(question), do: prompt("#{question} [y/N] ") =~ ~r/^[Yy]/
  defp trimmed(s), do: String.trim(s)
  defp abort, do: die("aborted.")

  defp die(msg) do
    IO.puts(:stderr, "✗ #{msg}")
    System.halt(1)
  end
end

Release.run(System.argv())
