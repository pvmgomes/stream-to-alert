# Points the AWS provider at LocalStack instead of real AWS. Credentials are
# fixed dummy values because LocalStack doesn't validate them, and
# skip_* flags avoid the metadata/account-id lookups that only exist against
# real AWS. See docker-compose.yml for the LocalStack container this targets.
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    dynamodb = "http://localhost:4566"
    sns      = "http://localhost:4566"
    sqs      = "http://localhost:4566"
    lambda   = "http://localhost:4566"
    iam      = "http://localhost:4566"
    sts      = "http://localhost:4566"
    logs     = "http://localhost:4566"
  }
}
