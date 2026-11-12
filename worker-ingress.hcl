disable_mlock = true

worker {
  name        = "worker-ingress-dmz"
  description = "Edge Ingress Worker"
  public_addr = "127.0.0.1:9202"

  # Upstream to Controller Cluster Listener
  initial_upstreams = ["127.0.0.1:9201"]

  tags {
    type = ["ingress"]
    env  = ["dmz"]
  }
}

# Client-facing Proxy Listener
listener "tcp" {
  address     = "0.0.0.0:9202"
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
