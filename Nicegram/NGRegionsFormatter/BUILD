load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "NGRegionsFormatter",
    module_name = "NGRegionsFormatter",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    deps = [
        "//Nicegram/NGLocalization:NGLocalization",
	    "//Nicegram/NGModels:NGModels",
    ],
    visibility = ["//visibility:public"],

)
