#!/bin/bash

# Simple CI Version Management Script
# Reads current version or updates patch version if same as main branch
# Always syncs tfvars with the current version (whether updated or not)
# 
# Usage:
#   ./ci_version.sh read <project_file>
#   ./ci_version.sh update <project_file> [tfvars_file]
#
# Examples:
#   ./ci_version.sh read backend/affolterNET.FormsG.Api/affolterNET.FormsG.Api.csproj
#   ./ci_version.sh update backend/affolterNET.FormsG.Api/affolterNET.FormsG.Api.csproj
#   ./ci_version.sh update backend/affolterNET.FormsG.Api/affolterNET.FormsG.Api.csproj tf/dev/api/terraform.tfvars

set -e

# Function to log messages
log() {
    echo "[$(date '+%H:%M:%S')] $1" >&2
}

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

# Function to get version from main branch
get_main_branch_version() {
    local project_file="$1"
    
    # Check if we can access main branch
    git fetch origin main
    if ! git show origin/main:"$project_file" >/dev/null 2>&1; then
        log "⚠️ Cannot access main branch or file doesn't exist on main"
        echo ""
        return
    fi

    local main_version=$(git show origin/main:"$project_file" | grep -o '<Version>[^<]*</Version>' | sed 's/<Version>\(.*\)<\/Version>/\1/')

    if [ -z "$main_version" ]; then
        echo "0.1.0"
    else
        echo "$main_version"
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

# Function to update terraform.tfvars with new version
update_tfvars_version() {
    local tfvars_file="$1"
    local new_version="$2"
    
    log "Updating terraform.tfvars with new version: $new_version"
    
    if [ ! -f "$tfvars_file" ]; then
        log "⚠️ Terraform tfvars file not found: $tfvars_file - skipping tfvars update"
        return 0
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

# Function to push with retry and pull
push_with_retry() {
    local max_attempts=5
    local attempt=1
    local delay=2
    
    # Determine the correct branch name to push to
    # GITHUB_HEAD_REF is only set for pull requests, use GITHUB_REF_NAME for pushes
    local target_branch="${GITHUB_HEAD_REF:-$GITHUB_REF_NAME}"
    if [ -z "$target_branch" ]; then
        # Fallback to current branch if GitHub variables aren't available
        target_branch=$(git branch --show-current)
        log "⚠️ GitHub branch variables not available, using current branch: $target_branch"
    fi
    
    log "🎯 Target branch: $target_branch"
    
    while [ $attempt -le $max_attempts ]; do
        log "📤 Attempt $attempt/$max_attempts: Pushing changes to GitHub..."
        
        if git push origin HEAD:"$target_branch" >&2; then
            log "✅ Changes pushed successfully to $target_branch"
            return 0
        else
            if [ $attempt -lt $max_attempts ]; then
                log "⚠️ Push failed, fetching and rebasing latest changes..."
                sleep $delay
                
                # First, fetch the latest remote state
                log "🔄 Fetching latest remote changes..."
                if ! git fetch origin "$target_branch" >&2; then
                    log "⚠️ Failed to fetch remote changes, retrying push anyway..."
                    delay=$((delay + 1))
                    attempt=$((attempt + 1))
                    continue
                fi
                
                # Check if we're behind the remote
                local local_commit=$(git rev-parse HEAD)
                local remote_commit=$(git rev-parse "origin/$target_branch" 2>/dev/null || echo "")
                
                if [ "$local_commit" != "$remote_commit" ] && [ -n "$remote_commit" ]; then
                    log "🔄 Local branch diverged from remote, rebasing our changes..."
                    
                    # Rebase our commit on top of the remote
                    if git rebase "origin/$target_branch" >&2; then
                        log "✅ Successfully rebased changes on remote commits"
                    else
                        log "❌ Rebase failed - this shouldn't happen with different files"
                        log "🔧 Attempting to abort rebase and continue with original commit..."
                        git rebase --abort >&2 2>/dev/null || true
                        
                        # As fallback, try a merge instead of rebase
                        log "🔄 Trying merge strategy instead..."
                        if git merge "origin/$target_branch" --no-edit >&2; then
                            log "✅ Successfully merged remote changes"
                        else
                            log "❌ Merge also failed, skipping this retry..."
                            git merge --abort >&2 2>/dev/null || true
                        fi
                    fi
                else
                    log "ℹ️ Local and remote commits are the same or no remote branch exists"
                fi
                
                delay=$((delay + 1))  # Linear backoff
                attempt=$((attempt + 1))
            else
                log "❌ Failed to push changes after $max_attempts attempts"
                return 1
            fi
        fi
    done
}

# Function to commit and push changes
commit_and_push_changes() {
    local project_file="$1"
    local tfvars_file="$2"
    local old_version="$3"
    local new_version="$4"
    local version_changed="$5"
    local tfvars_changed="$6"
    
    log "📝 Committing changes to Git..."
    
    # Configure git (required for GitHub Actions)
    git config --local user.email "action@github.com"
    git config --local user.name "GitHub Action (ci_version.sh)"
    
    # Add the changed files
    local files_added=()
    if [ "$version_changed" = "true" ]; then
        git add "$project_file"
        files_added+=("$project_file")
        log "Added project file to git: $project_file"
    fi
    
    if [ "$tfvars_changed" = "true" ] && [ -f "$tfvars_file" ]; then
        git add "$tfvars_file"
        files_added+=("$tfvars_file")
        log "Added tfvars file to git: $tfvars_file"
    fi
    
    # Check if there are changes to commit
    if git diff --staged --quiet; then
        log "⚠️ No changes to commit"
        return 0
    fi
    
    # Create appropriate commit message based on what changed
    local commit_message
    if [ "$version_changed" = "true" ] && [ "$tfvars_changed" = "true" ]; then
        commit_message="chore: bump version from $old_version to $new_version and sync tfvars

- Automated version bump and tfvars sync by ci_version.sh
- Component: $(basename "$(dirname "$project_file")")
- Files updated: ${files_added[*]}"
    elif [ "$version_changed" = "true" ]; then
        commit_message="chore: bump version from $old_version to $new_version

- Automated version bump by ci_version.sh
- Component: $(basename "$(dirname "$project_file")")
- Files updated: ${files_added[*]}"
    else
        commit_message="chore: sync tfvars with version $new_version

- Automated tfvars sync by ci_version.sh
- Component: $(basename "$(dirname "$project_file")")
- Files updated: ${files_added[*]}"
    fi
    
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
    if [ $# -lt 2 ] || [ $# -gt 3 ]; then
        log "❌ Usage:"
        log "     $0 read <project_file> [tfvars_file]"
        log "     $0 update <project_file> [tfvars_file]"
        log ""
        log "   Examples:"
        log "     $0 read backend/affolterNET.FormsG.Api/affolterNET.FormsG.Api.csproj"
        log "     $0 read backend/affolterNET.FormsG.Api/affolterNET.FormsG.Api.csproj tf/dev/api/terraform.tfvars"
        log "     $0 update backend/affolterNET.FormsG.Api/affolterNET.FormsG.Api.csproj"
        log "     $0 update backend/affolterNET.FormsG.Api/affolterNET.FormsG.Api.csproj tf/dev/api/terraform.tfvars"
        exit 1
    fi
    
    local action="$1"
    local project_file="$2"
    local tfvars_file="$3"  # Optional for update action
    
    # Validate action
    if [ "$action" != "read" ] && [ "$action" != "update" ]; then
        log "❌ Invalid action: $action"
        log "   Valid actions: read, update"
        exit 1
    fi
    
    # Validate required parameters based on action
    if [ "$action" = "read" ] && ([ $# -lt 2 ] || [ $# -gt 3 ]); then
        log "❌ Read action requires 2-3 parameters: read <project_file> [tfvars_file]"
        exit 1
    fi
    
    if [ "$action" = "update" ] && ([ $# -lt 2 ] || [ $# -gt 3 ]); then
        log "❌ Update action requires 2-3 parameters: update <project_file> [tfvars_file]"
        exit 1
    fi
    
    log "🔍 Action: $action"
    log "🔍 Project file: $project_file"
    if [ -n "$tfvars_file" ]; then
        log "🔍 Tfvars file: $tfvars_file"
    fi
    
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
        # Get main branch version
        local main_version=$(get_main_branch_version "$project_file")
        if [ -n "$main_version" ]; then
            log "Main branch version: $main_version"
        else
            log "Main branch version: (not accessible)"
            main_version="$current_version"
        fi
        
        # Initialize tracking variables
        local version_changed=false
        local tfvars_changed=false
        local final_version="$current_version"
        
        # Determine if patch update is needed
        if [ "$current_version" = "$main_version" ]; then
            # Version is same as main, bump patch
            final_version=$(bump_patch_version "$current_version")
            log "Version matches main branch, bumping patch: $current_version → $final_version"
            
            update_version_in_file "$project_file" "$final_version"
            version_changed=true
        else
            log "Version differs from main branch, no version update needed"
            log "Current version: $current_version (unchanged)"
        fi
        
        # Always update terraform.tfvars with the final version (if tfvars file provided)
        if [ -n "$tfvars_file" ]; then
            log "Checking if tfvars needs to be updated with version: $final_version"
            
            # Check if tfvars already has the correct version to avoid unnecessary commits
            if [ -f "$tfvars_file" ] && grep -q ":$final_version\"" "$tfvars_file"; then
                log "✅ Tfvars already has correct version: $final_version"
            else
                if update_tfvars_version "$tfvars_file" "$final_version"; then
                    log "✅ Tfvars updated successfully to version: $final_version"
                    tfvars_changed=true
                else
                    log "⚠️ Failed to update tfvars file"
                fi
            fi
        else
            log "ℹ️ No tfvars file provided, skipping tfvars update"
        fi
        
        # Commit and push changes if any files were modified
        if [ "$version_changed" = true ] || [ "$tfvars_changed" = true ]; then
            if commit_and_push_changes "$project_file" "$tfvars_file" "$current_version" "$final_version" "$version_changed" "$tfvars_changed"; then
                log "📋 Final version: $final_version (committed and pushed)"
                
                # Output for GitHub Actions - only on successful push
                echo "version=$final_version"
                echo "version_changed=$version_changed"
                echo "old_version=$current_version"
                echo "docker_tag=$final_version"
            else
                log "❌ Changes made but failed to push to GitHub - failing build"
                exit 1
            fi
        else
            log "📋 Final version: $final_version (no changes needed)"
            
            # Output for GitHub Actions
            echo "version=$final_version"
            echo "version_changed=$version_changed"
            echo "old_version=$current_version"
            echo "docker_tag=$final_version"
        fi
    fi
}

# Run main function
main "$@"