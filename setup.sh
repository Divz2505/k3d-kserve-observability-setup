#!/bin/bash
set -e
 
############################################
# INSTALL DEPENDENCIES (WSL)
############################################
echo "Installing dependencies..."
sudo apt update
install_if_missing() {
  if ! command -v $1 &> /dev/null
  then
    echo "Installing $1..."
    eval $2
  else
    echo "$1 already installed"
  fi
}
install_if_missing curl "sudo apt install -y curl"
 
echo "🚀 Starting reproducible setup..."
 
############################################
# DOCKER
############################################
if ! command -v docker &> /dev/null
then
    echo "Installing Docker..."
    sudo apt install -y docker.io
    sudo usermod -aG docker $USER
    echo "⚠️ Docker group added. You MUST logout/login for it to take effect."
else
    echo "Docker already installed"
fi
 
# Try to start Docker daemon only when a local service exists.
if ! docker ps &> /dev/null
then
  if command -v systemctl &> /dev/null && systemctl list-unit-files 2>/dev/null | grep -q '^docker.service'; then
    sudo systemctl start docker || true
  elif command -v service &> /dev/null; then
    sudo service docker start || true
  fi
fi
 
# Verify Docker access
if ! docker ps &> /dev/null
then
  echo "❌ Docker daemon is not accessible from this shell."
  echo "👉 Fix options:"
  echo "   1) If using Docker Desktop on WSL, enable WSL integration for this distro and restart Docker Desktop"
  echo "   2) If using native Docker Engine, run: sudo apt install -y docker.io && sudo usermod -aG docker $USER"
  echo "      then logout/login (or run: newgrp docker)"
  echo "   3) Re-test with: docker ps"
  exit 1
fi
############################################
# KUBECTL
############################################
if ! command -v kubectl &> /dev/null
then
    curl -LO "https://dl.k8s.io/release/$(curl -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
fi
############################################
# K3D
############################################
if ! command -v k3d &> /dev/null
then
    curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
fi
echo "Verifying tools..."
kubectl version --client
k3d version
docker ps
echo "Dependencies ready"
############################################
# PROJECT SETUP
############################################
BASE_DIR=$(pwd)
mkdir -p "$BASE_DIR/data/victoriametrics" "$BASE_DIR/data/victorialogs" "$BASE_DIR/data/grafana"
mkdir -p platform/k3s
cd platform/k3s
############################################
# CLUSTER
############################################
k3d cluster delete basic-setup || true
 
k3d cluster create basic-setup \
  --servers 1 \
  --agents 2 \
  --k3s-arg "--disable=traefik@server:0" \
  --volume "$BASE_DIR/data/victoriametrics:/data/victoriametrics@all" \
  --volume "$BASE_DIR/data/victorialogs:/data/victorialogs@all" \
  --volume "$BASE_DIR/data/grafana:/data/grafana@all" \
  --port "8081:80@loadbalancer" \
  -p "30300:30300@agent:0" \
  -p "30750:30750@agent:0" \
  -p "30751:30751@agent:0" \
  -p "30770:30770@agent:0" \
  -p "30771:30771@agent:0"
 
k3d kubeconfig merge basic-setup --kubeconfig-switch-context
kubectl wait --for=condition=Ready nodes --all --timeout=120s
 
############################################
# OBSERVABILITY NAMESPACE
############################################
kubectl create namespace observability || true
 
############################################
# PERSISTENT STORAGE
############################################
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: vm-pv
spec:
  capacity:
    storage: 20Gi
  storageClassName: ""
  accessModes:
    - ReadWriteOnce
  hostPath:
    path: /data/victoriametrics
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: vl-pv
spec:
  capacity:
    storage: 30Gi
  storageClassName: ""
  accessModes:
    - ReadWriteOnce
  hostPath:
    path: /data/victorialogs
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: grafana-pv
spec:
  capacity:
    storage: 5Gi
  storageClassName: ""
  accessModes:
    - ReadWriteOnce
  hostPath:
    path: /data/grafana
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vm-pvc
  namespace: observability
spec:
  storageClassName: ""
  volumeName: vm-pv
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vl-pvc
  namespace: observability
spec:
  storageClassName: ""
  volumeName: vl-pv
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 30Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: grafana-pvc
  namespace: observability
spec:
  storageClassName: ""
  volumeName: grafana-pv
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
EOF
############################################
# KUBE STATE METRICS
############################################
kubectl apply -k https://github.com/kubernetes/kube-state-metrics.git//examples/standard
 
echo "⏳ Waiting for kube-state-metrics..."
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=kube-state-metrics -n kube-system --timeout=120s || true
 
############################################
# VICTORIA METRICS
############################################
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: victoriametrics
  namespace: observability
spec:
  replicas: 1
  selector:
    matchLabels:
      app: victoriametrics
  template:
    metadata:
      labels:
        app: victoriametrics
    spec:
      containers:
      - name: vm
        image: victoriametrics/victoria-metrics:v1.101.0
        args:
          - "--httpListenAddr=:8428"
          - "--storageDataPath=/storage"
        ports:
        - containerPort: 8428
        volumeMounts:
        - name: vm-storage
          mountPath: /storage
      volumes:
      - name: vm-storage
        persistentVolumeClaim:
          claimName: vm-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: victoriametrics
  namespace: observability
spec:
  type: NodePort
  selector:
    app: victoriametrics
  ports:
  - name: http
    port: 8428
    targetPort: 8428
    nodePort: 30750
EOF
 
kubectl rollout status deployment/victoriametrics -n observability
 
############################################
#victoria logs
############################################
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: victorialogs
  namespace: observability
spec:
  replicas: 1
  selector:
    matchLabels:
      app: victorialogs
  template:
    metadata:
      labels:
        app: victorialogs
    spec:
      containers:
      - name: victorialogs
        image: victoriametrics/victoria-logs:latest
        args:
          - "--storageDataPath=/storage"
        ports:
        - containerPort: 9428
        volumeMounts:
        - name: vl-storage
          mountPath: /storage
      volumes:
      - name: vl-storage
        persistentVolumeClaim:
          claimName: vl-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: victorialogs
  namespace: observability
spec:
  type: NodePort
  selector:
    app: victorialogs
  ports:
  - port: 9428
    targetPort: 9428
    nodePort: 30751
EOF
 
kubectl rollout status deployment/victorialogs -n observability --timeout=120s
kubectl get pods -n observability
 
############################################
# FLUENT BIT (LOG COLLECTION)
############################################
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: fluent-bit
  namespace: observability
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: fluent-bit-read
rules:
  - apiGroups: [""]
    resources: ["pods", "namespaces"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: fluent-bit-read
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: fluent-bit-read
subjects:
  - kind: ServiceAccount
    name: fluent-bit
    namespace: observability
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluent-bit-config
  namespace: observability
data:
  fluent-bit.conf: |
    [SERVICE]
        Flush         1
        Log_Level     info
        Parsers_File  parsers.conf
 
    [INPUT]
        Name              tail
        Path              /var/log/containers/*.log
        Parser            cri
        Tag               kube.*
        Mem_Buf_Limit     10MB
        Skip_Long_Lines   On
        Refresh_Interval  5
 
    [FILTER]
        Name                kubernetes
        Match               kube.*
        Kube_URL            https://kubernetes.default.svc:443
        Kube_CA_File        /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        Kube_Token_File     /var/run/secrets/kubernetes.io/serviceaccount/token
        Merge_Log           Off
        Keep_Log            On
        K8S-Logging.Parser  On
        K8S-Logging.Exclude Off
 
    [FILTER]
        Name                modify
        Match               kube.*
        Copy                log _msg
 
    [OUTPUT]
        Name                   loki
        Match                  kube.*
        Host                   victorialogs.observability.svc.cluster.local
        Port                   9428
        Uri                    /insert/loki/api/v1/push
        Labels                 job=fluent-bit,namespace=$kubernetes['namespace_name'],pod=$kubernetes['pod_name'],container=$kubernetes['container_name']
        Line_Format            json
        Auto_Kubernetes_Labels on
 
  parsers.conf: |
    [PARSER]
        Name        cri
        Format      regex
        Regex       ^(?<time>[^ ]+) (?<stream>stdout|stderr) (?<flag>[^ ]*) (?<log>.*)$
        Time_Key    time
        Time_Format %Y-%m-%dT%H:%M:%S.%L%z
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluent-bit
  namespace: observability
spec:
  selector:
    matchLabels:
      app: fluent-bit
  template:
    metadata:
      labels:
        app: fluent-bit
    spec:
      serviceAccountName: fluent-bit
      tolerations:
        - operator: Exists
      containers:
        - name: fluent-bit
          image: fluent/fluent-bit:3.0.7
          imagePullPolicy: IfNotPresent
          volumeMounts:
            - name: varlog
              mountPath: /var/log
            - name: config
              mountPath: /fluent-bit/etc
      volumes:
        - name: varlog
          hostPath:
            path: /var/log
        - name: config
          configMap:
            name: fluent-bit-config
EOF
 
kubectl rollout status daemonset/fluent-bit -n observability --timeout=180s || true
 
############################################
# JAEGER
############################################
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jaeger
  namespace: observability
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jaeger
  template:
    metadata:
      labels:
        app: jaeger
    spec:
      containers:
        - name: jaeger
          image: jaegertracing/all-in-one:1.57
          ports:
            - containerPort: 16686   # UI
            - containerPort: 14250   # gRPC collector
            - containerPort: 14268   # HTTP collector
            - containerPort: 4317    # OTLP gRPC
            - containerPort: 4318    # OTLP HTTP
 
---
apiVersion: v1
kind: Service
metadata:
  name: jaeger
  namespace: observability
spec:
  type: NodePort  
  selector:
    app: jaeger
  ports:
    - name: ui
      port: 16686
      targetPort: 16686
      nodePort: 30770  
 
    - name: grpc-collector
      port: 14250
      targetPort: 14250
 
    - name: http-collector
      port: 14268
      targetPort: 14268
 
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
      nodePort: 30771  
 
    - name: otlp-http
      port: 4318
      targetPort: 4318
EOF
 
############################################
# OPENTELEMETRY COLLECTOR
############################################
 
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-config
  namespace: observability
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
          http:
 
    exporters:
      otlp:
        endpoint: jaeger.observability:4317
        tls:
          insecure: true
 
    service:
      pipelines:
        traces:
          receivers: [otlp]
          exporters: [otlp]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  namespace: observability
spec:
  replicas: 1
  selector:
    matchLabels:
      app: otel
  template:
    metadata:
      labels:
        app: otel
    spec:
      containers:
      - name: otel
        image: otel/opentelemetry-collector:0.102.0
        args:
          - "--config=/etc/otel/config.yaml"
        ports:
        - containerPort: 4317
        - containerPort: 4318
        volumeMounts:
        - name: config
          mountPath: /etc/otel
      volumes:
      - name: config
        configMap:
          name: otel-config
---
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  namespace: observability
spec:
  type: ClusterIP
  selector:
    app: otel
  ports:
  - name: grpc
    port: 4317
    targetPort: 4317
  - name: http
    port: 4318
    targetPort: 4318
EOF
 
kubectl rollout status deployment/otel-collector -n observability
 
echo "⏳ Waiting for VictoriaMetrics..."
kubectl rollout status deployment/victoriametrics -n observability --timeout=120s
 
 
############################################
# VMAGENT (SCRAPE KUBE-STATE-METRICS)
############################################
 
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: vmagent-scrape
  namespace: observability
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
    scrape_configs:
      - job_name: victoriametrics
        static_configs:
          - targets: ["victoriametrics.observability:8428"]
      - job_name: kube-state-metrics
        static_configs:
          - targets: ["kube-state-metrics.kube-system.svc.cluster.local:8080"]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vmagent
  namespace: observability
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vmagent
  template:
    metadata:
      labels:
        app: vmagent
    spec:
      containers:
      - name: vmagent
        image: victoriametrics/vmagent:v1.101.0
        args:
          - "--promscrape.config=/etc/vmagent/prometheus.yml"
          - "--remoteWrite.url=http://victoriametrics.observability:8428/api/v1/write"
        ports:
          - containerPort: 8429
        volumeMounts:
          - name: config
            mountPath: /etc/vmagent
      volumes:
        - name: config
          configMap:
            name: vmagent-scrape
EOF
 
kubectl rollout status deployment/vmagent -n observability --timeout=120s
 
############################################
# GRAFANA
############################################
 
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasource
  namespace: observability
data:
  datasource.yaml: |
    apiVersion: 1
    datasources:
      - name: VictoriaMetrics
        type: prometheus
        url: http://victoriametrics.observability:8428
        access: proxy
        isDefault: true
 
      - name: VictoriaLogs
        type: victoriametrics-logs-datasource
        url: http://victorialogs.observability:9428
        access: proxy
 
      - name: Jaeger
        type: jaeger
        url: http://jaeger.observability:16686
        access: proxy
 
  dashboard-provider.yaml: |
    apiVersion: 1
    providers:
      - name: default
        orgId: 1
        folder: Kubernetes
        type: file
        disableDeletion: false
        updateIntervalSeconds: 30
        allowUiUpdates: true
        options:
          path: /var/lib/grafana/dashboards
 
  dashboard-k8s-overview.json: |
    {
      "annotations": {
        "list": [
          {
            "builtIn": 1,
            "datasource": {
              "type": "grafana",
              "uid": "-- Grafana --"
            },
            "enable": true,
            "hide": true,
            "iconColor": "rgba(0, 211, 255, 1)",
            "name": "Annotations & Alerts",
            "type": "dashboard"
          }
        ]
      },
      "editable": true,
      "graphTooltip": 0,
      "panels": [
        {
          "id": 1,
          "type": "stat",
          "title": "Nodes",
          "gridPos": {
            "h": 8,
            "w": 6,
            "x": 0,
            "y": 0
          },
          "targets": [
            {
              "expr": "count(kube_node_info)",
              "refId": "A"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "thresholds": {
                "mode": "absolute",
                "steps": [
                  {
                    "color": "green",
                    "value": null
                  }
                ]
              }
            },
            "overrides": []
          },
          "options": {
            "reduceOptions": {
              "calcs": [
                "lastNotNull"
              ],
              "fields": "",
              "values": false
            },
            "orientation": "auto",
            "textMode": "auto",
            "colorMode": "value",
            "graphMode": "none",
            "justifyMode": "auto"
          }
        },
        {
          "id": 2,
          "type": "stat",
          "title": "Running Pods",
          "gridPos": {
            "h": 8,
            "w": 6,
            "x": 6,
            "y": 0
          },
          "targets": [
            {
              "expr": "sum(kube_pod_status_phase{phase=\"Running\"})",
              "refId": "A"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "thresholds": {
                "mode": "absolute",
                "steps": [
                  {
                    "color": "green",
                    "value": null
                  }
                ]
              }
            },
            "overrides": []
          },
          "options": {
            "reduceOptions": {
              "calcs": [
                "lastNotNull"
              ],
              "fields": "",
              "values": false
            },
            "orientation": "auto",
            "textMode": "auto",
            "colorMode": "value",
            "graphMode": "none",
            "justifyMode": "auto"
          }
        },
        {
          "id": 3,
          "type": "stat",
          "title": "Available Deployments",
          "gridPos": {
            "h": 8,
            "w": 6,
            "x": 12,
            "y": 0
          },
          "targets": [
            {
              "expr": "sum(kube_deployment_status_replicas_available)",
              "refId": "A"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "thresholds": {
                "mode": "absolute",
                "steps": [
                  {
                    "color": "green",
                    "value": null
                  }
                ]
              }
            },
            "overrides": []
          },
          "options": {
            "reduceOptions": {
              "calcs": [
                "lastNotNull"
              ],
              "fields": "",
              "values": false
            },
            "orientation": "auto",
            "textMode": "auto",
            "colorMode": "value",
            "graphMode": "none",
            "justifyMode": "auto"
          }
        },
        {
          "id": 4,
          "type": "timeseries",
          "title": "Pods by Phase",
          "gridPos": {
            "h": 10,
            "w": 24,
            "x": 0,
            "y": 8
          },
          "targets": [
            {
              "expr": "sum by (phase) (kube_pod_status_phase)",
              "legendFormat": "{{phase}}",
              "refId": "A"
            }
          ],
          "fieldConfig": {
            "defaults": {},
            "overrides": []
          },
          "options": {
            "legend": {
              "displayMode": "list",
              "placement": "bottom"
            },
            "tooltip": {
              "mode": "single"
            }
          }
        }
      ],
      "refresh": "10s",
      "schemaVersion": 39,
      "tags": [
        "kubernetes",
        "kube-state-metrics"
      ],
      "time": {
        "from": "now-30m",
        "to": "now"
      },
      "title": "Kubernetes Overview",
      "uid": "k8s-overview-default",
      "version": 1
    }
 
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: observability
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
    spec:
      securityContext:
        fsGroup: 472
      initContainers:
      - name: fix-grafana-permissions
        image: busybox:1.36
        command: ["sh", "-c", "chown -R 472:472 /var/lib/grafana"]
        volumeMounts:
        - name: grafana-storage
          mountPath: /var/lib/grafana
      containers:
      - name: grafana
        image: grafana/grafana:10.4.2
        env:
          - name: GF_INSTALL_PLUGINS
            value: victoriametrics-logs-datasource
          - name: GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH
            value: /var/lib/grafana/dashboards/dashboard-k8s-overview.json
        ports:
        - containerPort: 3000
        volumeMounts:
          - name: grafana-storage
            mountPath: /var/lib/grafana
          - name: datasource
            mountPath: /etc/grafana/provisioning/datasources
          - name: dashboard-provider
            mountPath: /etc/grafana/provisioning/dashboards
          - name: dashboards
            mountPath: /var/lib/grafana/dashboards
        readinessProbe:
          httpGet:
            path: /login
            port: 3000
          initialDelaySeconds: 10
          periodSeconds: 5
      volumes:
        - name: grafana-storage
          persistentVolumeClaim:
            claimName: grafana-pvc
        - name: datasource
          configMap:
            name: grafana-datasource
            items:
              - key: datasource.yaml
                path: datasource.yaml
        - name: dashboard-provider
          configMap:
            name: grafana-datasource
            items:
              - key: dashboard-provider.yaml
                path: dashboard-provider.yaml
        - name: dashboards
          configMap:
            name: grafana-datasource
            items:
              - key: dashboard-k8s-overview.json
                path: dashboard-k8s-overview.json
 
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: observability
spec:
  type: NodePort
  selector:
    app: grafana
  ports:
  - port: 3000
    targetPort: 3000
    nodePort: 30300
EOF
 
kubectl rollout status deployment/grafana -n observability
############################################
# KNATIVE
############################################
 
KNATIVE_VERSION="knative-v1.11.2"
 
kubectl apply -f https://github.com/knative/serving/releases/download/$KNATIVE_VERSION/serving-crds.yaml
kubectl wait --for=condition=established crd/services.serving.knative.dev --timeout=120s
 
kubectl apply -f https://github.com/knative/serving/releases/download/$KNATIVE_VERSION/serving-core.yaml
kubectl wait --for=condition=Ready pods --all -n knative-serving --timeout=300s
 
############################################
# KOURIER
############################################
 
kubectl apply -f https://github.com/knative/net-kourier/releases/download/$KNATIVE_VERSION/kourier.yaml
 
kubectl patch configmap/config-network -n knative-serving \
  --type merge \
  -p '{"data":{"ingress.class":"kourier.ingress.networking.knative.dev"}}'
 
kubectl patch configmap/config-domain -n knative-serving \
  -p '{"data":{"127.0.0.1.sslip.io":""}}'
 
kubectl wait --for=condition=Ready pods --all -n kourier-system --timeout=300s
 
############################################
# CERT MANAGER
############################################
 
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.12.3/cert-manager.yaml
kubectl wait --for=condition=Ready pod --all -n cert-manager --timeout=300s
kubectl get pods -n cert-manager
 
############################################
# STABILIZATION
############################################
sleep 60
 
############################################
# KSERVE
############################################
 
kubectl apply -f https://github.com/kserve/kserve/releases/download/v0.11.2/kserve.yaml
 
echo "⏳ Waiting cert-manager (STRICT)..."
kubectl wait --for=condition=Ready pod --all -n cert-manager --timeout=300s
 
echo "⏳ Waiting webhook cert..."
sleep 20
 
kubectl wait --for=condition=Ready certificate/serving-cert -n kserve --timeout=180s || true
 
echo "⏳ Checking KServe pods..."
kubectl get pods -n kserve
 
echo "⏳ Attempt rollout..."
if ! kubectl rollout status deployment/kserve-controller-manager -n kserve --timeout=300s; then
  echo "⚠️ Fixing KServe deployment..."
 
  echo "📋 KServe pod diagnostics:"
  kubectl get pods -n kserve -o wide || true
  kubectl describe deployment kserve-controller-manager -n kserve || true
  for p in $(kubectl get pods -n kserve -l control-plane=kserve-controller-manager -o name); do
    kubectl describe -n kserve "$p" | sed -n '1,180p' || true
  done
 
  # Preemptively patch known broken image references in older KServe manifests.
  kubectl patch deployment kserve-controller-manager -n kserve --type='json' -p='[
    {"op":"replace","path":"/spec/template/spec/containers/0/image","value":"kserve/kserve-controller:v0.11.2"},
    {"op":"replace","path":"/spec/template/spec/containers/1/image","value":"quay.io/brancz/kube-rbac-proxy:v0.14.0"}
  ]'
 
  echo "🔁 Restarting controller..."
  kubectl rollout restart deployment kserve-controller-manager -n kserve
 
  echo "⏳ Final rollout..."
  kubectl rollout status deployment/kserve-controller-manager -n kserve --timeout=420s
fi
 
echo "✅ KServe is stable"
kubectl get pods -n kserve
 
############################################
# INGRESS
############################################
 
kubectl patch configmap inferenceservice-config -n kserve \
  --type merge \
  -p '{"data":{"ingress":"{\n\"ingressGateway\":\"knative-serving/kourier\",\n\"ingressService\":\"kourier.kourier-system.svc.cluster.local\",\n\"localGatewayService\":\"kourier.kourier-system.svc.cluster.local\",\n\"ingressClassName\":\"kourier.ingress.networking.knative.dev\",\n\"disableIstioVirtualHost\":true\n}"}}'
 
kubectl rollout restart deployment kserve-controller-manager -n kserve
kubectl rollout status deployment/kserve-controller-manager -n kserve
 
############################################
# INSTALL RUNTIMES
############################################
 
kubectl apply -f https://github.com/kserve/kserve/releases/download/v0.11.2/kserve-runtimes.yaml
sleep 10
kubectl get clusterservingruntimes
 
############################################
# FINAL
############################################
 
echo "🔍 Verifying observability stack..."
 
echo "👉 Pods:"
kubectl get pods
 
echo "👉 Services:"
kubectl get svc
 
echo "👉 Access URLs:"
echo "Grafana: http://localhost:30300"
echo "Jaeger:  http://localhost:30770"
echo "VictoriaMetrics: http://localhost:30750"
