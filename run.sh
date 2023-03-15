#!/bin/bash

download() {
    [ -f "$1" ] && return
    code=$(curl -LSsfo "$1" -w "%{http_code}" "$2")
    if [ "$code" = "404" ]; then
        echo "Couldn't fetch $2 due to $code response."
    elif [ "$code" != "200" ]; then
        echo "FATAL: Couldn't fetch $2 due to $code response."
        exit 1
    fi
}

extract_hashes() {
    echo "Extracting all hashes from spack.lock files"
    rm -rf hashes

    for f in download/*.lock; do
        jq -r '.concrete_specs | keys_unsorted | .[]' < "$f" >> hashes
    done

    sort < hashes | uniq > recent_pipeline_hashes
}

fetch_all_from_recent_pipelines() {
    url="https://gitlab.spack.io/api/v4/projects/2"
    since="$1"
    mkdir -p download

    echo "Fetching all spack.lock files of pipelines since $since"

    for page in $(seq 100); do
        pipeline_url="$url/pipelines?ref=develop&per_page=16&page=$page&updated_after=$since"
        echo "Fetching page $page: $pipeline_url..."
        pipelines=$(curl -LfsS "$pipeline_url" | jq '.[].id')
        [ -z "$pipelines" ] && break
        for pipeline in $pipelines; do
            for job in $(curl -LfsS "$url/pipelines/$pipeline/jobs" | jq '.[] | select( .stage == "generate" and .status == "success" ) | .id'); do
                download "download/$pipeline-$job.lock" "$url/jobs/$job/artifacts/jobs_scratch_dir/concrete_environment/spack.lock" &
            done
        done
    done

    wait

    extract_hashes
}

buildcaches="\
    aws-ahug \
    aws-ahug-aarch64 \
    aws-isc \
    aws-isc-aarch64 \
    build_systems \
    data-vis-sdk \
    e4s \
    e4s-mac \
    e4s-oneapi \
    e4s-power \
    gpu-tests \
    ml-linux-x86_64-cpu \
    ml-linux-x86_64-cuda \
    ml-linux-x86_64-rocm \
    radiuss \
    radiuss-aws \
    radiuss-aws-aarch64 \
    tutorial"

buildcache_hashes() {
    [ -f "$1.hashes" ] && return
    echo "$1.hashes"
    curl -LfsS "https://binaries.spack.io/develop/$1/build_cache/index.json" | jq -r '.database.installs | .[] | select( .in_buildcache ) | .spec.hash' | sort | uniq > "$1.hashes"
}

fetch_all_from_buildcaches() {
    echo "Fetching all build cache indices"

    for name in $buildcaches; do
        buildcache_hashes "$name" &
    done

    wait

    cat *.hashes | sort | uniq > buildcache_hashes
}

prunable_from_buildcaches() {
    echo "Computing prunable specs from buildcaches"
    # Get all buildcaches hashes not in recent_pipeline_hashes, by taking
    # unique only and ensuring pipeline hashes are repeated
    for name in $buildcaches; do
        cat "$name.hashes" recent_pipeline_hashes recent_pipeline_hashes | sort | uniq -u > "$name.prune"
    done
}


filter_ls() {
    aws s3 --region us-east-1 --no-sign-request ls --recursive "s3://spack-binaries/develop/$1/build_cache" | grep -f "$1.prune" > "remove/$1"
}

list_removable_files() {
    echo "Listing all files to be pruned from buildcaches"
    mkdir -p remove
    for name in $buildcaches; do
        filter_ls "$name" &
    done
    wait

    # List all files to delete from all buildcaches
    awk '{ print $4 }' remove/* > remove-all

    # THe develop buildcache is the sum of them, so drop the develop/<name>/ bit.
    perl -pe 's|^develop/.*?/|develop/|' < remove-all | sort | uniq > remove-all-develop

    gzip remove-all remove-all-develop
}

#fetch_all_from_recent_pipelines 2023-02-10
#fetch_all_from_buildcaches
#prunable_from_buildcaches
#list_removable_files

echo "Active hashes: $(wc -l < recent_pipeline_hashes)"
echo "Total in buildcache: $(wc -l < buildcache_hashes)"
echo "Bytes to delete: $(awk '{count=count+$3}END{print count}' remove/*)"
echo "See ./remove-all for the full list"

