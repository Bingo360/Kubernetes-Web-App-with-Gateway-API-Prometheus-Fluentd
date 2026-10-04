#!/usr/bin/env bash
# Обёртка для повторного запуска только addon-части без bootstrap кластера.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
./deploy.sh