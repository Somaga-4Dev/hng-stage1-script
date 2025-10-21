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

read -p "Enter the branch name (default:main)" BRANCH_NAME
read -p "Enter remote server's IP address" SERVER_IP
read -p "Enter your remote server's SSH username (e.g. ubuntu)" SSH_USER
read -p "Enter the path to your SSH key (e.g. ~/.ssh/id_rsa):" SSH_KEY
read -p "Enter application port (e.g. 3000):" APP_PORT

# Set a default for the branch name if it's empty
if [ -z "$BRANCH_NAME" ]; then
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
if [ -d "$REPO_NAME" ]; then
  echo "Found existing directory, removing for a clean clone..."
  rm -rf "$REPO_NAME"
fi

#Clone the repo using Personal Access Token (PAT)
git -c credential.helper= clone "https://${GIT_PAT}@${REPO_URL#https://}"

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
echo "Preparing remote directory..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" "sudo rm -rf ~/$REPO_NAME && mkdir -p ~/$REPO_NAME"

echo "Transferring project files to server via scp..."
tar -czf "$REPO_NAME.tar.gz" --exclude='.git' "$REPO_NAME"
scp -i "$SSH_KEY" "$REPO_NAME.tar.gz" "$SSH_USER@$SERVER_IP:~/"
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" "tar -xzf $REPO_NAME.tar.gz && rm $REPO_NAME.tar.gz"
rm "$REPO_NAME.tar.gz"
echo "Files transferred successfully."

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
  sudo docker run -d --name hng-app --restart always -p 127.0.0.1:8080:80 hng-app

  echo 'Docker container deployed and running internally.'
"
echo ""


# --- 7. Configure Nginx as a Reverse Proxy ---
# --- 7. Configure Nginx as a Reverse Proxy ---
echo "Configuring Nginx reverse proxy..."
# We pass these variables to the SSH command
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" "
  export APP_PORT=$APP_PORT
  export SERVER_IP=$SERVER_IP
  set -e
  echo 'Creating Nginx config file...'
  # Create the config file using a Heredoc and tee
  sudo tee /etc/nginx/sites-available/hng-app > /dev/null <<'EOF'
server {
    listen 80;
    server_name SERVER_IP_PLACEHOLDER;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  # Replace placeholder with actual SERVER_IP
  sudo sed -i \"s/SERVER_IP_PLACEHOLDER/\$SERVER_IP/g\" /etc/nginx/sites-available/hng-app
  
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
# --- 8. Validate Deployment ---
echo "Validating deployment... Waiting 10 seconds for services to stabilize..."
sleep 10

# Check Docker container status on remote server
echo "Checking if Docker container is running..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" "
  if sudo docker ps | grep -q hng-app; then
    echo 'Container hng-app is running.'
  else
    echo 'ERROR: Container hng-app is not running!'
    sudo docker ps -a
    exit 1
  fi
"

# Check Nginx status
echo "Checking Nginx status..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" "
  if sudo systemctl is-active --quiet nginx; then
    echo 'Nginx is active and running.'
  else
    echo 'ERROR: Nginx is not running!'
    exit 1
  fi
"

# Use curl to check if the public IP is returning a 200 OK status
echo "Testing HTTP endpoint at http://$SERVER_IP..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://$SERVER_IP" || echo "000")

if [ "$HTTP_STATUS" -eq 200 ]; then
  echo "í¾‰í¾‰í¾‰ DEPLOYMENT SUCCESSFUL! í¾‰í¾‰í¾‰"
  echo "Your application is live at: http://$SERVER_IP"
else
  echo "EPLOYMENT FAILED."
  echo "Received HTTP status: $HTTP_STATUS"
  echo "Please check the log file: $LOG_FILE and your server."
  echo ""
  echo "Debugging information:"
  ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" "
    echo 'Docker container logs:'
    sudo docker logs hng-app --tail 50
    echo ''
    echo 'Nginx error log:'
    sudo tail -20 /var/log/nginx/error.log
  "
  exit 1
fi

echo ""
echo "--- Deployment Script Finished at $(date) ---"
