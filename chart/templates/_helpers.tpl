{{/*
Fullname helper
*/}}
{{- define "hyperpod-spaces-user-webhook.fullname" -}}
{{ .Release.Name }}-hyperpod-spaces-user-webhook
{{- end }}

{{/*
Common labels
*/}}
{{- define "hyperpod-spaces-user-webhook.labels" -}}
app: {{ include "hyperpod-spaces-user-webhook.fullname" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
