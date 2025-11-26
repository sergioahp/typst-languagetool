{
  description = "Spell and grammar checking of Typst documents with LanguageTool";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        typst-languagetool = pkgs.rustPlatform.buildRustPackage {
          pname = "typst-languagetool";
          version = "0.2.0";

          src = ./.;

          cargoLock = {
            lockFile = ./Cargo.lock;
          };

          # Build with jar backend feature for workspace members
          buildFeatures = [ "jar" ];
          cargoBuildFlags = [ "-p" "cli" "-p" "lsp" ];
          cargoTestFlags = [ "-p" "cli" "-p" "lsp" ];
          cargoInstallFlags = [ "-p" "cli" "-p" "lsp" ];

          nativeBuildInputs = with pkgs; [
            pkg-config
            jdk
            makeWrapper
          ];

          buildInputs = with pkgs; [
            openssl
          ];

          # Wrap binaries to use nixpkgs languagetool JAR
          postInstall = ''
            # CLI: automatically use jar backend with nixpkgs languagetool
            wrapProgram $out/bin/typst-languagetool \
              --set JAVA_HOME "${pkgs.jdk}" \
              --prefix LD_LIBRARY_PATH : "${pkgs.lib.makeLibraryPath [ pkgs.jdk ]}" \
              --add-flags "--jar-location ${pkgs.languagetool}/share/languagetool.jar"

            # LSP: provide JRE runtime (users configure backend in editor settings)
            wrapProgram $out/bin/typst-languagetool-lsp \
              --set JAVA_HOME "${pkgs.jdk}" \
              --prefix LD_LIBRARY_PATH : "${pkgs.lib.makeLibraryPath [ pkgs.jdk ]}"
          '';

          passthru = {
            inherit (pkgs) languagetool;
            languagetoolJar = "${pkgs.languagetool}/share/languagetool.jar";
          };

          meta = with pkgs.lib; {
            description = "Spell and grammar checking of Typst documents with LanguageTool";
            homepage = "https://github.com/jeertmans/typst-languagetool";
            license = licenses.mit;
            maintainers = [ ];
          };
        };
      in
      {
        packages = {
          default = typst-languagetool;
          cli = typst-languagetool;
        };

        apps = {
          default = flake-utils.lib.mkApp {
            drv = typst-languagetool;
            name = "typst-languagetool";
          };
          lsp = flake-utils.lib.mkApp {
            drv = typst-languagetool;
            name = "typst-languagetool-lsp";
          };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            rustc
            cargo
            jdk
            maven
            pkg-config
            openssl
          ];

          shellHook = ''
            echo "typst-languagetool dev environment"
            echo "Rust: $(rustc --version)"
            echo "Java: $(java -version 2>&1 | head -n1)"
            echo "Maven: $(mvn --version | head -n1)"
          '';
        };
      }
    );
}
