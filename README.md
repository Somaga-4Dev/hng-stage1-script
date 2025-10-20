# HNG Stage 1 DevOps Task - Deployment Script

This repository contains a deploy.sh bash script created for the HNG Internship Stage 1 task.

## Description

This is a production-grade bash script that automates the deployment of a Dockerized web application from a Git repository to a remote Ubuntu server.

## Features

- Collects all necessary parameters from the user (Git URL, PAT, SSH credentials, etc.).
- Clones the application repository locally.
- Connects to the remote server via SSH.
- Installs all required dependencies (Docker, Docker Compose, NGINX).
- Transfers the application code to the server.
- Builds the Docker image and runs the container.
- Configures NGINX as a reverse proxy to make the app public on Port 80.
- Provides detailed logging (deploy\_...log) for troubleshooting.
- Is idempotent, meaning it can be re-run safely.

## How to Run

1.  Clone this repository:
    git clone https://github.com/Somaga-4Dev/hng-stage1-script.git
2.  Navigate into the directory:
    cd hng-stage1-script
3.  Make the script executable:
    chmod +x deploy.sh
4.  Run the script and follow the prompts:
    ./deploy.sh
