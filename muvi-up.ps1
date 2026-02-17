#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Muvi Cinemas - All-in-One CLI (Bootstrap + Day-to-Day Commands)
.DESCRIPTION
    Single entry point for the entire Muvi Cinemas microservices stack.
    Works on Windows (PowerShell 5.1+), macOS, and Linux (PowerShell Core 7+).

    Actions:
      (none)    Full 11-phase bootstrap (clone -> destroy -> infra -> verdaccio -> patch -> build -> start -> health -> seed -> frontend -> verify)
      up        Start all services (backend + frontend)
      down      Stop all services
      restart   Restart all services (or specific: -BuildOnly "gateway-service")
      seed      Re-run database seeders
      status    Show container status
      logs      Tail logs (all services, or specific: -BuildOnly "gateway-service")
      publish   Build & publish @alpha.apps packages to Verdaccio
      patch     Apply/revert local dev patches (-BuildOnly revert | status)
      frontend  Start only frontend (when backend is already running)
.EXAMPLE
    .\muvi-up.ps1                                  # Full bootstrap (first time)
    .\muvi-up.ps1 up                               # Start existing containers
    .\muvi-up.ps1 down                             # Stop everything
    .\muvi-up.ps1 restart                          # Restart all services
    .\muvi-up.ps1 restart -BuildOnly gateway-service  # Restart one service
    .\muvi-up.ps1 seed                             # Re-seed databases
    .\muvi-up.ps1 status                           # Show container status
    .\muvi-up.ps1 logs                             # Tail all logs
    .\muvi-up.ps1 logs -BuildOnly gateway-service  # Tail one service
    .\muvi-up.ps1 publish                          # Build & publish shared packages
    .\muvi-up.ps1 patch                            # Apply local dev patches
    .\muvi-up.ps1 patch -BuildOnly revert          # Revert patches
    .\muvi-up.ps1 -SkipDestroy                     # Full bootstrap, keep volumes
    .\muvi-up.ps1 -SkipBuild                       # Full bootstrap, skip image rebuild
    .\muvi-up.ps1 -SkipClone                       # Full bootstrap, skip cloning repos
    .\muvi-up.ps1 frontend                         # Start frontend only (backend must be running)
    .\muvi-up.ps1 -SkipFrontend                    # Full bootstrap, skip frontend setup
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet("", "up", "down", "restart", "seed", "status", "logs", "publish", "patch", "frontend", "portal", "ide")]
    [string]$Action = "",
    [switch]$SkipDestroy,
    [switch]$SkipBuild,
    [switch]$SkipClone,
    [switch]$SkipFrontend,
    [string]$BuildOnly
)

$ErrorActionPreference = "Stop"
$ROOT = $PSScriptRoot
$COMPOSE = Join-Path $ROOT "docker-compose.yml"
$BACKUP_TAR = Join-Path $ROOT "verdaccio-packages-backup.tar.gz"
$MICROSERVICES_DIR = Join-Path $ROOT "main-backend-microservices"
$WEB_DIR = Join-Path $ROOT "web"

# Cross-platform: detect PowerShell executable and OS
$IS_WINDOWS = ($PSVersionTable.PSEdition -ne 'Core') -or $IsWindows
$PWSH_EXE = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }

# Repos to clone into main-backend-microservices/
$reposToClone = @(
    @{ Name = "alpha-muvi-identity-main";      Url = "https://github.com/muvicinemas/alpha-muvi-identity-main.git" },
    @{ Name = "alpha-muvi-gateway-main";       Url = "https://github.com/muvicinemas/alpha-muvi-gateway-main.git" },
    @{ Name = "alpha-muvi-main-main";           Url = "https://github.com/muvicinemas/alpha-muvi-main-main.git" },
    @{ Name = "alpha-muvi-payment-main";        Url = "https://github.com/muvicinemas/alpha-muvi-payment-main.git" },
    @{ Name = "alpha-muvi-fb-main";             Url = "https://github.com/muvicinemas/alpha-muvi-fb-main.git" },
    @{ Name = "alpha-muvi-notification-main";   Url = "https://github.com/muvicinemas/alpha-muvi-notification-main.git" },
    @{ Name = "alpha-muvi-offer";               Url = "https://github.com/muvicinemas/alpha-muvi-offer.git" }
)

# Repos to clone into web/
$webReposToClone = @(
    @{ Name = "alpha-muvi-website-main";  Url = "https://github.com/muvicinemas/alpha-muvi-website-main.git" },
    @{ Name = "alpha-muvi-cms-main";      Url = "https://github.com/muvicinemas/alpha-muvi-cms-main.git" }
)

$allNestjsServices = @(
    "identity-service",
    "main-service",
    "payment-service",
    "fb-service",
    "notification-service",
    "gateway-service"
)

# Gateway is HTTP - health check via URL
# Other services are gRPC - health check via docker logs
$healthEndpoints = @(
    @{ Name = "Gateway"; Url = "http://localhost:3000/heartbeat"; Timeout = 60 }
)

$grpcServices = @(
    @{ Name = "Identity";     Container = "muvi-identity" },
    @{ Name = "Main";         Container = "muvi-main" },
    @{ Name = "Payment";      Container = "muvi-payment" },
    @{ Name = "FB";           Container = "muvi-fb" },
    @{ Name = "Notification"; Container = "muvi-notification" }
)

# -----------------------------------------------
# Helpers
# -----------------------------------------------
$script:startTime = Get-Date

function Write-Phase($num, $total, $msg) {
    $elapsed = [int]((Get-Date) - $script:startTime).TotalSeconds
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host "  PHASE $num/$total -- $msg  [${elapsed}s elapsed]" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

function Write-Step($msg) {
    Write-Host ""
    Write-Host "  --> $msg" -ForegroundColor White
}

function Write-Ok($msg)   { Write-Host "      [OK]   $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "      [WARN] $msg" -ForegroundColor Yellow }
function Write-Fail($msg) { Write-Host "      [FAIL] $msg" -ForegroundColor Red }

function Invoke-NativeCmd {
    <# Runs a native command with stderr merged into stdout.
       Prevents PS from treating stderr output as terminating errors. #>
    param([scriptblock]$ScriptBlock)
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        return (& $ScriptBlock 2>&1)
    } finally {
        $ErrorActionPreference = $prevEAP
    }
}

function Wait-ForUrl($url, $timeoutSec, $label) {
    if (-not $timeoutSec) { $timeoutSec = 30 }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
        try {
            $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 3 -ErrorAction SilentlyContinue
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) {
                return $true
            }
        }
        catch {
            $null = $_ # connection refused or timeout - keep trying
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

# -----------------------------------------------
# PHASE 1: Clone microservice repos
# -----------------------------------------------
function Invoke-CloneRepos {
    Write-Phase 1 12 "Cloning repositories (backend + frontend)"

    # Pre-flight: check git is installed
    Write-Step "Checking prerequisites..."
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitCmd) {
        Write-Fail "git is not installed or not in PATH"
        Write-Host ""
        Write-Host "      Please install Git from https://git-scm.com/downloads" -ForegroundColor Yellow
        Write-Host "      Then re-run this script." -ForegroundColor Yellow
        throw "Git is not installed"
    }
    $gitVersion = git --version 2>&1
    Write-Ok "$gitVersion"

    # Pre-flight: check GitHub authentication
    Write-Step "Checking GitHub access..."
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $authOutput = git ls-remote --exit-code "https://github.com/muvicinemas/alpha-muvi-identity-main.git" HEAD 2>&1
    $authExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP
    if ($authExit -ne 0) {
        $authStr = $authOutput -join "`n"
        Write-Fail "Cannot access GitHub repos"
        Write-Host ""
        if ($authStr -match "could not read Username|Authentication|403|401") {
            Write-Host "      You are not authenticated with GitHub." -ForegroundColor Red
            Write-Host "      Please run one of:" -ForegroundColor Yellow
            if ($IS_WINDOWS) {
                Write-Host "        git config --global credential.helper manager       # Windows" -ForegroundColor Gray
            } elseif ($IsMacOS) {
                Write-Host "        git config --global credential.helper osxkeychain   # macOS" -ForegroundColor Gray
            } else {
                Write-Host "        git config --global credential.helper store         # Linux" -ForegroundColor Gray
            }
            Write-Host "        gh auth login                                           # GitHub CLI (any OS)" -ForegroundColor Gray
            Write-Host "      Then try cloning any repo manually to confirm:" -ForegroundColor Yellow
            Write-Host "        git clone https://github.com/muvicinemas/alpha-muvi-identity-main.git" -ForegroundColor Gray
        } elseif ($authStr -match "not found|404") {
            Write-Host "      Repository not found. Your account may not have access." -ForegroundColor Red
            Write-Host "      Ask your team lead to grant access to the muvicinemas org." -ForegroundColor Yellow
        } elseif ($authStr -match "Could not resolve host|unable to access") {
            Write-Host "      Network error - cannot reach github.com." -ForegroundColor Red
            Write-Host "      Check your internet connection and proxy settings." -ForegroundColor Yellow
        } else {
            Write-Host "      Git error output:" -ForegroundColor Red
            $authOutput | ForEach-Object { Write-Host "        $_" -ForegroundColor Red }
        }
        Write-Host ""
        throw "GitHub authentication failed - cannot clone repos"
    }
    Write-Ok "GitHub access verified"

    # Create main-backend-microservices directory if needed
    if (-not (Test-Path $MICROSERVICES_DIR)) {
        New-Item -ItemType Directory -Path $MICROSERVICES_DIR -Force | Out-Null
        Write-Ok "Created main-backend-microservices/"
    }

    # Clone repos
    $total = $reposToClone.Count
    $current = 0
    $cloned = 0
    $skipped = 0
    $failed = @()

    foreach ($repo in $reposToClone) {
        $current++
        $targetDir = Join-Path $MICROSERVICES_DIR $repo.Name

        if (Test-Path $targetDir) {
            # Verify it's not a broken clone (only .git, no files)
            $repoFiles = Get-ChildItem $targetDir -Force | Where-Object { $_.Name -ne '.git' }
            if ($repoFiles.Count -gt 0) {
                Write-Ok "[$current/$total] $($repo.Name) (already exists - skipped)"
                $skipped++
                continue
            } else {
                Write-Warn "$($repo.Name) exists but appears empty (broken clone). Re-cloning..."
                Remove-Item $targetDir -Recurse -Force
            }
        }

        Write-Step "[$current/$total] Cloning $($repo.Name)..."
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        
        # Retry logic for transient network failures
        $maxRetries = 3
        $retryDelay = 5
        $cloneExit = 1
        $cloneOutput = $null
        
        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            if ($attempt -gt 1) {
                Write-Warn "Retry $attempt/$maxRetries for $($repo.Name) in $retryDelay seconds..."
                Start-Sleep -Seconds $retryDelay
                # Clean up partial clone if exists
                if (Test-Path $targetDir) {
                    Remove-Item $targetDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            
            $cloneOutput = git clone $repo.Url $targetDir 2>&1
            $cloneExit = $LASTEXITCODE
            
            if ($cloneExit -eq 0) {
                break
            }
            
            $errStr = $cloneOutput -join " "
            # Don't retry for auth/permission errors - those won't resolve with retries
            if ($errStr -match "Permission denied|403|401|Authentication|not found|404") {
                break
            }
        }
        
        $ErrorActionPreference = $prevEAP

        # Handle "clone succeeded but checkout failed" (e.g. invalid paths on Windows)
        if ($cloneExit -ne 0) {
            $errStr = $cloneOutput -join " "
            if ($errStr -match "Clone succeeded, but checkout failed") {
                Write-Warn "$($repo.Name) - checkout had issues (invalid file paths on this OS)"

                # For notification repo: the "entities " directory (trailing space) is invalid on Windows.
                # Strategy: checkout everything except the bad dir, then extract files from git objects.
                if ($repo.Name -eq "alpha-muvi-notification-main") {
                    Write-Step "Fixing $($repo.Name) - extracting files with invalid directory names..."
                    $prevEAP2 = $ErrorActionPreference
                    $ErrorActionPreference = "Continue"

                    # Checkout all files except those in "entities " (trailing space)
                    git -C $targetDir checkout HEAD -- . ":(exclude)src/notification/entities *" 2>&1 | Out-Null

                    # List files in the bad directory from git tree and extract to correct path
                    $badFiles = git -C $targetDir ls-tree --name-only HEAD "src/notification/entities /" 2>&1
                    if ($LASTEXITCODE -eq 0 -and $badFiles) {
                        $entitiesDir = Join-Path (Join-Path (Join-Path $targetDir "src") "notification") "entities"
                        if (-not (Test-Path $entitiesDir)) {
                            New-Item -ItemType Directory -Path $entitiesDir -Force | Out-Null
                        }
                        foreach ($badFile in $badFiles) {
                            $fname = Split-Path $badFile -Leaf
                            $fileContent = git -C $targetDir show "HEAD:$badFile" 2>&1
                            if ($LASTEXITCODE -eq 0 -and $fileContent) {
                                $outPath = Join-Path $entitiesDir $fname
                                [System.IO.File]::WriteAllText($outPath, ($fileContent -join "`n"))
                                Write-Ok "Extracted $fname -> entities/$fname"
                            }
                        }
                    }

                    # Fix import paths: source files reference "entities /" (with trailing space)
                    # but we extracted to "entities/" (no space). Patch all .ts imports.
                    $notifSrcDir = Join-Path (Join-Path $targetDir "src") "notification"
                    $tsFiles = Get-ChildItem $notifSrcDir -Filter "*.ts" -Recurse -File
                    $fixedImports = 0
                    foreach ($tsFile in $tsFiles) {
                        $content = [System.IO.File]::ReadAllText($tsFile.FullName)
                        if ($content -match "entities /") {
                            $fixed = $content -replace "entities /", "entities/"
                            [System.IO.File]::WriteAllText($tsFile.FullName, $fixed)
                            $fixedImports++
                        }
                    }
                    if ($fixedImports -gt 0) {
                        Write-Ok "Fixed import paths in $fixedImports files (entities / -> entities/)"
                    }

                    # Clean up git index: remove old "entities /" paths, add new "entities/" files
                    # This prevents confusing staged deletions + untracked files in source control
                    foreach ($badFile in $badFiles) {
                        git -C $targetDir rm --cached "$badFile" 2>&1 | Out-Null
                    }
                    git -C $targetDir add "src/notification/entities/" 2>&1 | Out-Null
                    # Also stage the import path fixes so repos appear clean
                    foreach ($tsFile in $tsFiles) {
                        $relPath = $tsFile.FullName.Substring($targetDir.Length + 1) -replace '\\', '/'
                        git -C $targetDir add "$relPath" 2>&1 | Out-Null
                    }
                    Write-Ok "Git index updated (repo appears clean)"

                    $ErrorActionPreference = $prevEAP2
                } else {
                    # Generic fallback for any other repo with checkout issues
                    $prevEAP2 = $ErrorActionPreference
                    $ErrorActionPreference = "Continue"
                    git -C $targetDir checkout -f HEAD 2>&1 | Out-Null
                    $ErrorActionPreference = $prevEAP2
                }

                Write-Ok "$($repo.Name) cloned (files with invalid names fixed at script level)"
                $cloned++
                continue
            }
        }

        if ($cloneExit -eq 0) {
            Write-Ok "$($repo.Name) cloned successfully"
            $cloned++
        } else {
            $errStr = $cloneOutput -join " "
            if ($errStr -match "Permission denied|403|401|Authentication") {
                Write-Fail "$($repo.Name) - ACCESS DENIED (check your GitHub permissions)"
            } elseif ($errStr -match "not found|404") {
                Write-Fail "$($repo.Name) - REPO NOT FOUND (check URL or org access)"
            } elseif ($errStr -match "Could not resolve|unable to access") {
                Write-Fail "$($repo.Name) - NETWORK ERROR (check internet connection)"
            } else {
                Write-Fail "$($repo.Name) - clone failed"
                $cloneOutput | ForEach-Object { Write-Host "        $_" -ForegroundColor Red }
            }
            $failed += $repo.Name
        }
    }

    # Summary
    Write-Host ""
    Write-Step "Clone summary: $cloned cloned, $skipped already present, $($failed.Count) failed (of $total)"
    if ($failed.Count -gt 0) {
        Write-Warn "Failed repos: $($failed -join ', ')"
        Write-Host ""
        Write-Host "      The following repos could not be cloned:" -ForegroundColor Red
        foreach ($f in $failed) {
            $url = ($reposToClone | Where-Object { $_.Name -eq $f }).Url
            Write-Host "        - $f  ($url)" -ForegroundColor Red
        }
        Write-Host ""
        Write-Host "      You can clone them manually and re-run this script." -ForegroundColor Yellow
        throw "Some repos failed to clone: $($failed -join ', ')"
    }

    Write-Ok "All $total backend repos are present"

    # Clone frontend repos into web/
    Write-Step "Cloning frontend repositories..."
    if (-not (Test-Path $WEB_DIR)) {
        New-Item -ItemType Directory -Path $WEB_DIR -Force | Out-Null
        Write-Ok "Created web/"
    }

    $webTotal = $webReposToClone.Count
    $webCurrent = 0
    $webCloned = 0
    $webSkipped = 0
    $webFailed = @()

    foreach ($repo in $webReposToClone) {
        $webCurrent++
        $targetDir = Join-Path $WEB_DIR $repo.Name

        if (Test-Path $targetDir) {
            $repoFiles = Get-ChildItem $targetDir -Force | Where-Object { $_.Name -ne '.git' }
            if ($repoFiles.Count -gt 0) {
                Write-Ok "[$webCurrent/$webTotal] $($repo.Name) (already exists - skipped)"
                $webSkipped++
                continue
            } else {
                Write-Warn "$($repo.Name) exists but appears empty. Re-cloning..."
                Remove-Item $targetDir -Recurse -Force
            }
        }

        Write-Step "[$webCurrent/$webTotal] Cloning $($repo.Name)..."
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        
        # Retry logic for transient network failures
        $maxRetries = 3
        $retryDelay = 5
        $cloneExit = 1
        $cloneOutput = $null
        
        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            if ($attempt -gt 1) {
                Write-Warn "Retry $attempt/$maxRetries for $($repo.Name) in $retryDelay seconds..."
                Start-Sleep -Seconds $retryDelay
                if (Test-Path $targetDir) {
                    Remove-Item $targetDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            
            $cloneOutput = git clone $repo.Url $targetDir 2>&1
            $cloneExit = $LASTEXITCODE
            
            if ($cloneExit -eq 0) {
                break
            }
            
            $errStr = $cloneOutput -join " "
            if ($errStr -match "Permission denied|403|401|Authentication|not found|404") {
                break
            }
        }
        
        $ErrorActionPreference = $prevEAP

        if ($cloneExit -eq 0) {
            Write-Ok "$($repo.Name) cloned successfully"
            $webCloned++
        } else {
            Write-Fail "$($repo.Name) - clone failed"
            $cloneOutput | ForEach-Object { Write-Host "        $_" -ForegroundColor Red }
            $webFailed += $repo.Name
        }
    }

    Write-Step "Frontend clone summary: $webCloned cloned, $webSkipped already present, $($webFailed.Count) failed (of $webTotal)"
    if ($webFailed.Count -gt 0) {
        Write-Warn "Failed frontend repos: $($webFailed -join ', ')"
        throw "Some frontend repos failed to clone: $($webFailed -join ', ')"
    }
    Write-Ok "All $webTotal frontend repos are present"

    # Ensure .env files exist (docker-compose env_file requires them)
    # IMPORTANT: Create EMPTY .env files, NOT copies of .env.example.
    # .env.example has keys with empty values (e.g. DB_DIALECT='') which override
    # docker-compose.yml environment: section and cause validation failures.
    Write-Step "Ensuring .env files exist for all services..."
    foreach ($repo in $reposToClone) {
        $repoDir = Join-Path $MICROSERVICES_DIR $repo.Name
        $envFile = Join-Path $repoDir ".env"
        if (-not (Test-Path $envFile)) {
            Set-Content $envFile "# Auto-generated - all values come from docker-compose.yml environment section"
            Write-Ok "$($repo.Name)/.env (created)"
        }
    }
}

# -----------------------------------------------
# PHASE 2: Destroy existing state
# -----------------------------------------------
function Invoke-Destroy {
    Write-Phase 2 12 "Destroying existing Docker state"

    Write-Step "Stopping containers and removing volumes..."
    Invoke-NativeCmd { docker compose -f $COMPOSE down -v --remove-orphans } | Out-Null

    Write-Step "Pruning dangling images for muvi..."
    $ids = docker images --filter "reference=*muvi*" -q 2>$null
    if ($ids) {
        $ids | ForEach-Object {
            docker rmi $_ -f 2>&1 | Out-Null
        }
    }

    Write-Ok "Clean slate - all containers, volumes, and images removed"
}

# -----------------------------------------------
# PHASE 2: Start infrastructure
# -----------------------------------------------
function Start-Infrastructure {
    Write-Phase 3 12 "Starting infrastructure (Verdaccio + Postgres + Redis + PgAdmin)"

    Write-Step "Starting containers..."
    Invoke-NativeCmd { docker compose -f $COMPOSE up -d verdaccio postgres redis pgadmin } | Out-Null

    Write-Step "Waiting for Verdaccio..."
    $ready = Wait-ForUrl "http://localhost:4873" 30 "Verdaccio"
    if ($ready) { Write-Ok "Verdaccio is ready" } else { throw "Verdaccio failed to start" }

    Write-Step "Waiting for Postgres..."
    $retries = 0
    while ($retries -lt 30) {
        $result = Invoke-NativeCmd { docker exec muvi-postgres pg_isready -U muvi }
        if ($result -match "accepting connections") { break }
        Start-Sleep -Seconds 1
        $retries++
    }
    if ($retries -ge 30) { throw "Postgres failed to start" }
    Write-Ok "Postgres is ready"

    Write-Step "Waiting for Redis..."
    $retries = 0
    while ($retries -lt 15) {
        $result = Invoke-NativeCmd { docker exec muvi-redis redis-cli ping }
        if ($result -match "PONG") { break }
        Start-Sleep -Seconds 1
        $retries++
    }
    if ($retries -ge 15) { throw "Redis failed to start" }
    Write-Ok "Redis is ready"
}

# -----------------------------------------------
# PHASE 3: Restore packages to Verdaccio
# -----------------------------------------------
function Restore-VerdaccioPackages {
    Write-Phase 4 12 "Restoring @alpha.apps packages to Verdaccio"

    if (-not (Test-Path $BACKUP_TAR)) {
        throw "Backup tarball not found: $BACKUP_TAR"
    }

    Write-Step "Extracting backup tarball..."
    $tempDir = Join-Path $ROOT "_verdaccio-restore-temp"
    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    Push-Location $tempDir
    tar -xzf $BACKUP_TAR 2>&1 | Out-Null
    Pop-Location

    Write-Step "Copying packages into Verdaccio container..."

    # Copy the entire extracted data directory content into the container at once.
    # This avoids docker cp per-package issues where the first copy may flatten contents.
    $dataDir = Join-Path $tempDir "data"
    $packageDirs = Get-ChildItem (Join-Path $dataDir "@alpha.apps") -Directory
    foreach ($pkg in $packageDirs) {
        Write-Ok "@alpha.apps/$($pkg.Name)"
    }

    # Use docker cp to copy the entire @alpha.apps directory
    $alphaAppsDir = Join-Path $dataDir "@alpha.apps"
    docker cp "$alphaAppsDir" "muvi-verdaccio:/verdaccio/storage/data/" 2>&1 | Out-Null

    # Copy the .verdaccio-db.json
    $dbJson = Join-Path $dataDir ".verdaccio-db.json"
    if (Test-Path $dbJson) {
        docker cp $dbJson "muvi-verdaccio:/verdaccio/storage/data/.verdaccio-db.json" 2>&1 | Out-Null
    }

    # Fix permissions (verdaccio runs as uid 10001, use -u root for chown)
    Invoke-NativeCmd { docker exec -u root muvi-verdaccio sh -c "chown -R 10001:65533 /verdaccio/storage/data/" } | Out-Null

    Write-Step "Restarting Verdaccio to pick up restored packages..."
    docker restart muvi-verdaccio 2>&1 | Out-Null
    Start-Sleep -Seconds 5
    $ready = Wait-ForUrl "http://localhost:4873" 30 "Verdaccio"
    if (-not $ready) { throw "Verdaccio failed to restart after package restore" }

    Write-Step "Verifying packages are available (with retries)..."
    $verifyPkgs = @(
        "@alpha.apps/muvi-proto",
        "@alpha.apps/muvi-shared",
        "@alpha.apps/nestjs-common",
        "@alpha.apps/muvi-identity-sdk",
        "@alpha.apps/muvi-main-sdk",
        "@alpha.apps/muvi-payment-sdk",
        "@alpha.apps/muvi-fb-sdk",
        "@alpha.apps/react-common"
    )
    $maxRetries = 5
    $retryDelay = 3
    $allGood = $false
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        $allGood = $true
        $failedPkgs = @()
        foreach ($pkg in $verifyPkgs) {
            $encodedPkg = $pkg -replace "/", "%2f"
            try {
                $r = Invoke-WebRequest -Uri "http://localhost:4873/$encodedPkg" -UseBasicParsing -ErrorAction SilentlyContinue
                if ($r.StatusCode -eq 200) {
                    if ($attempt -eq 1 -or $failedPkgs.Count -eq 0) {
                        Write-Ok "$pkg"
                    }
                } else {
                    $allGood = $false
                    $failedPkgs += $pkg
                }
            }
            catch {
                $allGood = $false
                $failedPkgs += $pkg
            }
        }
        if ($allGood) { break }
        if ($attempt -lt $maxRetries) {
            Write-Host "      Retry $attempt/$maxRetries - waiting ${retryDelay}s for: $($failedPkgs -join ', ')" -ForegroundColor Yellow
            Start-Sleep -Seconds $retryDelay
        }
    }
    if (-not $allGood) {
        foreach ($pkg in $failedPkgs) { Write-Fail "$pkg - not found after $maxRetries retries" }
        throw "Some packages are missing from Verdaccio"
    }

    # Clean up temp
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "All 8 packages restored and verified (7 backend + react-common)"
}

# -----------------------------------------------
# PHASE 5: Apply patches (inlined from local-dev-patches.ps1)
# -----------------------------------------------

# -- Patch data --
$npmrcFiles = @(
    "main-backend-microservices\alpha-muvi-fb-main\.npmrc",
    "main-backend-microservices\alpha-muvi-fb-main\libs\fb-sdk\.npmrc",
    "main-backend-microservices\alpha-muvi-gateway-main\.npmrc",
    "main-backend-microservices\alpha-muvi-identity-main\.npmrc",
    "main-backend-microservices\alpha-muvi-identity-main\libs\identity-sdk\.npmrc",
    "main-backend-microservices\alpha-muvi-main-main\.npmrc",
    "main-backend-microservices\alpha-muvi-main-main\libs\main-sdk\.npmrc",
    "main-backend-microservices\alpha-muvi-notification-main\.npmrc",
    "main-backend-microservices\alpha-muvi-payment-main\.npmrc",
    "main-backend-microservices\alpha-muvi-payment-main\libs\payment-sdk\.npmrc",
    "web\alpha-muvi-cms-main\.npmrc",
    "web\alpha-muvi-website-main\.npmrc"
)
$npmrcOriginal = "//registry.npmjs.org/:_authToken=`${NPM_TOKEN}"
$npmrcPatched  = "@alpha.apps:registry=http://host.docker.internal:4873"

$lockFiles = @(
    "main-backend-microservices\alpha-muvi-identity-main\package-lock.json",
    "main-backend-microservices\alpha-muvi-gateway-main\package-lock.json",
    "main-backend-microservices\alpha-muvi-main-main\package-lock.json",
    "main-backend-microservices\alpha-muvi-payment-main\package-lock.json",
    "main-backend-microservices\alpha-muvi-fb-main\package-lock.json",
    "main-backend-microservices\alpha-muvi-notification-main\package-lock.json"
)

$yarnLockFiles = @(
    "web\alpha-muvi-cms-main\yarn.lock"
)

$sourcePatches = @(
    @{
        File     = "main-backend-microservices\alpha-muvi-fb-main\src\order\services\food-order.service.ts"
        Original = @"
        isStcPayActive: false,
        isApplePayActive: false,
        isEwalletActive: false,
        isCashbackWalletActive: false,
      };
"@
        Patched  = @"
        isStcPayActive: false,
        isApplePayActive: false,
        isEwalletActive: false,
        isCashbackWalletActive: false,
        isTabbyActive: false,
      };
"@
    }
)

function Apply-Patches {
    # .npmrc files
    foreach ($f in $npmrcFiles) {
        $fp = Join-Path $ROOT $f
        if (Test-Path $fp) { Set-Content $fp $npmrcPatched -NoNewline }
    }
    # package-lock.json files
    foreach ($f in $lockFiles) {
        $fp = Join-Path $ROOT $f
        if (-not (Test-Path $fp)) { continue }
        $content = Get-Content $fp -Raw
        if (-not ($content -match '"resolved":\s*"https://registry\.npmjs\.org/@alpha\.apps/')) { continue }
        $content = $content -replace '"resolved":\s*"https://registry\.npmjs\.org/@alpha\.apps/', '"resolved": "http://host.docker.internal:4873/@alpha.apps/'
        $lines = $content -split "`n"
        $newLines = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($i -gt 0 -and $lines[$i-1] -match 'host\.docker\.internal:4873/@alpha\.apps/' -and $line -match '^\s*"integrity":\s*"sha') {
                $nextLine = if ($i + 1 -lt $lines.Count) { $lines[$i + 1] } else { "" }
                if ($nextLine -match '^\s*\}') {
                    if ($newLines.Count -gt 0) {
                        $newLines[$newLines.Count - 1] = $newLines[$newLines.Count - 1] -replace ',(\s*)$', '$1'
                    }
                }
                continue
            }
            $newLines.Add($line)
        }
        Set-Content $fp ($newLines -join "`n") -NoNewline
    }
    # yarn.lock files - redirect @alpha.apps resolved URLs to Verdaccio
    foreach ($f in $yarnLockFiles) {
        $fp = Join-Path $ROOT $f
        if (-not (Test-Path $fp)) { continue }
        $content = Get-Content $fp -Raw
        if ($content -match 'registry\.npmjs\.org/@alpha\.apps/') {
            $content = $content -replace 'https://registry\.npmjs\.org/@alpha\.apps/', 'http://host.docker.internal:4873/@alpha.apps/'
            # Remove integrity lines for @alpha.apps (hash differs between npmjs and Verdaccio tgz)
            $lines = $content -split "`n"
            $newLines = [System.Collections.Generic.List[string]]::new()
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                if ($i -gt 0 -and $lines[$i-1] -match 'host\.docker\.internal:4873/@alpha\.apps/' -and $line -match '^\s+integrity\s') {
                    continue
                }
                $newLines.Add($line)
            }
            Set-Content $fp ($newLines -join "`n") -NoNewline
        }
    }
    # Source code patches
    foreach ($p in $sourcePatches) {
        $fp = Join-Path $ROOT $p.File
        if (-not (Test-Path $fp)) { continue }
        $content = Get-Content $fp -Raw
        if ($content.Contains($p.Original.Trim()) -and -not $content.Contains($p.Patched.Trim())) {
            $content = $content.Replace($p.Original.Trim(), $p.Patched.Trim())
            Set-Content $fp $content -NoNewline
        }
    }
}

function Revert-Patches {
    # .npmrc files
    foreach ($f in $npmrcFiles) {
        $fp = Join-Path $ROOT $f
        if (Test-Path $fp) { Set-Content $fp $npmrcOriginal -NoNewline }
    }
    # package-lock.json files (git checkout)
    foreach ($f in $lockFiles) {
        $fp = Join-Path $ROOT $f
        $dir = Split-Path $fp -Parent
        if (Test-Path $fp) {
            Push-Location $dir
            git checkout -- "package-lock.json" 2>&1 | Out-Null
            Pop-Location
        }
    }
    # yarn.lock files (git checkout)
    foreach ($f in $yarnLockFiles) {
        $fp = Join-Path $ROOT $f
        $dir = Split-Path $fp -Parent
        if (Test-Path $fp) {
            Push-Location $dir
            git checkout -- "yarn.lock" 2>&1 | Out-Null
            Pop-Location
        }
    }
    # Source code patches
    foreach ($p in $sourcePatches) {
        $fp = Join-Path $ROOT $p.File
        if (-not (Test-Path $fp)) { continue }
        $content = Get-Content $fp -Raw
        if ($content.Contains($p.Patched.Trim())) {
            $content = $content.Replace($p.Patched.Trim(), $p.Original.Trim())
            Set-Content $fp $content -NoNewline
        }
    }
}

function Invoke-ApplyPatches {
    Write-Phase 5 12 "Applying code patches (npmrc + lockfiles + source fix)"

    Write-Step "Patching $($npmrcFiles.Count) .npmrc files -> Verdaccio..."
    Apply-Patches

    # Create website local config (config npm package loads based on NODE_ENV)
    $websiteConfigDir = Join-Path (Join-Path (Join-Path $ROOT "web") "alpha-muvi-website-main") "config"
    $localJson = Join-Path $websiteConfigDir "local.json"
    if ((Test-Path $websiteConfigDir) -and -not (Test-Path $localJson)) {
        Write-Step "Creating website config/local.json..."
        $localConfig = @{
            NEXT_PUBLIC_API_URL                = "http://localhost:3000/api/v1/"
            NEXT_PUBLIC_BASE_URL               = "http://localhost:3002/"
            ONE_SIGNAL_APP_ID                  = ""
            RECAPTCHA_CLIENT_KEY               = ""
            APPLICATION_ID                     = ""
            CLIENT_TOKEN                       = ""
            SERVICE                            = "muvi-website-local"
            CHECKOUT_TOKEN_URL                 = "https://api.sandbox.checkout.com/tokens"
            PAY_FORT_TOKEN_URL                 = "https://sbpaymentservices.payfort.com"
            CHECKOUT_PUBLIC_KEY                = ""
            HYPER_PAY_TOKEN_URL                = "https://eu-test.oppwa.com/v1/checkouts"
            MAP_KEY                            = ""
            GOOGLE_ANALYTICS_ID                = ""
            GOOGLE_TAG_MANAGER_ID              = ""
            SENTRY_ID                          = ""
            MAINTENANCE                        = $false
            MERCHANT_ID_CHECKOUT               = ""
            MERCHANT_ID_HYPER_PAY              = ""
            MERCHANT_ID_PAYFORT                = ""
        } | ConvertTo-Json -Depth 2
        Set-Content $localJson $localConfig -Encoding UTF8
        
        # Add to git's local exclude (won't be pushed to repo)
        $gitExclude = Join-Path (Split-Path $websiteConfigDir -Parent) ".git\info\exclude"
        if (Test-Path $gitExclude) {
            $excludeContent = Get-Content $gitExclude -Raw -ErrorAction SilentlyContinue
            if ($excludeContent -notmatch "config/local\.json") {
                Add-Content -Path $gitExclude -Value "config/local.json"
            }
        }
        
        Write-Ok "Created config/local.json (API -> http://localhost:3000/api/v1/)"
    } elseif (Test-Path $localJson) {
        Write-Ok "Website config/local.json already exists"
    }

    Write-Ok "All $($npmrcFiles.Count + $lockFiles.Count + $sourcePatches.Count) patches applied"
}

# -----------------------------------------------
# PHASE 6: Build Docker images
# -----------------------------------------------
function Build-ServiceImages {
    Write-Phase 6 12 "Building Docker images (this takes a while...)"

    $servicesToBuild = $allNestjsServices
    if ($BuildOnly) {
        $servicesToBuild = $BuildOnly -split "," | ForEach-Object { $_.Trim() }
    }

    $totalServices = $servicesToBuild.Count
    $current = 0
    $failed = @()

    foreach ($svc in $servicesToBuild) {
        $current++
        Write-Step "[$current/$totalServices] Building $svc..."
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        # Stream output directly with --progress plain for line-by-line build log
        $logFile = Join-Path $ROOT "_build-${svc}.log"
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        docker compose --progress plain -f "$COMPOSE" build --no-cache $svc 2>&1 | Tee-Object -FilePath $logFile | ForEach-Object {
            $line = $_.ToString()
            if ($line -match "^#\d+ \[" -or $line -match "^#\d+ DONE" -or $line -match "error|ERROR|Error" -or $line -match "^#\d+ CACHED") {
                Write-Host "        $line" -ForegroundColor DarkGray
            }
        }
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP
        $sw.Stop()
        $duration = [math]::Round($sw.Elapsed.TotalSeconds)

        if ($exitCode -eq 0) {
            Write-Ok "$svc built in ${duration}s"
            Remove-Item $logFile -ErrorAction SilentlyContinue
        } else {
            Write-Fail "$svc failed after ${duration}s"
            $failed += $svc
            Get-Content $logFile | Select-Object -Last 15 | ForEach-Object { Write-Host "        $_" -ForegroundColor Red }
        }
    }

    if ($failed.Count -gt 0) {
        Write-Warn "Failed builds: $($failed -join ', ')"
        Write-Warn "Continuing with available images..."
    }

    # Build a minimal placeholder for offer-service (Go, needs GitLab creds)
    Write-Step "Creating placeholder image for offer-service..."
    $dummyDockerfile = Join-Path $ROOT "_dummy-offer.Dockerfile"
    Set-Content $dummyDockerfile "FROM alpine:latest`nCMD [`"sleep`", `"infinity`"]"
    Invoke-NativeCmd { docker build -t muvi-cinemas-offer-service:latest -f $dummyDockerfile $ROOT } | Out-Null
    Remove-Item $dummyDockerfile -ErrorAction SilentlyContinue
    Write-Ok "Placeholder offer-service image created (gateway dependency)"
}

# -----------------------------------------------
# PHASE 7: Revert patches & Start services
# -----------------------------------------------
function Invoke-RevertAndStart {
    Write-Phase 7 12 "Reverting patches and starting backend services"

    Write-Step "Reverting patches to keep repos clean..."
    Revert-Patches
    Write-Ok "Patches reverted"

    Write-Step "Starting all services (--no-build to skip offer-service rebuild)..."
    Invoke-NativeCmd { docker compose -f $COMPOSE up -d --no-build identity-service main-service payment-service fb-service notification-service offer-service gateway-service } | Out-Null

    Write-Ok "All service containers started"
}

# -----------------------------------------------
# VS Code debug configuration
# -----------------------------------------------
function Install-VsCodeDebugConfig {
    Write-Step "Setting up VS Code debug configuration..."

    $vscodeDir = Join-Path $ROOT ".vscode"
    $launchJson = Join-Path $vscodeDir "launch.json"

    if (Test-Path $launchJson) {
        Write-Ok "launch.json already exists (skipped)"
        return
    }

    if (-not (Test-Path $vscodeDir)) {
        New-Item -ItemType Directory -Path $vscodeDir -Force | Out-Null
    }

    $launchContent = @'
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Attach: Gateway (9229)",
      "type": "node",
      "request": "attach",
      "port": 9229,
      "restart": true,
      "localRoot": "${workspaceFolder}/main-backend-microservices/alpha-muvi-gateway-main",
      "remoteRoot": "/app",
      "sourceMaps": true,
      "skipFiles": ["<node_internals>/**", "**/node_modules/**"]
    },
    {
      "name": "Attach: Identity (9230)",
      "type": "node",
      "request": "attach",
      "port": 9230,
      "restart": true,
      "localRoot": "${workspaceFolder}/main-backend-microservices/alpha-muvi-identity-main",
      "remoteRoot": "/app",
      "sourceMaps": true,
      "skipFiles": ["<node_internals>/**", "**/node_modules/**"]
    },
    {
      "name": "Attach: Main (9231)",
      "type": "node",
      "request": "attach",
      "port": 9231,
      "restart": true,
      "localRoot": "${workspaceFolder}/main-backend-microservices/alpha-muvi-main-main",
      "remoteRoot": "/app",
      "sourceMaps": true,
      "skipFiles": ["<node_internals>/**", "**/node_modules/**"]
    },
    {
      "name": "Attach: Payment (9232)",
      "type": "node",
      "request": "attach",
      "port": 9232,
      "restart": true,
      "localRoot": "${workspaceFolder}/main-backend-microservices/alpha-muvi-payment-main",
      "remoteRoot": "/app",
      "sourceMaps": true,
      "skipFiles": ["<node_internals>/**", "**/node_modules/**"]
    },
    {
      "name": "Attach: FB (9233)",
      "type": "node",
      "request": "attach",
      "port": 9233,
      "restart": true,
      "localRoot": "${workspaceFolder}/main-backend-microservices/alpha-muvi-fb-main",
      "remoteRoot": "/app",
      "sourceMaps": true,
      "skipFiles": ["<node_internals>/**", "**/node_modules/**"]
    },
    {
      "name": "Attach: Notification (9234)",
      "type": "node",
      "request": "attach",
      "port": 9234,
      "restart": true,
      "localRoot": "${workspaceFolder}/main-backend-microservices/alpha-muvi-notification-main",
      "remoteRoot": "/app",
      "sourceMaps": true,
      "skipFiles": ["<node_internals>/**", "**/node_modules/**"]
    }
  ],
  "compounds": [
    {
      "name": "Attach: All Services",
      "configurations": [
        "Attach: Gateway (9229)",
        "Attach: Identity (9230)",
        "Attach: Main (9231)",
        "Attach: Payment (9232)",
        "Attach: FB (9233)",
        "Attach: Notification (9234)"
      ]
    }
  ]
}
'@

    Set-Content -Path $launchJson -Value $launchContent -Encoding UTF8
    Write-Ok "Created .vscode/launch.json (debug attach configs for all services)"
    Write-Ok "Debug ports: Gateway=9229, Identity=9230, Main=9231, Payment=9232, FB=9233, Notification=9234"
}

# -----------------------------------------------
# PHASE 8: Health check
# -----------------------------------------------
function Wait-ForContainerLog($containerName, $pattern, $timeoutSec) {
    if (-not $timeoutSec) { $timeoutSec = 90 }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
        $logs = Invoke-NativeCmd { docker logs $containerName }
        if ($logs | Select-String -SimpleMatch $pattern -Quiet) {
            return $true
        }
        Start-Sleep -Seconds 3
    }
    return $false
}

function Invoke-HealthCheck {
    Write-Phase 8 12 "Health-checking backend services"

    Write-Step "Waiting for services to initialize (NestJS boot + DB sync)..."
    Start-Sleep -Seconds 15

    $allHealthy = $true

    # Check Gateway via HTTP
    foreach ($ep in $healthEndpoints) {
        Write-Host "      Checking $($ep.Name) ($($ep.Url))..." -NoNewline -ForegroundColor Gray
        $healthy = Wait-ForUrl $ep.Url $ep.Timeout $ep.Name
        if ($healthy) {
            Write-Host " OK" -ForegroundColor Green
        } else {
            Write-Host " FAIL" -ForegroundColor Red
            $allHealthy = $false
        }
    }

    # Check gRPC services via docker logs
    foreach ($svc in $grpcServices) {
        Write-Host "      Checking $($svc.Name) ($($svc.Container))..." -NoNewline -ForegroundColor Gray
        $healthy = Wait-ForContainerLog $svc.Container "Nest application successfully started" 90
        if ($healthy) {
            Write-Host " OK" -ForegroundColor Green
        } else {
            Write-Host " FAIL" -ForegroundColor Red
            $allHealthy = $false
        }
    }

    # Quick API smoke test
    Write-Step "API smoke test..."
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:3000/heartbeat" -UseBasicParsing -TimeoutSec 10 -ErrorAction SilentlyContinue
        if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300) {
            Write-Ok "GET /heartbeat -> $($r.StatusCode) (Gateway HTTP stack works)"
        } else {
            Write-Warn "GET /heartbeat -> $($r.StatusCode)"
        }
    } catch {
        $code = ""
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -ge 200 -and $code -lt 500) {
            Write-Ok "GET /heartbeat -> $code (service responding)"
        } else {
            Write-Warn "GET /heartbeat -> not reachable yet"
        }
    }

    Write-Step "Container status:"
    $statusOutput = Invoke-NativeCmd { docker compose -f $COMPOSE ps }
    $statusOutput | ForEach-Object { Write-Host "      $_" -ForegroundColor Gray }

    return $allHealthy
}

# -----------------------------------------------
# PHASE 9: Seed databases (local only)
# -----------------------------------------------
function Invoke-SeedDatabases {
    Write-Phase 9 12 "Seeding databases (identity + main)"

    $GATEWAY = "http://localhost:3000/api/v1"

    # 1. Seed identity (permissions, super-admin, settings, dynamic pages, page metadata, languages)
    #    POST /seeders calls both identity + main seeders via gRPC
    #    Note: The gateway may close the connection before responding, but the seeder still runs on the backend.
    Write-Step "Triggering identity + main seeder via gateway (POST /seeders)..."
    try {
        Invoke-WebRequest -Uri "$GATEWAY/seeders" -Method POST -UseBasicParsing -TimeoutSec 120 -ErrorAction SilentlyContinue | Out-Null
        Write-Ok "Seeder call completed"
    } catch {
        Write-Ok "Seeder triggered (connection may close before response - this is normal)"
    }
    # Give the backend seeders a moment to finish
    Start-Sleep -Seconds 5

    # 2. Always seed permissions (no guard, idempotent findOrCreate)
    Write-Step "Seeding permissions (POST /seeders/seed-permissions)..."
    try {
        Invoke-WebRequest -Uri "$GATEWAY/seeders/seed-permissions" -Method POST -UseBasicParsing -TimeoutSec 60 -ErrorAction SilentlyContinue | Out-Null
        Write-Ok "Permissions seeded"
    } catch {
        Write-Ok "Permissions seeder triggered"
    }
    Start-Sleep -Seconds 3

    # 3. Verify settings data exists via API (works with both local and remote DBs)
    #    Note: Services may connect to external RDS (UAT) - we verify via API, not local postgres
    Write-Step "Verifying settings data via API..."
    $maxRetries = 5
    $settingsOk = $false
    for ($i = 1; $i -le $maxRetries; $i++) {
        try {
            $response = Invoke-WebRequest -Uri "$GATEWAY/settings" -Method GET -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            if ($response.StatusCode -eq 200) {
                Write-Ok "Settings endpoint returned 200 - OK"
                $settingsOk = $true
                break
            }
        } catch {
            $code = ""
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            if ($code -eq 500) {
                Write-Warn "Settings endpoint returned 500 (attempt $i/$maxRetries) - retrying..."
                Start-Sleep -Seconds 3
            } else {
                # Non-500 errors (401, 404, etc.) are acceptable - service is functional
                Write-Ok "Settings endpoint returned $code - API is functional"
                $settingsOk = $true
                break
            }
        }
    }
    if (-not $settingsOk) {
        Write-Warn "Settings verification had issues - continuing anyway (services may still work)"
    }

    # 4. Quick smoke test: send-otp should not 500 anymore
    Write-Step "Smoke-testing POST /auth/send-otp..."
    try {
        $body = '{"phoneNumber":"+966500000000"}'
        $r = Invoke-WebRequest -Uri "$GATEWAY/auth/send-otp" -Method POST -Body $body -ContentType "application/json" -UseBasicParsing -TimeoutSec 10 -ErrorAction SilentlyContinue
        Write-Ok "send-otp -> $($r.StatusCode) (API is functional)"
    } catch {
        $code = ""
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -and $code -ne 500) {
            Write-Ok "send-otp -> $code (API is functional, non-500 response)"
        } else {
            Write-Warn "send-otp -> $code (may still have issues)"
        }
    }
}

# -----------------------------------------------
# PHASE 10: Start frontend services
# -----------------------------------------------
function Invoke-StartFrontend {
    Write-Phase 10 12 "Starting frontend services (Website + CMS)"

    Write-Step "Starting website and CMS containers..."
    Write-Host "      (First start runs 'yarn install' inside containers - may take a few minutes)" -ForegroundColor Gray
    Invoke-NativeCmd { docker compose -f $COMPOSE up -d website cms } | Out-Null
    Write-Ok "Frontend containers started"

    Write-Step "Website:  http://localhost:3002  (Next.js)"
    Write-Step "CMS:      http://localhost:5173  (Vite)"
}

# -----------------------------------------------
# PHASE 11: Frontend health check
# -----------------------------------------------
function Invoke-FrontendHealthCheck {
    Write-Phase 11 12 "Verifying frontend services"

    $frontendHealthy = $true

    # Wait for website (Next.js takes a while to compile on first load)
    Write-Host "      Waiting for Website (Next.js cold start can take 30-60s)..." -NoNewline -ForegroundColor Gray
    $websiteReady = $false
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 120) {
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:3002" -UseBasicParsing -TimeoutSec 5 -ErrorAction SilentlyContinue
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) {
                $websiteReady = $true
                break
            }
        } catch {
            $code = ""
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            if ($code -ge 200 -and $code -lt 500) {
                $websiteReady = $true
                break
            }
        }
        Start-Sleep -Seconds 3
    }
    if ($websiteReady) {
        Write-Host " OK ($([int]$sw.Elapsed.TotalSeconds)s)" -ForegroundColor Green
    } else {
        Write-Host " WAITING" -ForegroundColor Yellow
        Write-Warn "Website not responding yet - may still be installing deps. Check: docker logs muvi-website"
        $frontendHealthy = $false
    }

    # Wait for CMS (Vite starts fast)
    Write-Host "      Waiting for CMS (Vite)..." -NoNewline -ForegroundColor Gray
    $cmsReady = $false
    $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw2.Elapsed.TotalSeconds -lt 90) {
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:5173" -UseBasicParsing -TimeoutSec 5 -ErrorAction SilentlyContinue
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) {
                $cmsReady = $true
                break
            }
        } catch {
            $code = ""
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            if ($code -ge 200 -and $code -lt 500) {
                $cmsReady = $true
                break
            }
        }
        Start-Sleep -Seconds 3
    }
    if ($cmsReady) {
        Write-Host " OK ($([int]$sw2.Elapsed.TotalSeconds)s)" -ForegroundColor Green
    } else {
        Write-Host " WAITING" -ForegroundColor Yellow
        Write-Warn "CMS not responding yet - check: docker logs muvi-cms"
        $frontendHealthy = $false
    }

    return $frontendHealthy
}

# -----------------------------------------------
# PHASE 12: IDE Setup (node_modules + dist for debugging)
# -----------------------------------------------
function Invoke-IdeSetup {
    Write-Phase 12 12 "Setting up IDE debugging support"

    $services = @(
        @{ Name = "Gateway";      Dir = "alpha-muvi-gateway-main"; Container = "muvi-gateway" },
        @{ Name = "Identity";     Dir = "alpha-muvi-identity-main"; Container = "muvi-identity" },
        @{ Name = "Main";         Dir = "alpha-muvi-main-main"; Container = "muvi-main" },
        @{ Name = "Payment";      Dir = "alpha-muvi-payment-main"; Container = "muvi-payment" },
        @{ Name = "FB";           Dir = "alpha-muvi-fb-main"; Container = "muvi-fb" },
        @{ Name = "Notification"; Dir = "alpha-muvi-notification-main"; Container = "muvi-notification" }
    )

    # Part A: Install node_modules locally for IntelliSense
    Write-Host "      Installing node_modules (IntelliSense, go-to-definition)..." -ForegroundColor Gray

    foreach ($svc in $services) {
        $svcDir = Join-Path (Join-Path $ROOT "main-backend-microservices") $svc.Dir
        $nmDir  = Join-Path $svcDir "node_modules"

        if (Test-Path (Join-Path $nmDir "@nestjs\common")) {
            Write-Host "        [OK] $($svc.Name)" -ForegroundColor Green
            continue
        }

        Write-Host "        [..] $($svc.Name)..." -ForegroundColor Yellow -NoNewline

        Push-Location $svcDir

        # Strip integrity hashes (Verdaccio tarballs have different checksums)
        node -e "const fs=require('fs');const p=JSON.parse(fs.readFileSync('package-lock.json','utf8'));function s(o){if(!o)return;if(o.integrity)delete o.integrity;if(o.dependencies)Object.values(o.dependencies).forEach(s);if(o.packages)Object.values(o.packages).forEach(s);}s(p);fs.writeFileSync('package-lock.json',JSON.stringify(p,null,2));"

        # Install with Verdaccio (npm warnings go to stderr, suppress them)
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
        npm install --ignore-scripts --registry http://localhost:4873 *>$null
        $ErrorActionPreference = $prevEAP

        # Revert package-lock.json
        git checkout -- package-lock.json 2>$null

        Pop-Location

        if (Test-Path (Join-Path $nmDir "@nestjs\common")) {
            Write-Host " OK" -ForegroundColor Green
        } else {
            Write-Host " FAILED" -ForegroundColor Red
        }
    }

    # Part B: Copy dist folders for source map debugging
    Write-Host "      Copying dist folders (debugger source maps)..." -ForegroundColor Gray

    foreach ($svc in $services) {
        $svcDir = Join-Path (Join-Path $ROOT "main-backend-microservices") $svc.Dir
        $distDir = Join-Path $svcDir "dist"

        # Check if container is running
        $running = docker ps --filter "name=$($svc.Container)" --format "{{.Names}}" 2>$null
        if (-not $running) {
            Write-Host "        [SKIP] $($svc.Name) - container not running" -ForegroundColor Yellow
            continue
        }

        # Copy dist folder from container
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
        docker cp "$($svc.Container):/app/dist" $svcDir 2>$null
        $ErrorActionPreference = $prevEAP

        if (Test-Path (Join-Path $distDir "src")) {
            Write-Host "        [OK] $($svc.Name)" -ForegroundColor Green
        } else {
            Write-Host "        [!!] $($svc.Name)" -ForegroundColor Red
        }
    }

    Write-Host "      IDE setup complete - breakpoints ready!" -ForegroundColor Green
}

# -----------------------------------------------
# Quick Actions (up / down / restart / seed / status / logs)
# -----------------------------------------------
function Invoke-QuickUp {
    Write-Host "`n  Starting all services (backend + frontend)..." -ForegroundColor Cyan
    docker compose -f $COMPOSE up -d
    Write-Host ""
    docker compose -f $COMPOSE ps
    Write-Host "`n  All services started." -ForegroundColor Green
    Write-Host "  Gateway:  http://localhost:3000" -ForegroundColor White
    Write-Host "  Website:  http://localhost:3002" -ForegroundColor White
    Write-Host "  CMS:      http://localhost:5173" -ForegroundColor White
}

function Invoke-QuickDown {
    Write-Host "`n  Stopping all services..." -ForegroundColor Cyan
    docker compose -f $COMPOSE down
    Write-Host "  All services stopped." -ForegroundColor Green
}

function Invoke-QuickRestart {
    if ($BuildOnly) {
        Write-Host "`n  Restarting $BuildOnly..." -ForegroundColor Cyan
        docker compose -f $COMPOSE restart $BuildOnly
    } else {
        Write-Host "`n  Restarting all services..." -ForegroundColor Cyan
        docker compose -f $COMPOSE restart
    }
    docker compose -f $COMPOSE ps
    Write-Host "  Done." -ForegroundColor Green
}

function Invoke-QuickStatus {
    Write-Host "`n  Container status:" -ForegroundColor Cyan
    docker compose -f $COMPOSE ps -a
}

function Invoke-QuickLogs {
    if ($BuildOnly) {
        Write-Host "`n  Tailing logs for $BuildOnly (Ctrl+C to stop)..." -ForegroundColor Cyan
        docker compose -f $COMPOSE logs -f --tail 100 $BuildOnly
    } else {
        Write-Host "`n  Tailing all logs (Ctrl+C to stop)..." -ForegroundColor Cyan
        docker compose -f $COMPOSE logs -f --tail 50
    }
}

function Invoke-QuickPublish {
    Write-Host "`n  Building and publishing shared packages to Verdaccio..." -ForegroundColor Cyan
    $packagesDir = Join-Path $ROOT 'packages'
    $registry = 'http://localhost:4873'
    $targets = @(
        @{ Name = 'muvi-shared';    Dir = Join-Path $packagesDir 'muvi-shared';    Out = 'dist' },
        @{ Name = 'nestjs-common';  Dir = Join-Path $packagesDir 'nestjs-common';  Out = 'lib' },
        @{ Name = 'react-common';   Dir = Join-Path $packagesDir 'react-common';   Out = 'dist'; PreBuilt = $true }
    )
    if ($BuildOnly) {
        $targets = $targets | Where-Object { $_.Name -eq $BuildOnly }
        if (-not $targets) { Write-Host "  Unknown package: $BuildOnly. Use 'muvi-shared', 'nestjs-common', or 'react-common'." -ForegroundColor Red; return }
    }
    foreach ($pkg in $targets) {
        if (-not (Test-Path $pkg.Dir)) { Write-Host "  [SKIP] $($pkg.Name) - not found" -ForegroundColor Yellow; continue }
        Push-Location $pkg.Dir
        if (-not $pkg.PreBuilt) {
            if (-not (Test-Path 'node_modules')) {
                Write-Host "  Installing deps for $($pkg.Name)..." -ForegroundColor Yellow
                npm install --quiet 2>&1 | Out-Null
            }
            Write-Host "  Building $($pkg.Name)..." -ForegroundColor Yellow
            npm run build 2>&1 | Out-Null
        } else {
            Write-Host "  $($pkg.Name) is pre-built (dist already present)" -ForegroundColor Gray
        }
        Write-Host "  Publishing $($pkg.Name) to $registry..." -ForegroundColor Yellow
        $publishOut = npm publish --registry $registry 2>&1
        if ($LASTEXITCODE -ne 0) {
            if ($publishOut -match 'cannot publish over|EPUBLISHCONFLICT') {
                Write-Host "  $($pkg.Name): version already exists (use npm version patch first)" -ForegroundColor Yellow
            } else {
                Write-Host "  $($pkg.Name): publish failed" -ForegroundColor Red
                $publishOut | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
            }
        } else {
            $ver = (Get-Content package.json | ConvertFrom-Json).version
            Write-Host "  $($pkg.Name)@$ver published" -ForegroundColor Green
        }
        Pop-Location
    }
}

function Invoke-QuickPatch {
    if ($BuildOnly -eq 'revert') {
        Write-Host "`n  Reverting all patches..." -ForegroundColor Cyan
        Revert-Patches
        Write-Host "  Done. Repos are clean." -ForegroundColor Green
    } elseif ($BuildOnly -eq 'status') {
        Write-Host "`n  Patch status:" -ForegroundColor Cyan
        foreach ($f in $npmrcFiles) {
            $fp = Join-Path $ROOT $f
            if (-not (Test-Path $fp)) { Write-Host "  [NOT FOUND] $f" -ForegroundColor Red; continue }
            $c = (Get-Content $fp -Raw).Trim()
            $s = if ($c -eq $npmrcPatched) { "APPLIED" } else { "original" }
            Write-Host "  [$s] $f" -ForegroundColor $(if ($s -eq "APPLIED") { "Green" } else { "Yellow" })
        }
    } else {
        Write-Host "`n  Applying all patches..." -ForegroundColor Cyan
        Apply-Patches
        Write-Host "  Done. $($npmrcFiles.Count + $lockFiles.Count + $sourcePatches.Count) patches applied." -ForegroundColor Green
        Write-Host "  Revert with: .\muvi-up.ps1 patch -BuildOnly revert" -ForegroundColor Gray
    }
}

function Invoke-QuickFrontend {
    Write-Host "`n  Starting frontend services..." -ForegroundColor Cyan

    # Verify backend is running
    Write-Host "  Checking if backend (gateway) is up..." -ForegroundColor Gray
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:3000/heartbeat" -UseBasicParsing -TimeoutSec 5 -ErrorAction SilentlyContinue
        Write-Host "  Gateway is running (port 3000)" -ForegroundColor Green
    } catch {
        $code = ""
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -ge 200 -and $code -lt 500) {
            Write-Host "  Gateway is running (port 3000)" -ForegroundColor Green
        } else {
            Write-Host "  WARNING: Gateway does not appear to be running on port 3000" -ForegroundColor Yellow
            Write-Host "  Frontend needs the backend API. Run '.\muvi-up.ps1 up' first or do a full bootstrap." -ForegroundColor Yellow
            Write-Host ""
            $confirm = Read-Host "  Continue anyway? (y/N)"
            if ($confirm -ne 'y' -and $confirm -ne 'Y') { return }
        }
    }

    # Clone frontend repos if needed
    if (-not (Test-Path $WEB_DIR)) {
        New-Item -ItemType Directory -Path $WEB_DIR -Force | Out-Null
    }
    foreach ($repo in $webReposToClone) {
        $targetDir = Join-Path $WEB_DIR $repo.Name
        if (-not (Test-Path $targetDir)) {
            Write-Host "  Cloning $($repo.Name)..." -ForegroundColor Yellow
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            
            # Retry logic for transient network failures
            $maxRetries = 3
            $retryDelay = 5
            $cloneExit = 1
            
            for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
                if ($attempt -gt 1) {
                    Write-Host "  Retry $attempt/$maxRetries for $($repo.Name) in $retryDelay seconds..." -ForegroundColor Yellow
                    Start-Sleep -Seconds $retryDelay
                    if (Test-Path $targetDir) {
                        Remove-Item $targetDir -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
                
                git clone $repo.Url $targetDir 2>&1 | Out-Null
                $cloneExit = $LASTEXITCODE
                
                if ($cloneExit -eq 0) {
                    break
                }
            }
            
            $ErrorActionPreference = $prevEAP
            if ($cloneExit -eq 0) {
                Write-Host "  $($repo.Name) cloned" -ForegroundColor Green
            } else {
                Write-Host "  $($repo.Name) clone FAILED" -ForegroundColor Red
                return
            }
        } else {
            Write-Host "  $($repo.Name) already exists" -ForegroundColor Gray
        }
    }

    # Ensure Verdaccio is running (CMS needs it for @alpha.apps/react-common)
    $verdaccioUp = $false
    try {
        $v = Invoke-WebRequest -Uri "http://localhost:4873" -UseBasicParsing -TimeoutSec 3 -ErrorAction SilentlyContinue
        if ($v.StatusCode -eq 200) { $verdaccioUp = $true }
    } catch {}
    if (-not $verdaccioUp) {
        Write-Host "  Starting Verdaccio (needed for CMS packages)..." -ForegroundColor Yellow
        docker compose -f $COMPOSE up -d verdaccio 2>&1 | Out-Null
        Start-Sleep -Seconds 5
    }

    # Patch web .npmrc files for Verdaccio
    foreach ($f in @("web\alpha-muvi-cms-main\.npmrc", "web\alpha-muvi-website-main\.npmrc")) {
        $fp = Join-Path $ROOT $f
        if (Test-Path $fp) {
            $c = (Get-Content $fp -Raw).Trim()
            if ($c -ne $npmrcPatched) {
                Set-Content $fp $npmrcPatched -NoNewline
                Write-Host "  Patched $f -> Verdaccio" -ForegroundColor Gray
            }
        }
    }

    # Patch CMS yarn.lock to redirect @alpha.apps URLs to Verdaccio
    foreach ($f in $yarnLockFiles) {
        $fp = Join-Path $ROOT $f
        if (Test-Path $fp) {
            $content = Get-Content $fp -Raw
            if ($content -match 'registry\.npmjs\.org/@alpha\.apps/') {
                $content = $content -replace 'https://registry\.npmjs\.org/@alpha\.apps/', 'http://host.docker.internal:4873/@alpha.apps/'
                # Remove integrity lines for @alpha.apps packages (hash differs between npmjs and our Verdaccio tgz)
                $lines = $content -split "`n"
                $newLines = [System.Collections.Generic.List[string]]::new()
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    $line = $lines[$i]
                    # Skip integrity line if previous line is a resolved URL pointing to Verdaccio @alpha.apps
                    if ($i -gt 0 -and $lines[$i-1] -match 'host\.docker\.internal:4873/@alpha\.apps/' -and $line -match '^\s+integrity\s') {
                        continue
                    }
                    $newLines.Add($line)
                }
                Set-Content $fp ($newLines -join "`n") -NoNewline
                Write-Host "  Patched $f -> Verdaccio URLs" -ForegroundColor Gray
            }
        }
    }

    # Create website local config if missing
    $websiteConfigDir = Join-Path (Join-Path (Join-Path $ROOT "web") "alpha-muvi-website-main") "config"
    $localJson = Join-Path $websiteConfigDir "local.json"
    if ((Test-Path $websiteConfigDir) -and -not (Test-Path $localJson)) {
        $localConfig = @{
            NEXT_PUBLIC_API_URL  = "http://localhost:3000/api/v1/"
            NEXT_PUBLIC_BASE_URL = "http://localhost:3002/"
        } | ConvertTo-Json -Depth 2
        Set-Content $localJson $localConfig -Encoding UTF8
        
        # Add to git's local exclude (won't be pushed to repo)
        $gitExclude = Join-Path (Split-Path $websiteConfigDir -Parent) ".git\info\exclude"
        if (Test-Path $gitExclude) {
            $excludeContent = Get-Content $gitExclude -Raw -ErrorAction SilentlyContinue
            if ($excludeContent -notmatch "config/local\.json") {
                Add-Content -Path $gitExclude -Value "config/local.json"
            }
        }
        
        Write-Host "  Created website config/local.json" -ForegroundColor Gray
    }

    # Start frontend containers
    docker compose -f $COMPOSE up -d website cms
    Write-Host ""
    docker compose -f $COMPOSE ps website cms
    Write-Host ""
    Write-Host "  Frontend started." -ForegroundColor Green
    Write-Host "  Website:  http://localhost:3002  (first load may take 30-60s for yarn install + Next.js compile)" -ForegroundColor White
    Write-Host "  CMS:      http://localhost:5173" -ForegroundColor White
    Write-Host ""
    Write-Host "  Tip: .\ muvi-up.ps1 logs -BuildOnly website   # tail website logs" -ForegroundColor Gray
    Write-Host "       .\ muvi-up.ps1 logs -BuildOnly cms       # tail CMS logs" -ForegroundColor Gray
}

# -----------------------------------------------
# IDE: Install node_modules locally for IntelliSense & debugging
# -----------------------------------------------
function Invoke-QuickIde {
    Write-Host "`n  Installing node_modules locally for IDE support..." -ForegroundColor Cyan
    Write-Host "  (IntelliSense, go-to-definition, breakpoints)`n" -ForegroundColor Gray

    # Ensure Verdaccio is running (needed for @alpha.apps packages)
    $verdaccioUp = $false
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:4873" -UseBasicParsing -TimeoutSec 3 -ErrorAction SilentlyContinue
        if ($r.StatusCode -eq 200) { $verdaccioUp = $true }
    } catch {}
    if (-not $verdaccioUp) {
        Write-Host "  [!] Verdaccio not running. Start services first: .\muvi-up.ps1 up" -ForegroundColor Red
        return
    }

    $services = @(
        @{ Name = "Gateway";      Dir = "alpha-muvi-gateway-main" },
        @{ Name = "Identity";     Dir = "alpha-muvi-identity-main" },
        @{ Name = "Main";         Dir = "alpha-muvi-main-main" },
        @{ Name = "Payment";      Dir = "alpha-muvi-payment-main" },
        @{ Name = "FB";           Dir = "alpha-muvi-fb-main" },
        @{ Name = "Notification"; Dir = "alpha-muvi-notification-main" }
    )

    foreach ($svc in $services) {
        $svcDir = Join-Path (Join-Path $ROOT "main-backend-microservices") $svc.Dir
        $nmDir  = Join-Path $svcDir "node_modules"

        if (Test-Path (Join-Path $nmDir "@nestjs\common")) {
            Write-Host "  [OK] $($svc.Name) - already installed" -ForegroundColor Green
            continue
        }

        Write-Host "  [..] $($svc.Name) - installing..." -ForegroundColor Yellow -NoNewline

        Push-Location $svcDir

        # Strip integrity hashes from package-lock.json (our Verdaccio tarballs have different checksums)
        $lockFile = Join-Path $svcDir "package-lock.json"
        node -e "const fs=require('fs');const p=JSON.parse(fs.readFileSync('package-lock.json','utf8'));function s(o){if(!o)return;if(o.integrity)delete o.integrity;if(o.dependencies)Object.values(o.dependencies).forEach(s);if(o.packages)Object.values(o.packages).forEach(s);}s(p);fs.writeFileSync('package-lock.json',JSON.stringify(p,null,2));"

        # Install with Verdaccio (npm warnings go to stderr, suppress them)
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
        npm install --ignore-scripts --registry http://localhost:4873 *>$null
        $ErrorActionPreference = $prevEAP

        # Revert package-lock.json so git stays clean
        git checkout -- package-lock.json 2>$null

        Pop-Location

        if (Test-Path (Join-Path $nmDir "@nestjs\common")) {
            Write-Host "`r  [OK] $($svc.Name) - installed                " -ForegroundColor Green
        } else {
            Write-Host "`r  [!!] $($svc.Name) - FAILED                  " -ForegroundColor Red
        }
    }

    # Copy dist folders from containers for source map debugging
    Write-Host ""
    Write-Host "  Copying dist folders (source maps) from containers..." -ForegroundColor Cyan

    $containerMap = @{
        "Gateway"      = "muvi-gateway"
        "Identity"     = "muvi-identity"
        "Main"         = "muvi-main"
        "Payment"      = "muvi-payment"
        "FB"           = "muvi-fb"
        "Notification" = "muvi-notification"
    }

    foreach ($svc in $services) {
        $containerName = $containerMap[$svc.Name]
        $svcDir = Join-Path (Join-Path $ROOT "main-backend-microservices") $svc.Dir
        $distDir = Join-Path $svcDir "dist"

        # Check if container is running
        $running = docker ps --filter "name=$containerName" --format "{{.Names}}" 2>$null
        if (-not $running) {
            Write-Host "  [SKIP] $($svc.Name) - container not running" -ForegroundColor Yellow
            continue
        }

        # Copy dist folder from container
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
        docker cp "${containerName}:/app/dist" $svcDir 2>$null
        $ErrorActionPreference = $prevEAP

        if (Test-Path (Join-Path $distDir "src")) {
            Write-Host "  [OK] $($svc.Name) - dist copied" -ForegroundColor Green
        } else {
            Write-Host "  [!!] $($svc.Name) - dist copy failed" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host "  IDE setup complete!" -ForegroundColor Green
    Write-Host "  - node_modules: IntelliSense, go-to-definition" -ForegroundColor Gray
    Write-Host "  - dist folders: Debugger source maps" -ForegroundColor Gray
    Write-Host "  - launch.json:  'Attach: All Services' for cross-service debugging" -ForegroundColor Gray
    Write-Host ""
}

# -----------------------------------------------
# Developer Portal: Start the dev portal server
# -----------------------------------------------
function Invoke-QuickPortal {
    Write-Host "`n  Starting Developer Portal..." -ForegroundColor Cyan

    $portalServer = Join-Path (Join-Path $ROOT "dev-portal") "server.js"
    if (-not (Test-Path $portalServer)) {
        Write-Host "  [!] Portal server not found: $portalServer" -ForegroundColor Red
        return
    }

    # Check if portal is already running
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:4000" -UseBasicParsing -TimeoutSec 2 -ErrorAction SilentlyContinue
        if ($response.StatusCode -eq 200) {
            Write-Host "  [OK] Developer Portal already running at http://localhost:4000" -ForegroundColor Green
            Start-Process "http://localhost:4000"
            return
        }
    } catch {}

    # Start the portal server in a new window
    Start-Process -FilePath "node" -ArgumentList "`"$portalServer`"" -WorkingDirectory $ROOT

    # Wait for it to start
    Write-Host "  Waiting for portal to start..." -ForegroundColor Gray
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 10) {
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:4000" -UseBasicParsing -TimeoutSec 2 -ErrorAction SilentlyContinue
            if ($r.StatusCode -eq 200) {
                Write-Host "  [OK] Developer Portal running at http://localhost:4000" -ForegroundColor Green
                Start-Process "http://localhost:4000"
                return
            }
        } catch {}
        Start-Sleep -Milliseconds 500
    }

    Write-Host "  [!] Portal may still be starting - check http://localhost:4000" -ForegroundColor Yellow
}

# -----------------------------------------------
# MAIN
# -----------------------------------------------

# Handle quick actions first
if ($Action) {
    switch ($Action) {
        "up"       { Invoke-QuickUp }
        "down"     { Invoke-QuickDown }
        "restart"  { Invoke-QuickRestart }
        "seed"     { Invoke-SeedDatabases }
        "status"   { Invoke-QuickStatus }
        "logs"     { Invoke-QuickLogs }
        "publish"  { Invoke-QuickPublish }
        "patch"    { Invoke-QuickPatch }
        "frontend" { Invoke-QuickFrontend }
        "ide"      { Invoke-QuickIde }
        "portal"   { Invoke-QuickPortal }
    }
    exit 0
}

# Full bootstrap
Write-Host ""
Write-Host ("*" * 70) -ForegroundColor Magenta
Write-Host "  MUVI CINEMAS - Full Bootstrap" -ForegroundColor Magenta
Write-Host "  From scratch -> all services running + seeded" -ForegroundColor Magenta
Write-Host ("*" * 70) -ForegroundColor Magenta
Write-Host ""
Write-Host "  Quick commands (for day-to-day use):" -ForegroundColor Gray
Write-Host "    .\muvi-up.ps1 up        Start services" -ForegroundColor Gray
Write-Host "    .\muvi-up.ps1 down      Stop services" -ForegroundColor Gray
Write-Host "    .\muvi-up.ps1 restart   Restart services" -ForegroundColor Gray
Write-Host "    .\muvi-up.ps1 seed      Re-seed databases" -ForegroundColor Gray
Write-Host "    .\muvi-up.ps1 status    Check status" -ForegroundColor Gray
Write-Host "    .\muvi-up.ps1 logs      Tail logs" -ForegroundColor Gray
Write-Host "    .\muvi-up.ps1 publish   Build and publish packages" -ForegroundColor Gray
Write-Host "    .\muvi-up.ps1 patch     Apply/revert dev patches" -ForegroundColor Gray
Write-Host "    .\muvi-up.ps1 frontend  Start frontend only" -ForegroundColor Gray
Write-Host "    .\muvi-up.ps1 ide       Sync IDE debug files" -ForegroundColor Gray
Write-Host "    .\muvi-up.ps1 portal    Open Developer Portal" -ForegroundColor Gray
Write-Host ""

try {
    # Phase 1
    if (-not $SkipClone) {
        Invoke-CloneRepos
    } else {
        Write-Host "`n  [SKIP] Clone step skipped" -ForegroundColor Yellow
    }

    # Phase 2
    if (-not $SkipDestroy) {
        Invoke-Destroy
    } else {
        Write-Host "`n  [SKIP] Destroy step skipped" -ForegroundColor Yellow
    }

    # Phase 3
    Start-Infrastructure

    # Phase 4
    Restore-VerdaccioPackages

    # Phase 5
    Invoke-ApplyPatches

    # Phase 6
    if (-not $SkipBuild) {
        Build-ServiceImages
    } else {
        Write-Host "`n  [SKIP] Build step skipped (using existing images)" -ForegroundColor Yellow
    }

    # Phase 7
    Invoke-RevertAndStart

    # VS Code debug config
    Install-VsCodeDebugConfig

    # Phase 8
    $allHealthy = Invoke-HealthCheck

    # Phase 9
    Invoke-SeedDatabases

    # Phase 10-11: Frontend
    $frontendHealthy = $true
    if (-not $SkipFrontend) {
        Invoke-StartFrontend
        $frontendHealthy = Invoke-FrontendHealthCheck
    } else {
        Write-Host "`n  [SKIP] Frontend setup skipped (-SkipFrontend)" -ForegroundColor Yellow
    }

    # Phase 12: IDE Setup (node_modules + dist for debugging)
    Invoke-IdeSetup

    # Final summary
    $elapsed = [int]((Get-Date) - $script:startTime).TotalSeconds
    $minutes = [math]::Floor($elapsed / 60)
    $seconds = $elapsed % 60

    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Green
    Write-Host ""
    if ($allHealthy -and $frontendHealthy) {
        Write-Host "  ALL SERVICES ARE UP AND RUNNING!" -ForegroundColor Green
    } elseif ($allHealthy) {
        Write-Host "  BACKEND SERVICES ARE UP! (frontend may still be starting)" -ForegroundColor Yellow
    } else {
        Write-Host "  SERVICES STARTED (some health checks failed)" -ForegroundColor Yellow
        Write-Host "  Check: docker compose logs [service-name]" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  ── Backend ──────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "  Gateway API:    http://localhost:3000" -ForegroundColor White
    Write-Host "  Identity:       http://localhost:5001  (gRPC)" -ForegroundColor White
    Write-Host "  Main:           http://localhost:5002  (gRPC)" -ForegroundColor White
    Write-Host "  Payment:        http://localhost:5003  (gRPC)" -ForegroundColor White
    Write-Host "  FB:             http://localhost:5004  (gRPC)" -ForegroundColor White
    Write-Host "  Notification:   http://localhost:5005  (gRPC)" -ForegroundColor White
    Write-Host ""
    Write-Host "  ── Frontend ─────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "  Website:        http://localhost:3002  (Next.js)" -ForegroundColor White
    Write-Host "  CMS:            http://localhost:5173  (Vite)" -ForegroundColor White
    Write-Host ""
    Write-Host "  ── Developer Tools ──────────────────────────────" -ForegroundColor DarkGray
    Write-Host "  Dev Portal:     http://localhost:4000  (All links, Docker mgmt)" -ForegroundColor Cyan
    Write-Host "  Verdaccio:      http://localhost:4873" -ForegroundColor White
    Write-Host "  PgAdmin:        http://localhost:5051" -ForegroundColor White
    Write-Host "  Postgres:       localhost:5432" -ForegroundColor White
    Write-Host "  Redis:          localhost:6379" -ForegroundColor White
    Write-Host ""
    Write-Host "  Total time: ${minutes}m ${seconds}s" -ForegroundColor Cyan
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Green
    Write-Host ""
    Write-Host "  Day-to-day commands:" -ForegroundColor Gray
    Write-Host "    .\muvi-up.ps1 up                               # Start" -ForegroundColor Gray
    Write-Host "    .\muvi-up.ps1 down                             # Stop" -ForegroundColor Gray
    Write-Host "    .\muvi-up.ps1 restart                          # Restart all" -ForegroundColor Gray
    Write-Host "    .\muvi-up.ps1 restart -BuildOnly gateway-service  # Restart one" -ForegroundColor Gray
    Write-Host "    .\muvi-up.ps1 seed                             # Re-seed DBs" -ForegroundColor Gray
    Write-Host "    .\muvi-up.ps1 logs                             # Tail logs" -ForegroundColor Gray
    Write-Host "    .\muvi-up.ps1 status                           # Container status" -ForegroundColor Gray
    Write-Host "    .\muvi-up.ps1 portal                           # Open Developer Portal" -ForegroundColor Gray
    Write-Host "    .\muvi-up.ps1 ide                              # Re-sync IDE debugging files" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Debugging (ready to use!):" -ForegroundColor Cyan
    Write-Host "    1. Press Ctrl+Shift+D (Run and Debug panel)" -ForegroundColor Gray
    Write-Host "    2. Select 'Attach: All Services' from dropdown" -ForegroundColor Gray
    Write-Host "    3. Press F5 - breakpoints work across all microservices!" -ForegroundColor Gray
    Write-Host ""

    # Start Developer Portal server and open in browser
    Write-Host "  Starting Developer Portal..." -ForegroundColor Cyan
    $portalServer = Join-Path (Join-Path $ROOT "dev-portal") "server.js"
    if (Test-Path $portalServer) {
        Start-Process -FilePath "node" -ArgumentList "`"$portalServer`"" -WorkingDirectory $ROOT
        Start-Sleep -Seconds 2
        Start-Process "http://localhost:4000"
        Write-Host "  Developer Portal: http://localhost:4000" -ForegroundColor Green
    }

    # Open website in default browser
    if (-not $SkipFrontend) {
        Write-Host "  Opening website (http://localhost:3002)..." -ForegroundColor Cyan
        Start-Process "http://localhost:3002"
    }
}
catch {
    $elapsed = [int]((Get-Date) - $script:startTime).TotalSeconds
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Red
    Write-Host "  BOOTSTRAP FAILED at ${elapsed}s" -ForegroundColor Red
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ("=" * 70) -ForegroundColor Red

    # Try to revert patches if they were applied
    $patchTarget = Join-Path (Join-Path $ROOT "main-backend-microservices") "alpha-muvi-identity-main"
    if (Test-Path (Join-Path $patchTarget ".npmrc")) {
        Write-Host ""
        Write-Host "  Reverting patches to keep repos clean..." -ForegroundColor Yellow
        try {
            Revert-Patches
            Write-Host "  Patches reverted." -ForegroundColor Yellow
        }
        catch {
            Write-Host "  Could not revert patches: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    exit 1
}
