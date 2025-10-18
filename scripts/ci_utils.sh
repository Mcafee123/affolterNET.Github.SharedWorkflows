#!/bin/bash

# Shared utilities for CI scripts
# Common functions used across multiple CI scripts

# Function to log messages
log() {
    echo "[$(date '+%H:%M:%S')] $1" >&2
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