{{/*
Expand the name of the chart.
*/}}
{{- define "grdb.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name. Truncated to 63 chars because
some Kubernetes name fields are limited to that (by the DNS naming spec).
*/}}
{{- define "grdb.fullname" -}}
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
{{- define "grdb.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "grdb.labels" -}}
helm.sh/chart: {{ include "grdb.chart" . }}
{{ include "grdb.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "grdb.selectorLabels" -}}
app.kubernetes.io/name: {{ include "grdb.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Name of the ServiceAccount the platform runs as — its only Kubernetes
identity (no cluster-admin, no host access; see templates/rbac.yaml).
*/}}
{{- define "grdb.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "grdb.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Name of the Secret the container's envFrom.secretRef points at.
existingSecret wins over the templated one so a customer can bring their
own (sealed-secrets, External Secrets Operator, a plain manual Secret).
*/}}
{{- define "grdb.secretName" -}}
{{- if .Values.existingSecret }}
{{- .Values.existingSecret }}
{{- else }}
{{- printf "%s-secret" (include "grdb.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Name of the non-secret ConfigMap the container's envFrom.configMapRef
points at.
*/}}
{{- define "grdb.configMapName" -}}
{{- printf "%s-config" (include "grdb.fullname" .) }}
{{- end }}

{{/*
Image reference: image.tag falls back to Chart.AppVersion, exactly the
`helm create` scaffold convention, so a fresh install with no
--set image.tag still resolves to a real, versioned image.
*/}}
{{- define "grdb.image" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- printf "%s:%s" .Values.image.repository $tag }}
{{- end }}
