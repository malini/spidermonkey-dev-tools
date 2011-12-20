#!/bin/sh

arch_sel=
bld_sel=
cc_sel=
phase_sel=
aphase_sel=
kontinue=false
arg=$1; shift;
oldarg=
while test "$arg" != "$oldarg"; do
    case ${arg%%-*} in
        (x86|x64|arm) arch_sel="$arch_sel ${arg%%-*}";;
        (dbg|opt) bld_sel="$bld_sel ${arg%%-*}";;
        (gcc*) cc_sel="$cc_sel ${arg%%-*}";;
        (cfg|make|chk|run|runi|chki|chkt|regen) phase_sel="$phase_sel ${arg%%-*}";;
        (patch) aphase_sel="$aphase_sel ${arg%%-*}";;
        (k) kontinue=true;;
        (*) echo 1>&2 "Unknown variation flag '$arg'.";
        exit 1;;
    esac
    oldarg=$arg
    arg=${arg#*-}
done

test -z "$arch_sel" && arch_sel="x64 x86"
test -z "$bld_sel" && bld_sel="dbg opt"
test -z "$cc_sel" && cc_sel="gcc45"
test -z "$phase_sel" && phase_sel="make"
phase_sel="$phase_sel $aphase_sel"

top_file(){
  local filename=$1
  local p=$2
  while test ! -r "$p/$filename"; do
    if test -z "$p"; then
      break;
    else
      p=${p%/*}
    fi
  done
  if test -r "$p/$filename"; then
    echo "$p/$filename"
  fi
}

export_front(){
    local env=$1
    echo "export $2=$3:\$$2" >> $env
}

export_last(){
    local env=$1
    echo "export $2=\$$2:$3" >> $env
}

export_list(){
  local cmd=$1
  local env=$2
  while read i; do
    case $i in
      *bin)    $cmd $env PATH $i;;
      */games) $cmd $env PATH $i;;
      */man)   $cmd $env MANPATH $i;;
      */include)
               $cmd $env INCLUDE $i;;
      */lib)
               $cmd $env LIBRARY_PATH $i;
               #$cmd $env LD_LIBRARY_PATH $i;
               #$cmd $env LD_RUN_PATH $i;
               ;;
      */aclocal*)
               $cmd $env ACLOCAL_PATH $i;;
      */pkgconfig)
               $cmd $env PKG_CONFIG_PATH $i;;
      */site_perl/*)
               $cmd $env PERLLIB $i;;
      */python*/site-packages)
               $cmd $env PYTHONPATH $i;;
      *) true;;
    esac
  done
}

# Used to unescape the '~' symbol and environment variables.
fulldir(){
  eval echo "$1"
}

regen_env(){
  local env=$1
  echo "Generate the new $env file, please wait ..."
  echo "#!/bin/sh" > $env
  echo "# This file has been generated by the 'set_env.sh' script." >> $env
  echo "# $(date)" >> $env

  local exp
  while read l; do # var:pos:dir@place
    local var=$(echo $l | sed 's,\(.*\):\(.\):\(.*\)@\(.*\),\1,')
    local pos=$(echo $l | sed 's,\(.*\):\(.\):\(.*\)@\(.*\),\2,')
    local dir=$(echo $l | sed 's,\(.*\):\(.\):\(.*\)@\(.*\),\3,')
    local loc=$(echo $l | sed 's,\(.*\):\(.\):\(.*\)@\(.*\),\4,')
    if test -z "$loc" -o "$WHEREAMI" = "$loc"; then
      case $pos in
        \^) exp="export_front";;
        \$) exp="export_last";;
         *) echo >&2 "unknow position character $exp, expected ^ or $.";
            exp="export_last";;
      esac
      dir=$(fulldir "$dir")
      echo "Generate $env: Visit '$dir'."
      if test -r "$dir"; then
        if test -n "$var"; then
          $exp $env $var "$dir"
        else
          find -L "$dir" -type d | export_list $exp $env
        fi
      fi
    fi
  done

  echo "Generation complete."
}

clean_env() {
  while read v; do
    export $v="";
  done <<EOF
PATH
MANPATH
INCLUDE
ACLOCAL_PATH
PKG_CONFIG_PATH
PERLLIB
PYTHONPATH
EOF
  unset LIBRARY_PATH
  unset LD_LIBRARY_PATH
  unset LD_RUN_PATH
}

regen_local_env() {
  local profile=$(top_file ".nix-profile" $1)
  regen_env "$(dirname $profile)/.env" <<EOF
PATH:$:/sbin@
:^:/var/run/current-system/sw@
PATH:^:/var/setuid-wrappers@
:^:$profile@
:^:~/.usr@
EOF
}

load_local_env() {
  local profile=$(top_file ".nix-profile" $1)
  local dir="${profile%/*}" # dirname
  local has_preinit=$(test -r "$dir/.preinit" && echo true || echo false)
  local has_init=$(test -r "$dir/.init" && echo true || echo false)

  clean_env
  export PROFILE_DIR=$dir
  if $has_preinit; then
    source "$dir/.preinit"
  fi
  source "$dir/.env"
  if $has_init; then
    source "$dir/.init"
  fi
}

failed=false

catch_failure() {
    reset='\e[0;0m'
    highlight='\e[0;31m'
    echo -e 1>&2 "error: ${highlight}Failed while building variant: $arch-$bld ($phase)${reset}"
    failed=true
    $kontinue || exit 1
}

run() {
    reset='\e[0;0m'
    highlight='\e[0;35m'
    echo -e 1>&2 "exec: ${highlight}$@${reset}"
    "$@"
    test $? -gt 0 && catch_failure
}

generate_patch() {
    if git st | grep -c '\(.M\|M.\)'; then
        echo 2>&1 "Please commit the changes and re-test."
        exit 1
    else
        tg patch -r ~/mozilla
    fi
}


gen_builddir() {
    if test \! -e "$builddir/../config.site"; then
        mkdir -p "$builddir"
        cd "$builddir/.."
        ln -s /nix/var/nix/profiles/per-user/nicolas/mozilla/profile-$cc-$arch .nix-profile
        regen_local_env $(pwd -L)
        cp $(top_file ".init" $buildtmpl) .
        cp $(top_file ".preinit" $buildtmpl) .
        cp $(top_file "config.site" $buildtmpl) .
        cd -
    fi
}

get_srcdir() {
    local source=$(top_file "configure.in" $(pwd -L))
    source=$(dirname "$source")
    echo $source
}

get_js_srcdir() {
    local source=$(get_srcdir)
    source=${source%/js/src}
    echo ${source}/js/src
}

# TODO use trap here !

for p in $phase_sel; do
    if test $p = regen; then
        PROFILE_NIX=/home/nicolas/mozilla/profile.nix
        nix-store -r $( nix-instantiate --show-trace $PROFILE_NIX) | \
            tee /dev/stderr | \
            tail -n $(nix-instantiate $PROFILE_NIX 2>/dev/null | wc -l) | \
            while read drv; do

            sum=$(echo $drv | sed 's,.*-profile-\([^-]*\)-\([^-]*\),\1:\2,')
            cc=${sum%:*}
            arch=${sum#*:}
            ln -sfT $drv /nix/var/nix/profiles/per-user/nicolas/mozilla/profile-$cc-$arch
        done
        exit 0
    fi
done

srcdir=$(get_js_srcdir)

arch_max=$(echo $arch_sel | wc -w)
arch_cnt=1
for arch in $arch_sel; do

bld_max=$(echo $bld_sel | wc -w)
bld_cnt=1
for bld in $bld_sel; do

cc_max=$(echo $cc_sel | wc -w)
cc_cnt=1
for cc in $cc_sel; do

    builddir=$srcdir/_build/$arch/$cc/$bld
    buildtmpl=$HOME/mozilla/_build_tmpl/$arch/$cc/$bld
    oldarch=$arch
    test $arch = arm && arch=x64
    gen_builddir

    clean_env
    load_local_env "$builddir"
    arch=$oldarch

    test -e "$builddir" || mkdir -p "$builddir"
    phase_sel_case="$phase_sel"

    if test "$(md5sum "$srcdir/configure.in")" != "$(cat "$builddir/config.sum")"; then
        phase_sel_case="autoconf cfg $phase_sel_case"
    elif test \! -e "$builddir/Makefile" -a "${phase_sel_case%make*}" == "${phase_sel_case#*make}"; then
        phase_sel_case="cfg $phase_sel_case"
    fi

for phase in $phase_sel_case; do

    case $phase in
        (autoconf)
            # does that once for all builds.
            cd $srcdir;
            run autoconf
            cd -
            cd $builddir;
            md5sum "$srcdir/configure.in" > config.sum
            cd -
            ;;
        (cfg)
            conf_args=
            case $bld in
                (dbg) conf_args="$conf_args --enable-debug --disable-optimize";;
            esac
            case $arch in
                (x86) conf_args="$conf_args i686-unknown-linux-gnu";;
                (arm) conf_args="$conf_args armv7l-unknown-linux-gnueabi"
                continue;;
            esac

            phase="configure"
            cd $builddir;
            run "$srcdir/configure" $conf_args
            cd -
            ;;

        (make)
            case $arch in
                (arm)
                    case $bld in
                        (dbg)
                            run nix-build -I /home/nicolas/mozilla /home/nicolas/mozilla/sync-repos/release.nix -A jsBuild -o "$builddir/result"
                            ;;
                        (opt)
                            run nix-build -I /home/nicolas/mozilla /home/nicolas/mozilla/sync-repos/release.nix -A jsOptBuild -o "$builddir/result"
                            ;;
                    esac
                    ln -sf "$builddir/result/bin/js" "$builddir/js"
                    ;;
                (*)
                    LC_ALL=C run make -C $srcdir/_build/$arch/$cc/$bld "$@"
                    ;;
            esac
            ;;

        (chk)
            LC_ALL=C run make -C $srcdir/_build/$arch/$cc/$bld check "$@"
            ;;

        (chki)
            # check ion test directory.
            #LC_ALL=C run make -C $srcdir/_build/$arch/$cc/$bld check-ion-test "$@"
            run python $srcdir/jit-test/jit_test.py --ion-tbpl --no-slow $srcdir/_build/$arch/$cc/$bld/js ion
            ;;

        (chkt)
            run python $srcdir/jit-test/jit_test.py --ion -s -o $srcdir/_build/$arch/$cc/$bld/js "$@"
            ;;

        (run)
            run $srcdir/_build/$arch/$cc/$bld/js "$@"
            ;;

        (runi)
            phase="runi interp"
            run $srcdir/_build/$arch/$cc/$bld/js "$@"
            failed=false
            kontinue_save=$kontinue
            kontinue=true
            empty_opt=
            for mode in eager infer none; do
                mode_opt=$empty_opt
                test $mode = eager && mode_opt="$mode_opt --ion-eager"
                test $mode = infer && mode_opt="$mode_opt -n"
            for gvn in off pessimistic optimistic; do
                gvn_opt=$mode_opt
                test $gvn != optimistic && gvn_opt="$gvn_opt --ion-gvn=$gvn"
            for licm in off on; do
                licm_opt=$gvn_opt
                test $licm != on && licm_opt="$licm_opt --ion-licm=$licm"
            for ra in greedy lsra; do
                ra_opt=$licm_opt
                test $ra != lsra && ra_opt="$ra_opt --ion-regalloc=$ra"
            for inline in on off; do
                inline_opt=$ra_opt
                test $inline != on && inline_opt="$inline_opt --ion-inlining=$inline"
            for osr in on off; do
                osr_opt=$inline_opt
                test $osr != on && osr_opt="$osr_opt --ion-osr=$osr"

            opt=$osr_opt
            phase="runi ion mode=$mode gvn=$gvn licm=$licm regalloc=$ra inlining=$inline osr=$osr"
            run $srcdir/_build/$arch/$cc/$bld/js --ion $opt "$@"

            done
            done
            done
            done
            done
            done
            phase="runi"
            kontinue=$kontinue_save
            ;;

        (patch)
            if test $arch_cnt -eq $arch_max -a $bld_cnt -eq $bld_max -a $cc_cnt -eq $cc_max; then
                cd $srcdir;
                run generate_patch
                cd -
            fi
            ;;
    esac

done # phase
done # cc
done # bld
done # arch

exit 0