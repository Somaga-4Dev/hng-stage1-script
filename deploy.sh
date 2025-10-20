#!/bin/bash

# ---Script Setup---
set -e

#Timestamped log file
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "--- Deployment Script Started at $(date) ---"
echo""

# --- 1. Collect Parameters  from User Input ---

echo "Please provide the following deployment details:"
read -p "Enter your Git Repository URL:" REPO_URL
read -sp "Enter your Github PAT (Personal Access Token):" GIT_PAT
echo ""

read -p "Enter the branch name (default:main)" SERVER_IP
read -p "Enter your remote server's SSH username (e.g. ubuntu)" SSH_USER
read -p "Enter the path to your SSH key (e.g. ~/.ssh/id_rsa):" SSH_KEY
read -p "Enter the port your app runs on inside the container (e.g. 3000):" APP_PORT

# Set a default for the branch name if it's empty
if [-z "$BRANCH_NAME"]; then
BRANCH_NAME="main"
echo "Branch name not set, using default: 'main'"
fi

#Extract repo name from url

REPO_NAME=$(basename -s.git "$REPO_URL")
echo ""
echo "Parameters collected. Starting deployment..."
echo "Repo: $REPO_URL"
echo "To: $SSH_USER@$SERVER_IP"
echo ""

# --- 2. Clone the repository locally ---
echo "Cloning repository '$REPO_URL'..."
if [-d "$REPO_NAME"]; then
  echo "Found existing directory, removing for a clean clone..."
  rm -rf "$REPO_NAME"
fi

#Clone the repo using Personal Access Token (PAT)
git clone "https://$[GIT_PAT]@${REPO_URL#https://}"
echo "Repo cloned successfully"

# --- 3. Navigate into Cloned Directory and Verify ---
cd "$REPO_NAME"
echo "Switched to local directory: $(pwd)"

echo "Checking out branch: '$BRANCH_NAME'..."
git checkout "$BRANCH_NAME"

echo "Verifying presence of Dockerfile or docker-compose.yml..."
if [ ! -f "Dockerfile" ] && [ ! -f "docker-compose.yml" ]; then
  echo "ERROR: Neither Dockerfile nor docker-compose.yml found in repo."
  echo "Deployment failed."
  exit 1 # Exit with an error code
fi
echo "Dockerfile/docker-compose.yml found."

# Go back to the parent directory for the next steps
cd ..
echo "Returned to base directory: $(pwd)"
echo ""

# --- 4. & 5. SSH into Remote Server and Prepare Environment ---
echo "Connecting to remote server $SSH_USER@$SERVER_IP to prepare environment..."

# We use a 'Heredoc' (<< 'ENDSSH') to send a block of commands
# The quotes around 'ENDSSH' prevent local variable expansion
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" << 'ENDSSH'
  # Set -e inside the SSH session too for safety
  set -e

  echo "Updating system packages on server..."
  sudo apt-get update -y

  echo "Installing Docker, Docker Compose, and Nginx..."
  sudo apt-get install -y docker.io docker-compose nginx

  echo "Starting and enabling services..."
  sudo systemctl start docker
  sudo systemctl enable docker
  sudo systemctl start nginx
  sudo systemctl enable nginx

  echo "Adding current user to Docker group (to run Docker without sudo)..."
  # '|| true' ignores the error if the user is already in the group
  sudo usermod -aG docker $USER || true

  echo "Server environment is ready."
  echo "Docker version: $(docker --version)"
  echo "Nginx version: $(nginx -v 2>&1)"
ENDSSH

echo ""

# --- 6. & 10. Transfer Project Files and Deploy Dockerized App ---
echo "Transferring project files to server via scp..."
# -r means "recursive" (copy the whole folder)
scp -i "$SSH_KEY" -r "$REPO_NAME" "$SSH_USER@$SERVER_IP:~/"
echo "Files transferred."

echo "Connecting to server to build and deploy container..."
# We pass APP_PORT and REPO_NAME by exporting them inside the SSH command
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" "
  # Make local variables available inside this remote session
  export APP_PORT=$APP_PORT
  export REPO_NAME=$REPO_NAME
  set -e # Safety first

  # Navigate to project directory
  cd \$REPO_NAME

  echo 'Stopping and removing old containers...'
  # This makes our script safe to re-run (Idempotent)
  sudo docker stop hng-app || true
  sudo docker rm hng-app || true

  echo 'Building new Docker image...'
  sudo docker build -t hng-app .

  echo 'Running new Docker container...'
  # Now $APP_PORT is available here!
  # We bind to 127.0.0.1 (localhost) so it's not public
  sudo docker run -d --name hng-app --restart always -p 127.0.0.1:\$APP_PORT:\$APP_PORT hng-app

  echo 'Docker container deployed and running internally.'
"
echo ""


# --- 7. Configure Nginx as a Reverse Proxy ---
echo "Configuring Nginx reverse proxy..."

# We pass these variables to the SSH command
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" "
  export APP_PORT=$APP_PORT
  export SERVER_IP=$SERVER_IP
  set -e

  echo 'Creating Nginx config file...'
  # Create the config file using a Heredoc and tee
  sudo tee /etc/nginx/sites-available/hng-app > /dev/null <<EOF
server {
    listen 80;
    server_name $SERVER_IP;

    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

  echo 'Enabling new Nginx config...'
  # Enable the site by creating a symbolic link
  sudo ln -sf /etc/nginx/sites-available/hng-app /etc/nginx/sites-enabled/

  # Remove default config if it exists
  sudo rm -f /etc/nginx/sites-enabled/default

  echo 'Testing Nginx config...'
  sudo nginx -t

  echo 'Reloading Nginx...'
  sudo systemctl reload nginx

  echo 'Nginx configured successfully.'
"
echo ""

# --- 8. Validate Deployment ---
echo "Validating deployment... Waiting 5 seconds for services..."
sleep 5

# Use curl to check if the public IP is returning a 200 OK status
echo "Pinging http://$SERVER_IP..."
HTTP_STATUS=\$(curl -s -o /dev/null -w "%{http_code}" "http://$SERVER_IP")

if [ "\$HTTP_STATUS" -eq 200 ]; then
  echo "í¾‰í¾‰í¾‰ DEPLOYMENT SUCCESSFUL! í¾‰í¾‰í¾‰"
  echo "Your application is live at: http://$SERVER_IP"
else
  echo " DEPLOYMENT FAILED."
  echo "Received HTTP status: \$HTTP_STATUS"
  echo "Please check the log file: $LOG_FILE and your server."
  exit 1
fi

echo ""
echo "--- Deployment Script Finished at $(date) ---"
