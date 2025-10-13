#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    wget

release="$(lsb_release -rs)"
config_url="https://packages.microsoft.com/config/ubuntu/${release}/packages-microsoft-prod.deb"
if ! curl -fsSL "${config_url}" -o /tmp/packages-microsoft-prod.deb; then
    curl -fsSL "https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb" -o /tmp/packages-microsoft-prod.deb
fi

dpkg -i /tmp/packages-microsoft-prod.deb
rm -f /tmp/packages-microsoft-prod.deb

apt-get update
if ! apt-get install -y --no-install-recommends dotnet-sdk-9.0; then
    echo "APT-based .NET SDK install failed; falling back to dotnet-install script." >&2
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
    chmod +x /tmp/dotnet-install.sh
    /tmp/dotnet-install.sh --channel 9.0 --install-dir /usr/share/dotnet --no-path
    ln -sf /usr/share/dotnet/dotnet /usr/bin/dotnet
    rm -f /tmp/dotnet-install.sh
fi

if ! apt-get install -y --no-install-recommends powershell; then
    echo "APT-based PowerShell install failed; falling back to tarball deployment." >&2
    arch="$(dpkg --print-architecture)"
    case "$arch" in
        amd64) pwsh_package="powershell-7.4.4-linux-x64.tar.gz" ;;
        arm64) pwsh_package="powershell-7.4.4-linux-arm64.tar.gz" ;;
        *)
            echo "Unsupported architecture for PowerShell fallback: ${arch}" >&2
            exit 1
            ;;
    esac
    curl -fsSL "https://github.com/PowerShell/PowerShell/releases/latest/download/${pwsh_package}" -o /tmp/powershell.tar.gz
    install_dir="/opt/microsoft/powershell/7"
    mkdir -p "$install_dir"
    tar -xzf /tmp/powershell.tar.gz -C "$install_dir"
    chmod +x "$install_dir/pwsh"
    ln -sf "$install_dir/pwsh" /usr/bin/pwsh
    rm -f /tmp/powershell.tar.gz
fi

curl -sL https://aka.ms/InstallAzureCLIDeb | bash

if command -v az >/dev/null 2>&1; then
    az config set extension.use_dynamic_install=yes_without_prompt >/dev/null
    if ! az extension show --name azure-devops >/dev/null 2>&1; then
        az extension add --name azure-devops --only-show-errors --yes
    fi
else
    echo "Azure CLI installation failed." >&2
    exit 1
fi

if ! command -v pwsh >/dev/null 2>&1; then
    echo "PowerShell 7 executable not detected after installation." >&2
    exit 1
fi

apt-get clean
rm -rf /var/lib/apt/lists/*
