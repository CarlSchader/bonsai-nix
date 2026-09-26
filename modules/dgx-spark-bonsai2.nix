# Preset: Ternary Bonsai 2 27B on a DGX Spark (GB10, aarch64, 128 GB unified).
#
# The PrismML release has no aarch64 CUDA prebuild, so this preset uses the
# Vulkan build. PQ2_0 silently falls back to the CPU on the current Vulkan
# binary (upstream #238, fixed in source), so it pairs PTQ1_0 with the 128 GB
# of unified memory. Everything is mkDefault — any option can be overridden.
#
# Import alongside `nixosModules.bonsai`:
#   imports = [
#     bonsai-nix.nixosModules.bonsai
#     bonsai-nix.nixosModules.dgx-spark-bonsai2
#   ];
{
  config,
  lib,
  ...
}: let
  cfg = config.services.bonsai;
in {
  config = lib.mkIf cfg.enable {
    services.bonsai = {
      model = {
        fileName = lib.mkDefault "Ternary-Bonsai-2-27B-PTQ1_0.gguf";
        # 128 GB unified: the demo's auto-tier tops out at 131072 for >71 GB
        # machines. FP16 KV is ~64 KiB/token on this hybrid-attention model,
        # so 131K ≈ 8 GiB of KV — comfortable.
        contextLength = lib.mkDefault 131072;
        numGpuLayers = lib.mkDefault 99;
        mmproj = lib.mkDefault "Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf";
      };

      # The model defaults to `xhigh` reasoning effort; cap the thinking
      # budget so answers don't run out of output tokens mid-reasoning.
      # (Per-request `reasoning_effort: "medium"` still overrides downward.)
      reasoningBudget = lib.mkDefault 16384;

      # Single-user box: one slot keeps the prompt cache intact across turns
      # instead of re-prefilling the whole conversation (Bonsai-demo #183).
      extraArgs = lib.mkDefault [
        "-np"
        "1"
        "--cache-ram"
        "24576"
      ];

      # Unified-memory guard: take the OOM hit on the engine, not the host.
      memoryMax = lib.mkDefault "100G";
    };
  };
}
