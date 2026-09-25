#!/usr/bin/env bash
# Validate the chart without a cluster or registry access.
set -euo pipefail
cd "$(dirname "$0")/charts/monty"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
chart=.
helm lint --strict "$chart" --set-string image.tag=local
helm template monty "$chart" --namespace monty \
  --set-string image.tag=local > "$tmp/ephemeral.yaml"
if grep -q 'MONTY_SERVER_OBJECT_STORE_URI' "$tmp/ephemeral.yaml"; then
  echo 'ephemeral mode unexpectedly configured a store' >&2
  exit 1
fi

prod_args=(
  -f values.prod.yaml --set-string image.tag=test-build
  --set gateway.gatewayClassName=test-gateway
  --set-string 'networkPolicy.ingressController.namespaceLabels.kubernetes\.io/metadata\.name=gateway-system'
  --set-string 'networkPolicy.ingressController.podLabels.app=proxy'
)
helm lint --strict "$chart" -f values.dev.yaml --set-string image.tag=test-build
helm template monty "$chart" --namespace monty \
  -f values.dev.yaml --set-string image.tag=test-build > "$tmp/dev.yaml"
helm lint --strict "$chart" "${prod_args[@]}"
helm template monty "$chart" --namespace monty "${prod_args[@]}" > "$tmp/prod.yaml"
helm template monty "$chart" --namespace monty "${prod_args[@]}" \
  --output-dir "$tmp/rendered" > /dev/null

helm template monty "$chart" --namespace monty "${prod_args[@]}" \
  --set gateway.enabled=false --set ingress.enabled=true \
  --set ingress.ingressClassName=test-ingress --set 'ingress.hostnames[0]=monty.example.com' \
  --set ingress.secretName=monty-tls \
  --set-string 'ingress.annotations.example\.com/auth=monty-auth' > "$tmp/ingress.yaml"
helm template custom "$chart" --namespace alternate "${prod_args[@]}" \
  --set 'gateway.hostnames[1]=other.example.com' \
  --set-json 'gateway.filters=[{"type":"ExtensionRef","extensionRef":{"group":"example.com","kind":"AuthPolicy","name":"monty-auth"}}]' \
  --set-json 'extraObjects=[{"apiVersion":"example.com/v1","kind":"AuthPolicy","metadata":{"name":"monty-auth"},"spec":{"targetRef":{"name":"custom-server"}}}]' \
  > "$tmp/auth-policy.yaml"
grep -q '^kind: AuthPolicy$' "$tmp/auth-policy.yaml"
grep -q 'type: ExtensionRef' "$tmp/auth-policy.yaml"
grep -q 'name: https-1' "$tmp/auth-policy.yaml"
grep -q 'name: custom-server' "$tmp/auth-policy.yaml"
grep -q 'app.kubernetes.io/instance: "custom"' "$tmp/auth-policy.yaml"

helm template monty "$chart" --namespace monty "${prod_args[@]}" \
  --set gateway.create=false --set gateway.name=shared \
  --set gateway.namespace=gateway-system --set gateway.sectionName=https \
  > "$tmp/existing-gateway.yaml"

helm package "$chart" --app-version test-version --destination "$tmp" > /dev/null
package=$(find "$tmp" -maxdepth 1 -name '*.tgz')
helm template monty "$package" -f values.dev.yaml > "$tmp/app-version.yaml"
helm template monty "$package" -f values.dev.yaml --set-string image.tag=override \
  > "$tmp/image-override.yaml"
for component in server worker; do
  grep -q "monty-$component:test-version" "$tmp/app-version.yaml"
  grep -q "monty-$component:override" "$tmp/image-override.yaml"
done

helm lint --strict "$chart" -f values.dev.yaml \
  --set image.repository=localhost --set-string image.tag=local --set image.pullPolicy=Never
helm template monty "$chart" --namespace monty -f values.dev.yaml \
  --set image.repository=localhost --set-string image.tag=local \
  --set image.pullPolicy=Never > "$tmp/dev-local.yaml"

# Storage credentials are referenced, not generated or copied by the chart.
for manifest in ephemeral dev prod; do
  if grep -q '^kind: Secret$' "$tmp/$manifest.yaml"; then
    echo "$manifest unexpectedly rendered a Secret" >&2
    exit 1
  fi
done

for manifest in ephemeral dev prod; do
  if grep -q 'name: LOGFIRE_TOKEN' "$tmp/$manifest.yaml"; then
    echo "$manifest unexpectedly configured Logfire" >&2
    exit 1
  fi
done

for target in server worker both; do
  logfire_args=(--set-string image.tag=test-build)
  for component in server worker; do
    if [[ "$target" == both || "$target" == "$component" ]]; then
      logfire_args+=(--set-json "$component.env.LOGFIRE_TOKEN={\"valueFrom\":{\"secretKeyRef\":{\"name\":\"monty-logfire-$component\",\"key\":\"token\"}}}")
    fi
  done
  helm lint --strict "$chart" "${logfire_args[@]}"
  helm template monty "$chart" --namespace monty "${logfire_args[@]}" > "$tmp/logfire.yaml"
  if grep -q '^kind: Secret$' "$tmp/logfire.yaml"; then
    echo 'Logfire token Secret unexpectedly rendered' >&2
    exit 1
  fi
  for component in server worker; do
    awk -v component="$component" 'BEGIN {RS="---"} /kind: Deployment/ && $0 ~ "name: monty-" component {print}' \
      "$tmp/logfire.yaml" > "$tmp/logfire-$component.yaml"
    if [[ "$target" == both || "$target" == "$component" ]]; then
      expected="            - name: LOGFIRE_TOKEN
              valueFrom:
                secretKeyRef:
                  key: token
                  name: monty-logfire-$component"
      if [[ $(< "$tmp/logfire-$component.yaml") != *"$expected"* ]]; then
        echo "Logfire Secret reference missing from $component" >&2
        exit 1
      fi
    elif grep -q 'LOGFIRE_TOKEN' "$tmp/logfire-$component.yaml"; then
      echo "Logfire configuration leaked to $component" >&2
      exit 1
    fi
  done
done
helm template monty "$chart" --set-string image.tag=test-build \
  --set-string server.env.LOGFIRE_TOKEN=test-only-plain-token \
  --set-json 'worker.env.LOGFIRE_TOKEN={"value":"test-only-value-token"}' > "$tmp/logfire-literals.yaml"
grep -q 'value: "test-only-plain-token"' "$tmp/logfire-literals.yaml"
grep -q 'value: test-only-value-token' "$tmp/logfire-literals.yaml"

grep -q 'value: "memory://"' "$tmp/dev.yaml"
grep -q 'value: "s3://monty-sessions/production"' "$tmp/prod.yaml"
grep -q '^kind: ServiceAccount$' "$tmp/prod.yaml"
grep -q 'serviceAccountName: "monty-server"' "$tmp/prod.yaml"
if grep -q 'MONTY_SERVER_DUMP_KEY\|checksum/dump-key' "$tmp/dev.yaml" "$tmp/prod.yaml"; then
  echo 'obsolete dump key configuration rendered' >&2
  exit 1
fi

storage_args=(
  --set-string image.tag=test-build
  --set-string 'objectStore.uri=gs://sessions/{{ .Release.Name }}'
  --set serviceAccount.create=true
  --set-string 'serviceAccount.annotations.iam\.gke\.io/gcp-service-account=monty@example.iam.gserviceaccount.com'
  --set-json 'objectStore.env={"GOOGLE_SERVICE_ACCOUNT":"/var/run/monty-storage/key.json","AWS_REGION":"{{ .Release.Namespace }}","AWS_ACCESS_KEY_ID":{"valueFrom":{"secretKeyRef":{"name":"monty-object-store","key":"access-key"}}},"AWS_ALLOW_HTTP":{"value":"false"}}'
  --set-json 'objectStore.volumes=[{"name":"object-store-credentials","secret":{"secretName":"monty-object-store"}}]'
  --set-json 'objectStore.volumeMounts=[{"name":"object-store-credentials","mountPath":"/var/run/monty-storage","readOnly":true}]'
)
helm lint --strict "$chart" "${storage_args[@]}"
helm template monty "$chart" --namespace test-region "${storage_args[@]}" > "$tmp/storage.yaml"
helm template monty "$chart" --namespace test-region "${storage_args[@]}" \
  --show-only templates/deployments.yaml > "$tmp/storage-deployments.yaml"
awk 'BEGIN {RS="---"} /name: monty-server/ {print}' "$tmp/storage-deployments.yaml" > "$tmp/storage-server.yaml"
awk 'BEGIN {RS="---"} /name: monty-worker/ {print}' "$tmp/storage-deployments.yaml" > "$tmp/storage-worker.yaml"
grep -q 'value: "gs://sessions/monty"' "$tmp/storage-server.yaml"
grep -q 'value: "test-region"' "$tmp/storage-server.yaml"
grep -q 'secretKeyRef:' "$tmp/storage-server.yaml"
grep -q 'name: monty-object-store' "$tmp/storage-server.yaml"
grep -q 'mountPath: /var/run/monty-storage' "$tmp/storage-server.yaml"
grep -q 'readOnly: true' "$tmp/storage-server.yaml"
grep -q 'fsGroup: 65532' "$tmp/storage-server.yaml"
grep -q 'startupProbe:' "$tmp/storage-server.yaml"
grep -q 'serviceAccountName: "monty-server"' "$tmp/storage-server.yaml"
grep -q 'iam.gke.io/gcp-service-account: monty@example.iam.gserviceaccount.com' "$tmp/storage.yaml"
if grep -Eq 'OBJECT_STORE|GOOGLE_|AWS_|object-store-credentials|serviceAccountName:|volumeMounts:|volumes:' "$tmp/storage-worker.yaml"; then
  echo 'storage configuration leaked to the worker' >&2
  exit 1
fi
if grep -q '^kind: Secret$' "$tmp/storage.yaml"; then
  echo 'storage credential Secret unexpectedly rendered' >&2
  exit 1
fi

helm template monty "$chart" --set-string image.tag=test-build \
  --set serviceAccount.name=external-server > "$tmp/existing-account.yaml"
grep -q 'serviceAccountName: "external-server"' "$tmp/existing-account.yaml"
if grep -q '^kind: ServiceAccount$' "$tmp/existing-account.yaml"; then
  echo 'external service account unexpectedly recreated' >&2
  exit 1
fi
helm template monty "$chart" --set-string image.tag=test-build \
  --set objectStore.uri=file:///var/lib/monty-server \
  --set-json 'objectStore.volumes=[{"name":"sessions","emptyDir":{}}]' \
  --set-json 'objectStore.volumeMounts=[{"name":"sessions","mountPath":"/var/lib/monty-server"}]' \
  > "$tmp/file-store.yaml"
grep -q 'value: "file:///var/lib/monty-server"' "$tmp/file-store.yaml"
grep -q 'mountPath: /var/lib/monty-server' "$tmp/file-store.yaml"
for uri in s3://sessions/prod gs://sessions/prod az://sessions/prod; do
  helm template monty "$chart" --set-string image.tag=test-build \
    --set-string "objectStore.uri=$uri" > "$tmp/backend.yaml"
  grep -q "value: \"$uri\"" "$tmp/backend.yaml"
done

for component in server worker; do
  grep -q "image: \"localhost/monty-$component:local\"" "$tmp/dev-local.yaml"
done
[[ $(grep -c 'imagePullPolicy: Never' "$tmp/dev-local.yaml") -eq 2 ]]
[[ $(grep -c 'replicas: 1$' "$tmp/dev.yaml") -eq 2 ]]
[[ $(grep -c 'replicas: 2$' "$tmp/prod.yaml") -eq 2 ]]

for kind in Ingress Gateway HTTPRoute NetworkPolicy; do
  if grep -q "^kind: $kind$" "$tmp/dev.yaml"; then
    echo "development overlay unexpectedly rendered $kind" >&2
    exit 1
  fi
done
[[ $(grep -c '^kind: NetworkPolicy$' "$tmp/prod.yaml") -eq 2 ]]
grep -q '^kind: Gateway$' "$tmp/prod.yaml"
grep -q '^kind: HTTPRoute$' "$tmp/prod.yaml"
grep -q 'protocol: HTTPS' "$tmp/prod.yaml"
grep -q 'mode: Terminate' "$tmp/prod.yaml"
grep -q 'name: "monty-tls"' "$tmp/prod.yaml"
grep -q '^kind: Ingress$' "$tmp/ingress.yaml"
grep -q 'example.com/auth: monty-auth' "$tmp/ingress.yaml"
grep -q '^kind: HTTPRoute$' "$tmp/existing-gateway.yaml"
grep -q 'namespace: "gateway-system"' "$tmp/existing-gateway.yaml"
grep -q 'sectionName: "https"' "$tmp/existing-gateway.yaml"
if grep -q '^kind: Gateway$' "$tmp/existing-gateway.yaml"; then
  echo 'existing Gateway unexpectedly recreated' >&2
  exit 1
fi

# These exact blocks guard against OR-ing the namespace and pod selectors, or
# allowing workers to be reached from other releases/namespaces.
grep -F -A16 '  ingress:' "$tmp/rendered/monty/templates/networkpolicies.yaml" > "$tmp/policy-rules.yaml"
expected_server='    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: gateway-system
          podSelector:
            matchLabels:
              app: proxy
      ports:
        - protocol: TCP
          port: 8000'
expected_worker='    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: monty
              app.kubernetes.io/instance: "monty"
              app.kubernetes.io/component: server
      ports:
        - protocol: TCP
          port: 8000'
for expected in "$expected_server" "$expected_worker"; do
  if [[ $(< "$tmp/policy-rules.yaml") != *"$expected"* ]]; then
    echo 'NetworkPolicy peer/port rules did not match' >&2
    exit 1
  fi
done

# Confirm invalid inputs fail for the intended reason, not an unrelated error.
expect_failure() {
  local expected=$1
  shift
  if helm template monty "$chart" "$@" > "$tmp/output" 2> "$tmp/error"; then
    echo "expected rendering to fail: $*" >&2
    exit 1
  fi
  grep -F -- "$expected" "$tmp/error"
}

for environment in dev prod; do
  expect_failure 'tag' -f "values.$environment.yaml" --set-string image.tag=latest
done
expect_failure 'objectStore.uri' --set-string image.tag=test-build --set objectStore.uri=https://invalid
expect_failure 'server.replicas=1' -f values.dev.yaml --set-string image.tag=test-build --set server.replicas=2
expect_failure 'volumeMounts' --set-string image.tag=test-build --set objectStore.uri=file:///data
expect_failure 'objectStore' --set-string image.tag=test-build --set objectStore.env.AWS_ALLOW_HTTP=true
expect_failure 'objectStore' --set-string image.tag=test-build --set-json 'objectStore.env.BAD={"valueFrom":{}}'
expect_failure 'only one of objectStore.env or server.env' --set-string image.tag=test-build \
  --set-string objectStore.env.AWS_REGION=a --set-string server.env.AWS_REGION=b
expect_failure 'is managed by the chart' --set-string image.tag=test-build \
  --set-string objectStore.env.MONTY_SERVER_OBJECT_STORE_URI=memory://
expect_failure 'no longer supported' --set-string image.tag=test-build \
  --set-string server.env.MONTY_SERVER_DUMP_KEY=obsolete
expect_failure 'dumpKey' --set-string image.tag=test-build --set dumpKey=obsolete
expect_failure 'existingSecret' --set-string image.tag=test-build --set existingSecret=obsolete

expect_failure 'gateway.gatewayClassName' "${prod_args[@]}" --set-string gateway.gatewayClassName=
expect_failure 'gateway.hostnames' "${prod_args[@]}" --set-json 'gateway.hostnames=[]'
expect_failure 'gateway.tlsSecretName' "${prod_args[@]}" --set-string gateway.tlsSecretName=
expect_failure 'gateway.name' "${prod_args[@]}" --set gateway.create=false
expect_failure 'gateway.sectionName' "${prod_args[@]}" --set gateway.create=false --set gateway.name=shared
expect_failure 'only one' "${prod_args[@]}" --set ingress.enabled=true
expect_failure 'namespaceLabels' -f values.prod.yaml --set-string image.tag=test-build \
  --set gateway.gatewayClassName=test-gateway --set networkPolicy.ingressController.podLabels.app=proxy
expect_failure 'podLabels' -f values.prod.yaml --set-string image.tag=test-build \
  --set gateway.gatewayClassName=test-gateway --set networkPolicy.ingressController.namespaceLabels.name=gateway-system
expect_failure 'ingress.hostnames' "${prod_args[@]}" --set gateway.enabled=false --set ingress.enabled=true
expect_failure 'ingress.secretName' "${prod_args[@]}" --set gateway.enabled=false \
  --set ingress.enabled=true --set 'ingress.hostnames[0]=monty.example.com'

original_chart=$chart
helm package "$chart" --app-version latest --destination "$tmp" > /dev/null
chart=$package
expect_failure 'effective image tag' -f values.dev.yaml
chart=$original_chart

for component in server worker; do
  expect_failure 'LOGFIRE_TOKEN' --set-string image.tag=test-build \
    --set-json "$component.env.LOGFIRE_TOKEN={\"valueFrom\":{}}"
  expect_failure 'LOGFIRE_TOKEN' --set-string image.tag=test-build \
    --set-json "$component.env.LOGFIRE_TOKEN={\"value\":\"token\",\"valueFrom\":{\"secretKeyRef\":{\"name\":\"logfire\",\"key\":\"token\"}}}"
  expect_failure 'LOGFIRE_TOKEN' --set-string image.tag=test-build \
    --set "$component.env.LOGFIRE_TOKEN=true"
done
expect_failure 'is managed by the chart' --set-string image.tag=test-build \
  --set-json 'server.env.MONTY_SERVER_WORKER_URL={"valueFrom":{"secretKeyRef":{"name":"other-worker","key":"url"}}}'

expect_failure 'tag' --set-string image.tag=latest
expect_failure 'is managed by the chart' --set-string image.tag=local \
  --set-string server.env.MONTY_SERVER_WORKER_URL=other-worker
expect_failure 'is managed by the chart' --set-string image.tag=local \
  --set-string server.env.MONTY_SERVER_OBJECT_STORE_URI=memory://
expect_failure 'is managed by the chart' --set-string image.tag=local \
  --set-string worker.env.MONTY_WORKER_DRAIN_GRACE=60
expect_failure 'MONTY_WORKER_MAX_SESSIONS' --set-string image.tag=local \
  --set worker.env.MONTY_WORKER_MAX_SESSIONS=4

echo 'Chart validation passed.'
