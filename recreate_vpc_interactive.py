#!/usr/bin/env python3
import os
import sys
import subprocess
from datetime import datetime

# ===============================
# CONFIG
# ===============================
BACKUP_ROOT = "/opt/terraform/logs"
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GENERATOR = os.path.join(SCRIPT_DIR, "generate_tfvars_full.py")
TERRAFORM_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))

MAX_DR_WORKSPACES = 5  # keep last 5 DR workspaces only

REGIONS = {
    "1": ("ap-south-1", "Mumbai"),
    "2": ("ap-southeast-1", "Singapore"),
    "3": ("me-central-1", "UAE"),
}

# ===============================
# HELPERS
# ===============================
def run(cmd, cwd=None):
    return subprocess.run(
        cmd,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )

def list_dirs(path):
    return sorted(
        [d for d in os.listdir(path) if os.path.isdir(os.path.join(path, d))],
        reverse=True
    )

def choose_from_list(items, title):
    if not items:
        print(f"❌ No {title} found")
        sys.exit(1)

    print(f"\nSelect {title}:")
    for i, item in enumerate(items, 1):
        print(f"{i}) {item}")

    while True:
        choice = input("Enter number: ").strip()
        if choice.isdigit() and 1 <= int(choice) <= len(items):
            return items[int(choice) - 1]
        print("❌ Invalid selection, try again")

def choose_region():
    print("\nSelect DR Region:")
    for k, (_, name) in REGIONS.items():
        print(f"{k}) {name}")

    while True:
        choice = input("Enter number: ").strip()
        if choice in REGIONS:
            return REGIONS[choice]
        print("❌ Invalid region selection")

def cleanup_old_workspaces(terraform_root, keep, current_ws):
    ws = run(["terraform", "workspace", "list"], cwd=terraform_root)

    dr_workspaces = []
    for line in ws.stdout.splitlines():
        name = line.replace("*", "").strip()
        if name.startswith("dr_"):
            dr_workspaces.append(name)

    # newest first (timestamp-based naming)
    dr_workspaces.sort(reverse=True)

    to_delete = dr_workspaces[keep:]

    for w in to_delete:
        if w == current_ws:
            continue
        print(f"🧹 Deleting old DR workspace: {w}")
        run(["terraform", "workspace", "delete", w], cwd=terraform_root)

# ===============================
# MAIN
# ===============================
print("\n🚀 VPC DR RECREATION TOOL")

# 1️⃣ Select DR region
region, region_name = choose_region()

# 2️⃣ Show LAST 5 backup folders
all_backups = list_dirs(BACKUP_ROOT)
backup_folders = all_backups[:5]
backup_folder = choose_from_list(backup_folders, "backup folder")
backup_path = os.path.join(BACKUP_ROOT, backup_folder)

# 3️⃣ Show ALL VPC folders
vpc_folders = list_dirs(backup_path)
vpc_folder = choose_from_list(vpc_folders, "VPC folder")
source_path = os.path.join(backup_path, vpc_folder)

# 4️⃣ Auto workspace name (safe & unique)
timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
workspace = f"dr_{vpc_folder}_{region}_{timestamp}"

# 5️⃣ Summary
print("\n==============================")
print(f"DR Region     : {region_name} ({region})")
print(f"Backup folder : {backup_folder}")
print(f"VPC folder    : {vpc_folder}")
print(f"Workspace     : {workspace}")
print(f"Source path   : {source_path}")
print("==============================\n")

confirm = input("Proceed? (yes/no): ").strip().lower()
if confirm != "yes":
    print("❌ Aborted by user")
    sys.exit(0)

# 6️⃣ Generate terraform.auto.tfvars
print("\n🚀 Generating terraform.auto.tfvars...\n")

gen = run(
    ["python3", GENERATOR, source_path, region],
    cwd=TERRAFORM_ROOT
)

print(gen.stdout)
if gen.returncode != 0:
    print(gen.stderr)
    print("❌ generate_tfvars_full.py failed")
    sys.exit(1)

# 7️⃣ Create/select workspace (SAFE & VISIBLE)
print("\n🚀 Preparing Terraform workspace...\n")

run(["terraform", "init"], cwd=TERRAFORM_ROOT)

ws_create = run(
    ["terraform", "workspace", "new", workspace],
    cwd=TERRAFORM_ROOT
)

if ws_create.returncode == 0:
    print(f"✅ Workspace created: {workspace}")
else:
    run(["terraform", "workspace", "select", workspace], cwd=TERRAFORM_ROOT)
    print(f"ℹ️ Workspace already exists, selected: {workspace}")

# Show workspace list
ws_list = run(["terraform", "workspace", "list"], cwd=TERRAFORM_ROOT)
print("\n📂 Available Terraform workspaces:")
print(ws_list.stdout)

# 8️⃣ Auto-clean old DR workspaces (SAFE)
cleanup_old_workspaces(
    terraform_root=TERRAFORM_ROOT,
    keep=MAX_DR_WORKSPACES,
    current_ws=workspace
)

# 9️⃣ Final message
print("\n✅ Setup complete. NO resources created yet.\n")
print("👉 Next steps (manual & safe):")
print(f"   cd {TERRAFORM_ROOT}")
print("   terraform plan")
print("   terraform apply")
