SPACK := spack
SINCE := 2023-02-13
GITLAB_URL := https://gitlab.spack.io/api/v4/projects/2
BUILDCACHES:=aws-ahug aws-ahug-aarch64 aws-isc \
	aws-isc-aarch64 build_systems data-vis-sdk \
	e4s e4s-mac e4s-oneapi e4s-power gpu-tests \
	ml-linux-x86_64-cpu ml-linux-x86_64-cuda \
	ml-linux-x86_64-rocm radiuss radiuss-aws \
	radiuss-aws-aarch64 tutorial

all: prunable.filelist

spack.lock: spack.yaml
	$(SPACK) -e . external find curl gawk jq bash automake autoconf m4 libtool perl
	$(SPACK) -e . concretize -f

env.mk: spack.lock
	$(SPACK) -e . env depfile -o $@ --make-prefix .deps

# These jobs use stuff from the view
pipeline.hashes prunabable.hashes prunable.filelist: export PATH := $(CURDIR)/view/bin:$(PATH)

pipeline.hashes: .deps/env
	mkdir -p download

	for page in $$(seq 100); do \
		pipeline_url="$(GITLAB_URL)/pipelines?ref=develop&per_page=100&page=$$page&updated_after=$(SINCE)"; \
		echo "Fetching page $$page: $$pipeline_url..."; \
		pipelines=$$(curl -LfsS "$$pipeline_url" | jq '.[].id'); \
		[ -z "$$pipelines" ] && break; \
		args=""; \
		for p in $$pipelines; do \
			args="$$args $(GITLAB_URL)/pipelines/$$p/jobs -fSLo download/$$p.pipeline"; \
		done; \
		curl --parallel --parallel-max 8 $$args; \
	done

	jobs="$$(cat download/*.pipeline | jq '.[] | select( .stage == "generate" and .status == "success" ) | .id')"; \
	args=""; \
	for j in $$jobs; do \
		args="$$args $(GITLAB_URL)/jobs/$$j/artifacts/jobs_scratch_dir/concrete_environment/spack.lock -fSLo download/$$j.lock"; \
	done; \
	curl --parallel --parallel-max 8 $$args || true

	cat download/*.lock | jq -r '.concrete_specs | keys_unsorted | .[]' | sort | uniq > pipeline.hashes

buildcache.hashes: .deps/env
	mkdir -p buildcache

	args=""; \
	for b in $(BUILDCACHES); do \
		args="$$args https://binaries.spack.io/develop/$$b/build_cache/index.json -fSLo buildcache/$$b.index.json"; \
	done; \
	curl --parallel --parallel-max 8 $$args

	cat buildcache/*.index.json | jq -r '.database.installs | .[] | select( .in_buildcache ) | .spec.hash' | sort | uniq > buildcache.hashes


prunable.filelist: buildcache.hashes pipeline.hashes
	cat buildcache.hashes pipeline.hashes pipeline.hashes | sort | uniq -u > prunable.hashes
	aws s3 --region us-east-1 --no-sign-request ls --recursive "s3://spack-binaries/develop" | grep -Ff prunable.hashes > prunable.filelist-with-metadata
	awk '{ sum+=$$3 }END{print $$sum;}' prunable.filelist-with-metadata
	awk '{ print $$4 }' prunable.filelist-with-metadata > prunable.filelist
	wc -l prunable.filelist

clean:
	rm -rf *.hashes prunable.* download buildcache hashes remove-all

ifeq (,$(filter clean,$(MAKECMDGOALS)))
include env.mk
endif

