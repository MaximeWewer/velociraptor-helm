{{/* Expand the name of the chart. */}}
{{- define "velociraptor.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Fully qualified app name. */}}
{{- define "velociraptor.fullname" -}}
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

{{- define "velociraptor.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Common labels. */}}
{{- define "velociraptor.labels" -}}
helm.sh/chart: {{ include "velociraptor.chart" . }}
{{ include "velociraptor.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: velociraptor
{{- end }}

{{- define "velociraptor.selectorLabels" -}}
app.kubernetes.io/name: {{ include "velociraptor.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* ServiceAccount name. */}}
{{- define "velociraptor.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "velociraptor.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* Full image reference (registry/repository:tag or @digest). */}}
{{- define "velociraptor.image" -}}
{{- $registry := .Values.image.registry -}}
{{- $repository := .Values.image.repository -}}
{{- $ref := $repository -}}
{{- if $registry -}}
{{- $ref = printf "%s/%s" $registry $repository -}}
{{- end -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" $ref .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" $ref (.Values.image.tag | default .Chart.AppVersion) -}}
{{- end -}}
{{- end }}

{{/* "true" when the master API (gRPC) listens on 0.0.0.0 behind the <fullname>-api Service:
     multi-frontend (minions) or api.expose (API clients outside the pod, e.g. Tracecat). */}}
{{- define "velociraptor.apiServed" -}}
{{- if or .Values.frontend.minions.enabled .Values.api.expose.enabled -}}true{{- end -}}
{{- end }}

{{/* Where the server config comes from: existingSecret | inline | bootstrap | none. */}}
{{- define "velociraptor.configSource" -}}
{{- if .Values.config.existingSecret -}}existingSecret
{{- else if .Values.config.inline -}}inline
{{- else if .Values.config.bootstrap.enabled -}}bootstrap
{{- else -}}none
{{- end -}}
{{- end }}

{{/* Secret generated & renewed by the PKI job (bootstrap mode). */}}
{{- define "velociraptor.bootstrapSecretName" -}}
{{- .Values.config.bootstrap.secretName | default (printf "%s-server-config" (include "velociraptor.fullname" .)) -}}
{{- end }}

{{/* Name of the Secret holding the server config. */}}
{{- define "velociraptor.configSecretName" -}}
{{- $src := include "velociraptor.configSource" . -}}
{{- if eq $src "existingSecret" -}}
{{- .Values.config.existingSecret -}}
{{- else if eq $src "bootstrap" -}}
{{- include "velociraptor.bootstrapSecretName" . -}}
{{- else -}}
{{- printf "%s-config" (include "velociraptor.fullname" .) -}}
{{- end -}}
{{- end }}

{{/* Secret holding the initial admin password. */}}
{{- define "velociraptor.adminSecretName" -}}
{{- .Values.gui.initialAdmin.existingSecret | default (printf "%s-admin" (include "velociraptor.fullname" .)) -}}
{{- end }}

{{/* "true" when the PKI hook Job must run: bootstrap mode, or an admin password to generate. */}}
{{- define "velociraptor.pkiJobEnabled" -}}
{{- if or (eq (include "velociraptor.configSource" .) "bootstrap") (and .Values.gui.initialAdmin.enabled (not .Values.gui.initialAdmin.existingSecret)) (and .Values.apiClients (ne (include "velociraptor.configSource" .) "none")) -}}true{{- end -}}
{{- end }}

{{/* API clients as the PKI job sees them: [{name, secret, key}]. */}}
{{- define "velociraptor.apiClientsPki" -}}
{{- $out := list -}}
{{- $reserved := list "GRPC_GW" "velociraptor-helm" -}}
{{- if $.Values.gui.initialAdmin.enabled }}{{ $reserved = append $reserved $.Values.gui.initialAdmin.username }}{{ end -}}
{{- range .Values.apiClients -}}
{{- /* GRPC_GW = the GUI gateway's certificate name: a client certificate carrying it may act as
       ANY user. velociraptor-helm = the reconciler itself. The initial admin is managed apart. */ -}}
{{- if has .name $reserved }}{{ fail (printf "apiClients: the name %q is reserved (%s)" .name (join ", " $reserved)) }}{{ end -}}
{{- $out = append $out (dict "name" .name "secret" (.secretName | default (printf "%s-api-%s" (include "velociraptor.fullname" $) .name)) "key" (.secretKey | default "api.config.yaml") "days" (.validityDays | default 0 | int)) -}}
{{- end -}}
{{- toJson $out -}}
{{- end }}

{{/* host:port API clients dial: the API Service when it is served, else in-pod loopback. */}}
{{- define "velociraptor.apiConnection" -}}
{{- if eq (include "velociraptor.apiServed" .) "true" -}}
{{- printf "%s-api.%s.svc:%v" (include "velociraptor.fullname" .) .Release.Namespace .Values.frontend.apiPort -}}
{{- else -}}
{{- printf "127.0.0.1:%v" .Values.frontend.apiPort -}}
{{- end -}}
{{- end }}

{{/* "true" when the certificate CronJob runs: renew (bootstrap) or check read-only (existingSecret / inline). */}}
{{- define "velociraptor.pkiCronEnabled" -}}
{{- if and .Values.config.bootstrap.renewal.enabled (ne (include "velociraptor.configSource" .) "none") -}}true{{- end -}}
{{- end }}

{{/* "true" when the PKI RBAC is needed (hook Job or CronJob). */}}
{{- define "velociraptor.pkiEnabled" -}}
{{- if or (eq (include "velociraptor.pkiJobEnabled" .) "true") (eq (include "velociraptor.pkiCronEnabled" .) "true") -}}true{{- end -}}
{{- end }}

{{/* Labels of the PKI job pods. No app.kubernetes.io/name on purpose: the chart's
     NetworkPolicy selects name+instance and would block their egress to the API server. */}}
{{- define "velociraptor.pkiLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: pki
app.kubernetes.io/part-of: velociraptor
{{- end }}

{{/* Pod template spec shared by the PKI hook Job and the renewal CronJob.
     Call with (dict "root" $ "cron" true|false). */}}
{{- define "velociraptor.pkiPodSpec" -}}
{{- $cron := .cron -}}
{{- with .root -}}
{{- $bs := .Values.config.bootstrap -}}
{{- $bootstrap := eq (include "velociraptor.configSource" .) "bootstrap" -}}
{{- /* Hook: manage the bootstrap Secret (if any). Cron: the active config Secret; read-only unless bootstrap. */}}
{{- $secretName := "" -}}
{{- if $cron }}{{ $secretName = include "velociraptor.configSecretName" . }}{{ else if $bootstrap }}{{ $secretName = include "velociraptor.bootstrapSecretName" . }}{{ end -}}
serviceAccountName: {{ include "velociraptor.fullname" . }}-pki
automountServiceAccountToken: true
restartPolicy: Never
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
securityContext:
  {{- toYaml .Values.podSecurityContext | nindent 2 }}
containers:
  - name: pki
    image: {{ include "velociraptor.image" . }}
    imagePullPolicy: {{ .Values.image.pullPolicy }}
    args:
      # -v: without it `velociraptor query` only prints ERROR logs (warnings would be lost).
      - -v
      - query
      - --nobanner
      - --format=jsonl
      - --env
      - Bin=/velociraptor
      - --env
      - WorkDir=/work
      - --env
      - KubeAPI=https://kubernetes.default.svc
      - --env
      - SADir=/var/run/secrets/kubernetes.io/serviceaccount
      - --env
      - Release={{ .Release.Name }}
      - --env
      - SecretName={{ $secretName }}
      - --env
      - SecretKey={{ .Values.config.secretKey }}
      - --env
      - ImportFrom={{ $bs.importFrom | default (printf "%s-config" (include "velociraptor.fullname" .)) }}
      - --env
      - ValidityDays={{ $bs.certificateValidityDays }}
      - --env
      - RenewBeforeDays={{ $bs.renewBeforeDays }}
      - --env
      - RestartOnRenew={{ $bs.restartOnRenew }}
      - --env
      - PodSelector=app.kubernetes.io/name={{ include "velociraptor.name" . }},app.kubernetes.io/instance={{ .Release.Name }}
      - --env
      - AdminSecretName={{ if and (not $cron) .Values.gui.initialAdmin.enabled (not .Values.gui.initialAdmin.existingSecret) }}{{ include "velociraptor.adminSecretName" . }}{{ end }}
      - --env
      - AdminPasswordKey={{ .Values.gui.initialAdmin.passwordKey }}
      - --env
      - CheckOnly={{ not $bootstrap }}
      - --env
      - Context={{ ternary "cron" "hook" $cron }}
      - --env
      - CAWarnDays={{ $bs.caWarnDays }}
      - --env
      - {{ printf "ApiClients=%s" (include "velociraptor.apiClientsPki" .) | quote }}
      - --env
      - ApiConnection={{ include "velociraptor.apiConnection" . }}
      - --env
      - ConfigSecret={{ if ne (include "velociraptor.configSource" .) "bootstrap" }}{{ include "velociraptor.configSecretName" . }}{{ end }}
      - {{ .Files.Get "files/pki.vql" | toJson }}
    securityContext:
      {{- toYaml .Values.securityContext | nindent 6 }}
    resources:
      {{- toYaml $bs.resources | nindent 6 }}
    volumeMounts:
      - name: work
        mountPath: /work
      - name: tmp
        mountPath: /tmp
volumes:
  - name: work
    emptyDir:
      sizeLimit: 64Mi
  - name: tmp
    emptyDir:
      sizeLimit: 64Mi
{{- end }}
{{- end }}

{{/* "true" when the API reconciler sidecar runs (orgs and/or API client roles to apply). */}}
{{- define "velociraptor.reconcilerEnabled" -}}
{{- /* api.expose: keeps revoking removed API clients even once the list is empty. */ -}}
{{- if or .Values.orgs.items .Values.apiClients .Values.state.orgs .Values.clientConfig.export.enabled .Values.api.expose.enabled -}}true{{- end -}}
{{- end }}

{{/* Org ids whose client config is exported (JSON list): clientConfig.export.orgs, or
     root + orgs.items. Empty list when the export is disabled. */}}
{{- define "velociraptor.exportOrgs" -}}
{{- $ids := list -}}
{{- if .Values.clientConfig.export.enabled -}}
{{- if .Values.clientConfig.export.orgs -}}{{ $ids = .Values.clientConfig.export.orgs }}
{{- else -}}{{ $ids = list "root" }}{{ range .Values.orgs.items }}{{ $ids = append $ids .id }}{{ end }}{{- end -}}
{{- end -}}
{{- toJson $ids -}}
{{- end }}

{{/* Non-root orgs the reconciler acts in (JSON list): orgs.items, state.orgs, export. */}}
{{- define "velociraptor.managedOrgs" -}}
{{- $ids := list -}}
{{- range .Values.orgs.items }}{{ $ids = append $ids .id }}{{ end -}}
{{- range .Values.state.orgs }}{{ $ids = append $ids (.id | default "root") }}{{ end -}}
{{- range (include "velociraptor.exportOrgs" . | fromJsonArray) }}{{ $ids = append $ids . }}{{ end -}}
{{- toJson (without ($ids | uniq) "root") -}}
{{- end }}

{{/* Prefix of the exported client config Secrets (+ lowercased org id). */}}
{{- define "velociraptor.exportPrefix" -}}
{{- .Values.clientConfig.export.secretPrefix | default (printf "%s-client-" (include "velociraptor.fullname" .)) -}}
{{- end }}

{{/* Seconds from an int or a duration string ("90s", "15m", "12h", "7d"). */}}
{{- define "velociraptor.seconds" -}}
{{- $v := toString . -}}
{{- if regexMatch "^[0-9]+$" $v -}}{{ $v }}
{{- else if regexMatch "^[0-9]+[smhd]$" $v -}}
{{- $n := int (trimSuffix (regexFind "[smhd]$" $v) $v) -}}
{{- $u := regexFind "[smhd]$" $v -}}
{{- if eq $u "s" }}{{ $n }}{{ else if eq $u "m" }}{{ mul $n 60 }}{{ else if eq $u "h" }}{{ mul $n 3600 }}{{ else }}{{ mul $n 86400 }}{{ end -}}
{{- else -}}{{ fail (printf "invalid duration %q (use an integer of seconds or 90s / 15m / 12h / 7d)" $v) }}
{{- end -}}
{{- end }}

{{/* ArtifactCollectorArgs (protobuf JSON shape) from a list of artifact names or
     {name, parameters: {key: value}} entries. */}}
{{- define "velociraptor.collectorArgs" -}}
{{- $names := list -}}{{- $specs := list -}}
{{- range . -}}
{{- if kindIs "string" . -}}
{{- $names = append $names . -}}
{{- else -}}
{{- $names = append $names .name -}}
{{- if .parameters -}}
{{- $env := list -}}
{{- range $k, $v := .parameters }}{{ $env = append $env (dict "key" $k "value" (toString $v)) }}{{ end -}}
{{- $specs = append $specs (dict "artifact" .name "parameters" (dict "env" $env)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $out := dict "artifacts" $names -}}
{{- if $specs }}{{ $_ := set $out "specs" $specs }}{{ end -}}
{{- toJson $out -}}
{{- end }}

{{/* Per-org state for chart/files/state.vql, as JSON. */}}
{{- define "velociraptor.stateJson" -}}
{{- $out := list -}}
{{- range .Values.state.orgs -}}
{{- $o := dict "id" (.id | default "root") "clientMonitoring" "" "serverMonitoring" "" -}}
{{- $users := list -}}
{{- range .users }}{{ if not (and .name .roles) }}{{ fail "state.orgs[].users[] needs a name and roles" }}{{ end }}{{ $users = append $users (dict "name" .name "roles" .roles "policy" (include "velociraptor.policyJson" .permissions)) }}{{ end -}}
{{- $_ := set $o "users" $users -}}
{{- if .clientMonitoring -}}
{{- $cm := dict "artifacts" (include "velociraptor.collectorArgs" (.clientMonitoring.all | default list) | fromJson) -}}
{{- $labels := list -}}
{{- range $label, $arts := (.clientMonitoring.labels | default dict) }}{{ $labels = append $labels (dict "label" $label "artifacts" (include "velociraptor.collectorArgs" $arts | fromJson)) }}{{ end -}}
{{- if $labels }}{{ $_ := set $cm "label_events" $labels }}{{ end -}}
{{- $_ := set $o "clientMonitoring" (toJson $cm) -}}
{{- end -}}
{{- if .serverMonitoring -}}
{{- $_ := set $o "serverMonitoring" (include "velociraptor.collectorArgs" .serverMonitoring) -}}
{{- end -}}
{{- $tools := list -}}
{{- range .tools -}}
{{- if not (and .name .url .hash) }}{{ fail "state.orgs[].tools[] needs a name, a url and a sha256 hash" }}{{ end -}}
{{- $tools = append $tools (dict "name" .name "url" .url "hash" (trimPrefix "sha256:" .hash) "serveLocally" (.serveLocally | default false) "filename" (.filename | default "") "version" (.version | default "")) -}}
{{- end -}}
{{- $_ := set $o "tools" $tools -}}
{{- $secrets := list -}}
{{- range .secrets -}}
{{- if not (and .name .type .fromSecret .fromSecret.name .fromSecret.key) }}{{ fail "state.orgs[].secrets[] needs a name, a type and fromSecret {name, key}" }}{{ end -}}
{{- $secrets = append $secrets (dict "name" .name "type" .type "file" (printf "/state-secrets/%s/%s" .fromSecret.name .fromSecret.key)) -}}
{{- end -}}
{{- $_ := set $o "secrets" $secrets -}}
{{- $hunts := list -}}
{{- range .hunts -}}
{{- if not (and .name .artifacts .every) }}{{ fail "state.orgs[].hunts[] needs a name, artifacts and every" }}{{ end -}}
{{- $every := include "velociraptor.seconds" .every | int -}}
{{- $h := dict "name" .name "tag" (printf "helm:%s" .name) "artifacts" .artifacts "labels" (.labels | default list) "os" (.os | default "") "everySeconds" $every "expiresSeconds" (include "velociraptor.seconds" (.expires | default .every) | int) "spec" "" -}}
{{- with .parameters }}{{ $_ := set $h "spec" (toJson .) }}{{ end -}}
{{- $hunts = append $hunts $h -}}
{{- end -}}
{{- $_ := set $o "hunts" $hunts -}}
{{- $out = append $out $o -}}
{{- end -}}
{{- toJson $out -}}
{{- end }}

{{/* Kubernetes Secrets referenced by state.orgs[].secrets[].fromSecret (JSON list of names). */}}
{{- define "velociraptor.stateSecretNames" -}}
{{- $names := list -}}
{{- range .Values.state.orgs }}{{ range .secrets }}{{ $names = append $names .fromSecret.name }}{{ end }}{{ end -}}
{{- toJson ($names | uniq) -}}
{{- end }}

{{/* API clients as the reconciler sees them: [{name, roles, orgs}]. */}}
{{/* Extra permissions on top of the roles, as the JSON policy user_grant expects
     ({"execve": true, ...}); "" when none. Names are case-insensitive (EXECVE = execve). */}}
{{- define "velociraptor.policyJson" -}}
{{- $p := dict -}}
{{- range . }}{{ $_ := set $p (lower .) true }}{{ end -}}
{{- if $p }}{{ toJson $p }}{{ end -}}
{{- end }}

{{- define "velociraptor.apiClientsGrants" -}}
{{- $out := list -}}
{{- range .Values.apiClients -}}
{{- $out = append $out (dict "name" .name "roles" .roles "orgs" (.orgs | default (list "root")) "policy" (include "velociraptor.policyJson" .permissions)) -}}
{{- end -}}
{{- toJson $out -}}
{{- end }}

{{/* Orgs: an init container issues an in-memory API client certificate (offline), then a
     native sidecar reconciles the declared state through the live API (chart/files/state.vql). */}}
{{- define "velociraptor.orgsInitContainers" -}}
{{- if eq (include "velociraptor.reconcilerEnabled" .) "true" }}
{{- if not (semverCompare ">=1.29.0-0" .Capabilities.KubeVersion.Version) }}
{{- fail "orgs.items / apiClients / state.orgs need Kubernetes >= 1.29 (native sidecar containers)." }}
{{- end }}
{{- range .Values.apiClients }}
{{- if not (and .name .roles) }}{{ fail "each apiClients[] entry needs a name and roles" }}{{ end }}
{{- end }}
{{- range .Values.orgs.items }}
{{- if not (and .id .name) }}{{ fail "each orgs.items[] entry needs an id and a name" }}{{ end }}
{{- end }}
- name: reconciler-api-client
  image: {{ include "velociraptor.image" . }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  # Issues the certificate and pins the connection to 127.0.0.1 (see the VQL).
  args:
    - --nobanner
    - --config
    - {{ .Values.config.mountPath }}
    - query
    - --format=jsonl
    - --env
    - Config={{ .Values.config.mountPath }}
    - --env
    - Out=/api/api.yaml
    - --env
    - Port={{ .Values.frontend.apiPort }}
    - {{ .Files.Get "files/reconciler-api-client.vql" | toJson }}
  securityContext:
    {{- toYaml .Values.securityContext | nindent 4 }}
  volumeMounts:
    {{- include "velociraptor.configVolumeMount" . | nindent 4 }}
    {{- include "velociraptor.customArtifactsVolumeMount" . | nindent 4 }}
    - name: datastore
      mountPath: {{ .Values.persistence.mountPath }}
    - name: api-client
      mountPath: /api
    {{- if .Values.tmpDir.enabled }}
    - name: tmp
      mountPath: /tmp
    {{- end }}
- name: state-reconciler
  image: {{ include "velociraptor.image" . }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  # Native sidecar: a local VQL loop that never exits (so it never delays the server's
  # start) and calls the API client every period, retrying until the API is up.
  restartPolicy: Always
  args:
    - -v
    - --nobanner
    - query
    - --format=jsonl
    - --env
    - Bin=/velociraptor
    - --env
    - ApiConfig=/api/api.yaml
    - --env
    - {{ printf "Orgs=%s" (toJson .Values.orgs.items) | quote }}
    - --env
    - {{ printf "ApiClients=%s" (include "velociraptor.apiClientsGrants" .) | quote }}
    - --env
    - Admin={{ if .Values.gui.initialAdmin.enabled }}{{ .Values.gui.initialAdmin.username }}{{ end }}
    - --env
    - {{ printf "State=%s" (include "velociraptor.stateJson" .) | quote }}
    - --env
    - Period={{ .Values.orgs.reconcilePeriodSeconds | default .Values.state.reconcilePeriodSeconds }}
    - --env
    - {{ printf "ManagedOrgs=%s" (include "velociraptor.managedOrgs" .) | quote }}
    - --env
    - ApiUser=velociraptor-helm
    - --env
    - LedgerFile={{ .Values.persistence.mountPath }}/helm-api-clients.json
    - --env
    - {{ printf "ExportOrgs=%s" (include "velociraptor.exportOrgs" .) | quote }}
    - --env
    - ExportPrefix={{ include "velociraptor.exportPrefix" . }}
    - --env
    - ExportKey={{ .Values.clientConfig.export.key }}
    - --env
    - Packages={{ .Values.clientConfig.packages.enabled }}
    - --env
    - Release={{ .Release.Name }}
    - --env
    - KubeAPI=https://kubernetes.default.svc
    - --env
    - SADir=/var/run/secrets/kubernetes.io/serviceaccount
    - {{ .Files.Get "files/state.vql" | toJson }}
  securityContext:
    {{- toYaml .Values.securityContext | nindent 4 }}
  resources:
    {{- toYaml (.Values.orgs.resources | default .Values.state.resources) | nindent 4 }}
  volumeMounts:
    - name: api-client
      mountPath: /api
      readOnly: true
    - name: reconciler-tmp
      mountPath: /tmp
    {{- if .Values.clientConfig.export.enabled }}
    # Kubernetes API token of this sidecar only (the pod does not automount one).
    - name: reconciler-token
      mountPath: /var/run/secrets/kubernetes.io/serviceaccount
      readOnly: true
    {{- end }}
{{- end }}
{{- end }}

{{/* Native sidecar uploading the identity + Velociraptor backups to S3 (chart/files/backup.vql). */}}
{{- define "velociraptor.backupSidecar" -}}
{{- $b := .Values.backup.s3 }}
{{- if $b.enabled }}
{{- if not (and $b.bucket $b.existingSecret) }}{{ fail "backup.s3.enabled needs backup.s3.bucket and backup.s3.existingSecret (keys accessKeyId, secretAccessKey)" }}{{ end }}
{{- if not (semverCompare ">=1.29.0-0" .Capabilities.KubeVersion.Version) }}
{{- fail "backup.s3 needs Kubernetes >= 1.29 (native sidecar containers)." }}
{{- end }}
- name: backup-uploader
  image: {{ include "velociraptor.image" . }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  restartPolicy: Always
  args:
    - -v
    - --nobanner
    - query
    - --format=jsonl
    - --env
    - Bucket={{ $b.bucket }}
    - --env
    - Region={{ $b.region }}
    - --env
    - Endpoint={{ $b.endpoint }}
    - --env
    - PathStyle={{ $b.pathStyle }}
    - --env
    - SkipVerify={{ $b.skipVerify }}
    - --env
    - Prefix={{ $b.prefix }}
    - --env
    - Sse={{ $b.serverSideEncryption }}
    - --env
    - KmsKey={{ $b.kmsKeyId }}
    - --env
    - IntervalSeconds={{ $b.intervalSeconds }}
    - --env
    - IdentityFile={{ if $b.includeIdentity }}/identity/{{ .Values.config.secretKey }}{{ end }}
    - --env
    - Release={{ .Release.Name }}
    - --env
    - BackupsGlob={{ .Values.persistence.mountPath }}/backups/*.zip
    - --env
    - CredsDir=/s3
    - {{ .Files.Get "files/backup.vql" | toJson }}
  securityContext:
    {{- toYaml .Values.securityContext | nindent 4 }}
  resources:
    {{- toYaml $b.resources | nindent 4 }}
  volumeMounts:
    - name: datastore
      mountPath: {{ .Values.persistence.mountPath }}
      readOnly: true
    {{- if $b.includeIdentity }}
    - name: backup-identity
      mountPath: /identity
      readOnly: true
    {{- end }}
    - name: backup-s3
      mountPath: /s3
      readOnly: true
    - name: backup-tmp
      mountPath: /tmp
{{- end }}
{{- end }}

{{/* Init container ensuring the initial admin exists with the Secret's password. */}}
{{- define "velociraptor.adminInitContainer" -}}
{{- if .Values.gui.initialAdmin.enabled }}
- name: ensure-admin
  image: {{ include "velociraptor.image" . }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  args:
    - --config
    - {{ .Values.config.mountPath }}
    - --nobanner
    - user
    - add
    - --role
    - administrator
    - {{ required "gui.initialAdmin.username is required" .Values.gui.initialAdmin.username | quote }}
    - $(ADMIN_PASSWORD)
  env:
    - name: ADMIN_PASSWORD
      valueFrom:
        secretKeyRef:
          name: {{ include "velociraptor.adminSecretName" . }}
          key: {{ .Values.gui.initialAdmin.passwordKey }}
  securityContext:
    {{- toYaml .Values.securityContext | nindent 4 }}
  volumeMounts:
    {{- include "velociraptor.configVolumeMount" . | nindent 4 }}
    {{- include "velociraptor.customArtifactsVolumeMount" . | nindent 4 }}
    - name: datastore
      mountPath: {{ .Values.persistence.mountPath }}
    {{- if .Values.tmpDir.enabled }}
    - name: tmp
      mountPath: /tmp
    {{- end }}
{{- end }}
{{- end }}

{{/* "true" when the chart owns the operational config. Forced in bootstrap mode: a raw
     `config generate` binds the GUI to 127.0.0.1, stores data under /var/tmp (off the PVC,
     read-only rootfs) and points agents at localhost - unusable without the overlay. */}}
{{- define "velociraptor.manageServerConfig" -}}
{{- if or .Values.config.manageServerConfig (eq (include "velociraptor.configSource" .) "bootstrap") -}}true{{- end -}}
{{- end }}

{{/* "true" when a config overlay (init-container merge) is needed. */}}
{{- define "velociraptor.overlayEnabled" -}}
{{- if or .Values.gui.oidc.enabled .Values.config.initializeServer .Values.customArtifacts.enabled (eq (include "velociraptor.manageServerConfig" .) "true") -}}true{{- end -}}
{{- end }}

{{/* Client.server_urls as a JSON array, first match wins:
     config.server.clientServerUrls > frontend ingress host (443, SSL passthrough) >
     LoadBalancer IP > in-cluster Service DNS (only reachable from inside the cluster). */}}
{{- define "velociraptor.clientServerUrls" -}}
{{- $fe := .Values.frontend -}}
{{- if .Values.config.server.clientServerUrls -}}
{{- toJson .Values.config.server.clientServerUrls -}}
{{- else if and $fe.ingress.enabled $fe.ingress.host -}}
{{- list (printf "https://%s/" $fe.ingress.host) | toJson -}}
{{- else if and (eq $fe.service.type "LoadBalancer") $fe.service.loadBalancerIP -}}
{{- list (printf "https://%s:%v/" $fe.service.loadBalancerIP $fe.service.port) | toJson -}}
{{- else -}}
{{- list (printf "https://%s-frontend.%s.svc:%v/" (include "velociraptor.fullname" .) .Release.Namespace $fe.service.port) | toJson -}}
{{- end -}}
{{- end }}

{{/*
Operational config overlay (YAML), deep-merged onto the base config (secrets) by the
config-merge init container. Built as an accumulated dict so each top-level key appears
once across all enabled features (oidc / initializeServer / customArtifacts / manageServerConfig).
- manageServerConfig=false: legacy targeted overlay (oidc + init + artifacts only).
- manageServerConfig=true:  chart owns the operational config - ports, bind addresses,
  hostnames, URLs, datastore, logging, monitoring, authenticator type - derived from chart
  values; secrets stay in the base. config.server.extraConfig is deep-merged last (wins).
*/}}
{{- define "velociraptor.configOverlay" -}}
{{- $o := dict -}}
{{- $manage := eq (include "velociraptor.manageServerConfig" .) "true" -}}
{{- $oidc := .Values.gui.oidc.enabled -}}
{{- $srv := .Values.config.server -}}
{{/*
LAYER 1 (lowest precedence) - raw per-section passthrough maps, keyed with the upstream
config field names. Lets any operational field be set verbatim; chart-derived fields
(layer 2) and extraConfig (layer 3) override these.
*/}}
{{- if $manage -}}
  {{- $rawSections := dict "client" "Client" "api" "API" "gui" "GUI" "frontend" "Frontend" "datastore" "Datastore" "monitoring" "Monitoring" "defaults" "defaults" "security" "security" "minion" "Minion" -}}
  {{- range $vk, $ck := $rawSections -}}
    {{- with index $srv $vk }}{{- $o = mergeOverwrite $o (dict $ck (deepCopy .)) -}}{{- end -}}
  {{- end -}}
  {{/* Top-level scalars */}}
  {{- with $srv.serverType }}{{- $_ := set $o "server_type" . -}}{{- end -}}
  {{- with $srv.autocertDomain }}{{- $_ := set $o "autocert_domain" . -}}{{- end -}}
  {{- with $srv.autocertCertCache }}{{- $_ := set $o "autocert_cert_cache" . -}}{{- end -}}
  {{- if kindIs "bool" $srv.lockdown }}{{- $_ := set $o "lockdown" $srv.lockdown -}}{{- end -}}
  {{- if kindIs "bool" $srv.debugMode }}{{- $_ := set $o "debug_mode" $srv.debugMode -}}{{- end -}}
{{- end -}}
{{/*
LAYER 2 - chart-derived operational fields. Built into $f then deep-merged so they win
over the raw maps. GUI authenticator / Frontend artifacts apply in legacy mode too.
*/}}
{{- $f := dict -}}
{{/* GUI */}}
{{- if or $oidc $manage -}}
  {{- $gui := dict -}}
  {{- if $manage -}}
    {{- $_ := set $gui "bind_address" "0.0.0.0" -}}
    {{- $_ := set $gui "bind_port" (.Values.gui.containerPort | int) -}}
    {{- with .Values.gui.basePath }}{{- $_ := set $gui "base_path" . -}}{{- end -}}
  {{- end -}}
  {{- if $oidc -}}
    {{- $_ := set $gui "public_url" (required "gui.publicUrl is required when gui.oidc.enabled (OIDC redirects)" .Values.gui.publicUrl) -}}
  {{- else -}}
    {{- with .Values.gui.publicUrl }}{{- $_ := set $gui "public_url" . -}}{{- end -}}
  {{- end -}}
  {{- $auth := dict "type" (ternary "oidc" "Basic" $oidc) -}}
  {{- if $oidc -}}
    {{- $_ := set $auth "oidc_issuer" (required "gui.oidc.issuer is required when gui.oidc.enabled" .Values.gui.oidc.issuer) -}}
    {{- $_ := set $auth "oidc_name" .Values.gui.oidc.name -}}
    {{- $_ := set $auth "oauth_client_id" .Values.gui.oidc.clientId -}}
    {{- with .Values.gui.oidc.avatar }}{{- $_ := set $auth "avatar" . -}}{{- end -}}
  {{- end -}}
  {{- $_ := set $gui "authenticator" $auth -}}
  {{- $_ := set $f "GUI" $gui -}}
{{- end -}}
{{/* Frontend */}}
{{- if or .Values.config.initializeServer $manage -}}
  {{- $fe := dict -}}
  {{- if $manage -}}
    {{- $_ := set $fe "bind_address" "0.0.0.0" -}}
    {{- $_ := set $fe "bind_port" (.Values.frontend.containerPort | int) -}}
    {{- with .Values.frontend.ingress.host }}{{- $_ := set $fe "hostname" . -}}{{- end -}}
  {{- end -}}
  {{- if .Values.config.initializeServer -}}
    {{- $_ := set $fe "initial_server_artifacts" (list "Container.InitializeServer") -}}
  {{- end -}}
  {{- $_ := set $f "Frontend" $fe -}}
{{- end -}}
{{- if $manage -}}
  {{/* API */}}
  {{- $served := eq (include "velociraptor.apiServed" .) "true" -}}
  {{- $api := dict "bind_address" (ternary "0.0.0.0" "127.0.0.1" $served) "bind_port" (.Values.frontend.apiPort | int) -}}
  {{- if $served -}}
    {{- $_ := set $api "hostname" (printf "%s-api.%s.svc" (include "velociraptor.fullname" .) .Release.Namespace) -}}
    {{- $_ := set $api "pinned_gw_name" "GRPC_GW" -}}
  {{- end -}}
  {{- $_ := set $f "API" $api -}}
  {{/* Client.server_urls - the address agents dial (see velociraptor.clientServerUrls) */}}
  {{- $_ := set $f "Client" (dict "server_urls" (include "velociraptor.clientServerUrls" . | fromJsonArray)) -}}
  {{/* Datastore */}}
  {{- $_ := set $f "Datastore" (dict "implementation" $srv.datastoreImplementation "location" .Values.persistence.mountPath "filestore_directory" .Values.persistence.mountPath) -}}
  {{/* Monitoring - 0.0.0.0 so Prometheus can scrape when serviceMonitor is on */}}
  {{- $_ := set $f "Monitoring" (dict "bind_address" (ternary "0.0.0.0" "127.0.0.1" .Values.serviceMonitor.enabled) "bind_port" (.Values.monitoring.containerPort | int)) -}}
  {{/* Logging */}}
  {{- $log := dict "separate_logs_per_component" $srv.logging.separateLogsPerComponent "rotation_time" ($srv.logging.rotationTime | int) "max_age" ($srv.logging.maxAge | int) -}}
  {{- with $srv.logging.outputDirectory }}{{- $_ := set $log "output_directory" . -}}{{- end -}}
  {{- with $srv.logging.remoteSyslogServer }}{{- $_ := set $log "remote_syslog_server" . -}}{{- end -}}
  {{- with $srv.logging.remoteSyslogProtocol }}{{- $_ := set $log "remote_syslog_protocol" . -}}{{- end -}}
  {{- with $srv.logging.remoteSyslogComponents }}{{- $_ := set $log "remote_syslog_components" . -}}{{- end -}}
  {{- $_ := set $f "Logging" $log -}}
{{- end -}}
{{/* defaults - artifact search dirs: chart-shipped (initializeServer) + custom (both modes) */}}
{{- $dirs := list -}}
{{- if .Values.config.initializeServer }}{{ $dirs = append $dirs "/chart-artifacts" }}{{ end -}}
{{- if .Values.customArtifacts.enabled }}{{ $dirs = append $dirs .Values.customArtifacts.path }}{{ end -}}
{{- with $dirs -}}
  {{- $_ := set $f "defaults" (dict "artifact_definitions_directories" .) -}}
{{- end -}}
{{- $o = mergeOverwrite $o $f -}}
{{/* LAYER 3 (highest) - raw escape hatch, overrides everything above */}}
{{- if $manage -}}
  {{- with $srv.extraConfig }}{{- $o = mergeOverwrite $o (deepCopy .) -}}{{- end -}}
{{- end -}}
{{- toYaml $o -}}
{{- end }}

{{/* Secret + key holding the OIDC client secret. */}}
{{- define "velociraptor.oidcSecretName" -}}
{{- if .Values.gui.oidc.existingSecret -}}
{{- .Values.gui.oidc.existingSecret -}}
{{- else -}}
{{- printf "%s-oidc" (include "velociraptor.fullname" .) -}}
{{- end -}}
{{- end }}
{{- define "velociraptor.oidcSecretKey" -}}
{{- if .Values.gui.oidc.existingSecret -}}
{{- .Values.gui.oidc.existingSecretKey -}}
{{- else -}}
oauth_client_secret
{{- end -}}
{{- end }}

{{/* Init container that deep-merges the chart overlay onto the base config.
     Called with (dict "ctx" $ "master" bool). On the master, API.hostname is pinned to the
     loopback: the GUI's gRPC gateway (and in-pod API clients) dial API.hostname, and going
     through the pod's own API Service hairpins, which some CNIs masquerade and the
     NetworkPolicy then drops. Minions keep the Service hostname to reach the master. */}}
{{- define "velociraptor.overlayInitContainer" -}}
{{- $master := .master }}
{{- with .ctx }}
{{- if eq (include "velociraptor.overlayEnabled" .) "true" }}
- name: config-merge
  image: {{ .Values.config.overlay.image.repository }}:{{ .Values.config.overlay.image.tag }}{{ with .Values.config.overlay.image.digest }}@{{ . }}{{ end }}
  imagePullPolicy: {{ .Values.config.overlay.image.pullPolicy }}
  command: ["sh", "-c"]
  args:
    - |
      set -eu
      yq eval-all 'select(fi==0) * select(fi==1)' \
        /base/{{ .Values.config.secretKey }} /overlay/overlay.yaml \
        {{- if .Values.gui.oidc.enabled }}
        | CLIENT_SECRET="$CLIENT_SECRET" yq '.GUI.authenticator.oauth_client_secret = strenv(CLIENT_SECRET)' \
        {{- end }}
        {{- if and $master (eq (include "velociraptor.apiServed" .) "true") (eq (include "velociraptor.manageServerConfig" .) "true") }}
        | yq '.API.hostname = "127.0.0.1"' \
        {{- end }}
        > /merged/{{ base .Values.config.mountPath }}
  {{- if .Values.gui.oidc.enabled }}
  env:
    - name: CLIENT_SECRET
      valueFrom:
        secretKeyRef:
          name: {{ include "velociraptor.oidcSecretName" . }}
          key: {{ include "velociraptor.oidcSecretKey" . }}
  {{- end }}
  securityContext:
    {{- toYaml .Values.securityContext | nindent 4 }}
  volumeMounts:
    - name: config-base
      mountPath: /base
      readOnly: true
    - name: config-overlay
      mountPath: /overlay
      readOnly: true
    - name: config
      mountPath: /merged
{{- end }}
{{- end }}
{{- end }}

{{/* Custom-artifacts volume mount (main container, read-only). */}}
{{- define "velociraptor.customArtifactsVolumeMount" -}}
{{- if .Values.customArtifacts.enabled }}
- name: custom-artifacts
  mountPath: {{ .Values.customArtifacts.path | quote }}
  readOnly: true
{{- end }}
{{- if .Values.config.initializeServer }}
- name: builtin-artifacts
  mountPath: /chart-artifacts
  readOnly: true
{{- end }}
{{- end }}

{{/* Custom-artifacts volumes (ConfigMap-backed). */}}
{{- define "velociraptor.customArtifactsVolume" -}}
{{- if .Values.customArtifacts.enabled }}
{{- $ca := .Values.customArtifacts }}
# Projected: every listed ConfigMap lands in the same directory (file names must be unique).
- name: custom-artifacts
  projected:
    sources:
      {{- if or $ca.files (and (not $ca.existingConfigMap) (not $ca.existingConfigMaps)) }}
      - configMap:
          name: {{ printf "%s-custom-artifacts" (include "velociraptor.fullname" .) }}
      {{- end }}
      {{- with $ca.existingConfigMap }}
      - configMap:
          name: {{ . }}
      {{- end }}
      {{- range $ca.existingConfigMaps }}
      - configMap:
          name: {{ tpl . $ }}
      {{- end }}
{{- end }}
{{- if .Values.config.initializeServer }}
- name: builtin-artifacts
  configMap:
    name: {{ include "velociraptor.fullname" . }}-builtin-artifacts
{{- end }}
{{- end }}

{{/* Config-related volumes (overlay-aware). */}}
{{- define "velociraptor.configVolumes" -}}
{{- if eq (include "velociraptor.overlayEnabled" .) "true" }}
- name: config-base
  secret:
    secretName: {{ include "velociraptor.configSecretName" . }}
- name: config-overlay
  secret:
    secretName: {{ include "velociraptor.fullname" . }}-config-overlay
- name: config
  emptyDir: {}
{{- else }}
- name: config
  secret:
    secretName: {{ include "velociraptor.configSecretName" . }}
{{- end }}
{{- end }}

{{/* Config volume mount on the main container (overlay-aware). */}}
{{- define "velociraptor.configVolumeMount" -}}
{{- if eq (include "velociraptor.overlayEnabled" .) "true" }}
- name: config
  mountPath: {{ dir .Values.config.mountPath }}
{{- else }}
- name: config
  mountPath: {{ .Values.config.mountPath }}
  subPath: {{ .Values.config.secretKey }}
  readOnly: true
{{- end }}
{{- end }}
