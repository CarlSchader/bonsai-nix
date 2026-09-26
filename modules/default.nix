{self, ...}: {
  nixosModules = rec {
    bonsai = import ./bonsai.nix;
    default = bonsai;
    # Opinionated preset for the DGX Spark (GB10, aarch64): from-source CUDA
    # build + PTQ1_0 packing, sized for many concurrent coding agents on
    # 128 GB unified memory. `package` defaults to this flake's
    # `llamaServerCuda` (overridable).
    dgx-spark-bonsai2 = import ./dgx-spark-bonsai2.nix {inherit self;};
  };
}
