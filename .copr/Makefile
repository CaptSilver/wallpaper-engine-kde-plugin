# COPR invokes this as:
#   make -f .copr/Makefile srpm outdir="<dir>" spec="<path>"
#
# make_srpm is the source method that works for this repo. The srpm step is the
# only COPR stage with network access, and it is where the two-level submodule
# checkout has to happen -- %prep and %build are offline under every method, so
# the submodule content must already be inside the tarball by then.
#
# COPR does clone --recursive, but do not lean on it: the shallow-clone retry
# drops that flag, and the checkout that follows the clone never refreshes
# submodule worktrees, so building a tag whose gitlink differs from the default
# branch silently yields stale sources. make-srpm.sh re-runs the update itself.

REPO_ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))/..

.PHONY: srpm
srpm:
	dnf -y install git rpm-build tar gzip
	git config --global --add safe.directory '*'
	$(REPO_ROOT)/tools/scripts/make-srpm.sh \
	    $(if $(outdir),--outdir "$(outdir)") \
	    $(if $(spec),--spec "$(spec)")
