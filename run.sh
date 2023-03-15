#!/usr/bin/env bash

buildcaches="aws-ahug aws-ahug-aarch64 aws-isc aws-isc-aarch64 build_systems data-vis-sdk e4s e4s-mac e4s-oneapi e4s-power gpu-tests ml-linux-x86_64-cpu ml-linux-x86_64-cuda ml-linux-x86_64-rocm radiuss radiuss-aws radiuss-aws-aarch64 tutorial"

fetch_all_from_recent_pipelines() {
    url="https://gitlab.spack.io/api/v4/projects/2"
    since="$1"
    mkdir -p download
    echo "Fetching all spack.lock files of pipelines since $since"

    # Download all pages of pipelines
    for page in $(seq 100); do
        pipeline_url="$url/pipelines?ref=develop&per_page=100&page=$page&updated_after=$since"
        echo "Fetching page $page: $pipeline_url..."
        pipelines=$(curl -LfsS "$pipeline_url" | jq '.[].id')
        [ -z "$pipelines" ] && break

        # Download all the pipelines as download/{id}.pipeline
        args=()
        for p in $pipelines; do
            args+=("$url/pipelines/$p/jobs")
            args+=("-fSLo")
            args+=("download/$p.pipeline")
        done
        curl --parallel --parallel-max 8 "${args[@]}"
    done

    # Retrieve all jobs
    jobs="$(cat download/*.pipeline | jq '.[] | select( .stage == "generate" and .status == "success" ) | .id')"

    # Download all spack.lock
    args=()
    for j in $jobs; do
        args+=("$url/jobs/$j/artifacts/jobs_scratch_dir/concrete_environment/spack.lock")
        args+=("-fSLo")
        args+=("download/$j.lock")
    done

    curl --parallel --parallel-max 8 "${args[@]}"

    cat download/*.lock | jq -r '.concrete_specs | keys_unsorted | .[]' | sort | uniq > pipeline.hashes
}

fetch_all_from_buildcaches() {
    echo "Fetching all build cache indices"

    mkdir -p buildcache

    args=()
    for b in $buildcaches; do
        args+=("https://binaries.spack.io/develop/$b/build_cache/index.json")
        args+=("-fSLo")
        args+=("buildcache/$b.index.json")
    done

    curl --parallel --parallel-max 8 "${args[@]}"

    for b in $buildcaches; do
        jq -r '.database.installs | .[] | select( .in_buildcache ) | .spec.hash' < "buildcache/$b.index.json" | sort | uniq > "buildcache/$b.hashes"
    done

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

