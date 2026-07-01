{{- define "engress-core.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "engress-core.fullname" -}}
{{- printf "%s" (include "engress-core.name" .) }}
{{- end }}

{{- define "engress-core.labels" -}}
app.kubernetes.io/name: {{ include "engress-core.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
