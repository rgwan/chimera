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

        h8300Binutils = (pkgs.binutils-unwrapped.override {
          enableGold = false;
          enableShared = false;
        }).overrideAttrs (old: {
          pname = "h8300-elf-binutils";
          configurePlatforms = [ "build" "host" ];
          configureFlags =
            (builtins.filter
              (flag: !(pkgs.lib.hasPrefix "--program-prefix=" flag))
              old.configureFlags)
            ++ [
              "--target=h8300-elf"
              "--program-prefix=h8300-elf-"
            ];
          doInstallCheck = false;
        });

        gnuOracleCheck = pkgs.runCommand "chimera-gnu-oracle-smoke" {
          nativeBuildInputs = [
            h8300Binutils
            pkgs.coreutils
            pkgs.gnugrep
          ];
        } ''
          cat > oracle.s <<'EOF'
          .text
          .global _start
          _start:
            nop
            mov.b #0x12, r0h
            mov.b #0x34, r0l
            add.b #0xee, r0h
            cmp.b #0x00, r0h
            mov.w #0xabcd, r2
          loop:
            bne loop
          EOF

          h8300-elf-as -o oracle.o oracle.s
          h8300-elf-ld -Ttext=0 -e _start -o oracle.elf oracle.o
          h8300-elf-objdump -f oracle.elf | grep -q 'file format elf32-h8300'
          h8300-elf-objdump -d oracle.elf > oracle.dump
          grep -qi 'mov.b' oracle.dump
          grep -qi 'add.b' oracle.dump
          grep -qi 'cmp.b' oracle.dump
          grep -qi 'bne' oracle.dump
          h8300-elf-objcopy -O binary -j .text oracle.elf oracle.bin
          actual="$(od -An -tx1 -v oracle.bin | tr -d ' \n')"
          expected="0000f012f83480eea0007902abcd46fe"
          test "$actual" = "$expected"
          touch $out
        '';

        isaCasesCheck = pkgs.runCommand "chimera-isa-cases" {
          nativeBuildInputs = [ pythonEnv ];
        } ''
          cp -R ${self} src
          chmod -R u+w src
          cd src
          python3 scripts/check_isa_cases.py
          touch $out
        '';

        sailModelCheck = pkgs.runCommand "chimera-sail-model" {
          nativeBuildInputs = [
            pkgs.gcc
            pkgs.ocamlPackages.sail
            pythonEnv
            pkgs.z3
          ];
          buildInputs = [
            pkgs.gmp
            pkgs.zlib
          ];
        } ''
          cp -R ${self} src
          chmod -R u+w src
          cd src
          python3 scripts/check_sail_model.py
          touch $out
        '';

        shellHook = ''
          echo "========================================"
          echo "Chimera Zaozi Development Environment"
          echo "========================================"
          echo "Build smoke: build-chimera --smoke"
          echo "Sail model:   make sail-model"
          echo "Full shell:   nix develop .#full"
          echo "Verify:      nix flake check"
          echo "========================================"
        '';

        smokeBuildInputs = [
          buildScript
          pkgs.git
          pkgs.gnumake
          pkgs.ocamlPackages.sail
          pkgs.reuse
          pkgs.scala-cli
          pkgs.z3
          pythonEnv
        ];

        fullBuildInputs = smokeBuildInputs ++ [
          pkgs.circt-install
          h8300Binutils
          pkgs.mlir-install
        ];
      in
      {
        packages.default = smokeCheck;
        packages.h8300-binutils = h8300Binutils;
        packages.isa-cases = isaCasesCheck;
        packages.sail-model = sailModelCheck;

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
          gnu-oracle-smoke = gnuOracleCheck;
          isa-cases = isaCasesCheck;
          reuse = reuseCheck;
          sail-model = sailModelCheck;
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
