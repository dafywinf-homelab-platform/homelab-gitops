#!/usr/bin/env bash
# Seal a Secret for this repo: prompts for each key's value (hidden, never on the command line or in shell history),
# builds the Secret with `kubectl create secret --dry-run`, encrypts it with the controller's public key and writes a
# SealedSecret that is safe to commit. Usage (normally via `make seal`):
#   scripts/seal-secret.sh <namespace> <name> <output.yaml> <key> [<key> ...]
# Values are read from the terminal, or one per line from stdin when piped.
set -euo pipefail

if [ $# -lt 4 ]; then
  echo "usage: $0 <namespace> <name> <output.yaml> <key> [<key> ...]" >&2
  exit 2
fi
namespace=$1 name=$2 out=$3
shift 3

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cert=${SEALED_SECRETS_CERT:-$repo_root/sealed-secrets/pub-cert.pem}

# Values go into a private temp dir, not into process arguments, and are removed on exit
tmp=$(mktemp -d)
chmod 700 "$tmp"
trap 'rm -rf "$tmp"' EXIT

from_files=()
for key in "$@"; do
  if [ -t 0 ]; then
    read -r -s -p "$namespace/$name $key: " value
    echo >&2
  else
    IFS= read -r value
  fi
  if [ -z "$value" ]; then
    echo "empty value for $key" >&2
    exit 1
  fi
  printf '%s' "$value" > "$tmp/$key"
  from_files+=("--from-file=$key=$tmp/$key")
done

{
  echo "# SealedSecret for Secret $namespace/$name (keys: $*). Safe to commit: only the sealed-secrets controller in the"
  echo "# cluster can decrypt it. Re-create with scripts/seal-secret.sh (make seal); never edit the ciphertext."
  kubectl create secret generic "$name" --namespace "$namespace" "${from_files[@]}" --dry-run=client -o yaml \
    | kubeseal --cert "$cert" --format yaml
} > "$out"
echo "wrote $out (commit it; Argo CD applies it and the controller creates Secret $namespace/$name)" >&2
