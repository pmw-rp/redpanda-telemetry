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

{{/*
Parses a Kubernetes memory quantity using a Mi or Gi suffix (the only two
this chart's alloy.resources.limits.memory is ever realistically set with)
into a plain byte count — Sprig has no built-in Kubernetes quantity parser.
*/}}
{{- define "redpanda-o11y.memoryBytes" -}}
{{- $qty := . | toString -}}
{{- if hasSuffix "Gi" $qty }}
{{- mulf (trimSuffix "Gi" $qty | float64) 1073741824 | printf "%.0f" }}
{{- else if hasSuffix "Mi" $qty }}
{{- mulf (trimSuffix "Mi" $qty | float64) 1048576 | printf "%.0f" }}
{{- else }}
{{- fail (printf "unsupported memory quantity %q for GOMEMLIMIT — expected a Mi or Gi suffix" $qty) }}
{{- end }}
{{- end }}

{{/*
Computes a GOMEMLIMIT value (raw bytes — Go's runtime accepts a plain byte
count, no suffix needed) as 90% of a Kubernetes memory quantity string.
Deliberately below the real limit, not equal to it: GOMEMLIMIT only paces
the Go heap, and the container's actual RSS also includes goroutine
stacks, mmap'd files, and other non-heap memory, so pacing right up to the
hard container limit would leave no margin for any of that.
*/}}
{{- define "redpanda-o11y.gomemlimitBytes" -}}
{{- $bytes := include "redpanda-o11y.memoryBytes" . | float64 -}}
{{- mulf $bytes 0.9 | printf "%.0f" -}}
{{- end }}

