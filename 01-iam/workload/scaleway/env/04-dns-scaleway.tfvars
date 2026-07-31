project_id = "6283c05b-a4c7-4f83-a75f-83adad236d54"

identities = {
  external-dns = {
    purpose            = "manages DNS zone records for domains bought through Scaleway"
    policy_description = "DNS zone record read/write for the external-dns workload. No domain registration/transfer access."
    rules = [
      {
        project_ids           = ["6283c05b-a4c7-4f83-a75f-83adad236d54"]
        permission_set_names  = ["DomainsDNSFullAccess"]
      }
    ]
  }
}

# api_key_rotation_days defaults to 365
