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
  touch search-index-tmp.js
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
    # XXX: This is going to break horribly if rustdoc ever changes its output format.
    # search-index.js is JS, not JSON. rustdoc generates a search-index.js for each
    # crate it creates docs for, but if such a file exists, it just loads the JSON part of it
    # (by filtering for lines starting with a double quote) and adds the newest crate index to it.
    # This is how `cargo doc` in a workspace generates a sidebar containing all the crates
    # in the entire workspace, even though a single rustdoc invocation can only ever consider
    # a single crate, and has no information about the contents of the workspace.
    grep '^"' $crate/share/doc/search-index.js >> search-index-tmp.js

    # For all dependencies we have that might appear in the generated documentation, the directory
    # containing *those* docs needs to already exist in the directory where the new docs are placed,
    # otherwise rustdoc will not generate links to the appropriate items.
    ln -sfv $crate/share/doc/$extern_name $target_dir/doc

    while IFS= read -r -d $'\0' file; do
      if [ "$(basename "$file")" != "$crateName" ]; then
        ln -TLsfv "$file" "$target_dir/doc/$(basename "$file")"
      fi
    done < <(find $crate/share/doc -maxdepth 1 -type l -print0)
  done
  # The crate name is the first string on each line, so we don't need to compare (`-w 40`)
  # further than that. rustdoc itself does *not* remove duplicate entries from the generated index,
  # so if it's not done manually here, the resulting index can be up to around 40MB in size
  # depending on the number of crates in the dependency graph.
  sort search-index-tmp.js | uniq -w 40 > $target_dir/doc/search-index.js
  rm search-index-tmp.js
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

  # Copy all bin artifacts to $out/bin. In test mode, we also copy test and bench binaries there, which are identified by having
  # "profile":{"test":true} in the cargo output. We add the latter to the file `$out/lib/.test-bins`.
  for bin_artifact in $(jq -r 'select(.target.kind[0] == "bin" and (.profile.test | not)) | .executable' cargo-output.json); do
    mkdir -p $out/bin
    cp -r "$bin_artifact" $out/bin
  done

  if [ "$build_mode" = "test" -o "$build_mode" = "bench" ]; then
    for test_exe in $(jq -r "select(.profile.test) | .executable" cargo-output.json); do
      mkdir -p $out/bin
      cp "$test_exe" $out/bin
      echo "$out/bin/$(basename "$test_exe")" >> $out/lib/.test-bins
    done
  else
    # Everything else is a regular rmeta file, rust library, or platform-native object.
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

  if [ -n "$doDoc" ]; then
    install_docs $CARGO_BUILD_TARGET doc-target
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
