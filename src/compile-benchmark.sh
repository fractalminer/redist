#!/bin/bash
set -eo pipefail

# The TU will be compiled this many times to get an avg time.
export TRIALS=5

cd ~/dev/revolution-now/.builds/current/

single() {
  $HOME/dev/tools/llvm-current/bin/clang++ \
    -DLUA_USE_LINUX \
    -DRN_BUILD_OUTPUT_ROOT_DIR=$HOME/dev/revolution-now/.builds/clang-22.1.8-lld-libstdc++-relwdeb-ninja \
    -DRN_SOURCE_TREE_ROOT=$HOME/dev/revolution-now \
    -I$HOME/dev/revolution-now/src/ss \
    -I$HOME/dev/revolution-now/.builds/clang-22.1.8-lld-libstdc++-relwdeb-ninja/src/ss \
    -I$HOME/dev/revolution-now/src \
    -I$HOME/dev/revolution-now/.builds/clang-22.1.8-lld-libstdc++-relwdeb-ninja/src \
    -I$HOME/dev/revolution-now/src/base \
    -I$HOME/dev/revolution-now/extern/base-util/src/include \
    -I$HOME/dev/revolution-now/src/cdr \
    -I$HOME/dev/revolution-now/src/gfx \
    -I$HOME/dev/revolution-now/.builds/clang-22.1.8-lld-libstdc++-relwdeb-ninja/src/gfx \
    -I$HOME/dev/revolution-now/src/luapp \
    -I$HOME/dev/revolution-now/extern/lua-5.4.8/lib \
    -I$HOME/dev/revolution-now/src/refl \
    -I$HOME/dev/revolution-now/src/traverse \
    -Wno-unused-command-line-argument \
    -nostdinc++ \
    -isystem $HOME/dev/tools/gcc-current/include/c++/16.2.0 \
    -isystem $HOME/dev/tools/gcc-current/include/c++/16.2.0/x86_64-pc-linux-gnu \
    -DENABLE_CPP23_STACKTRACE \
    -fcolor-diagnostics \
    -march=x86-64-v3 \
    -mtune=generic \
    -O2 \
    -g \
    -DNDEBUG \
    -std=c++23 \
    -Weverything \
    -Werror=return-type \
    -Wno-pre-c++20-compat \
    -Wno-c++20-compat \
    -Wno-pre-c++17-compat \
    -Wno-pre-c++14-compat \
    -Wno-c99-extensions \
    -Wno-c++98-compat \
    -Wno-c++98-compat-pedantic \
    -Wno-reserved-macro-identifier \
    -Wno-newline-eof \
    -Wno-padded \
    -Wno-extra-semi-stmt \
    -Wno-extra-semi \
    -Wno-reserved-identifier \
    -Wno-ctad-maybe-unsupported \
    -Wno-undefined-func-template \
    -Wno-switch-default \
    -Wno-c2y-extensions \
    -Wno-shadow-header \
    -Wno-unsafe-buffer-usage \
    -Wno-switch-enum \
    -Wno-shadow \
    -Wno-shadow-uncaptured-local \
    -Wno-shadow-field \
    -Wno-exit-time-destructors \
    -Wno-implicit-int-conversion \
    -Wno-implicit-float-conversion \
    -Wno-sign-conversion \
    -Wno-old-style-cast \
    -Wno-shorten-64-to-32 \
    -Wno-global-constructors \
    -Wno-weak-vtables \
    -Wno-double-promotion \
    -Wno-float-equal \
    -Wno-unknown-warning-option \
    -Wno-thread-safety-negative \
    -Wno-gnu-line-marker \
    -fno-fast-math \
    -ffp-contract=off \
    -frounding-math \
    -fexcess-precision=standard \
    -fno-associative-math \
    -fno-unsafe-math-optimizations \
    -fno-finite-math-only \
    -fsigned-zeros \
    -ftrapping-math \
    -MMD \
    -MT src/ss/lua-root-6.cpp \
    -MF /tmp/lua-root-6.cpp.d \
    -o /tmp/lua-root-6.cpp.o \
    -c \
    $HOME/dev/revolution-now/src/ss/lua-root-6.cpp
}
export -f single

ten_runs() {
  for (( i=0; i<TRIALS; i++ )); do
    single
  done
}
export -f ten_runs

timeit() {
  /usr/bin/time 2>&1 --format=%e bash -c ten_runs
}

lua -e "print( 'avg time[$TRIALS]:', $(timeit)/$TRIALS )"