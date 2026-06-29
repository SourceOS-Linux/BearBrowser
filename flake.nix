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
              mkdir -p $out/share/applications
              mkdir -p $out/share/metainfo
              mkdir -p $out/share/icons/hicolor/scalable/apps

              cp -R settings/profiles/${profile}/. $out/share/bearbrowser/profile/
              cp policy/bearbrowser-contract.yaml $out/share/bearbrowser/policy/
              cp manifests/upstream.json $out/share/bearbrowser/manifests/
              cp packaging/linux/dev.sourceos.BearBrowser.desktop $out/share/applications/
              cp packaging/linux/dev.sourceos.BearBrowser.metainfo.xml $out/share/metainfo/
              cp branding/bearbrowser.svg $out/share/icons/hicolor/scalable/apps/dev.sourceos.BearBrowser.svg

              if [ "${if includeMountPlan then "1" else "0"}" = "1" ]; then
                mkdir -p $out/share/bearbrowser/mounts
                cp mounts/agent-browser-mounts.yaml $out/share/bearbrowser/mounts/
              fi
            '';
          };

        mkBinaryPlaceholder = { pname, profile }:
          pkgs.runCommand pname { } ''
            echo "BearBrowser ${profile} full binary build is not wired yet." >&2
            echo "Use: bearbrowser-build-binary --profile ${profile} --dry-run" >&2
            echo "Then implement Lane 13 full browser compile integration." >&2
            exit 64
          '';
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

        packages.bearbrowser-human-secure-binary = mkBinaryPlaceholder {
          pname = "bearbrowser-human-secure-binary";
          profile = "human-secure";
        };

        packages.bearbrowser-agent-runtime-binary = mkBinaryPlaceholder {
          pname = "bearbrowser-agent-runtime-binary";
          profile = "agent-runtime";
        };

        packages.default = self.packages.${system}.bearbrowser-human-secure;

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [ bash desktop-file-utils git jq libxml2 nodejs python3 shellcheck yq ];
        };
      });
}
