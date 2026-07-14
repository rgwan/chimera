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

        # cocotb + Verilator harness. cocotb-bus comes from nixpkgs; the two
        # cocotbext.* extensions are vendored under test/cocotbext and reach the
        # interpreter through PYTHONPATH (see cocotbShellHook).
        cocotbPythonEnv = pkgs.python3.withPackages (ps: with ps; [
          cocotb
          cocotb-bus
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

        # Benchmark toolchain: the last GNU releases with base-H8/300 codegen
        # (gcc-11's cc0 removal dropped the plain H8/300). Pinned tarballs;
        # C plus libgcc so 16/32-bit mul/div lower through MULXU/DIVXU helpers.
        h8300BenchBinutils = pkgs.stdenv.mkDerivation {
          pname = "h8300-elf-binutils-base";
          version = "2.34";
          src = pkgs.fetchurl {
            url = "https://mirrors.tuna.tsinghua.edu.cn/gnu/binutils/binutils-2.34.tar.xz";
            sha256 = "0ll909bcsa0q2v8giarzvwsffnqk522mdgb544gap6yw0f40w2zh";
          };
          nativeBuildInputs = [ pkgs.perl pkgs.texinfo pkgs.flex pkgs.bison ];
          buildInputs = [ pkgs.zlib ];
          hardeningDisable = [ "format" ];
          configureFlags = [
            "--target=h8300-elf"
            "--program-prefix=h8300-elf-"
            "--disable-nls"
            "--disable-werror"
            "--disable-gdb"
            "--disable-sim"
          ];
          enableParallelBuilding = true;
          doInstallCheck = false;
        };

        h8300BenchGcc = pkgs.stdenv.mkDerivation {
          pname = "h8300-elf-gcc-base";
          version = "10.5.0";
          src = pkgs.fetchurl {
            url = "https://mirrors.tuna.tsinghua.edu.cn/gnu/gcc/gcc-10.5.0/gcc-10.5.0.tar.xz";
            sha256 = "1h87lcfaga0ydsf4pkhwlnjr8mky5ix8npbv6iy3jvzlzm1ra415";
          };
          nativeBuildInputs = [ h8300BenchBinutils pkgs.perl pkgs.texinfo pkgs.flex pkgs.bison ];
          buildInputs = [ pkgs.gmp.dev pkgs.mpfr.dev pkgs.libmpc pkgs.isl pkgs.zlib ];
          hardeningDisable = [ "format" ];
          CXXFLAGS = "-std=gnu++14";
          preConfigure = ''
            mkdir ../objdir
            cd ../objdir
            configureScript=../gcc-10.5.0/configure
          '';
          configureFlags = [
            "--target=h8300-elf"
            "--program-prefix=h8300-elf-"
            "--enable-languages=c"
            "--without-headers"
            "--with-newlib"
            "--disable-multilib"
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
            "--with-as=${h8300BenchBinutils}/bin/h8300-elf-as"
            "--with-ld=${h8300BenchBinutils}/bin/h8300-elf-ld"
          ];
          buildPhase = ''
            runHook preBuild
            make -j"$NIX_BUILD_CORES" all-gcc
            make -j"$NIX_BUILD_CORES" all-target-libgcc
            runHook postBuild
          '';
          installTargets = [ "install-gcc" "install-target-libgcc" ];
          enableParallelBuilding = true;
          dontDisableStatic = true;
        };

        # CoreMark upstream, fetched at build time; never vendored into the
        # repo. Scores are rtl cycle-accurate estimates, not EEMBC-certified.
        coremarkSrc = pkgs.fetchFromGitHub {
          owner = "eembc";
          repo = "coremark";
          rev = "1f483d5b8316753a742cbf5590caf5bd0a4e4777";
          hash = "sha256-QNYMReTx9w+kwTWxizj34McZNE2sbIqJRmUcYn48+T0=";
        };

        benchToolchainCheck = pkgs.runCommand "chimera-bench-toolchain-smoke" {
          nativeBuildInputs = [ h8300BenchBinutils h8300BenchGcc ];
        } ''
          cat > t.c <<'CEOF'
          unsigned mul(unsigned a, unsigned b) { return a * b; }
          unsigned long lmul(unsigned long a, unsigned long b) { return a * b; }
          unsigned div16(unsigned a, unsigned b) { return a / b; }
          CEOF
          h8300-elf-gcc -Os -S -o t.s t.c
          grep -q '\.h8300h' t.s && { echo "H8/300H asm emitted"; exit 1; }
          h8300-elf-gcc -Os -c -o t.o t.c
          h8300-elf-objdump -d t.o > t.dis
          grep -qE 'er[0-7]|\.l[[:space:]]' t.dis && { echo "300H-only ops"; exit 1; }
          h8300-elf-gcc -print-libgcc-file-name | grep -q libgcc.a
          touch $out
        '';

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
          export BENCH_CC=${h8300BenchGcc}/bin/h8300-elf-gcc
          export BENCH_OBJCOPY=${h8300BenchBinutils}/bin/h8300-elf-objcopy
          export BENCH_OBJDUMP=${h8300BenchBinutils}/bin/h8300-elf-objdump
          export COREMARK_SRC=${coremarkSrc}
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

        # Named RTL configurations, selectable as `nix build .#rtl-<name>`.
        # Two target platforms x three tiers. FPGA infers the microcode ROM as
        # block RAM (readmemh); ASIC synthesizes it to gates and drops the DV
        # collateral, leaving a filelist. Each platform has lean (smallest,
        # single-cycle), pipe (two-stage, highest clock) and strict (illegal-
        # encoding guards).
        # Debug features default off; the debug preset sets dm (and dtm) to
        # elaborate CoreTop (Core + JTAG DTM) and keeps every debug-off config
        # byte-identical.
        chimeraConfigs = {
          fpga-lean   = { strictDecode = false; romHex = true;  asic = false; pipeline = false; };
          fpga-pipe   = { strictDecode = false; romHex = true;  asic = false; pipeline = true;  };
          fpga-strict = { strictDecode = true;  romHex = true;  asic = false; pipeline = false; };
          fpga-debug  = { strictDecode = false; romHex = true;  asic = false; pipeline = false; dm = true; dtm = true; };
          asic-lean   = { strictDecode = false; romHex = false; asic = true;  pipeline = false; };
          asic-pipe   = { strictDecode = false; romHex = false; asic = true;  pipeline = true;  };
          asic-strict = { strictDecode = true;  romHex = false; asic = true;  pipeline = false; };
        };

        chimeraIvyCache = pkgs.ivy-gather zaoziIvyLock;

        rtlBuild = name: cfg: pkgs.runCommand "chimera-rtl-${name}" {
          nativeBuildInputs = [
            pkgs.scala-cli
            pkgs.circt-install
            pkgs.mlir-install
            pkgs.jdk25
            zaoziAssembly
          ];
        } ''
          cp -R ${self} src
          chmod -R u+w src
          cd src
          # The build user's passwd home is read-only (/var/empty on CI,
          # /dev/null with sandbox off) and scala-cli's native launcher derives
          # its cache/data dirs from it, not from $HOME. Redirect HOME and the XDG
          # dirs it honours to a fresh writable temp tree.
          export HOME=$(mktemp -d)
          export XDG_CACHE_HOME=$HOME/.cache
          export XDG_DATA_HOME=$HOME/.local/share
          export XDG_CONFIG_HOME=$HOME/.config
          mkdir -p "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"
          export JAVA_TOOL_OPTIONS="--enable-preview"
          export COURSIER_CACHE=$HOME/coursier
          export COURSIER_MODE=offline
          mkdir -p "$COURSIER_CACHE"
          cp -r ${chimeraIvyCache}/cache/. "$COURSIER_CACHE/"
          chmod -R u+w "$COURSIER_CACHE"
          export ZAOZI_JAR=${zaoziJar}
          export CIRCT_INSTALL_PATH=${pkgs.circt-install}
          export MLIR_INSTALL_PATH=${pkgs.mlir-install}
          export JAVA_HOME=${pkgs.jdk25}
          mkdir -p $out
          CHIMERA_RTL_OUT=$out \
            STRICT_DECODE=${pkgs.lib.boolToString cfg.strictDecode} \
            ROM_HEX=${pkgs.lib.boolToString cfg.romHex} \
            PIPELINE=${pkgs.lib.boolToString cfg.pipeline} \
            DM=${pkgs.lib.boolToString (cfg.dm or false)} \
            DTM=${pkgs.lib.boolToString (cfg.dtm or (cfg.dm or false))} \
            HW_BREAKPOINT=${pkgs.lib.boolToString (cfg.hardwareBreakpoint or false)} \
            HW_BREAKPOINT_COUNT=${toString (cfg.hwBreakpointCount or 0)} \
            SINGLE_STEP=${pkgs.lib.boolToString (cfg.singleStep or false)} \
            DBG_BASE=${toString (cfg.dbgBase or 65280)} \
            bash rtl/build.sh
          rm -f $out/*.mlirbc
          ${pkgs.lib.optionalString cfg.asic ''
            rm -f $out/layers-*.sv $out/ref_*.sv
            (cd $out && ls *.sv | sort > filelist.f)
          ''}
        '';

        # circt-bmc dlopen's libz3 as a shared library at solve time. The z3
        # "lib" output ships libz3.so; expose its full path so formal scripts
        # pass --shared-libs=$Z3_LIB without spelling a store path inline.
        z3Lib = "${pkgs.z3.lib}/lib/libz3${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}";

        smokeBuildInputs = [
          buildScript
          pkgs.git
          pkgs.gnumake
          pkgs.iverilog
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
          # Debug-subsystem host tool (jtag2gdb) and its gdb-transport e2e.
          pkgs.cargo
          pkgs.rustc
        ];

        # cocotb tests build CoreTop (DM=true) through rtl/build.sh, then compile
        # and run it on Verilator (which invokes gcc/make). The RTL toolchain
        # (scala-cli, jdk, circt, mlir, zaozi) is shared with the full shell.
        cocotbBuildInputs = [
          cocotbPythonEnv
          pkgs.verilator
          pkgs.gcc
          pkgs.gnumake
          pkgs.git
          pkgs.scala-cli
          pkgs.circt-install
          pkgs.mlir-install
          pkgs.jdk25
          zaoziAssembly
        ];

        cocotbShellHook = ''
          export PYTHONPATH="$PWD/test:''${PYTHONPATH:-}"
          export ZAOZI_JAR=${zaoziJar}
          export CIRCT_INSTALL_PATH=${pkgs.circt-install}
          export MLIR_INSTALL_PATH=${pkgs.mlir-install}
          export JAVA_HOME=${pkgs.jdk25.home}
          export JAVA_TOOL_OPTIONS="--enable-preview"
        '';
      in
      {
        packages.default = smokeCheck;
        packages.rtl-fpga-lean = rtlBuild "fpga-lean" chimeraConfigs.fpga-lean;
        packages.rtl-fpga-pipe = rtlBuild "fpga-pipe" chimeraConfigs.fpga-pipe;
        packages.rtl-fpga-strict = rtlBuild "fpga-strict" chimeraConfigs.fpga-strict;
        packages.rtl-fpga-debug = rtlBuild "fpga-debug" chimeraConfigs.fpga-debug;
        packages.rtl-asic-lean = rtlBuild "asic-lean" chimeraConfigs.asic-lean;
        packages.rtl-asic-pipe = rtlBuild "asic-pipe" chimeraConfigs.asic-pipe;
        packages.rtl-asic-strict = rtlBuild "asic-strict" chimeraConfigs.asic-strict;
        packages.h8300-binutils = h8300Binutils;
        packages.h8300-bench-gcc = h8300BenchGcc;
        packages.h8300-bench-binutils = h8300BenchBinutils;
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
          bench-toolchain = benchToolchainCheck;
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
            # circt-bmc JITs and dlopen's z3 as a shared library, not the binary.
            Z3_LIB = z3Lib;
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
            # circt-bmc JITs and dlopen's z3 as a shared library, not the binary.
            Z3_LIB = z3Lib;
          };
          inherit shellHook;
        };

        devShells.cocotb = pkgs.mkShell {
          buildInputs = cocotbBuildInputs;
          env = {
            CHIMERA_PROJECT_NAME = "chimera";
            ZAOZI_SRC = zaozi.outPath;
          };
          shellHook = cocotbShellHook;
        };
      }
    );
}
