// podcomp — a Compose Spec implementation with a Podman backend.
//
// It reads the same `compose.yaml` / `docker-compose.yml` files Docker Compose
// reads, merges and interpolates them, and drives `podman` directly: no
// daemon, no background process, one native binary.
//
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "kupas/podcomp"

version = "0.1.3"

readme = "README.mbt.md"

repository = "https://github.com/tomasky/podcomp"

license = "Apache-2.0"

keywords = [
  "podman",
  "compose",
  "docker-compose",
  "containers",
  "cli",
  "moonbit",
]

description = "A Compose Spec implementation that runs on Podman, written in MoonBit"

preferred_target = "native"

import {
  "moonbit-community/yaml@0.0.7",
  "moonbitlang/async@0.22.4",
  "moonbitlang/x@0.5.5",
}
