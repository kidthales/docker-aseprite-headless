variable "ASEPRITE_BUILD_TYPE" { default = "Release" }
variable "ASEPRITE_GIT_REF" { default = "main" }
variable "IMAGES_PREFIX" { default = "" }
variable "IMAGE_TAG" { default = "" }
variable "PLATFORMS" { default = ["linux/amd64", "linux/arm64"] }

target "aseprite-headless" {
  platforms = PLATFORMS
  args = {
    aseprite_build_type = "${ASEPRITE_BUILD_TYPE}"
    aseprite_git_ref = "${ASEPRITE_GIT_REF}"
  }
  target = "app"
  tags = [IMAGE_TAG != "" ? "${IMAGES_PREFIX}aseprite:${IMAGE_TAG}" : "${IMAGES_PREFIX}aseprite:${ASEPRITE_GIT_REF}-headless"]
}

group "default" {
  targets = ["aseprite-headless"]
}
