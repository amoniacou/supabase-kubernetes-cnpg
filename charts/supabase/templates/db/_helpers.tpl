{{/*
Expand the name of the chart.
Used by vector/config.yaml for log routing.
*/}}
{{- define "supabase.db.name" -}}
{{- print .Chart.Name "-db" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
CloudNativePG read-write service name (primary).
*/}}
{{- define "supabase.db.fullname" -}}
{{- printf "%s-rw" .Values.cnpg.clusterName -}}
{{- end }}

{{/*
CloudNativePG read-only service name (for read-heavy services).
*/}}
{{- define "supabase.db.ro.fullname" -}}
{{- printf "%s-ro" .Values.cnpg.clusterName -}}
{{- end }}

{{/*
Init DB ConfigMap name — used by CNPG bootstrap init job.
*/}}
{{- define "supabase.db.initdb.fullname" -}}
{{- $name := print .Chart.Name "-db" -}}
{{- if contains $name .Release.Name -}}
{{- printf "%s-initdb" .Release.Name -}}
{{- else -}}
{{- printf "%s-%s-initdb" .Release.Name $name -}}
{{- end -}}
{{- end }}
