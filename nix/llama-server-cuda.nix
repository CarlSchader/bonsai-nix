# From-source CUDA build of the PrismML llama.cpp fork.
#
# The fork ships no Linux aarch64 CUDA prebuild, and its Vulkan prebuild
# cannot run PQ2_0 on the GPU (upstream #238). On a DGX Spark (GB10,
# sm_121) a native CUDA build is the only way to get the fast PQ2_0
# kernels, CUDA graphs and proper continuous batching.
#
# We reuse nixpkgs' `llama-cpp` derivation (same upstream layout, same
# tools/ui npm lockfile as v0.5.0, so `npmDepsHash` still matches) and only
# swap the source and the CUDA architecture list.
{
  nixpkgs,
  system,
  # Compute capabilities to compile real device code for. 12.1 = GB10.
  cudaCapabilities ? [ "12.1" ],
}: let
  pkgs = import nixpkgs {
    inherit system;
    config = {
      allowUnfree = true;
      cudaSupport = true;
      inherit cudaCapabilities;
    };
  };
  lib = nixpkgs.lib;

  # Pinned fork commit (release prism-b10743-adfffbe).
  rev = "adfffbe41b2cabcd51fff326ab045662265062bb";
  buildNumber = "10743";

  src = pkgs.fetchFromGitHub {
    owner = "PrismML-Eng";
    repo = "llama.cpp";
    inherit rev;
    hash = "sha256-SNBAC+dNTwQxpGmKyG7i/8eqCNg6985DXtqGbzWgwFA=";
  };

  base = pkgs.llama-cpp.override {
    cudaSupport = true;
    cudaPackages = pkgs.cudaPackages_13;
    vulkanSupport = false;
    blasSupport = false;
  };
in {
  llamaServerCuda = (base.overrideAttrs (old: {
    pname = "llama-cpp-prism-cuda";
    version = "prism-b${buildNumber}-${lib.substring 0 7 rev}";
    inherit src;
    # Drop the upstream `-DLLAMA_BUILD_NUMBER/COMMIT` values and use the
    # fork's so `llama-server --version` reports what is actually running.
    cmakeFlags =
      (lib.filter
        (f: !(lib.hasPrefix "-DLLAMA_BUILD_NUMBER=" f || lib.hasPrefix "-DLLAMA_BUILD_COMMIT=" f))
        old.cmakeFlags)
      ++ [
        (lib.cmakeFeature "LLAMA_BUILD_NUMBER" buildNumber)
        (lib.cmakeFeature "LLAMA_BUILD_COMMIT" (lib.substring 0 7 rev))
        # CUDA graphs and the FA kernels are what make Blackwell fast;
        # both are on by default, listed for clarity.
        (lib.cmakeBool "GGML_CUDA_GRAPHS" true)
        (lib.cmakeBool "GGML_CUDA_FA" true)
      ];
    meta = old.meta // {
      description = "PrismML llama.cpp fork (${buildNumber}) built from source with CUDA for ${lib.concatStringsSep "," cudaCapabilities}";
      platforms = [ system ];
      mainProgram = "llama-server";
    };
  }));
}
