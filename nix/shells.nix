{
  nixpkgs,
  system,
  llamaServer,
}: let
  pkgs = import nixpkgs {
    inherit system;
    config.allowUnfree = true;
  };
in {
  devShells.default = pkgs.mkShell {
    buildInputs = with pkgs; [
      curl
      gnugrep
      coreutils
      openssl.out
      vulkan-loader
      llamaServer
    ];
    shellHook = ''
      export BONSAI_LLAMA_SERVER_DIR=${llamaServer}
      export LD_LIBRARY_PATH=${llamaServer}/lib:${pkgs.openssl.out}/lib:${pkgs.stdenv.cc.cc.lib}/lib:${pkgs.vulkan-loader}/lib$$LD_LIBRARY_PATH
      echo "bonsai-nix dev shell"
      echo "  llama-server: $${BONSAI_LLAMA_SERVER_DIR}/bin/llama-server"
      echo "  try:          $${BONSAI_LLAMA_SERVER_DIR}/bin/llama-server --version"
    '';
  };
}
