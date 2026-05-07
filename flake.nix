{
  inputs = {
    flake-parts = {
      inputs.nixpkgs-lib.follows = "nixpkgs-lib";
      url = "github:hercules-ci/flake-parts";
    };
    nixpkgs.url = "github:nixos/nixpkgs";
    nixpkgs-lib.url = "github:nix-community/nixpkgs.lib";
    git-hooks-nix = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:cachix/git-hooks.nix";
    };
    treefmt-nix = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:numtide/treefmt-nix";
    };
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      imports = [
        inputs.treefmt-nix.flakeModule
        inputs.git-hooks-nix.flakeModule
      ];

      flake =
        let
          # `mapAttrs` / `mapAttrsToList` / etc. come from the light
          # `nixpkgs-lib` flake; `nixosSystem` is module-system glue
          # that only lives in full nixpkgs. Keep them sourced from
          # the narrowest input each needs.
          inherit (inputs.nixpkgs-lib) lib;
          inherit (inputs.nixpkgs.lib) nixosSystem;
          serializeLib = import ./serialize.nix;

          # Bare-minimum NixOS scaffolding (bootloader + rootfs +
          # stateVersion) shared by both example configs. Targets
          # x86_64-linux so the configs evaluate on any system — they
          # are not meant to be built or deployed, only serialized
          # and diffed.
          commonModule = {
            nixpkgs.hostPlatform = "x86_64-linux";
            system.stateVersion = "25.11";
            boot.loader.grub.device = "/dev/sda";
            fileSystems."/" = {
              device = "/dev/sda1";
              fsType = "ext4";
            };
          };

          mkExample =
            overrides:
            nixosSystem {
              modules = [
                commonModule
                overrides
              ];
            };
        in
        {
          lib.serialize = serializeLib;

          # Two example NixOS configurations that differ in a handful
          # of meaningful ways (hostname, timezone, sshd port,
          # systemPackages). The point is to produce a small,
          # readable diff that demonstrates what `serialize` + the
          # diff tooling does. See `README.md`.
          nixosConfigurations = {
            exampleA = mkExample (
              { pkgs, ... }:
              {
                networking.hostName = "alpha";
                time.timeZone = "UTC";
                services.openssh = {
                  enable = true;
                  ports = [ 22 ];
                };
                environment.systemPackages = with pkgs; [
                  git
                  vim
                ];
              }
            );

            exampleB = mkExample (
              { pkgs, ... }:
              {
                networking.hostName = "beta";
                time.timeZone = "America/New_York";
                services.openssh = {
                  enable = true;
                  ports = [ 2222 ];
                };
                environment.systemPackages = with pkgs; [
                  git
                  htop
                  vim
                ];
              }
            );
          };

          # Ready-to-eval serialized mirrors of the example configs.
          # Point `diff-configs` at these via flake URIs:
          #   nix run .# -- .#serialized.exampleA .#serialized.exampleB
          #
          # `.nvidia` is added to `skipPatterns` because the nixpkgs
          # `hardware.nvidia.gsp.enable` submodule has a default that
          # `abort`s when `hardware.nvidia.open` is unset — an
          # uncatchable error that the `tryEval` guards in
          # `serialize` cannot intercept.
          serialized = lib.mapAttrs (
            _: sys:
            serializeLib.serialize {
              inherit (sys) config options;
              skipPatterns = serializeLib.defaultSkipPatterns ++ [ ".nvidia" ];
            }
          ) inputs.self.nixosConfigurations;
        };

      perSystem =
        { config, pkgs, ... }:
        let
          diff-configs = pkgs.callPackage ./diff-configs/package.nix { };
        in
        {
          packages = {
            inherit diff-configs;
            default = diff-configs;
          };

          pre-commit.settings.hooks = {
            # Formatter checks
            treefmt = {
              enable = true;
              package = config.treefmt.build.wrapper;
            };

            # Nix checks
            deadnix.enable = true;
            nil.enable = true;
            statix.enable = true;
          };

          treefmt = {
            projectRootFile = "flake.nix";
            programs = {
              # Nix
              nixfmt.enable = true;

              # Shell
              shellcheck.enable = true;
              shfmt.enable = true;
            };
          };
        };
    };
}
