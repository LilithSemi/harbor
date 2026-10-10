{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flakever.url = "github:numinit/flakever";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flakever,
      treefmt-nix,
      ...
    }@inputs:
    let
      inherit (nixpkgs) lib;

      flakeverConfig = flakever.lib.mkFlakever {
        inherit inputs;

        digits = [
          1
          2
          2
        ];
      };

      nameValuePair = name: value: { inherit name value; };
      genAttrs = names: f: builtins.listToAttrs (map (n: nameValuePair n (f n)) names);
      allSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "riscv64-linux"
      ];

      forAllSystems =
        f:
        genAttrs allSystems (
          system:
          f {
            inherit system;
            pkgs = import nixpkgs {
              inherit system;
              overlays = [
                self.overlays.default
              ];
            };
          }
        );

      treefmtEval = forAllSystems ({ pkgs, ... }: treefmt-nix.lib.evalModule pkgs (import ./treefmt.nix));
    in
    {
      versionTemplate = "1.1pre-<lastModifiedDate>-<rev>";

      overlays.default =
        final: prev:
        let
          final' = final // {
            flakever = flakeverConfig;
          };

          callPackage = lib.callPackageWith final';
          callPackages = lib.callPackagesWith final';
        in
        {
          harbor = callPackages ./nix { };

          testfloat = callPackage ./nix/testfloat.nix { };

          linuxKernel = prev.linuxKernel // {
            packages = lib.mapAttrs (
              _name: prevLinuxPackages:
              prevLinuxPackages.extend (
                lpFinal: _lpPrev: {
                  harbor-kmod = callPackage ./pkgs/harbor-kmod {
                    inherit (lpFinal) kernel kernelModuleMakeFlags;
                  };
                }
              )
            ) prev.linuxKernel.packages;
          };
        };

      devShells = forAllSystems (
        { pkgs, ... }:
        lib.optionalAttrs (!pkgs.stdenv.hostPlatform.isRiscV) {
          default = pkgs.mkShell {
            name = "harbor-dev-shell";
            packages = with pkgs; [
              yq
              dart
              flutter
              testfloat
            ];
          };
        }
      );

      checks = forAllSystems (
        { system, pkgs, ... }:
        {
          formatting = treefmtEval.${system}.config.build.check self;
        }
        // lib.optionalAttrs (!pkgs.stdenv.hostPlatform.isRiscV) {
          default = pkgs.buildDartApplication {
            pname = "harbor-check";
            inherit (flakever) version;

            src = lib.fileset.toSource {
              root = ./.;
              fileset = lib.fileset.unions [
                ./packages/harbor/lib
                ./packages/harbor/test
                ./packages/harbor/pubspec.yaml
                ./packages/harbor/dart_test.yaml
                ./pubspec.yaml
                ./pubspec.lock
              ];
            };

            pubspecLock = lib.importJSON ./pubspec.lock.json;
            dartEntryPoints = { };

            dontBuild = true;
            doCheck = true;

            checkPhase = ''
              runHook preCheck
              export HOME="$TMPDIR"
              dart analyze packages/harbor --fatal-infos
              packageRun test -r expanded --exclude-tags slow --timeout 10m packages/harbor/test
              runHook postCheck
            '';

            installPhase = ''
              touch $out
              mkdir -p $pubcache
            '';
          };
        }
      );

      packages = forAllSystems (
        { pkgs, ... }:
        {
          inherit (pkgs) testfloat;
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          inherit (pkgs.linuxPackages_latest) harbor-kmod;
        }
      );

      formatter = forAllSystems ({ system, ... }: treefmtEval.${system}.config.build.wrapper);

      legacyPackages = forAllSystems ({ pkgs, ... }: pkgs);
    };
}
