SPACK:=spack

all: prunable.filelist

spack.lock: spack.yaml
	$(SPACK) -e . external find curl gawk jq bash automake autoconf m4 libtool perl
	$(SPACK) -e . concretize -f

env.mk: spack.lock
	$(SPACK) -e . env depfile -o $@ --make-prefix .deps

# these jobs use the view
pipeline.hashes prunabable.hashes prunable.filelist: export PATH := $(CURDIR)/view/bin:$(PATH)

pipeline.hashes: .deps/env
	./run.sh pipelines

buildcache.hashes: pipeline.hashes
	./run.sh buildcaches

prunable.filelist: buildcache.hashes
	./run.sh prunable

clean:
	rm -rf *.hashes prunable.* download buildcache hashes remove-all

ifeq (,$(filter clean,$(MAKECMDGOALS)))
include env.mk
endif

