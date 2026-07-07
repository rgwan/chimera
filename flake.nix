# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
{
  description = "Chimera CPU core build environment";

  inputs = {
    zaozi.url = "github:sequencer/zaozi";
    nixpkgs.follows = "zaozi/nixpkgs";
    flake-utils.follows = "zaozi/flake-utils";
  };

  outputs = { self, flake-utils, zaozi, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = zaozi.legacyPackages.${system};

        pythonEnv = pkgs.python3.withPackages (ps: with ps; [
          pytest
          pyyaml
        ]);

        buildScript = pkgs.writeShellApplication {
          name = "build-chimera";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.scala-cli
            pythonEnv
          ];
          text = ''
            set -euo pipefail

            mode="''${1:---smoke}"
            case "$mode" in
              --smoke)
                ;;
              --help)
                cat <<'EOF'
Usage: build-chimera [--smoke]

Run the Chimera build-environment smoke check.
EOF
                exit 0
                ;;
              *)
                echo "unknown build-chimera option: $mode" >&2
                exit 2
                ;;
            esac

            out_dir="''${CHIMERA_SMOKE_OUT:-$PWD/result/build-smoke}"
            mkdir -p "$out_dir"

            test -d "${zaozi.outPath}"
            command -v scala-cli >/dev/null
            command -v python3 >/dev/null

            {
              echo "project=chimera"
              echo "zaozi=${zaozi.outPath}"
              scala-cli --version | sed 's/^/scala-cli=/'
              if command -v firtool >/dev/null; then
                firtool --version | head -n 1 | sed 's/^/firtool=/'
              else
                echo "firtool=not-found"
              fi
              python3 --version | sed 's/^/python=/'
            } > "$out_dir/smoke.txt"

            echo "Chimera build smoke passed: $out_dir/smoke.txt"
          '';
        };

        reuseCheck = pkgs.runCommand "chimera-reuse-lint" {
          nativeBuildInputs = [ pkgs.reuse ];
        } ''
          cp -R ${self} src
          chmod -R u+w src
          cd src
          reuse lint
          touch $out
        '';

        smokeCheck = pkgs.runCommand "chimera-build-smoke" {
          nativeBuildInputs = [ buildScript ];
        } ''
          export CHIMERA_SMOKE_OUT=$out
          build-chimera --smoke
        '';

        shellHook = ''
          echo "========================================"
          echo "Chimera Zaozi Development Environment"
          echo "========================================"
          echo "Build smoke: build-chimera --smoke"
          echo "Full shell:   nix develop .#full"
          echo "Verify:      nix flake check"
          echo "========================================"
        '';

        smokeBuildInputs = [
          buildScript
          pkgs.git
          pkgs.gnumake
          pkgs.reuse
          pkgs.scala-cli
          pythonEnv
        ];

        fullBuildInputs = smokeBuildInputs ++ [
          pkgs.circt-install
          pkgs.mlir-install
        ];
      in
      {
        packages.default = smokeCheck;

        apps.default = {
          type = "app";
          program = "${buildScript}/bin/build-chimera";
          meta.description = "Run the Chimera build smoke check";
        };

        apps.build = {
          type = "app";
          program = "${buildScript}/bin/build-chimera";
          meta.description = "Run the Chimera build smoke check";
        };

        checks = {
          build-smoke = smokeCheck;
          reuse = reuseCheck;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = smokeBuildInputs;
          env = {
            CHIMERA_PROJECT_NAME = "chimera";
            ZAOZI_SRC = zaozi.outPath;
            JAVA_TOOL_OPTIONS = "--enable-preview";
          };
          inherit shellHook;
        };

        devShells.smoke = pkgs.mkShell {
          buildInputs = smokeBuildInputs;
          env = {
            CHIMERA_PROJECT_NAME = "chimera";
            ZAOZI_SRC = zaozi.outPath;
            JAVA_TOOL_OPTIONS = "--enable-preview";
          };
          inherit shellHook;
        };

        devShells.full = pkgs.mkShell {
          buildInputs = fullBuildInputs;
          env = {
            CHIMERA_PROJECT_NAME = "chimera";
            ZAOZI_SRC = zaozi.outPath;
            CIRCT_INSTALL_PATH = pkgs.circt-install;
            MLIR_INSTALL_PATH = pkgs.mlir-install;
            JAVA_TOOL_OPTIONS = "--enable-preview";
          };
          inherit shellHook;
        };
      }
    );
}
