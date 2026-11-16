#!/bin/bash
#
# Entry point for the Galaxy "VS Code" Interactive Tool. Galaxy runs the tool
# command in the job working directory as the Galaxy job uid, with these
# variables injected by the tool definition (tool/interactivetool_vscode.xml):
#
#   EP_PATH     the path Galaxy routes to this entry point, which the server must
#               serve from because the proxy forwards the path unchanged. Path-based
#               ITs get /<prefix>/interactivetool/ep/<id>/<token>; domain-based ITs
#               get an empty value, which means "/"
#   GALAXY_URL  the Galaxy API endpoint reachable from inside the cluster
#   API_KEY     the launching user's API key
#   HISTORY_ID  the history the tool was launched from
#
# Everything written at runtime goes under the job working directory: it is the
# only writable location on the shared volume, and workspace/outputs is what
# Galaxy collects when the tool is stopped.

set -euo pipefail

# Empty for a domain-based entry point (Galaxy injects "" when the path is "/").
EP_PATH="${EP_PATH:-/}"

JOB_DIR="$PWD"
WORKSPACE="$JOB_DIR/workspace"
export HOME="$JOB_DIR/home"
export MAMBA_ROOT_PREFIX="$HOME/micromamba"

mkdir -p "$HOME/data/User" "$HOME/server" "$WORKSPACE/inputs" "$WORKSPACE/outputs"

# Shell for the integrated terminal.
cat > "$HOME/.bashrc" <<EOF
export PATH="/opt/galaxy-vscode/bin:\$PATH"
export MAMBA_ROOT_PREFIX="$MAMBA_ROOT_PREFIX"
eval "\$(micromamba shell hook -s bash)"
cd "$WORKSPACE"
PS1='\w \$ '
alias ll='ls -l'
EOF
echo 'source ~/.bashrc' > "$HOME/.bash_profile"

# Editor defaults, written once so a user's own changes during the session win.
if [[ ! -e "$HOME/data/User/settings.json" ]]; then
    cat > "$HOME/data/User/settings.json" <<EOF
{
    "python.defaultInterpreterPath": "/usr/bin/python3",
    "r.rpath.linux": "${R_ENV:-/opt/conda/envs/r}/bin/R",
    "r.rterm.linux": "${R_ENV:-/opt/conda/envs/r}/bin/R",
    "r.plot.useHttpgd": true,
    "telemetry.telemetryLevel": "off",
    "workbench.startupEditor": "readme",
    "workbench.tips.enabled": false,
    "extensions.autoUpdate": false,
    "security.workspace.trust.enabled": false
}
EOF
fi

# Orientation for the user. Written once; a user who edits it keeps the edits.
# The delimiter is not EOF because the text itself shows a heredoc ending in EOF.
if [[ ! -e "$WORKSPACE/README.md" ]]; then
    cat > "$WORKSPACE/README.md" <<'WORKSPACE_README'
# Galaxy VS Code workspace

Galaxy started this VS Code session as an Interactive Tool. It runs inside your
Galaxy instance, next to your data.

## Folders

- `inputs/` holds the datasets you selected when launching the tool, linked
  read-only.
- `outputs/` is collected when you stop the tool from Galaxy (User > Active
  Interactive Tools). Every file saved here WITH a file extension, such as
  `notes.txt` or `result.tsv`, is imported into your history as a collection.

Nothing else survives: when the tool stops, the rest of the workspace, the
editor settings and any extensions you installed are discarded.

## Talking to Galaxy

Open a terminal (Terminal > New Terminal). These variables are set:

- `GALAXY_URL` is the Galaxy API endpoint reachable from here.
- `API_KEY` is your Galaxy API key.
- `HISTORY_ID` is the history this tool was launched from.

Two helpers use them:

```
galaxy-get <dataset>  [destination]   # copy a dataset from the history here
galaxy-put <file> [<file> ...]        # upload files to the history now
```

`<dataset>` is a history item number (the "3" in "3: my.fasta"), a dataset id
or an exact dataset name. For anything else, bioblend is installed:

```
python3 -c 'from bioblend.galaxy import GalaxyInstance; import os
gi = GalaxyInstance(os.environ["GALAXY_URL"], os.environ["API_KEY"])
print(gi.histories.show_history(os.environ["HISTORY_ID"])["name"])'
```

## What is installed

- `python3` with `bioblend` and `ipykernel`, so `.ipynb` notebooks run with the
  pre-installed Jupyter extension. Select `/usr/bin/python3` as the kernel.
  `numpy`, `pandas`, `scipy`, `scikit-learn`, `matplotlib` and `seaborn` are
  installed for it.
- `R` and `Rscript` (conda-forge) with `languageserver` for the pre-installed R
  extension, `IRkernel` so notebooks can use the "R" kernel, and `httpgd` for
  plots. Add packages with `install.packages()` (they go under `~/R`, so they
  last for the session) or with micromamba from conda-forge (`r-tidyverse`) or
  bioconda (`bioconductor-deseq2`).
- `micromamba` for conda-forge and bioconda packages, for example
  `micromamba create -n work -c conda-forge -c bioconda samtools` and then
  `micromamba activate work`. Environments are created under `~/micromamba`.
- `git`, `git-lfs`, `jq`, `curl`, `nano`.
- `gcloud` and `gsutil`.

More extensions can be installed from the Extensions view (Open VSX registry).

## Keeping a conda environment for a later session

Environments are discarded when the tool stops. `conda-pack` turns one into a
single archive that can be restored later, here saved to a Google Cloud Storage
bucket you can write to:

```
conda-pack -p ~/micromamba/envs/work -o work.tar.gz
gcloud storage cp work.tar.gz gs://<bucket>/galaxy-vscode/work.tar.gz
```

In a later session:

```
gcloud storage cp gs://<bucket>/galaxy-vscode/work.tar.gz .
mkdir -p ~/micromamba/envs/work
tar -xzf work.tar.gz -C ~/micromamba/envs/work
python3 ~/micromamba/envs/work/bin/conda-unpack
micromamba activate work
```

Run `conda-unpack` with `python3` as shown: it repairs the paths inside the
environment, which was built under a different directory. An archive can also
be kept in the history with `galaxy-put work.tar.gz` and fetched with
`galaxy-get`.

## Google Cloud

`gcloud` and `gsutil` authenticate automatically as the service account of the
VM that Galaxy runs on. On Terra that is the workspace pet service account, so
`gcloud storage ls gs://<workspace bucket>` works without logging in. Check
with `gcloud auth list`.

## Run an analysis here, or send it to Batch

Your terminal, scripts and notebook kernels run inside this session and share
its CPU and memory (1 CPU and 4 GB RAM in the supplied configuration; your
Galaxy may differ). Keep small analyses here. For larger work, `batch` sends a
command to Google Cloud Batch, where it runs on a separate VM while you keep
working.

Batch compute is billed to the Google Cloud project separately. It needs a
bucket that this session can write to: name it in the "Google Cloud Storage
bucket for Batch jobs" box when launching the tool, or pass `--bucket`.

### Example: summarize a table

Take a table from your history, with gene IDs in the first column and numeric
gene lengths in the second, and save this script as `analyze.R`:

```r
x <- read.delim("input.tsv")
result <- data.frame(genes = nrow(x), mean_length = mean(x[[2]]))
write.table(result, "result.tsv", sep = "\t", row.names = FALSE)
```

Then:

```bash
galaxy-get gene-length.tabular input.tsv
batch run --input input.tsv Rscript analyze.R
batch status            # repeat, or use: batch status --wait
batch fetch --put
```

`batch run` uploads `analyze.R` and `input.tsv` and runs the command in a
directory that holds them, so the script uses the same relative paths on Batch
as it does here. `batch fetch` copies whatever the command wrote, here
`result.tsv`, into `outputs/`, and `--put` also adds it to your history.
`batch logs` shows what the command printed.

### More CPUs, another image

```bash
batch run --cpus 2 --memory 8 --image bioconductor/bioconductor_docker:RELEASE_3_22 \
    --input input.tsv Rscript analyze.R
```

More CPUs help only when the code uses parallel workers or threads, for example
`BiocParallel::MulticoreParam(workers = 2)`. By default the job runs in the same
image as this session, so it has the software listed above but NOT packages,
extensions or conda environments you installed during the session. Use
`--image` for a container that has what the job needs.

### Good to know

- `batch --help` lists every option, including `--time` (the limit is 60
  minutes unless you raise it), `--machine-type` and `--dry-run`.
- Job files stay in the bucket under `galaxy-vscode/batch/<job>/` until you
  delete them.
- `batch status`, `batch logs` and `batch fetch` act on the job you submitted
  last; give a job name for an earlier one. `batch list` shows this session's
  jobs.
- The project, region and service account default to those of the VM Galaxy
  runs on. `batch --help` shows how to override them.

## Submitting a Batch job by hand

`batch` writes a job configuration and runs `gcloud` for you. This section does
the same thing by hand, for when you need a setting `batch` does not offer.

The examples below take a table from your Galaxy history, process it on Batch,
and bring the result back. Batch compute is billed separately. You will need a
Google Cloud project with Batch enabled, a job service account you can use, and
a bucket accessible to both your terminal identity and that service account.
Check the current identity and project with `gcloud auth list` and
`gcloud config get-value project`.

### Example 1: summarize a table on Batch

Choose a table with gene IDs in the first column and numeric gene lengths in
the second. Replace `gene-length.tabular` with its name or number in your history,
and fill in your bucket name and job service-account email:

```bash
galaxy-get gene-length.tabular input.tsv
BUCKET=YOUR_BUCKET
SERVICE_ACCOUNT=YOUR_JOB_SERVICE_ACCOUNT
REGION=us-east4
JOB=vscode-$(date +%s)
STAGING="gs://$BUCKET/$JOB"
```

Save this short script as `analyze.R`:

```r
x <- read.delim("/data/input.tsv")
result <- data.frame(genes = nrow(x), mean_length = mean(x[[2]]))
write.table(result, "/data/result.tsv", sep = "\t", row.names = FALSE)
```

Batch cannot see files in the IT directly. Copy the input and script to your
bucket; the job below mounts that folder at `/data` in its R container:

```bash
gcloud storage cp input.tsv analyze.R "$STAGING/"
cat > job.json <<EOF
{
  "taskGroups": [{"taskCount": 1, "taskSpec": {
    "runnables": [{"container": {
      "imageUri": "bioconductor/bioconductor_docker:RELEASE_3_22",
      "entrypoint": "Rscript", "commands": ["/data/analyze.R"],
      "volumes": ["/mnt/data:/data"]
    }}],
    "computeResource": {"cpuMilli": 1000, "memoryMib": 1024},
    "maxRunDuration": "900s", "maxRetryCount": 0,
    "volumes": [{"gcs": {"remotePath": "$BUCKET/$JOB"}, "mountPath": "/mnt/data"}]
  }}],
  "allocationPolicy": {
    "instances": [{"policy": {"machineType": "e2-standard-2"}}],
    "serviceAccount": {"email": "$SERVICE_ACCOUNT"},
    "location": {"allowedLocations": ["regions/$REGION"]}
  },
  "logsPolicy": {"destination": "CLOUD_LOGGING"}
}
EOF
gcloud batch jobs submit "$JOB" --location="$REGION" --config=job.json
gcloud batch jobs describe "$JOB" --location="$REGION" --format='value(status.state)'
```

Run the last command again to check progress. When it reports `SUCCEEDED`, your
result is in the bucket. Download it into the IT and add it to your history:

```bash
gcloud storage cp "$STAGING/result.tsv" outputs/result.tsv
galaxy-put outputs/result.tsv
```

### Example 2: use two Bioconductor workers

Reuse the staged input, but replace `analyze.R` with this version. It splits the
gene lengths into two chunks and summarizes them with `BiocParallel`:

```r
if (!requireNamespace("BiocParallel", quietly = TRUE))
    BiocManager::install("BiocParallel", ask = FALSE, update = FALSE)
library(BiocParallel)
x <- read.delim("/data/input.tsv")
chunks <- split(x[[2]], rep(1:2, length.out = nrow(x)))
result <- bplapply(chunks, function(z) c(genes = length(z), mean_length = mean(z)),
                  BPPARAM = MulticoreParam(workers = 2))
write.table(do.call(rbind, result), "/data/result-parallel.tsv",
            sep = "\t", col.names = NA)
```

In `job.json`, change `cpuMilli` to `2000` (two CPUs) and `memoryMib` to `4096`
(4 GiB). Upload the revised script and submit with a new job name, keeping the
same staging folder:

```bash
gcloud storage cp analyze.R "$STAGING/"
JOB=vscode-parallel-$(date +%s)
gcloud batch jobs submit "$JOB" --location="$REGION" --config=job.json
gcloud batch jobs describe "$JOB" --location="$REGION" --format='value(status.state)'
# Once SUCCEEDED:
gcloud storage cp "$STAGING/result-parallel.tsv" outputs/result-parallel.tsv
galaxy-put outputs/result-parallel.tsv
```

More CPUs help when your code uses parallel workers or threads. This small
example shows the setup; parallel overhead may outweigh any speedup for a small
table. For random workloads, pin the generator and seed for reproducible results.
Batch uses the chosen container's software, so packages installed in the IT are
not carried over.

Files written under `/data` stay in the bucket. Other worker-local files do not
automatically return to the IT; logs go to Cloud Logging. Keep the bucket copies
you need and remove temporary inputs and results when finished.
WORKSPACE_README
fi

# The proxy (gx-it-proxy or a Kubernetes Ingress) forwards the request path
# unchanged, so the server must serve from the entry point path. The
# pre-installed extensions live in the image; the server records its state there
# too, which is why the directory is world-writable.
exec /home/.openvscode-server/bin/openvscode-server \
    --host 0.0.0.0 \
    --port 3000 \
    --without-connection-token \
    --server-base-path "$EP_PATH" \
    --server-data-dir "$HOME/server" \
    --user-data-dir "$HOME/data" \
    --extensions-dir "${GALAXY_VSCODE_EXTENSIONS:-/opt/openvscode-server/extensions}" \
    --disable-telemetry \
    --default-folder "$WORKSPACE"
