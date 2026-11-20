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
{{- if or (eq (include "velociraptor.configSource" .) "bootstrap") (and .Values.gui.initialAdmin.enabled (not .Values.gui.initialAdmin.existingSecret)) -}}true{{- end -}}
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

{{/* "true" when a config overlay (init-container merge) is needed. */}}
{{- define "velociraptor.overlayEnabled" -}}
{{- if or .Values.gui.oidc.enabled .Values.config.initializeServer .Values.customArtifacts.enabled -}}true{{- end -}}
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

{{/* Init container that deep-merges the chart overlay onto the base config. */}}
{{- define "velociraptor.overlayInitContainer" -}}
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

{{/* Custom-artifacts volume mount (main container, read-only). */}}
{{- define "velociraptor.customArtifactsVolumeMount" -}}
{{- if .Values.customArtifacts.enabled }}
- name: custom-artifacts
  mountPath: {{ .Values.customArtifacts.path | quote }}
  readOnly: true
{{- end }}
{{- end }}

{{/* Custom-artifacts volume (ConfigMap-backed). */}}
{{- define "velociraptor.customArtifactsVolume" -}}
{{- if .Values.customArtifacts.enabled }}
- name: custom-artifacts
  configMap:
    name: {{ .Values.customArtifacts.existingConfigMap | default (printf "%s-custom-artifacts" (include "velociraptor.fullname" .)) }}
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
