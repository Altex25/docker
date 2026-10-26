# À lancer depuis starter/ : les chemins (contextes, secret) sont relatifs au répertoire courant.

variable "VERSION" {
  default = "0.0.0-dev"
}

variable "GIT_SHA" {
  default = "unknown"
}

variable "REGISTRY" {
  default = "localhost:5050"
}

# Une référence de cache par cible : un ref partagé serait écrasé par la dernière cible construite.
function "cache_from" {
  params = [name]
  result = REGISTRY == "" ? [] : ["type=registry,ref=${REGISTRY}/cache:${name}"]
}

function "cache_to" {
  params = [name]
  result = REGISTRY == "" ? [] : ["type=registry,ref=${REGISTRY}/cache:${name},mode=max"]
}

function "tag" {
  params = [name]
  result = REGISTRY == "" ? ["${name}:${VERSION}"] : ["${REGISTRY}/${name}:${VERSION}"]
}

group "default" {
  targets = ["api", "worker"]
}

target "_common" {
  platforms = ["linux/amd64", "linux/arm64"]
  args = {
    APP_VERSION = VERSION
    GIT_SHA     = GIT_SHA
  }
  labels = {
    "org.opencontainers.image.version"  = VERSION
    "org.opencontainers.image.revision" = GIT_SHA
    "org.opencontainers.image.source"   = "https://github.com/Altex25/docker"
    "org.opencontainers.image.vendor"   = "Shop SAS"
  }
}

target "api" {
  inherits   = ["_common"]
  context    = "../../tp01-optimisation-image/starter/shopapi"
  target     = "runtime"
  tags       = tag("shopapi")
  cache-from = cache_from("api")
  cache-to   = cache_to("api")
}

target "worker" {
  inherits   = ["_common"]
  context    = "shop-worker"
  target     = "runtime"
  tags       = tag("shop-worker")
  secret     = ["id=pipconf,src=shop-worker/pip.conf"]
  cache-from = cache_from("worker")
  cache-to   = cache_to("worker")
}

target "worker-test" {
  inherits = ["worker"]
  target   = "test"
  tags     = []
  cache-to = []
  output   = ["type=cacheonly"]
}
