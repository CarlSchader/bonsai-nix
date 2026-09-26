{...}: {
  nixosModules = rec {
    bonsai = import ./bonsai.nix;
    default = bonsai;
    # Opinionated preset for the DGX Spark (GB10, aarch64): the Vulkan
    # prebuild + PTQ1_0 packing, sized for 128 GB unified memory.
    dgx-spark-bonsai2 = import ./dgx-spark-bonsai2.nix;
  };
}
