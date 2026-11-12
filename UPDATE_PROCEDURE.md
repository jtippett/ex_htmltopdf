# ExHtmltopdf Update Procedure

Run this procedure periodically to pull upstream sghtmltopdf changes and
update ExHtmltopdf.

## Overview

ExHtmltopdf pins an exact sghtmltopdf version from crates.io
(`sghtmltopdf = { version = "=X.Y.Z", … }` in
`native/ex_htmltopdf/Cargo.toml`). This procedure walks through pulling,
assessing, and integrating changes.

**Track tagged releases, not `main`.** Upstream cuts `v0.x.y` tags; target the
latest tag unless the user explicitly asks to chase `main`.

The upstream checkout lives at `../sghtmltopdf` relative to this project root.

---

## Phase 1: Pull and Assess

### 1.1 Fetch latest upstream and find the latest tag

```bash
cd ../sghtmltopdf && git fetch origin --tags
git tag --sort=-version:refname | head -5
```

Pick the highest tag. That's the **target** for this update. Confirm the
same version is on crates.io (`cargo info sghtmltopdf`) — upstream publishes
the crate as part of cutting the tag. Check the
tag out (`git checkout --detach <TARGET_TAG>`) — Phase 2's path dependency
builds whatever the working tree holds.

Read `CHANGELOG.md` at the target tag first: its `Changed`/`Removed`
sections are the fastest route to what breaks, and the source for our own
CHANGELOG entry.

zsh note: write `git show ${TAG}:path`, not `$TAG:path` — `:c` and friends
are history modifiers and silently eat the first character of the path.

### 1.2 Identify our current pin

```bash
grep '^sghtmltopdf = ' native/ex_htmltopdf/Cargo.toml
```

Our pin is the tag `v<that version>`; use it as `<OUR_PINNED_REV>` below.

### 1.3 Review changes since our pin

Our contract with upstream is narrower than ExMonty's — almost everything
flows through the shared CLI parser. Review, in order of importance:

```bash
cd ../sghtmltopdf

# 1. The option surface (this IS our API — new/renamed/removed flags flow
#    straight through Options.to_argv/1 to users):
git diff <OUR_PINNED_REV>..<TARGET_TAG> -- \
  core/src/cli/options.rs core/src/cli/unsupported.rs

# 2. The functions we call directly:
git diff <OUR_PINNED_REV>..<TARGET_TAG> -- \
  core/src/lib.rs core/src/cli/mod.rs core/src/cli/converter.rs \
  core/src/render_stack.rs core/src/sink/mod.rs

# 2b. Features and MSRV (compare with what bindings/ruby enables):
git diff <OUR_PINNED_REV>..<TARGET_TAG> -- \
  core/Cargo.toml bindings/ruby/ext/sghtmltopdf/Cargo.toml

# 3. Engine surfaces backing security-relevant options:
git diff <OUR_PINNED_REV>..<TARGET_TAG> -- \
  core/src/engine.rs core/src/img core/src/fonts

# 4. What the Ruby binding had to change (they hit our problems first):
git log --oneline <OUR_PINNED_REV>..<TARGET_TAG> -- bindings/ruby
```

We call exactly these crate-root re-exports (upstream's semver-covered
public API): `Converter::{from_args, render, render_to_vec}`,
`with_render_stack`, `ConvertError` (four variants), `FileSink::create`, and
`PageSettings` (smoke probe). A change to any of their signatures is a
breaking change for us.

For every update, explicitly re-check these invariants rather than relying
on compilation:

- `Converter::from_args` still takes the flags alone — no program name, no
  input path, `--output` rejected (`Options.to_argv/1` emits exactly that);
- `FileSink` still writes temp-file-then-rename (our "no truncated PDF"
  doc promise), and its temp name is still derived from the pid alone (if it
  becomes unique per call, the `.part` intermediate in `render_to_file` can
  go);
- remote asset fetching is still default-off; local file access defaults and
  `--allow` containment semantics unchanged (README security section);
- `ConvertError` variants still map 1:1 to our `Error.kind`s. The enum is
  `#[non_exhaustive]`, so a new variant **compiles** and falls into the
  catch-all arm as `:render` — diff the enum by eye and add a kind;
- the feature set still matches the Ruby gem's (`cli` + `svg` today), and
  `rust-version` in our `Cargo.toml` is at least upstream's;
- `with_render_stack`'s stack size still covers the engine's recursion needs
  (upstream owns this, but a removal/rename breaks us loudly — good).

### 1.4 New CLI flags = free features

New flags work through `Options.to_argv/1` with zero code changes. Still:
mention notable ones in the README options list and CHANGELOG so Elixir
users can discover them.

---

## Phase 2: Update

### 2.1 Switch to a path dependency for development

Edit `native/ex_htmltopdf/Cargo.toml`:

```toml
# sghtmltopdf = { version = "=X.Y.Z", default-features = false, features = ["cli", "svg"] }
sghtmltopdf = { path = "../../../sghtmltopdf/core", default-features = false, features = ["cli", "svg"] }
```

(`ExHtmltopdf.upstream_version/0` reads `Cargo.lock`, so it keeps working
here; the test comparing it with the `Cargo.toml` pin fails until Phase 3 —
expected.)

### 2.2 Build, fix, test

```bash
cd native/ex_htmltopdf && cargo check
cd ../.. && EXHTMLTOPDF_BUILD=1 mix test
```

If upstream changed rendered output (not API), some assertions may need
updating — prefer structural assertions (`<<"%PDF-", _::binary>>`, error
kinds) over golden bytes, so this stays rare.

### 2.3 Update docs

New flags or changed defaults → README options list, `ExHtmltopdf`
moduledoc (especially the security posture section), CHANGELOG `[Unreleased]`.

---

## Phase 3: Pin and Ship

### 3.1 Switch back to the crates.io dependency

```toml
sghtmltopdf = { version = "=<TARGET_VERSION>", default-features = false, features = ["cli", "svg"] }
```

Exact (`=`), not caret: upstream is pre-1.0 and changes rendered output
between releases, so a bump is always this procedure, never a side effect of
`cargo update`. crates.io versions are immutable and the lockfile carries
the checksum.

If an urgent fix exists only on upstream `main`, a temporary
`git = "…", rev = "<FULL_40_CHAR_HASH>"` dependency works — ask the user
first, and return to a crates.io version at the next tag.

### 3.2 Verify a clean build from crates.io

```bash
cd native/ex_htmltopdf && cargo update -p sghtmltopdf
cd ../.. && mix clean && EXHTMLTOPDF_BUILD=1 mix test
```

### 3.3 CHANGELOG + commit

```
Update sghtmltopdf to <version>

- <breaking changes fixed>
- <new flags now available>
- <upstream improvements picked up>
```

---

## Release

Run `just release` (interactive: bumps mix.exs and the README install
snippet, rolls the CHANGELOG, tags, pushes), or `just release <VERSION>` to
release an exact version. The tag push triggers `.github/workflows/release.yml`:

1. builds the 4 target NIFs and attaches them to a GitHub release;
2. the `publish` job (gated on approval of the `hex` GitHub environment)
   regenerates `checksum-Elixir.ExHtmltopdf.Native.exs` from the released
   artifacts via `mix rustler_precompiled.download ExHtmltopdf.Native
   --all --print`, then publishes to Hex.

The checksum file must come from the *released* artifacts — never commit one
generated from a local build (the ExMonty 0.4.0 re-tag lesson).

## When to Update

- **When upstream cuts a new tag** — the natural cadence.
- **Immediately** if upstream fixes a bug affecting us (chase `main` or wait
  for the next tag depending on severity — ask the user).
- **Before any ExHtmltopdf release** to pick up the latest stable tag.
