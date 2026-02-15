{
  description = "OpenCode Sandbox - Sandboxed OpenCode environment using bubblewrap";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        opencode-sandbox = pkgs.callPackage ./default.nix { };
      in
      {
        packages = {
          default = opencode-sandbox;
          opencode-sandbox = opencode-sandbox;
        };

        apps = {
          default = {
            type = "app";
            program = "${opencode-sandbox}/bin/opencode-sandbox";
          };
          opencode-sandbox = {
            type = "app";
            program = "${opencode-sandbox}/bin/opencode-sandbox";
          };
          update-opencode = {
            type = "app";
            program = "${pkgs.writeShellScript "update-opencode" ''
              export PATH=${pkgs.lib.makeBinPath [ pkgs.curl pkgs.jq pkgs.nix pkgs.gnused ]}:$PATH
              exec ${./update-opencode.sh}
            ''}";
          };
        };

        checks = pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          sandbox-test = import ./tests/sandbox.nix { inherit pkgs; opencode-sandbox = opencode-sandbox; };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            opencode-sandbox
          ];

          shellHook = ''
            echo "OpenCode Sandbox Development Environment"
          '';
        };
      });
}
