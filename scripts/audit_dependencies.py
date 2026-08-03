import os
import re
import urllib.request
import json
from concurrent.futures import ThreadPoolExecutor

WORKSPACE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def fetch_latest_github_release(repo):
    try:
        req = urllib.request.Request(f"https://api.github.com/repos/{repo}/releases/latest", headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=5) as response:
            data = json.loads(response.read().decode())
            return data.get('tag_name', 'Unknown')
    except Exception:
        return "Could not fetch"

def check_terraform_aws():
    print("-" * 50)
    print("[Terraform] AWS Provider")
    try:
        with open(os.path.join(WORKSPACE, 'terraform', 'jenkins', 'main.tf'), 'r') as f:
            content = f.read()
            match = re.search(r'source\s*=\s*"hashicorp/aws".*?version\s*=\s*"([^"]+)"', content, re.DOTALL)
            print(f"  Current Configured: {match.group(1) if match else 'Not found'}")
    except Exception:
        print("  Current Configured: Error reading file")
    
    latest = fetch_latest_github_release('hashicorp/terraform-provider-aws')
    print(f"  Latest Available:   {latest}")

def check_ansible_aws():
    print("-" * 50)
    print("[Ansible] amazon.aws Collection")
    try:
        with open(os.path.join(WORKSPACE, 'ansible', 'requirements.yml'), 'r') as f:
            content = f.read()
            match = re.search(r'version:\s*"([^"]+)"', content)
            print(f"  Current Configured: {match.group(1) if match else 'Not found'}")
    except Exception:
        print("  Current Configured: Error reading file")
    
    latest = fetch_latest_github_release('ansible-collections/amazon.aws')
    print(f"  Latest Available:   {latest}")

def check_sonarqube():
    print("-" * 50)
    print("[Ansible] SonarQube")
    try:
        with open(os.path.join(WORKSPACE, 'ansible', 'roles', 'sonarqube', 'tasks', 'main.yml'), 'r') as f:
            content = f.read()
            match = re.search(r'sonarqube-([0-9.]+)\.zip', content)
            print(f"  Current Configured: {match.group(1) if match else 'Not found'}")
    except Exception:
        print("  Current Configured: Error reading file")
    
    print("  Known Compatible:   10.7+ (Java 21 support) / 9.9 LTS (Java 17 support)")

def check_java():
    print("-" * 50)
    print("[Ansible] Java JDKs")
    try:
        with open(os.path.join(WORKSPACE, 'ansible', 'roles', 'common', 'tasks', 'main.yml'), 'r') as f:
            common = re.search(r'openjdk-([0-9]+)-jdk', f.read())
            print(f"  Global System (Jenkins): Java {common.group(1) if common else 'Not found'}")
    except Exception: pass
    
    try:
        with open(os.path.join(WORKSPACE, 'ansible', 'roles', 'sonarqube', 'tasks', 'main.yml'), 'r') as f:
            sq = re.search(r'openjdk-([0-9]+)-jdk', f.read())
            print(f"  SonarQube Node:          Java {sq.group(1) if sq else 'Not found'}")
    except Exception: pass
    print("  Compatibility Rule:      Jenkins requires 17/21. SonarQube < 10.7 requires 17.")

def check_jenkins():
    print("-" * 50)
    print("[Ansible] Jenkins")
    try:
        with open(os.path.join(WORKSPACE, 'ansible', 'roles', 'jenkins_master', 'tasks', 'main.yml'), 'r') as f:
            content = f.read()
            repo_match = re.search(r'https://pkg\.jenkins\.io/(debian[a-z-]*)', content)
            key_match = re.search(r'jenkins\.io-([0-9]{4})\.key', content)
            print(f"  Repository Track: {repo_match.group(1) if repo_match else 'Not found'}")
            print(f"  GPG Key Year:     {key_match.group(1) if key_match else 'Not found'}")
    except Exception:
        print("  Current Configured: Error reading file")
    
    print("  Compatibility Note: Ensure GPG key year matches current Jenkins rotation (2026 for debian, 2023 for debian-stable).")

if __name__ == "__main__":
    print("==================================================")
    print("  Infrastructure Dependency & Compatibility Audit ")
    print("==================================================")
    
    # Run sequentially for consistent output formatting
    check_terraform_aws()
    check_ansible_aws()
    check_sonarqube()
    check_jenkins()
    check_java()
    
    print("-" * 50)
    print("Audit Complete.")
