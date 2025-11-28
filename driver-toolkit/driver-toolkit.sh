#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Function to check if a command exists
check_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Error: $1 is not installed"
        case "$1" in
            jq)
                echo "To install jq:"
                echo "  For RHEL/CentOS: sudo yum install jq"
                echo "  For Ubuntu/Debian: sudo apt-get install jq"
                echo "  For macOS: brew install jq"
                ;;
            oc)
                echo "To install oc CLI:"
                echo "  Visit: https://console.redhat.com/openshift/downloads"
                echo "  Or: https://mirror.openshift.com/pub/openshift-v4/clients/ocp/"
                ;;
            curl)
                echo "To install curl:"
                echo "  For RHEL/CentOS: sudo yum install curl"
                echo "  For Ubuntu/Debian: sudo apt-get install curl"
                echo "  For macOS: brew install curl"
                ;;
        esac
        exit 1
    fi
}

# Check for required commands
for cmd in curl jq oc; do
    check_command "$cmd"
done

# Start with a temporary file
temp_json=$(mktemp)
echo "[" > "$temp_json"

first_entry=true
for major in {4..4}; do
    for minor in {16..20}; do
        page=1
        while true; do
            response=$(curl -s "https://quay.io/api/v1/repository/openshift-release-dev/ocp-release/tag/?onlyActiveTags=true&filter_tag_name=like:${major}.${minor}.&page=$page&limit=100")
            
            tags_count=$(echo "$response" | jq '.tags | length')
            if [ "$tags_count" -eq 0 ] || [ "$tags_count" = "null" ]; then
                break
            fi
            
            # Process each version
            while read -r version; do
                # Skip if empty
                [ -z "$version" ] && continue
                
                # Extract the version number without architecture
                version_num=${version%-x86_64}
                arch=${version#*-}
                
                # Show progress to user
                echo "Processing: ${version_num} (${arch})"
                
                # Get driver toolkit image
                dtk=$(oc adm release info "quay.io/openshift-release-dev/ocp-release:${version}" --image-for=driver-toolkit)
                
                # Create JSON entry
                entry=$(jq -c -n \
                    --arg version "$version_num" \
                    --arg arch "$arch" \
                    --arg dtk "$dtk" \
                    '{version: $version, arch: $arch, dtk: $dtk}')
                
                # Write to file with proper formatting
                if [ "$first_entry" = true ]; then
                    first_entry=false
                    echo "$entry" >> "$temp_json"
                else
                    echo ",$entry" >> "$temp_json"
                fi
                
            done < <(echo "$response" | \
                    jq -r '.tags[] | select(.name | test("^4\\.[0-9]+\\.[0-9]+-x86_64$")) | .name' | \
                    sort -V)
            
            ((page++))
        done
    done
done

# Close the temporary JSON
echo >> "$temp_json"
echo "]" >> "$temp_json"

# Sort the entire JSON array by version and write to final file
output_file="${OUTPUT_FILE:-driver-toolkit.json}"
jq -S 'sort_by(.version | split(".") | map(tonumber))' "$temp_json" > "$output_file"

# Clean up
rm "$temp_json"
