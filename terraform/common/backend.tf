terraform {
  backend "s3" {
    # Partial configuration -- supply remaining values via backend.hcl per environment:
    #   bucket, key, region, dynamodb_table, encrypt
  }
}
