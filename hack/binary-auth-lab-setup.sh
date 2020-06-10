#!/bin/bash
set -x

# Set some variables
export GCP_PROJECT=$(gcloud config list --format "value(core.project)")
export IDNS=${GCP_PROJECT}.svc.id.goog
export PROJECT_NUMBER=$(gcloud projects describe ${GCP_PROJECT} --format="value(projectNumber)")
export MESH_ID="proj-${PROJECT_NUMBER}"

# TODO - ensure GCP_PROJECT is set
echo "TODO - ensure GCP_PROJECT is set"

# Be sure we're in home
pushd ~

# Enable GCP APIs
gcloud services enable \
    cloudresourcemanager.googleapis.com \
    container.googleapis.com \
    gkeconnect.googleapis.com \
    gkehub.googleapis.com \
    serviceusage.googleapis.com \
    sourcerepo.googleapis.com \
    iamcredentials.googleapis.com \
    stackdriver.googleapis.com \
    compute.googleapis.com \
    meshca.googleapis.com \
    meshtelemetry.googleapis.com \
    meshconfig.googleapis.com \
    anthos.googleapis.com \
    cloudbuild.googleapis.com

# Create the Kubernetes cluster
gcloud compute networks subnets describe default --region us-central1 | grep rangeName:\ pods >/dev/null 2>&1
if [ "$?" != "0" ]; then
  gcloud compute networks subnets update default \
      --region us-central1 \
      --add-secondary-ranges pods=10.56.0.0/14
fi

gcloud container clusters describe dev-cluster --zone us-central1-a >/dev/null 2>&1
if [ "$?" != "0" ]; then
  gcloud beta container clusters create dev-cluster --zone \
     us-central1-a \
     --enable-ip-alias \
     --machine-type n1-standard-4 \
     --num-nodes=4 \
     --identity-namespace=${IDNS} \
     --enable-stackdriver-kubernetes \
     --subnetwork=default \
     --cluster-secondary-range-name=pods \
     --services-ipv4-cidr=10.120.0.0/20 \
     --enable-binauthz \
     --labels mesh_id=${MESH_ID} \
     --release-channel regular
fi

# Set up service account and map that service account into Kubernetes workloads
gcloud iam service-accounts describe microservices-demo@${GCP_PROJECT}.iam.gserviceaccount.com >/dev/null 2>&1
if [ "$?" != "0" ]; then
  gcloud iam service-accounts create microservices-demo
  gcloud projects add-iam-policy-binding ${GCP_PROJECT} \
      --member=serviceAccount:microservices-demo@${GCP_PROJECT}.iam.gserviceaccount.com \
      --role=roles/cloudtrace.agent

  gcloud projects add-iam-policy-binding ${GCP_PROJECT} \
      --member=serviceAccount:microservices-demo@${GCP_PROJECT}.iam.gserviceaccount.com \
      --role=roles/cloudprofiler.agent

  gcloud iam service-accounts add-iam-policy-binding \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:${GCP_PROJECT}.svc.id.goog[default/default]" \
    microservices-demo@${GCP_PROJECT}.iam.gserviceaccount.com

  kubectl annotate serviceaccount \
    --namespace default \
    default \
    iam.gke.io/gcp-service-account=microservices-demo@${GCP_PROJECT}.iam.gserviceaccount.com
fi

# Set the kube context
kubectx dev-cluster=gke_${GCP_PROJECT}_us-central1-a_dev-cluster >/dev/null 2>&1

# Initialize the Anthos Service Mesh API
curl --request POST \
  --header "Authorization: Bearer $(gcloud auth print-access-token)" \
  --data '' \
  https://meshconfig.googleapis.com/v1alpha1/projects/${GCP_PROJECT}:initialize

# Create the cluster role binding
kubectl get clusterrolebinding cluster-admin-binding >/dev/null 2>&1
if [ "$?" != "0" ]; then
  kubectl create clusterrolebinding cluster-admin-binding \
    --clusterrole=cluster-admin \
    --user="$(gcloud config get-value core/account)"
fi

# Retrieve the asm distribution
if [ ! -d istio-1.4.9-asm.1 ]; then
  curl -LO https://storage.googleapis.com/gke-release/asm/istio-1.4.9-asm.1-linux.tar.gz
  tar xzf istio-1.4.9-asm.1-linux.tar.gz
  pushd istio-1.4.9-asm.1
  grep PATH ~/.bashrc >/dev/null 2>&1
  if [ "$?" != "0" ]; then
    echo "export PATH=${PWD}/bin:\$PATH" >> ~/.bashrc
  fi
  export PATH=$PWD/bin:$PATH
  popd
fi

# Install ASM
kubectl get namespace istio-system >/dev/null 2>&1
if [ "$?" != "0" ]; then
  pushd istio-1.4.9-asm.1
  istioctl manifest apply --set profile=asm \
    --set values.global.trustDomain=${IDNS} \
    --set values.global.sds.token.aud=${IDNS} \
    --set values.nodeagent.env.GKE_CLUSTER_URL=https://container.googleapis.com/v1/projects/${GCP_PROJECT}/locations/us-central1-a/clusters/dev-cluster \
    --set values.global.meshID=${MESH_ID} \
    --set values.global.proxy.env.GCP_METADATA="${GCP_PROJECT}|${PROJECT_NUMBER}|dev-cluster|us-central1-a" \
    --set values.grafana.enabled=true
  popd
fi
kubectl wait --for condition=ready pod --all -n istio-system

# Clone the Hipster Store repo, put it in Source Repositories, and deploy the application
if [ ! -d ~/microservices-demo ]; then
  git clone https://github.com/nsabine/microservices-demo.git

  pushd microservices-demo
  git remote remove origin
  git remote add origin https://source.developers.google.com/p/${GCP_PROJECT}/r/microservices-demo
  git config credential.helper gcloud.sh
  gcloud source repos create microservices-demo
  git push -u origin master
  kubectl label namespace default istio-injection=enabled
  kubectl apply -f ./release/kubernetes-manifests.yaml
  popd
fi
kubectl wait --for condition=ready pod --all -n default

# Apply the istio manifests
kubectl describe virtualservice frontend >/dev/null 2>&1
if [ "$?" != "0" ]; then
  pushd microservices-demo
  kubectl apply -f ./istio-manifests
  kubectl --context dev-cluster get -n istio-system service \
   istio-ingressgateway -o \
   jsonpath='{.status.loadBalancer.ingress[0].ip}'
  popd
fi



# go back to where we where
popd
