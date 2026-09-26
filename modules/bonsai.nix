# NixOS module: services.bonsai
#
# Runs `llama-server` from the PrismML-Eng/llama.cpp fork as a hardened,
# auto-restarting systemd service serving an OpenAI-compatible API for the
# Ternary Bonsai 2 27B model (prism-ml/Ternary-Bonsai-2-27B-gguf), optionally
# fronted by Open WebUI.
#
# The model is a single GGUF file (~6-7 GB) that is downloaded into the
# service's state directory on first start and verified against a pinned
# SHA-256 — the same "pinned revision, runtime download" philosophy as
# sglang-nix.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.bonsai;

  stateDir = "/var/lib/bonsai";
  modelDir = "${stateDir}/models";

  # Pinned file metadata from prism-ml/Ternary-Bonsai-2-27B-gguf (main).
  # LFS oid == content SHA-256, so these are the download checksums.
  knownFiles = {
    "Ternary-Bonsai-2-27B-PQ2_0.gguf" = "3907dc1658db1f78a9826bf8d5bcb8dc65db0d466388937af57f2294fae62ec1";
    "Ternary-Bonsai-2-27B-PTQ1_0.gguf" = "53107f530aa52eb00912263ab1ee29bd199261c87cd7b4ad4ca1318c1fe33ee3";
    "Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf" = "6807ede61d570bb86ba34b756a0fa109edc33668604de867c6ea6d8f1d631903";
    "Ternary-Bonsai-2-27B-mmproj-BF16.gguf" = "e287342d92332fa3577ed1d42e921dac9370c08da58ba9337fa450f6cc76cfd7";
  };

  hfUrl = f: "https://huggingface.co/${cfg.model.hfRepo}/resolve/${cfg.model.revision}/${f}";

  # fileName -> sha256 (null when unknown and no explicit override given)
  shaFor = f:
    if knownFiles ? f then knownFiles.${f}
    else cfg.model.sha256;

  # Files to fetch on first start. localPath bypasses the download entirely.
  filesToFetch =
    if cfg.model.localPath != null then []
    else
      [cfg.model.fileName]
      ++ lib.optionals (cfg.model.mmproj != null) [cfg.model.mmproj];

  fetchPairs =
    lib.map
      (f: "${f}|${hfUrl f}|${if shaFor f != null then shaFor f else ""}")
      filesToFetch;

  fetchScript = pkgs.writeShellScriptBin "bonsai-fetch-model" ''
    set -euo pipefail
    outdir="$1"; shift
    mkdir -p "$outdir"
    cd "$outdir"
    for pair in "$@"; do
      file=$${pair%%|*}; rest=$${pair#*|}
      url=$${rest%%|*}; sha=$${rest#*|}
      if [ -s "$file" ]; then
        echo "bonsai-fetch: $file already present, skipping download"
        continue
      fi
      echo "bonsai-fetch: downloading $file"
      curl -fL --retry 5 --retry-delay 5 -C - -o "$file.part" "$url"
      if [ -n "$sha" ]; then
        echo "bonsai-fetch: verifying sha256 for $file"
        echo "$sha  $file.part" | sha256sum -c -
      fi
      mv "$file.part" "$file"
      echo "bonsai-fetch: $file ready"
    done
  '';

  modelPath =
    if cfg.model.localPath != null
    then cfg.model.localPath
    else "${modelDir}/${cfg.model.fileName}";

  serverBin = "${cfg.package}/bin/llama-server";

  serverArgs =
    [
      serverBin
      "-m"
      modelPath
      "--host"
      cfg.host
      "--port"
      (toString cfg.port)
      "-ngl"
      (toString cfg.model.numGpuLayers)
      "-fa"
      (if cfg.flashAttention then "on" else "off")
      "-c"
      (toString cfg.model.contextLength)
      "--temp"
      cfg.sampling.temperature
      "--top-p"
      cfg.sampling.topP
      "--top-k"
      (toString cfg.sampling.topK)
      "--min-p"
      cfg.sampling.minP
      "--jinja"
      "--alias"
      cfg.servedModelName
    ]
    ++ lib.optionals (cfg.model.mmproj != null && cfg.model.localPath == null) [
      "--mmproj"
      "${modelDir}/${cfg.model.mmproj}"
    ]
    ++ lib.optionals (cfg.reasoningBudget != null) [
      "--reasoning-budget"
      (toString cfg.reasoningBudget)
    ]
    ++ cfg.extraArgs;

in {
  options.services.bonsai = {
    enable = lib.mkEnableOption "Bonsai 2 27B (llama.cpp) OpenAI-compatible inference server";

    package = lib.mkOption {
      type = lib.types.package;
      description = ''
        Derivation providing `bin/llama-server` from the PrismML fork.
        Normally `bonsai-nix.packages.''${pkgs.system}.llamaServer`.
      '';
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Address the OpenAI-compatible API listens on.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port the OpenAI-compatible API listens on (llama.cpp default is 8080).";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the API port in the firewall.";
    };

    servedModelName = lib.mkOption {
      type = lib.types.str;
      default = "bonsai-2-27b";
      description = "Model alias exposed on the OpenAI API (llama-server `--alias`).";
    };

    model = {
      hfRepo = lib.mkOption {
        type = lib.types.str;
        default = "prism-ml/Ternary-Bonsai-2-27B-gguf";
        description = "Hugging Face repo the model file is downloaded from.";
      };

      fileName = lib.mkOption {
        type = lib.types.str;
        default = "Ternary-Bonsai-2-27B-PQ2_0.gguf";
        description = ''
          GGUF file to download. `PQ2_0` (7.2 GB) decodes fastest on CUDA /
          Blackwell; `PTQ1_0` (5.95 GB) is the smaller build and the correct
          choice on the Vulkan prebuilds (PQ2_0 silently falls back to CPU
          on Vulkan in the current release, upstream #238).
        '';
      };

      revision = lib.mkOption {
        type = lib.types.str;
        default = "main";
        description = "Hugging Face revision (branch/tag/commit) to download from.";
      };

      sha256 = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Override for `fileName` when it is not in the built-in known-files
          table. Required for verification if you point at a new/renamed
          file.
        '';
      };

      localPath = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Use an already-downloaded GGUF directly instead of downloading.
          When set, no model download happens at service start.
        '';
      };

      mmproj = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf";
        description = ''
          Optional vision-projector file from the same Hugging Face repo
          (downloaded alongside the model, `--mmproj` passed to the server).
          Null disables image input.
        '';
      };

      contextLength = lib.mkOption {
        type = lib.types.ints.between 2048 262144;
        default = 32768;
        description = "Context window (`-c`). The model supports up to 262144 tokens.";
      };

      numGpuLayers = lib.mkOption {
        type = lib.types.ints.between 0 999;
        default = 99;
        description = "GPU layer offload (`-ngl`); 99 = all layers.";
      };
    };

    sampling = {
      temperature = lib.mkOption {
        type = lib.types.str;
        default = "1.0";
        description = "`--temp` (model-card thinking-mode default).";
      };
      topP = lib.mkOption {
        type = lib.types.str;
        default = "0.95";
        description = "`--top-p`.";
      };
      topK = lib.mkOption {
        type = lib.types.ints.positive;
        default = 20;
        description = "`--top-k`.";
      };
      minP = lib.mkOption {
        type = lib.types.str;
        default = "0.05";
        description = "`--min-p` (llama.cpp's own default; recommended by the model card).";
      };
    };

    flashAttention = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Pass `-fa on` (flash attention; recommended for this hybrid-attention model).";
    };

    reasoningBudget = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      example = 8192;
      description = ''
        Server-wide thinking-token budget (`--reasoning-budget`). The model
        defaults to `xhigh` reasoning effort and a small output budget ends
        generation mid-thought, so set this generously (or let clients send
        `reasoning_effort: "medium"` per request).
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "-np" "1" "--cache-ram" "24576" ];
      description = "Extra arguments appended to `llama-server` (e.g. the single-user prompt-cache workaround `-np 1 --cache-ram 24576`).";
    };

    memoryMax = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "100G";
      description = ''
        systemd `MemoryMax=` for the service. On unified-memory hosts (DGX
        Spark) a runaway process can drive host memory to zero and freeze
        the box; a cap makes the OOM killer take the engine instead.
      '';
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra environment variables for the service.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/bonsai.env";
      description = "Environment file for secrets (e.g. `HF_TOKEN=...` if the repo is ever gated).";
    };

    vulkanIcdFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.json";
      description = ''
        `VULKAN_ICD_FILENAMES` for the Vulkan backend. On NixOS the NVIDIA
        ICD ships with the graphics driver under /run/opengl-driver and is
        not on the loader's default search path, so it is named explicitly.
        Set to `null` on systems where the ICD is found via the standard
        paths (or when using a CUDA build; the variable is then unused).
      '';
    };

    ui = {
      enable = lib.mkEnableOption "Open WebUI frontend wired to this Bonsai instance";

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.open-webui;
        defaultText = lib.literalExpression "pkgs.open-webui";
        description = "Open WebUI package to run.";
      };

      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        example = "0.0.0.0";
        description = "Address Open WebUI listens on.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 3080;
        description = "Port Open WebUI listens on (the API itself uses 8080).";
      };

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Open the UI port in the firewall.";
      };

      webSearch = {
        enable = lib.mkEnableOption "web search in Open WebUI";

        engine = lib.mkOption {
          type = lib.types.str;
          default = "duckduckgo";
          description = "Open WebUI web search engine.";
        };

        resultCount = lib.mkOption {
          type = lib.types.ints.positive;
          default = 5;
          description = "Search results per query.";
        };

        concurrentRequests = lib.mkOption {
          type = lib.types.ints.positive;
          default = 10;
          description = "Concurrent web search requests.";
        };
      };

      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Extra environment variables for Open WebUI (wins over module-set ones).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.model.localPath != null || knownFiles ? cfg.model.fileName || cfg.model.sha256 != null;
        message = "services.bonsai.model.fileName '${cfg.model.fileName}' is not in the known-files table; set model.sha256 or use a known file.";
      }
      {
        assertion = cfg.model.localPath != null || cfg.model.mmproj == null || knownFiles ? cfg.model.mmproj;
        message = "services.bonsai.model.mmproj '${cfg.model.mmproj}' is not in the known-files table.";
      }
      {
        assertion = cfg.model.contextLength <= 262144;
        message = "services.bonsai.model.contextLength exceeds the model's 262144-token window.";
      }
    ];

    systemd.services.bonsai = {
      description = "Ternary Bonsai 2 27B — llama.cpp OpenAI-compatible server (${cfg.servedModelName})";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      # curl/sha256sum needed by the ExecStartPre download helper.
      path = with pkgs; [ bash curl coreutils ];

      environment =
        {
          HOME = stateDir;
          # The prebuilt tarball's .so files live in $package/lib.
          LD_LIBRARY_PATH = lib.makeLibraryPath [
            cfg.package
            pkgs.openssl.out
            pkgs.stdenv.cc.cc.lib
            pkgs.vulkan-loader
          ];
        }
        // lib.optionalAttrs (cfg.vulkanIcdFile != null) {
          VULKAN_ICD_FILENAMES = cfg.vulkanIcdFile;
        }
        // cfg.environment;

      serviceConfig = {
        Type = "simple";
        ExecStartPre = [
          "${fetchScript}/bin/bonsai-fetch-model ${modelDir} ${lib.escapeShellArgs fetchPairs}"
        ];
        ExecStart = lib.escapeShellArgs serverArgs;
        User = "bonsai";
        Group = "bonsai";
        StateDirectory = "bonsai";
        WorkingDirectory = stateDir;

        Restart = "always";
        RestartSec = 5;
        # First start may download 6-7 GB of weights.
        TimeoutStartSec = "60min";

        EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
        MemoryMax = lib.mkIf (cfg.memoryMax != null) cfg.memoryMax;

        # GPU access (CUDA on x86_64, Vulkan on aarch64 — both use the DRM
        # nodes; the nvidia char devices are for the CUDA build).
        SupplementaryGroups = [ "video" "render" ];
        DeviceAllow = [
          "char-nvidiactl"
          "char-nvidia-caps"
          "char-nvidia-frontend"
          "char-nvidia-uvm"
          "char-drm"
        ];

        # Hardening (kept compatible with a prebuilt, dynamically-linked binary)
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
        UMask = "0077";
      };
    };

    users.users.bonsai = {
      isSystemUser = true;
      group = "bonsai";
      home = stateDir;
      description = "Bonsai service user";
    };
    users.groups.bonsai = { };

    networking.firewall.allowedTCPPorts =
      lib.optional cfg.openFirewall cfg.port
      ++ lib.optionals (cfg.ui.enable && cfg.ui.openFirewall) [ cfg.ui.port ];

    services.open-webui = lib.mkIf cfg.ui.enable {
      enable = true;
      package = cfg.ui.package;
      host = cfg.ui.host;
      port = cfg.ui.port;
      openFirewall = false; # handled above
      environment =
        {
          SCARF_NO_ANALYTICS = "True";
          DO_NOT_TRACK = "True";
          ANONYMIZED_TELEMETRY = "False";
          # Point at the local llama-server OpenAI endpoint.
          OPENAI_API_BASE_URL = "http://127.0.0.1:${toString cfg.port}/v1";
          OPENAI_API_KEY = "EMPTY";
          ENABLE_OLLAMA_API = "False";
        }
        // lib.optionalAttrs cfg.ui.webSearch.enable {
          ENABLE_WEB_SEARCH = "True";
          WEB_SEARCH_ENGINE = cfg.ui.webSearch.engine;
          WEB_SEARCH_RESULT_COUNT = toString cfg.ui.webSearch.resultCount;
          WEB_SEARCH_CONCURRENT_REQUESTS = toString cfg.ui.webSearch.concurrentRequests;
        }
        // cfg.ui.environment;
    };

    # Start the UI after the API it fronts.
    systemd.services.open-webui = lib.mkIf cfg.ui.enable {
      after = [ "bonsai.service" ];
      wants = [ "bonsai.service" ];
    };
  };
}
