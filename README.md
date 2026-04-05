# Strix-Halo MinerU Docker Container

A Docker-based deployment of [MinerU](https://github.com/opendatalab/MinerU) 3.0.8 for converting PDFs (textbooks, academic papers, technical documents) into structured Markdown with LaTeX formula support. Built specifically for AMD Strix-Halo systems like the Corsair AI Workstation 300, using ROCm 7.2.1 GPU acceleration that hasn't made it to mainstream yet.

## Why this exists

While strix-halo compatability has reached many releases, using PyTorch with ROCm 7.2.1 still requires using special AMD compiled wheels.  MinerU is product that leverages pytorch, so this is to address that gap.  This project uses a `pyproject.toml` that routes torch packages to AMD's wheel repository via `uv`'s index pinning, ensuring the ROCm builds are always used.

## Prerequisites

- AMD Strix-Halo (or compatible) GPU with ROCm 7.2.1 support
- Docker and Docker Compose
- ROCm kernel driver installed on the host
- At least 20GB disk space for models and the Docker image
- *Note:* I would get AMDGPU hang events, and then I set `amdgpu.cwsr_enable=0` in my `/etc/default/grub` and I have so far not had the hang events.


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

## Troubleshooting

### GPU not detected (0 GB VRAM, CUDA not available)

Run `make diagnose` to identify the issue. Most common causes:

**Wrong GPU GID**: The `GPU_GID` in `.env` doesn't match your system. Fix:
```bash
stat -c '%g' /dev/kfd /dev/dri/renderD128
# Update GPU_GID in .env with the output
make restart
```
If you end up with different GUIDs for both then you have to pass them both in, so you may need to manually edit the `docker-compose.yaml` file.

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

### AMDGPU Hang Events

There's a problem somewhere out there...  I've seen lots of people online give conflicting reports of what corrects this problem. For me on Ubuntu 25.10, I opened `/etc/default/grub` and added `amdgpu.cwsr_enable=0` to the end of `GRUB_CMDLINE_LINUX_DEFAULT="..."`.  After saving that, I ran `sudo update-grub`, and restarted.  

