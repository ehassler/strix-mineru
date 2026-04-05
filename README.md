# Strix-Halo MinerU Docker Container

A Docker-based deployment of [MinerU](https://github.com/opendatalab/MinerU) 3.0.8 for converting PDFs (textbooks, academic papers, technical documents) into structured Markdown with LaTeX formula support. Built specifically for AMD Strix-Halo systems using ROCm 7.2.1 GPU acceleration.

## Why this exists

I have a Corsair AI Workstation 300, and getting anything outside the most mainstream of mainstream AI workloads has been a challenge.  One such challenge was installing MinerU with ROCm GPU support. MinerU depends on PyTorch and so we need to use AMD's ROCm-compiled GPU wheels for PyTorch and a few other dependencies.  This project uses a `pyproject.toml` that routes torch packages to AMD's wheel repository via `uv`'s index pinning, ensuring the ROCm builds are always used.

## Prerequisites

- AMD Strix-Halo (or compatible) GPU with ROCm 7.2.1 support
- Docker and Docker Compose
- ROCm kernel driver installed on the host
- At least 20GB disk space for models and the Docker image

## Quick start

```bash
# 1. Configure for your system
cp example.env .env
# Edit .env — at minimum, set GPU_GID to match your system:
#   stat -c '%g' /dev/kfd /dev/dri/renderD128

# 2. Build, download models, and start
make build              # Build the Docker image (~30 min first time)
make download-models    # One-time model download (~5 min)
make up                 # Start mineru-api

# 3. Verify
# Point your web browser to http://localhost:8000/docs for Swagger
make diagnose           # Check GPU access, PyTorch, MinerU
make test               # Hit the health endpoint
```

## Configuration

All configuration lives in a single `.env` file. This file lives in the same directory as the docker-compose.yaml and the Makefile so you don't need to rebuild the container image each time you make changes.  Copy `example.env` to `.env` and edit:

```bash
cp example.env .env
```

| Variable | Default | Description |
|----------|---------|-------------|
| `MINERU_PORT` | `8000` | API server port |
| `GPU_GID` | `44` | GID that owns `/dev/kfd` and `/dev/dri/renderD128`. Find with: `stat -c '%g' /dev/kfd` |
| `MINERU_MODELS` | `./models` | Host directory for model cache (persists across container restarts) |
| `MINERU_OUTPUT` | `./output` | Host directory for API output files |
| `MINERU_VIRTUAL_VRAM_SIZE` | _(auto)_ | GPU memory limit in GB. Leave blank for auto-detection |
| `GPU_MEMORY_UTILIZATION` | `0.9` | Fraction of VRAM for KV cache (0.0–1.0) |
| `TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL` | `1` | Enable experimental memory-efficient attention via AOTriton (`0` = off, `1` = on) |

Changes take effect after `make restart` — no rebuild needed.

## Makefile targets

Run `make help` to see all targets. Key ones:

| Target | Description |
|--------|-------------|
| `make build` | Build the Docker image |
| `make download-models` | One-time model download into the local `models/` directory |
| `make up` | Start the API service (detached) |
| `make down` | Stop the API service |
| `make restart` | Restart the API service (picks up `.env` changes) |
| `make logs` | Tail service logs in real time (Ctrl-C to stop) |
| `make status` | Show container state and health |
| `make shell` | Open a bash shell inside the running container |
| `make diagnose` | Run GPU/ROCm/MinerU diagnostic checks |
| `make test` | Smoke test the health endpoint |
| `make clean` | Stop service and remove container (keeps models) |
| `make clean-all` | Stop service, remove container AND model cache |

Notes:
- `download-models` spins up a one-shot container with the same volume mounts, downloads into the persistent `models/` directory, and exits cleanly.
- `clean` keeps the model cache since re-downloading is expensive (~2GB). `clean-all` wipes everything including models.

## API usage

MinerU exposes a REST API. Full docs are available at `http://localhost:8000/docs` when the service is running.

### Parse a single page

```bash
curl -X POST http://127.0.0.1:8000/file_parse \
    -F "files=@paper.pdf" \
    -F "formula_enable=true" \
    -F "table_enable=true" \
    -F "return_md=true" \
    -F "response_format_zip=true" \
    -F "return_original_file=false" \
    -F "start_page_id=12" \
    -F "end_page_id=12" \
    -o output.zip
```

### Parse a page range

```bash
curl -X POST http://127.0.0.1:8000/file_parse \
    -F "files=@textbook.pdf" \
    -F "formula_enable=true" \
    -F "table_enable=true" \
    -F "return_md=true" \
    -F "response_format_zip=true" \
    -F "return_original_file=false" \
    -F "start_page_id=120" \
    -F "end_page_id=180" \
    -o chapter.zip
```

### Parse an entire document

```bash
curl -X POST http://127.0.0.1:8000/file_parse \
    -F "files=@document.pdf" \
    -F "formula_enable=true" \
    -F "table_enable=true" \
    -F "return_md=true" \
    -F "response_format_zip=true" \
    -o document.zip
```

### Common parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `files` | file | PDF file to parse (required) |
| `formula_enable` | bool | Enable LaTeX formula recognition |
| `table_enable` | bool | Enable table structure recognition |
| `return_md` | bool | Include Markdown in response |
| `response_format_zip` | bool | Return results as a ZIP archive |
| `return_original_file` | bool | Include the original PDF in the ZIP |
| `start_page_id` | int | First page to parse (0-indexed) |
| `end_page_id` | int | Last page to parse (0-indexed) |
| `backend` | string | Processing backend: `pipeline`, `vlm`, or `hybrid` |

### Check service health

```bash
curl http://127.0.0.1:8000/health
```

## Project structure

```
.
├── .env                 # Configuration (create from example.env)
├── example.env          # Template configuration
├── Dockerfile           # Container image definition
├── docker-compose.yml   # Service definition with GPU access and runtime args
├── pyproject.toml       # Python dependencies with ROCm wheel routing
├── diagnose.py          # GPU/ROCm/MinerU diagnostic script
├── Makefile             # Build, run, and management targets
├── models/              # Model cache (created by make download-models)
└── output/              # API output directory
```

## How ROCm wheel routing works

The central challenge is preventing `uv`/`pip` from replacing AMD's ROCm-compiled PyTorch wheels with generic CUDA/CPU builds from PyPI. The `pyproject.toml` solves this with three mechanisms:

1. **Explicit index**: The AMD wheel repository is declared as a flat index with `explicit = true`, meaning packages are ONLY fetched from it when specifically routed there.

2. **Source routing**: `[tool.uv.sources]` pins `torch`, `torchvision`, `torchaudio`, `triton`, and `apex` to the ROCm index. The resolver will not consider PyPI for these packages.

3. **Version pinning**: Each ROCm package is pinned to the exact version available for Python 3.13 in the ROCm 7.2.1 repository.

The Dockerfile's build-time verification step checks that no `nvidia-*` packages were installed, catching routing failures before the image ships.

## Troubleshooting

### GPU not detected (0 GB VRAM, CUDA not available)

Run `make diagnose` to identify the issue. Most common causes:

**Wrong GPU GID**: The `GPU_GID` in `.env` doesn't match your system. Fix:
```bash
stat -c '%g' /dev/kfd /dev/dri/renderD128
# Update GPU_GID in .env with the output
make restart
```

**PyPI torch replaced ROCm torch**: Check inside the container:
```bash
make shell
python -c "import torch; print(torch.version.hip)"
```
If this prints `None`, a PyPI build snuck in. Rebuild with `make build`.

### Health check failing

The healthcheck uses `wget` to GET `http://localhost:${MINERU_PORT}/health`. If the port in `.env` doesn't match the `--port` in `docker-compose.yml`'s command section, the check will hit the wrong port. Ensure `MINERU_PORT` in `.env` matches.

### Models not found

```bash
make download-models
```

Models are stored in the `models/` directory on the host. If you've moved or deleted it, re-run the download.

### Out of VRAM

Reduce GPU memory utilization in `.env`:
```bash
GPU_MEMORY_UTILIZATION=0.5
```
Or set an explicit VRAM limit:
```bash
MINERU_VIRTUAL_VRAM_SIZE=32
```
Then `make restart`.

## Available ROCm packages

The `pyproject.toml` routes the following packages to AMD's ROCm 7.2.1 repository. Additional packages are listed as comments and can be enabled if needed:

**Active (Python 3.13)**:
`torch`, `torchvision`, `torchaudio`, `triton`, `apex`

**Available for Python 3.13** (commented out):
`triton_kernels`, `xformers`, `transformer_engine`, `transformer_engine_rocm`, `transformer_engine_torch`

**Available for Python 3.12 only** (commented out):
`jaxlib`, `jax_rocm7_plugin`, `jax_rocm7_pjrt`, `onnxruntime_migraphx`, `tensorflow_rocm`

## Version matrix

| Component | Version | Notes |
|-----------|---------|-------|
| Ubuntu | 25.10 | Base image |
| Python | 3.13 | Highest supported by MinerU (<3.14) |
| ROCm | 7.2.1 | AMD GPU compute stack |
| PyTorch | 2.9.1 | Highest available for cp313 in ROCm 7.2.1 repo |
| torchvision | 0.24.0 | Matches torch 2.9.1 |
| torchaudio | 2.9.0 | Matches torch 2.9.1 |
| triton | 3.5.1 | ROCm-compiled |
| apex | 1.9.0 | ROCm-compiled |
| MinerU | 3.0.8 | Pinned with frozen dependencies |
| uv | 0.11.3 | Python package manager |
