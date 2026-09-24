#!/usr/bin/env bash

# Shared, read-only cluster checks for install-release.sh and upgrade-release.sh.

check_required_cluster_resources() {
  local rendered_resources="$1"
  local namespace="$2"
  local repo_root="$3"
  local required_resources resource_kind resource_name resource_contract
  local storage_classes resource_json

  echo 'Preflight: checking cluster storage, ingress, and external workload resources'
  required_resources="$(ruby "${repo_root}/scripts/required-cluster-resources.rb" \
    <<<"${rendered_resources}")"
  while IFS=$'\t' read -r resource_kind resource_name resource_contract; do
    [[ -n "${resource_kind}" ]] || continue
    case "${resource_kind}" in
      DefaultStorageClass)
        storage_classes="$(kubectl get storageclass --output=json)" || {
          echo 'unable to inspect StorageClasses' >&2
          return 1
        }
        jq --exit-status '
          any(
            .items[];
            .metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true" or
            .metadata.annotations["storageclass.beta.kubernetes.io/is-default-class"] == "true"
          )
        ' <<<"${storage_classes}" >/dev/null || {
          echo 'a rendered PVC relies on a default StorageClass, but none is configured' >&2
          return 1
        }
        ;;
      StorageClass)
        kubectl get "${resource_kind}" "${resource_name}" >/dev/null || {
          echo "required ${resource_kind} ${resource_name} does not exist" >&2
          return 1
        }
        ;;
      IngressClass)
        resource_json="$(kubectl get "${resource_kind}" "${resource_name}" --output=json)" || {
          echo "required ${resource_kind} ${resource_name} does not exist" >&2
          return 1
        }
        if [[ -n "${resource_contract}" ]]; then
          jq --exit-status --arg controller "${resource_contract}" \
            '.spec.controller == $controller' <<<"${resource_json}" >/dev/null || {
            echo "IngressClass ${resource_name} is not managed by required controller ${resource_contract}" >&2
            return 1
          }
        fi
        ;;
      APIService)
        resource_json="$(kubectl get apiservice "${resource_name}" --output=json)" || {
          echo "required APIService ${resource_name} does not exist" >&2
          return 1
        }
        if [[ "${resource_contract}" == 'Available' ]]; then
          jq --exit-status '
            any(
              .status.conditions[]?;
              .type == "Available" and .status == "True"
            )
          ' <<<"${resource_json}" >/dev/null || {
            echo "APIService ${resource_name} is not Available; autoscaling cannot read resource metrics" >&2
            return 1
          }
        fi
        ;;
      PersistentVolumeClaim | ServiceAccount)
        kubectl --namespace "${namespace}" get "${resource_kind}" "${resource_name}" >/dev/null || {
          echo "required ${resource_kind} ${namespace}/${resource_name} does not exist" >&2
          return 1
        }
        ;;
      *)
        echo "unsupported preflight resource kind: ${resource_kind}" >&2
        return 1
        ;;
    esac
  done <<<"${required_resources}"
}

check_required_secrets() {
  local rendered_resources="$1"
  local namespace="$2"
  local repo_root="$3"
  local required_secrets secret_name secret_keys secret_json secret_key
  local -a keys

  echo 'Preflight: checking externally managed Secrets and referenced keys'
  required_secrets="$(ruby "${repo_root}/scripts/required-secrets.rb" \
    <<<"${rendered_resources}")"
  while IFS=$'\t' read -r secret_name secret_keys; do
    [[ -n "${secret_name}" ]] || continue
    secret_json="$(kubectl --namespace "${namespace}" get secret \
      "${secret_name}" --output=json)" || {
      echo "required Secret ${namespace}/${secret_name} does not exist" >&2
      return 1
    }
    [[ -n "${secret_keys}" ]] || continue
    IFS=',' read -r -a keys <<<"${secret_keys}"
    for secret_key in "${keys[@]}"; do
      jq --exit-status --arg key "${secret_key}" '.data[$key] != null' \
        <<<"${secret_json}" >/dev/null || {
        echo "required key ${secret_key} does not exist in Secret ${namespace}/${secret_name}" >&2
        return 1
      }
    done
  done <<<"${required_secrets}"
}
