# Pinned prebuilt llama.cpp from the PrismML fork.
#
# Stock llama.cpp cannot load the Bonsai 2 27B GGUF files: the PTQ1_0 /
# PQ2_0 ternary quants and the hybrid-attention kernels only exist in the
# PrismML-Eng/llama.cpp fork. b10743 (commit adfffbe41) is the newest
# release that still ships aarch64 Linux binaries. There is no aarch64
# Linux CUDA prebuild at all and the Vulkan one is ~7x slower than CUDA on
# a GB10, so the DGX Spark preset uses the from-source build in
# ./llama-server-cuda.nix instead.
#
# Exports: { packages.<backend>, checks.llamaServerVersion } per system.
{
  nixpkgs,
  system,
}: let
  pkgs = import nixpkgs {
    inherit system;
    config.allowUnfree = true;
  };
  lib = nixpkgs.lib;

  release = "prism-b10743-adfffbe";
  releaseBase = "https://github.com/PrismML-Eng/llama.cpp/releases/download/${release}";

  # Prebuilt tarballs: a flat directory of executables + shared libs.
  # Hashes: SHA-256 of the .tar.gz, verified by fetchurl on download.
  artifact = {
    # aarch64: no CUDA prebuild exists; Vulkan is the GPU option.
    # NOTE: PQ2_0 on the current Vulkan binary silently falls back to CPU
    # (<2 tok/s; upstream #238, fixed in source) — use PTQ1_0 on Vulkan.
    aarch64-linux.vulkan = {
      url = "${releaseBase}/llama-${release}-bin-ubuntu-vulkan-arm64.tar.gz";
      sha256 = "c4aabed59a764e65b8ca03864dbd25c3b56c554e0e76a740868bb2bf9b693666";
    };
    aarch64-linux.cpu = {
      url = "${releaseBase}/llama-${release}-bin-ubuntu-arm64.tar.gz";
      sha256 = "589a3b271c2c4d3b22e9d1225277b8f7f09f1d6583706d4591945d3297654f6b";
    };
    x86_64-linux.cuda128 = {
      url = "${releaseBase}/llama-${release}-bin-linux-cuda-12.8-x64.tar.gz";
      sha256 = "43b73a24d5cd83c4482750ee52e59afac497c669c008a319e44e43a0033757e2";
    };
    x86_64-linux.cpu = {
      url = "${releaseBase}/llama-${release}-bin-ubuntu-x64.tar.gz";
      sha256 = "1bb340929fddae8667c97ec6d4064a5768fe1dd08eeee0074b8d5e08f07dfc31";
    };
  };

  # ELF interpreter path per system
  interp =
    if system == "x86_64-linux" then "ld-linux-x86-64.so.2"
    else "ld-linux-aarch64.so.1";

  makeLlamaServer = name: a:
    pkgs.stdenvNoCC.mkDerivation {
      pname = "llama-server-prism-${name}";
      version = "b10743";
      src = pkgs.fetchurl {
        inherit (a) url sha256;
      };
      nativeBuildInputs = [ pkgs.patchelf ];
      dontUnpack = true;
      dontConfigure = true;
      dontBuild = true;
      installPhase = ''
        mkdir -p $out/bin
        tar -xzf $src --strip-components=1 -C $out/bin
        # The prebuilt layout is flat: every executable dlopens its
        # ggml/llama backend plugins relative to its own directory
        # ($ORIGIN), so the shared libraries must stay next to the
        # binaries. Everything lives in $out/bin; $out/lib is a symlink
        # so LD_LIBRARY_PATH conventions keep working.
        ln -s bin $out/lib
        for f in $out/bin/*; do
          [ -f "$f" ] || continue
          patchelf --set-interpreter ${pkgs.glibc}/lib/${interp} --set-rpath '$ORIGIN' "$f" || true
        done
      '';
      meta = with lib; {
        description = "llama-server prebuilt by the PrismML fork (release ${release}, ${name} backend)";
        longDescription = ''
          Prebuilt llama.cpp binaries from the PrismML-Eng/llama.cpp fork,
          release ${release}.

          Required for the Ternary Bonsai 2 27B GGUF files
          (prism-ml/Ternary-Bonsai-2-27B-gguf): the PTQ1_0 and PQ2_0 quants
          plus the custom hybrid-attention kernels exist only in the fork.
          Stock llama.cpp rejects the files, and its generic Q2_0 loader
          produces garbled output on them.

          The ${name} backend. Shared libraries are unpacked into $out/lib;
          the runtime library search path must include it plus the system
          C++ runtime, OpenSSL and (for the Vulkan build) the Vulkan loader.
        '';
        license = licenses.mit;
        platforms = [system];
        mainProgram = "llama-server";
      };
    };

  # Default backend per system: CUDA 12.8 on x86_64 (release docs recommend
  # it over the crashing 13.3 build, upstream #222), Vulkan on aarch64.
  pkg =
    if system == "x86_64-linux" then makeLlamaServer "cuda-12.8" artifact.x86_64-linux.cuda128
    else makeLlamaServer "vulkan" artifact.aarch64-linux.vulkan;

in {
  packages =
    (lib.optionalAttrs (system == "x86_64-linux") {
      llamaServer = pkg;
      llamaServerCpu = makeLlamaServer "cpu" artifact.x86_64-linux.cpu;
    })
    // (lib.optionalAttrs (system == "aarch64-linux") {
      llamaServer = pkg;
      llamaServerVulkan = pkg;
      llamaServerCpu = makeLlamaServer "cpu" artifact.aarch64-linux.cpu;
    })
    // {
      # From-source CUDA build (sm_121 / GB10 by default); see llama-server-cuda.nix.
      inherit ((import ./llama-server-cuda.nix { inherit nixpkgs system; })) llamaServerCuda;
    };

  checks = {
    # Prove the prebuilt binary starts and reports its version. The Vulkan
    # build links libvulkan but only initialises the ICD when actually used,
    # so --version works in a sandbox.
    llamaServerVersion = pkgs.stdenvNoCC.mkDerivation {
      name = "llama-server-${system}-version-check";
      dontUnpack = true;
      dontConfigure = true;
      dontBuild = true;
      dontFixup = true;
      buildInputs = [ pkgs.openssl.out pkgs.stdenv.cc.cc.lib pkgs.vulkan-loader ];
      nativeBuildInputs = [ pkg ];
      installPhase = ''
        export LD_LIBRARY_PATH="${pkg}/lib:${pkgs.openssl.out}/lib:${pkgs.stdenv.cc.cc.lib}/lib:${pkgs.vulkan-loader}/lib"
        ${pkg}/bin/llama-server --version
        touch $out
      '';
    };
  };
}
