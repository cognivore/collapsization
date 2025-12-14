#!/usr/bin/env python3
"""
Monitor training progress, download results, and cleanup VMs when done.
"""

import subprocess
import time
import os
import sys
from pathlib import Path
from datetime import datetime

TRAINING_DIR = Path(__file__).parent
RESULTS_DIR = TRAINING_DIR / "results"

INSTANCES = {
    "h100": {
        "id": "28823284",
        "host": "ssh3.vast.ai",
        "port": "23284",
        "name": "H100 SXM",
    },
    "rtx4090": {
        "id": "28822965",
        "host": "ssh1.vast.ai",
        "port": "22964",
        "name": "RTX 4090",
    },
}


def get_api_key():
    """Get VAST API key from passveil."""
    result = subprocess.run(
        ["passveil", "show", "vast.ai/api"], capture_output=True, text=True
    )
    return result.stdout.strip()


def ssh_command(host: str, port: str, cmd: str) -> tuple[int, str]:
    """Run SSH command and return exit code and output."""
    full_cmd = [
        "ssh",
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "ConnectTimeout=10",
        "-p",
        port,
        f"root@{host}",
        cmd,
    ]
    result = subprocess.run(full_cmd, capture_output=True, text=True, timeout=60)
    return result.returncode, result.stdout + result.stderr


def check_training_status(instance: dict) -> dict:
    """Check if training is still running and get progress."""
    host, port = instance["host"], instance["port"]

    # Check if tmux session exists
    code, output = ssh_command(
        host,
        port,
        "tmux has-session -t training 2>/dev/null && echo 'running' || echo 'stopped'",
    )
    is_running = "running" in output

    # Get progress from log
    code, output = ssh_command(
        host,
        port,
        'grep -oP "PPO self-play:\\s+\\d+%.*?\\d+/500000.*?(?=PPO|$)" /root/collapsization-training/training.log 2>/dev/null | tail -1',
    )

    progress_line = output.strip()

    # Parse progress
    episodes = 0
    percent = 0
    if progress_line:
        import re

        match = re.search(r"(\d+)/500000", progress_line)
        if match:
            episodes = int(match.group(1))
            percent = (episodes / 500000) * 100

    return {
        "running": is_running,
        "episodes": episodes,
        "percent": percent,
        "progress_line": progress_line,
    }


def download_results(instance: dict, tag: str):
    """Download training results from instance."""
    host, port = instance["host"], instance["port"]
    name = instance["name"].replace(" ", "_")

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    dest_dir = RESULTS_DIR / f"{name}_{timestamp}"
    dest_dir.mkdir(parents=True, exist_ok=True)

    print(f"📥 Downloading results from {instance['name']} to {dest_dir}")

    # Download checkpoints
    subprocess.run(
        [
            "rsync",
            "-avz",
            "--progress",
            "-e",
            f"ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p {port}",
            f"root@{host}:/root/collapsization-training/checkpoints/",
            str(dest_dir / "checkpoints/"),
        ],
        check=False,
    )

    # Download training log
    subprocess.run(
        [
            "scp",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-P",
            port,
            f"root@{host}:/root/collapsization-training/training.log",
            str(dest_dir / "training.log"),
        ],
        check=False,
    )

    # Download any saved models
    subprocess.run(
        [
            "rsync",
            "-avz",
            "--progress",
            "-e",
            f"ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p {port}",
            f"root@{host}:/root/collapsization-training/models/",
            str(dest_dir / "models/"),
        ],
        check=False,
    )

    print(f"✅ Results saved to {dest_dir}")
    return dest_dir


def destroy_instance(instance_id: str):
    """Destroy a VAST.AI instance."""
    import urllib.request
    import json

    api_key = get_api_key()
    url = f"https://console.vast.ai/api/v0/instances/{instance_id}/?api_key={api_key}"

    req = urllib.request.Request(url, method="DELETE")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            print(f"🗑️  Instance {instance_id} destroyed")
            return True
    except Exception as e:
        print(f"❌ Failed to destroy {instance_id}: {e}")
        return False


def main():
    print("=" * 60)
    print("🔍 Collapsization Training Monitor")
    print("=" * 60)
    print(f"Monitoring {len(INSTANCES)} instances")
    print("Will download results and destroy VMs when training completes")
    print("Press Ctrl+C to stop monitoring (VMs will keep running)")
    print("=" * 60)

    RESULTS_DIR.mkdir(exist_ok=True)

    completed = set()
    check_interval = 120  # Check every 2 minutes

    while len(completed) < len(INSTANCES):
        print(f"\n[{datetime.now().strftime('%H:%M:%S')}] Checking status...")

        for tag, instance in INSTANCES.items():
            if tag in completed:
                continue

            try:
                status = check_training_status(instance)

                if status["progress_line"]:
                    print(f"  {instance['name']}: {status['progress_line'][:60]}...")
                else:
                    print(f"  {instance['name']}: Unable to get progress")

                # Check if done (either finished 500k or stopped)
                if status["episodes"] >= 499000 or (
                    not status["running"] and status["episodes"] > 1000
                ):
                    print(
                        f"\n🎉 {instance['name']} training complete ({status['episodes']} episodes)"
                    )

                    # Download results
                    download_results(instance, tag)

                    # Destroy instance
                    print(f"🗑️  Destroying {instance['name']} instance...")
                    destroy_instance(instance["id"])

                    completed.add(tag)

            except Exception as e:
                print(f"  {instance['name']}: Error - {e}")

        if len(completed) < len(INSTANCES):
            remaining = len(INSTANCES) - len(completed)
            print(
                f"\n⏳ {remaining} instance(s) still training. Next check in {check_interval}s..."
            )
            time.sleep(check_interval)

    print("\n" + "=" * 60)
    print("✅ All training complete! Results downloaded, VMs destroyed.")
    print(f"Results saved in: {RESULTS_DIR}")
    print("=" * 60)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\n⚠️  Monitoring stopped. VMs are still running!")
        print("To manually cleanup, run:")
        print("  python3 deploy.py destroy  # (with correct .env.instance)")
        sys.exit(0)
