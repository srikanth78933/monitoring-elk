// monitoring-elk — deploys a lightweight ELK stack (Elasticsearch, Kibana,
// Filebeat + Metricbeat DaemonSets) into the same EKS cluster used by
// Enterprise-DevOps-Learning-Platform, to collect and visualize app logs
// and node/pod resource metrics. Filebeat/Metricbeat ship straight to
// Elasticsearch - no Logstash - see README.md for why. Dashboards are
// imported automatically from kibana/saved-objects/dashboards.ndjson as
// part of the deploy - see README.md's "Dashboards are code" section.
//
// Reuses the same Jenkins AWS credentials as that project's pipeline
// (same cluster, same account).

pipeline {
    agent any

    options {
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '20'))
        disableConcurrentBuilds()
        timeout(time: 30, unit: 'MINUTES')
    }

    environment {
        AWS_ACCESS_KEY_ID     = credentials('AWS_ACCESS_KEY_ID')
        AWS_SECRET_ACCESS_KEY = credentials('AWS_SECRET_ACCESS_KEY')

        AWS_REGION        = 'us-east-1'
        EKS_CLUSTER_NAME  = 'mycompany-dev-eks'
        LOGGING_NAMESPACE = 'logging'
    }

    stages {

        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Configure kubeconfig') {
            steps {
                sh 'aws eks update-kubeconfig --name ${EKS_CLUSTER_NAME} --region ${AWS_REGION}'
            }
        }

        stage('Deploy ELK stack') {
            steps {
                sh 'chmod +x scripts/*.sh'
                sh './scripts/deploy-elk.sh'
            }
        }

        stage('Verify') {
            steps {
                sh './scripts/verify-elk.sh'
            }
        }
    }

    post {
        always {
            cleanWs()
        }
        success {
            echo "ELK stack deployed to ${EKS_CLUSTER_NAME}. Run scripts/kibana-port-forward.sh locally to open Kibana at http://localhost:5601."
        }
        failure {
            echo 'Pipeline failed - check `kubectl get pods -n logging` and `kubectl describe pod/<pod> -n logging` for details.'
        }
    }
}
