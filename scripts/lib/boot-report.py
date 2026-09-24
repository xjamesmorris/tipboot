#!/usr/bin/env python3

import argparse
import json
import os
from pathlib import Path
import re
import sys
import tempfile


PANIC_PATTERNS = (
    ("kernel_panic", re.compile(r"\bKernel panic\b")),
    ("kernel_oops", re.compile(r"\bOops(?:[:\s]|$)")),
    ("kernel_bug", re.compile(r"(?:\bBUG:|\bkernel BUG at\b)")),
    ("unable_to_handle_kernel", re.compile(r"\bUnable to handle kernel\b")),
    ("internal_error", re.compile(r"\bInternal error:\s+Oops\b")),
)


def atomic_text(path, content):
    path = Path(path)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=str(path.parent), text=True
    )
    try:
        os.fchmod(descriptor, 0o644)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.close(descriptor)
        except OSError:
            pass
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def analyze_log(path, marker):
    raw = Path(path).read_bytes()
    text = raw.decode("utf-8", errors="replace")
    lines = text.splitlines()
    marker_lines = [index for index, line in enumerate(lines) if line == marker]
    first_marker = marker_lines[0] if marker_lines else len(lines)

    panic = None
    for index, line in enumerate(lines):
        for signature, pattern in PANIC_PATTERNS:
            if pattern.search(line):
                panic = {
                    "signature": signature,
                    "line": index + 1,
                    "text": line,
                    "before_marker": index < first_marker,
                }
                break
        if panic is not None:
            break

    power_down_lines = [
        index
        for index, line in enumerate(lines)
        if re.search(r"\breboot:\s+Power down\b", line)
    ]
    power_down_after_marker = any(index > first_marker for index in power_down_lines)
    marker_bytes = marker.encode("ascii")
    return {
        "marker_count": len(marker_lines),
        "marker_line": marker_lines[0] + 1 if marker_lines else None,
        "marker_byte_count": raw.count(marker_bytes),
        "tipboot_token_count": raw.count(b"TIPBOOT_OK"),
        "panic_before_marker": panic is not None and panic["before_marker"],
        "panic_after_marker": panic is not None and not panic["before_marker"],
        "panic": panic,
        "power_down_after_marker": power_down_after_marker,
    }


def base_result(args):
    return {
        "schema_version": 1,
        "status": None,
        "stage": None,
        "reason": None,
        "kernel_image": args.kernel_image,
        "initramfs": args.initramfs,
        "kernel_release": args.kernel_release,
        "expected_marker": (
            f"TIPBOOT_OK kernel_release={args.kernel_release}"
            if args.kernel_release
            else None
        ),
        "host_arch": args.host_arch or None,
        "acceleration": args.acceleration or None,
        "cpu": args.cpu or None,
        "acceleration_reason": args.acceleration_reason or None,
        "qemu": args.qemu or None,
        "qemu_version": args.qemu_version or None,
        "timeout_seconds": args.timeout_seconds,
        "qemu_exit_code": None,
        "timed_out": False,
        "clean_shutdown": False,
        "boot_log": args.boot_log,
        "marker_count": None,
        "marker_byte_count": None,
        "tipboot_token_count": None,
        "marker_line": None,
        "panic_before_marker": None,
        "panic_after_marker": None,
        "panic": None,
        "power_down_after_marker": None,
    }


def write_outputs(args, result):
    result_text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    atomic_text(args.result, result_text)

    display_status = "PASS" if result["status"] == "passed" else "FAIL"
    summary_fields = (
        ("status", result["status"]),
        ("stage", result["stage"]),
        ("reason", result["reason"]),
        ("kernel_release", result["kernel_release"]),
        ("host_arch", result["host_arch"]),
        ("acceleration", result["acceleration"]),
        ("cpu", result["cpu"]),
        ("acceleration_reason", result["acceleration_reason"]),
        ("qemu_exit_code", result["qemu_exit_code"]),
        ("timed_out", result["timed_out"]),
        ("clean_shutdown", result["clean_shutdown"]),
        ("marker_count", result["marker_count"]),
        ("tipboot_token_count", result["tipboot_token_count"]),
        ("panic_before_marker", result["panic_before_marker"]),
        ("panic_after_marker", result["panic_after_marker"]),
        ("power_down_after_marker", result["power_down_after_marker"]),
        ("boot_log", result["boot_log"]),
    )
    summary = f"{display_status}\n" + "".join(
        f"{key}: {value}\n" for key, value in summary_fields if value is not None
    )
    atomic_text(args.summary, summary)
    print(f"{display_status} [{result['stage']}]: {result['reason']}")


def failure_command(args):
    result = base_result(args)
    result.update(
        {
            "status": "failed",
            "stage": args.stage,
            "reason": args.reason,
        }
    )
    write_outputs(args, result)


def finalize_command(args):
    result = base_result(args)
    analysis = analyze_log(args.boot_log, args.marker)
    result.update(analysis)
    result["qemu_exit_code"] = args.qemu_exit_code
    result["timed_out"] = args.timed_out

    if analysis["panic_before_marker"] or analysis["panic_after_marker"]:
        panic = analysis["panic"]
        position = "before" if panic["before_marker"] else "after"
        result.update(
            {
                "status": "failed",
                "stage": f"guest_panic_{position}_marker",
                "reason": (
                    f"{panic['signature']} at boot log line {panic['line']} "
                    f"{position} the success marker"
                ),
            }
        )
    elif args.timed_out:
        result.update(
            {
                "status": "failed",
                "stage": "qemu_timeout",
                "reason": (
                    f"QEMU exceeded the hard {args.timeout_seconds}-second timeout"
                ),
            }
        )
    elif args.qemu_exit_code != 0:
        result.update(
            {
                "status": "failed",
                "stage": "qemu_exit",
                "reason": f"QEMU exited with status {args.qemu_exit_code}",
            }
        )
    elif analysis["marker_count"] == 0:
        result.update(
            {
                "status": "failed",
                "stage": "marker_missing",
                "reason": "the exact expected success marker was not observed",
            }
        )
    elif (
        analysis["marker_count"] != 1
        or analysis["marker_byte_count"] != 1
        or analysis["tipboot_token_count"] != 1
    ):
        result.update(
            {
                "status": "failed",
                "stage": "marker_invalid",
                "reason": (
                    "the success marker was duplicated, malformed, or embedded "
                    "in other output"
                ),
            }
        )
    elif not analysis["power_down_after_marker"]:
        result.update(
            {
                "status": "failed",
                "stage": "shutdown_missing",
                "reason": (
                    "the success marker was observed but the kernel did not "
                    "confirm the expected power-down path"
                ),
            }
        )
    else:
        result.update(
            {
                "status": "passed",
                "stage": "boot",
                "reason": (
                    "observed one exact success marker and a clean QEMU shutdown"
                ),
                "clean_shutdown": True,
            }
        )

    write_outputs(args, result)
    return 0 if result["status"] == "passed" else 1


def add_common_arguments(parser):
    parser.add_argument("--result", required=True)
    parser.add_argument("--summary", required=True)
    parser.add_argument("--boot-log", required=True)
    parser.add_argument("--kernel-image", required=True)
    parser.add_argument("--initramfs", required=True)
    parser.add_argument("--kernel-release", required=True)
    parser.add_argument("--host-arch", default="")
    parser.add_argument("--acceleration", default="")
    parser.add_argument("--cpu", default="")
    parser.add_argument("--acceleration-reason", default="")
    parser.add_argument("--qemu", default="")
    parser.add_argument("--qemu-version", default="")
    parser.add_argument("--timeout-seconds", type=int, required=True)


def build_parser():
    parser = argparse.ArgumentParser(
        description="Write Tipboot QEMU smoke-test result artifacts."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    failure = subparsers.add_parser("failure")
    add_common_arguments(failure)
    failure.add_argument("--stage", required=True)
    failure.add_argument("--reason", required=True)
    failure.set_defaults(function=failure_command)

    finalize = subparsers.add_parser("finalize")
    add_common_arguments(finalize)
    finalize.add_argument("--marker", required=True)
    finalize.add_argument("--qemu-exit-code", type=int, required=True)
    finalize.add_argument("--timed-out", action="store_true")
    finalize.set_defaults(function=finalize_command)

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    try:
        status = args.function(args)
    except OSError as error:
        parser.exit(2, f"boot-report.py: error: {error}\n")
    return status or 0


if __name__ == "__main__":
    sys.exit(main())
