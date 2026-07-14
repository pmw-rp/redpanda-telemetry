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
Alloy resource name — combines alloy.name and alloy.namespace to ensure
cluster-scoped resources (ClusterRole, ClusterRoleBinding) are unique per install.
*/}}
{{- define "redpanda-o11y.alloyResourceName" -}}
{{- printf "%s-%s" .Values.alloy.name .Values.alloy.namespace }}
{{- end }}

{{/*
Kafka broker address
*/}}
{{- define "redpanda-o11y.kafkaBroker" -}}
{{- .Values.redpanda.bootstrapServer }}
{{- end }}

