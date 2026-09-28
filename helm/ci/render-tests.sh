#!/usr/bin/env bash
# Render smoke tests for the WeKnora chart scenarios.
set -euo pipefail
cd "$(dirname "$0")/.."

BASE=(--set secrets.dbPassword=t --set secrets.redisPassword=t --set secrets.jwtSecret=t)
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "OK: $*"; }

echo "== 1. External PostgreSQL + Redis =="
out=$(helm template weknora . "${BASE[@]}" \
  --set postgresql.enabled=false --set postgresql.external.enabled=true --set postgresql.external.host=db.corp.local --set postgresql.external.port=6543 \
  --set redis.enabled=false --set redis.external.enabled=true --set redis.external.host=redis.corp.local --set redis.external.port=6380)
grep -q 'value: "db.corp.local"' <<<"$out" || fail "DB_HOST not external"
grep -q 'value: "6543"' <<<"$out" || fail "DB_PORT not external"
grep -q 'value: "redis.corp.local:6380"' <<<"$out" || fail "REDIS_ADDR not external"
grep -q 'kind: Deployment' <<<"$out" && ! grep -q 'name: weknora-postgres' <<<"$out" || true
if grep -q 'name: weknora-postgres' <<<"$out"; then fail "postgres Deployment still rendered"; fi
if grep -q 'name: weknora-redis' <<<"$out"; then fail "redis Deployment still rendered"; fi
ok "external endpoints + no in-cluster postgres/redis"

echo "== 2. ESO =="
out=$(helm template weknora . "${BASE[@]}" \
  --set externalSecrets.enabled=true \
  --set externalSecrets.secretStore.name=vault-store \
  --set externalSecrets.secretStore.kind=ClusterSecretStore \
  --set externalSecrets.data[0].secretKey=DB_PASSWORD \
  --set externalSecrets.data[0].remoteRef.key=weknora/prod \
  --set externalSecrets.data[0].remoteRef.property=db-password)
grep -q 'kind: ExternalSecret' <<<"$out" || fail "ExternalSecret not rendered"
grep -q 'kind: ClusterSecretStore' <<<"$out" || fail "store kind not set"
grep -q 'property: db-password' <<<"$out" || fail "remoteRef.property not set"
if grep -q '^kind: Secret$' <<<"$out"; then fail "plain Secret rendered together with ESO"; fi
grep -q 'secretKeyRef' <<<"$out" || fail "app does not reference the secret"
ok "ExternalSecret rendered, no plain Secret"

echo "== 2b. ESO auto data mapping (no data/dataFrom given) =="
out=$(helm template weknora . \
  --set externalSecrets.enabled=true \
  --set externalSecrets.secretStore.name=onepassword-t8s-nsk \
  --set externalSecrets.secretStore.kind=ClusterSecretStore \
  --set externalSecrets.secretName=weknora-creds)
grep -q 'kind: ExternalSecret' <<<"$out" || fail "ExternalSecret not rendered"
[ "$(grep -c 'secretKey:' <<<"$out")" -eq 7 ] || fail "expected 7 auto base keys, got $(grep -c 'secretKey:' <<<"$out")"
grep -q 'key: weknora-creds' <<<"$out" || fail "remoteRef.key should default to secretName"
grep -q 'property: SYSTEM_AES_KEY' <<<"$out" || fail "auto property per key"
if grep -q 'property: NEO4J_USERNAME' <<<"$out"; then fail "neo4j keys leaked into base set"; fi
ok "auto mappings: 7 base keys, remoteKey=secretName"

echo "== 2c. ESO auto data includes feature keys =="
out=$(helm template weknora . \
  --set externalSecrets.enabled=true \
  --set externalSecrets.secretStore.name=op-store \
  --set neo4j.enabled=true --set neo4j.password=p \
  --set storage.type=minio --set storage.minio.endpoint=m:9000 --set storage.minio.bucket=b)
[ "$(grep -c 'secretKey:' <<<"$out")" -eq 11 ] || fail "expected 11 keys (base+neo4j+minio), got $(grep -c 'secretKey:' <<<"$out")"
grep -q 'property: MINIO_SECRET_ACCESS_KEY' <<<"$out" || fail "minio keys"
grep -q 'property: NEO4J_PASSWORD' <<<"$out" || fail "neo4j keys"
ok "feature-dependent keys auto-included"

echo "== 3. Traefik ingress =="
out=$(helm template weknora . "${BASE[@]}" \
  --set ingress.enabled=true --set ingress.className=traefik --set ingress.host=weknora.local)
grep -q 'ingressClassName: traefik' <<<"$out" || fail "ingressClassName"
grep -q "maxRequestBodyBytes.:104857600" <<<"$out" || fail "traefik buffering annotation missing/wrong"
if grep -q 'nginx.ingress.kubernetes.io' <<<"$out"; then fail "nginx annotations leaked into traefik ingress"; fi
ok "traefik preset annotations"

echo "== 4. Nginx ingress (default class) =="
out=$(helm template weknora . "${BASE[@]}" \
  --set ingress.enabled=true --set ingress.host=weknora.local)
grep -q 'ingressClassName: nginx' <<<"$out" || fail "ingressClassName"
grep -q 'nginx.ingress.kubernetes.io/proxy-body-size: 100m' <<<"$out" || fail "proxy-body-size"
grep -q 'nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"' <<<"$out" || fail "proxy-read-timeout"
ok "nginx preset annotations + user override wins"

echo "== 5. Ingress user annotation override =="
out=$(helm template weknora . "${BASE[@]}" \
  --set ingress.enabled=true --set ingress.host=weknora.local \
  --set ingress.maxBodySizeMB=200)
grep -q 'proxy-body-size: 200m' <<<"$out" || fail "maxBodySizeMB"
out=$(helm template weknora . "${BASE[@]}" \
  --set ingress.enabled=true --set ingress.host=weknora.local \
  --set 'ingress.annotations.nginx\.ingress\.kubernetes\.io/proxy-read-timeout=999')
grep -q 'proxy-read-timeout: 999' <<<"$out" || fail "user annotation override"
ok "maxBodySizeMB knob + user annotations win over preset"

echo "== 6. MinIO storage =="
out=$(helm template weknora . "${BASE[@]}" \
  --set storage.type=minio --set storage.minio.endpoint=minio.corp.local:9000 \
  --set storage.minio.bucket=weknora --set secrets.minioAccessKey=ak --set secrets.minioSecretKey=sk)
[ "$(grep -c 'value: minio' <<<"$out" | head -1)" -ge 1 ] || true
grep -q 'name: STORAGE_TYPE' <<<"$out" || fail "STORAGE_TYPE"
[ "$(grep 'name: STORAGE_TYPE' -A1 <<<"$out" | grep -c 'value: "minio"')" -eq 2 ] || fail "STORAGE_TYPE=minio not set on app+docreader"
grep -q 'name: MINIO_ENDPOINT' <<<"$out" || fail "MINIO_ENDPOINT"
grep -q 'name: MINIO_BUCKET_NAME' <<<"$out" || fail "MINIO_BUCKET_NAME"
grep -q 'key: MINIO_SECRET_ACCESS_KEY' <<<"$out" || fail "MINIO secret ref"
grep -q 'MINIO_ACCESS_KEY_ID: "ak"' <<<"$out" || fail "secret keys"
ok "minio env on app+docreader, credentials in Secret"

echo "== 7. S3 storage =="
out=$(helm template weknora . "${BASE[@]}" \
  --set storage.type=s3 --set storage.s3.bucket=weknora --set storage.s3.region=us-east-1 \
  --set secrets.s3AccessKey=ak --set secrets.s3SecretKey=sk)
[ "$(grep 'name: STORAGE_TYPE' -A1 <<<"$out" | grep -c 'value: "s3"')" -eq 2 ] || fail "STORAGE_TYPE=s3 not set on app+docreader"
grep -q 'name: S3_FORCE_PATH_STYLE' <<<"$out" || fail "S3_FORCE_PATH_STYLE"
grep -q 'S3_ACCESS_KEY: "ak"' <<<"$out" || fail "secret keys"
ok "s3 env + credentials"

echo "== 8. External Redis without password =="
out=$(helm template weknora . --set secrets.dbPassword=t --set secrets.jwtSecret=t \
  --set redis.enabled=false --set redis.external.enabled=true --set redis.external.host=redis.corp.local)
grep -q 'REDIS_PASSWORD: ""' <<<"$out" || fail "redis password should default to empty for external"
ok "no-auth external redis accepted"

echo "== 9. Neo4j still renders =="
out=$(helm template weknora . "${BASE[@]}" --set neo4j.enabled=true --set neo4j.password=p)
grep -q 'name: weknora-neo4j' <<<"$out" || fail "neo4j deployment"
grep -q 'NEO4J_ENABLE' <<<"$out" || fail "NEO4J_ENABLE env"
ok "neo4j regression"

echo "== 10. ESO without any secrets.* values =="
out=$(helm template weknora . --set externalSecrets.enabled=true --set externalSecrets.secretStore.name=vault-store)
grep -q 'kind: ExternalSecret' <<<"$out" || fail "ExternalSecret"
if grep -q '^kind: Secret$' <<<"$out"; then fail "plain Secret rendered"; fi
ok "chart renders with no secrets.* values (ESO path)"

echo "== 11. cert-manager Certificate for the ingress host =="
out=$(helm template weknora . "${BASE[@]}" \
  --set ingress.enabled=true --set ingress.host=weknora.bildme.ru \
  --set certificate.enabled=true --set certificate.issuerRef.name=letsencrypt-prod)
grep -q 'kind: Certificate' <<<"$out" || fail "Certificate not rendered"
grep -q 'commonName: "weknora.bildme.ru"' <<<"$out" || fail "commonName"
[ "$(grep -c 'weknora.bildme.ru' <<<"$out")" -ge 3 ] || fail "dnsNames should contain the ingress host"
grep -q 'name: letsencrypt-prod' <<<"$out" || fail "issuerRef"
grep -q 'kind: ClusterIssuer' <<<"$out" || fail "issuer kind"
grep -A6 '^  tls:' <<<"$out" | grep -q 'secretName: weknora-tls' || fail "ingress TLS not auto-wired to the certificate secret"
ok "certificate defaults to ingress host, TLS auto-wired (2 flags total)"

echo "== 12. cert-manager Certificate with custom dnsNames =="
out=$(helm template weknora . "${BASE[@]}" \
  --set ingress.enabled=true --set ingress.host=weknora.bildme.ru \
  --set certificate.enabled=true \
  --set certificate.dnsNames[0]=s3.bildme.ru \
  --set certificate.dnsNames[1]=alt.bildme.ru \
  --set certificate.secretName=s3-tls)
grep -q 'commonName: "s3.bildme.ru"' <<<"$out" || fail "primary from dnsNames[0]"
grep -q 'alt.bildme.ru' <<<"$out" || fail "extra SAN"
grep -q 'secretName: s3-tls' <<<"$out" || fail "custom secretName"
if grep -A6 '^  tls:' <<<"$out" | grep -q 'secretName: s3-tls'; then fail "foreign certificate wired into ingress"; fi
grep -A6 '^  tls:' <<<"$out" | grep -q 'secretName' && fail "ingress TLS should have no secretName without cert/tls config"
ok "dnsNames override the host; custom secretName; not wired into ingress"

echo "== 12b. Multi-SAN certificate for the ingress host stays wired =="
out=$(helm template weknora . "${BASE[@]}" \
  --set ingress.enabled=true --set ingress.host=weknora.bildme.ru \
  --set certificate.enabled=true \
  --set certificate.dnsNames[0]=weknora.bildme.ru \
  --set certificate.dnsNames[1]=www.bildme.ru)
grep -A6 '^  tls:' <<<"$out" | grep -q 'secretName: weknora-tls' || fail "ingress TLS not wired when primary matches"
grep -q 'www.bildme.ru' <<<"$out" || fail "extra SAN missing"
ok "primary-dnsNames[0]=ingress.host still auto-wires"

echo "== 13. secrets.create=false: fully external secret management =="
out=$(helm template weknora . \
  --set secrets.create=false \
  --set postgresql.external.enabled=true --set postgresql.external.host=db.corp.local \
  --set redis.external.enabled=true --set redis.external.host=redis.corp.local)
if grep -q '^kind: Secret$' <<<"$out"; then fail "chart rendered a Secret with secrets.create=false"; fi
if grep -q 'kind: ExternalSecret' <<<"$out"; then fail "ExternalSecret rendered without externalSecrets.enabled"; fi
grep -q 'name: weknora-secrets' <<<"$out" || fail "workloads should reference weknora-secrets"
ok "no Secret rendered and no secrets.* values required"

echo "== 14. Default install still fails without secrets values =="
if helm template weknora . >/dev/null 2>&1; then
  fail "default install should require secrets.dbPassword"
fi
msg=$(helm template weknora . 2>&1 || true)
grep -q 'secrets.dbPassword is required' <<<"$msg" || fail "error message should name secrets.dbPassword"
ok "chart-managed path still enforces dbPassword with a clear message"

echo
echo "ALL SCENARIOS PASSED"
