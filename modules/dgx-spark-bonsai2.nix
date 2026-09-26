# Preset: Ternary Bonsai 2 27B on a DGX Spark (GB10, aarch64, 128 GB unified),
# tuned for throughput with many concurrent coding agents.
#
# Backend: the PrismML fork built from source with CUDA for sm_121
# (`packages.aarch64-linux.llamaServerCuda`). The fork ships no Linux
# aarch64 CUDA prebuild and its Vulkan prebuild decodes at ~5 tok/s on this
# box; the native CUDA build measures ~35 tok/s single-stream and
# ~150-180 tok/s aggregate at 16-32 streams (llama-batched-bench, PTQ1_0).
#
# Measured on this hardware (b10743, -fa on), so you don't have to re-run it:
#   packing   pp512 t/s   tg128 t/s (1 stream)   tg aggregate @32
#   PTQ1_0      ~945          35.6                  ~178
#   PQ2_0      ~1020          30.5                  ~171
#   -ub 256/512/1024 and q8_0 KV: no measurable difference.
#   Same ternary weights in both files; PTQ1_0 is kept for the faster decode.
#
# Nothing here trades model quality for speed: full-precision KV, model-card
# sampling, no speculative drafter (none exists for Bonsai 2 27B, and the
# community one loses its gain past 2 slots). Everything is mkDefault.
#
# Import alongside `nixosModules.bonsai`:
#   imports = [
#     bonsai-nix.nixosModules.bonsai
#     bonsai-nix.nixosModules.dgx-spark-bonsai2
#   ];
{self}: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.bonsai;
in {
  config = lib.mkIf cfg.enable {
    # nixpkgs-unstable has no aarch64 binary cache entry for open-webui, so
    # it (and its torch stack) builds from source; torchaudio then fails one
    # numerical-tolerance test on this CPU (test_batch_melspectrogram,
    # 1 failed / 2232 passed). Skip its tests so the UI is installable.
    nixpkgs.overlays = lib.mkIf cfg.ui.enable [
      (final: prev: {
        pythonPackagesExtensions =
          prev.pythonPackagesExtensions
          ++ [
            (pyFinal: pyPrev: {
              torchaudio = pyPrev.torchaudio.overridePythonAttrs (_: { doCheck = false; });
            })
          ];
      })
    ];

    services.bonsai = {
      package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.llamaServerCuda;

      model = {
        fileName = lib.mkDefault "Ternary-Bonsai-2-27B-PTQ1_0.gguf";
        # Per-slot window. Coding agents routinely exceed 64K; the hybrid
        # model cannot context-shift, so an over-long request fails rather
        # than truncates. 128K per slot is the safe choice.
        contextLength = lib.mkDefault 131072;
        numGpuLayers = lib.mkDefault 99;
        mmproj = lib.mkDefault "Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf";
      };

      # 8 concurrent sequences. Measured on the server: 1 stream 35.6 tok/s,
      # 8 streams 12.7 tok/s each / 87 tok/s aggregate. 8 x 128K FP16 KV is
      # ~64 GiB (72 GiB RSS at load). Raise to 16 for more agents at ~9 tok/s
      # each (adds ~64 GiB), or halve contextLength to keep memory flat.
      slots = lib.mkDefault 8;
      batchSize = lib.mkDefault 2048;
      ubatchSize = lib.mkDefault 512;
      kvCacheType = lib.mkDefault "f16";

      # Prefix reuse across agent turns: every tool-call round trip re-sends
      # the whole conversation, so without this each turn re-prefills it.
      promptCache = {
        enable = lib.mkDefault true;
        ramMiB = lib.mkDefault 16384;
        checkpoints = lib.mkDefault 32;
        idleSlots = lib.mkDefault true;
      };

      # The model defaults to `xhigh` reasoning effort; cap the thinking
      # budget so answers don't run out of output tokens mid-reasoning.
      # (Per-request `reasoning_effort: "medium"` still overrides downward.)
      reasoningBudget = lib.mkDefault 16384;

      # No Vulkan ICD needed for the CUDA build.
      vulkanIcdFile = lib.mkDefault null;

      # Unified-memory guard: ~72 GiB weights+KV, +16 GiB prompt cache, plus
      # compute buffers. Take the OOM hit on the engine, not the host.
      memoryMax = lib.mkDefault "108G";
    };
  };
}
