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

Default preset for DGX Spark uses PTQ1_0 because PQ2_0 silently falls back
to CPU on the Vulkan prebuild (upstream #238, fix pending in source).

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
- **Single-user prompt cache** → add to `extraArgs`:
  ```nix
  extraArgs = [ "-np" "1" "--cache-ram" "24576" ];
  ```
- **Tool calling**: `--jinja` is enabled by default for OpenAI-style
  `tool_calls`.
- **CUDA 13.3 crashes** on some systems — use the 12.8 build (the default).
- **AVX-512 CPU crash with PQ2_0**: use PTQ1_0 or build from source.

## Updating the llama.cpp binary

1. Check for new releases: <https://github.com/PrismML-Eng/llama.cpp/releases>
2. Download the new tarball, compute its SHA-256:
   ```sh
   curl -LO <url> && sha256sum llama-*.tar.gz
   ```
3. Update `url` and `sha256` in `nix/llama-server.nix`.
4. `nix build .#llamaServer` to verify.

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
