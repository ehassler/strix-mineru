#!/usr/bin/env python3
"""MinerU ROCm environment diagnostic.

Run inside the container to verify GPU access, PyTorch ROCm build,
and MinerU readiness.

Usage:
    python /opt/mineru/diagnose.py
    # or via make:
    make diagnose
"""

import os
import sys
import shutil
import subprocess


def section(title):
    print(f"\n{'─' * 60}")
    print(f"  {title}")
    print(f"{'─' * 60}")


def check_devices():
    section("1. Device access")
    devices = ["/dev/kfd", "/dev/dri/renderD128"]
    all_ok = True
    for dev in devices:
        if os.path.exists(dev):
            readable = os.access(dev, os.R_OK)
            writable = os.access(dev, os.W_OK)
            status = "OK" if (readable and writable) else "NO ACCESS"
            if status != "OK":
                all_ok = False
            try:
                import stat as st
                info = os.stat(dev)
                gid = info.st_gid
                perms = oct(info.st_mode)[-3:]
                print(f"  {dev}: {status}  (gid={gid}, perms={perms})")
            except Exception:
                print(f"  {dev}: {status}")
        else:
            print(f"  {dev}: MISSING")
            all_ok = False
    return all_ok


def check_user():
    section("2. User and groups")
    uid = os.getuid()
    gid = os.getgid()
    groups = os.getgroups()
    username = os.environ.get("USER", "unknown")
    try:
        import pwd
        username = pwd.getpwuid(uid).pw_name
    except Exception:
        pass
    print(f"  User: {username} (uid={uid}, gid={gid})")
    print(f"  Groups: {groups}")
    return True


def check_rocm_smi():
    section("3. ROCm SMI")
    if not shutil.which("rocm-smi"):
        print("  rocm-smi: NOT FOUND")
        return False
    try:
        result = subprocess.run(
            ["rocm-smi", "--showid", "--showtemp", "--showmeminfo", "vram"],
            capture_output=True, text=True, timeout=10
        )
        for line in result.stdout.strip().splitlines():
            print(f"  {line}")
        return result.returncode == 0
    except Exception as e:
        print(f"  Error: {e}")
        return False


def check_torch():
    section("4. PyTorch ROCm build")
    try:
        import torch
    except ImportError:
        print("  torch: NOT INSTALLED")
        return False

    version = torch.__version__
    hip = getattr(torch.version, "hip", None)
    cuda_available = torch.cuda.is_available()
    device_count = torch.cuda.device_count()

    is_rocm = hip is not None
    print(f"  Version: {version}")
    print(f"  HIP runtime: {hip or 'None (NOT a ROCm build!)'}")
    print(f"  cuda.is_available(): {cuda_available}")
    print(f"  Device count: {device_count}")

    if not is_rocm:
        print("  ⚠ This is NOT a ROCm build — a PyPI torch may have replaced it")
        return False

    if not cuda_available:
        print("  ⚠ ROCm build detected but no GPU visible to PyTorch")
        print("    → Check device permissions (section 1) and group membership (section 2)")
        return False

    for i in range(device_count):
        name = torch.cuda.get_device_name(i)
        props = torch.cuda.get_device_properties(i)
        vram_gb = props.total_mem / (1024 ** 3)
        print(f"  GPU {i}: {name} — {vram_gb:.1f} GB VRAM")

    return True


def check_nvidia_packages():
    section("5. CUDA/nvidia package contamination")
    try:
        result = subprocess.run(
            ["uv", "pip", "list"],
            capture_output=True, text=True, timeout=30
        )
        nvidia_pkgs = [
            line for line in result.stdout.splitlines()
            if line.lower().startswith("nvidia")
        ]
        if nvidia_pkgs:
            print("  ⚠ nvidia packages detected — ROCm wheel routing may have failed:")
            for pkg in nvidia_pkgs:
                print(f"    {pkg}")
            return False
        else:
            print("  OK — no nvidia packages installed")
            return True
    except Exception as e:
        print(f"  Could not check: {e}")
        return True


def check_mineru():
    section("6. MinerU installation")
    try:
        import mineru
        version = getattr(mineru, "__version__", None)
        if version is None:
            from mineru.version import __version__ as version
        print(f"  Version: {version}")
    except ImportError:
        print("  mineru: NOT INSTALLED")
        return False
    except Exception as e:
        print(f"  Version check failed: {e}")

    # Check CLI tools
    cli_tools = ["mineru", "mineru-api", "mineru-models-download"]
    for tool in cli_tools:
        path = shutil.which(tool)
        status = "OK" if path else "MISSING"
        print(f"  {tool}: {status}")

    return True


def check_models():
    section("7. Model cache")
    cache_dirs = [
        os.path.expanduser("~/.cache/huggingface"),
        os.path.expanduser("~/.cache/modelscope"),
    ]
    found_any = False
    for d in cache_dirs:
        if os.path.isdir(d):
            # Count files to estimate if models are downloaded
            count = sum(1 for _, _, files in os.walk(d) for _ in files)
            size_mb = sum(
                os.path.getsize(os.path.join(root, f))
                for root, _, files in os.walk(d) for f in files
            ) / (1024 ** 2)
            print(f"  {d}: {count} files, {size_mb:.0f} MB")
            if count > 0:
                found_any = True
        else:
            print(f"  {d}: not present")

    if not found_any:
        print("  ⚠ No models found — run: mineru-models-download")
        return False

    # Check for mineru.json config
    config = os.path.expanduser("~/mineru.json")
    if os.path.isfile(config):
        print(f"  {config}: present")
    else:
        print(f"  {config}: not present (will be created on first model download)")

    return True


def main():
    print("=" * 60)
    print("  MinerU ROCm Diagnostic")
    print("=" * 60)

    results = {}
    results["devices"] = check_devices()
    results["user"] = check_user()
    results["rocm_smi"] = check_rocm_smi()
    results["torch"] = check_torch()
    results["no_nvidia"] = check_nvidia_packages()
    results["mineru"] = check_mineru()
    results["models"] = check_models()

    section("Summary")
    all_ok = True
    for name, ok in results.items():
        symbol = "✓" if ok else "✗"
        print(f"  {symbol}  {name}")
        if not ok:
            all_ok = False

    print()
    if all_ok:
        print("  All checks passed — MinerU is ready.")
    else:
        print("  Some checks failed — see details above.")
    print()

    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
