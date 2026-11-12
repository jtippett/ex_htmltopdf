//! Elixir NIF entry point for sghtmltopdf.
//!
//! This layer is kept thin, mirroring the upstream Ruby binding: the Elixir
//! side assembles the option list, and this side hands it to upstream's
//! [`Converter`] — the same option parser the CLI and HTTP server use — then
//! renders. No option semantics live here.

use std::io::Cursor;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use rustler::{Binary, Encoder, Env, NewBinary, Term};
use sghtmltopdf::{with_render_stack, ConvertError, Converter, FileSink};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        usage,
        input,
        render,
        timeout,
        panic,
    }
}

/// Renders `html` to a PDF returned as a binary.
///
/// The whole render runs on a dirty CPU scheduler; `with_render_stack` moves
/// it onto a dedicated 16 MiB-stack thread because layout/paint recursion can
/// exceed default thread stacks (upstream renders on such a thread from every
/// entry point).
#[rustler::nif(schedule = "DirtyCpu")]
fn render<'a>(env: Env<'a>, html: Binary<'a>, argv: Vec<String>) -> Term<'a> {
    let html = html.as_slice();

    let result = contain_panic(AssertUnwindSafe(|| {
        let converter = Converter::from_args(argv)?;
        with_render_stack(|| converter.render_to_vec(Cursor::new(html)))
    }));

    match result {
        Ok(pdf) => {
            let mut bin = NewBinary::new(env, pdf.len());
            bin.as_mut_slice().copy_from_slice(&pdf);
            (atoms::ok(), Binary::from(bin)).encode(env)
        }
        Err(err) => error_term(env, err),
    }
}

/// Renders `html` to a PDF written at `path`.
///
/// Writes are atomic: the render goes to a sibling temp path and is renamed
/// into place on success, so a failed render never leaves a truncated PDF
/// behind. [`FileSink`] already does temp+rename, but derives its temp name
/// from the process id alone — unique per CLI invocation, **not** unique when
/// N dirty schedulers render to the same path inside one BEAM process. We
/// point FileSink at a per-call unique intermediate (its own temp name derives
/// from that, staying unique too) and do the final rename ourselves.
#[rustler::nif(schedule = "DirtyCpu")]
fn render_to_file<'a>(env: Env<'a>, html: Binary<'a>, argv: Vec<String>, path: String) -> Term<'a> {
    static CALL_SEQ: AtomicU64 = AtomicU64::new(0);

    let html = html.as_slice();

    let result = contain_panic(AssertUnwindSafe(|| {
        let converter = Converter::from_args(argv)?;
        let path = PathBuf::from(path);

        let mut intermediate = path.clone().into_os_string();
        intermediate.push(format!(
            ".{}-{}.part",
            std::process::id(),
            CALL_SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        let intermediate = PathBuf::from(intermediate);

        let sink = FileSink::create(&intermediate).map_err(|e| {
            ConvertError::Input(format!("failed to create {}: {e}", path.display()))
        })?;
        with_render_stack(|| converter.render(Cursor::new(html), sink))?;

        std::fs::rename(&intermediate, &path).map_err(|e| {
            let _ = std::fs::remove_file(&intermediate);
            ConvertError::Input(format!("failed to move PDF into {}: {e}", path.display()))
        })
    }));

    match result {
        Ok(()) => atoms::ok().encode(env),
        Err(err) => error_term(env, err),
    }
}

/// Calls one real core symbol so tests can prove the NIF loaded and linked
/// against sghtmltopdf without paying for a render (same probe the Ruby
/// binding uses).
#[rustler::nif]
fn default_page_size() -> String {
    let settings = sghtmltopdf::PageSettings::default();
    format!("{}x{}", settings.size.width, settings.size.height)
}

/// An error crossing back to the BEAM: either a structured [`ConvertError`] or a
/// caught panic message.
enum NifError {
    Cli(ConvertError),
    Panic(String),
}

impl From<ConvertError> for NifError {
    fn from(e: ConvertError) -> Self {
        Self::Cli(e)
    }
}

/// Runs `f`, converting any panic into a bounded error instead of letting it
/// unwind into the scheduler. Rustler would catch it too, but as an opaque
/// `ErlangError`; this keeps the `{:error, {kind, message}}` contract total.
fn contain_panic<R>(
    f: impl FnOnce() -> Result<R, ConvertError> + std::panic::UnwindSafe,
) -> Result<R, NifError> {
    match catch_unwind(f) {
        Ok(result) => result.map_err(NifError::Cli),
        Err(payload) => {
            let msg = if let Some(s) = payload.downcast_ref::<&str>() {
                (*s).to_string()
            } else if let Some(s) = payload.downcast_ref::<String>() {
                s.clone()
            } else {
                "unknown panic".to_string()
            };
            Err(NifError::Panic(format!("panic in sghtmltopdf: {msg}")))
        }
    }
}

/// `{:error, {kind, message}}` — kinds mirror `ConvertError`'s exit-code variants.
fn error_term(env: Env<'_>, err: NifError) -> Term<'_> {
    let (kind, message) = match err {
        NifError::Cli(ConvertError::Usage(m)) => (atoms::usage(), m),
        NifError::Cli(ConvertError::Input(m)) => (atoms::input(), m),
        NifError::Cli(ConvertError::Render(m)) => (atoms::render(), m),
        NifError::Cli(ConvertError::Timeout(m)) => (atoms::timeout(), m),
        // `ConvertError` is #[non_exhaustive]. A variant added upstream that we
        // have not classified yet surfaces as a render failure rather than
        // breaking the build of a patch-level bump; UPDATE_PROCEDURE.md checks
        // the variant list on every update so this arm stays unreached.
        NifError::Cli(other) => (atoms::render(), other.to_string()),
        NifError::Panic(m) => (atoms::panic(), m),
    };
    (atoms::error(), (kind, message)).encode(env)
}

rustler::init!("Elixir.ExHtmltopdf.Native");
