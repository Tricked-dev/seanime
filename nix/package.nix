# Seanime Denshi - Electron-based desktop client for Seanime.
#
# Nix-specific runtime integration is wired through environment variables:
#   SEANIME_MPV_PATH                   host/store mpv executable for default mpv
#   SEANIME_DENSHI_RESOURCES_PATH      unpacked Denshi resource directory
#   SEANIME_DENSHI_SKIP_BINARY_CHMOD   skip chmod on immutable store binaries
#   SEANIME_DENSHI_WM_CLASS            X11 WM_CLASS for desktop icon matching
{
  stdenv,
  lib,
  buildNpmPackage,
  buildGoModule,
  electron,
  mpv,
  makeWrapper,
  copyDesktopItems,
  makeDesktopItem,
  ccache,
  source ? lib.cleanSource ../.,
}:

let
  version = "3.8.7";
  src = source;

  denshiArch =
    {
      x86_64 = "amd64";
      aarch64 = "arm64";
    }.${stdenv.hostPlatform.parsed.cpu.name} or stdenv.hostPlatform.parsed.cpu.name;

  serverBinaryName =
    if stdenv.hostPlatform.isDarwin then
      "seanime-server-darwin-${denshiArch}"
    else
      "seanime-server-linux-${denshiArch}";

  seanime-web = buildNpmPackage {
    pname = "seanime-web";
    inherit version src;

    sourceRoot = "source/seanime-web";
    npmDepsHash = "sha256-toqfrMi6bz4XWSF/EuPVpygnQMCGAAzgLoSnEpkKpl4=";
    npmBuildScript = "build";

    postBuild = ''
      npm run build:denshi
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/web $out/web-denshi
      cp -r out/* $out/web/
      cp -r out-denshi/* $out/web-denshi/
      runHook postInstall
    '';
  };

  seanime-server = buildGoModule {
    pname = "seanime-server";
    inherit version src;

    vendorHash = "sha256-cLUD6UvGQiOwuLlfScDPCvwmf3L66DIsBF/Gc1aWgrY=";
    nativeBuildInputs = lib.optional stdenv.isLinux ccache;

    preBuild = ''
      cp -r ${seanime-web}/web .
      cp -r ${seanime-web}/web-denshi seanime-denshi/
    '';

    ldflags = [ "-s" "-w" ];
    tags = [ "nosystray" ];
    subPackages = [ "." ];

    postInstall = ''
      mv $out/bin/seanime $out/bin/${serverBinaryName}
      chmod +x $out/bin/${serverBinaryName}
    '';
  };

  seanime-denshi-app = buildNpmPackage {
    pname = "seanime-denshi";
    inherit version src;

    sourceRoot = "source/seanime-denshi";
    npmDepsHash = "sha256-a4iDsJdcyl5fE/M/2XqtOLJPCJF/kB0jlTdMCbzbCD8=";
    ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
    dontNpmBuild = true;

    installPhase = ''
      runHook preInstall

      mkdir -p $out/lib/seanime-denshi
      cp -r src $out/lib/seanime-denshi/
      cp -r assets $out/lib/seanime-denshi/
      cp package.json $out/lib/seanime-denshi/
      cp -r node_modules $out/lib/seanime-denshi/

      rm -rf $out/lib/seanime-denshi/node_modules/electron/dist
      mkdir -p $out/lib/seanime-denshi/node_modules/electron/dist
      ln -s ${electron}/bin/electron $out/lib/seanime-denshi/node_modules/electron/dist/electron

      mkdir -p $out/lib/seanime-denshi/web-denshi
      cp -r ${seanime-web}/web-denshi/* $out/lib/seanime-denshi/web-denshi/
      ln -s ../web-denshi $out/lib/seanime-denshi/src/web-denshi

      mkdir -p $out/lib/seanime-denshi/binaries
      cp ${seanime-server}/bin/${serverBinaryName} $out/lib/seanime-denshi/binaries/
      chmod +x $out/lib/seanime-denshi/binaries/${serverBinaryName}

      runHook postInstall
    '';
  };
in
stdenv.mkDerivation {
  pname = "seanime-denshi";
  inherit version;

  dontUnpack = true;

  nativeBuildInputs =
    [ makeWrapper ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [ copyDesktopItems ];

  desktopItems = lib.optionals stdenv.hostPlatform.isLinux [
    (makeDesktopItem {
      name = "seanime-denshi";
      exec = "seanime-denshi";
      icon = "seanime";
      desktopName = "Seanime";
      comment = "Anime streaming and management application";
      categories = [ "AudioVideo" "Network" "Video" ];
      startupWMClass = "seanime-denshi";
      startupNotify = true;
    })
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/Applications $out/share/pixmaps
    cp ${src}/docs/images/seanime-logo.png $out/share/pixmaps/seanime.png

    ${lib.optionalString stdenv.hostPlatform.isDarwin ''
      appRoot="$out/Applications/Seanime.app"
      cp -R ${electron}/Applications/Electron.app "$appRoot"
      chmod -R u+w "$appRoot"
      mv "$appRoot/Contents/MacOS/Electron" "$appRoot/Contents/MacOS/Seanime"
      rm -f "$appRoot/Contents/Resources/default_app.asar"
      mkdir -p "$appRoot/Contents/Resources/app"
      mkdir -p "$appRoot/Contents/Resources/binaries"

      cp -R ${seanime-denshi-app}/lib/seanime-denshi/src "$appRoot/Contents/Resources/app/"
      cp -R ${seanime-denshi-app}/lib/seanime-denshi/assets "$appRoot/Contents/Resources/app/"
      cp ${seanime-denshi-app}/lib/seanime-denshi/package.json "$appRoot/Contents/Resources/app/"
      cp -R ${seanime-denshi-app}/lib/seanime-denshi/node_modules "$appRoot/Contents/Resources/app/"
      cp -R ${seanime-denshi-app}/lib/seanime-denshi/web-denshi "$appRoot/Contents/Resources/app/"
      cp ${seanime-server}/bin/${serverBinaryName} "$appRoot/Contents/Resources/binaries/"
      chmod +x "$appRoot/Contents/Resources/binaries/${serverBinaryName}"

      substituteInPlace "$appRoot/Contents/Info.plist" \
        --replace-fail '<string>Electron</string>' '<string>Seanime</string>' \
        --replace-fail '<string>com.github.Electron</string>' '<string>app.seanime.denshi</string>' \
        --replace-fail '<string>41.2.0</string>' '<string>${version}</string>' \
        --replace-fail '<string>electron.icns</string>' '<string>seanime.icns</string>'

      cp ${src}/seanime-denshi/assets/icon.icns "$appRoot/Contents/Resources/seanime.icns"
      cp ${src}/seanime-denshi/assets/icon.icns "$appRoot/Contents/Resources/electron.icns"
      cp $out/share/pixmaps/seanime.png "$appRoot/Contents/Resources/seanime.png"
    ''}

    ${lib.optionalString stdenv.hostPlatform.isLinux ''
      makeWrapper ${electron}/bin/electron $out/bin/seanime-denshi \
        --argv0 seanime-denshi \
        --add-flags ${seanime-denshi-app}/lib/seanime-denshi \
        --add-flags "--class=seanime-denshi" \
        --add-flags "--name=seanime-denshi" \
        --add-flags "--ozone-platform-hint=auto" \
        --add-flags "--enable-features=UseOzonePlatform,WaylandWindowDecorations" \
        --set NODE_ENV production \
        --set SEANIME_MPV_PATH ${mpv}/bin/mpv \
        --set SEANIME_DENSHI_RESOURCES_PATH ${seanime-denshi-app}/lib/seanime-denshi \
        --set SEANIME_DENSHI_SKIP_BINARY_CHMOD 1 \
        --set SEANIME_DENSHI_WM_CLASS seanime-denshi \
        --set BAMF_DESKTOP_FILE_HINT $out/share/applications/seanime-denshi.desktop \
        --chdir ${seanime-denshi-app}/lib/seanime-denshi
    ''}

    ${lib.optionalString stdenv.hostPlatform.isDarwin ''
      makeWrapper "$appRoot/Contents/MacOS/Seanime" $out/bin/seanime-denshi \
        --set NODE_ENV production
    ''}

    runHook postInstall
  '';

  passthru = {
    inherit seanime-web seanime-server seanime-denshi-app;
  };

  meta = {
    description = "Electron-based desktop client for Seanime";
    homepage = "https://github.com/5rahim/seanime";
    license = lib.licenses.mit;
    maintainers = [ ];
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
    mainProgram = "seanime-denshi";
  };
}
