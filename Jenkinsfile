// Jenkinsfile — AlmaLinux 10 daily xCAT cluster regression (self-contained).
//
// CI glue lives under ci/ in this repo (build-rpm.sh, cluster-test.sh,
// xcattest-junit.sh, run-ci.sh, alma10-cluster.conf). This pipeline is the entry
// point the xcat-alma10-daily Jenkins job runs.
//
//   Build stage        (role_package_builder): build + GPG-sign all el10 rpms on
//                       the xcat-build VM, publish the signed dnf repo to NFS.
//   Cluster test stage (role_xcat_mn): (re)provision xcat01-mn and run the
//                       xCAT-test alma10 daily bundle against ci/alma10-cluster.conf
//                       (default.conf), which provisions the service + compute nodes.
//
// NOTE: this CI glue is a temporary home; it is meant to move to the ci-cd-platform
// repo (pipelines/xcat-core/) once that repo is writable. See ci/ commit.

pipeline {
    agent none

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '30'))
        timeout(time: 300, unit: 'MINUTES')
    }

    triggers { cron('H H(1-4) * * 1-5') }

    parameters {
        string(name: 'TEST_OS', defaultValue: 'alma10',
               description: 'OS under test (matches the xCAT-test bundle prefix and osimage)')
        string(name: 'CLUSTER', defaultValue: 'xcat01-mn',
               description: 'Cluster MN node name to (re)provision and test')
        booleanParam(name: 'RUN_BUILD', defaultValue: true,
               description: 'Build + GPG-sign the el10 packages before testing')
    }

    stages {
        stage('Build') {
            when { expression { return params.RUN_BUILD } }
            agent { label 'arch_x86_64 && os_el10 && role_package_builder && trust_internal' }
            steps {
                checkout scm
                sh './ci/build-rpm.sh el10 x86_64'
            }
        }

        stage('Cluster test') {
            agent { label 'role_xcat_mn' }
            steps {
                checkout scm
                sh "./ci/cluster-test.sh ${params.TEST_OS} ${params.CLUSTER}"
            }
            post {
                always {
                    junit allowEmptyResults: true, testResults: 'reports/junit/**/*.xml'
                    archiveArtifacts artifacts: 'reports/**/*', allowEmptyArchive: true
                }
            }
        }
    }
}
