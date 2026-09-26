# bonsai-nix

A pinned [llama.cpp](https://github.com/PrismML-Eng/llama.cpp) (PrismML
fork) environment and a NixOS module that runs
[Ternary Bonsai 2 27B](https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf)
as a hardened, auto-restarting systemd service — optionally fronted by
Open WebUI.

Sibling of [sglang-nix](https://github.com/carlschader/sglang-nix); same
layout, different engine. SGLang cannot load these weights at all: the
PTQ1_0 / PQ2_0 ternary quants and the hybrid-attention kernels only exist in
the PrismML llama.cpp fork, so this project pins a release of that fork
(prebuilt tarballs, no source builds).

```nix
inputs.bonsai-nix.url = "github:carlschader/bonsai-nix";

{
  imports = [
    bonsai-nix.nixosModules.bonsai
    bonsai-nix.nixosModules.dgx-spark-bonsai2   # optional preset, see below
  ];

  services.bonsai = {
    enable = true;
    package = bonsai-nix.packages.${pkgs.system}.llamaServer;
    ui.enable = true;
  };
}
```

The DGX Spark preset reproduces the recommended setup for a GB10 machine:
Vulkan backend, PTQ1_0 packing (5.95 GB), 131K context, memory cap. On the
first start the service downloads the model into
`/var/lib/bonsai/models/` and verifies its SHA-256.

The API is OpenAI-compatible on `0.0.0.0:8080`; Open WebUI listens on
`127.0.0.1:3080`.

See [docs/usage.md](docs/usage.md) for the full option reference, model /
packing trade-offs, known issues, update procedure, and troubleshooting.

## Model facts

- **Ternary g128** weights: {−1, 0, +1} with FP16 group-wise scales,
  ~1.72 bits/weight, 27.36B params — full 27B-class reasoning at ~5.95 GB
  (PTQ1_0) or ~7.21 GB (PQ2_0), vs ~54 GB in FP16.
- **98.2% of FP16 benchmark average** (14 thinking-mode benchmarks); math
  and coding hold up, vision is the weakest category.
- **262K-token context**, kept practical on-device by the ~75%
  linear-attention backbone.
- **Thinking model**: `xhigh` reasoning effort by default; use
  `reasoning_effort: "medium"` for shorter answers, and keep output limits
  generous (≥ 16384) or answers get cut off mid-thought.
- **Vision**: optional Q8_0 `mmproj` projector (~0.63 GB), loaded with
  `--mmproj`.
- Apache 2.0.

## Flake outputs

- `packages.<system>.llamaServer` (also `default`) — the pinned PrismML
  llama.cpp build (CUDA 12.8 on x86_64-linux, Vulkan on aarch64-linux)
- `packages.<system>.llamaServerCpu` — CPU-only build of the fork
- `nixosModules.bonsai` (also `default`) — the `services.bonsai` module
- `nixosModules.dgx-spark-bonsai2` — preset: PTQ1_0 + Vulkan on a DGX Spark
- `checks.<system>.llamaServerVersion` — binary smoke test
- `checks.<system>.bonsaiModuleEval` — module eval against a minimal
  nixosSystem
- `devShells.<system>.default` — curl + the llama-server binary with
  `LD_LIBRARY_PATH` set

## Development

```console
nix build .#llamaServer    # fetch + unpack the pinned binary
nix flake check            # version check + module-eval check
```
