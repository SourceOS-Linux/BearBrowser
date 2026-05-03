{
  description = "BearBrowser SourceOS governed browser packaging";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        version = "0.1.0-overlay";

        mkBearBrowserPackage = { pname, profile, includeMountPlan ? false }:
          pkgs.stdenvNoCC.mkDerivation {
            inherit pname version;
            src = ./.;
            dontBuild = true;
            installPhase = ''
              mkdir -p $out/share/bearbrowser/profile
              mkdir -p $out/share/bearbrowser/policy
              mkdir -p $out/share/bearbrowser/manifests

              cp -R settings/profiles/${profile}/. $out/share/bearbrowser/profile/
              cp policy/bearbrowser-contract.yaml $out/share/bearbrowser/policy/
              cp manifests/upstream.json $out/share/bearbrowser/manifests/

              if [ "${if includeMountPlan then "1" else "0"}" = "1" ]; then
                mkdir -p $out/share/bearbrowser/mounts
                cp mounts/agent-browser-mounts.yaml $out/share/bearbrowser/mounts/
              fi
            '';
          };
      in
      {
        packages.bearbrowser-human-secure = mkBearBrowserPackage {
          pname = "bearbrowser-human-secure";
          profile = "human-secure";
        };

        packages.bearbrowser-agent-runtime = mkBearBrowserPackage {
          pname = "bearbrowser-agent-runtime";
          profile = "agent-runtime";
          includeMountPlan = true;
        };

        packages.default = self.packages.${system}.bearbrowser-human-secure;

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [ bash git jq nodejs python3 shellcheck yq ];
        };
      });
}
