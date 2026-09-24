{{- define "foreman-execution-proxy.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "foreman-execution-proxy.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "foreman-execution-proxy.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "foreman-execution-proxy.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "foreman-execution-proxy.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: execution-proxy
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: foreman
platform.theforeman.org/compatibility-set: {{ .Values.compatibilitySet | quote }}
{{- end }}

{{- define "foreman-execution-proxy.selectorLabels" -}}
app.kubernetes.io/name: {{ include "foreman-execution-proxy.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: execution-proxy
{{- end }}

{{- define "foreman-execution-proxy.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "foreman-execution-proxy.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- required "serviceAccount.name is required when serviceAccount.create is false" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "foreman-execution-proxy.stateClaimName" -}}
{{- default (printf "%s-state" (include "foreman-execution-proxy.fullname" .)) .Values.state.existingClaim }}
{{- end }}

{{- define "foreman-execution-proxy.ansibleClaimName" -}}
{{- default (printf "%s-ansible" (include "foreman-execution-proxy.fullname" .)) .Values.ansible.existingClaim }}
{{- end }}

{{- define "foreman-execution-proxy.containerSecurityContext" -}}
allowPrivilegeEscalation: false
capabilities:
  drop:
    - ALL
readOnlyRootFilesystem: true
runAsGroup: 991
runAsNonRoot: true
runAsUser: 991
{{- end }}
