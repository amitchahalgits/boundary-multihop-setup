disable_mlock = true

controller {
  name                = "enterprise-controller"
  description         = "Boundary Enterprise Controller"
  database {
    url = "postgresql://boundary:boundary@127.0.0.1:5432/boundary?sslmode=disable"
  }
  public_cluster_addr = "127.0.0.1:9201"
}

# API Listener (CLI & Web UI)
listener "tcp" {
  address     = "0.0.0.0:9200"
  purpose     = "api"
  tls_disable = true
}

# Cluster Listener (Worker Interconnect)
listener "tcp" {
  address     = "0.0.0.0:9201"
  purpose     = "cluster"
  tls_disable = true
}

# Shared AEAD KMS Keys
kms "aead" {
  purpose   = "root"
  aead_type = "aes-gcm"
  key       = "sP1fnF5Xz85RrXyELHFeZg9Ad2qt4Z4bgNHVGtD6ung="
  key_id    = "global_root"
}

kms "aead" {
  purpose   = "worker-auth"
  aead_type = "aes-gcm"
  key       = "OLFhJNbEb3umRjdhY15QKNEmNXokY1Iq8fZBjCUfN0T="
  key_id    = "global_worker-auth"
}

kms "aead" {
  purpose   = "recovery"
  aead_type = "aes-gcm"
  key       = "8fZBjCUfN0TzjEGLQldGY4+iE9AkOvCfjh7+p0GtRBQ="
  key_id    = "global_recovery"
}
