# oclazure
Terraform deployment of OCL for Azure Cloud

## Overview
The Azure deployment is automated and driven by terraform stored at https://github.com/OpenConceptLab/oclazure

## Terraform state
The "terraform-backend" directory contains setup for storing the Terraform state in Azure Storage. It needs to be run only once prior to setting up any environment. The Azure credentials used to setup terraform-backend should not be stored in any repo and reused. The state of terraform-backend stored locally should be discarded after running by removing the ".terraform" directory.

## Environments
Each environment is stored in a separate directory named after the environment. At the moment we only have one "test" environment. Each environment has separate Terraform state, which is stored in separate Azure Storage containers created via terraform-backend.

Environments are completely isolated from one another. They are deployed with Azure credentials, the scope of which is limited to the given environment. The test/terraform.tfvars contains all credentials needed to do deployment including Azure API keys, OCL API, DB, Redis and ES credentials. The tfvars are encrypted with git-crypt and can be decrypted only by admins, whose GPG keys were added to the repo.

Each environment consists of Azure services such as:
1. Virtual Network
2. Application Gateway
3. Private Links for Redis and DB
4. Container Registry
5. Kubernetes Cluster
6. PostgreSQL Flexible Server
7. Redis Cache 
8. Monitor

The Kubernetes cluster orchestrates running OCL services (api, web, celery workers, flower), Elasticsearch
and Errbit.

## Deployments
Deployments will be setup using Github Actions. There will be a manually triggered workflow that has a separete stage for each environment that needs to be reviewed and accepted by selected GitHub users. Each action will be pulling official OCL images from Dockerhub and pushing them to Azure Container Registry and doing deployments from ACR.

## Authentication
To start with OCL API will be deployed with internal authentication mechanism (django auth). It will be reconfigured to use Azure Active Directory SSO implementation.

