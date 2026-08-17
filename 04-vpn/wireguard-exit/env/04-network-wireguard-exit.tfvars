# Matches variables.tf's defaults — spelled out explicitly rather than left
# implicit, same convention as every other root's env/ file.
peers = {
  "nicolas" = { address = "10.200.0.2/32" }
}
server_address = "10.200.0.1/24"
wg_endpoint    = "wg-exit.scalepack.fr:30821"
