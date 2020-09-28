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
linkRustdocs() {
  local target_dir=$1
  shift
  local i=
  for (( i=1; i<$#; i+=2 )); do
    local extern_name="${@:$i:1}"
    local crate="${@:((i+1)):1}"
    [ -f "$crate/.cargo-info" ] || continue
    # Dependency xyz matches self, meaning it is an older or newer version of this crate.
    # We have no way to handle this case (cargo doesn't either).
    # See https://github.com/rust-lang/cargo/issues/6313
    if [ "$extern_name" = "$crateName" ]; then
      continue
    fi
    ln -sv $crate/share/doc/$extern_name $target_dir/doc
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
          local dep_file_target=$dep_files/DEP_$(upper $cargo_links)_$(upper $key)
          cp -r "$val" $dep_file_target
          val=$dep_file_target
        fi
        printf 'DEP_%s_%s=%s\n' $(upper $cargo_links) $(upper $key) "$val" >>$dep_keys
    esac
  done
}

install_crate() {
  local host_triple=$1
  local needs_deps=
  local has_output=

  pushd target/${host_triple}/${buildMode}
  for output in *; do
    if [ -d "$output" ]; then
      continue
    elif [ -x "$output" ]; then
      mkdir -p $out/bin
      cp $output $out/bin/
      has_output=1
    else
      case `extractFileExt "$output"` in
        rlib)
          mkdir -p $out/lib/.dep-files
          cp $output $out/lib/
          local link_flags=$out/lib/.link-flags
          local dep_keys=$out/lib/.dep-keys
          touch $link_flags $dep_keys
          for depinfo in build/*/output; do
            dumpDepInfo $link_flags $dep_keys "$cargo_links" $out/lib/.dep-files $depinfo
          done
          needs_deps=1
          has_output=1
          ;;
        a) ;&
        so) ;&
        dylib)
          mkdir -p $out/lib
          cp $output $out/lib/
          has_output=1
          ;;
        *)
          continue
      esac
    fi
  done
  popd

  if [ "$isProcMacro" ]; then
    pushd target/${buildMode}
    for output in *; do
      if [ -d "$output" ]; then
        continue
      fi
      case `extractFileExt "$output"` in
        so) ;&
        dylib)
          isProcMacro=`basename $output`
          mkdir -p $out/lib
          cp $output $out/lib
          needs_deps=1
          has_output=1
          ;;
        *)
          continue
      esac
    done
    popd
  fi

  if [ "$needs_deps" -a "${#dependencies[@]}" -ne 0 ]; then
    mkdir -p $out/lib/deps
    linkExternCrateToDeps $out/lib/deps $dependencies
  fi

  if [ -n "$needDevDependencies" ]; then
    for file in target/${host_triple}/${buildMode}/deps/*; do
      if grep -q __RUST_TEST_INVOKE "$file"; then
        mkdir -p $out/bin
        cp "$file" $out/bin
        has_output=1
      fi
    done
  fi

  if [ -z "$has_output" ]; then
      echo >&2 "no output found for crate"
      exit 1
  fi

  if [ -n "$doDoc" ]; then
    install_docs $host_triple doc-target
  fi
  
  echo {} | jq \
'{name:$name, metadata:$metadata, version:$version, proc_macro:$procmacro}' \
--arg name $crateName \
--arg metadata $NIX_RUST_METADATA \
--arg procmacro "$isProcMacro" \
--arg version $version >$out/.cargo-info
}

install_docs() {
  local host_triple=$1
  local target_dir=$2
  if [ -d $target_dir/$host_triple/doc ]; then
    mkdir -p $out/share
    cp -R $target_dir/$host_triple/doc $out/share
  # documentation for proc macro crates is not placed in a $target directory
  elif [ -d $target_dir/doc ]; then
    mkdir -p $out/share
    cp -R $target_dir/doc $out/share
  fi
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
