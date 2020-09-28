extractFileExt() {
  local name=`basename $1`
  echo ${name##*.}
}
extractHash() {
  local name=`basename $1`
  echo ${name%%-*}
}
makeExternCrateFlags() {
  local i=
  for (( i=1; i<$#; i+=2 )); do
    local extern_name="${@:$i:1}"
    local crate="${@:((i+1)):1}"
    [ -f "$crate/.cargo-info" ] || continue
    local crate_name=`jq -r '.name' $crate/.cargo-info`
    local proc_macro=`jq -r '.proc_macro' $crate/.cargo-info`
    if [ "$proc_macro" ]; then
      echo "--extern" "${extern_name}=$crate/lib/$proc_macro"
    elif [ -f "$crate/lib/lib${crate_name}.rlib" ]; then
      echo "--extern" "${extern_name}=$crate/lib/lib${crate_name}.rlib"
    elif [ -f "$crate/lib/lib${crate_name}.so" ]; then
      echo "--extern" "${extern_name}=$crate/lib/lib${crate_name}.so"
    elif [ -f "$crate/lib/lib${crate_name}.a" ]; then
      echo "--extern" "${extern_name}=$crate/lib/lib${crate_name}.a"
    elif [ -f "$crate/lib/lib${crate_name}.dylib" ]; then
      echo "--extern" "${extern_name}=$crate/lib/lib${crate_name}.dylib"
    else
      echo do not know how to find $extern_name \($crate_name\) >&2
      exit 1
    fi
    if [ -f "$crate/lib/.link-flags" ]; then
      cat $crate/lib/.link-flags
    fi
    echo "-L" "$crate/lib"
    if [ -d "$crate/lib/deps" ]; then
      echo "-L" "$crate/lib/deps"
    fi
  done
}
loadExternCrateLinkFlags() {
  local i=
  for (( i=1; i<$#; i+=2 )); do
    local extern_name="${@:$i:1}"
    local crate="${@:((i+1)):1}"
    [ -f "$crate/.cargo-info" ] || continue
    local crate_name=`jq -r '.name' $crate/.cargo-info`
    if [ -f "$crate/lib/.link-flags" ]; then
      cat $crate/lib/.link-flags
    fi
  done
}
loadDepKeys() {
  for (( i=2; i<=$#; i+=2 )); do
    local crate="${@:$i:1}"
    [ -f "$crate/.cargo-info" ] && [ -f "$crate/lib/.dep-keys" ] || continue
    cat $crate/lib/.dep-keys
  done
}
linkExternCrateToDeps() {
  local deps_dir=$1; shift
  for (( i=1; i<$#; i+=2 )); do
    local dep="${@:((i+1)):1}"
    [ -f "$dep/.cargo-info" ] || continue
    local crate_name=`jq -r '.name' $dep/.cargo-info`
    local metadata=`jq -r '.metadata' $dep/.cargo-info`
    local proc_macro=`jq -r '.proc_macro' $dep/.cargo-info`
    if [ "$proc_macro" ]; then
      local ext=`extractFileExt $proc_macro`
      ln -sf $dep/lib/$proc_macro $deps_dir/`basename $proc_macro .$ext`-$metadata.$ext
    else
      ln -sf $dep/lib/lib${crate_name}.rlib $deps_dir/lib${crate_name}-${metadata}.rlib
    fi
    if [ -d $dep/lib/deps ]; then
      ln -sf $dep/lib/deps/* $deps_dir
    fi
  done
}
upper() {
  echo ${1^^}
}
dumpDepInfo() {
  local link_flags="$1"; shift
  local dep_keys="$1"; shift
  local cargo_links="$1"; shift
  local dep_files="$1"; shift
  local depinfo="$1"; shift

  cat $depinfo | while read line; do
    [[ "x$line" =~ xcargo:([^=]+)=(.*) ]] || continue
    local key="${BASH_REMATCH[1]}"
    local val="${BASH_REMATCH[2]}"

    case $key in
      rustc-link-lib) ;&
      rustc-flags) ;&
      rustc-cfg) ;&
      rustc-env) ;&
      rerun-if-changed) ;&
      rerun-if-env-changed) ;&
      warning)
      ;;
      rustc-link-search)
        if [[ "$val" = *"$NIX_BUILD_TOP"* ]]; then
          if (( NIX_DEBUG >= 1 )); then
            echo >&2 "not propagating redundant linker arg '$val'"
          fi
        else
          echo "-L" `printf '%q' $val` >>$link_flags
        fi
        ;;
      *)
        if [ -e "$val" ]; then
          mkdir -p "$dep_files"
          local dep_file_target=$dep_files/DEP_$(upper $cargo_links)_$(upper $key)
          cp -r "$val" $dep_file_target
          val=$dep_file_target
        fi
        printf 'DEP_%s_%s=%s\n' $(upper $cargo_links) $(upper $key) "$val" >>$dep_keys
    esac
  done
}

install_crate() {
  local build_mode="$1"
  local cargo_links="$2"
  local needs_deps=
  local has_output=

  if (( NIX_DEBUG >= 1 )); then
    cp cargo-output.json $out
  fi

  # tl;dr: If we are building in test/bench mode, we only care about the test and bench binaries, so
  # skip all other build artifacts, even though these builds also produce binaries and libs.
  #
  # Otherwise, install all the libs + proc macro shared objects and add everything from the build
  # script output to the meta-files that other derivations check.
  if [ "$build_mode" = "test" -o "$build_mode" = "bench" ]; then
    for test_exe in $(jq -r "select(.reason == \"compiler-artifact\" and .target.kind[0] == \"$build_mode\") | .executable" cargo-output.json); do
      mkdir -p $out/bin
      cp "$test_exe" $out/bin
    done
  else
    for build_artifact in $(jq -r 'select(.reason == "compiler-artifact" and .target.kind[0] != "bin" and .target.kind[0] != "proc-macro" and .target.kind[0] != "custom-build") | .filenames[]' cargo-output.json); do
      if [[ "$build_artifact" == *.rmeta ]]; then
        mkdir -p $out/lib/meta
        cp "$build_artifact" $out/lib/meta
      else
        mkdir -p $out/lib
        cp -r "$build_artifact" $out/lib
      fi
      needs_deps=1
    done

    for bin_artifact in $(jq -r 'select(.reason == "compiler-artifact" and .target.kind[0] == "bin") | .executable' cargo-output.json); do
      mkdir -p $out/bin
      cp -r "$bin_artifact" $out/bin
    done

    if [ -n "$isProcMacro" ]; then
      for macro_lib in $(jq -r 'select(.reason == "compiler-artifact" and .target.kind[0] == "proc-macro") | .filenames[]' cargo-output.json); do
        mkdir -p $out/lib
        cp -r "$macro_lib" $out/lib
        needs_deps=1
        if [[ "$macro_lib" != *.dSYM ]]; then
          # D:
          isProcMacro="$(basename "$macro_lib")"
        fi
      done
    fi

    for build_script_output in $(jq -r 'select(.reason == "build-script-executed") | .out_dir' cargo-output.json); do
      output_file="$(dirname "$build_script_output")/output"
      if [ -e "$output_file" ]; then
        dumpDepInfo "$out/lib/.link-flags" "$out/lib/.dep-keys" "$cargo_links" "$out/lib/.dep-files" "$output_file"
      fi
    done

    if [ "$needs_deps" -a "${#dependencies[@]}" -ne 0 ]; then
      mkdir -p $out/lib/deps
      linkExternCrateToDeps $out/lib/deps $dependencies
    fi
  fi
  
  echo {} | jq \
'{name:$name, metadata:$metadata, version:$version, proc_macro:$procmacro}' \
--arg name $crateName \
--arg metadata $NIX_RUST_METADATA \
--arg procmacro "$isProcMacro" \
--arg version $version >$out/.cargo-info
}

cargoVerbosityLevel() {
  level=${1:-0}
  verbose_flag=""

  if (( level >= 1 )); then
  verbose_flag="-v"
  elif (( level >= 2 )); then
  verbose_flag="-vv"
  fi

  echo ${verbose_flag}
}
