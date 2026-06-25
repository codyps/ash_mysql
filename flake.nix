{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          pkgs = ((import nixpkgs) {
            inherit system;
          });

          beamPackages = pkgs.beam28Packages;

          commonPackages = with pkgs; [
            sqlcmd
          ] ++ (with beamPackages; [
            elixir_1_19
            erlang
            hex
          ]);
        in
        {
          devShells.default = pkgs.mkShell {
            packages = commonPackages ++ (with pkgs; [
            ]);
          };

          formatter = pkgs.nixpkgs-fmt;
        }
      );
}
