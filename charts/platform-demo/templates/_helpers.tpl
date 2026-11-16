{{/*
Every template loops over .Values.components (backend, frontend, ...).
Resource names are the component key, so "backend" stays reachable at
http://backend:3000 as the frontend's nginx config expects.
*/}}

{{/* Selector labels: must never change after the first deploy (Deployment selectors are immutable). */}}
{{- define "platform-demo.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end }}

{{/* Common labels for every object. */}}
{{- define "platform-demo.labels" -}}
{{ include "platform-demo.selectorLabels" . }}
{{- with .c.component }}
app.kubernetes.io/component: {{ . }}
{{- end }}
app.kubernetes.io/part-of: platform-demo
app.kubernetes.io/version: {{ .c.image.tag | default .root.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version }}
environment: {{ .root.Values.global.environment }}
{{- end }}

{{/* Name of the Secret a component reads: an external one, or the one this chart renders. */}}
{{- define "platform-demo.secretName" -}}
{{- if .c.existingSecret -}}
{{ .c.existingSecret }}
{{- else -}}
{{ .name }}-secret
{{- end -}}
{{- end }}
