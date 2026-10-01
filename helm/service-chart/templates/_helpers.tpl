{{/*
Nome completo do release, truncado a 63 caracteres.
*/}}
{{- define "service-chart.fullname" -}}
{{- printf "%s" .Values.name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Labels padrão aplicados em todos os recursos.
*/}}
{{- define "service-chart.labels" -}}
app.kubernetes.io/name: {{ .Values.name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.extraLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels — usados no matchLabels do Deployment e no selector do Service.
*/}}
{{- define "service-chart.selectorLabels" -}}
app.kubernetes.io/name: {{ .Values.name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Referência da imagem: usa digest quando definido, tag caso contrário.
*/}}
{{- define "service-chart.image" -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- else -}}
{{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- end }}
{{- end }}
