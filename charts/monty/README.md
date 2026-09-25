# Monty Helm chart

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square)
[![Test Chart](https://github.com/pydantic/monty-helm-chart/actions/workflows/pr.yaml/badge.svg)](https://github.com/pydantic/monty-helm-chart/actions/workflows/pr.yaml)

Helm chart for self-hosted Pydantic Full Monty.

This repository and the chart source it contains are licensed under the [MIT License](LICENSE).
Deploying the official self-hosted Pydantic Full Monty product requires separate commercial access to private container images.
**Self-hosted Full Monty is an Enterprise offering that requires a contract and payment.**
Please contact [sales@pydantic.dev](mailto:sales@pydantic.dev) to discuss setting up a contract and pricing.

## Install Paths

- **Local evaluation**: use [values.dev.yaml](https://github.com/pydantic/monty-helm-chart/blob/main/charts/monty/values.dev.yaml), with in-memory session storage and one replica per service.
- **Live deployment**: start from [values.prod.yaml](https://github.com/pydantic/monty-helm-chart/blob/main/charts/monty/values.prod.yaml), which uses shared object storage,
  enables Gateway API and NetworkPolicy, and runs two replicas per service.
  Replace its routing placeholders for your environment.

Choose one overlay; do not layer development values into a live deployment. `values.dev.yaml` is only
for evaluation and testing.

Both paths install from this source repository and use the chart's `appVersion` for the application
images. For a local cluster or source builds, see [Local Development](#local-development).

## Install the Chart

### 1. Get the Chart

```zsh
git clone https://github.com/pydantic/monty-helm-chart.git
cd monty-helm-chart
```

The following examples use `monty` for both the release name and namespace. If you change the release
name, adjust the Service and Deployment names in subsequent commands. Run the commands below from
the repository root; the chart is in `charts/monty`.

### 2. Image Configuration

Both service images default to the `appVersion` in [Chart.yaml](https://github.com/pydantic/monty-helm-chart/blob/main/charts/monty/Chart.yaml). You do not need to select
an image version separately when installing a released chart. `image.tag` is an optional override,
primarily for local builds; it applies to both services. `latest` is not supported.

If you mirror the images, keep them aligned with the chart's `appVersion`. Set `image.repository` to
their shared registry path, without the `monty-server` or `monty-worker` suffix.

Official Full Monty images are private. Create an image pull Secret in the release namespace and
reference it through `imagePullSecrets`; see [Image Pull Credentials](#image-pull-credentials).
The development and production overlays reference `monty-image-key`.

### 3a. Local Evaluation

Use the checked-in [values.dev.yaml](https://github.com/pydantic/monty-helm-chart/blob/main/charts/monty/values.dev.yaml):

```zsh
helm upgrade --install monty charts/monty \
  --namespace monty --create-namespace \
  -f charts/monty/values.dev.yaml \
  --wait --timeout 5m
```

The development overlay stores sessions in the server's memory. It needs no external object store,
but restarting or replacing the server loses all saved sessions. This is **only for local testing**.
If you need a local cluster first, follow [Local Development](#local-development).

### 3b. Live Deployment

Copy [values.prod.yaml](https://github.com/pydantic/monty-helm-chart/blob/main/charts/monty/values.prod.yaml) to a deployment-specific values file:

```zsh
cp charts/monty/values.prod.yaml values.live.yaml
```

Replace the hostname, GatewayClass, TLS Secret name, and controller pod/namespace selectors in
`values.live.yaml`. The starter uses Gateway API; alternatively, disable `gateway.enabled` and
configure `ingress` with your controller's settings.

Replace `objectStore.uri` with your shared bucket and prefix, and configure credentials through
`objectStore.env`, mounted Secrets, or the server's service account. See [Object Storage](#object-storage).

Before installing, confirm that you have:

- Provisioned shared object storage writable only by the server, with read/write credentials and lifecycle rules.
- Configured `imagePullSecrets` for the private images.
- Reviewed CPU, memory, and session limits for your workload; the starter inherits the base resource budgets.
- Installed a suitable Ingress or Gateway controller (and Gateway API CRDs if using Gateway API).
- Provisioned a TLS certificate Secret and DNS for your public hostname.
- Enabled NetworkPolicy enforcement in your CNI and selected the correct ingress/gateway data-plane pods.
- Reviewed [Production Considerations](#production-considerations), including availability and worker isolation.

Install with your customized values file:

```zsh
helm upgrade --install monty charts/monty \
  --namespace monty --create-namespace \
  -f values.live.yaml \
  --wait --timeout 5m
```

The starter runs two server and two worker replicas, but does not configure pod spreading,
disruption budgets, or autoscaling. Multiple replicas alone do not guarantee high availability or
session continuity. All server replicas must use the same object store and prefix.

### 4. Verify and Connect

For local evaluation, or an administrator's direct smoke test:

```zsh
kubectl -n monty get pods
kubectl -n monty port-forward svc/monty-server 8000:8000
```

In another terminal:

```zsh
curl --fail http://localhost:8000/health
curl --fail --header 'Content-Type: text/plain' \
  --data-binary '1 + 1' http://localhost:8000/run
```

The second command should print `2`. It exercises the server, worker, and sandbox subprocess;
`/health` alone does not check worker connectivity.

Alternatively, open <http://localhost:8000> and use the try-it form. WebSocket clients connect to
`ws://localhost:8000/`. The client's Monty protocol version must match the images; for local builds,
use the client pinned in the corresponding Monty source checkout.

For live deployments, connect through `https://<your-hostname>` or `wss://<your-hostname>/`.
Port-forwarding does not test TLS or NetworkPolicy.

## Configuration Notes

### Hostnames and Exposure

Choose either Ingress or Gateway API, not both. Routing always targets the server; the worker has no
public route. Both options support multiple hostnames and existing TLS certificate Secrets.

Load balancers may close WebSocket connections after a timeout (30 seconds by default on GKE); raise it through your Ingress controller or Gateway implementation to cover your longest sessions. When a server pod terminates, the load balancer must keep its WebSocket connections open for at least `drainGraceSeconds` (connection draining, disabled by default on GKE); otherwise clients miss the server's shutdown message and cannot automatically resume.

For an Ingress, configure your installed controller:

```yaml
gateway:
  enabled: false
ingress:
  enabled: true
  ingressClassName: YOUR_INGRESS_CLASS
  hostnames:
    - monty.example.com
  tls: true
  secretName: monty-tls
  annotations: {}
```

Add your controller's WebSocket settings under `ingress.annotations`. TLS settings
alone do not necessarily disable HTTP: configure HTTPS enforcement or redirection in your controller.
The TLS Secret must be in the release namespace and cover all configured hostnames.

The production starter instead creates a Gateway and HTTPRoute. Set `gateway.gatewayClassName` to
an installed GatewayClass. With `gateway.tls: true`, the chart creates only HTTPS listeners on port 443;
certificate issuance and renewal are managed outside this chart.

To attach to an existing Gateway, set `gateway.create: false`, `gateway.name`, and
`gateway.sectionName` to its HTTPS listener name. Set `gateway.namespace` if it is in another namespace.
The existing listener must allow routes from the release namespace. Its owner manages TLS;
`gateway.tls` and `gateway.tlsSecretName` do not change an existing Gateway.

### Authentication

Coming soon.

### Network Isolation

`networkPolicy.enabled` creates ingress policies for both components:

- The server accepts TCP port 8000 only from pods matching **both**
  `networkPolicy.ingressController.namespaceLabels` and `podLabels`.
- The worker accepts TCP port 8000 only from server pods of the same release in the same namespace.

Set these selectors to the actual ingress/gateway **data-plane** pods, not just the controller's
control plane. Empty selectors are rejected. A CNI that enforces NetworkPolicy is essential; creating
policies on an unsupported CNI provides no isolation. Other policies are additive and can broaden access.
These policies do not restrict egress or provide in-cluster TLS.

For managed gateways without selectable data-plane pods, manage equivalent policies using your
provider's networking controls and disable the chart's policies. Do not allow arbitrary pods or namespaces
to reach either service. Kubernetes API/port-forward access and permission to create or relabel workloads
must remain restricted to trusted operators.

### Object Storage

The server stores session state in an object store; clients hold session IDs, not snapshot bytes.
Configure `objectStore.uri` with `s3://bucket/prefix`, `gs://bucket/prefix`, or `az://container/prefix`
for live deployments. All server replicas must share the same store and prefix. The chart does not
create buckets or manage their lifecycle rules.

```yaml
objectStore:
  uri: s3://monty-sessions/production
  env:
    AWS_REGION: us-east-1
    AWS_ACCESS_KEY_ID:
      valueFrom:
        secretKeyRef:
          name: monty-object-store
          key: AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY:
      valueFrom:
        secretKeyRef:
          name: monty-object-store
          key: AWS_SECRET_ACCESS_KEY
```

Create the referenced Secret separately in the release namespace. `objectStore.env` accepts string
values or Kubernetes `valueFrom` references. Prefer Secret references to credentials in values files;
Helm stores supplied values in release history. The URI and string environment values support Helm
templating.

For credentials supplied as files, use `objectStore.volumes` and `objectStore.volumeMounts`. For example,
a Google service-account key can be mounted read-only and selected with `GOOGLE_SERVICE_ACCOUNT`:

```yaml
objectStore:
  uri: gs://monty-sessions/production
  env:
    GOOGLE_SERVICE_ACCOUNT: /var/run/monty-storage/key.json
  volumes:
    - name: object-store-credentials
      secret:
        secretName: monty-object-store
  volumeMounts:
    - name: object-store-credentials
      mountPath: /var/run/monty-storage
      readOnly: true
```

Alternatively, configure workload identity using `serviceAccount.create`, `serviceAccount.name`, and
`serviceAccount.annotations`. These apply **only to the server**; the worker receives neither that
identity nor the object-store environment or volumes. Configure your provider's IAM bindings and any
required projected tokens separately. Kubernetes API tokens are not automatically mounted. Do not
grant storage access to the namespace's default service account or the worker's node identity.

> **Important:** Only the server may write the bucket or prefix. Stored records are unsigned snapshots
> passed to the worker's deserializer; another writer could substitute crafted state. Keep storage
> credentials away from workers and untrusted workloads. Treat session IDs as sensitive capabilities.

The server probes storage with a write at startup and exits if it fails. Its startup probe allows
60 seconds before liveness checks begin, covering the default 30-second storage timeout. Session records live under
`monty/<session-id>` within the configured prefix; `monty-server-write-probe` is written beside them.
Records are not automatically deleted. Configure retention with bucket lifecycle rules, allowing for
how long clients need to resume sessions. Changing the store/prefix or expiring a record makes its ID
unavailable to clients.

For evaluation, `memory://` provides process-local storage and requires one server replica. Its records
consume server memory and disappear on restart; rolling updates can briefly run two isolated stores.
`file:///path` is also supported if you mount a writable volume at that path using the volume settings
above. The chart does not create a PVC. Leave the URI unset for ephemeral sessions: `Dump` and `Load`
are unavailable and shutdown cannot preserve session state.

Use `server.env` to configure `MONTY_SERVER_DEFAULT_PERSISTENCE` (`stored` or `ephemeral`),
`MONTY_SERVER_PARK_AFTER` (idle seconds before parking; default `60`, `0` disables), and
`MONTY_SERVER_STORE_TIMEOUT` (per-operation timeout in seconds; default `30`).

Changing a credential Secret does not restart server pods. After rotating environment credentials,
restart `deployment/monty-server` so the new values take effect.

### Image Pull Credentials

Contact [sales@pydantic.dev](mailto:sales@pydantic.dev) for image pull credentials. With the supplied
`key.json`, create the namespace and Secret:

```zsh
kubectl create namespace monty --dry-run=client -o yaml | kubectl apply -f -
kubectl -n monty create secret docker-registry monty-image-key \
  --docker-server=us-docker.pkg.dev \
  --docker-username=_json_key \
  --docker-password="$(<key.json)"
```

Both environment overlays reference this Secret:

```yaml
imagePullSecrets:
  - name: monty-image-key
```

Keep `key.json` out of source control. Host Podman credentials are not inherited by kind. Locally built
images loaded directly into kind do not need registry credentials.

### Logfire Telemetry (Optional)

Set `LOGFIRE_TOKEN` in `server.env` and/or `worker.env` to export traces to
[Pydantic Logfire](https://pydantic.dev/logfire). It is omitted by default: both services work normally
without it and log to stderr only. Configure both services to see server connection spans and worker
execution spans in the same trace.

Create a Secret in the release namespace containing a Logfire **write token**. The file below should
contain only the token, with no trailing newline:

```zsh
kubectl create namespace monty --dry-run=client -o yaml | kubectl apply -f -
kubectl -n monty create secret generic monty-logfire \
  --from-file=token=/path/to/logfire-token
```

Reference it in your deployment values file:

```yaml
server:
  env:
    LOGFIRE_TOKEN:
      valueFrom:
        secretKeyRef:
          name: monty-logfire
          key: token
worker:
  env:
    LOGFIRE_TOKEN:
      valueFrom:
        secretKeyRef:
          name: monty-logfire
          key: token
```

Each service can use its own Secret and token; use tokens for the same Logfire project for a combined
trace view. Omit the setting on either service to leave its trace export disabled. The chart does not
create the token Secret or read its contents into Helm release history. Avoid putting a token directly
in values or `--set` arguments, and do not commit token files.

After rotating the Secret, restart the services that use it to pick up the new token:

```zsh
kubectl -n monty rollout restart deployment/monty-server deployment/monty-worker
```

### Sizing and Environment

Server and worker replicas and resource budgets are configured independently. Base and development defaults:

| Component | Replicas | CPU request / limit | Memory request / limit |
| --- | --- | --- | --- |
| Server | 1 | 100m / 1 | 64Mi / 256Mi |
| Worker | 1 | 250m / 1 | 128Mi / 512Mi |

The production overlay increases both replica counts to two and inherits these per-pod resource budgets.

By default, each worker allows four sessions with a 32 MiB per-session memory limit, leaving room in
its container budget for subprocess overhead and type-checking. Revisit the worker's memory budget
when increasing either limit. Server session limits and per-client quotas are also **per pod**, not
cluster-wide.

Use `server.env` and `worker.env` for service environment settings. Entries may be strings,
`{value: "..."}`, or Kubernetes `{valueFrom: ...}` references. Quote literal numeric limits:

```yaml
server:
  env:
    MONTY_SERVER_MAX_SESSIONS: '8'
    MONTY_SERVER_MAX_SESSIONS_PER_CLIENT: '8'
worker:
  env:
    MONTY_WORKER_MAX_SESSIONS: '4'
    MONTY_WORKER_MAX_MEMORY_MIB: '32'
```

Host, port, drain grace, worker URL, and object-store URI settings are managed by the chart and cannot be
overridden through these maps, including through `valueFrom`. Use Secret references for credentials.

### Shutdown and Upgrades

Repeat the install command with your updated values file to upgrade. Always update server and worker
images together and keep the shared object-store URI stable.

Both services handle SIGTERM and drain for `drainGraceSeconds` (30 seconds by default). The pod
termination grace period adds 20 seconds for drain replies, slack, and margin. Readiness uses
`/health`, which returns 503 during drain; liveness uses `/robots.txt`, which remains available.
The images are shell-less; no shell-based lifecycle hook is needed.

Stored sessions park their state in the object store; shutdown events carry session IDs so compatible
clients can reconnect and resume on another server sharing the store. Ephemeral sessions cannot be
recovered this way. A killed server can lose changes since the last successful park; unfinished turns
may not reach a resumable boundary before the drain deadline. Stored snapshots remain interpreter-version
dependent, so do not assume seamless rolling upgrades when that version changes.

This chart targets the session-storage service API. When upgrading from the earlier dump-signing
model, remove `dumpKey` and `existingSecret` from your values and configure `objectStore` instead.
Previously exported signed dumps are not accepted as session IDs.

### Production Considerations

The production overlay configures routing, TLS references, and network isolation, but still needs
your cluster infrastructure. Before exposing it:

- Verify HTTPS, WebSocket access, and NetworkPolicy enforcement end to end.
- Confirm unrelated pods cannot connect directly to the server or worker.
- Review worker isolation (for example GKE Sandbox) and resource limits for your workload.
- Restrict object-store writes to the server and configure retention for stored sessions.
- Provide availability policies, autoscaling, and durable secret management appropriate to your deployment.

The chart does not install autoscaling, disruption budgets, persistent storage, or a sandbox runtime.

## Local Development

### Create a Cluster with Podman on macOS

Run these commands on your Mac, not inside a development container. Skip `podman machine init` if you
already have a machine, and skip `start` if it is running. Rust image builds benefit from at least
8 GiB of VM memory.

```zsh
brew install podman kind kubectl helm
podman machine init --cpus 4 --memory 8192
podman machine start
export KIND_EXPERIMENTAL_PROVIDER=podman
kind create cluster --name monty
kubectl config use-context kind-monty
```

Keep `KIND_EXPERIMENTAL_PROVIDER=podman` set for subsequent kind commands. Podman support in kind is
experimental; if cluster creation fails, consult [kind's rootless provider guide](https://kind.sigs.k8s.io/docs/user/rootless/).

### Build and Load Images

From the repository root, set `monty_source` to your Monty source checkout. Use a version with the
session-storage API, not an older dump-signing build. Build both images natively with the same tag; no registry credentials are needed. The first Rust build can take a while. The
`dev` profile is for local testing, not production.

```zsh
monty_source=/path/to/monty
for service in server worker; do
  podman build --build-arg CARGO_PROFILE=dev \
    --ignorefile "$monty_source/crates/monty-$service/Dockerfile.dockerignore" \
    -f "$monty_source/crates/monty-$service/Dockerfile" \
    -t "localhost/monty-${service}:local" "$monty_source" || break
  podman save --format docker-archive \
    -o "/tmp/monty-$service.tar" "localhost/monty-${service}:local" || break
  kind load image-archive --name monty "/tmp/monty-$service.tar" || break
done
```

Only continue once **both** images have loaded successfully:

```zsh
helm upgrade --install monty charts/monty \
  --namespace monty --create-namespace \
  -f charts/monty/values.dev.yaml \
  --set image.repository=localhost \
  --set-string image.tag=local \
  --set image.pullPolicy=Never \
  --set-json 'imagePullSecrets=[]' \
  --wait --timeout 5m
```

Then [verify and connect](#4-verify-and-connect). If you rebuild the same `local` tag, load both images
again and restart the Deployments:

```zsh
kubectl -n monty rollout restart deployment/monty-server deployment/monty-worker
```

Helm cannot detect changed image contents behind an unchanged tag. Prefer a fresh shared tag per build.

## Troubleshooting

Start with pod events and service logs:

```zsh
kubectl -n monty get pods
kubectl -n monty describe pods
kubectl -n monty logs deployment/monty-server
kubectl -n monty logs deployment/monty-worker
```

| Symptom | Check |
| --- | --- |
| Helm rejects values | Complete the routing and policy placeholders, use a supported object-store URI, and quote environment values as strings. |
| `ImagePullBackOff` | Confirm both images exist for the selected tag and architecture, and any image pull Secret exists in the release namespace with valid credentials. |
| `ErrImageNeverPull` | Load both local images into the correct kind cluster and check that their names and tags match the Helm values. |
| `/health` works but `/run` fails | Check worker readiness and logs. Server health does not verify worker connectivity. |
| Pods remain `Pending` or are `OOMKilled` | Check cluster capacity, pod events, and resource budgets alongside session limits. |
| Server exits at startup | Check object-store credentials, write permissions, endpoint access, and the startup write-probe error in the server logs. |
| Session IDs cannot resume | Check the shared store/prefix, lifecycle expiry, interpreter compatibility, and whether an in-memory store was restarted. |
| Gateway or Ingress does not serve requests | Check controller events, Gateway/HTTPRoute acceptance, DNS, the TLS Secret, and NetworkPolicy data-plane selectors. |

For chart issues, [open a GitHub issue](https://github.com/pydantic/monty-helm-chart/issues) with the chart
version, `appVersion` (and any image override), Kubernetes version, sanitized values, and relevant logs. Do not include keys or credentials.

## Uninstall

```zsh
helm uninstall monty --namespace monty
```

External Secrets and object-store records are not removed by Helm. To delete a disposable local kind cluster as well:

```zsh
kind delete cluster --name monty
```

## Chart Validation

With Helm installed, run from the repository root:

```zsh
bash ci/check-chart.sh
```

This lints and renders the base chart and both environment overlays, checks routing, network policies,
server-only storage credentials and mounts, optional Logfire token references, `appVersion` fallback,
and rejection of invalid inputs. It does not create a cluster or
pull images; [Verify and Connect](#4-verify-and-connect) describes runtime checks.

Before publishing a chart release, maintainers must pin `appVersion` in `charts/monty/Chart.yaml` to the published
Monty application version. It is currently unset pending the first release; source builds can use
`image.tag` to select local images.

## Values

Base defaults are defined in [values.yaml](https://github.com/pydantic/monty-helm-chart/blob/main/charts/monty/values.yaml), with input validation in
[values.schema.json](https://github.com/pydantic/monty-helm-chart/blob/main/charts/monty/values.schema.json).
[values.dev.yaml](https://github.com/pydantic/monty-helm-chart/blob/main/charts/monty/values.dev.yaml) and
[values.prod.yaml](https://github.com/pydantic/monty-helm-chart/blob/main/charts/monty/values.prod.yaml) configure the install paths described above. The production overlay
leaves environment-specific routing and policy settings for you to complete.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `image.repository` | string | `"us-docker.pkg.dev/pydantic-public-registries/monty"` | Shared image path; the chart appends `/monty-server` or `/monty-worker`. |
| `image.tag` | string | `""` | Optional shared image version override; defaults to the chart's `appVersion`. `latest` is rejected. |
| `image.pullPolicy` | string | `"IfNotPresent"` | `Always`, `IfNotPresent`, or `Never`. Use `Never` for images loaded into kind. |
| `imagePullSecrets` | list | `[]` | Image pull Secret references, for example `[{name: gar-pull}]`. |
| `objectStore.uri` | string/null | `null` | Session-store URI. Unset means ephemeral sessions. Supports Helm templating. |
| `objectStore.env` | object | `{}` | Server-only storage settings: strings (with Helm templating), `{value: ...}`, or `{valueFrom: ...}`. |
| `objectStore.volumeMounts` | list | `[]` | Server-only mounts for storage credentials or a writable `file://` store. |
| `objectStore.volumes` | list | `[]` | Server-only volumes backing the mounts. |
| `serviceAccount.create` | bool | `false` | Create the server's ServiceAccount. No Kubernetes RBAC permissions are granted. |
| `serviceAccount.name` | string | `""` | Server ServiceAccount; defaults to `<release>-server` when creating, otherwise `default`. |
| `serviceAccount.annotations` | object | `{}` | Annotations on a chart-created server ServiceAccount, such as workload identity settings. |
| `drainGraceSeconds` | int | `30` | Shared drain window in seconds, minimum 0. Pod termination grace is this value plus 20 seconds. |
| `ingress.enabled` | bool | `false` | Create an Ingress for the server. Mutually exclusive with Gateway API. |
| `ingress.ingressClassName` | string | `""` | Installed IngressClass; empty uses the cluster default. |
| `ingress.hostnames` | list | `[]` | Public hostnames, required when Ingress is enabled. |
| `ingress.tls` | bool | `true` | Reference a TLS certificate on the Ingress. Configure HTTPS enforcement in the controller. |
| `ingress.secretName` | string | `""` | TLS Secret in the release namespace, required when Ingress TLS is enabled. |
| `ingress.annotations` | object | `{}` | Controller-specific settings, including WebSocket support. |
| `gateway.enabled` | bool | `false` | Create an HTTPRoute, optionally with a Gateway. Mutually exclusive with Ingress. |
| `gateway.create` | bool | `true` | Create a Gateway; otherwise attach to an existing one. |
| `gateway.gatewayClassName` | string | `""` | GatewayClass, required when creating a Gateway. |
| `gateway.name` | string | `""` | Defaults to `<release>-gateway` when creating; required for an existing Gateway. |
| `gateway.namespace` | string | `""` | Existing Gateway namespace; empty uses the release namespace. |
| `gateway.sectionName` | string | `""` | Required listener name for an existing Gateway; not used when creating one. |
| `gateway.hostnames` | list | `[]` | Public hostnames, required when Gateway API is enabled. |
| `gateway.tls` | bool | `true` | Create HTTPS rather than HTTP listeners. Does not configure an existing Gateway. |
| `gateway.tlsSecretName` | string | `""` | TLS Secret in the release namespace, required when creating a TLS Gateway. |
| `gateway.gatewayAnnotations` | object | `{}` | Annotations on a chart-created Gateway. |
| `gateway.annotations` | object | `{}` | Annotations on the HTTPRoute. |
| `gateway.filters` | list | `[]` | HTTPRoute filters supported by your controller. |
| `extraObjects` | list | `[]` | Additional Kubernetes manifests, rendered without Helm template evaluation. |
| `networkPolicy.enabled` | bool | `false` | Restrict server and worker ingress. Requires an enforcing CNI. |
| `networkPolicy.ingressController.namespaceLabels` | object | `{}` | Labels selecting the data-plane namespace. Required and nonempty when policies are enabled. |
| `networkPolicy.ingressController.podLabels` | object | `{}` | Labels selecting data-plane pods within that namespace. Required and nonempty when policies are enabled. |
| `server.replicas` | int | `1` | Server replica count, minimum 1. |
| `server.resources.requests.cpu` | string | `"100m"` | Server CPU request. |
| `server.resources.requests.memory` | string | `"64Mi"` | Server memory request. |
| `server.resources.limits.cpu` | string | `"1"` | Server CPU limit. |
| `server.resources.limits.memory` | string | `"256Mi"` | Server memory limit. |
| `server.env` | object | `{"MONTY_SERVER_MAX_SESSIONS":"8","MONTY_SERVER_MAX_SESSIONS_PER_CLIENT":"8"}` | Server environment settings: strings, `{value: ...}`, or `{valueFrom: ...}`. Optional `LOGFIRE_TOKEN` enables tracing; prefer a Secret reference. Chart-managed settings are reserved. |
| `worker.replicas` | int | `1` | Worker replica count, minimum 1. |
| `worker.resources.requests.cpu` | string | `"250m"` | Worker CPU request. |
| `worker.resources.requests.memory` | string | `"128Mi"` | Worker memory request. |
| `worker.resources.limits.cpu` | string | `"1"` | Worker CPU limit. |
| `worker.resources.limits.memory` | string | `"512Mi"` | Worker memory limit. |
| `worker.env` | object | `{"MONTY_WORKER_MAX_SESSIONS":"4","MONTY_WORKER_MAX_MEMORY_MIB":"32"}` | Worker environment settings: strings, `{value: ...}`, or `{valueFrom: ...}`. Optional `LOGFIRE_TOKEN` enables tracing; prefer a Secret reference. Review memory budgets when raising session limits. |
