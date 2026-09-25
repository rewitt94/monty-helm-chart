{{/* Leave space for component and Secret suffixes within DNS label limits. */}}
{{- define "monty.fullname" -}}
{{- .Release.Name | trunc 54 | trimSuffix "-" -}}
{{- end -}}

{{/* Only stable identity labels belong in Deployment and Service selectors. */}}
{{- define "monty.selectorLabels" -}}
app.kubernetes.io/name: monty
app.kubernetes.io/instance: {{ .Release.Name | quote }}
{{- end -}}

{{- define "monty.labels" -}}
{{ include "monty.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | quote }}
{{- end -}}

{{- define "monty.imageTag" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion | toString -}}
{{- if not $tag -}}
{{- fail "set Chart.appVersion before releasing the chart, or override image.tag" -}}
{{- end -}}
{{- if or (eq $tag "latest") (not (regexMatch "^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$" $tag)) -}}
{{- fail "the effective image tag (image.tag or Chart.appVersion) must be a valid tag other than latest" -}}
{{- end -}}
{{- $tag -}}
{{- end -}}

{{- define "monty.gatewayName" -}}
{{- .Values.gateway.name | default (printf "%s-gateway" (include "monty.fullname" .)) -}}
{{- end -}}

{{- define "monty.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- .Values.serviceAccount.name | default (printf "%s-server" (include "monty.fullname" .)) -}}
{{- else -}}
{{- .Values.serviceAccount.name | default "default" -}}
{{- end -}}
{{- end -}}

{{- define "monty.objectStoreUri" -}}
{{- tpl (.Values.objectStore.uri | default "") . -}}
{{- end -}}

{{- define "monty.objectStoreEnv" -}}
{{- with include "monty.objectStoreUri" . }}
- name: MONTY_SERVER_OBJECT_STORE_URI
  value: {{ . | quote }}
{{- end }}
{{- range $name, $value := .Values.objectStore.env }}
- name: {{ $name }}
  {{- if kindIs "map" $value }}
  {{- toYaml $value | nindent 2 }}
  {{- else }}
  value: {{ tpl $value $ | quote }}
  {{- end }}
{{- end }}
{{- end -}}
