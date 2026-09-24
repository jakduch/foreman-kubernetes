{{- define "foreman-stack.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "foreman-stack.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "foreman-stack.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "foreman-stack.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ include "foreman-stack.name" . }}
{{- end }}

{{- define "foreman-stack.componentLabels" -}}
{{ include "foreman-stack.labels" .root }}
app.kubernetes.io/name: {{ include "foreman-stack.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "foreman-stack.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "foreman-stack.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- required "serviceAccount.name is required when serviceAccount.create is false" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "foreman-stack.image" -}}
{{- printf "%s:%s" .repository .tag }}
{{- end }}

{{- define "foreman-stack.foremanConfigName" -}}
{{- printf "%s-foreman-config" (include "foreman-stack.fullname" .) }}
{{- end }}

{{- define "foreman-stack.candlepinConfigName" -}}
{{- printf "%s-candlepin-config" (include "foreman-stack.fullname" .) }}
{{- end }}

{{- define "foreman-stack.candlepinServiceName" -}}
{{- printf "%s-candlepin" (include "foreman-stack.fullname" .) }}
{{- end }}

{{- define "foreman-stack.foremanEnv" -}}
- name: RAILS_ENV
  value: production
- name: RAILS_LOG_TO_STDOUT
  value: "true"
- name: FOREMAN_BIND
  value: 0.0.0.0
- name: RAILS_SERVE_STATIC_FILES
  value: "true"
- name: FOREMAN_ENABLED_PLUGINS
  value: {{ join " " .Values.foreman.enabledPlugins | quote }}
- name: FOREMAN_PUMA_WORKERS
  value: {{ .Values.foreman.puma.workers | quote }}
- name: FOREMAN_PUMA_THREADS_MIN
  value: {{ .Values.foreman.puma.threadsMin | quote }}
- name: FOREMAN_PUMA_THREADS_MAX
  value: {{ .Values.foreman.puma.threadsMax | quote }}
- name: DYNFLOW_REDIS_URL
  value: {{ printf "redis://%s:%v/%v" .Values.valkey.host .Values.valkey.port .Values.valkey.dynflowDatabase | quote }}
- name: REDIS_PROVIDER
  value: DYNFLOW_REDIS_URL
- name: CANDLEPIN_OAUTH_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .Values.sharedSecret.name }}
      key: {{ .Values.sharedSecret.candlepinOAuthSecretKey }}
{{- end }}

{{- define "foreman-stack.foremanVolumeMounts" -}}
- name: foreman-generated-config
  mountPath: /etc/foreman/settings.yaml
  subPath: settings.yaml
  readOnly: true
- name: foreman-generated-config
  mountPath: /etc/foreman/plugins/katello.yaml
  subPath: katello.yaml
  readOnly: true
- name: foreman-certificates
  mountPath: /etc/foreman/katello-default-ca.crt
  subPath: ca.crt
  readOnly: true
- name: foreman-certificates
  mountPath: /etc/foreman/client_cert.pem
  subPath: client_cert.pem
  readOnly: true
- name: foreman-certificates
  mountPath: /etc/foreman/client_key.pem
  subPath: client_key.pem
  readOnly: true
{{- end }}

{{- define "foreman-stack.foremanVolumes" -}}
- name: foreman-generated-config
  configMap:
    name: {{ include "foreman-stack.foremanConfigName" . }}
- name: foreman-certificates
  secret:
    secretName: {{ .Values.foreman.existingCertificateSecret }}
{{- end }}

{{- define "foreman-stack.pulpEnv" -}}
- name: PULP_DATABASES__default__NAME
  value: {{ .Values.pulp.database.name | quote }}
- name: PULP_DATABASES__default__USER
  value: {{ .Values.pulp.database.user | quote }}
- name: PULP_DATABASES__default__PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.pulp.existingRuntimeSecret }}
      key: {{ .Values.pulp.databasePasswordSecretKey }}
- name: PULP_DATABASES__default__HOST
  value: {{ .Values.pulp.database.host | quote }}
- name: PULP_DATABASES__default__PORT
  value: {{ .Values.pulp.database.port | quote }}
- name: PULP_DATABASES__default__OPTIONS__sslmode
  value: {{ .Values.pulp.database.sslMode | quote }}
- name: PULP_REDIS_URL
  value: {{ printf "redis://%s:%v/%v" .Values.valkey.host .Values.valkey.port .Values.valkey.pulpDatabase | quote }}
- name: PULP_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.pulp.existingRuntimeSecret }}
      key: {{ .Values.pulp.djangoSecretKey }}
- name: PULP_CONTENT_ORIGIN
  value: {{ .Values.pulp.contentOrigin | quote }}
- name: PULP_ANSIBLE_API_HOSTNAME
  value: {{ .Values.pulp.contentOrigin | quote }}
- name: PULP_ANSIBLE_CONTENT_HOSTNAME
  value: {{ printf "%s/pulp/content" (trimSuffix "/" .Values.pulp.contentOrigin) | quote }}
- name: PULP_SMART_PROXY_PULP_URL
  value: {{ printf "http://%s-pulp-api:%v" (include "foreman-stack.fullname" .) .Values.pulp.api.port | quote }}
- name: PULP_ENABLED_PLUGINS
  value: {{ toJson .Values.pulp.enabledPlugins | quote }}
- name: PULP_AUTHENTICATION_BACKENDS
  value: '["pulpcore.app.authentication.PulpNoCreateRemoteUserBackend"]'
- name: PULP_REST_FRAMEWORK__DEFAULT_AUTHENTICATION_CLASSES
  value: '["rest_framework.authentication.SessionAuthentication", "pulpcore.app.authentication.PulpRemoteUserAuthentication"]'
- name: PULP_REMOTE_USER_ENVIRON_NAME
  value: HTTP_REMOTE_USER
- name: PULP_TOKEN_AUTH_DISABLED
  value: "true"
- name: PULP_CACHE_ENABLED
  value: "true"
{{- end }}

{{- define "foreman-stack.topologySpread" -}}
{{- if .Values.affinity.spreadAcrossNodes }}
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app.kubernetes.io/instance: {{ .Release.Name }}
        app.kubernetes.io/component: {{ .component }}
{{- end }}
{{- end }}
