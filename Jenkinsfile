pipeline {
    agent {
        dockerfile {
            filename 'Dockerfile'
            additionalBuildArgs "-t triveni-desktop-24.04-main"
            args '--user 0:0 --privileged -e HOME=${WORKSPACE} -v /var/lib/jenkins/userContent:/mnt/userContent'
        }
    }
    parameters {
        string(name: 'BASE_ISO_FILE', defaultValue: params.BASE_ISO_FILE ?: '', description: 'Path to Base ISO')
        string(name: 'DEB_DIRS', defaultValue: params.DEB_DIRS ?: '', description: 'Colon-separated directories containing Debian packages')
    }
    environment {
        FAILED_STAGE = "Initialization / Agent Setup"
    }
    stages {
        // Stages are run inside your container

        stage('Build Combo ISO') {
            steps {
                script { env.FAILED_STAGE = "Build Combo ISO" }
                sh "ant -DBASE_ISO_FILE=${params.BASE_ISO_FILE} -DDEB_DIRS=${params.DEB_DIRS}"
            }
        }
    }

    post {
        cleanup {
            deleteDir()
        }

//         always {
//             // This runs inside the container as root and
//             // gives ownership back to the jenkins user (usually UID 111 or 1000)
//             sh 'chown -R 111:117 .'
//         }
        success {
            // Grabs the output file from the dist folder
            archiveArtifacts artifacts: 'dist/*.iso', fingerprint: true
//            sendGoogleChatNotificationMT("✅ Build Successful: ${env.JOB_NAME} [${env.BUILD_NUMBER}]")
//            sendGoogleChatNotificationXM("✅ Build Successful: ${env.JOB_NAME} [${env.BUILD_NUMBER}]")
        }
        failure {
            script {
                sendGoogleChatNotificationMT("❌ Build Failed: *${env.FAILED_STAGE}* ${env.JOB_NAME} [${env.BUILD_NUMBER}]")
                sendGoogleChatNotificationXM("❌ Build Failed: *${env.FAILED_STAGE}* ${env.JOB_NAME} [${env.BUILD_NUMBER}]")
            }
        }
    }
}

def sendGoogleChatNotificationMT(String message) {
    def chatWebHook = "https://chat.googleapis.com/v1/spaces/AAAANJvMvsg/messages?key=AIzaSyDdI0hCZtE6vySjMm-WEfRq3CPzqKqqsHI&token=WI5JUlqOWa9_f4hfXMDgyj0EfxYzgRH91jUZ93dP6xE"
    def payload = """
        {
            "text": "${message}\\nLink: ${env.BUILD_URL}"
        }
    """.stripIndent()
    sh "curl -X POST -H 'Content-Type: application/json' -d '${payload}' '${chatWebHook}'"
}

def sendGoogleChatNotificationXM(String message) {
    def chatWebHook = "https://chat.googleapis.com/v1/spaces/AAAAg1WwKeo/messages?key=AIzaSyDdI0hCZtE6vySjMm-WEfRq3CPzqKqqsHI&token=AJxwfCLQ2I6gSmp-zXTbmMpwmRUoX-736jHPwEZwMxg"
    def payload = """
        {
            "text": "${message}\\nLink: ${env.BUILD_URL}"
        }
    """.stripIndent()
    sh "curl -X POST -H 'Content-Type: application/json' -d '${payload}' '${chatWebHook}'"
}

