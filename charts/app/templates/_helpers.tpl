{{/* Chart/release name helpers */}}
{{- define "app.name" -}}
{{- default .Release.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "app.fullname" -}}
{{- include "app.name" . -}}
{{- end -}}

{{- define "app.secretName" -}}
{{- default (printf "%s-secrets" (include "app.fullname" .)) .Values.existingSecret -}}
{{- end -}}

{{/* ServiceAccount the pods run as: a dedicated one when tenantManager is on
     (it carries the cluster RBAC to provision tenant namespaces), else default. */}}
{{- define "app.serviceAccountName" -}}
{{- if .Values.tenantManager.enabled -}}
{{- include "app.fullname" . -}}
{{- else -}}
default
{{- end -}}
{{- end -}}

{{- define "app.labels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
platform.example.org/app: {{ include "app.name" . }}
{{- end -}}

{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Shared env block for app + worker: plain env from .Values.app.env, secret env
from .Values.app.secretEnv (each key pulled from the app Secret via secretKeyRef).
*/}}
{{- define "app.envBlock" -}}
{{- range $k, $v := .Values.app.env }}
- name: {{ $k }}
  value: {{ $v | quote }}
{{- end }}
{{- range .Values.app.secretEnv }}
- name: {{ . }}
  valueFrom:
    secretKeyRef:
      name: {{ include "app.secretName" $ }}
      key: {{ . }}
{{- end }}
{{- end -}}
