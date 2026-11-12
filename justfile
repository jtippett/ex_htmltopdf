# Project commands. Run `just --list` to see them all.

# Interactive release: pick patch/minor/major (or `just release 0.7.0` for an
# exact version), roll the CHANGELOG, tag & push.
release *version:
    elixir scripts/release.exs {{version}}

# Run the test suite (builds the NIF locally).
test:
    EXHTMLTOPDF_BUILD=1 mix test

# Format Elixir + Rust.
fmt:
    mix format
    cd native/ex_htmltopdf && cargo fmt
