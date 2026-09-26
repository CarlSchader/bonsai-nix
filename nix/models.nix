# Model catalogue for clients (e.g. pi-coding-agent's provider config).
# `id` must match `services.bonsai.servedModelName` (llama-server --alias);
# `contextWindow` is the per-slot window from the DGX Spark preset — the
# hybrid-attention model cannot shift context, so a longer request fails.
{...}: {
  models = [
    {
      id = "bonsai-2-27b";
      hfId = "prism-ml/Ternary-Bonsai-2-27B-gguf";
      contextWindow = 131072;
      maxTokens = 32768;
    }
  ];
}
