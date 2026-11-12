disable_mlock = true

worker {
  name        = "worker-egress-private"
  description = "Internal Egress Worker in Private VPC"
  public_addr = "127.0.0.1:9204"

  # Upstream to Ingress Worker Proxy Listener (Forms Multi-Hop DAG)
  initial_upstreams = ["127.0.0.1:9202"]

  tags {
    type = ["egress"]
    env  = ["private-vpc"]
  }
}

# Internal Proxy Listener
listener "tcp" {
  address     = "0.0.0.0:9204"
  purpose     = "proxy"
  tls_disable = true
}

# Matching Worker-Auth KMS
kms "aead" {
  purpose   = "worker-auth"
  aead_type = "aes-gcm"
  key       = "OLFhJNbEb3umRjdhY15QKNEmNXokY1Iq8fZBjCUfN0T="
  key_id    = "global_worker-auth"
}
