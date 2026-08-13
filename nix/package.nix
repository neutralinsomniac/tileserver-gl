{
  lib,
  stdenv,
  buildNpmPackage,
  fetchurl,
  nodejs_22,
  python3,
  pkg-config,
  autoPatchelfHook,
  makeWrapper,
  # sharp (built from source)
  vips,
  # canvas (built from source)
  cairo,
  pango,
  glib,
  libpng,
  libjpeg_turbo,
  giflib,
  librsvg,
  pixman,
  # prebuilt @maplibre/maplibre-gl-native and sharp binaries
  libglvnd,
  icu74,
  libwebp,
  libuv,
  curl,
  zlib,
  libx11,
  libxext,
}:

let
  # the maplibre-native prebuilt binary links against libjpeg.so.8
  libjpeg8 = libjpeg_turbo.override { enableJpeg8 = true; };

  # mbgl.node refuses to run if the loaded libpng is not exactly the
  # 1.6.43 it was built against (Ubuntu 24.04). It gets a private copy
  # under a unique soname (see postFixup) so it can never collide with
  # the newer libpng that cairo and friends pull into the process.
  libpngMbgl = (libpng.override { apngSupport = false; }).overrideAttrs (old: {
    version = "1.6.43";
    src = fetchurl {
      url = "mirror://sourceforge/libpng/libpng-1.6.43.tar.xz";
      hash = "sha256-alygZSOSotfJ2yrltAIQhDwLvAgcvUEIJasAzFnxSmw=";
    };
  });

  nodejs = nodejs_22;
  # Node ABI version of the maplibre-native prebuilt binary below.
  # Must match `nodejs` above: node 20 = 115, node 22 = 127, node 24 = 137.
  nodeAbi = "127";

  packageJson = lib.importJSON ../package.json;
  mbglVersion = packageJson.dependencies."@maplibre/maplibre-gl-native";

  arch =
    {
      x86_64-linux = "x64";
      aarch64-linux = "arm64";
    }
    .${stdenv.hostPlatform.system}
      or (throw "tileserver-gl: unsupported system ${stdenv.hostPlatform.system}");

  # @maplibre/maplibre-gl-native normally downloads this in its install
  # script (node-pre-gyp), which cannot work in the sandbox. Building it
  # from source is a very large C++ build, so use the official prebuilt
  # binary and let autoPatchelfHook fix it up.
  mbglBinary = fetchurl {
    url = "https://github.com/maplibre/maplibre-native/releases/download/node-v${mbglVersion}/node-v${nodeAbi}-linux-${arch}-Release.tar.gz";
    hash =
      {
        x64 = "sha256-0EwN34k4eiCpz/k7V0Q851bTRSndg9xDS94QMbEo7lk=";
        arm64 = "sha256-gv31VRmHEZCPszYjFhSPOLE/HfBU+zgdTuhkwal2J2c=";
      }
      .${arch};
  };
in
(buildNpmPackage.override { inherit nodejs; }) {
  pname = "tileserver-gl";
  version = packageJson.version;

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../package.json
      ../package-lock.json
      ../src
      ../public
      ../CHANGELOG.md
      ../README.md
      ../LICENSE.md
    ];
  };

  npmDepsHash = "sha256-n8xaI09ArIOh5irdy28BVd0pYD88hjodB6P5V1rEZPc=";

  # Install scripts either download prebuilt binaries (impossible in the
  # sandbox) or need special setup; they are handled in buildPhase instead.
  npmFlags = [ "--ignore-scripts" ];

  nativeBuildInputs = [
    python3
    pkg-config
    autoPatchelfHook
    makeWrapper
  ];

  buildInputs = [
    cairo
    pango
    glib
    libpng
    libjpeg8
    giflib
    librsvg
    pixman
    vips
    libglvnd
    icu74
    libwebp
    libuv
    curl
    zlib
    libx11
    libxext
    (lib.getLib stdenv.cc.cc)
  ];

  env = {
    # let node-gyp find the Node headers instead of downloading them
    npm_config_nodedir = nodejs;
  };

  buildPhase = ''
    runHook preBuild

    mkdir -p node_modules/@maplibre/maplibre-gl-native/lib
    tar -xzf ${mbglBinary} -C node_modules/@maplibre/maplibre-gl-native/lib

    # canvas and sqlite3 build from their vendored sources
    export npm_config_build_from_source=true
    npm rebuild canvas sqlite3

    # sharp's patchelf'ed prebuilt libvips crashes on load; build it from
    # source against the nixpkgs vips instead and drop the prebuilts
    (cd node_modules/sharp && npm run build)
    rm -rf node_modules/@img/sharp-libvips-* node_modules/@img/sharp-linux-* node_modules/@img/sharp-wasm32

    # copy web viewer assets (maplibre-gl, leaflet, ...) into public/resources
    npm run prepare

    runHook postBuild
  '';

  # The bin entry npm generates relies on a /usr/bin/env node shebang;
  # replace it with a wrapper pinned to this package's node
  postInstall = ''
    rm $out/bin/tileserver-gl
    makeWrapper ${lib.getExe nodejs} $out/bin/tileserver-gl \
      --add-flags "$out/lib/node_modules/tileserver-gl/src/main.js"
  '';

  # Runs before autoPatchelfHook, which then resolves the new soname to
  # the copy placed next to mbgl.node.
  postFixup = ''
    mbglLib=$out/lib/node_modules/tileserver-gl/node_modules/@maplibre/maplibre-gl-native/lib/node-v${nodeAbi}
    install -m644 ${lib.getLib libpngMbgl}/lib/libpng16.so.16 "$mbglLib/libpng16-mbgl.so.16"
    patchelf --set-soname libpng16-mbgl.so.16 "$mbglLib/libpng16-mbgl.so.16"
    patchelf --replace-needed libpng16.so.16 libpng16-mbgl.so.16 "$mbglLib/mbgl.node"
  '';

  meta = {
    description = "Map tile server for JSON GL styles - vector and server side generated raster tiles";
    homepage = "https://github.com/maptiler/tileserver-gl";
    license = lib.licenses.bsd2;
    mainProgram = "tileserver-gl";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
