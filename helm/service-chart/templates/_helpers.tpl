{{/*
Nome completo do recurso, derivado do role e target.
  staging (ou vazio)      → <name>
  candidate               → <name>-candidate
  dependency + target     → <name>-<target>-dependency
  client + target         → <name>-<target>-client
Truncado a 63 caracteres (limite do Kubernetes).
*/}}
{{- define "service-chart.fullname" -}}
{{- $name := .Values.name -}}
{{- $role := .Values.role | default "staging" -}}
{{- $target := .Values.target | default "" -}}
{{- if eq $role "candidate" -}}
{{- printf "%s-candidate" $name | trunc 63 | trimSuffix "-" }}
{{- else if eq $role "dependency" -}}
{{- printf "%s-%s-dependency" $name $target | trunc 63 | trimSuffix "-" }}
{{- else if eq $role "client" -}}
{{- printf "%s-%s-client" $name $target | trunc 63 | trimSuffix "-" }}
{{- else -}}
{{- printf "%s" $name | trunc 63 | trimSuffix "-" }}
{{- end -}}
{{- end }}

{{/*
Labels padrão aplicados em todos os recursos.
*/}}
{{- define "service-chart.labels" -}}
app: {{ include "service-chart.fullname" . }}
app.kubernetes.io/name: {{ .Values.name }}
app.kubernetes.io/instance: {{ include "service-chart.fullname" . }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.extraLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels — usados no matchLabels do Deployment e no selector do Service.
O label 'app' usa o fullname (com role/target) — é o que o VirtualService
referencia via sourceLabels para rotear o tráfego dos clients.
*/}}
{{- define "service-chart.selectorLabels" -}}
app: {{ include "service-chart.fullname" . }}
app.kubernetes.io/name: {{ .Values.name }}
app.kubernetes.io/instance: {{ include "service-chart.fullname" . }}
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
