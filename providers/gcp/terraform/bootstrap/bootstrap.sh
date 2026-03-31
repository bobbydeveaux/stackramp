#!/bin/bash
# StackRamp Platform Bootstrap
# Sets up the shared GCP platform project: WIF, Service Account, Artifact Registry, TF state bucket.
# Run ONCE per environment. After this, apps deploy with zero config.
#
# Usage: ./bootstrap.sh [dev|prod]

set -e

ENVIRONMENT=${1:-dev}

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error()   { echo -e "${RED}❌ $1${NC}"; }

# ── Validate environment ──────────────────────────────────────────────────────
if [[ ! "$ENVIRONMENT" =~ ^(dev|prod)$ ]]; then
    print_error "Invalid environment. Usage: $0 [dev|prod]"
    exit 1
fi

# ── Working directory ─────────────────────────────────────────────────────────
cd "$(dirname "$0")"

# ── Read tfvars ───────────────────────────────────────────────────────────────
TFVARS_FILE="${ENVIRONMENT}.tfvars"

if [ ! -f "$TFVARS_FILE" ]; then
    print_error "${TFVARS_FILE} not found. Copy the example and fill in your values:"
    echo "   cp ${ENVIRONMENT}.tfvars.example ${TFVARS_FILE}"
    exit 1
fi

PROJECT_ID=$(grep 'platform_project' "$TFVARS_FILE" | cut -d'"' -f2)
REGION=$(grep 'region' "$TFVARS_FILE" | cut -d'"' -f2)
GITHUB_OWNER=$(grep 'github_owner' "$TFVARS_FILE" | cut -d'"' -f2)

print_info "StackRamp Platform Bootstrap — ${ENVIRONMENT}"
echo "   Project:      $PROJECT_ID"
echo "   Region:       $REGION"
echo "   GitHub owner: $GITHUB_OWNER"
echo

# ── GCloud auth ───────────────────────────────────────────────────────────────
print_info "Checking GCP authentication..."
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
    print_error "No active GCP authentication. Please run:"
    echo "   gcloud auth login"
    exit 1
fi

ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" | head -n1)
print_success "Authenticated as: $ACTIVE_ACCOUNT"

# ── Application Default Credentials ──────────────────────────────────────────
print_info "Checking Application Default Credentials (ADC)..."
ADC_FILE="${HOME}/.config/gcloud/application_default_credentials.json"

if [ ! -f "$ADC_FILE" ]; then
    print_warning "ADC not set — Terraform requires ADC. Opening browser..."
    gcloud auth application-default login
    print_success "ADC authentication complete"
else
    print_success "ADC credentials found"
    read -p "   Re-authenticate ADC to ensure correct account? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        gcloud auth application-default login
        print_success "ADC re-authenticated"
    fi
fi

# ── Set active project ────────────────────────────────────────────────────────
print_info "Setting active GCP project to $PROJECT_ID..."
if ! gcloud config set project "$PROJECT_ID" 2>/dev/null; then
    print_error "Failed to set project. Check the project ID and your permissions."
    exit 1
fi

if ! gcloud projects describe "$PROJECT_ID" &>/dev/null; then
    print_error "Cannot access project $PROJECT_ID. Check:"
    echo "   1. Project ID is correct"
    echo "   2. You have access to this project"
    exit 1
fi
print_success "Project set to: $PROJECT_ID"

# ── Enable prerequisite APIs ──────────────────────────────────────────────────
print_info "Checking required GCP APIs..."
REQUIRED_APIS=(
    "cloudresourcemanager.googleapis.com"
    "iam.googleapis.com"
    "iamcredentials.googleapis.com"
    "storage.googleapis.com"
)

for api in "${REQUIRED_APIS[@]}"; do
    if ! gcloud services list --enabled --project="$PROJECT_ID" \
            --filter="name:${api}" --format="value(name)" | grep -q "${api}"; then
        print_warning "${api} not enabled — enabling..."
        gcloud services enable "${api}" --project="$PROJECT_ID"
        print_success "${api} enabled"
    else
        print_success "${api} already enabled"
    fi
done

sleep 2   # let API enablement propagate

# ── Create state bucket (pre-Terraform) ───────────────────────────────────────
# The bucket must exist before `terraform init` so remote state is used from run 1.
TF_STATE_BUCKET="${PROJECT_ID}-tf-state"

print_info "Ensuring state bucket gs://${TF_STATE_BUCKET} exists..."
if gsutil ls -p "$PROJECT_ID" "gs://${TF_STATE_BUCKET}" &>/dev/null; then
    print_success "Bucket already exists"
else
    gsutil mb -p "$PROJECT_ID" -l "$REGION" "gs://${TF_STATE_BUCKET}"
    print_success "Bucket created"
fi

print_info "Enabling versioning on gs://${TF_STATE_BUCKET}..."
gsutil versioning set on "gs://${TF_STATE_BUCKET}"
print_success "Versioning enabled"

# ── Write backend.tf ──────────────────────────────────────────────────────────
cat > backend.tf <<EOF
terraform {
  backend "gcs" {
    bucket = "${TF_STATE_BUCKET}"
    prefix = "bootstrap"
  }
}
EOF
print_success "Backend configured → gs://${TF_STATE_BUCKET}/bootstrap/"

# ── Terraform init (remote backend from the start) ────────────────────────────
print_info "Initialising Terraform..."
terraform init -reconfigure
print_success "Terraform initialised"

terraform validate
print_success "Configuration valid"

# ── Plan ──────────────────────────────────────────────────────────────────────
print_info "Planning bootstrap (${ENVIRONMENT})..."
terraform plan -var-file="$TFVARS_FILE"

echo
read -p "🤔 Apply these changes? (y/N): " -n 1 -r
echo

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_warning "Cancelled."
    exit 0
fi

# ── Apply ─────────────────────────────────────────────────────────────────────
print_info "Applying..."
terraform apply -var-file="$TFVARS_FILE" -auto-approve
print_success "Bootstrap resources deployed!"

# ── Outputs ───────────────────────────────────────────────────────────────────
echo
print_success "📤 Terraform outputs:"
terraform output

# ── Next steps ────────────────────────────────────────────────────────────────
echo
print_success "🎉 Bootstrap complete for ${ENVIRONMENT}!"
print_info "Next steps:"
echo "   1. Set these as GitHub Variables (org or repo → Settings → Actions → Variables):"
echo
terraform output -json | python3 -c "
import json, sys
data = json.load(sys.stdin)
keys = ['stackramp_provider','stackramp_project','stackramp_region','stackramp_wif_provider','stackramp_sa_email']
for k in keys:
    if k in data:
        print(f'      {k.upper():<30} = {data[k][\"value\"]}')
"
echo
echo "   2. Add stackramp.yaml + .github/workflows/deploy.yml to your app repo"
echo "   3. Push to main — the platform handles the rest"
