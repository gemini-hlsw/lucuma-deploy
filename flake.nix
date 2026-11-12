{
  inputs = {
    typelevel-nix.url = "github:typelevel/typelevel-nix";
    nixpkgs.follows = "typelevel-nix/nixpkgs";
    flake-utils.follows = "typelevel-nix/flake-utils";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, flake-utils, typelevel-nix, sops-nix }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ typelevel-nix.overlays.default ];
        };

        # SOPS secrets
        secretValues = {
          GPP_SLACK_WEBHOOK_URL = "SOPS_ENCRYPTED_GPP_SLACK_WEBHOOK_URL";
        };
      in
      {
        # Only the CLIs the promotion, rollback and test scripts call. No JDK, no node.
        devShell = pkgs.devshell.mkShell {
          packages = [
            pkgs.bash
            pkgs.git
            pkgs.jq
            pkgs.curl
            pkgs.github-cli
            pkgs.heroku
            pkgs.firebase-tools
            pkgs.awscli2
            pkgs.hasura-cli
            pkgs.sops
            pkgs.age
            pkgs.direnv
          ];
          env = [
            {
              name = "GPP_SLACK_WEBHOOK_URL";
              value = secretValues.GPP_SLACK_WEBHOOK_URL;
            }
          ];
        };
      }

    );
}
