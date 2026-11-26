# vmquickstart

Quick-start scripts for freshly installed Debian/Ubuntu VMs.

## `setup-github-runner.sh`

Interactive installer for a **GitHub Actions self-hosted runner**:

- creates a dedicated `github-runner` user (optional passwordless sudo)
- optionally installs **Docker** from the official repo and adds the runner user to the `docker` group
- downloads the latest [actions/runner](https://github.com/actions/runner) release for your CPU (x64 / arm64 / arm) and verifies its SHA-256
- prompts for the repo/org URL, registration token, runner name, labels, work folder and runner group
- registers the runner, then installs and starts it as a systemd service (`svc.sh`)

Safe to re-run: steps that are already done are skipped.

### Usage

Run on the server as root:

```bash
curl -fsSL https://raw.githubusercontent.com/sobhydo/vmquickstart/main/setup-github-runner.sh -o setup-github-runner.sh
sudo bash setup-github-runner.sh
```

Get the registration token from **Repo (or Org) → Settings → Actions → Runners → New self-hosted runner** (valid for 1 hour).

When it finishes, the runner shows as **Idle** in that Runners page.

### Manage the runner

```bash
cd /home/github-runner/actions-runner
sudo ./svc.sh status   # or stop | start | uninstall
```
