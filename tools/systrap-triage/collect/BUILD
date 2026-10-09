load("//tools:defs.bzl", "go_binary")

package(
    default_applicable_licenses = ["//:license"],
    licenses = ["notice"],
)

go_binary(
    name = "collect",
    srcs = [
        "main.go",
        "regs_amd64.go",
        "regs_arm64.go",
    ],
    pure = True,
    static = True,
    deps = ["//pkg/sentry/platform/systrap/sysmsg"],
)
