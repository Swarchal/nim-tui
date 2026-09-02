import std/[os, strutils]

# Package

version       = "0.4.0"
author        = "Scott Warchal"
description   = "A Nim library for building terminal UI applications, inspired by Bubble Tea"
license       = "MIT"
srcDir        = "src"
skipDirs      = @["examples", "scripts"]

# Dependencies

requires "nim >= 2.0.0"

task examples, "Build every example into bin/, several at once":
  # The loop lives in a compiled helper: NimScript has no `osproc`, and `exec`
  # blocks, so anything written here is sequential. See the file for the why and
  # for how much parallelism actually buys.
  exec "nim r --hints:off scripts/build_examples.nim"

task docs, "Generate API documentation into htmldocs/":
  exec "nim doc --project --index:on --outdir:htmldocs src/nimtui.nim"

task snippets, "Build examples/treesitter/*.nim (needs nim-treesitter)":
  # Kept out of `examples` on purpose: that task builds every file in examples/,
  # and these need a second library. A subdirectory is enough, since the glob in
  # scripts/build_examples.nim is not recursive.
  #
  # nim-treesitter is not a `requires`: it is needed by one example and by
  # nothing in src/, and it vendors its own tree-sitter runtime and grammars as
  # C sources, which a nimble install does not carry (its `installExt` is .nim
  # only). So the dependency is a checkout on the path rather than a package —
  # $TREESITTER_SRC if set, a sibling clone if there is one, and otherwise
  # cloned into deps/ from the repo below. This mirrors that library's own
  # `nimble adapter` task, which finds nimtui the same way.
  const Repo = "https://github.com/Swarchal/nim-treesitter"
  mkDir "bin"
  var ts = getEnv("TREESITTER_SRC")
  if ts.len == 0:
    for dir in ["../nim-treesitter", "deps/nim-treesitter"]:
      if dirExists(dir / "src"):
        ts = dir / "src"
        break
  if ts.len == 0:
    echo "cloning ", Repo, " into deps/nim-treesitter"
    mkDir "deps"
    exec "git clone --depth 1 " & Repo & " deps/nim-treesitter"
    ts = "deps/nim-treesitter/src"

  for f in listFiles("examples/treesitter"):
    if f.endsWith(".nim"):
      exec "nim c --path:src --path:" & ts & " -d:release -o:bin/" &
        f.splitFile.name & " " & f
