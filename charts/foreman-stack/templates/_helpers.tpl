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
{{- end }}

{{- define "foreman-stack.foremanVolumeMounts" -}}
- name: foreman-config
  mountPath: /etc/foreman/settings.yaml
  subPath: settings.yaml
  readOnly: true
- name: foreman-config
  mountPath: /etc/foreman/plugins/katello.yaml
  subPath: katello.yaml
  readOnly: true
- name: foreman-config
  mountPath: /etc/foreman/katello-default-ca.crt
  subPath: ca.crt
  readOnly: true
- name: foreman-config
  mountPath: /etc/foreman/client_cert.pem
  subPath: client_cert.pem
  readOnly: true
- name: foreman-config
  mountPath: /etc/foreman/client_key.pem
  subPath: client_key.pem
  readOnly: true
{{- end }}

{{- define "foreman-stack.foremanVolumes" -}}
- name: foreman-config
  secret:
    secretName: {{ .Values.foreman.existingConfigSecret }}
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
