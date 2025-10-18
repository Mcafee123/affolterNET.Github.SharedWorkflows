#!/bin/bash

# CI Tag Creation Script
# Creates and pushes annotated git tags with release information
# 
# Usage: ./ci_tag.sh <version> <tag_prefix> <registry_name> <image_name>
# Example: ./ci_tag.sh 0.1.22 api gpplatformacr.azurecr.io an-formsg-api

set -e

log() {
    echo "[$(date '+%H:%M:%S')] $1" >&2
}

# Function to sync with remote before tagging
sync_with_remote() {
    # Determine the correct branch name
    local target_branch="${GITHUB_HEAD_REF:-$GITHUB_REF_NAME}"
    if [ -z "$target_branch" ]; then
        target_branch=$(git branch --show-current)
        log "⚠️ GitHub branch variables not available, using current branch: $target_branch"
    fi
    
    log "🔄 Syncing with remote branch: $target_branch"
    
    # Fetch latest changes from remote
    if git fetch origin "$target_branch"; then
        log "✅ Fetched latest changes from origin/$target_branch"
    else
        log "⚠️ Failed to fetch from origin/$target_branch, continuing with current state"
        return 0
    fi
    
    # Check if we're behind the remote
    local local_commit=$(git rev-parse HEAD)
    local remote_commit=$(git rev-parse "origin/$target_branch" 2>/dev/null || echo "")
    
    if [ "$local_commit" != "$remote_commit" ] && [ -n "$remote_commit" ]; then
        log "🔄 Local branch is behind remote, updating to latest commit..."
        log "ℹ️ Local commit: $local_commit"
        log "ℹ️ Remote commit: $remote_commit"
        
        # Fast-forward to the latest remote commit
        if git merge --ff-only "origin/$target_branch"; then
            log "✅ Successfully fast-forwarded to latest remote commit"
        else
            log "⚠️ Cannot fast-forward, there might be divergent changes"
            log "ℹ️ Continuing with current commit to avoid conflicts"
            # Continue with current commit rather than failing
        fi
    else
        log "ℹ️ Local branch is up to date with remote"
    fi
}


# Function to push tag with retry mechanism
push_tag_with_retry() {
    local tag_name="$1"
    local max_attempts=3
    local attempt=1
    local delay=2
    
    while [ $attempt -le $max_attempts ]; do
        log "📤 Attempt $attempt/$max_attempts: Pushing tag $tag_name to GitHub..."
        
        if git push origin "$tag_name"; then
            log "✅ Tag $tag_name pushed successfully"
            return 0
        else
            if [ $attempt -lt $max_attempts ]; then
                log "⚠️ Tag push failed, retrying in ${delay}s..."
                sleep $delay
                
                # Fetch latest refs in case of conflicts
                if git fetch origin 2>/dev/null; then
                    log "✅ Fetched latest refs from origin"
                else
                    log "ℹ️ Fetch failed or no new refs, continuing..."
                fi
                
                delay=$((delay * 2))  # Exponential backoff
                attempt=$((attempt + 1))
            else
                log "❌ Failed to push tag $tag_name after $max_attempts attempts"
                return 1
            fi
        fi
    done
}

create_tag() {
    local version="$1"
    local tag_prefix="$2" 
    local registry_name="$3"
    local image_name="$4"
    
    local tag_name="${tag_prefix}-${version}"
    
    log "Creating tag: $tag_name"
    
    # Check if tag already exists
    if git tag -l | grep -q "^$tag_name$"; then
        log "⚠️ Tag $tag_name already exists, skipping"
        echo "tag_created=false"
        echo "tag_name=$tag_name"
        echo "version=$version"
        return 0
    fi
    
    # Configure git
    git config --local user.email "action@github.com"
    git config --local user.name "GitHub Action"
    
    # Sync with remote to ensure we're tagging the latest commit
    sync_with_remote

    # Create release message
    local release_message="Release $tag_name

🐳 Docker Image: $registry_name/$image_name:$version
📋 Container Deployment: Successfully deployed to Azure
🔧 Environment: CONTAINER_IMAGE_VERSION=$version

📊 Build Information:
- Branch: $(git branch --show-current || echo "HEAD")
- Commit: $(git rev-parse HEAD)"

    # Create tag locally
    git tag -a "$tag_name" -m "$release_message"
    log "✅ Tag $tag_name created locally"
    
    # Push tag with retry mechanism
    if push_tag_with_retry "$tag_name"; then
        log "✅ Tag $tag_name created and pushed successfully"
    else
        log "❌ Failed to push tag $tag_name after all retry attempts"
        # Clean up local tag if push failed
        git tag -d "$tag_name" 2>/dev/null || true
        exit 1
    fi
    
    # GitHub Actions outputs
    echo "tag_created=true"
    echo "tag_name=$tag_name"
    echo "version=$version"
}

# Validate parameters
if [ $# -ne 4 ]; then
    log "❌ Usage: $0 <version> <tag_prefix> <registry_name> <image_name>"
    log "   Example: $0 0.1.22 api gpplatformacr.azurecr.io an-formsg-api"
    exit 1
fi

# Create the tag
create_tag "$@"