# Copyright 2023 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""AppIntents intents related actions."""

load("@apple_support//lib:apple_support.bzl", "apple_support")
load("@bazel_skylib//lib:paths.bzl", "paths")
load("//apple/internal:intermediates.bzl", "intermediates")
load("//apple/internal:shared_environment.bzl", "shared_environment")

# Maps the strings passed in to the "families" attribute to the string represention used as an input
# for the App Intents Metadata Processor tool.
_PLATFORM_TYPE_TO_PLATFORM_FAMILY = {
    "ios": "iOS",
    "macos": "macOS",
    "tvos": "tvOS",
    "watchos": "watchOS",
    "visionos": "xrOS",
}

def generate_app_intents_metadata_bundle(
        *,
        actions,
        apple_fragment,
        constvalues_files,
        intents_module_names,
        label,
        platform_prerequisites,
        source_files,
        target_triples,
        xcode_version_config,
        json_tool):
    """Process and generate AppIntents metadata bundle (Metadata.appintents).

    Args:
        actions: The actions provider from `ctx.actions`.
        apple_fragment: An Apple fragment (ctx.fragments.apple).
        constvalues_files: List of swiftconstvalues files generated from Swift source files
            implementing the AppIntents protocol.
        intents_module_names: List of Strings with the module names corresponding to the modules
            found which have intents compiled.
        label: Label for the current target (`ctx.label`).
        platform_prerequisites: Struct containing information on the platform being targeted.
        source_files: List of Swift source files implementing the AppIntents protocol.
        target_triples: List of Apple target triples from `CcToolchainInfo` providers.
        xcode_version_config: The `apple_common.XcodeVersionConfig` provider from the current ctx.
        json_tool: A `files_to_run` wrapping Python's `json.tool` module
            (https://docs.python.org/3.5/library/json.html#module-json.tool) for deterministic
            JSON handling.
    Returns:
        File referencing the Metadata.appintents bundle.
    """

    output = intermediates.directory(
        actions = actions,
        target_name = label.name,
        output_discriminator = None,
        dir_name = "Metadata.appintents",
    )

    args = actions.args()
    args.add("/usr/bin/xcrun")
    args.add("appintentsmetadataprocessor")

    # FB347041279: Though this is not required for --compile-time-extraction, which is the only
    # valid mode for extracting app intents metadata in Xcode 15.3, a string value is still
    # required by the appintentsmetadataprocessor.
    args.add("--binary-file", "/bazel_rules_apple/fakepath")

    if len(intents_module_names) > 1:
        fail("""
Found the following module names in the top level target {label} for app_intents: {intents_module_names}

App Intents must have only one module name for metadata generation to work correctly.
""".format(
            intents_module_names = ", ".join(intents_module_names),
            label = str(label),
        ))
    elif len(intents_module_names) == 0:
        fail("""
Could not find a module name for app_intents. One is required for App Intents metadata generation.
""")

    args.add("--module-name", intents_module_names[0])
    args.add("--output", output.dirname)
    args.add_all(
        source_files,
        before_each = "--source-files",
    )
    transitive_inputs = [depset(source_files)]
    args.add("--sdk-root", apple_support.path_placeholders.sdkroot())
    platform_type_string = str(platform_prerequisites.platform_type)
    platform_family = _PLATFORM_TYPE_TO_PLATFORM_FAMILY[platform_type_string]
    args.add("--platform-family", platform_family)
    args.add("--deployment-target", platform_prerequisites.minimum_os)
    args.add_all(target_triples, before_each = "--target-triple")
    args.add_all(
        constvalues_files,
        before_each = "--swift-const-vals",
    )
    transitive_inputs.append(depset(constvalues_files))
    args.add("--compile-time-extraction")

    # Read the build version from the fourth component of the Xcode version.
    xcode_version_split = str(xcode_version_config.xcode_version()).split(".")
    if len(xcode_version_split) < 4:
        fail("""\
Internal Error: Expected xcode_config to report the Xcode version with the build version as the \
fourth component of the full version string, but instead found {xcode_version_string}. Please file \
an issue with the Apple BUILD rules with repro steps.
""".format(
            xcode_version_string = str(xcode_version_config.xcode_version()),
        ))
    args.add("--xcode-version", xcode_version_split[3])

    json_tool_path = json_tool.executable.path

    apple_support.run_shell(
        actions = actions,
        apple_fragment = apple_fragment,
        arguments = [args],
        env = shared_environment.default_env,
        command = '''\
set -euo pipefail

# sorts JSON file keys for deterministic output
sort_json_file() {{
    local original_file="$1"
    local temp_file="${{original_file}}.sorted"

    # Sort the JSON file keys
    "{json_tool_path}" --compact --sort-keys "$original_file" > "$temp_file"
    # Replace original with sorted version
    mv "$temp_file" "$original_file"
}}

exit_status=0
output=$($@ --sdk-root "$SDKROOT" --toolchain-dir "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain" 2>&1) || exit_status=$?

# The Metadata.appintents/extract.actionsdata and version.json outputs are json
# files with non-deterministic keys order.
# Here we sort their keys to ensure that the output is deterministic.
# This should be removed once the issue is fixed (FB19585633).
actionsdata_file="{output_dir}/extract.actionsdata"
version_file="{output_dir}/version.json"

# Sort both JSON files to ensure deterministic output
sort_json_file "$version_file"
sort_json_file "$actionsdata_file"

# Set write permission to allow rewriting files
chmod +w "$version_file" "$actionsdata_file"

# Restore read-only permission
chmod -w "$version_file" "$actionsdata_file"

if [[ "$exit_status" -ne 0 ]]; then
  echo "$output" >&2
  exit $exit_status
elif [[ "$output" == *error:* ]]; then
  echo "$output" >&2
  exit 1
elif [[ "$output" == *"skipping writing output"* ]]; then
  echo "$output" >&2
  exit 1
fi
'''.format(
            output_dir = output.path,
            json_tool_path = json_tool_path,
        ),
        inputs = depset(transitive = transitive_inputs),
        tools = [json_tool],
        outputs = [output],
        mnemonic = "AppIntentsMetadataProcessor",
        xcode_config = xcode_version_config,
    )

    return output

def app_intents_ssu_training_commands(
        *,
        bundle_id,
        contents_path,
        resources_path):
    """Returns shell command lines that generate App Intents SSU (NL training) assets.

    Mirrors Xcode's AppIntentsSSUTraining build phase, which runs
    appintentsnltrainingprocessor on the assembled product to generate
    Metadata.appintents/root.ssu.yaml and the per-locale <locale>.lproj/nlu.appintents
    archives. Without these assets, Siri's assistant schema routing and App Shortcuts
    utterances do not recognize the app.

    The returned commands must be executed on an assembled (but not yet codesigned)
    bundle, in an environment where $WORK_DIR points to the archive root and DEVELOPER_DIR
    is set (i.e. within the bundling/signing actions), so that the generated assets are
    sealed by the code signature.

    Args:
        bundle_id: The bundle identifier of the bundle being processed.
        contents_path: Path to the bundle's contents directory, relative to the archive
            root. Equal to the bundle root except on macOS, where it is `Contents`.
        resources_path: Path to the bundle's resources directory, relative to the
            archive root. Equal to the bundle root except on macOS, where it is
            `Contents/Resources`.

    Returns:
        A string with the shell command lines to execute.
    """
    contents_dir = paths.join("$WORK_DIR", contents_path) if contents_path else "$WORK_DIR"
    product_dir = paths.join("$WORK_DIR", resources_path) if resources_path else "$WORK_DIR"
    # The tool may report failures on its output while still exiting with 0 (e.g.
    # "error: Could not archive SSU artifacts"), so inspect the output for errors
    # like the AppIntentsMetadataProcessor action does.
    return """\
if [[ -d "{product_dir}/Metadata.appintents" ]] && \\
    xcrun --find appintentsnltrainingprocessor >/dev/null 2>&1; then
  ssu_temp_dir="$(mktemp -d)"
  chmod u+w "{product_dir}" "{product_dir}/Metadata.appintents"
  find "{product_dir}" -maxdepth 1 -type d -name "*.lproj" -exec chmod u+w {{}} +
  ssu_exit_status=0
  ssu_output=$(xcrun appintentsnltrainingprocessor \\
      --infoplist-path "{contents_dir}/Info.plist" \\
      --temp-dir-path "$ssu_temp_dir" \\
      --bundle-id "{bundle_id}" \\
      --product-path "{product_dir}" \\
      --extracted-metadata-path "{product_dir}/Metadata.appintents" \\
      --archive-ssu-assets 2>&1) || ssu_exit_status=$?
  rm -rf "$ssu_temp_dir"
  if [[ "$ssu_exit_status" -ne 0 || "$ssu_output" == *error:* ]]; then
    echo "$ssu_output" >&2
    exit 1
  fi
fi
""".format(
        bundle_id = bundle_id,
        contents_dir = contents_dir,
        product_dir = product_dir,
    )
