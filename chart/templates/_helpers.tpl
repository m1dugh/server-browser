{{/*
Expand the name of the chart.
*/}}
{{- define "server-browser.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "server-browser.fullname" -}}
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
{{- define "server-browser.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "server-browser.labels" -}}
helm.sh/chart: {{ include "server-browser.chart" . }}
{{ include "server-browser.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "server-browser.selectorLabels" -}}
app.kubernetes.io/name: {{ include "server-browser.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Whether the nginx proxy container is rendered: it fronts both kasmvnc and the
CDP debugger, so it exists when either of them is enabled.
*/}}
{{- define "server-browser.nginxEnabled" -}}
{{- if or .Values.kasmvnc.enabled .Values.chromium.debug.enabled -}}true{{- end -}}
{{- end }}

{{/*
INTERNAL KasmVNC credential. KasmVNC has no passwordless mode, so the chart
uses one fixed credential that is set as VNC_PW on the kasmvnc container and
injected by nginx into every request it proxies -- users never authenticate
against KasmVNC and it is intentionally not configurable. KasmVNC itself only
listens on the pod's loopback, so only nginx can reach it.
*/}}
{{- define "server-browser.kasmvncUser" -}}kasm_user{{- end }}
{{- define "server-browser.kasmvncPassword" -}}server-browser-internal{{- end }}
