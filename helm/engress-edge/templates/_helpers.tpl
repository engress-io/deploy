{{- define "engress-edge.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "engress-edge.fullname" -}}
{{- printf "%s" (include "engress-edge.name" .) }}
{{- end }}

{{- define "engress-edge.labels" -}}
app.kubernetes.io/name: {{ include "engress-edge.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
