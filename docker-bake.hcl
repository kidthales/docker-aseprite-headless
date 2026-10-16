variable "APP_UPSTREAM" { default = "docker-image://ubuntu:24.04" }
variable "ASEPRITE_BUILD_TYPE" { default = "Release" }
variable "ASEPRITE_GIT_REF" { default = "main" }
variable "BUILDER_UPSTREAM" { default = "docker-image://ubuntu:24.04" }
variable "IMAGES_PREFIX" { default = "" }
variable "PLATFORMS" { default = ["linux/amd64", "linux/arm64"] }

target "aseprite-headless" {
  platforms = PLATFORMS
  args = {
    aseprite_build_type = "${ASEPRITE_BUILD_TYPE}"
    aseprite_git_ref = "${ASEPRITE_GIT_REF}"
  }
  contexts = {
    builder-upstream = "${BUILDER_UPSTREAM}"
    app-upstream = "${APP_UPSTREAM}"
  }
  target = "app"
  tags = ["${IMAGES_PREFIX}aseprite:${ASEPRITE_GIT_REF}-headless"]
}

group "default" {
  targets = ["aseprite-headless"]
}
