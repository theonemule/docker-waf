{{- define "lightedge.name" -}}
{{- printf "%s-lightedge" .Release.Name | trunc 50 | trimSuffix "-" -}}
{{- end -}}
{{- define "lightedge.appliance" -}}
{{- printf "%s-appliance" (include "lightedge.name" .) -}}
{{- end -}}
{{- define "lightedge.providerURL" -}}
{{- if .Values.provider.url -}}
{{- .Values.provider.url -}}
{{- else if .Values.appliance.enabled -}}
{{- printf "https://%s.%s.svc:9443" (include "lightedge.appliance" .) .Release.Namespace -}}
{{- else -}}
{{- fail "provider.url is required for an external appliance" -}}
{{- end -}}
{{- end -}}
