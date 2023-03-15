#!/usr/bin/env bash

buildcaches="aws-ahug aws-ahug-aarch64 aws-isc aws-isc-aarch64 build_systems data-vis-sdk e4s e4s-mac e4s-oneapi e4s-power gpu-tests ml-linux-x86_64-cpu ml-linux-x86_64-cuda ml-linux-x86_64-rocm radiuss radiuss-aws radiuss-aws-aarch64 tutorial"

download() {
    code=$(curl -Lsfo "$1" -w "%{http_code}" "$2")
    if [ "$code" = "404" ]; then
        echo "Not found: $2 (artifacts removed?)"
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

    sort < hashes | uniq > pipeline.hashes
}

fetch_all_from_recent_pipelines() {
    url="https://gitlab.spack.io/api/v4/projects/2"
    since="$1"
    mkdir -p download

    echo "Fetching all spack.lock files of pipelines since $since"

    for page in $(seq 100); do
        pipeline_url="$url/pipelines?ref=develop&per_page=32&page=$page&updated_after=$since"
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

buildcache_hashes() {
    curl -LfsS "https://binaries.spack.io/develop/$1/build_cache/index.json" | jq -r '.database.installs | .[] | select( .in_buildcache ) | .spec.hash' | sort | uniq > "buildcache/$1.hashes"
}

fetch_all_from_buildcaches() {
    echo "Fetching all build cache indices"

    mkdir -p buildcache

    for name in $buildcaches; do
        buildcache_hashes "$name" &
    done

    wait

    cat buildcache/*.hashes | sort | uniq > buildcache.hashes
}

list_prunable_files() {
    echo "Listing all files to be pruned from buildcaches"

    # Get all buildcaches hashes not in pipeline.hashes, by taking
    # unique only and ensuring pipeline hashes are repeated
    cat buildcache.hashes pipeline.hashes pipeline.hashes | sort | uniq -u > prunable.hashes
    aws s3 --region us-east-1 --no-sign-request ls --recursive "s3://spack-binaries/develop" | grep -Ff prunable.hashes > prunable.filelist-with-metadata

    # List all files to delete from all buildcaches
    awk '{ print $4 }' prunable.filelist-with-metadata > prunable.filelist

    wc -l prunable.filelist
}

if [ "$1" = "pipelines" ]; then
    fetch_all_from_recent_pipelines 2023-02-10
elif [ "$1" = "buildcaches" ]; then
    fetch_all_from_buildcaches
elif [ "$1" = "prunable" ]; then
    list_prunable_files
else
    exit 1
fi

