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
platform.theforeman.org/compatibility-set: {{ .root.Values.platform.compatibilitySet | quote }}
{{- with .root.Values.releaseOperation.id }}
platform.theforeman.org/release-operation: {{ . | quote }}
platform.theforeman.org/release-owner: {{ $.root.Values.releaseOperation.ownerUid | quote }}
{{- end }}
{{- end }}

{{- define "foreman-stack.podLabels" -}}
app.kubernetes.io/name: {{ include "foreman-stack.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
platform.theforeman.org/compatibility-set: {{ .root.Values.platform.compatibilitySet | quote }}
{{- with .root.Values.releaseOperation.id }}
platform.theforeman.org/release-operation: {{ . | quote }}
platform.theforeman.org/release-owner: {{ $.root.Values.releaseOperation.ownerUid | quote }}
{{- end }}
{{- end }}

{{- define "foreman-stack.releaseOperationSuffix" -}}
{{- default (printf "%v" .Release.Revision) .Values.releaseOperation.id -}}
{{- end }}

{{- define "foreman-stack.releaseJobName" -}}
{{- $raw := printf "%s-%s-%s" (include "foreman-stack.fullname" .root) .component (include "foreman-stack.releaseOperationSuffix" .root) -}}
{{- if gt (len $raw) 63 -}}
{{- printf "%s-%s" ($raw | trunc 54 | trimSuffix "-") ($raw | sha256sum | trunc 8) -}}
{{- else -}}
{{- $raw -}}
{{- end -}}
{{- end }}

{{- define "foreman-stack.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "foreman-stack.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- required "serviceAccount.name is required when serviceAccount.create is false" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "foreman-stack.pulpServiceAccountName" -}}
{{- if .Values.pulp.serviceAccount.create }}
{{- default (printf "%s-pulp" (include "foreman-stack.fullname" .)) .Values.pulp.serviceAccount.name }}
{{- else }}
{{- required "pulp.serviceAccount.name is required when pulp.serviceAccount.create is false" .Values.pulp.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "foreman-stack.image" -}}
{{- printf "%s:%s" .repository .tag }}
{{- end }}

{{- define "foreman-stack.valkeyScheme" -}}
{{- ternary "rediss" "redis" .Values.valkey.tls.enabled }}
{{- end }}

{{- define "foreman-stack.imagePullSecrets" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "foreman-stack.restrictedContainerSecurityContext" -}}
allowPrivilegeEscalation: false
capabilities:
  drop:
    - ALL
runAsNonRoot: true
{{- with .runAsUser }}
runAsUser: {{ . }}
{{- end }}
{{- with .runAsGroup }}
runAsGroup: {{ . }}
{{- end }}
{{- end }}

{{- define "foreman-stack.foremanConfigName" -}}
{{- printf "%s-foreman-config" (include "foreman-stack.fullname" .) }}
{{- end }}

{{- define "foreman-stack.foremanClientHeadersName" -}}
{{- printf "%s-foreman-client-headers" (include "foreman-stack.fullname" .) }}
{{- end }}

{{- define "foreman-stack.candlepinConfigName" -}}
{{- printf "%s-candlepin-config" (include "foreman-stack.fullname" .) }}
{{- end }}

{{- define "foreman-stack.candlepinServiceName" -}}
{{- printf "%s-candlepin" (include "foreman-stack.fullname" .) }}
{{- end }}

{{- define "foreman-stack.pulpApiServiceName" -}}
{{- printf "%s-pulp-api" (include "foreman-stack.fullname" .) }}
{{- end }}

{{- define "foreman-stack.pulpContentServiceName" -}}
{{- printf "%s-pulp-content" (include "foreman-stack.fullname" .) }}
{{- end }}

{{- define "foreman-stack.pulpControlProxyServiceName" -}}
{{- printf "%s-pulp-control" (include "foreman-stack.fullname" .) }}
{{- end }}

{{- define "foreman-stack.pulpControlProxyUrl" -}}
{{- printf "https://%s" (include "foreman-stack.pulpControlProxyServiceName" .) }}
{{- end }}

{{- define "foreman-stack.pulpSmartProxyUrl" -}}
{{- printf "%s/pulp/api/v3/smart_proxy" (include "foreman-stack.pulpControlProxyUrl" .) }}
{{- end }}

{{- define "foreman-stack.pulpSmartProxyName" -}}
{{- default (printf "%s-pulp" .Values.platform.fqdn) .Values.pulp.controlProxy.registration.name }}
{{- end }}

{{- define "foreman-stack.pulpContentHeadersName" -}}
{{- printf "%s-pulp-content-headers" (include "foreman-stack.fullname" .) }}
{{- end }}

{{- define "foreman-stack.pulpPublicApiHeadersName" -}}
{{- printf "%s-pulp-public-api-headers" (include "foreman-stack.fullname" .) }}
{{- end }}

{{- define "foreman-stack.pulpControlProxyConfig" -}}
map $ssl_client_s_dn $pulp_remote_user {
  default "";
  ~(?:^|,)CN={{ regexQuoteMeta .Values.platform.fqdn }}(?:,|$) admin;
  {{- range .Values.pulp.controlProxy.trustedClientCommonNames }}
  ~(?:^|,)CN={{ regexQuoteMeta . }}(?:,|$) admin;
  {{- end }}
}

upstream pulp_api {
  server {{ include "foreman-stack.pulpApiServiceName" . }}:{{ .Values.pulp.api.port }};
  keepalive 32;
}

server {
  listen {{ .Values.pulp.controlProxy.port }} ssl;
  server_name _;
  server_tokens off;
  client_max_body_size 0;

  ssl_certificate /etc/nginx/pki/tls.crt;
  ssl_certificate_key /etc/nginx/pki/tls.key;
  ssl_client_certificate /etc/nginx/pki/ca.crt;
  ssl_verify_client on;
  ssl_verify_depth 3;
  ssl_protocols TLSv1.2 TLSv1.3;

  location / {
    if ($pulp_remote_user = "") { return 403; }

    proxy_http_version 1.1;
    proxy_request_buffering off;
    proxy_read_timeout 600s;
    proxy_set_header Connection "";
    proxy_set_header Host $http_host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header REMOTE-USER $pulp_remote_user;
    proxy_set_header X-CLIENT-CERT "";
    proxy_pass http://pulp_api;
  }
}
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
- name: VALKEY_FOREMAN_CACHE_URI_AUTH
  valueFrom:
    secretKeyRef:
      name: {{ .Values.valkey.existingSecret }}
      key: {{ .Values.valkey.foremanCacheUriAuthSecretKey }}
- name: VALKEY_DYNFLOW_URI_AUTH
  valueFrom:
    secretKeyRef:
      name: {{ .Values.valkey.existingSecret }}
      key: {{ .Values.valkey.dynflowUriAuthSecretKey }}
- name: FOREMAN_RAILS_CACHE_STORE_TYPE
  value: redis
- name: FOREMAN_RAILS_CACHE_STORE_URLS
  value: {{ printf "%s://$(VALKEY_FOREMAN_CACHE_URI_AUTH)%s:%v/%v" (include "foreman-stack.valkeyScheme" .) .Values.valkey.foremanCache.host .Values.valkey.foremanCache.port .Values.valkey.foremanCache.database | quote }}
- name: VALKEY_TLS_ENABLED
  value: {{ .Values.valkey.tls.enabled | quote }}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ .Values.foreman.existingEnvSecret }}
      key: {{ .Values.foreman.databaseUrlSecretKey }}
- name: PGSSLMODE
  value: {{ .Values.foreman.database.sslMode | quote }}
{{- if .Values.foreman.existingDatabaseCaSecret }}
- name: PGSSLROOTCERT
  value: /etc/foreman/certs/db-ca.crt
{{- end }}
- name: ENCRYPTION_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.foreman.existingEnvSecret }}
      key: {{ .Values.foreman.encryptionKeySecretKey }}
- name: SECRET_KEY_BASE
  valueFrom:
    secretKeyRef:
      name: {{ .Values.foreman.existingEnvSecret }}
      key: {{ .Values.foreman.secretKeyBaseSecretKey }}
- name: DYNFLOW_REDIS_URL
  value: {{ printf "%s://$(VALKEY_DYNFLOW_URI_AUTH)%s:%v/%v" (include "foreman-stack.valkeyScheme" .) .Values.valkey.dynflow.host .Values.valkey.dynflow.port .Values.valkey.dynflow.database | quote }}
- name: REDIS_PROVIDER
  value: DYNFLOW_REDIS_URL
- name: CANDLEPIN_OAUTH_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .Values.sharedSecret.name }}
      key: {{ .Values.sharedSecret.candlepinOAuthSecretKey }}
{{- if and .Values.foreman.email.enabled (ne .Values.foreman.email.smtp.authentication "none") }}
- name: FOREMAN_SMTP_USERNAME
  valueFrom:
    secretKeyRef:
      name: {{ .Values.foreman.email.smtp.existingSecret }}
      key: {{ .Values.foreman.email.smtp.usernameSecretKey }}
- name: FOREMAN_SMTP_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.foreman.email.smtp.existingSecret }}
      key: {{ .Values.foreman.email.smtp.passwordSecretKey }}
{{- end }}
{{- end }}

{{- define "foreman-stack.foremanSeedEnv" -}}
- name: SEED_ADMIN_USER
  valueFrom:
    secretKeyRef:
      name: {{ .Values.foreman.existingEnvSecret }}
      key: {{ .Values.foreman.seedAdminUserSecretKey }}
- name: SEED_ADMIN_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.foreman.existingEnvSecret }}
      key: {{ .Values.foreman.seedAdminPasswordSecretKey }}
{{- end }}

{{- define "foreman-stack.foremanDatabasePoolEnv" -}}
- name: FOREMAN_DATABASE_POOL
  value: {{ . | quote }}
{{- end }}

{{- define "foreman-stack.foremanVolumeMounts" -}}
- name: foreman-tmp
  mountPath: /usr/share/foreman/tmp
- name: foreman-generated-config
  mountPath: /usr/share/foreman/config/database.yml
  subPath: database.yml
  readOnly: true
- name: foreman-generated-config
  mountPath: /etc/foreman/settings.yaml
  subPath: settings.yaml
  readOnly: true
- name: foreman-generated-config
  mountPath: /etc/foreman/plugins/katello.yaml
  subPath: katello.yaml
  readOnly: true
- name: foreman-generated-config
  mountPath: /usr/share/foreman/config/initializers/foreman_kubernetes_client_certificate.rb
  subPath: foreman-kubernetes-client-certificate.rb
  readOnly: true
- name: foreman-generated-config
  mountPath: /usr/share/foreman/config/initializers/foreman_kubernetes_valkey_tls.rb
  subPath: foreman-kubernetes-valkey-tls.rb
  readOnly: true
- name: foreman-generated-config
  mountPath: /opt/foreman-kubernetes/foreman-readiness.rb
  subPath: foreman-readiness.rb
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
{{- if .Values.foreman.existingDatabaseCaSecret }}
- name: foreman-database-ca
  mountPath: /etc/foreman/certs/db-ca.crt
  subPath: db-ca.crt
  readOnly: true
{{- end }}
{{- if .Values.valkey.tls.enabled }}
- name: valkey-ca
  mountPath: /etc/foreman/certs/valkey-ca.crt
  subPath: {{ .Values.valkey.tls.caSecretKey }}
  readOnly: true
{{- end }}
{{- end }}

{{- define "foreman-stack.foremanVolumes" -}}
- name: foreman-tmp
  persistentVolumeClaim:
    claimName: {{ default (printf "%s-foreman-tmp" (include "foreman-stack.fullname" .)) .Values.foreman.sharedTmp.existingClaim }}
- name: foreman-generated-config
  configMap:
    name: {{ include "foreman-stack.foremanConfigName" . }}
- name: foreman-certificates
  secret:
    secretName: {{ .Values.foreman.existingCertificateSecret }}
{{- if .Values.foreman.existingDatabaseCaSecret }}
- name: foreman-database-ca
  secret:
    secretName: {{ .Values.foreman.existingDatabaseCaSecret }}
    items:
      - key: db-ca.crt
        path: db-ca.crt
{{- end }}
{{- if .Values.valkey.tls.enabled }}
- name: valkey-ca
  secret:
    secretName: {{ .Values.valkey.tls.existingCaSecret }}
    items:
      - key: {{ .Values.valkey.tls.caSecretKey }}
        path: {{ .Values.valkey.tls.caSecretKey }}
{{- end }}
{{- end }}

{{- define "foreman-stack.foremanAvatarVolumeMount" -}}
- name: foreman-avatars
  mountPath: /usr/share/foreman/public/images/avatars
{{- end }}

{{- define "foreman-stack.foremanAvatarVolume" -}}
- name: foreman-avatars
  persistentVolumeClaim:
    claimName: {{ default (printf "%s-foreman-avatars" (include "foreman-stack.fullname" .)) .Values.foreman.avatarStorage.existingClaim }}
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
{{- if .Values.pulp.existingDatabaseCaSecret }}
- name: PULP_DATABASES__default__OPTIONS__sslrootcert
  value: /etc/pulp/certs/db-ca.crt
{{- end }}
{{- if eq .Values.pulp.storage.backend "s3" }}
- name: PULP_MEDIA_ROOT
  value: ""
- name: PULP_WORKING_DIRECTORY
  value: /var/lib/pulp/tmp
- name: PULP_STORAGES__default__BACKEND
  value: storages.backends.s3.S3Storage
- name: PULP_STORAGES__default__OPTIONS__bucket_name
  value: {{ .Values.pulp.storage.s3.bucket | quote }}
{{- with .Values.pulp.storage.s3.location }}
- name: PULP_STORAGES__default__OPTIONS__location
  value: {{ . | quote }}
{{- end }}
{{- with .Values.pulp.storage.s3.region }}
- name: PULP_STORAGES__default__OPTIONS__region_name
  value: {{ . | quote }}
{{- end }}
{{- with .Values.pulp.storage.s3.endpointUrl }}
- name: PULP_STORAGES__default__OPTIONS__endpoint_url
  value: {{ . | quote }}
{{- end }}
- name: PULP_STORAGES__default__OPTIONS__addressing_style
  value: {{ .Values.pulp.storage.s3.addressingStyle | quote }}
- name: PULP_STORAGES__default__OPTIONS__signature_version
  value: {{ .Values.pulp.storage.s3.signatureVersion | quote }}
- name: PULP_REDIRECT_TO_OBJECT_STORAGE
  value: {{ .Values.pulp.storage.s3.redirectToObjectStorage | quote }}
{{- if .Values.pulp.storage.s3.existingCaSecret }}
- name: AWS_CA_BUNDLE
  value: /etc/pulp/object-storage/ca.crt
{{- end }}
{{- end }}
- name: PULP_REDIS_HOST
  value: {{ .Values.valkey.pulp.host | quote }}
- name: PULP_REDIS_PORT
  value: {{ .Values.valkey.pulp.port | quote }}
- name: PULP_REDIS_DB
  value: {{ .Values.valkey.pulp.database | quote }}
- name: PULP_REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.valkey.existingSecret }}
      key: {{ .Values.valkey.pulpPasswordSecretKey }}
{{- if .Values.valkey.tls.enabled }}
- name: PULP_REDIS_SSL
  value: "true"
- name: PULP_REDIS_SSL_CA_CERTS
  value: /etc/pulp/certs/valkey-ca.crt
{{- else }}
- name: PULP_REDIS_SSL
  value: "false"
{{- end }}
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
  value: {{ include "foreman-stack.pulpControlProxyUrl" . | quote }}
- name: PULP_SMART_PROXY_RHSM_URL
  value: {{ printf "%s/rhsm" (trimSuffix "/" .Values.platform.externalUrl) | quote }}
- name: PULP_SMART_PROXY_MIRROR
  value: "false"
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

{{- define "foreman-stack.pulpObjectStorageCredentialEnv" -}}
{{- if and (eq .Values.pulp.storage.backend "s3") .Values.pulp.storage.s3.existingSecret }}
- name: PULP_STORAGES__default__OPTIONS__access_key
  valueFrom:
    secretKeyRef:
      name: {{ .Values.pulp.storage.s3.existingSecret }}
      key: {{ .Values.pulp.storage.s3.accessKeySecretKey }}
- name: PULP_STORAGES__default__OPTIONS__secret_key
  valueFrom:
    secretKeyRef:
      name: {{ .Values.pulp.storage.s3.existingSecret }}
      key: {{ .Values.pulp.storage.s3.secretKeySecretKey }}
{{- if .Values.pulp.storage.s3.sessionTokenSecretKey }}
- name: PULP_STORAGES__default__OPTIONS__security_token
  valueFrom:
    secretKeyRef:
      name: {{ .Values.pulp.storage.s3.existingSecret }}
      key: {{ .Values.pulp.storage.s3.sessionTokenSecretKey }}
{{- end }}
{{- end }}
{{- end }}

{{- define "foreman-stack.pulpStorageVolumeMount" -}}
- name: pulp-data
{{- if eq .Values.pulp.storage.backend "filesystem" }}
  mountPath: /var/lib/pulp
{{- else }}
  mountPath: /var/lib/pulp/tmp
{{- end }}
{{- end }}

{{- define "foreman-stack.pulpStorageVolume" -}}
- name: pulp-data
{{- if eq .Values.pulp.storage.backend "filesystem" }}
  persistentVolumeClaim:
    claimName: {{ default (printf "%s-pulp" (include "foreman-stack.fullname" .)) .Values.pulp.storage.existingClaim }}
{{- else }}
  emptyDir:
    sizeLimit: {{ .Values.pulp.storage.scratch.sizeLimit }}
{{- end }}
{{- end }}

{{- define "foreman-stack.pulpObjectStorageCaVolumeMount" -}}
{{- if and (eq .Values.pulp.storage.backend "s3") .Values.pulp.storage.s3.existingCaSecret }}
- name: pulp-object-storage-ca
  mountPath: /etc/pulp/object-storage/ca.crt
  subPath: {{ .Values.pulp.storage.s3.caSecretKey }}
  readOnly: true
{{- end }}
{{- end }}

{{- define "foreman-stack.pulpObjectStorageCaVolume" -}}
{{- if and (eq .Values.pulp.storage.backend "s3") .Values.pulp.storage.s3.existingCaSecret }}
- name: pulp-object-storage-ca
  secret:
    secretName: {{ .Values.pulp.storage.s3.existingCaSecret }}
{{- end }}
{{- end }}

{{- define "foreman-stack.pulpDatabaseCaVolumeMount" -}}
{{- if .Values.pulp.existingDatabaseCaSecret }}
- name: pulp-database-ca
  mountPath: /etc/pulp/certs/db-ca.crt
  subPath: db-ca.crt
  readOnly: true
{{- end }}
{{- end }}

{{- define "foreman-stack.pulpDatabaseCaVolume" -}}
{{- if .Values.pulp.existingDatabaseCaSecret }}
- name: pulp-database-ca
  secret:
    secretName: {{ .Values.pulp.existingDatabaseCaSecret }}
    items:
      - key: db-ca.crt
        path: db-ca.crt
{{- end }}
{{- end }}

{{- define "foreman-stack.pulpValkeyCaVolumeMount" -}}
{{- if .Values.valkey.tls.enabled }}
- name: valkey-ca
  mountPath: /etc/pulp/certs/valkey-ca.crt
  subPath: {{ .Values.valkey.tls.caSecretKey }}
  readOnly: true
{{- end }}
{{- end }}

{{- define "foreman-stack.pulpValkeyCaVolume" -}}
{{- if .Values.valkey.tls.enabled }}
- name: valkey-ca
  secret:
    secretName: {{ .Values.valkey.tls.existingCaSecret }}
    items:
      - key: {{ .Values.valkey.tls.caSecretKey }}
        path: {{ .Values.valkey.tls.caSecretKey }}
{{- end }}
{{- end }}

{{- define "foreman-stack.foremanMigrationWait" -}}
- name: wait-for-foreman-migrations
  image: {{ include "foreman-stack.image" .Values.foreman.image }}
  imagePullPolicy: {{ .Values.foreman.image.pullPolicy }}
  securityContext:
    {{- include "foreman-stack.restrictedContainerSecurityContext" (dict "runAsUser" 994 "runAsGroup" 994) | nindent 4 }}
  command:
    - /bin/bash
    - -ec
    - until bin/rails db:abort_if_pending_migrations; do sleep {{ .Values.migrations.checkIntervalSeconds }}; done
  env:
    {{- include "foreman-stack.foremanEnv" . | nindent 4 }}
    {{- include "foreman-stack.foremanDatabasePoolEnv" .Values.foreman.databasePools.utility | nindent 4 }}
  resources:
    {{- toYaml .Values.foreman.resources | nindent 4 }}
  volumeMounts:
    {{- include "foreman-stack.foremanVolumeMounts" . | nindent 4 }}
{{- end }}

{{- define "foreman-stack.pulpMigrationWait" -}}
- name: wait-for-pulp-migrations
  image: {{ include "foreman-stack.image" .Values.pulp.image }}
  imagePullPolicy: {{ .Values.pulp.image.pullPolicy }}
  securityContext:
    {{- include "foreman-stack.restrictedContainerSecurityContext" (dict "runAsUser" 700 "runAsGroup" 700) | nindent 4 }}
  command:
    - /bin/bash
    - -ec
    - until pulpcore-manager migrate --check; do sleep {{ .Values.migrations.checkIntervalSeconds }}; done
  env:
    {{- include "foreman-stack.pulpEnv" . | nindent 4 }}
  resources:
    {{- toYaml .Values.pulp.resources | nindent 4 }}
  volumeMounts:
    - name: pulp-config
      mountPath: /etc/pulp/certs/database_fields.symmetric.key
      subPath: database_fields.symmetric.key
      readOnly: true
    {{- include "foreman-stack.pulpDatabaseCaVolumeMount" . | nindent 4 }}
    {{- include "foreman-stack.pulpValkeyCaVolumeMount" . | nindent 4 }}
    {{- include "foreman-stack.pulpObjectStorageCaVolumeMount" . | nindent 4 }}
{{- end }}

{{- define "foreman-stack.topologySpread" -}}
{{- if .Values.affinity.spreadAcrossNodes }}
topologySpreadConstraints:
  {{- range .Values.affinity.topologyKeys }}
  - maxSkew: 1
    topologyKey: {{ . }}
    whenUnsatisfiable: {{ $.Values.affinity.whenUnsatisfiable }}
    labelSelector:
      matchLabels:
        app.kubernetes.io/instance: {{ $.Release.Name }}
        app.kubernetes.io/component: {{ $.component }}
  {{- end }}
{{- end }}
{{- end }}
