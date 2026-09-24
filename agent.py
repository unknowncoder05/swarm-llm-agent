#!/usr/bin/env python3
"""
swarm-llm Agent  -  Python version
Works on Windows, Linux, macOS wherever Python 3.8+ is available.

Usage (non-interactive):
    python agent.py --coordinator https://1.2.3.4:8443 --api-key abc123 --model devstral-small-2:24b

Usage (wizard):
    python agent.py
"""

import argparse
import getpass
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path
from urllib.parse import quote as urlquote
from urllib.request import urlopen, Request
from urllib.error import URLError, HTTPError

# ---------------------------------------------------------------------------
# bootstrap requests if missing
# ---------------------------------------------------------------------------
try:
    import requests
except ImportError:
    print("[*] Installing requests...")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "requests", "--quiet"])
    import requests

# ---------------------------------------------------------------------------
# global state  (set once during startup, read by threads)
# ---------------------------------------------------------------------------
_coordinator  = ""
_api_key      = ""
_model        = ""
_agent_id     = ""
_hw           = {}

# ---------------------------------------------------------------------------
# console helpers
# ---------------------------------------------------------------------------
CYAN    = "\033[96m"
GREEN   = "\033[92m"
YELLOW  = "\033[93m"
RED     = "\033[91m"
GRAY    = "\033[90m"
RESET   = "\033[0m"

def _c(color, msg): return f"{color}{msg}{RESET}" if sys.stdout.isatty() else msg

def step(msg):  print(_c(CYAN,   f"[*] {msg}"))
def ok(msg):    print(_c(GREEN,  f"[+] {msg}"))
def err(msg):   print(_c(RED,    f"[!] {msg}"))

def write_status(phase, detail=""):
    ts = time.strftime("%H:%M:%S")
    msg = f"[{ts}] {phase}  -  {detail}" if detail else f"[{ts}] {phase}"
    print(_c("\033[36m", f"  {msg}"))
    try:
        Path(tempfile.gettempdir(), "swarm-agent-status.txt").write_text(msg, encoding="utf-8")
    except Exception:
        pass
    if _coordinator and _api_key:
        try:
            requests.post(
                f"{_coordinator}/agent-status",
                json={"phase": phase, "detail": detail,
                      "agent_id": _agent_id, "hostname": socket.gethostname(),
                      "model": _model},
                headers={"X-API-Key": _api_key},
                timeout=5,
            )
        except Exception:
            pass

def show_banner():
    print()
    print(_c(CYAN, "  +-------------------------------------------------------+"))
    print(_c(CYAN, "  |         swarm-llm Agent  -  Python Edition            |"))
    print(_c(CYAN, "  |         TLS ON  |  API Key Auth ON                    |"))
    print(_c(CYAN, "  +-------------------------------------------------------+"))
    print()

# ---------------------------------------------------------------------------
# hardware detection
# ---------------------------------------------------------------------------
def detect_hardware():
    hw = {"vram_gb": 0.0, "ram_gb": 0, "gpu_name": "none",
          "cpu_name": "unknown", "cpu_cores": None, "network_mbps": None,
          "os_version": platform.platform()}
    # GPU via nvidia-smi
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=name,memory.total",
             "--format=csv,noheader,nounits"],
            stderr=subprocess.DEVNULL, text=True, encoding="utf-8", errors="replace"
        ).strip()
        parts = out.split(",")
        hw["gpu_name"] = parts[0].strip()
        hw["vram_gb"]  = round(float(parts[1].strip()) / 1024, 1)
    except Exception:
        pass
    # RAM + CPU
    try:
        import psutil
        hw["ram_gb"]   = round(psutil.virtual_memory().total / 1024**3)
        hw["cpu_cores"] = psutil.cpu_count(logical=True)
    except ImportError:
        pass
    try:
        hw["cpu_name"] = platform.processor() or "unknown"
    except Exception:
        pass
    return hw

def measure_network_speed():
    url = "https://speed.cloudflare.com/__down?bytes=5242880"
    try:
        t0 = time.time()
        r  = requests.get(url, stream=True, timeout=30)
        data = r.content
        elapsed = time.time() - t0
        if elapsed > 0 and len(data) > 0:
            return round(len(data) / elapsed / 1024**2, 2)
    except Exception:
        pass
    return None

def get_system_info(hw):
    info = dict(hw)
    info["hostname"]       = socket.gethostname()
    info["ollama_version"] = "?"
    try:
        ver = subprocess.check_output(
            ["ollama", "--version"],
            stderr=subprocess.DEVNULL, text=True,
            encoding="utf-8", errors="replace"
        ).strip()
        info["ollama_version"] = re.sub(r"ollama version (is )?", "", ver).strip()
    except Exception:
        pass
    return info

# ---------------------------------------------------------------------------
# model catalog / VRAM helpers
# ---------------------------------------------------------------------------
_MODEL_VRAM = {
    "devstral-small-2:24b": 15.0,
    "qwen3.6:27b":          17.0,
    "qwen3:30b-a3b":        17.0,
    "qwen3:14b":             9.3,
    "gemma4:12b":            8.0,
    "qwen3:8b":              5.2,
}

_MODEL_CATALOG = [
    {"id": "qwen3:8b",             "vram": 5.2 },
    {"id": "gemma4:12b",           "vram": 8.0 },
    {"id": "qwen3:14b",            "vram": 9.3 },
    {"id": "devstral-small-2:24b", "vram": 15.0},
    {"id": "qwen3.6:27b",          "vram": 17.0},
    {"id": "qwen3:30b-a3b",        "vram": 17.0},
]

def model_vram(model):
    if model in _MODEL_VRAM:
        return _MODEL_VRAM[model]
    m = re.search(r":(\d+\.?\d*)b", model, re.I)
    if m:
        return round(float(m.group(1)) * 0.65, 1)
    return 5.0

def recommended_model_index(vram_gb):
    if   vram_gb >= 18: return 5
    elif vram_gb >= 16: return 3
    elif vram_gb >= 12: return 2
    elif vram_gb >=  8: return 1
    else:               return 0

def ollama_parallel(vram_gb, model):
    if vram_gb <= 0:
        return 1
    model_v = {
        "devstral-small-2:24b": 15, "qwen3.6:27b": 17, "qwen3:14b": 9,
        "gemma4:12b": 8, "qwen3:8b": 5,
    }.get(model, int(vram_gb * 0.65))
    free = vram_gb - model_v - 2
    return max(1, min(4, 1 + int(free // 4)))

# ---------------------------------------------------------------------------
# agent ID
# ---------------------------------------------------------------------------
def get_agent_id():
    id_file = Path(tempfile.gettempdir()) / "swarm-agent-id.txt"
    if id_file.exists():
        val = id_file.read_text().strip()
        if re.match(r"^[0-9a-f-]{36}$", val):
            return val
    val = str(uuid.uuid4())
    id_file.write_text(val, encoding="utf-8")
    return val

# ---------------------------------------------------------------------------
# Ollama management
# ---------------------------------------------------------------------------
def find_ollama():
    if shutil.which("ollama"):
        return shutil.which("ollama")
    candidates = []
    if platform.system() == "Windows":
        local = os.environ.get("LOCALAPPDATA", "")
        profile = os.environ.get("USERPROFILE", "")
        candidates = [
            os.path.join(local,   "Programs", "Ollama", "ollama.exe"),
            os.path.join(profile, "AppData", "Local", "Programs", "Ollama", "ollama.exe"),
            os.path.join(tempfile.gettempdir(), "ollama", "ollama.exe"),
        ]
    else:
        candidates = ["/usr/local/bin/ollama", "/usr/bin/ollama",
                      str(Path.home() / ".ollama" / "ollama")]
    for c in candidates:
        if os.path.isfile(c):
            return c
    return None

def install_ollama():
    if platform.system() == "Windows":
        return _install_ollama_windows()
    else:
        return _install_ollama_unix()

def _install_ollama_unix():
    step("Installing Ollama via install script...")
    write_status("INSTALLING", "running ollama install script")
    try:
        subprocess.run(
            "curl -fsSL https://ollama.ai/install.sh | sh",
            shell=True, check=True
        )
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"Ollama install failed: {e}")
    path = find_ollama()
    if not path:
        raise RuntimeError("Ollama not found after install")
    ok(f"Ollama ready at: {path}")
    return path

def _install_ollama_windows():
    local = os.environ.get("LOCALAPPDATA", tempfile.gettempdir())
    cache_dir   = os.path.join(local, "swarm-llm")
    install_dir = os.path.join(local, "Programs", "Ollama")
    os.makedirs(cache_dir,   exist_ok=True)
    os.makedirs(install_dir, exist_ok=True)
    zip_file = os.path.join(cache_dir, "ollama-windows-amd64.zip")

    # Try coordinator mirror first
    mirror_url   = f"{_coordinator}/ollama/ollama-windows-amd64.zip"
    official_url = "https://github.com/ollama/ollama/releases/latest/download/ollama-windows-amd64.zip"
    download_url = official_url
    try:
        r = requests.head(mirror_url, timeout=4)
        if r.status_code == 200:
            download_url = mirror_url
            step("Using coordinator mirror for Ollama download")
    except Exception:
        pass

    for attempt in range(3):
        try:
            step(f"Downloading Ollama from {download_url} ...")
            write_status("INSTALLING", "downloading Ollama...")
            with requests.get(download_url, stream=True, timeout=300) as r:
                r.raise_for_status()
                downloaded = 0
                with open(zip_file, "wb") as f:
                    for chunk in r.iter_content(65536):
                        f.write(chunk)
                        downloaded += len(chunk)
                        if downloaded % (5 * 1024**2) < 65536:
                            write_status("INSTALLING", f"downloading Ollama... {downloaded // 1024**2} MB")
            break
        except Exception as e:
            if attempt >= 2:
                raise RuntimeError(f"Download failed after 3 attempts: {e}")
            err(f"Retrying ({attempt+1}/3)...")
            time.sleep(2)

    step(f"Extracting to {install_dir} ...")
    write_status("INSTALLING", "extracting Ollama...")
    import zipfile
    with zipfile.ZipFile(zip_file) as z:
        z.extractall(install_dir)

    path = find_ollama()
    if not path:
        raise RuntimeError(f"Ollama not found after extract - check {install_dir}")
    ok(f"Ollama ready at: {path}")
    return path

def wait_ollama_ready(port, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            r = requests.get(f"http://127.0.0.1:{port}/api/tags", timeout=2)
            if r.status_code == 200:
                return True
        except Exception:
            pass
        time.sleep(1)
    return False

def pull_model(ollama_exe, model, port):
    step(f"Pulling '{model}' (instant if already cached)...")
    env = dict(os.environ, OLLAMA_HOST=f"127.0.0.1:{port}")
    proc = subprocess.Popen(
        [ollama_exe, "pull", model],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, encoding="utf-8", errors="replace", env=env
    )
    last_report = 0
    for line in proc.stdout:
        line = line.rstrip()
        print(line)
        m = re.search(r"(\d+)%", line)
        if m and time.time() - last_report >= 5:
            speed = ""
            sm = re.search(r"([\d.]+ [MG]B/s)", line)
            if sm:
                speed = f"  {sm.group(1)}"
            write_status("DOWNLOADING", f"{m.group(1)}%{speed}  -  {model}")
            last_report = time.time()
    proc.wait()
    if proc.returncode != 0:
        raise RuntimeError(f"Failed to pull '{model}'")
    ok(f"Model '{model}' ready.")

# ---------------------------------------------------------------------------
# coordinator comms
# ---------------------------------------------------------------------------
def get_local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"

def register(coordinator, api_key, port, model, hw):
    info = get_system_info(hw)
    body = {
        "agent_id":       _agent_id,
        "port":           port,
        "model":          model,
        "hostname":       info.get("hostname"),
        "cpu_name":       info.get("cpu_name"),
        "cpu_cores":      info.get("cpu_cores"),
        "ram_total_gb":   info.get("ram_gb"),
        "ram_free_gb":    None,
        "gpu_name":       info.get("gpu_name") if info.get("gpu_name") != "none" else None,
        "gpu_vram_gb":    info.get("vram_gb") if info.get("vram_gb", 0) > 0 else None,
        "network_mbps":   info.get("network_mbps"),
        "ollama_version": info.get("ollama_version"),
        "os_version":     info.get("os_version"),
    }
    r = requests.post(
        f"{coordinator}/register", json=body,
        headers={"X-API-Key": api_key}, timeout=15
    )
    r.raise_for_status()
    data = r.json()
    ok(f"Registered. Total machines: {data.get('machines_total', '?')}")

def test_coordinator(coordinator, api_key):
    step(f"Connecting to coordinator at {coordinator} ...")
    try:
        r = requests.get(f"{coordinator}/healthz", timeout=8)
        if r.status_code != 200:
            raise RuntimeError(f"unexpected status {r.status_code}")
    except Exception as e:
        err(f"Cannot reach coordinator at {coordinator}")
        err(f"Check the URL and make sure the server is running. ({e})")
        return False
    step("Validating API key ...")
    try:
        r = requests.post(
            f"{coordinator}/agent-status",
            json={"phase": "CONNECTING", "detail": "", "agent_id": _agent_id,
                  "hostname": socket.gethostname(), "model": _model},
            headers={"X-API-Key": api_key}, timeout=8
        )
        if r.status_code == 401:
            err("API key rejected (401)  -  check the key and try again.")
            return False
        r.raise_for_status()
    except requests.HTTPError:
        return False
    except Exception as e:
        err(f"Key validation failed: {e}")
        return False
    ok("Connected  -  key valid.")
    return True

# ---------------------------------------------------------------------------
# inference
# ---------------------------------------------------------------------------
def infer(port, body_json, job_id="", coordinator="", api_key=""):
    spinners = ["-", "\\", "|", "/"]
    result   = [None]
    error    = [None]

    def _run():
        try:
            r = requests.post(
                f"http://127.0.0.1:{port}/api/chat",
                data=body_json.encode(),
                headers={"Content-Type": "application/json"},
                timeout=1800,
            )
            r.raise_for_status()
            result[0] = r.text
        except Exception as e:
            error[0] = str(e)

    t = threading.Thread(target=_run, daemon=True)
    t.start()

    frame = 0
    last_cancel = 0
    thoughts = [
        "crunching tokens   ", "hot take incoming  ", "brb, doing math    ",
        "yes this is fast   ", "GPU go brrrr       ", "almost there...    ",
    ]
    t0 = time.time()

    while t.is_alive():
        elapsed = int(time.time() - t0)
        spin    = spinners[frame % 4]
        think   = thoughts[(frame // 4) % len(thoughts)]
        sys.stdout.write(f"\r  {spin}  [{think}]  {elapsed}s  ")
        sys.stdout.flush()

        # Cancel check every ~5s
        if job_id and coordinator and time.time() - last_cancel >= 5:
            last_cancel = time.time()
            try:
                cr = requests.get(
                    f"{coordinator}/agent/jobs/{job_id}/cancelled",
                    headers={"X-API-Key": api_key}, timeout=3
                )
                if cr.status_code == 200 and cr.json().get("cancelled"):
                    t.join(timeout=2)
                    sys.stdout.write("\r" + " " * 60 + "\r")
                    raise RuntimeError(f"Job {job_id} cancelled by coordinator")
            except RuntimeError:
                raise
            except Exception:
                pass

        frame += 1
        time.sleep(0.15)

    sys.stdout.write("\r" + " " * 60 + "\r")
    sys.stdout.flush()

    if error[0]:
        raise RuntimeError(error[0])
    return result[0]

# ---------------------------------------------------------------------------
# media work loop  (runs in a background thread)
# ---------------------------------------------------------------------------
MEDIA_INFER_PY = r'''
import argparse, os, sys, time, warnings
warnings.filterwarnings("ignore", category=FutureWarning)

def _load(model_id, pipeline_cls, dtype, token=None, **kw):
    """Load pipeline fully onto GPU. Use when model fits in VRAM."""
    import torch
    if not torch.cuda.is_available():
        raise RuntimeError(
            f"CUDA unavailable (torch {torch.__version__} — CPU-only build). "
            "Re-run the agent to reinstall torch with CUDA support."
        )
    return pipeline_cls.from_pretrained(
        model_id, dtype=dtype, token=token or None, **kw
    ).to("cuda")

def _load_offload(model_id, pipeline_cls, dtype, token=None, **kw):
    """Load pipeline with CPU offload. Mutually exclusive with .to('cuda')."""
    import torch
    if not torch.cuda.is_available():
        raise RuntimeError(
            f"CUDA unavailable (torch {torch.__version__} — CPU-only build). "
            "Re-run the agent to reinstall torch with CUDA support."
        )
    pipe = pipeline_cls.from_pretrained(
        model_id, dtype=dtype, token=token or None, **kw
    )
    pipe.enable_model_cpu_offload()
    return pipe

def run_image(model, prompt, neg, out_dir, n, size, quality, token=None):
    import torch
    w, h = map(int, size.split("x"))
    os.makedirs(out_dir, exist_ok=True)

    if model == "flux-schnell":
        from diffusers import FluxPipeline
        pipe = _load("black-forest-labs/FLUX.1-schnell", FluxPipeline, torch.bfloat16, token)
        images = pipe(prompt=prompt, num_inference_steps=4, guidance_scale=0.0,
                      width=w, height=h, num_images_per_prompt=n).images

    elif model == "flux-dev":
        from diffusers import FluxPipeline
        pipe = _load("black-forest-labs/FLUX.1-dev", FluxPipeline, torch.bfloat16, token)
        images = pipe(prompt=prompt, num_inference_steps=20, guidance_scale=3.5,
                      width=w, height=h, num_images_per_prompt=n).images

    elif model == "sd3.5-medium":
        from diffusers import StableDiffusion3Pipeline
        pipe = _load("stabilityai/stable-diffusion-3.5-medium",
                     StableDiffusion3Pipeline, torch.bfloat16, token)
        images = pipe(prompt=prompt, negative_prompt=neg or None,
                      num_inference_steps=28, guidance_scale=7.0,
                      width=w, height=h, num_images_per_prompt=n).images

    elif model == "sdxl":
        from diffusers import StableDiffusionXLPipeline, StableDiffusionXLImg2ImgPipeline
        # SDXL requires base + refiner; base alone produces low-quality images.
        # enable_model_cpu_offload handles VRAM — do NOT call .to("cuda") with it.
        base = _load_offload(
            "stabilityai/stable-diffusion-xl-base-1.0",
            StableDiffusionXLPipeline, torch.float16, token,
            use_safetensors=True, variant="fp16",
        )
        refiner = _load_offload(
            "stabilityai/stable-diffusion-xl-refiner-1.0",
            StableDiffusionXLImg2ImgPipeline, torch.float16, token,
            use_safetensors=True, variant="fp16",
        )
        default_neg = ("worst quality, low quality, blurry, watermark, "
                       "ugly, distorted, deformed, noise")
        neg_prompt = neg if neg else default_neg
        steps, guidance, denoise_frac = 40, 7.5, 0.8

        images = []
        for _ in range(n):
            # Base generates low-frequency structure as a latent
            latent = base(
                prompt=prompt, negative_prompt=neg_prompt,
                num_inference_steps=steps, guidance_scale=guidance,
                denoising_end=denoise_frac,
                output_type="latent",
                width=w, height=h,
            ).images
            # Refiner adds fine detail
            img = refiner(
                prompt=prompt, negative_prompt=neg_prompt,
                num_inference_steps=steps, guidance_scale=guidance,
                denoising_start=denoise_frac,
                image=latent,
            ).images[0]
            images.append(img)

    else:
        sys.exit(f"Unknown image model: {model}")

    for i, img in enumerate(images):
        fp = os.path.join(out_dir, f"img_{i}_{int(time.time())}.png")
        img.save(fp)
        print(fp, flush=True)

def run_video(model, prompt, neg, out_file, duration, width, height, token=None):
    import torch
    if model == "ltx-video":
        from diffusers import LTXPipeline
        pipe = _load("Lightricks/LTX-Video", LTXPipeline, torch.bfloat16, token)
        result = pipe(prompt=prompt, negative_prompt=neg or None,
                      width=width, height=height,
                      num_frames=duration * 8 + 1, num_inference_steps=50)
    elif model == "cogvideox-2b":
        from diffusers import CogVideoXPipeline
        pipe = _load("THUDM/CogVideoX-2b", CogVideoXPipeline, torch.bfloat16, token)
        # CogVideoX is trained at 720x480, 49 frames (6s). Resolution is not adjustable.
        result = pipe(prompt=prompt, num_inference_steps=50,
                      num_frames=49, guidance_scale=6,
                      width=720, height=480)
    elif model == "cogvideox-5b":
        from diffusers import CogVideoXPipeline
        pipe = _load("THUDM/CogVideoX-5b", CogVideoXPipeline, torch.bfloat16, token)
        result = pipe(prompt=prompt, num_inference_steps=50,
                      num_frames=49, guidance_scale=6,
                      width=720, height=480)
    elif model == "wan-2.1-t2v-1.3b":
        from diffusers import WanPipeline
        pipe = _load("Wan-AI/Wan2.1-T2V-1.3B-Diffusers", WanPipeline, torch.bfloat16, token)
        result = pipe(prompt=prompt, negative_prompt=neg or None,
                      height=height, width=width,
                      num_frames=duration * 16, guidance_scale=5.0)
    else:
        sys.exit(f"Unknown video model: {model}")
    frames = result.frames[0]
    import numpy as np, imageio
    frames_np = [np.array(f) for f in frames]
    os.makedirs(os.path.dirname(os.path.abspath(out_file)), exist_ok=True)
    imageio.mimwrite(out_file, frames_np, fps=8, quality=8)
    print(out_file, flush=True)

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--type",      required=True, choices=["image", "video"])
    p.add_argument("--model",     required=True)
    p.add_argument("--prompt",    required=True)
    p.add_argument("--neg",       default="")
    p.add_argument("--hf-token",  default="")
    p.add_argument("--out-dir",   default=".")
    p.add_argument("--out-file",  default="out.mp4")
    p.add_argument("--n",         type=int, default=1)
    p.add_argument("--size",      default="1024x1024")
    p.add_argument("--quality",   default="standard")
    p.add_argument("--duration",  type=int, default=5)
    p.add_argument("--width",     type=int, default=512)
    p.add_argument("--height",    type=int, default=512)
    a = p.parse_args()
    tok = a.hf_token or os.environ.get("HF_TOKEN", "")
    if a.type == "image":
        run_image(a.model, a.prompt, a.neg, a.out_dir, a.n, a.size, a.quality, tok)
    else:
        run_video(a.model, a.prompt, a.neg, a.out_file, a.duration, a.width, a.height, tok)
'''

def _cuda_install_candidates():
    """Return ordered list of (description, pip_extra_args) to try for a CUDA torch build."""
    candidates = []
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=driver_version", "--format=csv,noheader"],
            stderr=subprocess.DEVNULL, text=True, encoding="utf-8", errors="replace"
        ).strip().split("\n")[0]
        driver = float(out.split(".")[0])
        # driver → CUDA toolkit version mapping (newest compat first)
        if driver >= 570:
            tags = ["cu128", "cu126", "cu124"]
        elif driver >= 560:
            tags = ["cu126", "cu124"]
        elif driver >= 550:
            tags = ["cu124", "cu126"]
        elif driver >= 525:
            tags = ["cu121", "cu124"]
        elif driver >= 450:
            tags = ["cu118"]
        else:
            return candidates
        for tag in tags:
            stable  = f"https://download.pytorch.org/whl/{tag}"
            nightly = f"https://download.pytorch.org/whl/nightly/{tag}"
            candidates.append((f"stable/{tag}",  ["--index-url", stable]))
            candidates.append((f"nightly/{tag}", ["--index-url", nightly, "--pre"]))
    except Exception:
        pass
    return candidates

def _torch_has_cuda(python_exe=None):
    """Spawn a fresh subprocess to check torch.cuda.is_available() (avoids import cache)."""
    exe = python_exe or sys.executable
    try:
        r = subprocess.run(
            [exe, "-c",
             "import torch; print('1' if torch.cuda.is_available() else '0')"],
            capture_output=True, text=True, timeout=30,
            encoding="utf-8", errors="replace"
        )
        return r.stdout.strip() == "1"
    except Exception:
        return False

def _find_cuda_python():
    """Return the Python executable that has CUDA-enabled torch.

    On Python 3.14+ Windows, PyTorch has no CUDA wheels — try the Windows
    Python Launcher (py -3.12 / py -3.13 / py -3.11) which likely has an
    older Python where CUDA wheels exist.
    """
    if _torch_has_cuda():
        return sys.executable
    if platform.system() == "Windows":
        for ver in ["3.12", "3.13", "3.11", "3.10"]:
            try:
                r = subprocess.run(
                    ["py", f"-{ver}", "-c", "import sys; print(sys.executable)"],
                    capture_output=True, text=True, timeout=10,
                    encoding="utf-8", errors="replace"
                )
                if r.returncode != 0 or not r.stdout.strip():
                    continue
                exe = r.stdout.strip()
                if _torch_has_cuda(exe):
                    step(f"  py -{ver} has CUDA torch — using {exe} for inference")
                    return exe
            except Exception:
                pass
    return sys.executable  # no better option found

def _pip_install(pkgs, extra_args=None, python_exe=None):
    exe = python_exe or sys.executable
    cmd = [exe, "-m", "pip", "install", "--quiet"] + pkgs
    if extra_args:
        cmd += extra_args
    subprocess.check_call(cmd, stderr=subprocess.STDOUT)

def install_media_deps(python_exe=None):
    exe = python_exe or sys.executable
    step(f"Checking media deps for {exe} ...")

    if _torch_has_cuda(exe):
        step("  torch already has CUDA — skipping reinstall")
    else:
        torch_ok = False
        for desc, extra in _cuda_install_candidates():
            step(f"  torch: trying {desc} ...")
            try:
                _pip_install(["torch", "torchvision"],
                             extra + ["--force-reinstall", "--no-deps"],
                             python_exe=exe)
                if _torch_has_cuda(exe):
                    step(f"  CUDA torch installed via {desc}")
                    torch_ok = True
                    break
                step(f"  {desc}: still CPU-only, trying next index...")
            except subprocess.CalledProcessError:
                step(f"  {desc}: pip failed, trying next index...")

        if not torch_ok:
            step("  torch: all CUDA indexes failed, falling back to PyPI...")
            try:
                _pip_install(["torch", "torchvision"],
                             ["--force-reinstall", "--no-deps"],
                             python_exe=exe)
            except subprocess.CalledProcessError:
                err("torch install failed  -  media inference disabled")

    for group in [
        ["diffusers", "transformers", "accelerate", "safetensors", "huggingface_hub"],
        ["imageio[ffmpeg]", "sentencepiece", "protobuf"],
    ]:
        step(f"pip install {group[0]} ...")
        try:
            _pip_install(group, ["--upgrade"], python_exe=exe)
        except subprocess.CalledProcessError as e:
            err(f"pip install {group[0]} failed: {e}")

    ok("Media deps ready.")

def _media_loop(coordinator, api_key, agent_id, vram_gb, infer_py_path, hf_token=""):
    headers         = {"X-API-Key": api_key}
    deps_installed  = False
    infer_python    = sys.executable   # may be updated to py -3.12 etc. after deps check
    aid_enc         = urlquote(agent_id)
    last_status_log = 0
    STATUS_INTERVAL = 60

    print(_c(CYAN, f"  [media] thread started  -  {vram_gb} GB VRAM  -  polling {coordinator}"))

    while True:
        # ── poll coordinator ──────────────────────────────────────────────────
        try:
            r = requests.get(
                f"{coordinator}/agent/media/jobs/next?vram_gb={vram_gb}&agent_id={aid_enc}",
                headers=headers, timeout=8
            )
        except Exception as e:
            ts = time.strftime("%H:%M:%S")
            print(_c(YELLOW, f"  [media] [{ts}] coordinator unreachable: {e}  -  retrying in 5s"))
            time.sleep(5)
            continue

        if r.status_code == 204:
            if time.time() - last_status_log >= STATUS_INTERVAL:
                ts = time.strftime("%H:%M:%S")
                print(f"  [media] [{ts}] idle  -  no jobs queued for {vram_gb} GB VRAM")
                last_status_log = time.time()
            time.sleep(3)
            continue
        if r.status_code != 200:
            print(_c(YELLOW, f"  [media] unexpected status {r.status_code}, retrying..."))
            time.sleep(5)
            continue

        # ── got a job ─────────────────────────────────────────────────────────
        last_status_log = time.time()
        job      = r.json()
        job_id   = job["id"]
        job_type = job["type"]
        model    = job["model"]
        body     = json.loads(job["body_json"])
        print(_c(CYAN, f"  [media] {job_type} job {job_id[:8]}  -  model={model}"))

        # ── lazy deps install ─────────────────────────────────────────────────
        if not deps_installed:
            print(_c(YELLOW, "  [media] installing deps (first job)..."))
            try:
                install_media_deps()                   # install for sys.executable first
                infer_python = _find_cuda_python()     # may fall back to py -3.12 etc.
                if infer_python != sys.executable:
                    install_media_deps(infer_python)   # ensure deps present in that env
                if not _torch_has_cuda(infer_python):
                    raise RuntimeError(
                        f"no CUDA torch found in any available Python — "
                        "install torch with CUDA support manually"
                    )
                deps_installed = True
                print(_c(GREEN, f"  [media] deps ready  python={infer_python}"))
            except Exception as deps_err:
                print(_c(RED, f"  [media] deps failed: {deps_err}"))
                try:
                    requests.post(
                        f"{coordinator}/agent/media/jobs/{job_id}/error?job_type={job_type}",
                        json={"error": str(deps_err)}, headers=headers, timeout=10
                    )
                except Exception:
                    pass
                time.sleep(5)
                continue  # back to polling; next job will retry install

        # ── run inference ─────────────────────────────────────────────────────
        tmp_dir = Path(tempfile.gettempdir()) / "swarm-media"
        tmp_dir.mkdir(exist_ok=True)
        t0 = time.time()

        try:
            if job_type == "image":
                out_dir = tmp_dir / job_id
                out_dir.mkdir(exist_ok=True)
                cmd = [infer_python, str(infer_py_path),
                       "--type", "image", "--model", model,
                       "--prompt", body["prompt"],
                       "--n", str(body.get("n", 1)),
                       "--size", body.get("size", "1024x1024"),
                       "--quality", body.get("quality", "standard"),
                       "--out-dir", str(out_dir)]
                if body.get("negative_prompt"):
                    cmd += ["--neg", body["negative_prompt"]]
                if hf_token:
                    cmd += ["--hf-token", hf_token]
                proc = subprocess.run(cmd, capture_output=True, text=True,
                                      encoding="utf-8", errors="replace")
                if proc.returncode != 0:
                    raise RuntimeError(f"inference error: {proc.stderr}")
                out_paths = [l.strip() for l in proc.stdout.splitlines()
                             if l.strip() and os.path.isfile(l.strip())]
                if not out_paths:
                    raise RuntimeError("no output files produced")
                out_file = out_paths[0]
                ms  = int((time.time() - t0) * 1000)
                ext = Path(out_file).suffix.lstrip(".")
                data = open(out_file, "rb").read()
                requests.post(
                    f"{coordinator}/agent/media/jobs/{job_id}/result"
                    f"?job_type=image&ext={ext}&elapsed_ms={ms}",
                    data=data, headers={**headers, "Content-Type": "application/octet-stream"},
                    timeout=120
                ).raise_for_status()
                print(f"  [media] image done {ms/1000:.1f}s  {len(data)/1024**2:.1f} MB")
            else:
                out_file = str(tmp_dir / f"{job_id}.mp4")
                cmd = [infer_python, str(infer_py_path),
                       "--type", "video", "--model", model,
                       "--prompt", body["prompt"],
                       "--duration", str(body.get("duration", 5)),
                       "--width",    str(body.get("width",  512)),
                       "--height",   str(body.get("height", 512)),
                       "--out-file", out_file]
                if body.get("negative_prompt"):
                    cmd += ["--neg", body["negative_prompt"]]
                if hf_token:
                    cmd += ["--hf-token", hf_token]
                proc = subprocess.run(cmd, capture_output=True, text=True,
                                      encoding="utf-8", errors="replace")
                if proc.returncode != 0:
                    raise RuntimeError(f"inference error: {proc.stderr}")
                ms   = int((time.time() - t0) * 1000)
                data = open(out_file, "rb").read()
                requests.post(
                    f"{coordinator}/agent/media/jobs/{job_id}/result"
                    f"?job_type=video&ext=mp4&elapsed_ms={ms}",
                    data=data, headers={**headers, "Content-Type": "application/octet-stream"},
                    timeout=600
                ).raise_for_status()
                print(f"  [media] video done {ms/1000:.1f}s  {len(data)/1024**2:.1f} MB")
        except Exception as e:
            err_msg = str(e)
            print(_c(RED, f"  [media] job {job_id[:8]} failed: {err_msg}"))
            try:
                requests.post(
                    f"{coordinator}/agent/media/jobs/{job_id}/error?job_type={job_type}",
                    json={"error": err_msg}, headers=headers, timeout=10
                )
            except Exception:
                pass

def start_media_loop(coordinator, api_key, agent_id, vram_gb, hf_token=""):
    tmp_dir    = Path(tempfile.gettempdir()) / "swarm-media"
    tmp_dir.mkdir(exist_ok=True)
    infer_path = tmp_dir / "infer.py"
    infer_path.write_text(MEDIA_INFER_PY, encoding="utf-8")

    t = threading.Thread(
        target=_media_loop,
        args=(coordinator, api_key, agent_id, vram_gb, infer_path, hf_token),
        daemon=True,
    )
    t.start()
    return t

# ---------------------------------------------------------------------------
# main work loop
# ---------------------------------------------------------------------------
def work_loop(ollama_exe, coordinator, api_key, port, vram_gb):
    global _model, _hw
    headers    = {"X-API-Key": api_key}
    vram_limit = max(6.0, vram_gb - 1.0)
    last_hb    = 0

    # Pre-populate pulled models from local ollama list
    pulled = set()
    try:
        env = dict(os.environ, OLLAMA_HOST=f"127.0.0.1:{port}")
        out = subprocess.check_output(
            [ollama_exe, "list"], stderr=subprocess.DEVNULL, text=True,
            encoding="utf-8", errors="replace", env=env
        )
        for line in out.splitlines()[1:]:
            name = line.split()[0] if line.split() else ""
            if name:
                pulled.add(name)
        if pulled:
            step(f"Already on disk: {', '.join(pulled)}")
    except Exception:
        pass

    write_status("RUNNING", f"accepting any model that fits in {vram_gb} GB VRAM  -  Ctrl+C to quit")

    while True:
        # Heartbeat every 15s
        if time.time() - last_hb >= 15:
            try:
                r = requests.post(
                    f"{coordinator}/heartbeat",
                    json={"port": port, "agent_id": _agent_id},
                    headers=headers, timeout=8
                )
                if r.status_code == 404:
                    print(_c(YELLOW, f"[{time.strftime('%H:%M:%S')}] Coordinator restarted, re-registering..."))
                    try:
                        register(coordinator, api_key, port, _model, _hw)
                    except Exception:
                        pass
            except Exception:
                pass
            last_hb = time.time()

        # Ask coordinator which models have queued jobs
        candidates = []
        try:
            r = requests.get(
                f"{coordinator}/agent/jobs/queued-models",
                headers=headers, timeout=8
            )
            r.raise_for_status()
            candidates = [m for m in r.json().get("models", [])
                          if model_vram(m) <= vram_limit]
        except Exception:
            pass

        served = False
        for model in candidates:
            model_enc = urlquote(model)

            # Pull on demand
            if model not in pulled:
                write_status("DOWNLOADING", f"demand detected  -  pulling {model}")
                try:
                    pull_model(ollama_exe, model, port)
                    pulled.add(model)
                    _model = model
                    try:
                        register(coordinator, api_key, port, model, _hw)
                    except Exception:
                        pass
                except Exception as e:
                    err_msg = f"Pull failed for {model}: {e}"
                    err(err_msg)
                    try:
                        requests.post(
                            f"{coordinator}/agent-status",
                            json={"phase": "RUNNING", "detail": err_msg,
                                  "agent_id": _agent_id, "hostname": socket.gethostname(),
                                  "model": model},
                            headers=headers, timeout=5
                        )
                    except Exception:
                        pass
                    continue

            # Pick up a job
            try:
                agent_id_enc = urlquote(_agent_id)
                r = requests.get(
                    f"{coordinator}/agent/jobs/next?model={model_enc}&agent_id={agent_id_enc}",
                    headers=headers, timeout=10
                )
                if r.status_code != 200:
                    continue

                job          = r.json()
                job_id       = job["id"]
                job_body_json = job["body_json"]
                ts = time.strftime("%H:%M:%S")
                print(_c("\033[36m", f"[{ts}] Job {job_id}  model={model}"))

                t0 = time.time()
                try:
                    raw_result = infer(port, job_body_json, job_id, coordinator, api_key)
                    ms         = round((time.time() - t0) * 1000, 1)
                    post_body  = f'{{"result":{raw_result},"elapsed_ms":{ms}}}'
                    requests.post(
                        f"{coordinator}/agent/jobs/{job_id}/result",
                        data=post_body.encode(),
                        headers={**headers, "Content-Type": "application/json"},
                        timeout=30
                    )
                    ok(f"Job {job_id} done in {ms/1000:.1f}s")
                except Exception as e:
                    err(f"Job {job_id} failed: {e}")
                    try:
                        requests.post(
                            f"{coordinator}/agent/jobs/{job_id}/result",
                            json={"error": str(e)},
                            headers=headers, timeout=10
                        )
                    except Exception:
                        pass

                served = True
                break
            except Exception:
                pass  # poll error, skip

        if not served:
            time.sleep(2)

# ---------------------------------------------------------------------------
# interactive wizard
# ---------------------------------------------------------------------------
def run_wizard():
    show_banner()
    step("Detecting hardware...")
    hw = detect_hardware()

    print()
    print(_c(YELLOW, "  Detected hardware:"))
    print(f"    CPU  : {hw['cpu_name']}")
    print(f"    RAM  : {hw['ram_gb']} GB")
    if hw["vram_gb"] > 0:
        print(_c(GREEN, f"    GPU  : {hw['gpu_name']} ({hw['vram_gb']} GB VRAM)"))
    else:
        print(_c(YELLOW, "    GPU  : none detected  (CPU inference)"))
    print()

    rec_idx   = recommended_model_index(hw["vram_gb"])
    chosen_id = _MODEL_CATALOG[rec_idx]["id"]
    print(_c(GREEN,  f"  Default model  : {chosen_id}  (auto-selected for {hw['vram_gb']} GB VRAM)"))
    print(_c(GRAY,   "  Other models   : pulled on demand when a job requests them"))
    print()

    coord_url = input(_c(YELLOW, "  Coordinator URL (e.g. https://1.2.3.4:8443): ")).strip().rstrip("/")
    api_key   = getpass.getpass(_c(YELLOW, "  API Key: "))

    print()
    print("  Local Ollama port:")
    port_choices = [11434, 11435, 11436, 11437]
    for i, p in enumerate(port_choices):
        suffix = "  (default)" if i == 0 else ""
        print(f"    [{i+1}] {p}{suffix}")
    port_in = input("  Choice [1]: ").strip()
    try:
        port = port_choices[int(port_in) - 1] if port_in else 11434
    except (ValueError, IndexError):
        port = 11434

    return {"model": chosen_id, "coordinator": coord_url,
            "api_key": api_key, "port": port, "hw": hw}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------
def main():
    global _coordinator, _api_key, _model, _agent_id, _hw

    parser = argparse.ArgumentParser(description="swarm-llm agent")
    parser.add_argument("--coordinator",     default="")
    parser.add_argument("--api-key",         default="")
    parser.add_argument("--model",           default="")
    parser.add_argument("--port",            type=int, default=11434)
    parser.add_argument("--skip-model-pull", action="store_true")
    parser.add_argument("--hf-token",        default="",
                        help="HuggingFace token for gated models (FLUX, SD3). "
                             "Also read from HF_TOKEN env var.")
    args = parser.parse_args()

    _agent_id = get_agent_id()

    interactive = not (args.coordinator and args.api_key and args.model)
    if interactive:
        cfg             = run_wizard()
        args.coordinator = cfg["coordinator"]
        args.api_key     = cfg["api_key"]
        args.model       = cfg["model"]
        args.port        = cfg["port"]
        hw               = cfg["hw"]
    else:
        hw = detect_hardware()
        show_banner()
        print(_c(YELLOW, f"  Model: {args.model}  |  Coordinator: {args.coordinator}"))
        print()

    _coordinator = args.coordinator
    _api_key     = args.api_key
    _model       = args.model
    _hw          = hw

    # 1. Verify coordinator
    if not test_coordinator(args.coordinator, args.api_key):
        sys.exit(1)

    # 2. Ensure Ollama
    ollama_exe = find_ollama()
    if not ollama_exe:
        ollama_exe = install_ollama()
    else:
        ok(f"Ollama found at: {ollama_exe}")

    # 3. Kill any existing Ollama on this port
    if platform.system() != "Windows":
        try:
            out = subprocess.check_output(
                ["lsof", "-ti", f"tcp:{args.port}"],
                stderr=subprocess.DEVNULL, text=True,
                encoding="utf-8", errors="replace"
            ).strip()
            if out:
                step(f"Stopping existing Ollama on port {args.port} ...")
                subprocess.run(["kill", "-9"] + out.split(), check=False)
                time.sleep(2)
        except Exception:
            pass
    else:
        try:
            out = subprocess.check_output(
                ["netstat", "-ano"], text=True, stderr=subprocess.DEVNULL,
                encoding="utf-8", errors="replace"
            )
            for line in out.splitlines():
                if f":{args.port}" in line and "LISTENING" in line:
                    pid = line.split()[-1]
                    subprocess.run(["taskkill", "/PID", pid, "/F"],
                                   check=False, capture_output=True)
            time.sleep(2)
        except Exception:
            pass

    # 4. Start Ollama server
    write_status("STARTING", f"Ollama server on port {args.port}")
    parallel = ollama_parallel(hw["vram_gb"], args.model)
    env = dict(os.environ,
               OLLAMA_HOST=f"0.0.0.0:{args.port}",
               OLLAMA_FLASH_ATTENTION="1",
               OLLAMA_KV_CACHE_TYPE="q8_0",
               OLLAMA_NUM_PARALLEL=str(parallel))
    step(f"Parallel slots: {parallel} (VRAM: {hw['vram_gb']} GB, model: {args.model})")
    popen_kwargs = dict(env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if platform.system() == "Windows":
        popen_kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
    server_proc = subprocess.Popen([ollama_exe, "serve"], **popen_kwargs)

    step("Waiting for Ollama to be ready...")
    if not wait_ollama_ready(args.port, 60):
        raise RuntimeError("Ollama did not start within 60 seconds")
    ok(f"Ollama up (PID {server_proc.pid})")

    # 5. Network speed test
    step("Measuring network speed (5 MB test)...")
    hw["network_mbps"] = measure_network_speed()
    if hw["network_mbps"]:
        ok(f"Network speed: {hw['network_mbps']} MB/s")
    else:
        step("Speed test failed  -  skipping")

    # 6. Pull default model
    if not args.skip_model_pull:
        speed_tag = f"{hw['network_mbps']} MB/s  |  " if hw["network_mbps"] else ""
        write_status("DOWNLOADING", f"{speed_tag}starting pull  -  {args.model}")
        pull_model(ollama_exe, args.model, args.port)

    # 7. Register
    write_status("REGISTERING", "")
    register(args.coordinator, args.api_key, args.port, args.model, hw)

    # 8. Media loop (always on; deps installed lazily on first job; skipped if no GPU)
    hf_token = args.hf_token or os.environ.get("HF_TOKEN", "")
    if hw["vram_gb"] > 0:
        start_media_loop(args.coordinator, args.api_key, _agent_id, hw["vram_gb"], hf_token)
        ok(f"Media loop ready  ({hw['vram_gb']} GB VRAM)  -  deps install on first job")

    # 9. Work loop
    work_loop(ollama_exe, args.coordinator, args.api_key, args.port, hw["vram_gb"])


if __name__ == "__main__":
    main()
