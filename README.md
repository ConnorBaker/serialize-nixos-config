# serialize-nixos-config

> [!CAUTION]
> The contents of this repository were vibe-coded. Review carefully
> before relying on any of it.

Tools for producing JSON-safe snapshots of evaluated NixOS configs, and
for diffing those snapshots with external tools (`dyff`, `jd`, `jq`)
instead of hand-reading 200 000-line `nix eval` dumps.

The use case is answering questions like *"what actually changed between
host `alpha` and host `beta`?"*, or *"does this refactor move the module
graph, or just rename things?"*, without being drowned in store-path
churn, alias triplication, and subtrees that `abort` when forced.

## What's in here

- [`serialize.nix`](./serialize.nix) — a pure Nix walker. Given an
  evaluated NixOS `config` (and optionally its `options`), it returns
  a nested attrset that mirrors `config` but is safe to feed to
  `builtins.toJSON`. Derivations collapse to their `outPath`,
  functions become `"<function>"`, disabled submodules collapse to
  `{ enable = false; }`, alias options (renamed via
  `mkAliasOptionModule` / `mkRenamedOptionModule`) are pruned to
  `"<alias>"`, and a small set of known-problematic subtrees
  (`.pkgs`, `.system`, `.assertions`, per-language `Packages` sets,
  …) are elided.
- [`diff-configs/`](./diff-configs) — a `writeShellApplication`
  wrapping `nix eval` + `dyff` / `jd`. Takes two
  [Nix installables](https://nix.dev/manual/nix/latest/command-ref/new-cli/nix3-build.html#installables)
  (flake URIs, `path:…#attr`, or `-f FILE attr` for plain `.nix`
  files), evaluates both to JSON, and prints a human-readable diff.
  Exposed as `packages.default` on every supported system; run it
  with `nix run .# -- …`. The directory contains a
  [`package.nix`](./diff-configs/package.nix), the script
  [`diff-configs.sh`](./diff-configs/diff-configs.sh), and
  [`patch-to-markdown.jq`](./diff-configs/patch-to-markdown.jq),
  which classifies `jd`'s RFC 6902 patch output into
  `changed` / `only-in-left` / `only-in-right` and renders a
  markdown table, one row per path (used when `--format markdown`
  is passed).
- [`flake.nix`](./flake.nix) — exposes `lib.serialize`, the
  `diff-configs` package, plus two worked examples
  (`nixosConfigurations.exampleA` / `exampleB`) and their
  pre-serialized outputs under `serialized.{exampleA,exampleB}`.

## Quick start: diff the two example configs

The flake ships two minimal `nixosConfigurations` that differ only in
hostname, timezone, sshd port, and one extra system package. Their
serialized mirrors are exposed as `serialized.exampleA` and
`serialized.exampleB`, so you can diff them directly via flake URIs:

```sh
nix run .# -- .#serialized.exampleA .#serialized.exampleB
```

That prints a `dyff`-style per-change stanza view. For a one-row-per-
change markdown table, pass `--format markdown`:

```sh
nix run .# -- --format markdown .#serialized.exampleA .#serialized.exampleB
```

Filtered to the rows you'd expect, the output looks like:

```
| Path                          | Kind    | .#serialized.exampleA | .#serialized.exampleB |
|-------------------------------|---------|-----------------------|------------------------|
| environment.etc.hostname.text | changed | alpha␤                | beta␤                  |
| networking.hostName           | changed | alpha                 | beta                   |
| services.openssh.ports.0      | changed | 22                    | 2222                   |
| time.timeZone                 | changed | UTC                   | America/New_York       |
```

(`␤` is `patch-to-markdown.jq`'s single-line stand-in for embedded
newlines — `/etc/hostname` has a trailing `\n`.)

There are also downstream rows the walker *does* surface — store paths
for generated files (`/etc/hostname.source`, initrd contents), new
entries in `environment.systemPackages` for the extra `htop` package,
and so on. That's the point: you see the full closure-level effect of
each source-level change.

Any installable `nix eval` accepts works, not just `.#…`:

```sh
# Compare a local checkout to the same flake on GitHub
nix run .# -- .#serialized.exampleA github:you/repo#serialized.exampleA

# Compare attrs in a plain .nix file (example structure:
#   { foo = serialize { ... }; bar = serialize { ... }; })
nix run .# -- -f ./configs.nix foo bar
```

Any extra positional args pass through to the underlying diff tool:

```sh
nix run .# -- .#serialized.exampleA .#serialized.exampleB -o brief
```

## Using it on your own configs

The pattern is the same as `flake.nix` uses: evaluate your NixOS
system, pass it into `serialize`, and expose the result as a flake
output.

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
    serialize-nixos-config.url = "github:ConnorBaker/serialize-nixos-config";
    serialize-nixos-config.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, serialize-nixos-config, self, ... }: {
    nixosConfigurations = {
      myHost = nixpkgs.lib.nixosSystem { modules = [ ./hosts/myHost ]; };
      myHostRefactor = nixpkgs.lib.nixosSystem { modules = [ ./hosts/myHostRefactor ]; };
    };

    serialized = nixpkgs.lib.mapAttrs
      (_: sys: serialize-nixos-config.lib.serialize.serialize {
        inherit (sys) config options;
      })
      self.nixosConfigurations;
  };
}
```

Then, from within your flake:

```sh
nix run github:ConnorBaker/serialize-nixos-config -- \
  .#serialized.myHost .#serialized.myHostRefactor
```

If evaluation hits an uncatchable `abort` or `attribute 'X' missing`
error (some nixpkgs modules, notably `hardware.nvidia.gsp`, have
defaults that explode when forced out of context), extend
`skipPatterns`:

```nix
serialize-nixos-config.lib.serialize.serialize {
  inherit (sys) config options;
  skipPatterns =
    serialize-nixos-config.lib.serialize.defaultSkipPatterns
    ++ [ ".nvidia" ];
}
```

Suffix-matched against the dotted path at every node. See the comment
on `defaultSkipPatterns` in [`serialize.nix`](./serialize.nix) for the
full rationale.

## Why not just `nix eval .#nixosConfigurations.x.config --json`?

Two reasons:

1. It doesn't work — `builtins.toJSON` explodes on functions, on
   derivations (their `drvPath` forces the whole build closure), and
   on several nixpkgs modules whose defaults deliberately
   `abort`/`throw` when forced without context.
2. Even if it did, the raw tree is enormous and mostly noise:
   alias-renamed options appear two-to-three times, `meta.*` fields
   churn on every nixpkgs bump, entire language-specific
   `Packages` sets get forced, etc. `serialize` collapses or elides
   all of that, leaving the user-meaningful shape intact.

The output is designed to be diffed, not to round-trip back into a
usable NixOS config.

## Development

```sh
nix flake check        # runs pre-commit hooks (treefmt, nil, statix, deadnix)
nix fmt -- --ci        # treefmt in check mode
```
