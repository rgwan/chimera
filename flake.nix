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

        h8300Gdb = pkgs.gdb.overrideAttrs (old: {
          pname = "h8300-elf-gdb";
          configurePlatforms = [ "build" "host" ];
          configureFlags =
            (builtins.filter
              (flag:
                !(pkgs.lib.hasPrefix "--program-prefix=" flag)
                && !(pkgs.lib.hasPrefix "--target=" flag))
              (old.configureFlags or []))
            ++ [
              "--target=h8300-elf"
              "--program-prefix=h8300-elf-"
              "--enable-sim"
              "--disable-werror"
            ];
          doInstallCheck = false;
        });

        # C-only bare-metal cross compiler (install-gcc: no libgcc/newlib needed
        # to emit and disassemble code). Modern gcc/binutils only target H8/300H
        # and up; the base-H8/300 encodings are the assembled subset.
        h8300Gcc = pkgs.stdenv.mkDerivation {
          pname = "h8300-elf-gcc";
          version = pkgs.gcc-unwrapped.version;
          src = pkgs.gcc-unwrapped.src;
          nativeBuildInputs = [ h8300Binutils pkgs.perl pkgs.texinfo pkgs.flex pkgs.bison ];
          buildInputs = [ pkgs.gmp.dev pkgs.mpfr.dev pkgs.libmpc pkgs.isl pkgs.zlib ];
          hardeningDisable = [ "format" ];
          configureFlags = [
            "--target=h8300-elf"
            "--program-prefix=h8300-elf-"
            "--enable-languages=c"
            "--without-headers"
            "--with-newlib"
            "--disable-shared"
            "--disable-threads"
            "--disable-nls"
            "--disable-libssp"
            "--disable-libgomp"
            "--disable-libquadmath"
            "--disable-libatomic"
            "--disable-decimal-float"
            "--disable-libffi"
            "--disable-bootstrap"
            "--with-gmp=${pkgs.gmp.dev}"
            "--with-mpfr=${pkgs.mpfr.dev}"
            "--with-mpc=${pkgs.libmpc}"
            "--with-isl=${pkgs.isl}"
          ];
          buildFlags = [ "all-gcc" ];
          installTargets = [ "install-gcc" ];
          enableParallelBuilding = true;
          dontDisableStatic = true;
        };

        gccFootprintCheck = pkgs.runCommand "chimera-gcc-footprint-smoke" {
          nativeBuildInputs = [
            h8300Binutils
            h8300Gcc
            pythonEnv
          ];
        } ''
          cp -R ${self} src
          chmod -R u+w src
          cd src
          python3 scripts/check_gcc_footprint.py
          touch $out
        '';

        gdbOracleCheck = pkgs.runCommand "chimera-gdb-oracle-smoke" {
          nativeBuildInputs = [
            h8300Binutils
            h8300Gdb
            pythonEnv
          ];
        } ''
          cp -R ${self} src
          chmod -R u+w src
          cd src
          python3 scripts/check_gdb_oracle.py
          touch $out
        '';

        gnuOracleCheck = pkgs.runCommand "chimera-gnu-oracle-smoke" {
          nativeBuildInputs = [
            h8300Binutils
            pkgs.ocamlPackages.sail
            pythonEnv
            pkgs.z3
          ];
        } ''
          cp -R ${self} src
          chmod -R u+w src
          cd src
          python3 scripts/check_gnu_oracle.py
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

        decodeDispatchCheck = pkgs.runCommand "chimera-decode-dispatch" {
          nativeBuildInputs = [ pythonEnv ];
        } ''
          cp -R ${self} src
          chmod -R u+w src
          cd src
          python3 scripts/check_decode_dispatch.py --table-only
          touch $out
        '';

        sailCoverageCheck = pkgs.runCommand "chimera-sail-coverage" {
          nativeBuildInputs = [ pythonEnv ];
        } ''
          cp -R ${self} src
          chmod -R u+w src
          cd src
          python3 scripts/check_sail_coverage.py
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

        zaoziIvyLock = pkgs.writeText "chimera-zaozi-lock.nix" ''
          { fetchurl }:
          (import ${zaozi.outPath}/nix/zaozi/zaozi-lock.nix { inherit fetchurl; })
          // (import ${./nix/zaozi-extra-lock.nix} { inherit fetchurl; })
        '';

        zaoziAssembly = zaozi.packages.${system}.zaozi-assembly.overrideAttrs (_old: {
          buildInputs = [
            (pkgs.ivy-gather zaoziIvyLock)
          ];
        });

        zaoziJar = "${zaoziAssembly}/share/java/elaborator.jar";

        shellHook = ''
          echo "========================================"
          echo "Chimera Zaozi Development Environment"
          echo "========================================"
          echo "Build smoke: build-chimera --smoke"
          echo "RTL build:    make rtl-verilog"
          echo "Sail model:   make sail-model"
          echo "Smoke shell:  nix develop .#smoke"
          echo "Verify:      nix flake check"
          echo "========================================"
        '';

        smokeBuildInputs = [
          buildScript
          pkgs.git
          pkgs.gnumake
          h8300Binutils
          h8300Gdb
          h8300Gcc
          pkgs.ocamlPackages.sail
          pkgs.reuse
          pkgs.scala-cli
          pkgs.z3
          pythonEnv
        ];

        fullBuildInputs = smokeBuildInputs ++ [
          pkgs.circt-install
          pkgs.jdk25
          pkgs.mlir-install
          zaoziAssembly
        ];
      in
      {
        packages.default = smokeCheck;
        packages.h8300-binutils = h8300Binutils;
        packages.h8300-gdb = h8300Gdb;
        packages.h8300-gcc = h8300Gcc;
        packages.isa-cases = isaCasesCheck;
        packages.sail-coverage = sailCoverageCheck;
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
          decode-dispatch = decodeDispatchCheck;
          gcc-footprint-smoke = gccFootprintCheck;
          gdb-oracle-smoke = gdbOracleCheck;
          gnu-oracle-smoke = gnuOracleCheck;
          isa-cases = isaCasesCheck;
          reuse = reuseCheck;
          sail-coverage = sailCoverageCheck;
          sail-model = sailModelCheck;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = fullBuildInputs;
          env = {
            CHIMERA_PROJECT_NAME = "chimera";
            ZAOZI_SRC = zaozi.outPath;
            ZAOZI_JAR = zaoziJar;
            CIRCT_INSTALL_PATH = pkgs.circt-install;
            MLIR_INSTALL_PATH = pkgs.mlir-install;
            JAVA_HOME = pkgs.jdk25.home;
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
            ZAOZI_JAR = zaoziJar;
            CIRCT_INSTALL_PATH = pkgs.circt-install;
            MLIR_INSTALL_PATH = pkgs.mlir-install;
            JAVA_HOME = pkgs.jdk25.home;
            JAVA_TOOL_OPTIONS = "--enable-preview";
          };
          inherit shellHook;
        };
      }
    );
}
