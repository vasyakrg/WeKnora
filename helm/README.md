# WeKnora Helm Chart

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/weknora)](https://artifacthub.io/packages/helm/weknora/weknora)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)

Helm chart for deploying [WeKnora](https://github.com/Tencent/WeKnora) - an AI-powered Knowledge RAG Platform.

## Overview

WeKnora is an intelligent knowledge base platform that combines:
- Document parsing and understanding
- Vector search with BM25 hybrid retrieval
- LLM integration for conversational AI
- Multi-tenant support with encryption

## Prerequisites

- Kubernetes 1.25+
- Helm 3.10+
- PV provisioner support in the underlying infrastructure
- Ingress controller for external access (nginx-ingress or Traefik; both get
  sensible annotation presets automatically)
- Optional: [External Secrets Operator](https://external-secrets.io/) if
  syncing secrets from Vault / cloud secret managers
- Optional: [cert-manager](https://cert-manager.io/) for automatic TLS
  certificates (`certificate.enabled=true`)

## Quick Start

```bash
# Add required secrets
helm install weknora ./helm \
  --namespace weknora \
  --create-namespace \
  --set secrets.dbPassword=<your-db-password> \
  --set secrets.redisPassword=<your-redis-password> \
  --set secrets.jwtSecret=<your-jwt-secret>
```

## Architecture

```
                    ┌─────────────┐
                    │   Ingress   │
                    └──────┬──────┘
                           │
           ┌───────────────┴───────────────┐
           │                               │
           ▼                               ▼
    ┌─────────────┐                 ┌─────────────┐
    │  Frontend   │                 │   Backend   │
    │  (Vue.js)   │                 │   (Go/Gin)  │
    └─────────────┘                 └──────┬──────┘
                                           │
                    ┌──────────────────────┼──────────────────────┐
                    │                      │                      │
                    ▼                      ▼                      ▼
             ┌─────────────┐        ┌─────────────┐        ┌─────────────┐
             │  Docreader  │        │  PostgreSQL │        │    Redis    │
             │   (gRPC)    │        │  (ParadeDB) │        │   (Queue)   │
             └─────────────┘        └─────────────┘        └─────────────┘
```

## Installation

### Basic Installation

```bash
helm install weknora ./helm \
  --namespace weknora \
  --create-namespace \
  --set secrets.dbPassword=secure-password \
  --set secrets.redisPassword=secure-password \
  --set secrets.jwtSecret=$(openssl rand -base64 32)
```

### With Ingress

```bash
helm install weknora ./helm \
  --namespace weknora \
  --create-namespace \
  --set ingress.enabled=true \
  --set ingress.host=weknora.example.com \
  --set ingress.tls.enabled=true \
  --set ingress.tls.secretName=weknora-tls \
  --set secrets.dbPassword=secure-password \
  --set secrets.redisPassword=secure-password \
  --set secrets.jwtSecret=$(openssl rand -base64 32)
```

### With Traefik

Set `ingress.className=traefik` — the chart detects the controller and applies
Traefik annotations instead of nginx ones (request body limit via the
buffering middleware annotation). Per-Ingress timeouts do not exist in
Traefik annotations; configure them on the controller entrypoint transport.

```bash
helm install weknora ./helm \
  --namespace weknora \
  --create-namespace \
  --set ingress.enabled=true \
  --set ingress.className=traefik \
  --set ingress.host=weknora.example.com \
  --set secrets.dbPassword=secure-password \
  --set secrets.redisPassword=secure-password \
  --set secrets.jwtSecret=$(openssl rand -base64 32)
```

The preset can also be forced explicitly with `--set ingress.preset=traefik`
(or `nginx`, `none`) when auto-detection from the class name is not enough.

### With cert-manager TLS

Instead of supplying a pre-created TLS secret, let
[cert-manager](https://cert-manager.io/) issue one (requires cert-manager
with its CRDs installed and a configured issuer):

```bash
helm install weknora ./helm \
  --namespace weknora \
  --create-namespace \
  --set ingress.enabled=true \
  --set ingress.host=weknora.example.com \
  --set certificate.enabled=true \
  --set certificate.issuerRef.name=letsencrypt-prod \
  --set secrets.dbPassword=secure-password \
  --set secrets.redisPassword=secure-password \
  --set secrets.jwtSecret=$(openssl rand -base64 32)
```

The DNS names default to `ingress.host`; when the primary name (first of
`certificate.dnsNames`) matches, the ingress TLS section is wired to the
issued secret automatically (`<fullname>-tls`). Extra SANs, a custom secret
name, a custom lifetime, or a certificate for a completely different endpoint
(e.g. an external S3 host) are configured via the `certificate.*` values —
see the parameter table below.

A certificate for a different endpoint, mirroring the manual resource:

```yaml
certificate:
  enabled: true
  dnsNames:
    - s3.example.com
  secretName: s3-tls        # optional, defaults to <fullname>-tls
  issuerRef:
    name: letsencrypt-prod  # optional, this is the default
```

### With External PostgreSQL / Redis

Skip the in-cluster deployments and point the app at managed services.
Credentials are still read from the chart secret (or existing secret / ESO).

```bash
helm install weknora ./helm \
  --namespace weknora \
  --create-namespace \
  --set postgresql.external.enabled=true \
  --set postgresql.external.host=mydb.example.com \
  --set redis.external.enabled=true \
  --set redis.external.host=myredis.example.com \
  --set secrets.dbPassword=secure-password \
  --set secrets.redisPassword=secure-password \
  --set secrets.jwtSecret=$(openssl rand -base64 32)
```

### With External Secrets Operator

Instead of passing secrets via `--set`, sync them from an external store.
The chart renders an `ExternalSecret` that produces the very same Secret the
workloads already reference — nothing else changes.

```yaml
# values-eso.yaml
externalSecrets:
  enabled: true
  secretStore:
    name: vault-backend
    kind: ClusterSecretStore   # or SecretStore
  data:
    - secretKey: DB_PASSWORD
      remoteRef:
        key: weknora/prod
        property: db-password
    - secretKey: JWT_SECRET
      remoteRef:
        key: weknora/prod
        property: jwt-secret
    - secretKey: SYSTEM_AES_KEY
      remoteRef:
        key: weknora/prod
        property: system-aes-key
```

```bash
helm install weknora ./helm \
  --namespace weknora \
  --create-namespace \
  -f values-eso.yaml
```

No `secrets.*` values are needed with ESO enabled — the chart-managed Secret
is not rendered at all.

Required remote keys mirror `secrets.existingSecret` — see values.yaml.

### With S3 / MinIO Storage

Store uploaded files in an S3-compatible backend instead of the local PVC
(files become accessible from every app/docreader replica):

```bash
helm install weknora ./helm \
  --namespace weknora \
  --create-namespace \
  --set storage.type=minio \
  --set storage.minio.endpoint=minio.example.com:9000 \
  --set storage.minio.bucket=weknora \
  --set storage.minio.useSSL=true \
  --set secrets.minioAccessKey=<access-key> \
  --set secrets.minioSecretKey=<secret-key> \
  --set secrets.dbPassword=secure-password \
  --set secrets.redisPassword=secure-password \
  --set secrets.jwtSecret=$(openssl rand -base64 32)
```

For AWS S3 use `--set storage.type=s3` plus `storage.s3.*` settings
(`region`, `bucket`, optional `endpoint` for S3-compatible providers,
`forcePathStyle=true` for MinIO-like endpoints). Other backends supported by
the app (cos/tos/obs/oss) can be wired with `app.extraEnv` +
`app.extraEnvFrom` / `docreader.extraEnvFrom`.

### With External LLM (Ollama)

```bash
helm install weknora ./helm \
  --namespace weknora \
  --create-namespace \
  --set app.extraEnv[0].name=OLLAMA_BASE_URL \
  --set app.extraEnv[0].value=http://ollama.ollama:11434 \
  --set app.extraEnv[1].name=INIT_LLM_MODEL_NAME \
  --set app.extraEnv[1].value=qwen2.5:7b \
  --set secrets.dbPassword=secure-password \
  --set secrets.redisPassword=secure-password \
  --set secrets.jwtSecret=$(openssl rand -base64 32)
```

### Production Installation

For production, use a values file:

```yaml
# values-production.yaml
global:
  storageClass: "fast-ssd"

app:
  replicaCount: 3
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: 2
      memory: 4Gi

postgresql:
  persistence:
    size: 100Gi

ingress:
  enabled: true
  host: weknora.company.com
  tls:
    enabled: true
    secretName: weknora-tls

secrets:
  existingSecret: weknora-secrets  # Use pre-created secret
```

```bash
helm install weknora ./helm \
  --namespace weknora \
  --create-namespace \
  -f values-production.yaml
```

## Configuration

### Global Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `global.storageClass` | Storage class for PVCs | `""` |
| `global.imagePullSecrets` | Image pull secrets | `[]` |
| `global.maxFileSizeMB` | Maximum upload size in MB (frontend, app, docreader) | `50` |
| `global.podSecurityContext` | Pod security context | See values.yaml |
| `global.containerSecurityContext` | Container security context | See values.yaml |

### ServiceAccount

| Parameter | Description | Default |
|-----------|-------------|---------|
| `serviceAccount.create` | Create ServiceAccount | `true` |
| `serviceAccount.name` | ServiceAccount name | `""` |
| `serviceAccount.annotations` | ServiceAccount annotations | `{}` |

### App (Backend)

| Parameter | Description | Default |
|-----------|-------------|---------|
| `app.enabled` | Enable backend | `true` |
| `app.replicaCount` | Number of replicas | `1` |
| `app.image.repository` | Image repository | `wechatopenai/weknora-app` |
| `app.image.tag` | Image tag | `""` (uses appVersion) |
| `app.resources` | Resource limits | See values.yaml |
| `app.env` | Environment variables | See values.yaml |
| `app.extraEnv` | Additional env vars | `[]` |

### Frontend

| Parameter | Description | Default |
|-----------|-------------|---------|
| `frontend.enabled` | Enable frontend | `true` |
| `frontend.replicaCount` | Number of replicas | `1` |
| `frontend.image.repository` | Image repository | `wechatopenai/weknora-ui` |
| `frontend.image.tag` | Image tag | `""` (uses appVersion) |

### DocReader

| Parameter | Description | Default |
|-----------|-------------|---------|
| `docreader.enabled` | Enable DocReader | `true` |
| `docreader.replicaCount` | Number of replicas | `1` |
| `docreader.image.repository` | Image repository | `wechatopenai/weknora-docreader` |
| `docreader.image.tag` | Image tag | `""` (uses appVersion) |

### PostgreSQL (ParadeDB)

| Parameter | Description | Default |
|-----------|-------------|---------|
| `postgresql.enabled` | Enable PostgreSQL | `true` |
| `postgresql.external.enabled` | Use an external PostgreSQL instead of the in-cluster one | `false` |
| `postgresql.external.host` | External PostgreSQL host (required if external) | `""` |
| `postgresql.external.port` | External PostgreSQL port | `5432` |
| `postgresql.image.repository` | Image repository | `paradedb/paradedb` |
| `postgresql.image.tag` | Image tag | `v0.18.9-pg17` |
| `postgresql.persistence.enabled` | Enable persistence | `true` |
| `postgresql.persistence.size` | PVC size | `10Gi` |

### Redis

| Parameter | Description | Default |
|-----------|-------------|---------|
| `redis.enabled` | Enable Redis | `true` |
| `redis.external.enabled` | Use an external Redis instead of the in-cluster one | `false` |
| `redis.external.host` | External Redis host (required if external) | `""` |
| `redis.external.port` | External Redis port | `6379` |
| `redis.external.database` | Logical database index (`REDIS_DB`) | `0` |
| `redis.image.repository` | Image repository | `redis` |
| `redis.image.tag` | Image tag | `7-alpine` |
| `redis.persistence.enabled` | Enable persistence | `true` |
| `redis.persistence.size` | PVC size | `1Gi` |

### File Storage

Mirrors `STORAGE_TYPE` / `MINIO_*` / `S3_*` from docker-compose.yml, applied
to both app and docreader. Credentials live in the chart secret (or ESO /
existing secret).

| Parameter | Description | Default |
|-----------|-------------|---------|
| `storage.type` | Storage backend: `local`, `minio`, `s3` | `local` |
| `storage.minio.endpoint` | MinIO endpoint `host:port` | `""` |
| `storage.minio.bucket` | MinIO bucket (must exist) | `""` |
| `storage.minio.pathPrefix` | Key prefix inside the bucket | `""` |
| `storage.minio.useSSL` | Use TLS to reach MinIO | `false` |
| `storage.s3.endpoint` | Custom S3 endpoint (empty = real AWS) | `""` |
| `storage.s3.region` | AWS region | `""` |
| `storage.s3.bucket` | S3 bucket | `""` |
| `storage.s3.pathPrefix` | Key prefix inside the bucket | `weknora/` |
| `storage.s3.useSSL` | Use TLS | `true` |
| `storage.s3.forcePathStyle` | Path-style addressing (MinIO etc.) | `false` |

### Ingress

| Parameter | Description | Default |
|-----------|-------------|---------|
| `ingress.enabled` | Enable ingress | `false` |
| `ingress.className` | Ingress class | `nginx` |
| `ingress.preset` | Annotation preset: `nginx`, `traefik`, `none` (empty = auto from className) | `""` |
| `ingress.host` | Hostname | `weknora.example.com` |
| `ingress.maxBodySizeMB` | Upload body size limit applied by the preset | `100` |
| `ingress.annotations` | Extra annotations (win over the preset) | `{}` |
| `ingress.tls.enabled` | Enable TLS | `false` |
| `ingress.tls.secretName` | TLS secret name (empty = cert-manager certificate secret if enabled) | `""` |

### cert-manager Certificate

| Parameter | Description | Default |
|-----------|-------------|---------|
| `certificate.enabled` | Render a Certificate resource | `false` |
| `certificate.dnsNames` | DNS names (SANs); first entry is primary and becomes commonName | `[]` (= `[ingress.host]`) |
| `certificate.secretName` | Issued TLS secret name | `<fullname>-tls` |
| `certificate.issuerRef.name` | Issuer name | `letsencrypt-prod` |
| `certificate.issuerRef.kind` | `ClusterIssuer` or `Issuer` | `ClusterIssuer` |
| `certificate.issuerRef.group` | Issuer API group | `cert-manager.io` |
| `certificate.duration` | Certificate lifetime | `""` (issuer default) |
| `certificate.renewBefore` | Renewal window | `""` (issuer default) |
| `certificate.privateKey` | Private key options (e.g. `rotationPolicy`) | `{}` |
| `certificate.annotations` | Extra annotations | `{}` |

### Secrets

| Parameter | Description | Default |
|-----------|-------------|---------|
| `secrets.create` | Create the chart-managed Secret (false = provision it yourself) | `true` |
| `secrets.dbUser` | Database username | `postgres` |
| `secrets.dbPassword` | Database password | `""` (required) |
| `secrets.dbName` | Database name | `weknora` |
| `secrets.redisUsername` | Redis username (optional ACL) | `""` |
| `secrets.redisPassword` | Redis password | `""` (required in-cluster; optional for external) |
| `secrets.jwtSecret` | JWT signing secret | `""` (required) |
| `secrets.systemAesKey` | AES-256 field-encryption key (32 bytes) | `""` (random, persisted via upgrade lookup) |
| `secrets.minioAccessKey` / `secrets.minioSecretKey` | MinIO credentials (`storage.type=minio`) | `""` |
| `secrets.s3AccessKey` / `secrets.s3SecretKey` | S3 credentials (`storage.type=s3`) | `""` |
| `secrets.existingSecret` | Use existing secret | `""` |

### External Secrets Operator

| Parameter | Description | Default |
|-----------|-------------|---------|
| `externalSecrets.enabled` | Render an ExternalSecret instead of a plain Secret | `false` |
| `externalSecrets.secretStore.name` | (Cluster)SecretStore name | `""` (required) |
| `externalSecrets.secretStore.kind` | `SecretStore` or `ClusterSecretStore` | `SecretStore` |
| `externalSecrets.secretName` | Target Secret name | `<fullname>-secrets` |
| `externalSecrets.refreshInterval` | Sync interval | `1h` |
| `externalSecrets.creationPolicy` | `Owner` or `Merge` | `Owner` |
| `externalSecrets.deletionPolicy` | `Retain` or `Delete` | `Retain` |
| `externalSecrets.data` | Key mappings (`secretKey` + `remoteRef`) | `[]` |
| `externalSecrets.dataFrom` | Whole-entry extracts | `[]` |

### Optional Components

Maps to docker-compose profiles:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `neo4j.enabled` | Enable Neo4j (GraphRAG) | `false` |

## Security Best Practices

### Secret Management

**Never commit secrets to Git!** The `secrets.*` values are only required for
the default install (chart-managed Secret). Any external secret workflow is
never blocked by render-time validation:

1. **Helm --set flags** (for testing)
   ```bash
   helm install weknora ./helm --set secrets.dbPassword=xxx
   ```

2. **External Secrets Operator** (recommended for production)
   ```yaml
   externalSecrets:
     enabled: true
     secretStore:
       name: vault-backend
       kind: ClusterSecretStore
   ```
   See the [With External Secrets Operator](#with-external-secrets-operator)
   example for the full key mapping.

3. **Sealed Secrets / own ExternalSecret CR / manual Secret**
   Provision the Secret named `<fullname>-secrets` (or any name referenced by
   `secrets.existingSecret`) yourself and skip the chart-managed one:
   ```yaml
   secrets:
     create: false
   ```

4. **Pre-created Secret by name**
   ```yaml
   secrets:
     existingSecret: weknora-external-secret
   ```

### Pod Security

The chart follows CNCF security best practices:
- Runs as non-root user
- Read-only root filesystem where possible
- Drops all capabilities
- Uses seccomp profiles

## Upgrading

```bash
helm upgrade weknora ./helm \
  --namespace weknora \
  --reuse-values
```

## Uninstalling

```bash
helm uninstall weknora --namespace weknora

# Optional: Remove PVCs
kubectl delete pvc -n weknora -l app.kubernetes.io/instance=weknora
```

## Troubleshooting

### Check Pod Status
```bash
kubectl get pods -n weknora
```

### View Logs
```bash
# Backend logs
kubectl logs -n weknora -l app.kubernetes.io/component=app -f

# Frontend logs
kubectl logs -n weknora -l app.kubernetes.io/component=frontend -f
```

### Common Issues

**Pod stuck in Pending**
- Check if PVCs are bound: `kubectl get pvc -n weknora`
- Verify storage class exists: `kubectl get sc`

**Connection refused errors**
- Wait for all pods to be Ready
- Check service endpoints: `kubectl get endpoints -n weknora`

**Database connection errors**
- Verify secrets are correct
- Check PostgreSQL logs: `kubectl logs -n weknora -l app.kubernetes.io/component=database`

## Contributing

See [CONTRIBUTING.md](https://github.com/Tencent/WeKnora/blob/main/CONTRIBUTING.md) in the main repository.

## References

This Helm chart follows best practices from:
- [Helm Best Practices](https://helm.sh/docs/chart_best_practices/)
- [ArgoCD Helm Chart](https://github.com/argoproj/argo-helm)
- [Prometheus Helm Charts](https://github.com/prometheus-community/helm-charts)
- [cert-manager Helm Chart](https://github.com/cert-manager/cert-manager)

## License

This chart is licensed under the MIT License - see the [LICENSE](https://github.com/Tencent/WeKnora/blob/main/LICENSE) file for details.
