# ExHtmltopdf Porting Playbook

How to grow this scaffold into a complete, community-grade Elixir wrapper
around [sghtmltopdf](https://github.com/waka/sghtmltopdf). It carries the
lessons from the sibling projects **ExMonty** (Python interpreter NIF) and
**ExBashkit** (bash interpreter NIF — read its `PORTING.md` for the general
framework lessons; they are not repeated in full here) and lays out a staged
plan for the parts that are genuinely different — chiefly that sghtmltopdf is
a *batch renderer* with a *shared CLI option parser*, not an interactive
interpreter.

Read this top-to-bottom once, then work the phases in order. Each phase is
shippable on its own.

---

## 0. The shape of the thing

ExHtmltopdf is a thin **Rustler NIF** over the `sghtmltopdf` crate,
distributed as a **precompiled binary** via `rustler_precompiled` so end users
need no Rust toolchain. sghtmltopdf renders HTML to PDF using Servo components
(html5ever, Stylo, Taffy) — no headless browser, no external binary.

```
lib/ex_htmltopdf.ex          # render/2, render!/2, render_to_file/3(!)
lib/ex_htmltopdf/options.ex  # keyword opts → CLI argv
lib/ex_htmltopdf/error.ex    # %ExHtmltopdf.Error{kind, message}
lib/ex_htmltopdf/native.ex   # RustlerPrecompiled config + NIF stubs
native/ex_htmltopdf/src/lib.rs  # #[rustler::nif] fns (thin bridge)
```

**Golden rule (carried from ExMonty/ExBashkit):** vendor *no* rendering or
option logic on the Elixir side. Every semantic comes from sghtmltopdf. We
only marshal data across the boundary.

**The load-bearing design decision:** upstream deliberately routes every
entry point — CLI, HTTP server, Ruby gem — through **one option parser**,
fronted for bindings by `Converter::from_args` (originally
`cli::parse_convert_argv`). The Ruby binding builds a CLI argv from a Ruby
hash and passes it through; we do exactly the same from Elixir
(`ExHtmltopdf.Options.to_argv/1`). This means:

- zero option-decoding code in Rust (no drift when upstream adds a flag —
  new options work from Elixir the day the pin is bumped, no code change);
- the upstream docs for CLI flags *are* our option docs;
- our NIF crate needs upstream's `cli` feature (that's where the shared
  parser lives), but not `server` (tiny_http — useless inside the BEAM).

Do not "improve" this into a typed Rust options decoder. One surface.

## 1. What's genuinely different about sghtmltopdf

### a) Batch rendering, not interactive execution

monty yields per-effect; bashkit calls back into Elixir mid-run. sghtmltopdf
does neither: HTML in, PDF out, no host callbacks during the render (assets
come from disk/network subject to engine policy). So **none of the back-call
machinery** (pending tables, reply NIFs, handler processes, cancellation-leak
guards) exists here — until/unless we build streaming (phase 2), whose chunk
delivery is one-directional (Rust → BEAM messages) and much simpler.

### b) The 16 MiB render stack

Layout/paint recursion can exceed default thread stacks. Upstream renders on
a dedicated big-stack thread from *every* entry point (`cli::with_render_stack`,
16 MiB — the Ruby binding learned this against Ruby's 1 MiB thread stacks).
Our NIFs must always wrap the render in `with_render_stack`; a dirty
scheduler's stack is not guaranteed to be big enough. The NIF blocks a
DirtyCpu scheduler for the duration (fine — that's what dirty CPU schedulers
are for; concurrency is bounded by the dirty CPU pool size).

### c) Deadlines exist but are not a CLI flag

`ConvertArgs.deadline: Option<Instant>` is how the HTTP server bounds a
request (`--timeout` is a *server launch* option, not a convert option), and
`clap(skip)` keeps it out of the parser. Exposing `timeout_ms:` from Elixir
means setting `deadline` on the parsed `ConvertArgs` **after**
`parse_convert_argv` — a small, honest post-parse touch-up in the NIF, and
the one place we deviate from pure argv passthrough (phase 3).
**As of upstream v0.7.0 this is blocked:** bindings now go through
`Converter`, whose `ConvertArgs` is private, and `convert::render_with` is
`pub(crate)`, so there is no way to set `deadline` from outside the crate.
Phase 3 needs an upstream API (e.g. `Converter::with_deadline`) first. Note the
upstream caveat: the deadline is checked between chunks/elements/pages, so
overruns are detected late by up to one layout call. A running dirty NIF
cannot be killed from the BEAM — the deadline is the *only* way to bound a
pathological document. `Task.shutdown` does not stop it (same lesson as
bashkit).

### d) Security posture is per-render config

- `allow_remote_assets: true` opts into http(s) asset fetches (default off).
- Local file access defaults to **allowed, unrestricted** (upstream CLI
  compat). For untrusted HTML, callers must pass
  `disable_local_file_access: true` or `allow: [dirs]`.
- We inherit these semantics; we do not re-implement them. But our docs must
  state them loudly (README "Rendering untrusted HTML" section), and the
  audit phase must test path escape attempts against the pinned upstream.

### e) Fonts

`--font`/`--font-index` pair positionally (index binds to the nearest
preceding font). `Options.to_argv/1` already encodes this; don't reorder
pairs. System font fallback uses fontdb; generic families are overridable
(`gothic_font:`/`serif_font:`/`mono_font:`).

### f) Upstream is pinned by git hash

Like ExMonty we pin a full 40-char git hash of the commit a release tag
points at. (The crate was git-only when this was written; it is now
also on crates.io as `sghtmltopdf`. The git pin stays because
`ExHtmltopdf.upstream_revision/0` reads the hash from `Cargo.toml`.) `UPDATE_PROCEDURE.md` has the bump procedure. Upstream is at
`../sghtmltopdf` (sibling checkout).

---

## 2. Staged plan

Each phase: implement the NIF(s), add the Elixir API, write tests
(`EXHTMLTOPDF_BUILD=1 mix test`), update README + CHANGELOG, keep CI green.
Per-phase loop that worked on ExBashkit: TDD (failing test first) → implement
→ full gate (`mix test` + `mix format` + `cargo fmt` + `cargo clippy -D
warnings` + `mix compile --warnings-as-errors`) → dispatch the code-reviewer
subagent → fold fixes → commit → watch CI.

### Phase 1 — `render/2` + `render_to_file/3` ✅ (this scaffold)

- `render(html, opts)` → `{:ok, pdf_binary}`; DirtyCpu NIF; options through
  `Converter::from_args`; render inside `with_render_stack`;
  `Converter::render_to_vec`.
- `render_to_file(html, path, opts)` → `:ok`; `FileSink` (temp file + rename,
  never leaves a truncated PDF).
- Errors: `ConvertError`'s four classes (`Usage`/`Input`/`Render`/`Timeout`) →
  `{:error, %Error{kind: :usage | :input | :render | :timeout}}`, plus
  `:panic` for contained native panics (`catch_unwind` inside the NIF keeps
  the error contract total; rustler's own catch would raise an opaque
  `ErlangError`).
- `default_page_size/0` smoke NIF proving core linkage (Ruby binding does
  the same); `upstream_revision/0` surfaces the Cargo pin (compile-time
  extracted, can't drift).
- **Deviation from upstream (reviewer-caught):** `FileSink` derives its temp
  name from `std::process::id()` alone — unique per CLI invocation, NOT
  unique when N dirty schedulers write the same path inside one BEAM
  process (interleaved writes into a shared temp file). Our NIF points
  FileSink at a per-call unique intermediate (`.<pid>-<seq>.part`) and does
  the final rename itself. *Candidate upstream issue: `.tmp-<pid>` is not
  unique in any threaded embedder — worth reporting.*

### Phase 2 — Streaming output

`render_stream(html, opts)` returning a `Stream`/`Enumerable` of PDF chunks,
or `render_each(html, opts, fun)`. Upstream support: `--streaming` mode +
`BufferedSink` (used for multipart uploads; min part size 5 MiB) and the Ruby
binding's `render_each` (chunked callback). For Elixir the natural bridge is
a sink that `send`s chunks to the caller pid; the caller assembles a lazy
`Stream.resource/3`. One direction only — no reply channel needed — but the
send must happen off the render thread correctly (`OwnedEnv`; recall
ExBashkit's hard-won rule that `send_and_clear` panics on BEAM-managed
threads — here the render thread is our own spawn, so it's the safe side,
but verify). Constraint to surface in docs: streaming mode forbids
`[topage]` in headers/footers (total pages unknown mid-stream) — upstream
returns a `Render` error; ensure a test covers it.

### Phase 3 — Deadlines / cancellation bound

`timeout_ms:` option → set `ConvertArgs.deadline` post-parse (see 1c).
Timeout surfaces as `{:error, %Error{kind: :timeout}}` (exit code 4 upstream,
already mapped). Tests: a pathological/huge document times out, the error is
`:timeout`, the scheduler is released, subsequent renders work.

### Phase 4 — Ergonomics & integration recipes

- Phoenix/LiveView recipe in README (render a heex-produced HTML string).
- `examples/` scripts: invoice with header/footer + TOC; custom fonts; CJK.
- Consider `page_count/1` or PDF metadata passthrough only if upstream
  exposes it — do not parse PDFs ourselves (golden rule).
- Explicit non-goals: HTTP server mode (`server` feature — Plug/Bandit
  exists), wkhtmltopdf compat shims beyond upstream's own.

### Phase 5 — Hardening & audit

Run `RUST_NIF_AUDIT_STARTFILE.md` (copied verbatim from the framework; the
auditor replaces the ExMonty profile with this repo's after discovery).
sghtmltopdf-specific surfaces to seed the audit: hostile HTML/CSS (recursion
depth, allocation amplification, decompression bombs in images), path escape
via `base_dir`/`--allow`, SSRF via `allow_remote_assets` (upstream has an
SSRF guard — `spike_image_fetch_ssrf_guard.rs` — verify it holds at our pin),
malformed UTF-8/NULs in argv values, huge argv, `deadline` boundary races,
panic containment, and FileSink temp-file behavior on weird paths.

### Release

First release follows `UPDATE_PROCEDURE.md` §Release: tag `v0.1.0` → CI
builds 4 target NIFs + GitHub release → the `publish` job regenerates the
checksum file from the released artifacts and publishes to Hex after manual
approval of the `hex` environment. Hex publish is **the user's call**.

---

## 3. Definition of done (per phase and overall)

- [ ] NIF stubs in `native.ex` match the `#[rustler::nif]` fns exactly.
- [ ] Public functions have moduledocs, `@spec`s, and doctests/tests.
- [ ] `EXHTMLTOPDF_BUILD=1 mix test` green; `cargo fmt`/`clippy` clean.
- [ ] README capability section + CHANGELOG `[Unreleased]` entry.
- [ ] An `examples/` script demonstrating the new capability end-to-end.
- [ ] No vendored rendering/option logic — semantics come from sghtmltopdf.

When in doubt, open ExMonty/ExBashkit (in `~/Desktop/lib/`) and copy the
proven shape.
