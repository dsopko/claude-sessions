<#
  Builds a self-contained sessions-demo.html with synthetic data (no real
  transcripts) so the viewer can be shown off / screenshotted. Throwaway.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$now  = Get-Date

function S($proj, $cwd, $branch, $title, $prompt, $ago, $unit, $dur, $size, $fork, $ver) {
    $last = if ($unit -eq 'h') { $now.AddHours(-$ago) } elseif ($unit -eq 'm') { $now.AddMinutes(-$ago) } else { $now.AddDays(-$ago) }
    $start = if ($dur) { $last.AddMinutes(-$dur) } else { $last }
    [pscustomobject][ordered]@{
        sessionId    = [guid]::NewGuid().ToString()
        title        = $title
        firstPrompt  = $prompt
        cwd          = $cwd
        projectDir   = $proj
        gitBranch    = $branch
        version      = $ver
        startTime    = $start.ToUniversalTime().ToString('o')
        lastActivity = $last.ToUniversalTime().ToString('o')
        durationMin  = $dur
        sizeBytes    = $size
        isFork       = $fork
        filePath     = "C:\Users\dev\.claude\projects\$proj\session.jsonl"
    }
}

$web = 'C:\Users\dev\code\aurora-web'; $webK = 'C--Users-dev-code-aurora-web'
$api = 'C:\Users\dev\code\aurora-api'; $apiK = 'C--Users-dev-code-aurora-api'
$inf = 'C:\Users\dev\infra\terraform'; $infK = 'C--Users-dev-infra-terraform'
$dot = 'C:\Users\dev\code\dotfiles';   $dotK = 'C--Users-dev-code-dotfiles'
$gam = 'C:\Users\dev\code\pico-game';  $gamK = 'C--Users-dev-code-pico-game'

$sessions = @(
    S $webK $web 'feat/checkout' 'Checkout redesign' 'Redesign the checkout flow to cut cart abandonment. Start with a single-page address + payment step and validate inline.' 25 'm' 95 482113 $false '1.2.47'
    S $webK $web 'fix/hydration' $null 'Getting a React hydration mismatch warning on the product page, only in production. Help me track down the source.' 2 'h' 38 151204 $false '1.2.47'
    S $webK $web 'main' 'Stripe webhooks' 'Wire up Stripe webhook handling for payment_intent.succeeded and charge.refunded, with idempotency keys.' 6 'h' 131 723880 $true '1.2.46'
    S $webK $web 'feat/checkout' $null 'Add unit tests for the cart reducer covering merge, quantity clamp, and coupon application.' 27 'h' 19 88990 $false '1.2.46'

    S $apiK $api 'feat/rate-limit' 'Rate limiting' 'Implement token-bucket rate limiting middleware backed by Redis, keyed per API token.' 22 'h' 74 341006 $false '1.2.46'
    S $apiK $api 'main' $null 'Migrate the users table to add a soft-delete column and backfill existing rows safely.' 38 'h' 56 210773 $false '1.2.45'
    S $apiK $api 'main' $null 'Why is the /health endpoint returning 503 under load? Walk through the connection pool config.' 3 'd' 12 61240 $false '1.2.45'

    S $infK $inf 'main' 'Staging VPC' 'Stand up a staging VPC with private subnets, a NAT gateway, and tagged route tables in Terraform.' 4 'd' 142 511902 $false '1.2.44'
    S $infK $inf 'main' $null 'terraform plan shows a forced replacement on the RDS instance. What attribute changed and how do I avoid it?' 9 'd' 31 109887 $false '1.2.42'

    S $dotK $dot 'main' $null 'Set up a cross-platform tmux config with sane copy-mode bindings and a minimal status line.' 25 'd' 18 70210 $false '1.2.40'
    S $dotK $dot 'main' 'Neovim LSP' 'Configure nvim LSP for typescript, lua, and go with format-on-save and inlay hints.' 26 'd' 61 231559 $false '1.2.40'

    S $gamK $gam 'main' $null 'Implement A* pathfinding for the enemy AI on a tile grid with weighted terrain.' 27 'd' 44 160338 $false '1.2.39'
    S $gamK $gam 'feat/render' 'Sprite batching' 'Batch sprite draws to cut frame time; we are at 18ms, target is 8ms. Profile first.' 28 'd' 81 291004 $true '1.2.39'
)

$payload = [pscustomobject][ordered]@{
    generated         = $now.ToUniversalTime().ToString('o')
    machine           = 'DEV-WORKSTATION'
    claudeDir         = 'C:\Users\dev\.claude'
    launchEnabled     = $true
    cleanupPeriodDays = 30
    sessions          = $sessions
}
$json = $payload | ConvertTo-Json -Depth 6 -Compress

$html = Get-Content -Path (Join-Path $root 'sessions.html') -Raw
$html = $html.Replace('<script src="data.js"></script>', "<script>window.SESSION_DATA = $json;</script>")
$out = Join-Path $root 'sessions-demo.html'
Set-Content -Path $out -Value $html -Encoding UTF8
Write-Host "Wrote $out ($($sessions.Count) demo sessions)"
