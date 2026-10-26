param(
    [string]$Token = "",
    [string]$WorkspacePath = ""
)

$ErrorActionPreference = "Continue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$BotDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $BotDir "config.json"
$DefaultCascadeConfigPath = Join-Path $BotDir "default_cascade_config.json"
$UploadsDir = Join-Path $BotDir "uploads"

if (-not (Test-Path $UploadsDir)) {
    New-Item -ItemType Directory -Path $UploadsDir -Force | Out-Null
}

# --- Prevent Windows Sleep while Bot is running ---
$SleepCode = @"
using System;
using System.Runtime.InteropServices;
public class PowerHelper {
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);
    public static void KeepAwake() {
        // ES_CONTINUOUS (0x80000000) | ES_SYSTEM_REQUIRED (0x00000001)
        SetThreadExecutionState(0x80000001);
    }
}
"@
try {
    Add-Type -TypeDefinition $SleepCode -ErrorAction SilentlyContinue
    [PowerHelper]::KeepAwake()
} catch {}

Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$httpClient = New-Object System.Net.Http.HttpClient
$httpClient.Timeout = [TimeSpan]::FromSeconds(65)

function U([int]$code) {
    return [char]::ConvertFromUtf32($code)
}

$EMOJI_ROBOT  = U 0x1F916
$EMOJI_CHAT   = U 0x1F4AC
$EMOJI_CHART  = U 0x1F4CA
$EMOJI_NEW    = U 0x1F195
$EMOJI_CAM    = U 0x1F4F8
$EMOJI_STOP   = U 0x1F6D1
$EMOJI_CHECK  = U 0x2705
$EMOJI_GREEN  = U 0x1F7E2
$EMOJI_WHITE  = U 0x26AA
$EMOJI_WAIT   = U 0x23F3
$EMOJI_MIC    = U 0x1F3A4
$EMOJI_IMG    = U 0x1F5BC
$EMOJI_FILE   = U 0x1F4CE
$EMOJI_WARN   = U 0x26A0
$EMOJI_SPARK  = U 0x2728
$EMOJI_TOOL   = U 0x1F527
$EMOJI_BOLT   = U 0x26A1
$EMOJI_BRAIN  = U 0x1F9E0

# --- Single Instance Check (kill old instance if restarting) ---
$PidFile = Join-Path $BotDir "bot.pid"
if (Test-Path $PidFile) {
    try {
        $oldPid = [int](Get-Content $PidFile -Raw).Trim()
        if ($oldPid -ne $PID) {
            $oldProc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
            if ($oldProc -and $oldProc.ProcessName -match "powershell|pwsh") {
                Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 500
            }
        }
    } catch {}
}
$PID | Set-Content $PidFile -Encoding ASCII

$defaultWsDir = Join-Path $env:USERPROFILE ".gemini\antigravity\scratch"
if (-not (Test-Path $defaultWsDir)) { $defaultWsDir = $env:USERPROFILE }
$defaultWsUri = "file:///" + ($defaultWsDir.Replace('\', '/').TrimStart('/'))

# --- Load or Initialize Config ---
$config = @{
    botToken           = ""
    authorizedChatId   = 0
    activeCascadeId    = ""
    selectedModel      = "MODEL_PLACEHOLDER_M418"
    selectedModelLabel = "Gemini 4 Argon (Medium)"
    workspaceUri       = $defaultWsUri
}

if (Test-Path $ConfigPath) {
    try {
        $loaded = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($loaded.botToken) { $config.botToken = [string]$loaded.botToken }
        if ($loaded.authorizedChatId) { $config.authorizedChatId = [long]$loaded.authorizedChatId }
        if ($loaded.activeCascadeId) { $config.activeCascadeId = [string]$loaded.activeCascadeId }
        if ($loaded.selectedModel) { $config.selectedModel = [string]$loaded.selectedModel }
        if ($loaded.selectedModelLabel) { $config.selectedModelLabel = [string]$loaded.selectedModelLabel }
        if ($loaded.workspaceUri) { $config.workspaceUri = [string]$loaded.workspaceUri }
    } catch {}
}

if ($Token -ne "") {
    $config.botToken = $Token.Trim()
}
if ($WorkspacePath -ne "") {
    $resolved = (Resolve-Path $WorkspacePath -ErrorAction SilentlyContinue)
    if ($resolved) {
        $config.workspaceUri = "file:///" + ($resolved.Path.Replace('\', '/').TrimStart('/'))
    }
}

function Save-Config {
    $config | ConvertTo-Json -Depth 5 | Set-Content $ConfigPath -Encoding UTF8
}

if ([string]::IsNullOrWhiteSpace($config.botToken)) {
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "   ANTIGRAVITY TELEGRAM BOT - CONFIGURATION INITIALE" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1. Ouvre Telegram et cherche @BotFather" -ForegroundColor Yellow
    Write-Host "2. Envoie-lui /newbot, choisis un nom et un username (ex: MonAntigravityBot)" -ForegroundColor Yellow
    Write-Host "3. Copie le Token HTTP API (ex: 123456789:AAH...)" -ForegroundColor Yellow
    Write-Host ""
    $inputToken = Read-Host "Colle ton Token Telegram Bot ici"
    if ([string]::IsNullOrWhiteSpace($inputToken)) {
        Write-Host "Aucun token fourni. Fermeture." -ForegroundColor Red
        exit 1
    }
    $config.botToken = $inputToken.Trim()
    Save-Config
} else {
    Save-Config
}

$TgBaseUrl = "https://api.telegram.org/bot$($config.botToken)"

# --- Discover Local Antigravity Language Server ---
$script:lsPort = $null
$script:lsCsrf = $null

function Connect-AntigravityServer {
    $procs = Get-CimInstance Win32_Process -Filter "Name = 'language_server.exe'" -ErrorAction SilentlyContinue
    if (-not $procs) {
        return $false
    }
    foreach ($proc in $procs) {
        $cmd = $proc.CommandLine
        if ($cmd -match "--csrf_token\s+([a-fA-F0-9\-]+)") {
            $csrf = $Matches[1]
            $conns = Get-NetTCPConnection -OwningProcess $proc.ProcessId -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalAddress -eq "127.0.0.1" }
            foreach ($c in $conns) {
                $port = $c.LocalPort
                try {
                    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, "http://127.0.0.1:$port/exa.language_server_pb.LanguageServerService/GetUserStatus")
                    $req.Headers.Add("x-codeium-csrf-token", $csrf)
                    $req.Headers.Add("Connect-Protocol-Version", "1")
                    $req.Content = [System.Net.Http.StringContent]::new("{}", [System.Text.Encoding]::UTF8, "application/json")
                    $resp = $httpClient.SendAsync($req).GetAwaiter().GetResult()
                    if ($resp.IsSuccessStatusCode) {
                        $script:lsPort = $port
                        $script:lsCsrf = $csrf
                        return $true
                    }
                } catch {}
            }
        }
    }
    return $false
}

function Invoke-LsRpc([string]$method, [string]$jsonBody = "{}") {
    if (-not $script:lsPort -or -not $script:lsCsrf) {
        if (-not (Connect-AntigravityServer)) {
            throw "Serveur Antigravity (language_server.exe) introuvable. Verifie qu'Antigravity est bien ouvert sur le PC."
        }
    }
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            $uri = "http://127.0.0.1:$($script:lsPort)/exa.language_server_pb.LanguageServerService/$method"
            $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $uri)
            $req.Headers.Add("x-codeium-csrf-token", $script:lsCsrf)
            $req.Headers.Add("Connect-Protocol-Version", "1")
            $req.Content = [System.Net.Http.StringContent]::new($jsonBody, [System.Text.Encoding]::UTF8, "application/json")
            $resp = $httpClient.SendAsync($req).GetAwaiter().GetResult()
            $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            $str = [System.Text.Encoding]::UTF8.GetString($bytes)
            if (-not $resp.IsSuccessStatusCode) {
                throw "HTTP $($resp.StatusCode): $str"
            }
            return ($str | ConvertFrom-Json)
        } catch {
            if ($attempt -eq 1) {
                Connect-AntigravityServer | Out-Null
            } else {
                throw $_
            }
        }
    }
}

# --- Telegram API Helpers ---
function Invoke-TgApi([string]$method, [hashtable]$payload) {
    try {
        $json = $payload | ConvertTo-Json -Depth 10 -Compress
        $content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, "application/json")
        $resp = $httpClient.PostAsync("$TgBaseUrl/$method", $content).GetAwaiter().GetResult()
        $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $str = [System.Text.Encoding]::UTF8.GetString($bytes)
        return ($str | ConvertFrom-Json)
    } catch {
        Write-Host "[TG Error $method] $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

function Get-MainReplyKeyboard {
    return @{
        keyboard = @(
            @(
                @{ text = "$EMOJI_CHAT Conversations" },
                @{ text = "$EMOJI_ROBOT Modele" },
                @{ text = "$EMOJI_CHART Limites" }
            ),
            @(
                @{ text = "$EMOJI_NEW Nouvelle conv" },
                @{ text = "$EMOJI_CAM Ecran PC" },
                @{ text = "$EMOJI_STOP Stop" }
            )
        )
        resize_keyboard = $true
        is_persistent = $true
    }
}

function Send-TgMessage([long]$chatId, [string]$text, $replyMarkup = $null) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $maxLen = 3900
    $chunks = @()
    $remaining = $text
    while ($remaining.Length -gt $maxLen) {
        $splitIdx = $remaining.LastIndexOf("`n", $maxLen)
        if ($splitIdx -lt 500) { $splitIdx = $maxLen }
        $chunks += $remaining.Substring(0, $splitIdx)
        $remaining = $remaining.Substring($splitIdx).TrimStart("`r", "`n")
    }
    if ($remaining.Length -gt 0) { $chunks += $remaining }

    $lastResp = $null
    for ($i = 0; $i -lt $chunks.Count; $i++) {
        $payload = @{
            chat_id = $chatId
            text    = $chunks[$i]
        }
        if ($i -eq ($chunks.Count - 1)) {
            if ($null -ne $replyMarkup) {
                $payload.reply_markup = $replyMarkup
            } else {
                $payload.reply_markup = Get-MainReplyKeyboard
            }
        }
        $lastResp = Invoke-TgApi "sendMessage" $payload
    }
    return $lastResp
}

function Edit-TgMessage([long]$chatId, [long]$messageId, [string]$text, $inlineMarkup = $null) {
    $payload = @{
        chat_id    = $chatId
        message_id = $messageId
        text       = $text
    }
    if ($null -ne $inlineMarkup) {
        $payload.reply_markup = $inlineMarkup
    }
    return Invoke-TgApi "editMessageText" $payload
}

function Send-TgPhoto([long]$chatId, [string]$filePath, [string]$caption = "") {
    if (-not (Test-Path $filePath)) { return }
    try {
        $multipart = New-Object System.Net.Http.MultipartFormDataContent
        $chatIdContent = New-Object System.Net.Http.StringContent($chatId.ToString())
        $multipart.Add($chatIdContent, "chat_id")
        if ($caption) {
            if ($caption.Length -gt 950) { $caption = $caption.Substring(0, 950) + "..." }
            $capContent = New-Object System.Net.Http.StringContent($caption, [System.Text.Encoding]::UTF8)
            $multipart.Add($capContent, "caption")
        }
        $fileBytes = [System.IO.File]::ReadAllBytes($filePath)
        $byteContent = New-Object System.Net.Http.ByteArrayContent($fileBytes, 0, $fileBytes.Length)
        $fileName = [System.IO.Path]::GetFileName($filePath)
        $multipart.Add($byteContent, "photo", $fileName)
        $resp = $httpClient.PostAsync("$TgBaseUrl/sendPhoto", $multipart).GetAwaiter().GetResult()
        $multipart.Dispose()
    } catch {
        Write-Host "[Send-TgPhoto Error] $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Send-TgDocument([long]$chatId, [string]$filePath, [string]$caption = "") {
    if (-not (Test-Path $filePath)) { return }
    try {
        $multipart = New-Object System.Net.Http.MultipartFormDataContent
        $chatIdContent = New-Object System.Net.Http.StringContent($chatId.ToString())
        $multipart.Add($chatIdContent, "chat_id")
        if ($caption) {
            $capContent = New-Object System.Net.Http.StringContent($caption, [System.Text.Encoding]::UTF8)
            $multipart.Add($capContent, "caption")
        }
        $fileBytes = [System.IO.File]::ReadAllBytes($filePath)
        $byteContent = New-Object System.Net.Http.ByteArrayContent($fileBytes, 0, $fileBytes.Length)
        $fileName = [System.IO.Path]::GetFileName($filePath)
        $multipart.Add($byteContent, "document", $fileName)
        $resp = $httpClient.PostAsync("$TgBaseUrl/sendDocument", $multipart).GetAwaiter().GetResult()
        $multipart.Dispose()
    } catch {
        Write-Host "[Send-TgDocument Error] $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Download-TgFile([string]$fileId, [string]$destFileName) {
    $res = Invoke-TgApi "getFile" @{ file_id = $fileId }
    if (-not $res -or -not $res.ok) { return $null }
    $tgFilePath = $res.result.file_path
    $downloadUrl = "https://api.telegram.org/file/bot$($config.botToken)/$tgFilePath"
    $localPath = Join-Path $UploadsDir $destFileName
    $bytes = $httpClient.GetByteArrayAsync($downloadUrl).GetAwaiter().GetResult()
    [System.IO.File]::WriteAllBytes($localPath, $bytes)
    return $localPath
}

function Format-MarkdownToCleanText([string]$md) {
    if ([string]::IsNullOrWhiteSpace($md)) { return "" }
    $clean = [regex]::Replace($md, '\[([^\]]+)\]\(file:///[^\)]+\)', '$1')
    return $clean
}

function Extract-LocalImagesFromMarkdown([string]$md) {
    $paths = @()
    if ([string]::IsNullOrWhiteSpace($md)) { return $paths }
    $matches = [regex]::Matches($md, 'file:///([A-Za-z]:/[^\)\s"]+\.(?:jpg|jpeg|png|webp))', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($m in $matches) {
        $p = $m.Groups[1].Value -replace '/', '\'
        $p = [uri]::UnescapeDataString($p)
        if ((Test-Path $p) -and ($paths -notcontains $p)) {
            $paths += $p
        }
    }
    return $paths
}

# --- Antigravity High-Level Actions ---
function Get-SortedConversations {
    $res = Invoke-LsRpc "GetAllCascadeTrajectories" "{}"
    $list = @()
    if ($res -and $res.trajectorySummaries) {
        foreach ($prop in $res.trajectorySummaries.PSObject.Properties) {
            $cid = $prop.Name
            $val = $prop.Value
            $list += [PSCustomObject]@{
                cascadeId        = $cid
                summary          = if ($val.summary) { [string]$val.summary } else { "Conversation sans titre" }
                stepCount        = [int]$val.stepCount
                status           = [string]$val.status
                lastModifiedTime = [string]$val.lastModifiedTime
            }
        }
    }
    return ($list | Sort-Object -Property lastModifiedTime -Descending)
}

function Ensure-ActiveConversation {
    $convs = Get-SortedConversations
    if ([string]::IsNullOrWhiteSpace($config.activeCascadeId) -and $convs.Count -gt 0) {
        $config.activeCascadeId = $convs[0].cascadeId
        Save-Config
    }
    return $convs
}

function Show-Dashboard([long]$chatId) {
    try {
        $convs = Ensure-ActiveConversation
        $activeConv = $convs | Where-Object { $_.cascadeId -eq $config.activeCascadeId } | Select-Object -First 1
        if (-not $activeConv -and $convs.Count -gt 0) {
            $activeConv = $convs[0]
            $config.activeCascadeId = $activeConv.cascadeId
            Save-Config
        }
        $convTitle = if ($activeConv) { $activeConv.summary } else { "Aucune" }
        $convSteps = if ($activeConv) { $activeConv.stepCount } else { 0 }
        $convStatus = if ($activeConv -and $activeConv.status -eq "CASCADE_RUN_STATUS_RUNNING") { "$EMOJI_GREEN En cours d'execution" } else { "$EMOJI_WHITE Pret (En attente)" }
        $shortId = if ($config.activeCascadeId.Length -ge 8) { $config.activeCascadeId.Substring(0,8) } else { $config.activeCascadeId }

        $statusRes = Invoke-LsRpc "GetUserStatus" "{}"
        $quotaPct = "N/A"
        if ($statusRes -and $statusRes.userStatus.cascadeModelConfigData.clientModelConfigs) {
            $m = $statusRes.userStatus.cascadeModelConfigData.clientModelConfigs | Where-Object { $_.modelOrAlias.model -eq $config.selectedModel } | Select-Object -First 1
            if (-not $m) { $m = $statusRes.userStatus.cascadeModelConfigData.clientModelConfigs[0] }
            if ($m -and $m.quotaInfo -and $null -ne $m.quotaInfo.remainingFraction) {
                $quotaPct = "$([Math]::Round([double]$m.quotaInfo.remainingFraction * 100, 1))%"
            }
        }

        $msg = @(
            "$EMOJI_BOLT ANTIGRAVITY REMOTE CONTROL (PC ACTIF)"
            "----------------------------------------"
            "$EMOJI_CHAT Conversation active :"
            "   $convTitle"
            "   ID : $shortId... ($convSteps etapes)"
            "   Statut : $convStatus"
            ""
            "$EMOJI_ROBOT Modele selectionne :"
            "   $($config.selectedModelLabel)"
            "   Quota restant : $quotaPct"
            "----------------------------------------"
            "Envoie directement :"
            "- Un message texte pour travailler sur le projet"
            "- Un message vocal ($EMOJI_MIC) : Antigravity l'ecoute directement"
            "- Une photo ou un fichier ($EMOJI_IMG / $EMOJI_FILE) : transfere sur le PC"
            "- Ou utilise les boutons ci-dessous :"
        ) -join "`n"

        Send-TgMessage $chatId $msg | Out-Null
    } catch {
        Send-TgMessage $chatId "$EMOJI_WARN Erreur lors de la recuperation du statut Antigravity : $($_.Exception.Message)" | Out-Null
    }
}

function Show-ConversationPicker([long]$chatId) {
    try {
        $convs = Ensure-ActiveConversation | Select-Object -First 10
        if ($convs.Count -eq 0) {
            Send-TgMessage $chatId "Aucune conversation trouvee." | Out-Null
            return
        }
        $buttons = @()
        foreach ($c in $convs) {
            $isCurrent = ($c.cascadeId -eq $config.activeCascadeId)
            $icon = if ($isCurrent) { $EMOJI_CHECK } elseif ($c.status -eq "CASCADE_RUN_STATUS_RUNNING") { $EMOJI_GREEN } else { $EMOJI_CHAT }
            $shortTitle = $c.summary
            if ($shortTitle.Length -gt 34) { $shortTitle = $shortTitle.Substring(0, 34) + "..." }
            $btnText = "$icon $shortTitle ($($c.stepCount))"
            $buttons += ,@(
                @{
                    text          = $btnText
                    callback_data = "conv:$($c.cascadeId)"
                }
            )
        }
        $buttons += ,@(
            @{
                text          = "$EMOJI_NEW Creer une nouvelle conversation"
                callback_data = "new_conv"
            }
        )
        $markup = @{ inline_keyboard = $buttons }
        Send-TgMessage $chatId "$EMOJI_CHAT Choisis la conversation Antigravity a controler :" $markup | Out-Null
    } catch {
        Send-TgMessage $chatId "$EMOJI_WARN Erreur : $($_.Exception.Message)" | Out-Null
    }
}

function Show-ModelPicker([long]$chatId) {
    try {
        $statusRes = Invoke-LsRpc "GetUserStatus" "{}"
        $models = $statusRes.userStatus.cascadeModelConfigData.clientModelConfigs
        $buttons = @()
        foreach ($m in $models) {
            $modelCode = [string]$m.modelOrAlias.model
            $label = [string]$m.label
            $pct = ""
            if ($m.quotaInfo -and $null -ne $m.quotaInfo.remainingFraction) {
                $pct = " [$([Math]::Round([double]$m.quotaInfo.remainingFraction * 100, 0))%]"
            }
            $icon = if ($modelCode -eq $config.selectedModel) { $EMOJI_CHECK } else { $EMOJI_ROBOT }
            $buttons += ,@(
                @{
                    text          = "$icon $label$pct"
                    callback_data = "model:$modelCode"
                }
            )
        }
        $markup = @{ inline_keyboard = $buttons }
        Send-TgMessage $chatId "$EMOJI_ROBOT Choisis le modele IA pour tes prochains messages :" $markup | Out-Null
    } catch {
        Send-TgMessage $chatId "$EMOJI_WARN Erreur : $($_.Exception.Message)" | Out-Null
    }
}

function Make-ProgressBar([double]$fraction) {
    $clamped = [Math]::Max(0.0, [Math]::Min(1.0, $fraction))
    $filled = [int][Math]::Round($clamped * 10)
    $empty = 10 - $filled
    $fullChar = [char]0x2588
    $emptyChar = [char]0x2591
    return (([string]$fullChar * $filled) + ([string]$emptyChar * $empty))
}

function Show-LimitsAndQuota([long]$chatId) {
    try {
        $statusRes = Invoke-LsRpc "GetUserStatus" "{}"
        $user = $statusRes.userStatus
        $planName = $user.planStatus.planInfo.planName
        $lines = @(
            "$EMOJI_CHART LIMITES D'UTILISATION & CONTEXTE"
            "----------------------------------------"
            "Compte : $($user.name) ($($user.email))"
            "Forfait : Antigravity $planName"
            ""
            "QUOTA DES MODELES :"
        )

        foreach ($m in $user.cascadeModelConfigData.clientModelConfigs) {
            $frac = if ($m.quotaInfo -and $null -ne $m.quotaInfo.remainingFraction) { [double]$m.quotaInfo.remainingFraction } else { 1.0 }
            $pct = [Math]::Round($frac * 100, 1)
            $bar = Make-ProgressBar $frac
            $resetStr = ""
            if ($m.quotaInfo -and $m.quotaInfo.resetTime) {
                try {
                    $dt = [DateTime]::Parse([string]$m.quotaInfo.resetTime).ToLocalTime()
                    $resetStr = " (Reset: $($dt.ToString('dd/MM HH:mm')))"
                } catch {}
            }
            $check = if ($m.modelOrAlias.model -eq $config.selectedModel) { "$EMOJI_CHECK " } else { "- " }
            $lines += "$check$($m.label)"
            $lines += "   [$bar] $pct% restant$resetStr"
        }

        if ($config.activeCascadeId) {
            try {
                $genReq = @{
                    cascadeId               = $config.activeCascadeId
                    generatorMetadataOffset = 0
                } | ConvertTo-Json -Compress
                $genRes = Invoke-LsRpc "GetCascadeTrajectoryGeneratorMetadata" $genReq
                if ($genRes -and $genRes.generatorMetadata -and $genRes.generatorMetadata.Count -gt 0) {
                    $lastMeta = $genRes.generatorMetadata[-1]
                    $ctx = $lastMeta.chatModel.chatStartMetadata.contextWindowMetadata
                    if ($ctx -and $ctx.maxContextTokens) {
                        $used = [int]$ctx.estimatedTokensUsed
                        $max  = [int]$ctx.maxContextTokens
                        $ctxFrac = [double]$used / [double]$max
                        $ctxPct = [Math]::Round($ctxFrac * 100, 1)
                        $ctxBar = Make-ProgressBar $ctxFrac
                        $lines += ""
                        $lines += "FENETRE DE CONTEXTE (Conv. active) :"
                        $lines += "   [$ctxBar] $ctxPct% utilise"
                        $lines += "   $([Math]::Round($used/1000, 1))k / $([Math]::Round($max/1000, 0))k tokens"
                    }
                }
            } catch {}
        }

        Send-TgMessage $chatId ($lines -join "`n") | Out-Null
    } catch {
        Send-TgMessage $chatId "$EMOJI_WARN Erreur lors de la lecture des limites : $($_.Exception.Message)" | Out-Null
    }
}

function Send-PcScreenshot([long]$chatId) {
    try {
        $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bmp)
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $graphics.Dispose()
        $shotPath = Join-Path $UploadsDir "screen_$(Get-Date -Format 'yyyyMMdd_HHmmss').jpg"
        $bmp.Save($shotPath, [System.Drawing.Imaging.ImageFormat]::Jpeg)
        $bmp.Dispose()
        Send-TgPhoto $chatId $shotPath "$EMOJI_CAM Capture d'ecran du PC en direct ($(Get-Date -Format 'HH:mm:ss'))"
    } catch {
        Send-TgMessage $chatId "$EMOJI_WARN Impossible de capturer l'ecran : $($_.Exception.Message)" | Out-Null
    }
}

function Get-LastAssistantResponse([string]$cascadeId) {
    $convs = Get-SortedConversations
    $c = $convs | Where-Object { $_.cascadeId -eq $cascadeId } | Select-Object -First 1
    if (-not $c -or $c.stepCount -le 0) { return "Aucun message dans cette conversation." }
    $offset = [Math]::Max(0, $c.stepCount - 35)
    $req = @{
        cascadeId  = $cascadeId
        stepOffset = $offset
    } | ConvertTo-Json -Compress
    $res = Invoke-LsRpc "GetCascadeTrajectorySteps" $req
    if (-not $res -or -not $res.steps) { return "Aucune reponse trouvee." }
    $plannerSteps = $res.steps | Where-Object { $_.type -eq "CORTEX_STEP_TYPE_PLANNER_RESPONSE" -and $_.plannerResponse.response }
    if ($plannerSteps) {
        $last = $plannerSteps[-1]
        return [string]$last.plannerResponse.response
    }
    return "Aucune reponse texte recente."
}

function Start-NewAntigravityConversation([long]$chatId, [string]$initialPrompt = "") {
    try {
        $startReq = @{
            requestedModel = $config.selectedModel
            workspaceUris  = @($config.workspaceUri)
        } | ConvertTo-Json -Compress
        $res = Invoke-LsRpc "StartCascade" $startReq
        if ($res -and $res.cascadeId) {
            $config.activeCascadeId = [string]$res.cascadeId
            Save-Config
            Send-TgMessage $chatId "$EMOJI_NEW Nouvelle conversation creee et activee !`nID : $($config.activeCascadeId)`nModele : $($config.selectedModelLabel)" | Out-Null
            if (-not [string]::IsNullOrWhiteSpace($initialPrompt)) {
                Send-PromptToAntigravity $chatId $initialPrompt
            }
        } else {
            Send-TgMessage $chatId "$EMOJI_WARN Impossible de creer la conversation." | Out-Null
        }
    } catch {
        Send-TgMessage $chatId "$EMOJI_WARN Erreur StartCascade : $($_.Exception.Message)" | Out-Null
    }
}

# --- Watcher State for Live Streaming of Thinking, Tools & Full Responses ---
$watchState = @{
    active          = $false
    cascadeId       = ""
    startStepIndex  = 0
    statusMessageId = 0
    lastStatusText  = ""
    idleTicks       = 0
    startedAt       = [DateTime]::Now
    sentItems       = @{}
}

function Format-ToolCallSummary($tc) {
    $name = [string]$tc.name
    $argsRaw = [string]$tc.argumentsJson
    $detail = ""
    try {
        $argsObj = $argsRaw | ConvertFrom-Json
        if ($argsObj.Path) { $detail = " -> $($argsObj.Path)" }
        elseif ($argsObj.CommandLine) { $detail = " -> $($argsObj.CommandLine)" }
        elseif ($argsObj.query) { $detail = " -> $($argsObj.query)" }
        elseif ($argsObj.toolSummary) { $detail = " ($($argsObj.toolSummary))" }
    } catch {}
    return "$EMOJI_TOOL Outil : $name$detail"
}

function Send-PromptToAntigravity([long]$chatId, [string]$promptText) {
    try {
        $convs = Ensure-ActiveConversation
        $activeConv = $convs | Where-Object { $_.cascadeId -eq $config.activeCascadeId } | Select-Object -First 1
        $currentStepCount = if ($activeConv) { [int]$activeConv.stepCount } else { 0 }

        $cascadeCfg = Get-Content $DefaultCascadeConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $cascadeCfg.plannerConfig.planModel = $config.selectedModel

        $msgReq = @{
            cascadeId     = $config.activeCascadeId
            items         = @(
                @{ text = $promptText }
            )
            cascadeConfig = $cascadeCfg
        } | ConvertTo-Json -Depth 20 -Compress

        try {
            Invoke-LsRpc "SendUserCascadeMessage" $msgReq | Out-Null
        } catch {
            $agentApi = Join-Path $env:USERPROFILE ".gemini\antigravity\bin\agentapi.bat"
            if (Test-Path $agentApi) {
                & $agentApi send-message $config.activeCascadeId $promptText | Out-Null
            } else {
                throw $_
            }
        }

        $stopMarkup = @{
            inline_keyboard = @(
                @(
                    @{
                        text          = "$EMOJI_STOP Arreter la generation"
                        callback_data = "stop_run"
                    }
                )
            )
        }
        $statusText = "$EMOJI_WAIT Antigravity travaille sur ta demande...`nModele : $($config.selectedModelLabel)"
        $sent = Send-TgMessage $chatId $statusText $stopMarkup
        $msgId = if ($sent -and $sent.ok) { [long]$sent.result.message_id } else { 0 }

        $watchState.active          = $true
        $watchState.cascadeId       = $config.activeCascadeId
        $watchState.startStepIndex  = $currentStepCount
        $watchState.statusMessageId = $msgId
        $watchState.lastStatusText  = $statusText
        $watchState.idleTicks       = 0
        $watchState.startedAt       = [DateTime]::Now
        $watchState.sentItems       = @{}
    } catch {
        Send-TgMessage $chatId "$EMOJI_WARN Erreur lors de l'envoi a Antigravity : $($_.Exception.Message)" | Out-Null
    }
}

function Step-Watcher([long]$chatId) {
    if (-not $watchState.active -or $chatId -eq 0) { return }
    try {
        $convs = Get-SortedConversations
        $c = $convs | Where-Object { $_.cascadeId -eq $watchState.cascadeId } | Select-Object -First 1
        if (-not $c) {
            $watchState.active = $false
            return
        }

        $offset = [Math]::Max(0, $watchState.startStepIndex)
        $req = @{
            cascadeId  = $watchState.cascadeId
            stepOffset = $offset
        } | ConvertTo-Json -Compress
        $stepsRes = Invoke-LsRpc "GetCascadeTrajectorySteps" $req
        $steps = if ($stepsRes -and $stepsRes.steps) { @($stepsRes.steps) } else { @() }

        $activityDesc = "Reflexion en cours..."
        for ($i = 0; $i -lt $steps.Count; $i++) {
            $s = $steps[$i]
            $absIdx = $offset + $i
            $t = [string]$s.type
            $st = [string]$s.status
            $isStepFinished = ($st -ne "CORTEX_STEP_STATUS_GENERATING" -and $st -ne "CORTEX_STEP_STATUS_RUNNING" -and $st -ne "CORTEX_STEP_STATUS_PENDING")

            if ($t -eq "CORTEX_STEP_TYPE_RUN_COMMAND") {
                $activityDesc = "$EMOJI_TOOL Execution d'une commande..."
            } elseif ($t -eq "CORTEX_STEP_TYPE_READ_FILE" -or $t -eq "CORTEX_STEP_TYPE_VIEW_FILE") {
                $activityDesc = "$EMOJI_FILE Lecture de fichier..."
            } elseif ($t -eq "CORTEX_STEP_TYPE_EDIT_FILE" -or $t -eq "CORTEX_STEP_TYPE_WRITE_FILE" -or $t -eq "CORTEX_STEP_TYPE_CODE_ACTION") {
                $activityDesc = "$EMOJI_SPARK Modification du code..."
            } elseif ($t -eq "CORTEX_STEP_TYPE_PLANNER_RESPONSE") {
                if (-not $isStepFinished) {
                    $activityDesc = "$EMOJI_BRAIN Reflexion / Redaction en cours..."
                } else {
                    # 1. Send Thinking if present and not yet sent
                    $thinkKey = "think_$absIdx"
                    if ($s.plannerResponse -and -not [string]::IsNullOrWhiteSpace($s.plannerResponse.thinking) -and -not $watchState.sentItems.ContainsKey($thinkKey)) {
                        $watchState.sentItems[$thinkKey] = $true
                        $thinkText = Format-MarkdownToCleanText ([string]$s.plannerResponse.thinking).Trim()
                        Send-TgMessage $chatId "$EMOJI_BRAIN Reflexion (Etape $absIdx) :`n`n$thinkText" | Out-Null
                    }

                    # 2. Send Tool Calls if present and not yet sent
                    $toolsKey = "tools_$absIdx"
                    if ($s.plannerResponse -and $s.plannerResponse.toolCalls -and $s.plannerResponse.toolCalls.Count -gt 0 -and -not $watchState.sentItems.ContainsKey($toolsKey)) {
                        $watchState.sentItems[$toolsKey] = $true
                        $toolLines = @()
                        foreach ($tc in $s.plannerResponse.toolCalls) {
                            $toolLines += (Format-ToolCallSummary $tc)
                        }
                        Send-TgMessage $chatId ($toolLines -join "`n") | Out-Null
                    }

                    # 3. Send Full Planner Response if present and not yet sent
                    $respKey = "resp_$absIdx"
                    if ($s.plannerResponse -and -not [string]::IsNullOrWhiteSpace($s.plannerResponse.response) -and -not $watchState.sentItems.ContainsKey($respKey)) {
                        $watchState.sentItems[$respKey] = $true
                        $rawMd = [string]$s.plannerResponse.response
                        $cleanText = Format-MarkdownToCleanText $rawMd
                        Send-TgMessage $chatId "$EMOJI_ROBOT Reponse d'Antigravity :`n`n$cleanText" | Out-Null

                        $imgs = Extract-LocalImagesFromMarkdown $rawMd
                        $imgCount = 0
                        foreach ($imgPath in $imgs) {
                            if ($imgCount -lt 5) {
                                Send-TgPhoto $chatId $imgPath ([System.IO.Path]::GetFileName($imgPath))
                                $imgCount++
                            }
                        }
                    }
                }
            }
        }

        $elapsed = [int]([DateTime]::Now - $watchState.startedAt).TotalSeconds
        if ($c.status -eq "CASCADE_RUN_STATUS_RUNNING") {
            $watchState.idleTicks = 0
            if ($watchState.statusMessageId -gt 0) {
                $newStatus = "$EMOJI_WAIT Antigravity travaille... (${elapsed}s)`nEtape : $($c.stepCount) | $activityDesc"
                if ($newStatus -ne $watchState.lastStatusText) {
                    $stopMarkup = @{
                        inline_keyboard = @(
                            @(
                                @{
                                    text          = "$EMOJI_STOP Arreter"
                                    callback_data = "stop_run"
                                }
                            )
                        )
                    }
                    Edit-TgMessage $chatId $watchState.statusMessageId $newStatus $stopMarkup | Out-Null
                    $watchState.lastStatusText = $newStatus
                }
            }
        } else {
            if ($c.stepCount -gt $watchState.startStepIndex -or $elapsed -gt 6) {
                $watchState.idleTicks++
            }
            if ($watchState.idleTicks -ge 2) {
                $watchState.active = $false
                if ($watchState.statusMessageId -gt 0) {
                    Edit-TgMessage $chatId $watchState.statusMessageId "$EMOJI_CHECK Termine en ${elapsed}s ($($c.stepCount) etapes)." | Out-Null
                }
                # Fallback if no response was sent during streaming
                $anyRespSent = $false
                foreach ($k in $watchState.sentItems.Keys) {
                    if ($k -like "resp_*") { $anyRespSent = $true; break }
                }
                if (-not $anyRespSent) {
                    $fallback = Get-LastAssistantResponse $watchState.cascadeId
                    $cleanFallback = Format-MarkdownToCleanText $fallback
                    Send-TgMessage $chatId "$EMOJI_ROBOT Reponse d'Antigravity :`n`n$cleanFallback" | Out-Null
                }
            }
        }
    } catch {
        Write-Host "[Watcher Error] $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# --- Verify Bot Token & Start Polling Loop ---
$me = Invoke-TgApi "getMe" @{}
if (-not $me -or -not $me.ok) {
    Write-Host "ERREUR : Le Token Telegram est invalide ($($config.botToken))." -ForegroundColor Red
    Write-Host "Supprime $ConfigPath ou relance avec un token valide." -ForegroundColor Yellow
    exit 1
}

$botUsername = $me.result.username
Connect-AntigravityServer | Out-Null
Ensure-ActiveConversation | Out-Null

Write-Host "==========================================================" -ForegroundColor Green
Write-Host "   BOT TELEGRAM ANTIGRAVITY ACTIF : @$botUsername" -ForegroundColor Green
Write-Host "   Port local Antigravity         : $($script:lsPort)" -ForegroundColor Green
Write-Host "   Anti-Veille Windows            : ACTIVE" -ForegroundColor Green
if ($config.authorizedChatId -ne 0) {
    Write-Host "   Verrouille sur Chat ID         : $($config.authorizedChatId)" -ForegroundColor Green
} else {
    Write-Host "   En attente de ton 1er message sur Telegram (@$botUsername)..." -ForegroundColor Yellow
}
Write-Host "==========================================================" -ForegroundColor Green

if ($config.authorizedChatId -ne 0) {
    Send-TgMessage $config.authorizedChatId "$EMOJI_GREEN Bot Antigravity connecte sur ton PC (@$botUsername) !`nEnvoie /menu ou utilise les boutons ci-dessous." | Out-Null
}

$offset = 0
$pendingPhotos = @()

while ($true) {
    try {
        [PowerHelper]::KeepAwake()
        $pollTimeout = if ($watchState.active) { 2 } else { 20 }
        $updatesRes = Invoke-TgApi "getUpdates" @{
            offset          = $offset
            timeout         = $pollTimeout
            allowed_updates = @("message", "callback_query")
        }

        if ($updatesRes -and $updatesRes.ok -and $updatesRes.result) {
            foreach ($upd in $updatesRes.result) {
                $offset = [long]$upd.update_id + 1

                if ($upd.callback_query) {
                    $cb = $upd.callback_query
                    $cbChatId = [long]$cb.message.chat.id
                    $cbData = [string]$cb.data

                    if ($config.authorizedChatId -eq 0) {
                        $config.authorizedChatId = $cbChatId
                        Save-Config
                    }
                    if ($cbChatId -ne $config.authorizedChatId) { continue }

                    Invoke-TgApi "answerCallbackQuery" @{ callback_query_id = $cb.id } | Out-Null

                    if ($cbData -like "conv:*") {
                        $newCid = $cbData.Substring(5)
                        $config.activeCascadeId = $newCid
                        Save-Config
                        $convs = Get-SortedConversations
                        $sel = $convs | Where-Object { $_.cascadeId -eq $newCid } | Select-Object -First 1
                        $title = if ($sel) { $sel.summary } else { $newCid }
                        $lastMsg = Format-MarkdownToCleanText (Get-LastAssistantResponse $newCid)
                        Send-TgMessage $cbChatId "$EMOJI_CHECK Conversation activee :`n$title`n`n--- Dernier message complet ---`n$lastMsg" | Out-Null
                    }
                    elseif ($cbData -like "model:*") {
                        $newModel = $cbData.Substring(6)
                        $config.selectedModel = $newModel
                        $statusRes = Invoke-LsRpc "GetUserStatus" "{}"
                        $mObj = $statusRes.userStatus.cascadeModelConfigData.clientModelConfigs | Where-Object { $_.modelOrAlias.model -eq $newModel } | Select-Object -First 1
                        if ($mObj) { $config.selectedModelLabel = [string]$mObj.label }
                        Save-Config
                        Send-TgMessage $cbChatId "$EMOJI_CHECK Modele change pour : $($config.selectedModelLabel)" | Out-Null
                    }
                    elseif ($cbData -eq "new_conv") {
                        Start-NewAntigravityConversation $cbChatId ""
                    }
                    elseif ($cbData -eq "stop_run") {
                        try {
                            $cancelReq = @{ cascadeId = $config.activeCascadeId } | ConvertTo-Json -Compress
                            Invoke-LsRpc "CancelCascadeInvocation" $cancelReq | Out-Null
                            $watchState.active = $false
                            Send-TgMessage $cbChatId "$EMOJI_STOP Execution interrompue sur la conversation active." | Out-Null
                        } catch {
                            Send-TgMessage $cbChatId "$EMOJI_WARN Erreur lors de l'arret : $($_.Exception.Message)" | Out-Null
                        }
                    }
                    elseif ($cbData -eq "analyze_photos") {
                        if ($pendingPhotos.Count -gt 0) {
                            $listStr = ($pendingPhotos | ForEach-Object { "- $_" }) -join "`n"
                            $pendingPhotos = @()
                            $prompt = "[Images envoyees depuis Telegram :`n$listStr`n] Inspecte ces images avec l'outil read_file et dis-moi ce que tu vois ou traite-les selon le contexte du projet."
                            Send-PromptToAntigravity $cbChatId $prompt
                        }
                    }
                    continue
                }

                if ($upd.message) {
                    $msg = $upd.message
                    $chatId = [long]$msg.chat.id

                    if ($config.authorizedChatId -eq 0) {
                        $config.authorizedChatId = $chatId
                        Save-Config
                        Write-Host "Compte Telegram autorise verrouille sur Chat ID : $chatId" -ForegroundColor Green
                    }
                    if ($chatId -ne $config.authorizedChatId) {
                        Send-TgMessage $chatId "Acces refuse. Ce bot est verrouille sur le proprietaire du PC." | Out-Null
                        continue
                    }

                    # 1. Voice Message or Audio File
                    if ($msg.voice -or $msg.audio) {
                        $fileId = if ($msg.voice) { [string]$msg.voice.file_id } else { [string]$msg.audio.file_id }
                        $dur = if ($msg.voice) { [int]$msg.voice.duration } else { [int]$msg.audio.duration }
                        $ext = if ($msg.voice) { ".ogg" } else { ".mp3" }
                        $fileName = "vocal_$(Get-Date -Format 'yyyyMMdd_HHmmss')$ext"
                        $savedPath = Download-TgFile $fileId $fileName
                        if ($savedPath) {
                            Send-TgMessage $chatId "$EMOJI_MIC Message vocal recu (${dur}s) -> transmis a Antigravity..." | Out-Null
                            $voicePrompt = "[Message vocal envoye depuis Telegram : $savedPath]`nUtilise immediatement l'outil read_file sur ce fichier audio ($savedPath) pour ecouter mon message vocal. Indique d'abord en une phrase courte ce que tu as compris de mon vocal, puis execute exactement mes instructions."
                            Send-PromptToAntigravity $chatId $voicePrompt
                        } else {
                            Send-TgMessage $chatId "$EMOJI_WARN Echec du telechargement du message vocal." | Out-Null
                        }
                        continue
                    }

                    # 2. Photo Message
                    if ($msg.photo) {
                        $bestPhoto = $msg.photo[-1]
                        $fileId = [string]$bestPhoto.file_id
                        $fileName = "photo_$(Get-Date -Format 'yyyyMMdd_HHmmss_fff').jpg"
                        $savedPath = Download-TgFile $fileId $fileName
                        if ($savedPath) {
                            $caption = if ($msg.caption) { [string]$msg.caption } else { "" }
                            if (-not [string]::IsNullOrWhiteSpace($caption)) {
                                $allPhotos = $pendingPhotos + @($savedPath)
                                $pendingPhotos = @()
                                $pathsStr = ($allPhotos | ForEach-Object { "- $_" }) -join "`n"
                                $photoPrompt = "[Image(s) transferee(s) depuis Telegram :`n$pathsStr`n]`nInstruction de l'utilisateur : $caption`n(Utilise l'outil read_file sur ce(s) fichier(s) pour voir les images et executer la demande)."
                                Send-PromptToAntigravity $chatId $photoPrompt
                            } else {
                                $pendingPhotos += $savedPath
                                $photoMarkup = @{
                                    inline_keyboard = @(
                                        @(
                                            @{
                                                text          = "$EMOJI_SPARK Analyser maintenant avec Antigravity"
                                                callback_data = "analyze_photos"
                                            }
                                        )
                                    )
                                }
                                Send-TgMessage $chatId "$EMOJI_IMG Photo enregistree sur le PC :`n$savedPath`n($($pendingPhotos.Count) photo(s) en attente)`n`nEcris ton instruction (ex: 'Recadre cette photo') ou clique ci-dessous :" $photoMarkup | Out-Null
                            }
                        }
                        continue
                    }

                    # 3. Document / File
                    if ($msg.document) {
                        $doc = $msg.document
                        $origName = if ($doc.file_name) { [string]$doc.file_name } else { "document_$(Get-Date -Format 'HHmmss')" }
                        $safeName = "$(Get-Date -Format 'yyyyMMdd_HHmmss')_$origName"
                        $savedPath = Download-TgFile ([string]$doc.file_id) $safeName
                        if ($savedPath) {
                            $caption = if ($msg.caption) { [string]$msg.caption } else { "" }
                            if (-not [string]::IsNullOrWhiteSpace($caption)) {
                                $docPrompt = "[Fichier transfere depuis Telegram : $savedPath]`nInstruction : $caption"
                                Send-PromptToAntigravity $chatId $docPrompt
                            } else {
                                $pendingPhotos += $savedPath
                                Send-TgMessage $chatId "$EMOJI_FILE Fichier enregistre sur le PC :`n$savedPath`nEcris maintenant ce qu'Antigravity doit faire avec ce fichier." | Out-Null
                            }
                        }
                        continue
                    }

                    # 4. Text Commands & Prompts
                    if ($msg.text) {
                        $txt = ([string]$msg.text).Trim()

                        if ($txt -eq "/start" -or $txt -eq "/menu" -or $txt -eq "/help") {
                            Show-Dashboard $chatId
                            continue
                        }
                        if ($txt -eq "/conv" -or $txt -eq "/conversations" -or $txt -like "*Conversations*") {
                            Show-ConversationPicker $chatId
                            continue
                        }
                        if ($txt -eq "/model" -or $txt -eq "/modele" -or $txt -like "*Modele*") {
                            Show-ModelPicker $chatId
                            continue
                        }
                        if ($txt -eq "/limites" -or $txt -eq "/quota" -or $txt -like "*Limites*") {
                            Show-LimitsAndQuota $chatId
                            continue
                        }
                        if ($txt -eq "/screen" -or $txt -like "*Ecran PC*") {
                            Send-PcScreenshot $chatId
                            continue
                        }
                        if ($txt -eq "/stop" -or $txt -like "*Stop*") {
                            try {
                                $cancelReq = @{ cascadeId = $config.activeCascadeId } | ConvertTo-Json -Compress
                                Invoke-LsRpc "CancelCascadeInvocation" $cancelReq | Out-Null
                                $watchState.active = $false
                                Send-TgMessage $chatId "$EMOJI_STOP Execution interrompue." | Out-Null
                            } catch {
                                Send-TgMessage $chatId "$EMOJI_WARN Erreur Stop : $($_.Exception.Message)" | Out-Null
                            }
                            continue
                        }
                        if ($txt -eq "/new" -or $txt -like "*Nouvelle conv*") {
                            Start-NewAntigravityConversation $chatId ""
                            continue
                        }
                        if ($txt -like "/new *") {
                            $newPrompt = $txt.Substring(5).Trim()
                            Start-NewAntigravityConversation $chatId $newPrompt
                            continue
                        }
                        if ($txt -like "/file *") {
                            $reqFile = $txt.Substring(6).Trim().Trim('"')
                            if (Test-Path $reqFile) {
                                Send-TgDocument $chatId $reqFile "Fichier depuis le PC : $reqFile"
                            } else {
                                Send-TgMessage $chatId "$EMOJI_WARN Fichier introuvable : $reqFile" | Out-Null
                            }
                            continue
                        }
                        if ($txt -eq "/last") {
                            $lastResp = Format-MarkdownToCleanText (Get-LastAssistantResponse $config.activeCascadeId)
                            Send-TgMessage $chatId "$EMOJI_ROBOT Derniere reponse :`n`n$lastResp" | Out-Null
                            continue
                        }

                        $finalPrompt = $txt
                        if ($pendingPhotos.Count -gt 0) {
                            $pathsStr = ($pendingPhotos | ForEach-Object { "- $_" }) -join "`n"
                            $pendingPhotos = @()
                            $finalPrompt = "[Fichier(s) / Image(s) joint(s) depuis Telegram :`n$pathsStr`n]`nInstruction : $txt`n(Utilise l'outil read_file pour lire/voir les fichiers joints)."
                        }
                        Send-PromptToAntigravity $chatId $finalPrompt
                    }
                }
            }
        }

        if ($watchState.active -and $config.authorizedChatId -ne 0) {
            Step-Watcher $config.authorizedChatId
        }
    } catch {
        Write-Host "[Loop Error] $($_.Exception.Message)" -ForegroundColor Yellow
        Start-Sleep -Seconds 3
    }
}
