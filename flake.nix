{
  description = "Iocaine Classifier - CloudFront edge function for AI bot detection";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
    passveil.url = "github:doma-engineering/passveil";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      passveil,
      ...
    }:
    flake-utils.lib.eachSystem
      [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ]
      (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };

          # Google Cloud SDK with alpha and beta components
          gcloud = pkgs.google-cloud-sdk.withExtraComponents (
            with pkgs.google-cloud-sdk.components;
            [
              alpha
              beta
            ]
          );
        in
        {
          devShells.default = pkgs.mkShell {
            buildInputs = with pkgs; [
              # Node.js runtime for CloudFront function development & tests
              nodejs_22
              pnpm

              # AWS CLI for CloudFront deployments
              awscli2

              # Google Cloud SDK for GCE deployments
              gcloud

              # YSH (Oils shell) for declarative deployment scripts
              oils-for-unix

              # Passveil for secrets management
              passveil.packages.${system}.passveil

              # Load testing
              k6

              # Shell utilities
              curl
              jq
              zip
              git
              gnused
              dnsutils # For DNS verification (dig)

              # Shell script linting
              shellcheck
              shfmt

              # Documentation generation
              texliveFull
              pandoc

              # Gamedev
              # godot_4
            ];
          };
        }
      );
}
