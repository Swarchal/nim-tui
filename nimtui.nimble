import std/[os, strutils]

# Package

version       = "0.4.0"
author        = "Scott Warchal"
description   = "A Nim library for building terminal UI applications, inspired by Bubble Tea"
license       = "MIT"
srcDir        = "src"
skipDirs      = @["examples"]

# Dependencies

requires "nim >= 2.0.0"

task examples, "Build every example into bin/":
  mkDir "bin"
  for f in listFiles("examples"):
    if f.endsWith(".nim"):
      let name = f.extractFilename.changeFileExt("")
      echo "building ", name
      exec "nim c --path:src -d:release -o:bin/" & name & " " & f

task docs, "Generate API documentation into htmldocs/":
  exec "nim doc --project --index:on --outdir:htmldocs src/nimtui.nim"
