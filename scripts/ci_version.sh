#!/bin/bash

# Simple CI Version Management Script
# Reads current version or always updates patch version
# 
# Usage:
#   ./ci_version.sh read <project_file>
#   ./ci_version.sh update <project_file>
#
# Examples:
#   ./ci_version.sh read backend/affolterNET.FormsG.Api/affolterNET.FormsG.Api.csproj
#   ./ci_version.sh update backend/affolterNET.FormsG.Api/affolterNET.FormsG.Api.csproj

set -e

# Source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ci_utils.sh"

# Function to extract version from project file
get_version_from_file() {
    local project_file="$1"
    
    if [ ! -f "$project_file" ]; then
        log "❌ Project file not found: $project_file"
        exit 1
    fi
    
    local version=$(grep -o '<Version>[^<]*</Version>' "$project_file" | sed 's/<Version>\(.*\)<\/Version>/\1/')
    
    if [ -z "$version" ]; then
        log "⚠️ No version found in project file, using default: 0.1.0"
        echo "0.1.0"
    else
        echo "$version"
    fi
}

# Function to bump patch version
bump_patch_version() {
    local version="$1"
    
    local major=$(echo "$version" | cut -d'.' -f1)
    local minor=$(echo "$version" | cut -d'.' -f2)
    local patch=$(echo "$version" | cut -d'.' -f3)
    
    patch=$((patch + 1))
    
    echo "$major.$minor.$patch"
}

# Function to update version in project file
update_version_in_file() {
    local project_file="$1"
    local new_version="$2"
    
    log "Updating version to $new_version in $project_file"
    
    # Create backup
    cp "$project_file" "$project_file.bak"
    
    # Update version
    sed -i.tmp "s/<Version>[^<]*<\/Version>/<Version>$new_version<\/Version>/g" "$project_file"
    rm "$project_file.tmp" 2>/dev/null || true
    
    # Verify update
    local updated_version=$(get_version_from_file "$project_file")
    if [ "$updated_version" = "$new_version" ]; then
        log "✅ Version updated successfully"
        rm "$project_file.bak"
    else
        log "❌ Version update failed, restoring backup"
        mv "$project_file.bak" "$project_file"
        exit 1
    fi
}

# Function to commit and push changes
commit_and_push_changes() {
    local project_file="$1"
    local old_version="$2"
    local new_version="$3"
    
    log "📝 Committing changes to Git..."
    
    # Configure git (required for GitHub Actions)
    git config --local user.email "action@github.com"
    git config --local user.name "GitHub Action (ci_version.sh)"
    
    # Add the project file
    git add "$project_file"
    log "Added project file to git: $project_file"
    
    # Check if there are changes to commit
    if git diff --staged --quiet; then
        log "⚠️ No changes to commit"
        return 0
    fi
    
    # Create commit message
    local commit_message="chore: bump version from $old_version to $new_version

- Automated version bump by ci_version.sh
- Component: $(basename "$(dirname "$project_file")")
- Files updated: $project_file"
    
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
    if [ $# -ne 2 ]; then
        log "❌ Usage:"
        log "     $0 read <project_file>"
        log "     $0 update <project_file>"
        log ""
        log "   Examples:"
        log "     $0 read backend/affolterNET.FormsG.Api/affolterNET.FormsG.Api.csproj"
        log "     $0 update backend/affolterNET.FormsG.Api/affolterNET.FormsG.Api.csproj"
        exit 1
    fi
    
    local action="$1"
    local project_file="$2"
    
    # Validate action
    if [ "$action" != "read" ] && [ "$action" != "update" ]; then
        log "❌ Invalid action: $action"
        log "   Valid actions: read, update"
        exit 1
    fi
    
    log "🔍 Action: $action"
    log "🔍 Project file: $project_file"
    
    # Debug: Show GitHub environment variables
    log "🔍 GitHub environment:"
    log "   - GITHUB_REF_NAME: ${GITHUB_REF_NAME:-'(not set)'}"
    log "   - GITHUB_HEAD_REF: ${GITHUB_HEAD_REF:-'(not set)'}"
    log "   - Current branch: $(git branch --show-current 2>/dev/null || echo '(unknown)')"
    
    log "🔍 Reading version information..."
    
    # Get current version
    local current_version=$(get_version_from_file "$project_file")
    log "Current version: $current_version"
    
    if [ "$action" = "read" ]; then
        # Just return the current version
        log "📋 Current version: $current_version"
        
        # Output for GitHub Actions
        echo "version=$current_version"
        echo "version_changed=false"
        echo "old_version=$current_version"
        echo "docker_tag=$current_version"
        
    elif [ "$action" = "update" ]; then
        # Always bump patch version
        local final_version=$(bump_patch_version "$current_version")
        log "Bumping patch version: $current_version → $final_version"
        
        update_version_in_file "$project_file" "$final_version"
        
        # Commit and push changes
        if commit_and_push_changes "$project_file" "$current_version" "$final_version"; then
            log "📋 Final version: $final_version (committed and pushed)"
            
            # Output for GitHub Actions - only on successful push
            echo "version=$final_version"
            echo "version_changed=true"
            echo "old_version=$current_version"
            echo "docker_tag=$final_version"
        else
            log "❌ Changes made but failed to push to GitHub - failing build"
            exit 1
        fi
    fi
}

# Run main function
main "$@"
