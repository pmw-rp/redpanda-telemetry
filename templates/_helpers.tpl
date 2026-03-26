{{/*
Expand the name of the chart.
*/}}
{{- define "redpanda-o11y.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "redpanda-o11y.fullname" -}}
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
*/}}
{{- define "redpanda-o11y.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "redpanda-o11y.labels" -}}
helm.sh/chart: {{ include "redpanda-o11y.chart" . }}
{{ include "redpanda-o11y.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "redpanda-o11y.selectorLabels" -}}
app.kubernetes.io/name: {{ include "redpanda-o11y.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Kafka broker address
*/}}
{{- define "redpanda-o11y.kafkaBroker" -}}
{{- .Values.redpanda.bootstrapServer }}
{{- end }}

{{/*
Kafka username - determines the username to use for authentication
Priority:
1. credentials.secretName - lookup username from secret
2. credentials.username - use explicit username
*/}}
{{- define "redpanda-o11y.kafkaUsername" -}}
{{- if .Values.credentials }}
  {{- if .Values.credentials.secretName }}
    {{- $secret := lookup "v1" "Secret" .Values.alloy.namespace .Values.credentials.secretName }}
    {{- if $secret }}
      {{- index $secret.data "username" | b64dec }}
    {{- else }}
      {{- fail (printf "Secret %s not found in namespace %s" .Values.credentials.secretName .Values.alloy.namespace) }}
    {{- end }}
  {{- else if .Values.credentials.username }}
    {{- .Values.credentials.username }}
  {{- else }}
    {{- fail "credentials.secretName or credentials.username is required" }}
  {{- end }}
{{- else }}
  {{- fail "credentials section is required" }}
{{- end }}
{{- end }}

{{/*
Kafka password - determines the password to use for authentication
Priority:
1. credentials.secretName - lookup password from secret
2. credentials.password - use explicit password
*/}}
{{- define "redpanda-o11y.kafkaPassword" -}}
{{- if .Values.credentials }}
  {{- if .Values.credentials.secretName }}
    {{- $secret := lookup "v1" "Secret" .Values.alloy.namespace .Values.credentials.secretName }}
    {{- if $secret }}
      {{- index $secret.data "password" | b64dec }}
    {{- else }}
      {{- fail (printf "Secret %s not found in namespace %s" .Values.credentials.secretName .Values.alloy.namespace) }}
    {{- end }}
  {{- else if .Values.credentials.password }}
    {{- .Values.credentials.password }}
  {{- else }}
    {{- fail "credentials.secretName or credentials.password is required" }}
  {{- end }}
{{- else }}
  {{- fail "credentials section is required" }}
{{- end }}
{{- end }}

{{/*
Gateway username - determines the username for gateway authentication
Priority:
1. gateway.credentials.secretName - lookup username from gateway secret
2. gateway.credentials.username - use explicit gateway username
3. Fall back to kafkaUsername (reuse Kafka credentials)
*/}}
{{- define "redpanda-o11y.gatewayUsername" -}}
{{- if .Values.gateway }}
  {{- if .Values.gateway.credentials }}
    {{- if .Values.gateway.credentials.secretName }}
      {{- $secret := lookup "v1" "Secret" .Values.alloy.namespace .Values.gateway.credentials.secretName }}
      {{- if $secret }}
        {{- index $secret.data "username" | b64dec }}
      {{- else }}
        {{- fail (printf "Gateway secret %s not found in namespace %s" .Values.gateway.credentials.secretName .Values.alloy.namespace) }}
      {{- end }}
    {{- else if .Values.gateway.credentials.username }}
      {{- .Values.gateway.credentials.username }}
    {{- else }}
      {{- include "redpanda-o11y.kafkaUsername" . }}
    {{- end }}
  {{- else }}
    {{- include "redpanda-o11y.kafkaUsername" . }}
  {{- end }}
{{- else }}
  {{- include "redpanda-o11y.kafkaUsername" . }}
{{- end }}
{{- end }}

{{/*
Gateway password - determines the password for gateway authentication
Priority:
1. gateway.credentials.secretName - lookup password from gateway secret
2. gateway.credentials.password - use explicit gateway password
3. Fall back to kafkaPassword (reuse Kafka credentials)
*/}}
{{- define "redpanda-o11y.gatewayPassword" -}}
{{- if .Values.gateway }}
  {{- if .Values.gateway.credentials }}
    {{- if .Values.gateway.credentials.secretName }}
      {{- $secret := lookup "v1" "Secret" .Values.alloy.namespace .Values.gateway.credentials.secretName }}
      {{- if $secret }}
        {{- index $secret.data "password" | b64dec }}
      {{- else }}
        {{- fail (printf "Gateway secret %s not found in namespace %s" .Values.gateway.credentials.secretName .Values.alloy.namespace) }}
      {{- end }}
    {{- else if .Values.gateway.credentials.password }}
      {{- .Values.gateway.credentials.password }}
    {{- else }}
      {{- include "redpanda-o11y.kafkaPassword" . }}
    {{- end }}
  {{- else }}
    {{- include "redpanda-o11y.kafkaPassword" . }}
  {{- end }}
{{- else }}
  {{- include "redpanda-o11y.kafkaPassword" . }}
{{- end }}
{{- end }}
