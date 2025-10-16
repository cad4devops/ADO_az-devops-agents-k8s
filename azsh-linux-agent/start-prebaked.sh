#!/bin/bash
set -e

# Optional fast-path: allow skipping Azure DevOps agent configuration for local DinD/image validation
if [ "${SKIP_AGENT_CONFIG}" = "true" ]; then
  echo "[Startup] SKIP_AGENT_CONFIG=true: skipping Azure DevOps agent registration."
  # Still honour DinD if requested (ENABLE_DIND handled below this block if we move it earlier)
  # We move DinD bootstrap earlier so it is available during skip mode.
fi

# Optional: start Docker daemon for DinD if requested and running as root (do this early so both normal & skip paths can use it)
if [ "${ENABLE_DIND}" = "true" ]; then
  if [ "$(id -u)" != "0" ]; then
    echo "ENABLE_DIND=true but current user is not root; skipping dockerd startup." >&2
  else
    echo "[DinD] Starting Docker daemon..."
    # Create required dirs
    mkdir -p /var/lib/docker /var/run
    # Best-effort cleanup of any stale lock/socket
    rm -f /var/run/docker.pid /var/run/docker.sock || true
    # Launch dockerd in background
    dockerd --host=unix:///var/run/docker.sock ${DOCKER_DAEMON_ARGS:-} &
    dind_pid=$!
    # Wait for readiness
    tries=0
    until docker info >/dev/null 2>&1; do
      tries=$((tries+1))
      if [ $tries -ge 30 ]; then
        echo "[DinD] Docker daemon failed to become ready after $tries attempts." >&2
        break
      fi
      sleep 1
    done
    if docker info >/dev/null 2>&1; then
      echo "[DinD] Docker daemon is ready." 
    fi
    # Ensure daemon stops on exit
    cleanup_dind() { if [ -n "$dind_pid" ] && kill -0 $dind_pid 2>/dev/null; then echo "[DinD] Stopping Docker daemon"; kill $dind_pid; wait $dind_pid || true; fi; }
    trap cleanup_dind EXIT INT TERM
  fi
fi

# If skipping agent config, keep container alive after optional DinD start
if [ "${SKIP_AGENT_CONFIG}" = "true" ]; then
  # Provide a simple health loop so container stays up but is easily stoppable
  echo "[Startup] Container entering idle loop (DinD: ${ENABLE_DIND:-false}). Set SKIP_AGENT_CONFIG=false to enable agent."
  trap 'echo "[Startup] Caught termination signal, exiting."; exit 0' INT TERM
  while true; do sleep 3600; done
fi

if [ -z "${AZP_URL}" ]; then
  echo 1>&2 "error: missing AZP_URL environment variable (unset SKIP_AGENT_CONFIG or supply AZP_URL to proceed)"
  exit 1
fi

if [ -n "$AZP_CLIENTID" ]; then
  echo "Using service principal credentials to get token"
  az login --allow-no-subscriptions --service-principal --username "$AZP_CLIENTID" --password "$AZP_CLIENTSECRET" --tenant "$AZP_TENANTID"
  # adapted from https://learn.microsoft.com/en-us/azure/databricks/dev-tools/user-aad-token
  AZP_TOKEN=$(az account get-access-token --query accessToken --output tsv)
  echo "Token retrieved"
fi

if [ -z "${AZP_TOKEN_FILE}" ]; then
  if [ -z "${AZP_TOKEN}" ]; then
    echo 1>&2 "error: missing AZP_TOKEN environment variable"
    exit 1
  fi

  AZP_TOKEN_FILE="/azp/.token"
  echo -n "${AZP_TOKEN}" > "${AZP_TOKEN_FILE}"
fi

unset AZP_CLIENTSECRET
unset AZP_TOKEN

if [ -n "${AZP_WORK}" ]; then
  mkdir -p "${AZP_WORK}"
fi

cleanup() {
  trap "" EXIT

  if [ -e ./config.sh ]; then
    print_header "Cleanup. Removing Azure Pipelines agent..."

    # If the agent has some running jobs, the configuration removal process will fail.
    # So, give it some time to finish the job.
    while true; do
  ./config.sh remove --unattended --auth "PAT" --token "$(cat "${AZP_TOKEN_FILE}")" && break

      echo "Retrying in 30 seconds..."
      sleep 30
    done
  fi
}

print_header() {
  lightcyan="\033[1;36m"
  nocolor="\033[0m"
  echo -e "\n${lightcyan}$1${nocolor}\n"
}

# Let the agent ignore the token env variables
export VSO_AGENT_IGNORE="AZP_TOKEN,AZP_TOKEN_FILE"

# Check if agent was pre-baked into the image
if [ -d "/azp/agent" ] && [ -f "/azp/agent/config.sh" ]; then
  print_header "Using pre-baked Azure Pipelines agent (no download required)"
  cd /azp/agent
else
  # Fallback: Download agent if not pre-baked (backward compatibility)
  print_header "1. Determining matching Azure Pipelines agent..."

  AZP_AGENT_PACKAGES=$(curl -LsS \
  -u "user:$(cat "${AZP_TOKEN_FILE}")" \
      -H "Accept:application/json" \
      "${AZP_URL}/_apis/distributedtask/packages/agent?platform=${TARGETARCH}&top=1")

  AZP_AGENT_PACKAGE_LATEST_URL=$(echo "${AZP_AGENT_PACKAGES}" | jq -r ".value[0].downloadUrl")

  if [ -z "${AZP_AGENT_PACKAGE_LATEST_URL}" ] || [ "${AZP_AGENT_PACKAGE_LATEST_URL}" = "null" ]; then
  echo 1>&2 "error: could not determine a matching Azure Pipelines agent"
  echo 1>&2 "check that account ${AZP_URL} is correct and the token is valid for that account"
    exit 1
  fi

  print_header "2. Downloading and extracting Azure Pipelines agent..."

  curl -LsS "${AZP_AGENT_PACKAGE_LATEST_URL}" | tar -xz & wait $!
fi

source ./env.sh

trap "cleanup; exit 0" EXIT
trap "cleanup; exit 130" INT
trap "cleanup; exit 143" TERM

print_header "3. Configuring Azure Pipelines agent..."

# Despite it saying "PAT", it can be the token through the service principal
./config.sh --unattended \
  --agent "${AZP_AGENT_NAME:-$(hostname)}" \
  --url "${AZP_URL}" \
  --auth "PAT" \
  --token "$(cat "${AZP_TOKEN_FILE}")" \
  --pool "${AZP_POOL:-Default}" \
  --work "${AZP_WORK:-_work}" \
  --replace \
  --acceptTeeEula & wait $!

print_header "4. Running Azure Pipelines agent..."

chmod +x ./run.sh

# To be aware of TERM and INT signals call ./run.sh
# Running it with the --once flag at the end will shut down the agent after the build is executed
./run.sh "$@" & wait $!
