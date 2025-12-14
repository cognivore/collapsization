#!/usr/bin/env python3
"""
Collapsization Training Manager

A resilient local manager that:
- Creates and tracks its own Vast.ai instance
- Only destroys instances it created (safe for shared API keys)
- Survives MacBook sleep/restart via state file
- Shows progress charts in terminal
- Downloads results to timestamped folders
- Verifies checkpoint integrity before cleanup

Usage:
    python training_manager.py              # Start/resume training management
    python training_manager.py status       # Check status without starting
    python training_manager.py destroy      # Force destroy tracked instance
    python training_manager.py download     # Download results manually

State is persisted to .training-manager.state
"""

import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass, field, asdict
from datetime import datetime
from pathlib import Path
from typing import Optional
import urllib.request
import urllib.error


# ─────────────────────────────────────────────────────────────────────────────
# State Management
# ─────────────────────────────────────────────────────────────────────────────


@dataclass
class TrainingManagerState:
    """Persistent state for the training manager.

    This state survives MacBook sleep/restart and ensures we only
    destroy instances that WE created.
    """

    # Instance tracking (CRITICAL: only destroy what we created)
    instance_id: Optional[str] = None
    instance_host: Optional[str] = None
    instance_port: Optional[int] = None

    # Timestamps for lifecycle tracking
    created_at: Optional[str] = None
    training_started_at: Optional[str] = None
    last_check_at: Optional[str] = None

    # Progress history for charting
    progress_history: list = field(default_factory=list)

    # Configuration snapshot (to detect config changes)
    config_snapshot: dict = field(default_factory=dict)

    # Track downloaded checkpoints to avoid re-downloading
    downloaded_checkpoints: list = field(default_factory=list)

    STATE_FILE = Path(__file__).parent / ".training-manager.state"

    def save(self):
        """Persist state to file."""
        with open(self.STATE_FILE, "w") as f:
            json.dump(asdict(self), f, indent=2)
        print(f"[State] Saved to {self.STATE_FILE}")

    @classmethod
    def load(cls) -> "TrainingManagerState":
        """Load state from file or create new."""
        if cls.STATE_FILE.exists():
            try:
                with open(cls.STATE_FILE) as f:
                    data = json.load(f)
                # Handle list fields
                if "progress_history" not in data:
                    data["progress_history"] = []
                if "config_snapshot" not in data:
                    data["config_snapshot"] = {}
                if "downloaded_checkpoints" not in data:
                    data["downloaded_checkpoints"] = []
                return cls(**data)
            except (json.JSONDecodeError, TypeError) as e:
                print(f"[Warning] Failed to load state: {e}, starting fresh")
                return cls()
        return cls()

    def clear_instance(self):
        """Clear instance info (after destroy)."""
        self.instance_id = None
        self.instance_host = None
        self.instance_port = None
        self.created_at = None
        self.training_started_at = None
        self.progress_history = []
        self.downloaded_checkpoints = []
        self.save()


# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────


@dataclass
class Config:
    """Configuration for training manager."""

    # Vast.ai settings - use 1xH100
    gpu_type: str = "H100"
    num_gpus: int = 1
    max_price_per_hour: float = 3.50
    min_gpu_ram: int = 80  # H100 SXM has 80GB
    min_disk: int = 100
    min_ram: int = 64

    # Training settings
    training_phase: str = "ppo"
    training_episodes: int = 500000
    population_size: int = 5
    save_every: int = 50000

    # Paths
    remote_dir: str = "/root/collapsization-training"
    local_training_dir: str = str(Path(__file__).parent)
    results_dir: str = str(Path(__file__).parent / "results")

    # SSH
    ssh_key_path: str = str(Path.home() / ".ssh" / "id_ed25519")

    # Polling
    check_interval: int = 120  # seconds

    @classmethod
    def from_env(cls) -> "Config":
        """Load config from .env file."""
        config = cls()
        env_file = Path(__file__).parent / ".env"

        if env_file.exists():
            with open(env_file) as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    if "=" in line:
                        key, value = line.split("=", 1)
                        key = key.strip().lower()
                        value = value.strip().strip('"').strip("'")

                        if key == "gpu_type":
                            config.gpu_type = value
                        elif key == "max_price_per_hour":
                            config.max_price_per_hour = float(value)
                        elif key == "training_phase":
                            config.training_phase = value
                        elif key == "training_episodes":
                            config.training_episodes = int(value)
                        elif key == "population_size":
                            config.population_size = int(value)
                        elif key == "save_every":
                            config.save_every = int(value)
                        elif key == "ssh_key_path":
                            config.ssh_key_path = os.path.expanduser(value)

        return config


# ─────────────────────────────────────────────────────────────────────────────
# Vast.ai Client
# ─────────────────────────────────────────────────────────────────────────────


class VastClient:
    """Client for Vast.ai API."""

    BASE_URL = "https://console.vast.ai/api/v0"

    def __init__(self):
        self.api_key = self._get_api_key()

    def _get_api_key(self) -> str:
        """Get API key from environment or passveil."""
        key = os.getenv("VAST_API_KEY", "")
        if key:
            return key

        # Try passveil
        try:
            result = subprocess.run(
                ["passveil", "show", "vast.ai/api"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            if result.returncode == 0:
                return result.stdout.strip()
        except (FileNotFoundError, subprocess.TimeoutExpired):
            pass

        raise RuntimeError("VAST_API_KEY not found. Set env var or install passveil.")

    def _request(self, method: str, endpoint: str, data: Optional[dict] = None) -> dict:
        """Make API request."""
        url = f"{self.BASE_URL}/{endpoint}"
        if "?" in url:
            url += f"&api_key={self.api_key}"
        else:
            url += f"?api_key={self.api_key}"

        headers = {"Accept": "application/json"}

        if data is not None:
            headers["Content-Type"] = "application/json"
            req = urllib.request.Request(
                url, data=json.dumps(data).encode(), headers=headers, method=method
            )
        else:
            req = urllib.request.Request(url, headers=headers, method=method)

        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            error_body = e.read().decode() if e.fp else ""
            raise RuntimeError(f"API error {e.code}: {error_body}")

    def list_instances(self) -> list[dict]:
        """List all instances."""
        result = self._request("GET", "instances/")
        return result.get("instances", [])

    def get_instance(self, instance_id: str) -> dict:
        """Get instance details."""
        result = self._request("GET", f"instances/{instance_id}/")
        return result.get("instances", {})

    def search_offers(self, config: Config) -> list[dict]:
        """Search for GPU offers."""
        import urllib.parse

        gpu_map = {
            "H100": "H100 NVL",
            "H100_SXM": "H100 SXM",
            "H200": "H200",
            "H200_NVL": "H200 NVL",
            "A100": "A100 PCIE",
            "A100_SXM": "A100 SXM4",
            "RTX_4090": "RTX 4090",
        }

        query = {
            "verified": {"eq": True},
            "rentable": {"eq": True},
            "gpu_ram": {"gte": config.min_gpu_ram * 1024},
            "disk_space": {"gte": config.min_disk},
            "dph_total": {"lte": config.max_price_per_hour},
            "cuda_max_good": {"gte": 12.0},
            "num_gpus": {"eq": config.num_gpus},
        }

        if config.gpu_type in gpu_map:
            query["gpu_name"] = {"eq": gpu_map[config.gpu_type]}

        query_str = urllib.parse.quote(json.dumps(query, separators=(",", ":")))
        order_str = urllib.parse.quote('[["dph_total","asc"]]')

        result = self._request("GET", f"bundles/?q={query_str}&order={order_str}")
        return result.get("offers", [])

    def create_instance(self, offer_id: int, disk: int = 100) -> dict:
        """Create a new instance."""
        data = {
            "client_id": "me",
            "image": "pytorch/pytorch:2.1.0-cuda12.1-cudnn8-runtime",
            "disk": disk,
            "onstart": "touch ~/.no_auto_tmux",
        }
        return self._request("PUT", f"asks/{offer_id}/", data)

    def destroy_instance(self, instance_id: str) -> dict:
        """Destroy an instance."""
        return self._request("DELETE", f"instances/{instance_id}/")


# ─────────────────────────────────────────────────────────────────────────────
# SSH/Rsync Helpers
# ─────────────────────────────────────────────────────────────────────────────


def ssh_command(
    state: TrainingManagerState,
    config: Config,
    cmd: str,
    capture: bool = False,
    timeout: int = 60,
) -> subprocess.CompletedProcess:
    """Run SSH command on remote instance."""
    if not state.instance_host or not state.instance_port:
        raise RuntimeError("No instance configured")

    ssh_args = [
        "ssh",
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "ConnectTimeout=10",
        "-p",
        str(state.instance_port),
    ]

    if config.ssh_key_path and os.path.exists(config.ssh_key_path):
        ssh_args.extend(["-i", config.ssh_key_path])

    ssh_args.append(f"root@{state.instance_host}")
    ssh_args.append(cmd)

    if capture:
        return subprocess.run(ssh_args, capture_output=True, text=True, timeout=timeout)
    else:
        return subprocess.run(ssh_args, timeout=timeout)


def rsync_upload(
    state: TrainingManagerState, config: Config, local_path: str, remote_path: str
) -> bool:
    """Upload files via rsync."""
    ssh_opts = f"-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p {state.instance_port}"
    if config.ssh_key_path and os.path.exists(config.ssh_key_path):
        ssh_opts += f" -i {config.ssh_key_path}"

    rsync_args = [
        "rsync",
        "-avz",
        "--progress",
        "-e",
        f"ssh {ssh_opts}",
        "--exclude",
        ".venv",
        "--exclude",
        "__pycache__",
        "--exclude",
        "*.pyc",
        "--exclude",
        ".git",
        "--exclude",
        "checkpoints",
        "--exclude",
        "results",
        f"{local_path}/",
        f"root@{state.instance_host}:{remote_path}/",
    ]

    result = subprocess.run(rsync_args)
    return result.returncode == 0


def rsync_download(
    state: TrainingManagerState, config: Config, remote_path: str, local_path: str
) -> bool:
    """Download files via rsync."""
    ssh_opts = f"-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p {state.instance_port}"
    if config.ssh_key_path and os.path.exists(config.ssh_key_path):
        ssh_opts += f" -i {config.ssh_key_path}"

    rsync_args = [
        "rsync",
        "-avz",
        "--progress",
        "-e",
        f"ssh {ssh_opts}",
        f"root@{state.instance_host}:{remote_path}/",
        f"{local_path}/",
    ]

    result = subprocess.run(rsync_args)
    return result.returncode == 0


# ─────────────────────────────────────────────────────────────────────────────
# Progress Display
# ─────────────────────────────────────────────────────────────────────────────


def print_progress_chart(history: list[dict], total_episodes: int = 500000):
    """Print ASCII progress chart."""
    if len(history) < 1:
        return

    width = 50

    print("\n" + "=" * 65)
    print("  TRAINING PROGRESS")
    print("=" * 65)

    # Show last 15 data points
    display_history = history[-15:]

    for h in display_history:
        episodes = h.get("episodes", 0)
        pct = episodes / total_episodes
        bar_len = int(pct * width)
        bar = "\u2588" * bar_len + "\u2591" * (width - bar_len)
        time_str = h.get("time", "")[-8:]  # HH:MM:SS
        print(f"  {time_str} |{bar}| {episodes:>7}/{total_episodes}")

    # Summary
    if display_history:
        latest = display_history[-1]
        pct = latest.get("episodes", 0) / total_episodes * 100
        print("=" * 65)
        print(f"  Progress: {pct:.1f}% | Episodes: {latest.get('episodes', 0):,}")

        # Estimate time remaining
        if len(history) >= 2:
            first = history[0]
            latest = history[-1]
            elapsed_mins = (
                datetime.fromisoformat(latest["time"])
                - datetime.fromisoformat(first["time"])
            ).total_seconds() / 60
            episodes_done = latest.get("episodes", 0) - first.get("episodes", 0)
            if episodes_done > 0 and elapsed_mins > 0:
                rate = episodes_done / elapsed_mins
                remaining = (total_episodes - latest.get("episodes", 0)) / rate
                print(
                    f"  Rate: {rate:.0f} ep/min | ETA: {remaining:.0f} min ({remaining/60:.1f} hr)"
                )

    print("=" * 65 + "\n")


# ─────────────────────────────────────────────────────────────────────────────
# Training Manager
# ─────────────────────────────────────────────────────────────────────────────


class TrainingManager:
    """Main training manager class."""

    def __init__(self):
        self.config = Config.from_env()
        self.state = TrainingManagerState.load()
        self.client = VastClient()

    def provision(self) -> bool:
        """Provision a new instance (or reconnect to existing)."""
        # Check if we already have an instance
        if self.state.instance_id:
            print(f"[Provision] Found existing instance: {self.state.instance_id}")
            try:
                instance = self.client.get_instance(self.state.instance_id)
                status = instance.get("actual_status", "unknown")
                if status == "running":
                    print(
                        f"[Provision] Instance is running at {self.state.instance_host}:{self.state.instance_port}"
                    )
                    return True
                else:
                    print(f"[Provision] Instance status: {status}, will create new")
                    self.state.clear_instance()
            except Exception as e:
                print(f"[Provision] Existing instance not accessible: {e}")
                self.state.clear_instance()

        # Search for offers
        print(
            f"[Provision] Searching for {self.config.num_gpus}x {self.config.gpu_type} @ <${self.config.max_price_per_hour}/hr..."
        )
        offers = self.client.search_offers(self.config)

        if not offers:
            print("[Provision] No offers found matching criteria")
            return False

        offer = offers[0]
        print(
            f"[Provision] Found: {offer.get('gpu_name')} @ ${offer.get('dph_total', 0):.3f}/hr"
        )

        # Create instance
        print("[Provision] Creating instance...")
        result = self.client.create_instance(offer["id"], disk=self.config.min_disk)

        if not result.get("success"):
            print(f"[Provision] Failed: {result}")
            return False

        instance_id = str(result.get("new_contract"))
        print(f"[Provision] Instance created: {instance_id}")

        # Wait for ready
        print("[Provision] Waiting for instance to start...")
        for _ in range(60):
            time.sleep(5)
            instance = self.client.get_instance(instance_id)
            status = instance.get("actual_status", "unknown")
            print(f"[Provision]   Status: {status}")

            if status == "running":
                ssh_host = instance.get("ssh_host")
                ssh_port = instance.get("ssh_port", 22)

                # Save state IMMEDIATELY
                self.state.instance_id = instance_id
                self.state.instance_host = ssh_host
                self.state.instance_port = ssh_port
                self.state.created_at = datetime.now().isoformat()
                self.state.save()

                # Wait for SSH to be ready (not just instance status)
                print(f"[Provision] Instance running, waiting for SSH to be ready...")
                if self._wait_for_ssh():
                    print(f"[Provision] Ready: {ssh_host}:{ssh_port}")
                    return True
                else:
                    print("[Provision] SSH failed to become ready")
                    return False

        print("[Provision] Timeout waiting for instance")
        return False

    def _wait_for_ssh(self, max_retries: int = 12, delay: int = 5) -> bool:
        """Wait for SSH to be ready with retries."""
        for attempt in range(max_retries):
            try:
                result = ssh_command(
                    self.state,
                    self.config,
                    "echo SSH_READY",
                    capture=True,
                    timeout=15,
                )
                if result.returncode == 0 and "SSH_READY" in result.stdout:
                    return True
            except subprocess.TimeoutExpired:
                pass
            except Exception as e:
                print(f"[Provision]   SSH attempt {attempt + 1}/{max_retries}: {e}")

            if attempt < max_retries - 1:
                print(f"[Provision]   SSH not ready, retrying in {delay}s...")
                time.sleep(delay)

        return False

    def setup(self) -> bool:
        """Upload code and setup environment."""
        print("[Setup] Uploading training code...")

        # Create remote directory
        ssh_command(self.state, self.config, f"mkdir -p {self.config.remote_dir}")

        # Upload code
        if not rsync_upload(
            self.state,
            self.config,
            self.config.local_training_dir,
            self.config.remote_dir,
        ):
            print("[Setup] Failed to upload code")
            return False

        # Run setup script
        print("[Setup] Running setup.sh...")
        result = ssh_command(
            self.state,
            self.config,
            f"cd {self.config.remote_dir} && chmod +x setup.sh && ./setup.sh",
            timeout=600,
        )

        if result.returncode != 0:
            print("[Setup] Setup script failed")
            return False

        print("[Setup] Complete")
        return True

    def start_training(self) -> bool:
        """Start training in tmux session."""
        print(
            f"[Train] Starting {self.config.training_phase} training ({self.config.training_episodes} episodes)..."
        )

        # Kill existing session
        ssh_command(
            self.state, self.config, "tmux kill-session -t training 2>/dev/null || true"
        )
        time.sleep(1)

        # Create training script
        training_script = f"""#!/bin/bash
set -e
LOGFILE="{self.config.remote_dir}/training.log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "=========================================="
echo "Training started at $(date)"
echo "Phase: {self.config.training_phase}"
echo "Episodes: {self.config.training_episodes}"
echo "=========================================="
cd {self.config.remote_dir}
source .venv/bin/activate
python -c "import torch; print(f'CUDA: {{torch.cuda.is_available()}}, Device: {{torch.cuda.get_device_name(0)}}')"
python train.py \\
    --phase={self.config.training_phase} \\
    --episodes={self.config.training_episodes} \\
    --population={self.config.population_size} \\
    --save-every={self.config.save_every} \\
    --device=cuda
echo "=========================================="
echo "TRAINING_COMPLETE"
echo "Training finished at $(date)"
echo "=========================================="
"""

        # Upload script
        script_cmd = f"cat > {self.config.remote_dir}/run_training.sh << 'EOF'\n{training_script}\nEOF"
        ssh_command(self.state, self.config, script_cmd)
        ssh_command(
            self.state,
            self.config,
            f"chmod +x {self.config.remote_dir}/run_training.sh",
        )

        # Start in tmux
        tmux_cmd = f"""
tmux new-session -d -s training -c {self.config.remote_dir}
tmux send-keys -t training 'bash {self.config.remote_dir}/run_training.sh' Enter
"""
        result = ssh_command(self.state, self.config, tmux_cmd)

        if result.returncode != 0:
            print("[Train] Failed to start tmux session")
            return False

        # Verify
        time.sleep(2)
        result = ssh_command(
            self.state,
            self.config,
            "tmux has-session -t training 2>/dev/null && echo RUNNING || echo STOPPED",
            capture=True,
        )

        if result.stdout.strip() != "RUNNING":
            print("[Train] Training session failed to start")
            return False

        self.state.training_started_at = datetime.now().isoformat()
        self.state.save()

        print("[Train] Training started in tmux session")
        return True

    def check_status(self) -> dict:
        """Check training status."""
        try:
            # Check tmux session
            result = ssh_command(
                self.state,
                self.config,
                "tmux has-session -t training 2>/dev/null && echo RUNNING || echo STOPPED",
                capture=True,
                timeout=30,
            )
            is_running = "RUNNING" in result.stdout

            # Get progress
            result = ssh_command(
                self.state,
                self.config,
                f'grep -oP "\\d+(?=/500000)" {self.config.remote_dir}/training.log 2>/dev/null | tail -1',
                capture=True,
                timeout=30,
            )
            episodes = 0
            try:
                episodes = int(result.stdout.strip())
            except ValueError:
                pass

            # Check completion - only complete if we found the marker AND have significant progress
            is_complete = False
            if episodes >= self.config.training_episodes * 0.95:  # At least 95% done
                result = ssh_command(
                    self.state,
                    self.config,
                    f"grep -c TRAINING_COMPLETE {self.config.remote_dir}/training.log 2>/dev/null || echo 0",
                    capture=True,
                    timeout=30,
                )
                is_complete = result.stdout.strip() not in ("0", "")

            return {
                "running": is_running,
                "complete": is_complete,
                "episodes": episodes,
                "time": datetime.now().isoformat(),
            }
        except Exception as e:
            print(f"[Status] Error checking status: {e}")
            return {
                "running": False,
                "complete": False,
                "episodes": 0,
                "time": datetime.now().isoformat(),
            }

    def get_available_checkpoints(self) -> list[int]:
        """Get list of checkpoint episodes available on remote."""
        try:
            result = ssh_command(
                self.state,
                self.config,
                f"ls {self.config.remote_dir}/checkpoints/ppo_mayor_ep*.pt 2>/dev/null | grep -oP 'ep\\K\\d+' | sort -n",
                capture=True,
                timeout=30,
            )
            episodes = []
            for line in result.stdout.strip().split("\n"):
                if line.strip():
                    try:
                        episodes.append(int(line.strip()))
                    except ValueError:
                        pass
            return episodes
        except Exception as e:
            print(f"[Checkpoint] Error listing checkpoints: {e}")
            return []

    def download_checkpoint(self, episode: int) -> Optional[Path]:
        """Download a specific checkpoint to dated/episode directory.

        Structure: results/YYYY-MM-DD/NNNNNN/ppo_*.pt
        """
        date_str = datetime.now().strftime("%Y-%m-%d")
        episode_str = f"{episode:07d}"  # Zero-padded to 7 digits
        dest_dir = Path(self.config.results_dir) / date_str / episode_str

        dest_dir.mkdir(parents=True, exist_ok=True)
        print(f"[Checkpoint] Downloading episode {episode} to {dest_dir}")

        # Download specific checkpoint files
        roles = ["mayor", "industry", "urbanist"]
        ssh_opts = f"-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p {self.state.instance_port}"
        if self.config.ssh_key_path and os.path.exists(self.config.ssh_key_path):
            ssh_opts += f" -i {self.config.ssh_key_path}"

        success = True
        for role in roles:
            filename = f"ppo_{role}_ep{episode}.pt"
            remote_path = f"{self.config.remote_dir}/checkpoints/{filename}"
            local_path = dest_dir / filename

            scp_args = [
                "scp",
                "-o",
                "StrictHostKeyChecking=no",
                "-o",
                "UserKnownHostsFile=/dev/null",
                "-P",
                str(self.state.instance_port),
            ]
            if self.config.ssh_key_path and os.path.exists(self.config.ssh_key_path):
                scp_args.extend(["-i", self.config.ssh_key_path])
            scp_args.extend(
                [
                    f"root@{self.state.instance_host}:{remote_path}",
                    str(local_path),
                ]
            )

            result = subprocess.run(scp_args, capture_output=True)
            if result.returncode != 0:
                print(f"[Checkpoint] Failed to download {filename}")
                success = False

        if success:
            # Also download the log file
            log_dest = dest_dir / "training.log"
            scp_args = [
                "scp",
                "-o",
                "StrictHostKeyChecking=no",
                "-o",
                "UserKnownHostsFile=/dev/null",
                "-P",
                str(self.state.instance_port),
            ]
            if self.config.ssh_key_path and os.path.exists(self.config.ssh_key_path):
                scp_args.extend(["-i", self.config.ssh_key_path])
            scp_args.extend(
                [
                    f"root@{self.state.instance_host}:{self.config.remote_dir}/training.log",
                    str(log_dest),
                ]
            )
            subprocess.run(scp_args, capture_output=True)  # Don't fail if log missing

            print(f"[Checkpoint] Downloaded episode {episode}")
            return dest_dir

        return None

    def sync_checkpoints(self) -> list[int]:
        """Check for new checkpoints and download them."""
        available = self.get_available_checkpoints()
        new_checkpoints = [
            ep for ep in available if ep not in self.state.downloaded_checkpoints
        ]

        downloaded = []
        for ep in sorted(new_checkpoints):
            dest = self.download_checkpoint(ep)
            if dest:
                self.state.downloaded_checkpoints.append(ep)
                downloaded.append(ep)

        if downloaded:
            self.state.save()

        return downloaded

    def download_results(self, dest_dir: Optional[Path] = None) -> Optional[Path]:
        """Download all training results (final download)."""
        if dest_dir is None:
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            dest_dir = Path(self.config.results_dir) / f"training_{timestamp}"

        dest_dir.mkdir(parents=True, exist_ok=True)
        print(f"[Download] Downloading all results to {dest_dir}")

        # Download all checkpoints
        rsync_download(
            self.state,
            self.config,
            f"{self.config.remote_dir}/checkpoints",
            str(dest_dir / "checkpoints"),
        )

        # Download log
        ssh_command(
            self.state,
            self.config,
            f"cp {self.config.remote_dir}/training.log {self.config.remote_dir}/checkpoints/ 2>/dev/null || true",
        )

        print(f"[Download] Complete: {dest_dir}")
        return dest_dir

    def verify_integrity(self, dest_dir: Path) -> bool:
        """Verify checkpoint integrity."""
        expected_files = [
            f"ppo_{role}_ep{self.config.training_episodes}.pt"
            for role in ["mayor", "industry", "urbanist"]
        ]

        checkpoints_dir = dest_dir / "checkpoints"
        missing = [f for f in expected_files if not (checkpoints_dir / f).exists()]

        if missing:
            print(f"[Verify] Missing checkpoints: {missing}")
            return False

        print("[Verify] All expected checkpoints present")
        return True

    def destroy_instance(self, force: bool = False) -> bool:
        """Destroy ONLY the instance we created."""
        if not self.state.instance_id:
            print("[Destroy] No tracked instance to destroy")
            return False

        instance_id = self.state.instance_id
        print(f"[Destroy] Attempting to destroy instance {instance_id}...")

        # Safety check: verify instance matches our records (skip with force)
        if not force:
            try:
                instance = self.client.get_instance(instance_id)
                # Check if we got valid instance data
                if instance and instance.get("ssh_host"):
                    if instance.get("ssh_host") != self.state.instance_host:
                        print(f"[Destroy] WARNING: Instance mismatch! Use 'destroy --force' to override.")
                        print(f"[Destroy]   Expected: {self.state.instance_host}")
                        print(f"[Destroy]   Got: {instance.get('ssh_host')}")
                        return False
                    print(f"[Destroy] Verified instance matches: {instance.get('ssh_host')}")
            except Exception as e:
                print(f"[Destroy] Could not verify instance (will try to destroy anyway): {e}")

        # Always try to destroy - the API will tell us if it doesn't exist
        try:
            self.client.destroy_instance(instance_id)
            print(f"[Destroy] Instance {instance_id} destroyed successfully")
        except Exception as e:
            error_msg = str(e).lower()
            if "not found" in error_msg or "404" in error_msg or "does not exist" in error_msg:
                print(f"[Destroy] Instance {instance_id} already gone (not found)")
            else:
                print(f"[Destroy] API error: {e}")
                print("[Destroy] Instance may or may not be destroyed - check Vast.ai console")

        # Always clear state after attempting destroy
        self.state.clear_instance()
        print("[Destroy] Local state cleared")
        return True

    def run(self):
        """Main run loop."""
        print("\n" + "=" * 65)
        print("  COLLAPSIZATION TRAINING MANAGER")
        print("  Safe instance management with state persistence")
        print("=" * 65 + "\n")

        # Check for existing state
        if self.state.instance_id:
            print(f"[Resume] Found existing instance: {self.state.instance_id}")
            print(f"[Resume] Created: {self.state.created_at}")
            print(f"[Resume] Training started: {self.state.training_started_at}")

            # Wait for instance to be ready
            print("[Resume] Checking instance status...")
            time.sleep(5)

            # If training was never started, we need to set up and start it
            if not self.state.training_started_at:
                print("[Resume] Training was not started, setting up...")

                # Setup environment
                if not self.setup():
                    print("[Error] Failed to setup environment")
                    return

                # Start training
                if not self.start_training():
                    print("[Error] Failed to start training")
                    return
        else:
            # Provision new instance
            if not self.provision():
                print("[Error] Failed to provision instance")
                return

            # Setup environment
            if not self.setup():
                print("[Error] Failed to setup environment")
                return

            # Start training
            if not self.start_training():
                print("[Error] Failed to start training")
                return

        # Monitor loop
        print("\n[Monitor] Monitoring training (Ctrl+C to stop)...")
        print(f"[Monitor] Checking every {self.config.check_interval} seconds")
        print(
            f"[Monitor] Checkpoints will be downloaded to: {self.config.results_dir}/YYYY-MM-DD/NNNNNNN/"
        )

        try:
            while True:
                status = self.check_status()

                # Update history
                self.state.progress_history.append(
                    {
                        "time": status["time"],
                        "episodes": status["episodes"],
                    }
                )
                self.state.last_check_at = status["time"]

                # Sync new checkpoints incrementally
                new_checkpoints = self.sync_checkpoints()
                if new_checkpoints:
                    print(f"[Checkpoint] Downloaded new checkpoints: {new_checkpoints}")

                self.state.save()

                # Display progress
                print_progress_chart(
                    self.state.progress_history, self.config.training_episodes
                )

                # Show downloaded checkpoints
                if self.state.downloaded_checkpoints:
                    print(
                        f"  Downloaded checkpoints: {sorted(self.state.downloaded_checkpoints)}"
                    )

                # Check completion
                if status["complete"]:
                    print("\n[Complete] Training finished!")

                    # Final sync to make sure we have everything
                    self.sync_checkpoints()

                    # Download full results as backup
                    dest_dir = self.download_results()

                    # Verify integrity
                    if dest_dir and self.verify_integrity(dest_dir):
                        print("[Complete] Destroying instance...")
                        self.destroy_instance()
                        print(f"\n[SUCCESS] Results saved to: {dest_dir}")
                        print(
                            f"[SUCCESS] Checkpoints also in: {self.config.results_dir}/YYYY-MM-DD/"
                        )
                    else:
                        print("[Warning] Integrity check failed, keeping instance")

                    return

                if not status["running"] and status["episodes"] > 1000:
                    print("\n[Warning] Training stopped unexpectedly!")
                    print("[Warning] Download results and investigate")

                time.sleep(self.config.check_interval)

        except KeyboardInterrupt:
            print("\n\n[Stopped] Monitoring stopped")
            print(f"[Stopped] Instance still running: {self.state.instance_id}")
            print("[Stopped] Resume with: python training_manager.py")
            print("[Stopped] Destroy with: python training_manager.py destroy")


# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser(
        description="Collapsization Training Manager",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Commands:
  (none)    Start/resume training management
  status    Check current status
  download  Download results manually
  destroy   Force destroy tracked instance
""",
    )
    parser.add_argument(
        "command",
        nargs="?",
        default="run",
        choices=["run", "status", "download", "destroy"],
        help="Command to run",
    )
    parser.add_argument(
        "--force", action="store_true", help="Force destroy without verification"
    )

    args = parser.parse_args()

    manager = TrainingManager()

    if args.command == "status":
        if manager.state.instance_id:
            print(f"Instance ID: {manager.state.instance_id}")
            print(f"Host: {manager.state.instance_host}:{manager.state.instance_port}")
            print(f"Created: {manager.state.created_at}")
            status = manager.check_status()
            print(f"Running: {status['running']}")
            print(f"Complete: {status['complete']}")
            print(f"Episodes: {status['episodes']}")
        else:
            print("No tracked instance")

    elif args.command == "download":
        if manager.state.instance_id:
            manager.download_results()
        else:
            print("No tracked instance")

    elif args.command == "destroy":
        manager.destroy_instance(force=args.force)

    else:
        manager.run()


if __name__ == "__main__":
    main()
