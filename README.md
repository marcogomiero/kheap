# k8s-heapdump-toolbox

A lightweight Bash toolbox for collecting JVM heap dumps and thread dumps from Kubernetes pods — even when the target container has no Java diagnostic tools installed.

## Overview

kheap is a single-script solution that automates the full heap-dump lifecycle:

1. Validates the target namespace, pod, and container
2. Auto-detects the Java PID (or accepts one explicitly)
3. Collects thread dumps (sequentially, with configurable count and interval)
4. Triggers the heap dump inside the container
5. Copies the .hprof file locally
6. Verifies size integrity (remote vs. local) and optionally MD5 checksum
7. Compresses the heap dump with gzip (unless --no-gzip)
8. Removes the remote copy (unless --keep-remote is set)

It supports two operating modes and falls back automatically from one to the other.

## Operating Modes

### DIRECT mode
Executes the heap dump directly inside the target container using tools already present there (jcmd or jattach). This is the preferred mode when the application image ships with JDK tooling.

### DEBUG mode
Injects a reusable ephemeral container (kheap or a unique name) into the pod using kubectl debug. The ephemeral container carries jattach and attaches to the JVM process in the target container. This is the fallback for minimal/distroless images that have no diagnostic tools.

By default, DIRECT mode is attempted first; if it fails, the script falls back to DEBUG mode. This behaviour can be overridden with --direct-only or --debug-only.

Note: If a debug container already exists and is running, it is reused. If it exists but is not running, the script automatically creates a new ephemeral container with a unique name (e.g., kheap-1712345678) instead of forcing pod recreation.

## Thread Dump Collection

Thread dumps are always attempted before the heap dump, regardless of the mode. They are collected in a cascading sequence:

1. jcmd Thread.print - if available in the target container (DIRECT mode)
2. jattach threaddump - via the debug container (DEBUG mode)
3. kill -3 + kubectl logs - universal fallback (works on any image)

The script can collect multiple sequential thread dumps with a configurable delay between them, which is useful for analysing deadlocks or progressive thread states.

Options:
- --thread-dump-count N - number of dumps to collect (default: 5, max 10)
- --thread-dump-interval S - seconds between dumps (default: 30)

All individual dumps are merged into a single gzipped archive (.log.gz) with clear separators.

## Requirements

Local machine:
- kubectl configured and authorised against the target cluster
- Standard POSIX utilities: awk, grep, date, gzip
- For checksum verification: md5sum (Linux) or md5 (macOS) - automatically detected

Cluster:
- The pod must be in Running phase
- DEBUG mode requires the cluster to allow ephemeral containers (kubectl debug) and ptrace/attach syscalls (check your PodSecurityPolicy / SecurityContext constraints)

## Toolbox Image

The DEBUG mode ephemeral container is built from the included Dockerfile. It is based on Chainguard Wolfi (minimal, distroless-style) and bundles:

- jattach - a lightweight JVM attach tool (default version: v2.2)
- procps - for Java PID detection via ps

### Build

docker build --build-arg JATTACH_VERSION=v2.2 -t your-registry/k8s-heapdump-toolbox:kheap .

### Override the toolbox image

Set the KHEAP_IMAGE environment variable or use the -i flag:

export KHEAP_IMAGE=your-registry/k8s-heapdump-toolbox:kheap

# or

./kheap -n my-ns -p my-pod -i your-registry/k8s-heapdump-toolbox:kheap

## Usage

./kheap -n namespace -p pod [-c container] [-P java_pid] [-i toolbox_image] [-r remote_dir] [-o output_dir] [--no-gzip] [--keep-remote] [--checksum] [--direct-only] [--debug-only] [--thread-dump-count N] [--thread-dump-interval S]

### Options

Flag                    Description                                         Default
-n namespace            Kubernetes namespace                                required
-p pod                  Pod name                                            required
-c container            Target container name                               auto-detect (first container)
-P pid                  Java PID                                            auto-detect
-i image                Toolbox image for DEBUG mode                        KHEAP_IMAGE or built-in default
-r remote_dir           Directory inside target container for the dump      /tmp
-o output_dir           Local directory where the dump is saved             current directory
--no-gzip               Skip local gzip compression                         -
--keep-remote           Do not delete the .hprof from the pod after copying -
--checksum              Verify MD5 checksum after copy (in addition to size check) -
--direct-only           Use DIRECT mode only, no fallback                   -
--debug-only            Use DEBUG mode only, skip DIRECT                    -
--thread-dump-count N   Collect N sequential thread dumps (max 10)          5
--thread-dump-interval S Seconds between thread dumps when N > 1           30
-h, --help              Show help                                           -

### Environment variables

Variable        Description
KHEAP_IMAGE     Override the default toolbox image used in DEBUG mode

## Examples

Minimal usage - auto-detect container and Java PID:
./kheap -n pt-healthcheck -p fanny-547bb857d8-jq59m

Specify the target container explicitly:
./kheap -n pt-healthcheck -p fanny-547bb857d8-jq59m -c app

Force DIRECT mode only (fails if the container has no jcmd/jattach):
./kheap -n pt-healthcheck -p fanny-547bb857d8-jq59m --direct-only

Force DEBUG mode only (always uses the ephemeral toolbox container):
./kheap -n pt-healthcheck -p fanny-547bb857d8-jq59m --debug-only

Save dump to a specific directory, skip compression:
./kheap -n pt-healthcheck -p fanny-547bb857d8-jq59m -o /dumps --no-gzip

Use a custom registry image:
./kheap -n pt-healthcheck -p fanny-547bb857d8-jq59m -i myregistry.example.com/toolbox:kheap

Collect 3 thread dumps with 10 seconds interval + checksum verification:
./kheap -n pt-healthcheck -p fanny-547bb857d8-jq59m --thread-dump-count 3 --thread-dump-interval 10 --checksum

## Output

On success, kheap prints a summary:

================== KHEAP SUMMARY ==================
Mode used        : DEBUG
Namespace        : pt-healthcheck
Pod              : fanny-547bb857d8-jq59m
Target container : app
Java PID         : 1
Remote file      : /tmp/heap_pt-healthcheck_fanny-547bb857d8-jq59m_20240315120000.hprof
Local heap dump  : ./pt-healthcheck_fanny-547bb857d8-jq59m_20240315120000.hprof.gz
Thread dumps     : 5/5 collected (via jattach (DEBUG container))
Thread dump archive: ./pt-healthcheck_fanny-547bb857d8-jq59m_20240315120000_threaddump.log.gz
Debug container  : kheap-1712345678 (REUSE, kept running)
Tool image       : myregistry.example.com/toolbox:kheap
Gzip             : enabled
Checksum (MD5)   : yes
Keep remote      : no
===================================================

- The heap dump is saved as ns_pod_timestamp.hprof.gz (or .hprof if --no-gzip).
- The thread dump archive is saved as ns_pod_timestamp_threaddump.log.gz.
- The ephemeral debug container is kept running after the first invocation so it can be reused for subsequent dumps on the same pod without re-injection overhead.

## Notes

- --direct-only and --debug-only are mutually exclusive.
- If the debug container exists but is not running, the script creates a new ephemeral container with a unique name instead of failing. This avoids forcing pod recreation.
- On copy failure, kubectl cp is retried up to 12 times; if all attempts fail, the script falls back to streaming via kubectl exec ... cat.
- Partial local files are cleaned up automatically on error via a trap.
- Checksum uses md5sum on Linux and md5 -q on macOS - detected automatically.
- Thread dumps are always attempted; failures are non-fatal (only a warning is emitted).

## Troubleshooting

Issue                                   Likely cause                           Suggestion
kubectl debug fails                     Cluster does not support ephemeral     Verify Kubernetes version (>=1.16) and feature gate
                                        containers or lacks permissions        EphemeralContainers=true. Check RBAC for pods/ephemeralcontainers.
Heap dump fails in DEBUG mode           Debug container lacks SYS_PTRACE       Ensure the toolbox image is run with adequate security context
                                        capability                             (e.g., securityContext.privileged=true or capabilities.add=["SYS_PTRACE"]).
jattach not found in toolbox            Toolbox image not built correctly      Rebuild the image with the included Dockerfile, ensuring jattach is installed.
Thread dump via kill -3 produces        JVM writes thread dump to stderr       Check if the container logs are available. The fallback kill -3 method
empty logs                              or log file, not stdout                may not capture everything if logs are rotated or truncated.

## License

See LICENSE if present, or refer to the repository root.