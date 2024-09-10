.DEFAULT_GOAL := help

CLUSTER_NAME := ambient
PROJECT_ID := $(shell gcloud config get-value project)
PROJECT_NUMBER := $(shell gcloud projects describe ${PROJECT_ID} --format="value(projectNumber)")
M_TYPE := n2-standard-2
ZONE := europe-west2-a
KUBECOST_TOKEN := $(shell cat KUBECOST_TOKEN)

cluster: ## Setup cluster
	gcloud services enable container.googleapis.com
	gcloud container clusters describe ${CLUSTER_NAME} || gcloud container clusters create ${CLUSTER_NAME} \
		--cluster-version latest \
		--spot \
		--machine-type=${M_TYPE} \
		--num-nodes 4 \
		--zone ${ZONE} \
		--project ${PROJECT_ID}
	gcloud container clusters get-credentials ${CLUSTER_NAME}
	kubectl apply -f priorityclass.yaml

istio: ## Install Istio with ambient profile
	helm repo add istio https://istio-release.storage.googleapis.com/charts
	helm repo update
	helm upgrade -i istio-base istio/base -n istio-system --create-namespace --set defaultRevision=default 
	helm upgrade -i istio-cni istio/cni -n istio-system --set profile=ambient
	helm upgrade -i istiod istio/istiod -n istio-system --set profile=ambient \
		--set meshConfig.defaultConfig.tracing.zipkin.address=jaeger-collector.jaeger:9411
	helm upgrade -i ztunnel istio/ztunnel -n istio-system
# helm upgrade -i istio-ingress istio/gateway -n istio-ingress --create-namespace

.PHONY: jaeger
jaeger:
	helm upgrade -i jaeger -n jaeger --create-namespace oci://registry-1.docker.io/bitnamicharts/jaeger

jaeger-pf:
	kubectl port-forward -n jaeger svc/jaeger-query 16686

.PHONY: prometheus
prometheus:
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo update
	helm upgrade -i --create-namespace -n prometheus prometheus-operator prometheus-community/kube-prometheus-stack \
		--set alertmanager.enabled=false \
		--set nodeExporter.enabled=false \
		--set grafana.enabled=true \
		-f prometheus/prometheus-additional.yaml

prom-pf:
	kubectl port-forward -n prometheus svc/prometheus-operator-kube-p-prometheus 9090

.PHONY: kiali
kiali:
	helm repo add kiali https://kiali.org/helm-charts
	helm install \
	    -n kiali-operator \
    	--create-namespace \
		kiali-operator \
		kiali/kiali-operator
	kubectl apply -f kiali.yaml

kiali-pf:
	kubectl port-forward svc/kiali 20001:20001 -n istio-system

kubecost:
	gcloud projects add-iam-policy-binding ${PROJECT_ID} --role=roles/bigquery.user \
		--member=principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/kubecost/sa/kubecost-cost-analyzer --condition=None
	gcloud projects add-iam-policy-binding ${PROJECT_ID} --role=roles/compute.viewer \
		--member=principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/kubecost/sa/kubecost-cost-analyzer --condition=None
	gcloud projects add-iam-policy-binding ${PROJECT_ID} --role=roles/bigquery.dataViewer \
		--member=principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/kubecost/sa/kubecost-cost-analyzer --condition=None
	gcloud projects add-iam-policy-binding ${PROJECT_ID} --role=roles/bigquery.jobUser \
		--member=principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/kubecost/sa/kubecost-cost-analyzer --condition=None
	gcloud projects add-iam-policy-binding ${PROJECT_ID} --role=roles/iam.serviceAccountTokenCreator \
		--member=principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/kubecost/sa/kubecost-cost-analyzer --condition=None

	helm upgrade -i kubecost cost-analyzer \
		--repo https://kubecost.github.io/cost-analyzer/ \
		--namespace kubecost --create-namespace \
		--set kubecostToken="${KUBECOST_TOKEN}" \
		--set global.prometheus.enabled=false \
		--set global.prometheus.fqdn=http://prometheus-operator-kube-p-prometheus.prometheus.svc:9090 \
		--set global.grafana.enabled=false \
		--set global.grafana.proxy=false

kubecost-pf:
	kubectl port-forward --namespace kubecost deployment/kubecost-cost-analyzer 9090

opencost-pf:
	kubectl port-forward -n opencost svc/opencost 9090

app-ambient: ## Deploy bank of anthos
	kubectl get ns bank-of-ambient || kubectl create ns bank-of-ambient
	kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/bank-of-anthos/main/extras/jwt/jwt-secret.yaml -n bank-of-ambient
	kubectl apply -f bank-of-anthos/ -n bank-of-ambient

app-waypoint:
	kubectl get crd gateways.gateway.networking.k8s.io &> /dev/null || \
		{ kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml; }
	kubectl apply -f waypoint-proxy.yaml -n bank-of-ambient
	kubectl label ns bank-of-ambient istio.io/use-waypoint=waypoint

app-sidecar: ## Deploy bank of anthos
	kubectl get ns bank-of-sidecar || kubectl create ns bank-of-sidecar
	kubectl label namespace bank-of-sidecar istio-injection=enabled
	kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/bank-of-anthos/main/extras/jwt/jwt-secret.yaml -n bank-of-sidecar
	kubectl apply -f bank-of-anthos/ -n bank-of-sidecar

cluster-datav2:
	gcloud services enable container.googleapis.com
	gcloud container clusters describe ambient-datav2 || gcloud container clusters create ambient-datav2 \
		--enable-dataplane-v2 \
		--enable-ip-alias \
		--cluster-version latest \
		--machine-type=${M_TYPE} \
		--num-nodes 4 \
		--zone ${ZONE} \
		--project ${PROJECT_ID}
	gcloud container clusters get-credentials ambient-datav2

cleanup: ## Cleaup
	gcloud container clusters delete ${CLUSTER_NAME}

help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m \t%s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)
