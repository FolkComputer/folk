# flake.nix
{
  description = "A build environment for Folk OS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      # Use the x86_64-linux toolchains
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in
    {
      # This command creates the developer shell
      # Run it with `nix develop`
      devShells.x86_64-linux.default = pkgs.mkShell {
        # All your apt dependencies go here, provided by Nix!
        buildInputs = [
          pkgs.live-build
          pkgs.parted
          pkgs.dosfstools
          pkgs.zip
          pkgs.git
          pkgs.gnumake
          pkgs.gcc # For the C submodule
        ];
      };
    };
}
