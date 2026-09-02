include "root" {
  path = find_in_parent_folders("backend.hcl")
}

include "zone" {
  path = find_in_parent_folders("zones.hcl")
}
