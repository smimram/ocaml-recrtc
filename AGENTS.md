# AGENTS.md

## Project

`recrtc` — an OCaml web application. The server is a small
[Dream](https://aantron.github.io/dream/) app (`src/recrtc.ml`) that serves the
static frontend in `static/`: `/` maps to `static/index.html`, everything else
is served from `static/` by `Dream.static`. The client side lives entirely in
`static/index.html` for now (no bundler, no JS toolchain).

The project is at an early stage: the server is minimal and the page is a
placeholder.

## Layout

- `src/recrtc.ml` — Dream server (routing, static file serving).
- `src/dune` — executable `recrtc`, depends on the `dream` library.
- `static/` — frontend assets served as-is.
- `dune-project` — `(lang dune 3.14)`.
- `Makefile` — thin wrapper over dune.

## Build and run

```sh
make          # or: dune build
make serve    # or: dune exec src/recrtc.exe   -- serves on http://localhost:8080
```

There are no tests yet. After changing OCaml code, run `dune build` to check it
compiles; after changing `static/`, restart the server (files are read from disk
at request time, so a reload of the page is enough unless routing changed).

## Conventions

- OCaml code is formatted in ocamlformat's default style, but there is no
  `.ocamlformat` file, so `dune build @fmt` only reformats `dune` files and
  skips `.ml` files. Match the existing style by hand; do not add a
  `.ocamlformat` unless asked.
- `.gitignore` covers `_build` and editor backups (`*~`). Untracked `*~` files
  in the tree are Emacs backups — leave them alone.
- Commit messages are short capitalized sentences ending with a period
  (e.g. "Minimal server.").
