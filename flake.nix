{
  description = "Norish - household-first recipe management application";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      nixosModule = import ./nix/module.nix self;
    in
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        norish = pkgs.stdenv.mkDerivation (finalAttrs: {
          pname = "norish";
          version = "0.17.3-beta";
          src = ./.;

          pnpmDeps = pkgs.fetchPnpmDeps {
            pnpm = pkgs.pnpm_10;
            inherit (finalAttrs) pname version src;
            fetcherVersion = 3;
            hash = "sha256-z6ssO0GFiwCKO8z/dLr6Ua6CmwBejOEpTUdM9ArcpUk=";
          };

          nativeBuildInputs = with pkgs; [
            nodejs_22
            pnpm_10
            pnpmConfigHook
            turbo
            python3
            pkg-config
          ];

          buildInputs = with pkgs; [
            vips
            postgresql.lib
          ];

          postPatch = ''
            # nixpkgs ships pnpm ${pkgs.pnpm_10.version} but package.json declares pnpm@10.30.1.
            # Patch the version so pnpm doesn't try to download 10.30.1 (no network in sandbox).
            # Turbo still needs the packageManager field to detect the workspace manager.
            sed -i 's|"packageManager": "pnpm@[^"]*"|"packageManager": "pnpm@${pkgs.pnpm_10.version}"|' package.json

            # next/font/google fetches fonts from Google at build time (network unavailable).
            # Patch fonts.ts to use next/font/local with the nixpkgs Inter and FiraCode fonts.
            # These are the same upstream fonts — functionally identical, and this means the
            # NixOS server also doesn't need outbound Google Fonts requests at runtime.
            mkdir -p apps/web/config/fonts
            cp ${pkgs.inter}/share/fonts/truetype/InterVariable.ttf \
               apps/web/config/fonts/InterVariable.ttf
            cp ${pkgs.fira-code}/share/fonts/truetype/FiraCode-VF.ttf \
               apps/web/config/fonts/FiraCode-VF.ttf
            cat > apps/web/config/fonts.ts <<'EOF'
import localFont from "next/font/local";

export const fontSans = localFont({
  src: "./fonts/InterVariable.ttf",
  variable: "--font-sans",
});

export const fontMono = localFont({
  src: "./fonts/FiraCode-VF.ttf",
  variable: "--font-mono",
});
EOF
          '';

          env = {
            SHARP_IGNORE_GLOBAL_LIBVIPS = "0";
            SKIP_ENV_VALIDATION = "1";
            TURBO_TELEMETRY_DISABLED = "1";
            NEXT_TELEMETRY_DISABLED = "1";
            NODE_ENV = "production";
            # ffmpeg-static@5.3.0 checks FFMPEG_BIN; if set to an existing binary
            # its install.js sees the binary is "already installed" and exits 0
            # (no network download needed). At runtime, getFfmpegPath() uses
            # `which ffmpeg` first, so the Nix store path here is only a fallback.
            # Use ffmpeg-headless to avoid pulling in 200+ MB of GUI libraries.
            FFMPEG_BIN = "${pkgs.ffmpeg-headless}/bin/ffmpeg";
          };

          # pnpm_10.configHook already ran pnpm install --ignore-scripts.
          # Rebuild sharp here so it compiles against system libvips.
          postConfigure = ''
            pnpm rebuild sharp
          '';

          buildPhase = ''
            runHook preBuild
            turbo run build --filter=@norish/web... --no-cache
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            local dest="$out/lib/norish"
            mkdir -p "$dest"

            # Deploy production node_modules (runs pnpm deploy --prod)
            pnpm --filter=@norish/web deploy --prod "$dest/deploy"
            mv "$dest/deploy/node_modules" "$dest/node_modules"
            rm -rf "$dest/deploy"

            # .next build output (Next.js standalone mode builds to standalone/apps/web/.next)
            # We use pnpm deploy for node_modules so only copy the .next directory itself.
            mkdir -p "$dest/apps/web"
            cp -r apps/web/.next "$dest/apps/web/.next"
            cp -r apps/web/public "$dest/apps/web/public"
            install -m644 apps/web/package.json "$dest/apps/web/package.json"
            install -m644 apps/web/next.config.js "$dest/apps/web/next.config.js"
            cp -r apps/web/config "$dest/apps/web/config"

            # Bundled custom server (all @norish/* packages compiled in)
            cp -r dist-server "$dest/dist-server"

            # Root package.json (read by next.config.js for the app version)
            install -m644 package.json "$dest/package.json"

            # packages/ directory contains runtime data files
            # (e.g. Drizzle migration SQL files, AI prompt templates).
            # Exclude node_modules/ inside each package — those contain symlinks
            # to tooling/ (eslint-config, tsconfig, etc.) which are dev-only and
            # not present in the output; keeping them would create broken symlinks.
            cp -r packages "$dest/packages"
            find "$dest/packages" -mindepth 2 -maxdepth 2 -type d -name "node_modules" \
              -exec rm -rf {} + 2>/dev/null || true

            # Static Next.js assets are not inside the standalone trace
            cp -r apps/web/.next/static "$dest/apps/web/.next/static"

            # Create writable directories that must exist at startup;
            # they will be bind-mounted / tmpfs at runtime on NixOS.
            mkdir -p "$dest/uploads"
            mkdir -p "$dest/bin"

            # Wrapper script — note unquoted heredoc so $out and Nix paths expand here;
            # \$@ is escaped so it becomes $@ in the installed script.
            mkdir -p "$out/bin"
            cat > "$out/bin/norish" <<WRAPPER
            #!/usr/bin/env bash
            exec ${pkgs.nodejs_22}/bin/node "$out/lib/norish/dist-server/index.mjs" "\$@"
            WRAPPER
            chmod +x "$out/bin/norish"

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Household-first recipe management with real-time sync";
            homepage = "https://github.com/norish-recipes/norish";
            license = licenses.mit;
            mainProgram = "norish";
            platforms = platforms.linux;
          };
        });
      in
      {
        packages.default = norish;
        packages.norish = norish;

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            nodejs_22
            pnpm_10
            turbo
            vips
            postgresql
          ];
        };
      }
    ) // {
      nixosModules.default = nixosModule;
      nixosModules.norish = nixosModule;
    };
}
