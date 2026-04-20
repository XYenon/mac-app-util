# Copyright © 2023–2025  Hraban Luyat
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, version 3 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-compat = {
      # Use my own fixed-output-derivation branch because I don’t want users to
      # need to eval-time download dependencies.
      url = "github:hraban/flake-compat/fixed-output";
      flake = false;
    };
    systems.url = "github:nix-systems/default-darwin";
    flake-utils = {
      url = "flake-utils";
      inputs.systems.follows = "systems";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      treefmt-nix,
      ...
    }:
    {
      homeManagerModules.default =
        {
          pkgs,
          lib,
          config,
          ...
        }:
        {
          options = with lib; {
            targets.darwin.mac-app-util.enable = mkOption {
              type = types.bool;
              default = builtins.hasAttr pkgs.stdenv.system self.packages;
              example = true;
              description = "Whether to enable mac-app-util home manager integration";
            };
          };
          config = lib.mkIf config.targets.darwin.mac-app-util.enable {
            home.activation = {
              trampolineApps =
                let
                  mac-app-util = self.packages.${pkgs.stdenv.system}.default;
                in
                lib.hm.dag.entryAfter [ "writeBoundary" ] ''
                  fromDir="$HOME/Applications/Home Manager Apps"
                  toDir="$HOME/Applications/Home Manager Trampolines"
                  ${mac-app-util}/bin/mac-app-util sync-trampolines "$fromDir" "$toDir"
                '';
            };
          };
        };
      darwinModules.default =
        {
          config,
          pkgs,
          lib,
          ...
        }:
        {
          options = {
            # Technically this isn’t a “service” but this seems like the most
            # polite place to put this?
            services.mac-app-util.enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              example = false;
            };
          };
          config = lib.mkIf config.services.mac-app-util.enable {
            system.activationScripts.postActivation.text =
              let
                mac-app-util = self.packages.${pkgs.stdenv.system}.default;
              in
              ''
                ${mac-app-util}/bin/mac-app-util sync-trampolines "/Applications/Nix Apps" "/Applications/Nix Trampolines"
              '';
          };
        };
    }
    // (
      with flake-utils.lib;
      eachDefaultSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          treefmt =
            { ... }:
            {
              projectRootFile = "flake.nix";
              programs = {
                nixfmt = {
                  enable = true;
                  strict = true;
                };
                shellcheck.enable = true;
                shfmt = {
                  enable = true;
                  indent_size = 0;
                };
              };
              settings.formatter.shellcheck.excludes = [ ".envrc" ];
            };
          treefmtPkg = treefmt-nix.lib.evalModule pkgs treefmt;
        in
        {
          checks = {
            default = self.packages.${system}.default;
            treefmt = treefmtPkg.config.build.check self;
          };
          packages = {
            default = pkgs.callPackage (
              {
                dockutil,
                findutils,
                jq,
                rsync,
              }:
              pkgs.stdenvNoCC.mkDerivation {
                pname = "mac-app-util";
                version = "0.0.0";
                src = ./main.sh;
                dontUnpack = true;
                nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
                installPhase = ''
                  install -Dm755 "$src" "$out/bin/mac-app-util"
                  wrapProgramBinary "$out/bin/mac-app-util" \
                    --suffix PATH : "${
                      pkgs.lib.makeBinPath [
                        dockutil
                        rsync
                        findutils
                        jq
                      ]
                    }"
                '';
                installCheckPhase = ''
                  $out/bin/mac-app-util --help
                '';
                doInstallCheck = true;
                meta.license = pkgs.lib.licenses.agpl3Only;
              }
            ) { };
          };
          formatter = treefmtPkg.config.build.wrapper;
        }
      )
    );
}
