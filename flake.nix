{
  description = "Basic Haskell Project Flake";
  inputs = {
    haskellProjectFlake.url = "github:mstksg/haskell-project-flake";
    nixpkgs.follows = "haskellProjectFlake/nixpkgs";
  };
  outputs =
    { self
    , nixpkgs
    , flake-utils
    , haskellProjectFlake
    }:
    flake-utils.lib.eachDefaultSystem (system:
    let
      name = "santabot";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ haskellProjectFlake.overlays."${system}".default ];
      };
      project-flake = pkgs.haskell-project-flake
        {
          inherit name;
          src = ./.;
          excludeCompilerMajors = [ "ghc810" "ghc90" "ghc92" "ghc94" "ghc96" "ghc910" ];
          defaultCompiler = "ghc982";
        };
    in
    {
      packages = project-flake.packages
        //
        {
          dhall = pkgs.dhallPackages.buildDhallDirectoryPackage {
            name = "santabot-dhall";
            src = ./dhall;
            source = true;
          };
        }
      ;
      apps = project-flake.apps;
      checks = project-flake.checks;
      devShells = project-flake.devShells;
      legacyPackages = pkgs;
    }
    );
}

