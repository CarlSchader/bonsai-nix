# Using bonsai-nix

## Quick start

```nix
# configuration.nix
{ pkgs, ... }:
{
  imports = [
    /path/to/bonsai-nix/modules/bonsai.nix
    /path/to/bonsai-nix/modules/dgx-spark-bonsai2.nix  # optional preset
  ];

  services.bonsai = {
    enable = true;
    package = (import /path/to/bonsai-nix { inherit pkgs; }).packages.${pkgs.system}.llamaServer;
    openFirewall = true;
    ui.enable = true;
  };
}
```

Or as a flake input:

```nix
{
  inputs.bonsai-nix.url = "github:carlschader/bonsai-nix";

  outputs = { self, nixpkgs, bonsai-nix, ... } @ inputs:
    let
      system = "aarch64-linux";  # or x86_64-linux
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      nixosConfigurations.spark = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./configuration.nix
          bonsai-nix.nixosModules.bonsai
          bonsai-nix.nixosModules.dgx-spark-bonsai2
          {
            services.bonsai = {
              enable = true;
              package = bonsai-nix.packages.${system}.llamaServer;
              openFirewall = true;
              ui.enable = true;
            };
          }
        ];
      };
    };
}
```

After `nixos-rebuild switch`:
- **API**: `http://localhost:8080/v1/chat/completions` (OpenAI-compatible)
- **Web UI**: `http://localhost:3080` (when `ui.enable = true`)
- **Logs**: `journalctl -u bonsai -f`

## First boot

The service downloads the model on first start into `/var/lib/bonsai/models/`:

| File | Size | Purpose |
|---|---|---|
| `Ternary-Bonsai-2-27B-PQ2_0.gguf` | 7.2 GB | Main model (faster decode on CUDA/Blackwell) |
| `Ternary-Bonsai-2-27B-PTQ1_0.gguf` | 5.9 GB | Main model (smaller; better on Vulkan) |
| `Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf` | 0.6 GB | Vision projector (optional) |

Download is resuming-safe (`curl -C -`) and SHA-256 verified. Subsequent
starts skip the download.

## Choosing a packing

The model ships two GGUF variants:

| Packing | Size | Best for | Notes |
|---|---|---|---|
| **PTQ1_0** | 5.95 GB | Ada GPUs, L4, **Vulkan** | Smaller; slightly slower decode on Blackwell |
| **PQ2_0** | 7.21 GB | CUDA / Blackwell / H100 / A100 | Faster decode & prefill; **broken on current Vulkan release** |

On the DGX Spark CUDA build both packings run on the GPU and produce the
same outputs (same ternary weights, different packing). Measured there:
PTQ1_0 decodes ~16% faster single-stream (35.6 vs 30.5 tok/s), PQ2_0
prefills ~7% faster (~1020 vs ~945 tok/s); aggregate decode at 32 streams
is equal. The preset keeps PTQ1_0.

## Sampling

Model-card recommended defaults (thinking mode) are baked in:

```
--temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.05
```

Override via `services.bonsai.sampling.*`.

### Reasoning effort

The model defaults to `xhigh` reasoning effort. For shorter/faster answers
send `reasoning_effort: "medium"` in the API request, or set a server-wide
cap:

```nix
services.bonsai.reasoningBudget = 8192;  # --reasoning-budget 8192
```

> ⚠️ `reasoning_effort: "high"` returns HTTP 500 — use `"xhigh"` or `"medium"`.

## Known issues & tips

- **Empty / truncated answers** → increase `max_tokens` to ≥ 16384 and/or
  use `reasoning_effort: "medium"`.
- **Prompt cache** is on by default (`promptCache.*` → `--cache-ram`,
  `--ctx-checkpoints`, `--cache-idle-slots`). Clients must send
  `cache_prompt: true` (llama-server's default) to reuse a prefix. Agent
  loops that re-render *reasoning* into history defeat the prefix match
  (Bonsai-demo #183) — strip it, or pass `--reasoning-preserve` via
  `extraArgs` if your client relies on it.
- **`-kvu` / `--cache-reuse` are not supported** on this hybrid-attention
  model: every slot owns a full `contextLength` window and a request longer
  than that fails instead of being shifted.
- **Tool calling**: `--jinja` is enabled by default for OpenAI-style
  `tool_calls`.
- **CUDA 13.3 crashes** on some systems — use the 12.8 build (the default).
- **AVX-512 CPU crash with PQ2_0**: use PTQ1_0 or build from source.

## Serving many agents (DGX Spark)

Options that matter, with what the preset sets and what was measured on a
GB10 with the CUDA build:

| Option | Preset | Notes |
|---|---|---|
| `slots` (`-np`) | 8 | 1 stream 35.6 tok/s; 8 streams 12.7 each / 87 aggregate; 16–32 streams ~150–180 aggregate. |
| `model.contextLength` (per slot) | 131072 | `-c` = slots × contextLength. FP16 KV ≈ 64 KiB/token → 8×128K ≈ 64 GiB (72 GiB RSS at load). |
| `kvCacheType` | `f16` | `q8_0` halves KV memory at no measured speed cost; `q4_0` is not offered (3–60× slower prefill). |
| `batchSize` / `ubatchSize` | 2048 / 512 | `-ub` 256–1024 measure identically. |
| `promptCache.ramMiB` | 16384 | Host RAM for saved prompt states. |
| `memoryMax` | 108G | systemd cap; keep weights + KV + cache under it. |

Trade-offs, all without touching model quality:
- More agents → `slots = 16` (adds ~64 GiB at 128K; or set
  `contextLength = 65536` to keep memory flat). Per-stream speed at 16 is
  ~9 tok/s.
- Fewer, faster agents → `slots = 4` (~20 tok/s each).
- Speculative decoding: no official drafter exists for Bonsai 2 27B, and
  the community DSpark drafter's gain collapses past 2 slots and disables
  the prompt cache — not used.

Benchmark the running service with `CONCURRENCY=8 ./bench.sh`.

## Updating the llama.cpp binary

1. Check for new releases: <https://github.com/PrismML-Eng/llama.cpp/releases>
2. Download the new tarball, compute its SHA-256:
   ```sh
   curl -LO <url> && sha256sum llama-*.tar.gz
   ```
3. Update `url` and `sha256` in `nix/llama-server.nix` (prebuilds) and
   `rev`/`hash`/`buildNumber` in `nix/llama-server-cuda.nix` (source build;
   `nix-prefetch-url --unpack https://github.com/PrismML-Eng/llama.cpp/archive/<rev>.tar.gz`).
   If `tools/ui/package-lock.json` changed relative to nixpkgs' llama-cpp,
   the `npmDepsHash` must be overridden too.
4. `nix build .#llamaServer .#llamaServerCuda` to verify.

## Updating the model

1. Check the HuggingFace repo for new files / revisions.
2. Compute SHA-256 of the new file.
3. Update `model.fileName` and `model.sha256` (or the known-files table in
   `modules/bonsai.nix`).

## Dev shell

```sh
nix develop
# llama-server is on PATH with LD_LIBRARY_PATH set
llama-server --help
```

## Benchmark

```sh
./bench.sh                      # default: http://127.0.0.1:8080, model "bonsai-2-27b"
./bench.sh http://host:8080 my-model
```
