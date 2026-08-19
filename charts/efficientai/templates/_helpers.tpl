{{/* vim: set filetype=mustache: */}}

{{/*
Expand the name of the chart.
*/}}
{{- define "efficientai.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this
(by the DNS naming spec).
*/}}
{{- define "efficientai.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "efficientai.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels.
*/}}
{{- define "efficientai.labels" -}}
helm.sh/chart: {{ include "efficientai.chart" . }}
{{ include "efficientai.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: efficientai
{{- end -}}

{{/*
Selector labels (shared across the release).
*/}}
{{- define "efficientai.selectorLabels" -}}
app.kubernetes.io/name: {{ include "efficientai.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Per-component fullname: {release}-{chart}-{component}.
Usage: {{ include "efficientai.componentFullname" (dict "root" . "component" "web") }}
*/}}
{{- define "efficientai.componentFullname" -}}
{{- $root := .root -}}
{{- printf "%s-%s" (include "efficientai.fullname" $root) .component | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Per-component labels.
Usage: {{ include "efficientai.componentLabels" (dict "root" . "component" "web") }}
*/}}
{{- define "efficientai.componentLabels" -}}
{{- $root := .root -}}
{{ include "efficientai.labels" $root }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/*
Per-component selector labels.
Usage: {{ include "efficientai.componentSelectorLabels" (dict "root" . "component" "web") }}
*/}}
{{- define "efficientai.componentSelectorLabels" -}}
{{- $root := .root -}}
{{ include "efficientai.selectorLabels" $root }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/*
Service account name.
*/}}
{{- define "efficientai.serviceAccountName" -}}
{{- if .Values.efficientai.serviceAccount.create -}}
{{- default (include "efficientai.fullname" .) .Values.efficientai.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.efficientai.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Name of the in-chart secret that holds inline secret values
(values supplied via `value:` rather than `secretKeyRef:`).
*/}}
{{- define "efficientai.secretName" -}}
{{- printf "%s-secrets" (include "efficientai.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Image reference resolver for the api or worker image.
Usage: {{ include "efficientai.image" (dict "root" . "type" "api") }}
*/}}
{{- define "efficientai.image" -}}
{{- $root := .root -}}
{{- $type := .type -}}
{{- $img := index $root.Values.efficientai.image $type -}}
{{- $registry := default $root.Values.efficientai.image.registry $root.Values.global.imageRegistry -}}
{{- $tag := default $root.Chart.AppVersion $img.tag -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" $registry $img.repository $tag -}}
{{- else -}}
{{- printf "%s:%s" $img.repository $tag -}}
{{- end -}}
{{- end -}}

{{/*
Render a single env entry sourced from a value/secretKeyRef block.

Inputs:
  - root:    the top-level scope ($)
  - cfg:     the value/secretKeyRef config block (e.g. .Values.efficientai.secretKey)
  - envName: the env var name (also used as the in-chart secret key when `value:` is provided)

Behavior:
  - If cfg.secretKeyRef.name is set, wire env var to that user-managed secret.
  - Else if cfg.value is set (non-empty), wire env var to the in-chart secret (rendered by secret.yaml).
  - Else: emit nothing (caller decides whether the env is required).
*/}}
{{- define "efficientai.secretValueEnv" -}}
{{- $root := .root -}}
{{- $cfg := .cfg -}}
{{- $envName := .envName -}}
{{- if and $cfg $cfg.secretKeyRef $cfg.secretKeyRef.name }}
- name: {{ $envName }}
  valueFrom:
    secretKeyRef:
      name: {{ $cfg.secretKeyRef.name | quote }}
      key: {{ $cfg.secretKeyRef.key | quote }}
{{- else if and $cfg (hasKey $cfg "value") (not (empty $cfg.value)) }}
- name: {{ $envName }}
  valueFrom:
    secretKeyRef:
      name: {{ include "efficientai.secretName" $root | quote }}
      key: {{ $envName | quote }}
{{- end }}
{{- end -}}

{{/*
Returns "true" if the given value/secretKeyRef config has an inline `value:` set
(so secret.yaml should render a key for it).
*/}}
{{- define "efficientai.hasInlineValue" -}}
{{- $cfg := . -}}
{{- if and $cfg (hasKey $cfg "value") (not (empty $cfg.value)) -}}
true
{{- end -}}
{{- end -}}

{{/*
Returns "true" if a value/secretKeyRef config is wired (either inline value or
secretKeyRef present). Used to decide whether to render a ${VAR} placeholder
into the ConfigMap-based config.yml.
*/}}
{{- define "efficientai.isConfigured" -}}
{{- $cfg := . -}}
{{- if or (include "efficientai.hasInlineValue" $cfg) (and $cfg $cfg.secretKeyRef $cfg.secretKeyRef.name) -}}
true
{{- end -}}
{{- end -}}

{{/*
Postgres host (in-chart subchart or external).
*/}}
{{- define "efficientai.postgresql.host" -}}
{{- if .Values.postgresql.deploy -}}
{{- printf "%s-postgresql" .Release.Name -}}
{{- else -}}
{{- required "postgresql.host is required when postgresql.deploy is false" .Values.postgresql.host -}}
{{- end -}}
{{- end -}}

{{/*
Postgres port.
*/}}
{{- define "efficientai.postgresql.port" -}}
{{- default 5432 .Values.postgresql.port -}}
{{- end -}}

{{/*
Postgres env block: POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB.
Pulls password from postgresql.auth.existingSecret if set, otherwise the
in-chart secret rendered with key POSTGRES_PASSWORD.
*/}}
{{- define "efficientai.postgresql.envBlock" -}}
- name: POSTGRES_USER
  value: {{ .Values.postgresql.auth.username | quote }}
- name: POSTGRES_DB
  value: {{ .Values.postgresql.auth.database | quote }}
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
{{- if .Values.postgresql.auth.existingSecret }}
      name: {{ .Values.postgresql.auth.existingSecret | quote }}
      key: {{ .Values.postgresql.auth.secretKeys.userPasswordKey | default "password" | quote }}
{{- else }}
      name: {{ include "efficientai.secretName" . | quote }}
      key: POSTGRES_PASSWORD
{{- end }}
- name: POSTGRES_HOST
  value: {{ include "efficientai.postgresql.host" . | quote }}
- name: POSTGRES_PORT
  value: {{ include "efficientai.postgresql.port" . | quote }}
- name: DATABASE_URL
  value: "postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@$(POSTGRES_HOST):$(POSTGRES_PORT)/$(POSTGRES_DB)"
{{- end -}}

{{/*
Redis env block: REDIS_URL, CELERY_BROKER_URL, CELERY_RESULT_BACKEND.
Supports standalone (in-chart or external host) and cluster mode (external only).
*/}}
{{- define "efficientai.redis.envBlock" -}}
{{- if and .Values.redis.cluster .Values.redis.cluster.enabled }}
- name: REDIS_CLUSTER_NODES
  value: {{ join "," .Values.redis.cluster.nodes | quote }}
- name: REDIS_URL
  value: "redis://{{ index .Values.redis.cluster.nodes 0 }}/0"
{{- else }}
{{- $host := "" -}}
{{- if .Values.redis.deploy -}}
{{- $host = printf "%s-redis-master" .Release.Name -}}
{{- else -}}
{{- $host = required "redis.host is required when redis.deploy is false and cluster is not enabled" .Values.redis.host -}}
{{- end }}
- name: REDIS_HOST
  value: {{ $host | quote }}
- name: REDIS_PORT
  value: {{ .Values.redis.port | default 6379 | quote }}
{{- if or (and .Values.redis.auth .Values.redis.auth.enabled) (and .Values.redis.auth .Values.redis.auth.password) (and .Values.redis.auth .Values.redis.auth.existingSecret) }}
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
{{- if .Values.redis.auth.existingSecret }}
      name: {{ .Values.redis.auth.existingSecret | quote }}
      key: {{ .Values.redis.auth.existingSecretPasswordKey | default "password" | quote }}
{{- else }}
      name: {{ include "efficientai.secretName" . | quote }}
      key: REDIS_PASSWORD
{{- end }}
- name: REDIS_URL
  value: "redis://:$(REDIS_PASSWORD)@$(REDIS_HOST):$(REDIS_PORT)/0"
{{- else }}
- name: REDIS_URL
  value: "redis://$(REDIS_HOST):$(REDIS_PORT)/0"
{{- end }}
{{- end }}
- name: CELERY_BROKER_URL
  value: "$(REDIS_URL)"
- name: CELERY_RESULT_BACKEND
  value: "$(REDIS_URL)"
{{- end -}}

{{/*
Common application env block (secret_key, encryption_key, license, HF token, blob storage).
*/}}
{{- define "efficientai.appEnvBlock" -}}
{{- include "efficientai.secretValueEnv" (dict "root" . "cfg" .Values.efficientai.secretKey "envName" "SECRET_KEY") }}
{{- include "efficientai.secretValueEnv" (dict "root" . "cfg" .Values.efficientai.encryptionKey "envName" "ENCRYPTION_KEY") }}
{{- include "efficientai.secretValueEnv" (dict "root" . "cfg" .Values.efficientai.huggingfaceToken "envName" "HUGGINGFACE_TOKEN") }}
{{- include "efficientai.secretValueEnv" (dict "root" . "cfg" .Values.efficientai.license "envName" "EFFICIENTAI_LICENSE") }}
{{- if and .Values.s3.enabled .Values.gcs.enabled }}
{{- fail "Only one blob storage provider can be enabled: set either s3.enabled=true or gcs.enabled=true, not both" }}
{{- end }}
{{- if .Values.s3.enabled }}
- name: BLOB_STORAGE_PROVIDER
  value: "s3"
{{- include "efficientai.secretValueEnv" (dict "root" . "cfg" .Values.s3.accessKeyId "envName" "S3_ACCESS_KEY_ID") }}
{{- include "efficientai.secretValueEnv" (dict "root" . "cfg" .Values.s3.secretAccessKey "envName" "S3_SECRET_ACCESS_KEY") }}
{{- end }}
{{- if .Values.gcs.enabled }}
- name: BLOB_STORAGE_PROVIDER
  value: "gcs"
- name: GCS_ENABLED
  value: "true"
- name: GCS_BUCKET_NAME
  value: {{ required "gcs.bucket is required when gcs.enabled=true" .Values.gcs.bucket | quote }}
- name: GCS_PROJECT_ID
  value: {{ required "gcs.projectId is required when gcs.enabled=true" .Values.gcs.projectId | quote }}
- name: GCS_PREFIX
  value: {{ .Values.gcs.prefix | quote }}
{{- end }}
- name: UPLOAD_DIR
  value: {{ .Values.efficientai.config.storage.upload_dir | quote }}
- name: FRONTEND_DIR
  value: "/app/frontend/dist"
{{- end -}}

{{/*
Build the default worker container command unless efficientai.worker.command is set.
Usage: {{- include "efficientai.worker.command" . | nindent 12 }}
*/}}
{{- define "efficientai.worker.command" -}}
{{- $w := .Values.efficientai.worker -}}
{{- if gt (len $w.command) 0 -}}
{{ toYaml $w.command }}
{{- else -}}
{{- $args := list "eai" "worker" "--config" "/app/config.yml" "--loglevel" "info" -}}
{{- /* Only restrict queues when a dedicated worker-imports pool is enabled. */ -}}
{{- if .Values.efficientai.workerImports.enabled -}}
{{- if $w.queues -}}
{{- $args = concat $args (list "--queues" $w.queues) -}}
{{- end -}}
{{- if $w.concurrency -}}
{{- $args = concat $args (list "--concurrency" (printf "%d" (int $w.concurrency))) -}}
{{- end -}}
{{- end -}}
{{ toYaml $args }}
{{- end -}}
{{- end -}}

{{/*
Build the default worker-imports container command unless efficientai.workerImports.command is set.
Usage: {{- include "efficientai.workerImports.command" . | nindent 12 }}
*/}}
{{- define "efficientai.workerImports.command" -}}
{{- $wi := .Values.efficientai.workerImports -}}
{{- if gt (len $wi.command) 0 -}}
{{ toYaml $wi.command }}
{{- else -}}
{{- $args := list "eai" "worker" "--config" "/app/config.yml" "--loglevel" "info" -}}
{{- $args = concat $args (list "--queues" (default "imports,diarization,eval-control,evaluations" $wi.queues)) -}}
{{- with $wi.pool -}}
{{- if ne . "" -}}
{{- $args = concat $args (list "--pool" .) -}}
{{- end -}}
{{- end -}}
{{- $args = concat $args (list "--concurrency" (printf "%d" (int (default 8 $wi.concurrency)))) -}}
{{ toYaml $args }}
{{- end -}}
{{- end -}}

{{/*
Build the default beat container command unless efficientai.beat.command is set.
Runs Celery Beat plus a co-located platform queue worker in one container.
A supervision loop exits (and Kubernetes restarts the pod) if either process dies.
SIGTERM/INT from Kubernetes is forwarded to both Celery processes for warm shutdown.
Usage: {{- include "efficientai.beat.command" . | nindent 12 }}
*/}}
{{- define "efficientai.beat.command" -}}
{{- $b := .Values.efficientai.beat -}}
{{- if gt (len $b.command) 0 -}}
{{ toYaml $b.command }}
{{- else -}}
{{- $queue := default "platform" $b.platformQueue -}}
{{- $concurrency := default 2 $b.platformConcurrency -}}
- sh
- -c
- celery -A app.workers.celery_app worker -Q {{ $queue }} --pool threads --concurrency {{ $concurrency }} --loglevel=info & WORKER_PID=$!; celery -A app.workers.celery_app beat --loglevel=info & BEAT_PID=$!; shutdown() { kill -TERM "$WORKER_PID" "$BEAT_PID" 2>/dev/null; wait "$WORKER_PID" "$BEAT_PID" 2>/dev/null; exit 0; }; trap shutdown TERM INT; while kill -0 "$WORKER_PID" 2>/dev/null && kill -0 "$BEAT_PID" 2>/dev/null; do sleep 2; done; kill -TERM "$WORKER_PID" "$BEAT_PID" 2>/dev/null; wait; exit 1
{{- end -}}
{{- end -}}

{{/*
Build the default worker-usage container command unless efficientai.workerUsage.command is set.
Usage: {{- include "efficientai.workerUsage.command" . | nindent 12 }}
*/}}
{{- define "efficientai.workerUsage.command" -}}
{{- $wu := .Values.efficientai.workerUsage -}}
{{- if gt (len $wu.command) 0 -}}
{{ toYaml $wu.command }}
{{- else -}}
{{- $args := list "eai" "worker" "--config" "/app/config.yml" "--loglevel" "info" -}}
{{- $args = concat $args (list "--queues" (default "usage" $wu.queues)) -}}
{{- with $wu.pool -}}
{{- if ne . "" -}}
{{- $args = concat $args (list "--pool" .) -}}
{{- end -}}
{{- end -}}
{{- $args = concat $args (list "--concurrency" (printf "%d" (int (default 4 $wu.concurrency)))) -}}
{{ toYaml $args }}
{{- end -}}
{{- end -}}

{{/*
True when Redis auth credentials are configured (matches efficientai.redis.envBlock).
*/}}
{{- define "efficientai.redis.authEnabled" -}}
{{- or (and .Values.redis.auth .Values.redis.auth.enabled) (and .Values.redis.auth .Values.redis.auth.password) (and .Values.redis.auth .Values.redis.auth.existingSecret) -}}
{{- end -}}

{{/*
Secret name holding the Redis password for TriggerAuthentication.
*/}}
{{- define "efficientai.redis.authSecretName" -}}
{{- if .Values.redis.auth.existingSecret -}}
{{- .Values.redis.auth.existingSecret -}}
{{- else -}}
{{- include "efficientai.secretName" . -}}
{{- end -}}
{{- end -}}

{{/*
Redis host:port for KEDA redis scaler (FQDN when in-cluster so keda-operator can reach the broker).
*/}}
{{- define "efficientai.redis.kedaAddress" -}}
{{- $kedaRedis := .Values.efficientai.workerImports.keda.redis | default dict -}}
{{- if $kedaRedis.address -}}
{{- $kedaRedis.address -}}
{{- else if and .Values.redis.cluster .Values.redis.cluster.enabled -}}
{{- fail "KEDA Redis list scaler requires standalone Redis; redis.cluster.enabled is not supported" -}}
{{- else -}}
{{- $host := "" -}}
{{- if .Values.redis.deploy -}}
{{- $host = printf "%s-redis-master.%s.svc.cluster.local" .Release.Name .Release.Namespace -}}
{{- else -}}
{{- $host = required "redis.host is required when redis.deploy is false" .Values.redis.host -}}
{{- end -}}
{{- printf "%s:%d" $host (int (.Values.redis.port | default 6379)) -}}
{{- end -}}
{{- end -}}

{{/*
Celery queue names for KEDA redis triggers (defaults to workerImports.queues).
Returns a comma-separated string for splitList in templates.
*/}}
{{- define "efficientai.workerImports.kedaQueueList" -}}
{{- $wi := .Values.efficientai.workerImports -}}
{{- $keda := $wi.keda | default dict -}}
{{- $kedaQueues := $keda.queues | default list -}}
{{- if gt (len $kedaQueues) 0 -}}
{{- join "," $kedaQueues -}}
{{- else -}}
{{- $wi.queues | default "imports,diarization,eval-control,evaluations" -}}
{{- end -}}
{{- end -}}
