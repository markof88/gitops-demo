{{/*
Expand the name of the chart
*/}}
{{- define "caralegal-service.name" -}}
{{- .Release.Name }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "caralegal-service.labels" -}}
app: {{ include "caralegal-service.name" . }}
app.kubernetes.io/name: {{ include "caralegal-service.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "caralegal-service.selectorLabels" -}}
app: {{ include "caralegal-service.name" . }}
{{- end }}