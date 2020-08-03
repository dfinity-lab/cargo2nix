{
  cargo,
  rustc,

  lib,
  pkgs,
  buildPackages,
  rustLib,
  stdenv,
}:
{
  release, # Compiling in release mode?
  name,
  version,
  registry,
  src,
  features ? [ ],
  dependencies ? { },
  devDependencies ? { },
  buildDependencies ? { },
  compileMode ? "build",
  profile,
  meta ? { },
  rustcflags ? [ ],
  rustcBuildFlags ? [ ],
  hostPlatformCpu ? null,
  hostPlatformFeatures ? [],
  NIX_DEBUG ? 0,
}:
with builtins; with lib;
let
  inherit (rustLib) realHostTriple decideProfile;

  wrapper = exename: rustLib.wrapRustc { inherit rustc exename; };

  ccForBuild="${buildPackages.stdenv.cc}/bin/${buildPackages.stdenv.cc.targetPrefix}cc";
  cxxForBuild="${buildPackages.stdenv.cc}/bin/${buildPackages.stdenv.cc.targetPrefix}c++";
  targetPrefix = stdenv.cc.targetPrefix;
  cc = stdenv.cc;
  ccForHost="${cc}/bin/${targetPrefix}cc";
  cxxForHost="${cc}/bin/${targetPrefix}c++";
  host-triple = realHostTriple stdenv.hostPlatform;
  depMapToList = deps:
    flatten
      (sort (a: b: elemAt a 0 < elemAt b 0)
        (mapAttrsToList (name: value: [ name "${value}" ]) deps));
  buildCmd =
    let
      hasDefaultFeature = elem "default" features;
      featuresWithoutDefault = if hasDefaultFeature
        then filter (feature: feature != "default") features
        else features;
      buildMode = {
        "test" = "--tests";
        "bench" = "--benches";
      }.${compileMode} or "";
      featuresArg = if featuresWithoutDefault == [ ]
        then ""
        else "--features ${concatStringsSep "," featuresWithoutDefault}";
    in
      ''
        cargo build $CARGO_VERBOSE ${optionalString release "--release"} ${buildMode} \
          ${featuresArg} ${optionalString (!hasDefaultFeature) "--no-default-features"}
      '';
  needDevDependencies = compileMode == "test" || compileMode == "bench";
  preserveBench = if registry == "unknown"
    then ".bench"
    else "null";

  inherit
    (({ right, wrong }: { runtimeDependencies = right; buildtimeDependencies = wrong; })
      (partition (drv: drv.stdenv.hostPlatform == stdenv.hostPlatform)
        (concatLists [
          (attrValues dependencies)
          (optionals needDevDependencies (attrValues devDependencies))
          (attrValues buildDependencies)
        ])))
    runtimeDependencies buildtimeDependencies;

  dependencyGraph = crate: builtins.listToAttrs (builtins.genericClosure {
    startSet = makeKvs crate;
    operator = crate: makeKvs crate.value;
  });

  makeKvs = parent: map (crate: rec {
    key = "${crate.name}-${crate.version}";
    name = key;
    value = crate;
  }) (builtins.attrValues (parent.dependencies // parent.devDependencies));

  maybeSelfLib = (dependencyGraph { inherit dependencies devDependencies; })."${name}-${version}" or null;

  drvAttrs = {
    inherit NIX_DEBUG;
    name = "crate-${name}-${version}${optionalString (compileMode != "build") "-${compileMode}"}";
    inherit src version meta needDevDependencies;
    buildMode = if release then "release" else "debug";
    propagatedBuildInputs = lib.unique (concatMap (drv: drv.propagatedBuildInputs) runtimeDependencies);
    nativeBuildInputs = [ cargo ] ++ buildtimeDependencies;

    RUSTC = "${wrapper "rustc"}/bin/rustc";
    RUSTDOC = "${wrapper "rustdoc"}/bin/rustdoc";

    # allows easier overriding of the cargo invocation (to run clippy and so on)
    CARGO_BUILD_TARGET = host-triple;

    depsBuildBuild =
      let inherit (buildPackages.buildPackages) stdenv jq remarshal;
      in [ stdenv.cc jq remarshal ];

    # Running the default `strip -S` command on Darwin corrupts the
    # .rlib files in "lib/".
    #
    # See https://github.com/NixOS/nixpkgs/pull/34227
    stripDebugList = if stdenv.isDarwin then [ "bin" ] else null;

    passthru = {
      inherit
        name
        version
        registry
        dependencies
        devDependencies
        buildDependencies
        features;
      shell = pkgs.mkShell (removeAttrs drvAttrs ["src"]);
    };

    dependencies = depMapToList dependencies;
    buildDependencies = depMapToList buildDependencies;
    devDependencies = depMapToList (optionalAttrs needDevDependencies devDependencies);

    selfLib = if !needDevDependencies || maybeSelfLib == null
      then null
      else "${maybeSelfLib}/lib";

    extraRustcFlags =
      optionals (hostPlatformCpu != null) ([("-Ctarget-cpu=" + hostPlatformCpu)]) ++
      optionals (hostPlatformFeatures != []) [("-Ctarget-feature=" + (concatMapStringsSep "," (feature: "+" + feature) hostPlatformFeatures))] ++
      rustcflags;

    extraRustcBuildFlags = rustcBuildFlags;

    # HACK: 2019-08-01: wasm32-wasi always uses `wasm-ld`
    configureCargo = ''
      mkdir -p .cargo
      cat > .cargo/config <<'EOF'
      [target."${realHostTriple stdenv.buildPlatform}"]
      linker = "${ccForBuild}"
    '' + optionalString (stdenv.buildPlatform != stdenv.hostPlatform && !(stdenv.hostPlatform.isWasi or false)) ''
      [target."${host-triple}"]
      linker = "${ccForHost}"
    '' + ''
      EOF
    '';

    manifestPatch = toJSON {
      features = genAttrs features (_: [ ]);
      profile.${ decideProfile compileMode release } = profile;
    };

    overrideCargoManifest = ''
      echo [[package]] > Cargo.lock
      echo name = \"${name}\" >> Cargo.lock
      echo version = \"${version}\" >> Cargo.lock
      echo source = \"registry+${registry}\" >> Cargo.lock
      mv Cargo.toml Cargo.original.toml
      remarshal -if toml -of json Cargo.original.toml \
        | jq "{ package: .package
              , lib: .lib
              , bin: .bin
              , test: .test
              , example: .example
              , bench: ${preserveBench}
              } + $manifestPatch" \
        | remarshal -if json -of toml > Cargo.toml
    '';

    configurePhase =
      ''
        runHook preConfigure
        runHook configureCargo
        runHook postConfigure
      '';

    runCargo = ''
      (
        set -euo pipefail
        if (( NIX_DEBUG >= 1 )); then
          set -x
        fi
        env \
          "CC_${stdenv.buildPlatform.config}"="${ccForBuild}" \
          "CXX_${stdenv.buildPlatform.config}"="${cxxForBuild}" \
          "CC_${host-triple}"="${ccForHost}" \
          "CXX_${host-triple}"="${cxxForHost}" \
          "''${depKeys[@]}" \
          ${buildCmd}
      )
    '';

    setBuildEnv = ''
      isProcMacro="$( \
        remarshal -if toml -of json Cargo.original.toml \
        | jq -r 'if .lib."proc-macro" or .lib."proc_macro" then "1" else "" end' \
      )"
      crateName="$(
        remarshal -if toml -of json Cargo.original.toml \
        | jq -r 'if .lib."name" then .lib."name" else "${replaceChars ["-"] ["_"] name}" end' \
      )"
      . ${./utils.sh}
      export CARGO_VERBOSE=`cargoVerbosityLevel $NIX_DEBUG`
      export NIX_RUST_METADATA=`extractHash $out`
      export CARGO_HOME=`pwd`/.cargo
      linkFlags=(`makeExternCrateFlags $dependencies $devDependencies`)
      buildLinkFlags=(`makeExternCrateFlags $buildDependencies`)

      export NIX_RUST_LINK_FLAGS="''${linkFlags[@]} $extraRustcFlags"
      export NIX_RUST_BUILD_LINK_FLAGS="''${buildLinkFlags[@]} $extraRustcBuildFlags"
      export crateName selfLib NIX_RUSTC_LINKER_HACK NIX_RUSTC_LINKER_HACK_ARGS

      depKeys=(`loadDepKeys $dependencies`)

      if (( NIX_DEBUG >= 1 )); then
        echo $NIX_RUST_LINK_FLAGS
        echo $NIX_RUST_BUILD_LINK_FLAGS
        for key in ''${depKeys[@]}; do
          echo $key
        done
      fi
    '';

    buildPhase = ''
      runHook preBuild
      runHook overrideCargoManifest
      runHook setBuildEnv
      runHook runCargo
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib
      cargo_links="$(remarshal -if toml -of json Cargo.original.toml | jq -r '.package.links | select(. != null)')"
      install_crate ${host-triple}
      runHook postInstall
    '';
  };
in
  stdenv.mkDerivation drvAttrs
