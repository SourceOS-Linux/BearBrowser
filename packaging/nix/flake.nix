{
  description = "BearBrowser packaging scaffold";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        bearbrowserVersion = "150.0.1";
      in
      {
        packages.bearbrowser-human-secure = pkgs.stdenvNoCC.mkDerivation {
          pname = "bearbrowser-human-secure";
          version = bearbrowserVersion;
          src = ../..;
          dontBuild = true;
          installPhase = ''
            mkdir -p $out/share/bearbrowser
            cp -R settings/profiles/human-secure $out/share/bearbrowser/profile
            cp policy/bearbrowser-contract.yaml $out/share/bearbrowser/
            cp manifests/upstream.json $out/share/bearbrowser/
          '';
        };

        packages.bearbrowser-agent-runtime = pkgs.stdenvNoCC.mkDerivation {
          pname = "bearbrowser-agent-runtime";
          version = bearbrowserVersion;
          src = ../..;
          dontBuild = true;
          installPhase = ''
            mkdir -p $out/share/bearbrowser
            cp -R settings/profiles/agent-runtime $out/share/bearbrowser/profile
            cp policy/bearbrowser-contract.yaml $out/share/bearbrowser/
            cp mounts/agent-browser-mounts.yaml $out/share/bearbrowser/
            cp manifests/upstream.json $out/share/bearbrowser/
          '';
        };

        packages.default = self.packages.${system}.bearbrowser-human-secure;

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            bash
            git
            jq
            python3
            shellcheck
            yq
          ];
        };
      });
}
