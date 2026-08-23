{{/*
Chart name, overridable.
*/}}
{{- define "agent.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified resource name. `helm install agent ./k8s/agent` yields plain
"agent" (the release name already contains the chart name), so the chart is a
drop-in replacement for the raw manifests in k8s/ — deploy/agent, svc/agent.
*/}}
{{- define "agent.fullname" -}}
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

{{- define "agent.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels. These are immutable once the Deployment exists — never add to
this block on an existing release without a delete/recreate.

`app` is carried alongside the standard app.kubernetes.io/* labels on purpose:
scripts/smoke-test.sh selects with `-l app=agent`, so the same checks work
against a Helm release and against the raw manifests in k8s/.
*/}}
{{- define "agent.selectorLabels" -}}
app: {{ include "agent.name" . }}
app.kubernetes.io/name: {{ include "agent.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "agent.labels" -}}
helm.sh/chart: {{ include "agent.chart" . }}
{{ include "agent.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/component: service
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "agent.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "agent.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Image reference. image.tag falls back to Chart.appVersion.
*/}}
{{- define "agent.image" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end }}

{{/*
Guard rail: a surge Pod cannot be placed when the spread constraint allows only
one Pod per node and every eligible node already holds one. Rendering fails here
with an explanation instead of the upgrade hanging in Pending with no clue why.
*/}}
{{- define "agent.validateStrategy" -}}
{{- if and .Values.topologySpread.enabled (eq .Values.topologySpread.whenUnsatisfiable "DoNotSchedule") }}
{{- if eq .Values.updateStrategy.type "RollingUpdate" }}
{{- $surge := toString (dig "rollingUpdate" "maxSurge" 0 .Values.updateStrategy) }}
{{- if and (ne $surge "0") (ne $surge "0%") }}
{{- fail (printf "agent chart: updateStrategy.rollingUpdate.maxSurge is %s, but topologySpread.whenUnsatisfiable is DoNotSchedule. The surge Pod would exceed maxSkew on every node and the rollout would deadlock in Pending. Set maxSurge to 0, or set topologySpread.whenUnsatisfiable to ScheduleAnyway." $surge) }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
