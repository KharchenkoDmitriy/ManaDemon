# ManaDemon release helper (wraps release.sh). Output lands in the TOP-LEVEL
# dist/, one folder per source: dist/main/ManaDemon, dist/<worktree>/ManaDemon.
#
#   make release                       pick the main checkout or a worktree
#   make release SRC=main              non-interactive; SRC = name or path
#   make release SRC=feedback-round-3
#   make install WOW_ADDONS=/path/to/Interface/AddOns [SRC=...]
#   make list                          show sources, branches, versions
#   make clean                         remove the top-level dist/
#
# WOW_ADDONS may also come from the environment.

.RECIPEPREFIX := >
SRC ?=
WOW_ADDONS ?=
RELEASE := ./release.sh
SRCARG = $(if $(SRC),--src "$(SRC)",--menu)
ROOT := $(patsubst %/.git,%,$(abspath $(shell git rev-parse --git-common-dir 2>/dev/null)))

.PHONY: release install list clean

release:
> @$(RELEASE) $(SRCARG)

install:
> @test -n "$(WOW_ADDONS)" || { echo "usage: make install WOW_ADDONS=/path/to/Interface/AddOns [SRC=name]"; exit 1; }
> @$(RELEASE) $(SRCARG) --install "$(WOW_ADDONS)"

list:
> @$(RELEASE) --list

clean:
> rm -rf "$(ROOT)/dist"
