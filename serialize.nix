/**
  Serialize a NixOS `config` tree (or any module-system evaluation) into
  a JSON-safe nested attrset, suitable for diffing with external tools
  like `dyff`, `jd`, or shell-based pipelines.

  Returns an attrset with:

  - `serialize`: the main walker.
  - `collectAliasPaths`: helper to derive the alias-path set from an
    `options` tree. Useful if you want to inspect or override it.
  - `defaultSkipPatterns`: the default path-suffix skip list, so callers
    can extend it rather than replace it.

  # Examples
  :::{.example}
  ## `serialize` usage example

  ```nix
  let
    inherit (import ./serialize.nix) serialize;
    sys = (builtins.getFlake "…").nixosConfigurations.foo;
  in
  serialize { inherit (sys) config options; }
  ```

  :::
*/

let
  inherit (builtins)
    attrValues
    concatMap
    concatStringsSep
    elem
    elemAt
    filter
    genList
    hasAttr
    head
    isAttrs
    length
    listToAttrs
    map
    mapAttrs
    match
    replaceStrings
    stringLength
    substring
    toJSON
    tryEval
    typeOf
    ;

  /**
    Evaluate `thunk`, returning `default` if it raises a catchable error.

    `x.foo or default` already handles attr-missing; `tryEval` catches
    `throw`s/assertions on top. Neither catches `abort`.

    # Inputs

    `default`

    : Value to return if `thunk` fails.

    `thunk`

    : The value to force.

    # Type

    ```
    tryOr :: a -> a -> a
    ```
  */
  tryOr =
    default: thunk:
    let
      t = tryEval thunk;
    in
    if t.success then t.value else default;

  /**
    Whether `str` begins with `pref`.

    Inlined `lib.strings.hasPrefix`, minus the path-deprecation warning:
    we never feed paths into it.

    # Inputs

    `pref`

    : The prefix to test for.

    `str`

    : The string to test.

    # Type

    ```
    hasPrefix :: String -> String -> Bool
    ```
  */
  hasPrefix = pref: str: substring 0 (stringLength pref) str == pref;

  /**
    Whether `s` ends with `pat`.

    Inlined, hoisted `lib.strings.hasSuffix`: avoids one attribute
    lookup per call, and we specialize on the known-short pattern
    length. The `serialize` hot path hits this `length(skipPatterns)`
    times per node.

    # Inputs

    `pat`

    : The suffix to test for.

    `s`

    : The string to test.

    # Type

    ```
    hasSuffix :: String -> String -> Bool
    ```
  */
  hasSuffix =
    pat: s:
    let
      lp = stringLength pat;
      ls = stringLength s;
    in
    lp <= ls && substring (ls - lp) lp s == pat;

  # Nix reserved words — see
  # https://nix.dev/manual/nix/2.26/language/identifiers#keywords.
  nixKeywords = [
    "assert"
    "else"
    "if"
    "in"
    "inherit"
    "let"
    "or"
    "rec"
    "then"
    "with"
  ];

  /**
    Escape `s` so it is safe to use as an attr name in Nix source:
    pass through valid non-keyword identifiers verbatim, otherwise
    render as a `$`-escaped Nix string so interpolation round-trips
    safely.

    Inlined from `lib.strings.escapeNixIdentifier`. Identifier regex
    from Nix's lexer:
    https://github.com/NixOS/nix/blob/d048577909e383439c2549e849c5c2f2016c997e/src/libexpr/lexer.l#L91

    # Inputs

    `s`

    : The candidate identifier.

    # Type

    ```
    escapeNixIdentifier :: String -> String
    ```
  */
  escapeNixIdentifier =
    s:
    if match "[a-zA-Z_][a-zA-Z0-9_'-]*" s != null && !(elem s nixKeywords) then
      s
    else
      replaceStrings [ "$" ] [ "\\$" ] (toJSON s);

  /**
    Render an attribute path as a dotted string, escaping each segment
    with `escapeNixIdentifier`. Empty paths render as
    `<root attribute path>`.

    Inlined from `lib.attrsets.showAttrPath`.

    # Inputs

    `path`

    : The attribute path to render.

    # Type

    ```
    showAttrPath :: [String] -> String
    ```
  */
  showAttrPath =
    path:
    if path == [ ] then
      "<root attribute path>"
    else
      concatStringsSep "." (map escapeNixIdentifier path);

  /**
    Default set of path-suffix patterns to skip during serialization.

    Each pattern is matched with `hasSuffix` against the dotted
    `pathStr` at every node, so `.services.frp` matches
    `config.services.frp` and any deeper occurrence.

    Note: when `serialize` descends into a list, `pathStr` gains
    `[N]` index segments (e.g. `config.foo.bar[3].baz`). Skip
    patterns are naive string suffixes, so a short pattern like
    `.baz` would also match inside list elements. None of the
    current defaults are short enough to collide — all target
    top-level attrset paths — but keep patterns rooted in an
    attrset path if you add new ones.

    They exist to cover noise that `collectAliasPaths` doesn't
    address:

    1. Store-path churn inside submodule values (e.g. the per-service
       `.runner` script hash) — not an alias, just a closure-level
       difference that's rarely informative. `.runner` specifically
       is also a nixpkgs bug: its module
       (`nixos/modules/testing/service-runner.nix`) interpolates
       `serviceConfig.ExecStart` without a guard, so forcing it on a
       service that doesn't set `ExecStart` (dbus, socket-activated
       units) hits an uncatchable attribute-missing error.
    2. Large non-informative subtrees (`.pkgs`, `.system`,
       `.virtualisation`, `.assertions`, per-language `Packages`
       sets). Walking these explodes output size, and some contain
       lazy values that `abort` or hit "attribute missing"
       uncatchably.

    # Type

    ```
    defaultSkipPatterns :: [String]
    ```
  */
  defaultSkipPatterns = [
    ".runner" # see note 1
    ".pkgs"
    "Packages" # no leading dot — matches haskellPackages, pythonPackages, etc.
    ".system"
    ".virtualisation"
    # assertion `.message` strings are lazy — they interpolate values
    # that only exist when the assertion fires. Forcing them for
    # serialization hits uncatchable "attribute missing" errors.
    ".assertions"
  ];

  /**
    Walk an `options` tree and return a
    `{ "<pathPrefix>.some.path" = null; … }` attrset of every option
    whose `description` starts with `Alias of `, which is the literal
    marker `doRename` (lib/modules.nix) attaches to every
    `mkRenamedOptionModule`, `mkAliasOptionModule`, and friends.

    Downstream, `serialize` uses this set to prune entire subtrees
    that are just aliases of canonical paths — the module system
    renders both the canonical and alias paths under `config`, so
    each real diff would otherwise appear two-to-three times. Every
    probe is `tryEval`-guarded so uncatchable errors in one option
    don't abort the whole walk.

    Key format matches the dotted `pathStr` `serialize` uses — e.g.
    `"config.services.sshd.enable"` with the default
    `pathPrefix = [ "config" ]`. Both sides escape identifier-illegal
    segments consistently via `escapeNixIdentifier` (so
    `config.environment.etc."pam.d/sshd"` round-trips correctly).

    # Inputs

    Structured function argument:

    `options`

    : The module-system `options` tree to scan.

    `pathPrefix`

    : Path prefix prepended to every key, matching the prefix used
      by `serialize`. Defaults to `[ "config" ]`.

    # Type

    ```
    collectAliasPaths ::
      { options :: AttrSet, pathPrefix :: [String] } -> AttrSet
    ```
  */
  collectAliasPaths =
    {
      options,
      pathPrefix ? [ "config" ],
    }:
    let
      # For each alias option, yield a listToAttrs-ready `{name;value;}`
      # pair rather than a bare string — the final `listToAttrs` then
      # does no intermediate mapping pass.
      #
      # `hasPrefix` forces `desc`, so an option whose `description`
      # throws (or `abort`s) will sink the whole walk. Known limitation:
      # real nixpkgs options almost never do this, but if it ever
      # happens, wrap the test in `tryOr false`.
      aliasPairOf =
        opt:
        let
          desc = opt.description or null;
          loc = opt.loc or null;
        in
        if loc != null && desc != null && hasPrefix "Alias of " desc then
          [
            {
              name = showAttrPath (pathPrefix ++ loc);
              value = null;
            }
          ]
        else
          [ ];

      # Every probe on `subtree` starts with `tryOr` on `_type`: a
      # pathological option whose parent itself throws on attribute
      # access would otherwise sink the whole walk. Deeper accesses
      # (`isAttrs`, `attrValues`, and the forces inside `aliasPairOf`)
      # are intentionally unguarded — see the note on `aliasPairOf`.
      go =
        subtree:
        let
          typeTry = tryOr null (subtree._type or null);
        in
        if typeTry == "option" then
          aliasPairOf subtree
        else if isAttrs subtree then
          concatMap go (attrValues subtree)
        else
          [ ];
    in
    listToAttrs (go options);

  /**
    Walk a NixOS config tree and produce a JSON-safe mirror for
    external diffing. The returned shape mirrors `config` verbatim
    (nested attrsets), with the following per-value rules:

    - Path is an alias (per `options`) → emit `"<alias>"`.
    - Path matches `skipPatterns` → emit `"<skipped: PATTERN>"`.
    - Forcing throws / assertion fails → emit `"<evalFailure>"`.
    - Function → emit `"<function>"`.
    - Derivation (has `outPath`) → emit `outPath` (string).
    - Attrset with `enable = false` → emit `{ enable = false; }` and
      stop (the disabled module's body is not informative for
      diffing).
    - Attrset / list → recurse.
    - Scalar (int, bool, string, path, null, float) → emit as-is.

    Uncatchable errors (`abort`, "attribute missing") can still
    crash the whole serialization; those paths must be in
    `skipPatterns` or covered by the alias detection. Passing
    `options` enables the latter and eliminates most
    renamed-to-nonexistent options automatically.

    # Inputs

    Structured function argument:

    `config`

    : The evaluated config tree to walk — i.e.
      `nixosSystem.config`, not the `nixosSystem` wrapper itself.

    `options`

    : The module-system `options` tree — sibling of `config` on a
      `nixosSystem` result. Enables alias pruning when passed.
      Defaults to `null`.

    `skipPatterns`

    : List of path-suffix patterns to skip. Defaults to
      `defaultSkipPatterns`.

    `aliasPaths`

    : Precomputed alias-path set — computed from `options` and
      `pathPrefix` when not supplied.

    `pathPrefix`

    : Dotted-path prefix prepended to every emitted key (purely for
      output labeling; it does not affect traversal). Defaults to
      `[ "config" ]`, so paths render as `config.services.…`,
      matching nixpkgs' usual convention.

    # Type

    ```
    serialize ::
      { config :: AttrSet
      , options :: AttrSet | Null
      , skipPatterns :: [String]
      , aliasPaths :: AttrSet
      , pathPrefix :: [String]
      }
      -> Any
    ```
  */
  serialize =
    {
      config,
      options ? null,
      skipPatterns ? defaultSkipPatterns,
      pathPrefix ? [ "config" ],
      aliasPaths ? if options != null then collectAliasPaths { inherit options pathPrefix; } else { },
    }:
    let
      # One walk per node, returning the first matching pattern or null.
      # `filter` doesn't short-circuit, but at `length skipPatterns` = 6
      # that's not worth a hand-rolled recursion (which would allocate
      # tail-sublist thunks per step — slower in practice).
      findSkip =
        pathStr:
        let
          match' = filter (pat: hasSuffix pat pathStr) skipPatterns;
        in
        if match' == [ ] then null else head match';

      go =
        pathStr: v:
        # Alias and skip checks use only the already-evaluated pathStr;
        # they don't touch `v` at all. Forcing `v` up front would defeat
        # the whole point of skip patterns (which exist precisely because
        # some paths are unsafe to force).
        if hasAttr pathStr aliasPaths then
          "<alias>"
        else
          let
            skip = findSkip pathStr;
          in
          if skip != null then
            "<skipped: ${skip}>"
          else
            let
              t = tryEval v;
            in
            if !t.success then
              "<evalFailure>"
            else
              let
                v' = t.value;
                tType = typeOf v';
              in
              if tType == "lambda" then
                "<function>"
              else if tType == "set" then
                if v' ? outPath then
                  tryOr "<evalFailure>" (toString v'.outPath)
                # Short-circuit `enable = false` submodules: the disabled
                # module's body is just default machinery, not informative
                # for diffing. Skip the probe entirely if `.enable` is a
                # renamed alias to a nonexistent option (forcing it
                # `abort`s).
                else if
                  v' ? enable && !(hasAttr "${pathStr}.enable" aliasPaths) && tryOr null v'.enable == false
                then
                  { enable = false; }
                else
                  mapAttrs (name: go (pathStr + "." + escapeNixIdentifier name)) v'
              else if tType == "list" then
                genList (n: go (pathStr + "[${toString n}]") (elemAt v' n)) (length v')
              else if tType == "path" then
                # Paths serialize as strings through toJSON; explicit
                # toString keeps behaviour consistent even before the
                # final JSON pass.
                toString v'
              # lambda/set/list/path are handled above; anything else
              # typeOf could return (string/int/float/bool/null) is
              # JSON-safe as-is.
              else
                v';
    in
    go (showAttrPath pathPrefix) config;
in
{
  inherit
    collectAliasPaths
    defaultSkipPatterns
    serialize
    ;
}
