#!/bin/bash

# CI Terraform Version Management Script
# Updates Terraform tfvars files with deployment versions
# 
# Usage:
#   ./ci_tf.sh sync-tfvars <version> <tfvars_file>
#
# Examples:
#   ./ci_tf.sh sync-tfvars 1.2.3 tf/dev/api/terraform.tfvars

set -e

# Source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ci_utils.sh"

# Function to update terraform.tfvars with new version
update_tfvars_version() {
    local tfvars_file="$1"
    local new_version="$2"
    
    log "Updating terraform.tfvars with new version: $new_version"
    
    if [ ! -f "$tfvars_file" ]; then
        log "❌ Terraform tfvars file not found: $tfvars_file"
        exit 1
    fi
    
    log "Updating existing tfvars file: $tfvars_file"
    
    # Create backup
    cp "$tfvars_file" "$tfvars_file.bak"
    
    # Update existing terraform.tfvars - only replace the version part after the colon
    sed -i.tmp "s|\(image_name.*=.*\".*:\)[^\"]*\"|\1$new_version\"|g" "$tfvars_file"
    rm "$tfvars_file.tmp" 2>/dev/null || true
    
    # Verify the update worked by checking if the new version appears in the file
    if grep -q ":$new_version\"" "$tfvars_file"; then
        log "✅ Tfvars file updated successfully"
        rm "$tfvars_file.bak"
    else
        log "❌ Tfvars update failed, restoring backup"
        mv "$tfvars_file.bak" "$tfvars_file"
        return 1
    fi
    
    # Show updated content for verification
    log "Updated tfvars content:"
    grep "image_name" "$tfvars_file" || log "No image_name found in tfvars file"
}

# Function to commit and push changes
commit_and_push_changes() {
    local tfvars_file="$1"
    local version="$2"
    
    log "📝 Committing tfvars changes to Git..."
    
    # Configure git (required for GitHub Actions)
    git config --local user.email "action@github.com"
    git config --local user.name "GitHub Action (ci_tf.sh)"
    
    # Add the tfvars file
    git add "$tfvars_file"
    log "Added tfvars file to git: $tfvars_file"
    
    # Check if there are changes to commit
    if git diff --staged --quiet; then
        log "⚠️ No changes to commit"
        return 0
    fi
    
    # Create commit message
    local commit_message="chore: update tfvars with deployment version $version

- Automated tfvars update by ci_tf.sh for deployment
- Files updated: $tfvars_file"
    
    if git commit -m "$commit_message" >&2; then
        log "✅ Changes committed successfully"
        
        # Push the changes back to the current branch with retry mechanism
        if push_with_retry; then
            log "✅ Changes pushed successfully"
        else
            log "❌ Failed to push changes to GitHub after all retry attempts"
            return 1
        fi
    else
        log "❌ Failed to commit changes"
        return 1
    fi
}

# Main script
main() {
    if [ $# -ne 3 ]; then
        log "❌ Usage:"
        log "     $0 sync-tfvars <version> <tfvars_file>"
        log ""
        log "   Examples:"
        log "     $0 sync-tfvars 1.2.3 tf/dev/api/terraform.tfvars"
        exit 1
    fi
    
    local action="$1"
    local version="$2"
    local tfvars_file="$3"
    
    # Validate action
    if [ "$action" != "sync-tfvars" ]; then
        log "❌ Invalid action: $action"
        log "   Valid actions: sync-tfvars"
        exit 1
    fi
    
    log "🔍 Action: $action"
    log "🔍 Version: $version"
    log "🔍 Tfvars file: $tfvars_file"
    
    # Debug: Show GitHub environment variables
    log "🔍 GitHub environment:"
    log "   - GITHUB_REF_NAME: ${GITHUB_REF_NAME:-'(not set)'}"
    log "   - GITHUB_HEAD_REF: ${GITHUB_HEAD_REF:-'(not set)'}"
    log "   - Current branch: $(git branch --show-current 2>/dev/null || echo '(unknown)')"
    
    log "🔍 Syncing tfvars with deployment version: $version"
    
    # Check if tfvars already has the correct version to avoid unnecessary commits
    if [ -f "$tfvars_file" ] && grep -q ":$version\"" "$tfvars_file"; then
        log "✅ Tfvars already has correct version: $version"
        
        # Output for GitHub Actions
        echo "version=$version"
        echo "tfvars_changed=false"
        echo "docker_tag=$version"
    else
        if update_tfvars_version "$tfvars_file" "$version"; then
            log "✅ Tfvars updated successfully to version: $version"
            
            # Commit and push changes
            if commit_and_push_changes "$tfvars_file" "$version"; then
                log "📋 Tfvars synced with version: $version (committed and pushed)"
                
                # Output for GitHub Actions - only on successful push
                echo "version=$version"
                echo "tfvars_changed=true"
                echo "docker_tag=$version"
            else
                log "❌ Changes made but failed to push to GitHub - failing build"
                exit 1
            fi
        else
            log "❌ Failed to update tfvars file"
            exit 1
        fi
    fi
}

# Run main function
main "$@"