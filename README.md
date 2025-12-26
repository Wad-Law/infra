# Infra: Cloud Infrastructure for Polymind

This repository contains the Terraform configuration and infrastructure-as-code (IaC) definitions required to deploy the **Polymind** trading bot environment on AWS.

## 🏗 Architecture

The infrastructure is designed for high availability, security, and automated deployment.

```mermaid
graph TD
    User[User/GitHub Actions] -->|Terraform Apply| AWS[AWS Cloud]
    subgraph AWS VPC
        subgraph Public Subnet
            EC2[EC2 Instance (Polymind)]
            SG_EC2[Security Group: EC2]
        end
        subgraph Private Subnet/RDS Subnet
            RDS[RDS Postgres (Polymind DB)]
            SG_RDS[Security Group: RDS]
        end
    end
    
    EC2 -->|Connects| RDS
    EC2 -->|Pulls Image| ECR[Elastic Container Registry]
    User -->|SSH (Optional)| EC2
```

### Key Components

*   **Compute**: 
    *   **EC2 (t3.micro)**: Hosts the `polymind` application container.
    *   **Auto Scaling Group (ASG)**: Ensures exactly one instance is running at all times (self-healing).
    *   **Launch Template**: Defines the instance configuration (AMI, Instance Type, IAM Profile, User Data).
*   **Database**:
    *   **Amazon RDS (PostgreSQL 16)**: Managed relational database for persistent storage (Events, Signals, Orders, Positions).
    *   **Storage**: gp3 EBS volumes.
*   **Security**:
    *   **IAM Roles**: Least-privilege roles for the EC2 instance (ECR access, SSM access, CloudWatch logs).
    *   **Security Groups**: 
        *   `ec2-sg`: Allows outbound traffic and necessary inbound (e.g., SSH if configured).
        *   `rds-sg`: Restricts database access to the EC2 security group (and temporarily public for dev testing).
*   **Containerization**:
    *   **Docker**: The application runs as a Docker container managed by `docker-compose`.
    *   **ECR**: Stores the Docker images built by CI/CD.

## 🛠 Tech Stack

-   **Terraform**: Infrastructure provisioning.
-   **AWS**: Cloud provider (US-East-1).
-   **Docker & Docker Compose**: Application runtime.
-   **Bash**: Bootstrapping and deployment scripts.

## 🚀 Deployment

### Prerequisites

1.  **Terraform**: `v1.0+`
2.  **AWS CLI**: Configured with appropriate credentials (`~/.aws/credentials`).
3.  **S3 Backend**: An S3 bucket for Terraform state (configured in `backend.hcl`).

### Steps to Deploy

1.  **Initialize**:
    ```bash
    cd env/prod
    terraform init
    ```

2.  **Plan**:
    Review the changes before applying.
    ```bash
    terraform plan -var="db_username=admin" -var="db_password=securepass"
    ```

3.  **Apply**:
    Provision the resources.
    ```bash
    terraform apply -var="db_username=admin" -var="db_password=securepass"
    ```

### Bootstrapping

The **User Data** script (`bootstrap.sh.tpl`) automatically:
1.  Installs Docker and Docker Compose on the EC2 instance.
2.  Authenticates with ECR.
3.  Pulls the latest `polymind` image.
4.  Starts the application using `docker-compose`.

## 📂 Directory Structure

```
infra/
├── env/
│   └── prod/               # Production environment configuration
│       ├── main.tf         # EC2, ASG, Launch Template
│       ├── rds.tf          # Database configuration
│       ├── iam.tf          # Permissions and Roles
│       ├── network.tf      # Networking (Security Groups)
│       ├── providers.tf    # AWS Provider setup
│       ├── variables.tf    # Input variables
│       ├── outputs.tf      # Output values (e.g., RDS Endpoint)
│       └── bootstrap.sh.tpl # EC2 startup script
└── ...
```