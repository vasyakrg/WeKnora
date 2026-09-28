{{/*
Copyright 2025 Tencent
SPDX-License-Identifier: MIT

WeKnora Helm Chart Template Helpers

Best Practices References:
- https://helm.sh/docs/chart_best_practices/templates/
- https://github.com/argoproj/argo-helm/blob/main/charts/argo-cd/templates/_helpers.tpl
*/}}

{{/*
Expand the name of the chart.
*/}}
{{- define "weknora.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "weknora.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
Ref: https://helm.sh/docs/chart_best_practices/labels/
*/}}
{{- define "weknora.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels following Kubernetes recommended labels.
Ref: https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/
*/}}
{{- define "weknora.labels" -}}
helm.sh/chart: {{ include "weknora.chart" . }}
{{ include "weknora.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: weknora
{{- end }}

{{/*
Selector labels
*/}}
{{- define "weknora.selectorLabels" -}}
app.kubernetes.io/name: {{ include "weknora.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Component labels - use for individual components
Usage: {{ include "weknora.componentLabels" (dict "component" "app" "context" .) }}
*/}}
{{- define "weknora.componentLabels" -}}
{{ include "weknora.labels" .context }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Component selector labels
Usage: {{ include "weknora.componentSelectorLabels" (dict "component" "app" "context" .) }}
*/}}
{{- define "weknora.componentSelectorLabels" -}}
{{ include "weknora.selectorLabels" .context }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Create the name of the service account to use.
Ref: https://helm.sh/docs/chart_best_practices/rbac/
*/}}
{{- define "weknora.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "weknora.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Secret name - supports existing secret and External Secrets Operator.
The ExternalSecret renders a Secret with the same name the workloads read, so
callers only ever need this helper.
*/}}
{{- define "weknora.secretName" -}}
{{- if .Values.externalSecrets.enabled }}
{{- .Values.externalSecrets.secretName | default (printf "%s-secrets" (include "weknora.fullname" .)) }}
{{- else if .Values.secrets.existingSecret }}
{{- .Values.secrets.existingSecret }}
{{- else }}
{{- include "weknora.fullname" . }}-secrets
{{- end }}
{{- end }}

{{/*
PostgreSQL host/port - external endpoint or in-cluster service.
Service names stay hardcoded ("postgres") because the frontend nginx config
and docker-compose parity rely on them.
*/}}
{{- define "weknora.postgresql.host" -}}
{{- if .Values.postgresql.external.enabled }}
{{- required "postgresql.external.host is required when postgresql.external.enabled=true" .Values.postgresql.external.host }}
{{- else }}
postgres
{{- end }}
{{- end }}

{{- define "weknora.postgresql.port" -}}
{{- if .Values.postgresql.external.enabled }}
{{- .Values.postgresql.external.port | default 5432 }}
{{- else }}
5432
{{- end }}
{{- end }}

{{/*
Redis host:port, database index - external endpoint or in-cluster service.
*/}}
{{- define "weknora.redis.addr" -}}
{{- if .Values.redis.external.enabled }}
{{- required "redis.external.host is required when redis.external.enabled=true" .Values.redis.external.host }}:{{ .Values.redis.external.port | default 6379 }}
{{- else }}
redis:6379
{{- end }}
{{- end }}

{{- define "weknora.redis.db" -}}
{{- if .Values.redis.external.enabled }}
{{- .Values.redis.external.database | default 0 }}
{{- else }}
0
{{- end }}
{{- end }}

{{/*
TLS secret issued by the cert-manager Certificate.
*/}}
{{- define "weknora.certificate.secretName" -}}
{{- .Values.certificate.secretName | default (printf "%s-tls" (include "weknora.fullname" .)) }}
{{- end }}

{{/*
Primary DNS name of the cert-manager Certificate: first of dnsNames,
defaulting to ingress.host. compact() drops nulls from sparse lists created
by --set certificate.dnsNames[1]=... (index 0 left unset).
*/}}
{{- define "weknora.certificate.primaryHost" -}}
{{- first (compact (.Values.certificate.dnsNames | default (list .Values.ingress.host))) }}
{{- end }}

{{/*
Secret backing the Ingress TLS section: explicit ingress.tls.secretName wins,
otherwise the cert-manager Certificate secret — but only when the certificate
is issued for the ingress host itself.
*/}}
{{- define "weknora.ingress.tlsSecretName" -}}
{{- if .Values.ingress.tls.secretName -}}
{{- .Values.ingress.tls.secretName -}}
{{- else if and .Values.certificate.enabled (eq (include "weknora.certificate.primaryHost" .) .Values.ingress.host) -}}
{{- include "weknora.certificate.secretName" . -}}
{{- end -}}
{{- end }}

{{/*
Whether the Ingress TLS section renders: explicit ingress.tls.enabled, or
automatically when the certificate is issued for the ingress host itself
(a certificate for a different endpoint is not wired into the ingress).
*/}}
{{- define "weknora.ingress.tlsEnabled" -}}
{{- if .Values.ingress.tls.enabled -}}
true
{{- else if and .Values.certificate.enabled (eq (include "weknora.certificate.primaryHost" .) .Values.ingress.host) -}}
true
{{- else -}}
false
{{- end -}}
{{- end }}

{{/*
Ingress controller preset: "nginx", "traefik" or "none".
Explicit ingress.preset wins; otherwise infer from ingress.className.
*/}}
{{- define "weknora.ingress.preset" -}}
{{- $preset := .Values.ingress.preset -}}
{{- if not $preset -}}
  {{- $className := .Values.ingress.className | default "" -}}
  {{- if contains "nginx" $className -}}
    {{- $preset = "nginx" -}}
  {{- else if contains "traefik" $className -}}
    {{- $preset = "traefik" -}}
  {{- else -}}
    {{- $preset = "none" -}}
  {{- end -}}
{{- end -}}
{{- $preset -}}
{{- end }}

{{/*
Ingress annotations: controller preset merged with user overrides
(user annotations win on key conflicts).
nginx:   body size + proxy timeouts.
traefik: buffering middleware enforcing maxRequestBodyBytes. Per-Ingress
         timeouts do not exist in Traefik annotations - configure them on the
         controller entrypoint transport.
*/}}
{{- define "weknora.ingress.annotations" -}}
{{- $preset := include "weknora.ingress.preset" . -}}
{{- $bodyMB := int .Values.ingress.maxBodySizeMB -}}
{{- $presetAnnotations := dict -}}
{{- if eq $preset "nginx" -}}
{{- $presetAnnotations = dict
    "nginx.ingress.kubernetes.io/proxy-body-size" (printf "%dm" $bodyMB)
    "nginx.ingress.kubernetes.io/proxy-connect-timeout" "60"
    "nginx.ingress.kubernetes.io/proxy-read-timeout" "3600"
    "nginx.ingress.kubernetes.io/proxy-send-timeout" "3600" -}}
{{- else if eq $preset "traefik" -}}
{{- $presetAnnotations = dict
    "traefik.ingress.kubernetes.io/buffering" (printf "{\"maxRequestBodyBytes\":%d}" (mul $bodyMB 1048576)) -}}
{{- end -}}
{{- $merged := merge .Values.ingress.annotations $presetAnnotations -}}
{{- with $merged -}}
{{- toYaml . -}}
{{- end -}}
{{- end }}

{{/*
Return the app image with tag.
Defaults to Chart.appVersion if tag is not specified.
*/}}
{{- define "weknora.app.image" -}}
{{- $tag := default .Chart.AppVersion .Values.app.image.tag }}
{{- printf "%s:%s" .Values.app.image.repository $tag }}
{{- end }}

{{/*
Return the frontend image with tag.
Defaults to Chart.appVersion if tag is not specified.
*/}}
{{- define "weknora.frontend.image" -}}
{{- $tag := default .Chart.AppVersion .Values.frontend.image.tag }}
{{- printf "%s:%s" .Values.frontend.image.repository $tag }}
{{- end }}

{{/*
Return the docreader image with tag.
Defaults to Chart.appVersion if tag is not specified.
*/}}
{{- define "weknora.docreader.image" -}}
{{- $tag := default .Chart.AppVersion .Values.docreader.image.tag }}
{{- printf "%s:%s" .Values.docreader.image.repository $tag }}
{{- end }}

{{/*
Return the PostgreSQL image with tag.
*/}}
{{- define "weknora.postgresql.image" -}}
{{- printf "%s:%s" .Values.postgresql.image.repository .Values.postgresql.image.tag }}
{{- end }}

{{/*
Return the Redis image with tag.
*/}}
{{- define "weknora.redis.image" -}}
{{- printf "%s:%s" .Values.redis.image.repository .Values.redis.image.tag }}
{{- end }}

{{/*
Return the Neo4j image with tag.
*/}}
{{- define "weknora.neo4j.image" -}}
{{- printf "%s:%s" .Values.neo4j.image.repository .Values.neo4j.image.tag }}
{{- end }}

{{/*
Create image pull secrets list.
*/}}
{{- define "weknora.imagePullSecrets" -}}
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Return the storage class name.
*/}}
{{- define "weknora.storageClass" -}}
{{- if .Values.global.storageClass }}
{{- if eq .Values.global.storageClass "-" }}
storageClassName: ""
{{- else }}
storageClassName: {{ .Values.global.storageClass | quote }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Pod security context.
Merges global defaults with component-specific overrides.
*/}}
{{- define "weknora.podSecurityContext" -}}
{{- $global := .Values.global.podSecurityContext | default dict }}
{{- $component := .componentSecurityContext | default dict }}
{{- $merged := merge $component $global }}
{{- if $merged }}
securityContext:
{{- toYaml $merged | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Container security context.
*/}}
{{- define "weknora.containerSecurityContext" -}}
{{- if . }}
securityContext:
{{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}
