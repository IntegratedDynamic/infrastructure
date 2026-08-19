# create_identity's `count` on module.identity (added so callers can opt out)
# changed its instance address from the countless form to `[0]`. This applies
# automatically to every caller of this module — no per-call-site moved block
# needed.
moved {
  from = module.identity
  to   = module.identity[0]
}
