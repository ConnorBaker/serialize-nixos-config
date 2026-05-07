{
  writeShellApplication,
  dyff,
  jd-diff-patch,
  jq,
}:
writeShellApplication {
  name = "diff-configs";
  # `nix` intentionally isn't in runtimeInputs: the script relies on
  # `--eval-cores`, a Determinate/Lix flag not present in the upstream
  # `nix` that nixpkgs ships. writeShellApplication keeps the caller's
  # PATH on the tail by default (`inheritPath = true`), so `nix`
  # resolves to whatever the user has installed.
  runtimeInputs = [
    dyff
    jd-diff-patch
    jq
  ];
  # Interpolated (not a bare path) so Nix imports it to the store with
  # proper context; a bare `./patch-to-markdown.jq` here stringifies
  # the flake source and warns about a dangling reference.
  runtimeEnv.PATCH_TO_MARKDOWN_JQ = "${./patch-to-markdown.jq}";
  text = builtins.readFile ./diff-configs.sh;
}
