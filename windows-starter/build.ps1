param(
    [string]$Version = "0.5.2",
    [switch]$SelfContained
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

Write-Host "==> 运行核心领域层测试 (Englishwords.Core.Tests)"
dotnet test tests\Englishwords.Core.Tests\Englishwords.Core.Tests.csproj -c Release
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$PublishDir = Join-Path $Root "build\publish-win-x64"
$DistDir = Join-Path $Root "build\dist"
if (Test-Path $PublishDir) { Remove-Item $PublishDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

$SelfContainedFlag = if ($SelfContained) { "true" } else { "false" }
Write-Host "==> 发布 Windows x64 客户端 (SelfContained=$SelfContainedFlag)"
dotnet publish src\Englishwords.Win\Englishwords.Win.csproj `
    -c Release `
    -r win-x64 `
    --self-contained $SelfContainedFlag `
    -o $PublishDir `
    "-p:Version=$Version"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$ExePath = Join-Path $PublishDir "Englishwords.Win.exe"
Write-Host "==> 随包词库自检: --check-word unbelievable"
$OutLog = Join-Path $PublishDir "selfcheck-out.txt"
$ErrLog = Join-Path $PublishDir "selfcheck-err.txt"
$Proc = Start-Process -FilePath $ExePath -ArgumentList "--check-word","unbelievable" -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog -NoNewWindow -PassThru -Wait
$CheckOut = if (Test-Path $OutLog) { Get-Content $OutLog -Raw } else { "" }
$CheckErr = if (Test-Path $ErrLog) { Get-Content $ErrLog -Raw } else { "" }
Remove-Item $OutLog, $ErrLog -Force -ErrorAction SilentlyContinue
if ($CheckOut) { Write-Host $CheckOut }
if ($CheckErr) { Write-Host $CheckErr }
if ($Proc.ExitCode -ne 0 -or $CheckOut -notmatch "词素:") {
    Write-Error "随包词库或词素库自检失败 (ExitCode=$($Proc.ExitCode))"
    exit 1
}

$ZipName = "Englishwords-$Version-win-x64.zip"
$ZipPath = Join-Path $DistDir $ZipName
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
Compress-Archive -Path "$PublishDir\*" -DestinationPath $ZipPath

$Hash = (Get-FileHash $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
"$Hash  $ZipName" | Out-File -FilePath "$ZipPath.sha256" -Encoding ascii

Write-Host "==> 打包完成: $ZipPath"
